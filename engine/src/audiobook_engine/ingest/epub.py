"""EPUB → Book.

Chapters are cut at table-of-contents targets (file + optional #anchor) in
spine order, not one-per-file: real EPUBs often put several chapters in one
XHTML file, or split one chapter across several files.
"""

from __future__ import annotations

import codecs
import posixpath
import re
import warnings
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

import ebooklib
from ebooklib import epub
from lxml import etree, html

from ..models import Book, Cover, IngestError, Section
from .classify import (
    BACK_TYPES,
    FRONT_TYPES,
    classify_section,
    detect_language,
    looks_like_title,
    matter_title,
    normalize_language,
)

EPUB_NS = "http://www.idpf.org/2007/ops"
EPUB_TYPE = f"{{{EPUB_NS}}}type"

BLOCK_TAGS = {
    "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "div", "section",
    "article", "pre", "dt", "dd", "address", "header", "footer", "main", "body",
    "ul", "ol", "dl", "figure", "hr", "center",
}
HEADING_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6"}
# Dropped entirely (with their text). Tables are not narrated in v1.
SKIP_TAGS = {
    "script", "style", "table", "img", "svg", "math", "rt", "rp", "nav", "audio",
    "video", "object", "iframe", "figcaption", "head", "title",
}
# Note bodies, note calls and page-break markers: dropped with their text.
NOTE_TYPES = {"noteref", "footnote", "endnote", "rearnote", "note", "doc-noteref",
              "doc-footnote", "doc-endnote", "pagebreak", "doc-pagebreak"}
# Containers holding a list of notes. They are not dropped: like any typed
# front/back-matter container they become a section of their own (back matter,
# unticked), even when they sit at the end of a chapter's file.
NOTE_CONTAINER_TYPES = {"footnotes", "endnotes", "rearnotes", "doc-endnotes"}
_NOTE_TARGET_TYPES = (NOTE_TYPES - {"noteref", "doc-noteref", "pagebreak", "doc-pagebreak"}) | NOTE_CONTAINER_TYPES
# epub:type / role values that make a container front or back matter.
MATTER_TYPES = FRONT_TYPES | BACK_TYPES


def _local(tag) -> str:
    if not isinstance(tag, str):
        return ""  # comments, processing instructions
    return tag.rsplit("}", 1)[-1].lower()


def _types(el) -> set[str]:
    vals = (el.get(EPUB_TYPE) or "") + " " + (el.get("epub:type") or "") + " " + (el.get("role") or "")
    return {v.lower() for v in vals.split() if v}


def _el_id(el) -> str | None:
    """The element's id; legacy <a name="..."> anchors count as ids too."""
    if not isinstance(el.tag, str):
        return None
    return el.get("id") or (el.get("name") if _local(el.tag) == "a" else None) or None


# --------------------------------------------------------------------------- note calls

# Set by _mark_note_calls on <a>/<sup> elements that are note calls.
_NOTE_ATTR = "data-abe-note"
_MARKER_TEXT = re.compile(r"\[?[\d*†‡§ivx]+\]?", re.IGNORECASE)
_SYMBOL_MARKER = re.compile(r"\[?[*†‡§]+\]?")
_DIGIT_MARKER = re.compile(r"\[?\d+\]?")
_NOTE_CLASS = re.compile(
    r"footnote|endnote|rearnote|noteref|note[-_]?(?:ref|link|call|anchor|marker)|fn[-_]?(?:ref|link|anchor)"
    r"|(?:^|[\s_-])notes?(?:$|[\s_-])"
)
_URL_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)


def _is_note(el) -> bool:
    return bool(_types(el) & NOTE_TYPES) or el.get(_NOTE_ATTR) == "1"


def _link_target(href: str, base_file: str) -> tuple[str, str] | None:
    """(file, fragment) of a link with a fragment; file is "" for an external URL."""
    if "#" not in href:
        return None
    if _URL_SCHEME.match(href):
        return "", href.partition("#")[2]
    path, _, frag = unquote(href).partition("#")
    if not frag:
        return None
    if not path:
        return base_file, frag
    return posixpath.normpath(posixpath.join(posixpath.dirname(base_file), path)), frag


def _note_like(el) -> bool:
    """The element, or a container around it, is a note or a list of notes."""
    x = el
    while x is not None:
        if isinstance(x.tag, str) and (
            _types(x) & _NOTE_TARGET_TYPES or _NOTE_CLASS.search((x.get("class") or "").lower())
        ):
            return True
        x = x.getparent()
    return False


def _heading_like(el) -> bool:
    """A heading, inside one, or a container of headings: a structural link target, not a note."""
    if _local(el.tag) in HEADING_TAGS or any(_local(a.tag) in HEADING_TAGS for a in el.iterancestors()):
        return True
    return any(_local(d.tag) in HEADING_TAGS for d in el.iterdescendants())


def _block_ancestor(el):
    for a in el.iterancestors():
        if _local(a.tag) in BLOCK_TAGS:
            return a
    return None


@dataclass
class _NoteIndex:
    files: set[str]                                   # documents in the reading order
    ids: dict[tuple[str, str], object] = field(default_factory=dict)
    note_targets: set[tuple[str, str]] = field(default_factory=set)
    links: set[tuple[str, str, str]] = field(default_factory=set)   # (source file, target file, id)
    linked: set[tuple[str, str]] = field(default_factory=set)       # (target file, id)
    toc_ids: set[tuple[str, str]] = field(default_factory=set)      # (file, id) the table of contents points at
    notes_files: set[str] = field(default_factory=set)              # documents whose first heading is "Notes"
    blocks: dict = field(default_factory=dict)                      # block element -> (text, link targets)


# The whole first heading of a page of notes: "Notes", "NOTES", "Endnotes", "Footnotes:"
# (not a book title such as "Notes from Underground" heading its contents page).
_NOTES_HEADING = re.compile(r"\s*(?:end|foot)?\s*notes\s*[\W\d]*", re.IGNORECASE)


def _note_index(docs: list[tuple[str, object]], extra_docs=(), toc_ids=frozenset()) -> _NoteIndex:
    """Ids and links of the reading-order documents, plus those of extra_docs.

    extra_docs are documents outside the reading order (non-linear note pages,
    the navigation document): their links back to a note call are evidence too.
    """
    idx = _NoteIndex(files={fn for fn, _ in docs}, toc_ids=set(toc_ids))
    for fn, body in [*docs, *extra_docs]:
        first_heading = True
        for el in body.iter():
            if not isinstance(el.tag, str):
                continue
            if first_heading and _local(el.tag) in HEADING_TAGS:
                first_heading = False
                if _NOTES_HEADING.fullmatch(_clean("".join(el.itertext()))):
                    idx.notes_files.add(fn)
            eid = _el_id(el)
            if eid:
                idx.ids.setdefault((fn, eid), el)
                if _note_like(el):
                    idx.note_targets.add((fn, eid))
            if _local(el.tag) == "a" and el.get("href"):
                tgt = _link_target(el.get("href"), fn)
                if tgt and tgt[0]:
                    idx.links.add((fn, *tgt))
                    idx.linked.add(tgt)
    return idx


def _is_note_link(a, fn: str, idx: _NoteIndex) -> bool:
    """A bare number/symbol link is a note call only with a note signal.

    Without one ("see Chapter <a href='#ch3'>3</a>") it is a cross-reference
    and its text is narrated.
    """
    tgt = _link_target(a.get("href") or "", fn)
    if tgt is None:
        return False
    text = _clean("".join(a.itertext()))
    if not _MARKER_TEXT.fullmatch(text):
        return False
    block = _block_ancestor(a)
    if block is not None and _block_facts(block, fn, idx)[0] == text:
        return False  # the link is the whole block: a numbered heading or a contents line
    if _NOTE_CLASS.search((a.get("class") or "").lower()) or _SYMBOL_MARKER.fullmatch(text) or text.startswith("["):
        return True  # cross-references are never written "[3]"
    if any(_local(x.tag) == "sup" for x in a.iterancestors()) or any(
        _local(d.tag) == "sup" for d in a.iterdescendants()
    ):
        return True
    file, frag = tgt
    if (file, frag) in idx.note_targets:
        return True
    target = idx.ids.get((file, frag))
    heading = next((x for x in a.iterancestors() if _local(x.tag) in HEADING_TAGS), None)
    if heading is not None:
        # "<h2><a href='toc.xhtml#c3'>III</a> The Return</h2>" links back to the contents and is
        # narrated. A note call on a heading ("<h2>Introduction<a id='r2' href='notes.xhtml#n2'>2</a></h2>")
        # is one whose note links back to it, and whose target is not a contents entry for the heading.
        return _backlinked(a, fn, file, idx) and not _contents_entry(a, text, heading, fn, file, target, idx)
    if not file or file not in idx.files:
        return True  # external, or outside the reading order (note pages are usually non-linear)
    if target is not None and (
        _heading_like(target)
        or _types(target) & {"pagebreak", "doc-pagebreak"}
        or "page" in (target.get("class") or "").lower()
    ):
        return False  # "see Chapter <a href='#ch3'>3</a>", "see page <a href='#p12'>12</a>"
    # Untyped endnotes (Calibre, InDesign) link back to their call...
    if _backlinked(a, fn, file, idx):
        return True
    # ...or are a paragraph/item starting with their own number ("3. The source is...").
    # (Not an inline target: from a note back to its call, that would be the call itself.)
    if (
        target is not None
        and _local(target.tag) in BLOCK_TAGS | {"aside"}
        and re.match(rf"\s*\[?{re.escape(text.strip('[]'))}(?![\w])", "".join(target.itertext()))
    ):
        return True
    return False


def _own_ids(a) -> set[str]:
    """Ids a note can link back to for this call: the link's own, or the <sup>/<span> around it."""
    parent = a.getparent()
    ids = {_el_id(a), _el_id(parent) if parent is not None and _local(parent.tag) in {"span", "sup", "small"} else None}
    return {i for i in ids if i}


def _backlinked(a, fn: str, file: str, idx: _NoteIndex) -> bool:
    """The target file links back to this call: a note and its call."""
    return any((file, fn, i) in idx.links for i in _own_ids(a))


def _words(text: str) -> str:
    return " ".join(re.findall(r"\w+", text.casefold()))


def _contents_entry(a, text: str, heading, fn: str, file: str, target, idx: _NoteIndex) -> bool:
    """The link in a heading points at a contents entry for that heading, not at a note."""
    if (fn, _el_id(a) or "") in idx.toc_ids:
        return True  # the link carries the chapter's own anchor: the contents links to the chapter
    if target is None:
        return False
    if _heading_like(target):
        return True
    if file in idx.notes_files:
        # A page headed "Notes": a note that quotes the heading ("An earlier version of this
        # introduction..."), or a note number on a line of its own, is still a note.
        return False
    entry = target if _local(target.tag) in BLOCK_TAGS else (_block_ancestor(target) or target)
    entry_text = _words("".join(entry.itertext()))
    if not re.search(r"[^\W\d_]", entry_text):
        return True  # a bare number: a contents line, never a note (a note has words)
    rest = _words(" ".join(_clean("".join(heading.itertext())).rsplit(text, 1)))
    return bool(rest) and f" {rest} " in f" {entry_text} "


# A note call directly follows sentence punctuation or a closing quote ("born.¹").
_CALL_AFTER = set(".,;:!?…\"'”’»")


def _texts_reversed(node):
    """The text inside node (not its tail), last piece first."""
    for c in reversed(node):
        if c.tail:
            yield c.tail
        if isinstance(c.tag, str):
            yield from _texts_reversed(c)
    if isinstance(node.tag, str) and node.text:
        yield node.text


def _text_before(el, enough: int = 40) -> str:
    """The end of the text of el's block that comes before el (about `enough` characters)."""
    block = _block_ancestor(el)
    out: list[str] = []
    size = 0

    def pieces():
        x = el
        while x is not None and x is not block:
            s = x.getprevious()
            while s is not None:
                if s.tail:
                    yield s.tail
                if isinstance(s.tag, str):
                    yield from _texts_reversed(s)
                s = s.getprevious()
            x = x.getparent()
            if x is not None and isinstance(x.tag, str) and x.text:
                yield x.text

    for piece in pieces():
        out.append(piece)
        size += len(piece.strip())
        if size >= enough:
            break
    return "".join(reversed(out))


def _is_note_sup(sup, fn: str, idx: _NoteIndex) -> bool:
    """<sup><a href="#fn1">1</a></sup> and <sup>*</sup> are note calls; a bare <sup>2</sup> needs a signal."""
    text = _clean("".join(sup.itertext()))
    if not text:
        return False
    if any(_local(d.tag) == "a" and d.get("href") for d in sup.iterdescendants()):
        return True
    if _SYMBOL_MARKER.fullmatch(text):
        return True
    if not _DIGIT_MARKER.fullmatch(text):
        return False  # "er", "e", "me": French ordinals
    if _NOTE_CLASS.search((sup.get("class") or "").lower()):
        return True
    sid = _el_id(sup)
    if sid and (fn, sid) in idx.linked:
        return True  # a note links back to this call
    # An unlinked number after sentence punctuation ("born.¹") is a note call; after a digit
    # or a letter it may be an exponent ("10⁶", "m/s²") and is narrated. In a heading, where
    # exponents are rare, a number after a word ("Introduction¹") is a note call too; a
    # one- or two-letter unit or variable ("km²", "mc²") still keeps it.
    before = _clean(_text_before(sup))
    if not before:
        return False
    if before[-1] in _CALL_AFTER:
        return True
    if any(_local(x.tag) in HEADING_TAGS for x in sup.iterancestors()):
        word = re.search(r"[^\W\d_]+$", before)
        return bool(word) and len(word.group(0)) >= 3
    return False


_NOTE_BODY_TAGS = {"p", "li", "div", "aside", "dd", "blockquote"}


def _block_facts(block, fn: str, idx: _NoteIndex) -> tuple[str, set]:
    """(clean text, link targets) of a block, computed once per block.

    When all the notes share one large container, every call points into the
    same block: reading it again for each call would be quadratic.
    """
    facts = idx.blocks.get(block)
    if facts is None:
        text = _clean("".join(block.itertext()))
        links = {_link_target(x.get("href") or "", fn) for x in block.iter() if isinstance(x.tag, str) and _local(x.tag) == "a"}
        facts = idx.blocks[block] = (text, links)
    return facts


def _inline_note_body(a, fn: str, idx: _NoteIndex):
    """The untyped note a note call points at in its own file (Kindle, Calibre), or None.

    Only a short paragraph/item that starts with the call's number and links
    back to the call counts: "<p id='n3'><a href='#r3'>3</a> The note.</p>".
    """
    tgt = _link_target(a.get("href") or "", fn)
    if tgt is None or tgt[0] != fn:
        return None
    target = idx.ids.get(tgt)
    if target is None:
        return None
    block = target if _local(target.tag) in _NOTE_BODY_TAGS else _block_ancestor(target)
    if block is None or _local(block.tag) not in _NOTE_BODY_TAGS or any(x is block for x in a.iterancestors()):
        return None
    text, links = _block_facts(block, fn, idx)
    links_back = any((fn, i) in links for i in _own_ids(a))
    marker = _clean("".join(a.itertext())).strip("[]")
    if not links_back or len(text) > 3000 or not re.match(rf"\[?{re.escape(marker)}(?![\w])", text):
        return None
    return block


def _mark_note_calls(docs: list[tuple[str, object]], extra_docs=(), toc_ids=frozenset()) -> None:
    """Decide once, with the whole book in view, which <a>/<sup> elements are note calls.

    An untyped note in the same file as its call is marked too, so it is not
    narrated in the middle or at the end of the chapter.
    """
    idx = _note_index(docs, extra_docs, toc_ids)
    for fn, body in docs:
        for el in body.iter():
            if not isinstance(el.tag, str):
                continue
            tag = _local(el.tag)
            if tag == "a" and _is_note_link(el, fn, idx):
                el.set(_NOTE_ATTR, "1")
                if (note := _inline_note_body(el, fn, idx)) is not None:
                    note.set(_NOTE_ATTR, "1")
            elif tag == "sup" and _is_note_sup(el, fn, idx):
                el.set(_NOTE_ATTR, "1")


# --------------------------------------------------------------------------- text extraction

# Words naming a caption, page number or footnote, inside a class token. "pageno" and
# "pagebreak" must not run on into another word ("pagenormal", "pagenote", "pagebreaker",
# "pagebreakbefore"), and "captionless" is not a caption.
_SKIP_CLASS_WORD = re.compile(r"caption(?!less)|pagenum|pageno(?![a-z])|page-number|pagebreak(?![a-z])|footnote|fnanchor")
# Classes that contain a skip word but style real content: CSS utility classes such as
# "pagebreak-before" or "nopagebreak", "captioned-image" (a figure with its text), and
# "AfterCaptionText" (the paragraph after a caption).
_CONTENT_CLASS = re.compile(r"[-_](?:before|after|inside|avoid)$|^no[-_]?page[-_]?break|captioned|aftercaption")
# A decorative first letter, possibly with its opening quote: "W", "“I", "«L".
_DROP_CAP = re.compile(r"^[\"'“‘«„]?\s?[A-Za-zÀ-ÿ]{1,3}[\"'”’»]?$")


def _skip_class(cls: str) -> bool:
    """Class tokens naming a caption, page number or footnote.

    A token matches when it contains the word, whatever the case or what is
    glued to it ("x-ebookmaker-pageno", "imgcaption", "MsoFootnoteText",
    "footnotetext", "captiontext"), unless it styles content
    ("captioned-image", "pagebreak-before", "PageBreakBefore", "PageNormal").
    """
    for tok in cls.lower().split():
        if _CONTENT_CLASS.search(tok):
            continue
        if _SKIP_CLASS_WORD.search(tok):
            return True
    return False


def _skip(el) -> bool:
    if _local(el.tag) in SKIP_TAGS or _is_note(el):
        return True
    return _skip_class(el.get("class") or "")


def _drop_cap_alt(el) -> str | None:
    """Decorative first letters are often images whose alt text is the letter."""
    if _local(el.tag) == "img":
        alt = (el.get("alt") or "").strip()
        if _DROP_CAP.match(alt):
            return alt
    return None


def _has_block_child(el) -> bool:
    for d in el.iterdescendants():
        if _local(d.tag) in BLOCK_TAGS and not _skipped_ancestor(d, el):
            return True
    return False


def _skipped_ancestor(el, stop) -> bool:
    p = el.getparent()
    while p is not None and p is not stop:
        if _skip(p):
            return True
        p = p.getparent()
    return False


def _inline_text(el) -> str:
    """Text of an element, excluding skipped descendants, keeping tails."""
    parts: list[str] = []

    def rec(e, include_self_text=True):
        if include_self_text and e.text:
            parts.append(e.text)
        for c in e:
            if not isinstance(c.tag, str):
                if c.tail:
                    parts.append(c.tail)
                continue
            if _local(c.tag) == "br":
                parts.append(" ")
            elif (alt := _drop_cap_alt(c)) is not None:
                parts.append(alt)
            elif not _skip(c):
                rec(c)
            if c.tail:
                parts.append(c.tail)

    rec(el)
    return _clean("".join(parts))


_WS = re.compile(r"\s+")


def _clean(text: str) -> str:
    text = text.replace("­", "")  # soft hyphen
    text = text.replace("​", "").replace("﻿", "")
    return _WS.sub(" ", text).strip()


@dataclass
class _Event:
    kind: str  # "id" or "block"
    value: str
    tag: str = ""
    types: set[str] = field(default_factory=set)
    cls: str = ""  # the block element's class attribute


def _walk(el, out: list[_Event], inherited_types: set[str], targets: set[str] = frozenset()) -> None:
    """Flatten a document into id and block events.

    targets are the anchors the table of contents points at in this document:
    they must become id events wherever they sit, even inside inline or
    skipped elements, or the chapter cut is lost.
    """
    if not isinstance(el.tag, str):
        return
    if _skip(el):
        out.extend(_Event("id", i, types=set(inherited_types)) for i in _ids_in(el))
        return
    types = inherited_types | _types(el)
    if eid := _el_id(el):
        out.append(_Event("id", eid, types=types))
    tag = _local(el.tag)
    if tag in BLOCK_TAGS and not _has_block_child(el):
        # ids nested inside a leaf block (e.g. <h2><a id="ch1"/>…) mark its start
        for d in el.iterdescendants():
            if did := _el_id(d):
                out.append(_Event("id", did, types=types))
        text = _inline_text(el)
        if text:
            out.append(_Event("block", text, tag, types, el.get("class") or ""))
        return
    # Mixed container: direct text runs become their own paragraphs.
    buf: list[str] = [el.text or ""]

    def flush():
        t = _clean("".join(buf))
        if t:
            out.append(_Event("block", t, "p", types))
        buf.clear()

    for c in el:
        if not isinstance(c.tag, str):
            buf.append(c.tail or "")
            continue
        ctag = _local(c.tag)
        if (ctag in BLOCK_TAGS or _has_block_child(c)) and not _skip(c):
            flush()
            _walk(c, out, types, targets)
            buf.append(c.tail or "")
            continue
        # Inline or skipped child: a TOC target inside it starts a new paragraph here.
        hit = [i for i in _ids_in(c) if i in targets] if targets else []
        if hit:
            flush()
            out.extend(_Event("id", i, types=types) for i in hit)
        if ctag == "br":
            buf.append(" ")
        elif (alt := _drop_cap_alt(c)) is not None:
            buf.append(alt)
        elif not _skip(c):
            buf.append(_inline_text(c))
        buf.append(c.tail or "")
    flush()


def _ids_in(el) -> list[str]:
    return [i for d in el.iter() if (i := _el_id(d))]


_XML_DECL_ENCODING = re.compile(rb"""^\s*<\?xml[^>]*?encoding\s*=\s*["']([A-Za-z0-9._:-]+)["']""")
_META_CHARSET = re.compile(rb"""<meta[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)""", re.IGNORECASE)
_BOMS = ((codecs.BOM_UTF8, "utf-8"), (codecs.BOM_UTF16_LE, "utf-16"), (codecs.BOM_UTF16_BE, "utf-16"))


def _html_encoding(content: bytes) -> str:
    """The document's encoding: its byte order mark; UTF-8 when the bytes hold non-ASCII text
    that is valid UTF-8 (EPUB content must be UTF-8 or UTF-16, so a legacy charset declared on
    valid UTF-8 is a stale template line); else the XML declaration or <meta charset> (which
    also covers 7-bit encodings such as ISO-2022-JP); else UTF-8."""
    for bom, name in _BOMS:
        if content.startswith(bom):
            return name
    if not content.isascii():
        try:
            content.decode("utf-8")
            return "utf-8"
        except UnicodeDecodeError:
            pass
    head = content[:4096]
    for pattern in (_XML_DECL_ENCODING, _META_CHARSET):
        m = pattern.search(head)
        if m:
            try:
                return codecs.lookup(m.group(1).decode("ascii")).name
            except (LookupError, UnicodeDecodeError):
                break
    return "utf-8"


def _parse_doc(content: bytes, as_html: bool = False):
    root = None
    if not as_html:
        try:
            parser = etree.XMLParser(recover=True, resolve_entities=False, no_network=True, huge_tree=True)
            root = etree.fromstring(content, parser)
        except Exception:
            root = None
    if root is None:
        text = content.decode(_html_encoding(content), errors="replace") if isinstance(content, bytes) else content
        text = re.sub(r"^\ufeff?\s*<\?xml[^>]*\?>", "", text)  # lxml refuses str input with an encoding declaration
        try:
            root = html.document_fromstring(text)
        except etree.ParserError:  # "Document is empty": an empty page, not a reason to abort the whole book
            root = html.document_fromstring("<html><body></body></html>")
    body = None
    for el in root.iter():
        if _local(el.tag) == "body":
            body = el
            break
    return root, body if body is not None else root


# --------------------------------------------------------------------------- spine and TOC

_HTML_MEDIA_TYPES = {"application/xhtml+xml", "text/html"}
_HTML_EXTENSIONS = (".xhtml", ".xht", ".html", ".htm")


def _is_text_document(item) -> bool:
    if item.get_type() == ebooklib.ITEM_DOCUMENT:
        return True
    media = (item.media_type or "").lower()
    return media in _HTML_MEDIA_TYPES or (item.file_name or "").lower().endswith(_HTML_EXTENSIONS)


def _item_body(item):
    if isinstance(item, epub.EpubHtml):
        return _parse_doc(item.get_content())[1]
    # Documents ebooklib does not recognise (e.g. declared text/html): parse the raw file.
    name = (item.file_name or "").lower()
    as_html = (item.media_type or "").lower() == "text/html" or name.endswith((".html", ".htm"))
    return _parse_doc(item.get_content(), as_html=as_html)[1]


def _flatten_toc(toc, depth=0, out=None):
    out = [] if out is None else out
    if toc is None:
        return out
    if not isinstance(toc, (list, tuple)):
        # ebooklib returns a bare, empty Link when the navigation document has no entries
        toc = [toc]
    for entry in toc:
        if isinstance(entry, tuple) or isinstance(entry, list):
            sec, children = entry[0], entry[1]
            href = getattr(sec, "href", "") or ""
            out.append((getattr(sec, "title", "") or "", href, depth))
            _flatten_toc(children, depth + 1, out)
        else:
            out.append((getattr(entry, "title", "") or "", getattr(entry, "href", "") or "", depth))
    return out


def _nav_toc(book: epub.EpubBook) -> list[tuple[str, str, int]]:
    """Entries of the EPUB 3 navigation document's toc, flattened like _flatten_toc.

    ebooklib only reads the nav when there is no NCX, so a stub NCX would hide
    a complete nav; read_epub compares both.
    """
    nav = next((i for i in book.get_items() if isinstance(i, epub.EpubNav)), None)
    if nav is None or not nav.content:
        return []
    try:
        root = _parse_doc(nav.content, as_html=True)[0]
    except Exception:
        return []
    base = posixpath.dirname(nav.file_name or "")
    out: list[tuple[str, str, int]] = []

    def parse(ol, depth: int) -> None:
        for li in ol:
            if _local(li.tag) != "li":
                continue
            label = next((c for c in li if _local(c.tag) in {"a", "span"}), None)
            title = _clean(label.text_content()) if label is not None else ""
            href = label.get("href") if label is not None and _local(label.tag) == "a" else ""
            if href and not _URL_SCHEME.match(href):
                path, sep, frag = href.partition("#")
                href = (posixpath.normpath(posixpath.join(base, path)) if path else "") + sep + frag
            out.append((title, href or "", depth))
            for sub in li:
                if _local(sub.tag) == "ol":
                    parse(sub, depth + 1)

    for el in root.iter():
        if isinstance(el.tag, str) and _local(el.tag) == "nav" and _types(el) & {"toc", "doc-toc"}:
            for ol in el:
                if _local(ol.tag) == "ol":
                    parse(ol, 0)
            break
    return out


def _resolve(href: str, file_names: dict[str, str]) -> tuple[str | None, str | None]:
    """Map a TOC href to (spine file_name, anchor)."""
    if not href:
        return None, None
    path, _, anchor = unquote(href).partition("#")
    path = posixpath.normpath(path) if path else ""
    if path in file_names:
        return file_names[path], anchor or None
    base = posixpath.basename(path)
    matches = [fn for key, fn in file_names.items() if posixpath.basename(key) == base]
    if len(matches) == 1:
        return matches[0], anchor or None
    return None, None


def _toc_cuts(toc, file_names, id_pos):
    """Cut points (event index -> (title, depth, outer titles)) for one TOC.

    Also returns the number of unresolved and not-found entries, and the
    (depth, spine file) of each resolved entry.
    """
    cut_at: dict[int, tuple[str, int, list[str]]] = {}
    unresolved = not_found = 0
    resolved: list[tuple[int, str]] = []
    for t_title, href, depth in toc:
        if not href:
            continue
        fn, anchor = _resolve(href, file_names)
        if fn is None:
            unresolved += 1
            continue
        pos = id_pos.get((fn, anchor or ""))
        if pos is None:
            not_found += 1
            continue
        resolved.append((depth, fn))
        title = _clean(t_title)
        if pos in cut_at:
            prev_title, prev_depth, prev_outer = cut_at[pos]
            # A parent entry and its first child often share a target ("Part I" and its
            # "Chapter 1"): keep both names, outermost first.
            if depth > prev_depth and title and title.lower() != prev_title.lower():
                cut_at[pos] = (title, depth, prev_outer + ([prev_title] if prev_title else []))
            continue
        cut_at[pos] = (title, depth, [])
    return cut_at, unresolved, not_found, resolved


_GUTENBERG_MARK = re.compile(r"^\*{3}\s*(START|END) OF (?:THE|THIS) PROJECT GUTENBERG", re.IGNORECASE)
# Older Gutenberg texts close with a one-line formula before the END marker:
# "End of Project Gutenberg's Le Tour du Monde en 80 Jours, by Jules Verne". Never narrated.
_GUTENBERG_END_LINE = re.compile(r"^\s*end of (?:the |this )?project gutenberg\b", re.IGNORECASE)
_NUMBERED = re.compile(
    r"^\s*(?:(chapter|chapitre|ch\.|book|livre|part|partie)\s+)?([IVXLCDM]+|\d{1,3})\b\.?", re.IGNORECASE
)
_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def _to_int(token: str) -> int | None:
    if token.isdigit():
        return int(token)
    token = token.upper()
    if not all(c in _ROMAN for c in token):
        return None
    total = 0
    for a, b in zip(token, token[1:] + " "):
        v = _ROMAN[a]
        total += -v if b != " " and _ROMAN[b] > v else v
    return total


def _number_of(title: str) -> tuple[str, int] | None:
    m = _NUMBERED.match(title or "")
    if not m:
        return None
    n = _to_int(m.group(2))
    return ((m.group(1) or "").lower(), n) if n else None


def _already_cut(events, cut_at, i: int, floor: int) -> bool:
    """True when an existing cut precedes event i with no text block in between."""
    j = i - 1
    while j > floor:
        if j in cut_at:
            return True
        if events[j][1].kind == "block":
            return False
        j -= 1
    return False


def _repair_numbering_gaps(events, cut_at: dict[int, tuple]) -> list[tuple[int, str]]:
    """Find headings for chapter numbers the TOC skips (e.g. I..XI, XIII).

    Only runs when most TOC entries are numbered in sequence, and only accepts
    a heading whose number is exactly the missing one, located between the
    neighbouring chapters. Returns (event index, heading text) pairs.
    """
    numbered = []
    for pos in sorted(cut_at):
        num = _number_of(cut_at[pos][0])
        if num:
            numbered.append((pos, num))
    if len(numbered) < 5:
        return []
    found: list[tuple[int, str]] = []
    for (p1, (pre1, n1)), (p2, (pre2, n2)) in zip(numbered, numbered[1:]):
        if pre1 != pre2 or n2 - n1 != 2:
            continue
        missing = n1 + 1
        for i in range(p1 + 1, p2):
            fn, ev = events[i]
            if ev.kind != "block" or ev.tag not in HEADING_TAGS:
                continue
            num = _number_of(ev.value)
            if num == (pre1, missing):
                if _already_cut(events, cut_at, i, p1):
                    break  # the TOC has this chapter under a title we could not parse
                # cut at the id event that introduces this heading, if any
                cut = i - 1 if i > 0 and events[i - 1][1].kind == "id" else i
                found.append((cut, ev.value))
                break
    return found


def _cover(book: epub.EpubBook) -> Cover | None:
    for item in book.get_items_of_type(ebooklib.ITEM_COVER):
        if item.get_content():
            return Cover(item.get_content(), item.media_type or "image/jpeg", "EPUB cover-image")
    meta = book.get_metadata("OPF", "cover")
    for _, attrs in meta or []:
        cid = (attrs or {}).get("content")
        item = book.get_item_with_id(cid) if cid else None
        if item is not None and item.get_content() and (item.media_type or "").startswith("image/"):
            return Cover(item.get_content(), item.media_type, "OPF <meta name='cover'>")
    images = [i for i in book.get_items_of_type(ebooklib.ITEM_IMAGE) if i.get_content()]
    named = [i for i in images if "cover" in (i.file_name or "").lower()]
    if named:
        best = max(named, key=lambda i: len(i.get_content()))
        return Cover(best.get_content(), best.media_type, f"image named {posixpath.basename(best.file_name)}")
    return None


# --------------------------------------------------------------------------- sections

def _matter_changes(section_types: set[str], block_types: set[str]) -> bool:
    """A typed front/back-matter container starts or ends between the section's opening and this block."""
    cur = section_types & MATTER_TYPES
    new = block_types & MATTER_TYPES
    return bool(new - cur) or (bool(cur) and not new)


def _opens_like_heading(ev: _Event) -> bool:
    """An <h1>-<h6>, or a block whose class marks it as a chapter title (<p class="chapter-title">)."""
    return ev.tag in HEADING_TAGS or looks_like_title(ev.value, [], ev.cls)


def _matter_label(types: set[str]) -> str:
    matter = sorted(types & MATTER_TYPES)
    if not matter:
        return ""
    return matter[0].removeprefix("doc-").replace("-", " ").capitalize()


def _title_parts(raw: dict) -> list[str]:
    return raw["outer"] + ([raw["title"]] if raw["title"] else [])


def _to_section(raw: dict, index: int) -> Section:
    blocks = raw["blocks"]
    paragraphs = [b.value for b in blocks]
    own_heading = next((b.value for b in blocks[raw["carried"]:][:3] if b.tag in HEADING_TAGS), "")
    title = raw["title"]
    # TOC titles sometimes include illustration captions; prefer the clean heading.
    if own_heading and title and own_heading != title and title.lower().endswith(own_heading.lower()):
        title = own_heading
    parts: list[str] = []
    for p in raw["outer"] + [title]:
        if p and (not parts or parts[-1].lower() != p.lower()):
            parts.append(p)
    heading = next((b.value for b in blocks[:3] if b.tag in HEADING_TAGS), "")
    sec_title = ": ".join(parts) or heading or _matter_label(raw["types"]) or (paragraphs[0][:60] if paragraphs else "")
    sec_title = sec_title or f"Section {index + 1}"
    first = blocks[0]
    sec = Section(
        index=index,
        title=sec_title,
        kind="chapter",
        paragraphs=paragraphs,
        # a <p class="chapter-title">CHAPTER ONE</p> is the heading as much as an <h2> is
        starts_with_heading=first.tag in HEADING_TAGS or looks_like_title(first.value, [sec_title, *parts], first.cls),
    )
    heading_ratio = sum(1 for b in blocks if b.tag in HEADING_TAGS) / len(blocks)
    # Classified from the types at the section's start (the TOC target and the
    # container of its opening text), not from every block it holds.
    classify_section(sec, raw["types"], heading_ratio=heading_ratio)
    if raw["forced"]:
        sec.kind = raw["forced"]
        sec.include = False
        sec.reasons = [raw["reason"]]
    elif raw["pre_toc"] and sec.kind == "chapter" and sec.chars < 1000:
        # Untitled text before the first table-of-contents entry: a title page.
        sec.kind, sec.include = "front", False
        sec.reasons = ["short page before the first table-of-contents entry (title page)"]
    return sec


def read_epub(path: str | Path) -> Book:
    path = Path(path)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            book = epub.read_epub(str(path), options={"ignore_ncx": False})
    except Exception as exc:  # ebooklib raises many types
        raise IngestError(f"Could not open EPUB: {exc}") from exc

    warn: list[str] = []
    book_title = _first_meta(book, "title") or path.stem
    author = _first_meta(book, "creator") or "Unknown"
    lang_raw = _first_meta(book, "language")
    lang_meta = normalize_language(lang_raw)

    # Spine documents in reading order (non-linear items such as note pages skipped).
    spine_items = []
    not_text: list[str] = []
    for idref, linear in book.spine:
        if str(linear).lower() == "no":
            continue
        item = book.get_item_with_id(idref)
        if item is None:
            not_text.append(f"{idref} (missing from the manifest)")
        elif _is_text_document(item):
            spine_items.append(item)
        elif not (item.media_type or "").lower().startswith("image/"):
            not_text.append(f"{item.file_name} ({item.media_type or 'unknown type'})")
    if not_text:
        warn.append(
            f"Skipped {len(not_text)} reading-order item(s) that are not text documents: {', '.join(not_text)}."
        )
    if not spine_items:
        raise IngestError("The EPUB has no readable documents in its spine.")

    file_names = {posixpath.normpath(i.file_name): i.file_name for i in spine_items}

    # Candidate tables of contents: ebooklib's (the NCX when present) and the EPUB 3 nav.
    tocs = [_flatten_toc(book.toc)]
    nav = _nav_toc(book)
    if nav:
        tocs.append(nav)
    targets: dict[str, set[str]] = {}
    for toc in tocs:
        for _, href, _ in toc:
            fn, anchor = _resolve(href, file_names)
            if fn and anchor:
                targets.setdefault(fn, set()).add(anchor)

    bodies = [(item, _item_body(item)) for item in spine_items]
    # Documents outside the reading order (non-linear note pages, the nav) are indexed for
    # their links back to note calls, but not narrated.
    in_spine = set(file_names)
    extra_docs = []
    for item in book.get_items():
        name = posixpath.normpath(item.file_name or "")
        if name not in in_spine and _is_text_document(item):
            try:
                extra_docs.append((name, _item_body(item)))
            except Exception:  # a broken page outside the reading order must not stop the book
                continue
    toc_ids = {(posixpath.normpath(fn), anchor) for fn, anchors in targets.items() for anchor in anchors}
    _mark_note_calls([(posixpath.normpath(item.file_name), body) for item, body in bodies], extra_docs, toc_ids)

    # Events per spine document, flattened in reading order.
    events: list[tuple[str, _Event]] = []
    for item, body in bodies:
        evs: list[_Event] = [_Event("id", "", types=_types(body))]  # file start marker (anchor "")
        _walk(body, evs, _types(body), targets.get(item.file_name, frozenset()))
        events.extend((item.file_name, e) for e in evs)

    id_pos: dict[tuple[str, str], int] = {}
    for i, (fn, ev) in enumerate(events):
        if ev.kind == "id":
            id_pos.setdefault((fn, ev.value), i)

    # Cut points from ebooklib's TOC (the NCX when present), unless the nav resolves more
    # entries at the NCX's own depth (a stub NCX), or as many plus deeper entries in files
    # the NCX never cuts at (an NCX listing only the parts, where the nav also lists their
    # chapters). A nav that merely adds the subsections inside the NCX's chapter files is
    # not preferred.
    toc, cut_at, unresolved, not_found, resolved = tocs[0], *_toc_cuts(tocs[0], file_names, id_pos)
    for other in tocs[1:]:
        o_cut, o_unres, o_nf, o_res = _toc_cuts(other, file_names, id_pos)
        top = max((d for d, _ in resolved), default=None)
        comparable = [d for d, _ in o_res if top is None or d <= top]
        cut_files = {f for _, f in resolved}
        new_files = top is not None and any(d > top and f not in cut_files for d, f in o_res)
        if len(comparable) > len(resolved) or (new_files and len(comparable) >= len(resolved)):
            if resolved:
                warn.append("The NCX table of contents is incomplete; used the EPUB 3 navigation document instead.")
            toc, cut_at, unresolved, not_found, resolved = other, o_cut, o_unres, o_nf, o_res
    if unresolved:
        warn.append(f"{unresolved} table-of-contents entries point outside the reading order and were ignored.")
    if not_found:
        warn.append(f"{not_found} table-of-contents anchors were not found in the text.")

    used_toc = bool(cut_at)
    if not used_toc:
        warn.append("No usable table of contents; one section per file, titled from its first heading.")
        cut_at = {id_pos[(i.file_name, "")]: ("", 0, []) for i in spine_items}
    else:
        for pos, gap_title in _repair_numbering_gaps(events, cut_at):
            cut_at[pos] = (gap_title, 0, [])
            warn.append(f"Recovered '{gap_title}', which is missing from the book's table of contents.")

    # Walk events into raw sections. Gutenberg START/END markers force boundaries, and
    # so does the start or end of a typed front/back-matter container (an endnotes list
    # at the end of a chapter file, acknowledgments the TOC does not list...).
    sections_raw: list[dict] = []
    current: dict | None = None

    def start(title: str = "", depth: int = 0, outer=(), forced: str | None = None, reason: str = "",
              types=()) -> dict:
        raw = {"title": title, "depth": depth, "outer": list(outer), "blocks": [], "types": set(types),
               "target_types": set(types), "opened": False, "carried": 0, "forced": forced, "reason": reason,
               "pre_toc": used_toc and not any(r.get("from_toc") for r in sections_raw), "from_toc": False,
               # owner: the TOC section this part belongs to; resume: (section, file) whose text an
               # inline matter container (a glossary list, per-page footnotes) interrupted
               "owner": None, "resume": None}
        sections_raw.append(raw)
        return raw

    def title_moves(owner: dict) -> bool:
        """The TOC title of a section that opened with typed matter belongs to the untyped text after it."""
        title = owner["title"]
        return bool(
            title and owner["types"] & MATTER_TYPES and not owner["target_types"] & MATTER_TYPES
            and matter_title(title) is None and not any(looks_like_title(b.value, [title]) for b in owner["blocks"])
        )

    for i, (fn, ev) in enumerate(events):
        if i in cut_at:
            t, d, outer = cut_at[i]
            current = start(t, d, outer, types=ev.types)
            current["from_toc"], current["pre_toc"] = True, False
        if ev.kind != "block":
            continue
        marker = _GUTENBERG_MARK.match(ev.value)
        if marker:
            if current is not None and marker.group(1).upper() == "START":
                current["forced"], current["reason"] = "front", "Project Gutenberg header"
                current = start()
            elif marker.group(1).upper() == "END":
                current = start("Project Gutenberg license", forced="back", reason="Project Gutenberg license text")
            continue  # the marker line itself is never narrated
        if len(ev.value) <= 300 and _GUTENBERG_END_LINE.match(ev.value):
            continue  # Gutenberg's closing formula
        if current is None:
            current = start()  # content before the first TOC target
        elif current["opened"] and _matter_changes(current["types"], ev.types):
            prev = current
            owner = prev if prev["from_toc"] else prev["owner"]
            if ev.types & MATTER_TYPES:
                current = start()
                current["owner"] = owner
                current["resume"] = prev["resume"] if prev["types"] & MATTER_TYPES else (prev, fn)
            elif prev["resume"] is not None and prev["resume"][1] == fn and not _opens_like_heading(ev):
                # Untyped text after a matter container inside a chapter (a glossary list,
                # per-page footnotes) is the rest of that chapter. (Text that opens with a
                # heading starts a section of its own: it may be a chapter the TOC leaves out.)
                current = prev["resume"][0]
            else:
                current = start()
                current["owner"] = owner
                if owner is not None and title_moves(owner):
                    # The TOC entry points at the file start, but its text comes after a typed
                    # preamble (a dedication, a copyright notice): the title belongs to this part.
                    current["title"], current["depth"], current["outer"] = owner["title"], owner["depth"], owner["outer"]
                    owner["title"], owner["depth"], owner["outer"] = "", 0, []
        if not current["opened"]:
            # The section's types are those of its start: the TOC target plus the
            # container of its opening text (headings first, up to the first paragraph).
            current["types"] |= ev.types
            current["opened"] = ev.tag not in HEADING_TAGS
        current["blocks"].append(ev)

    sections_raw = [r for r in sections_raw if r["blocks"]]  # image-only / empty targets

    # Merge heading-only sections (e.g. "Part One" pages) into the next one, but never a
    # title page before the TOC, front/back matter, or into front/back matter.
    provisional = [_to_section(r, n) for n, r in enumerate(sections_raw)]
    merged: list[dict] = []
    carry: dict | None = None
    for n, raw in enumerate(sections_raw):
        if carry is not None:
            raw["outer"] = _title_parts(carry) + raw["outer"]
            raw["carried"] = len(carry["blocks"])
            raw["blocks"] = carry["blocks"] + raw["blocks"]
            carry = None
        text_len = sum(len(b.value) for b in raw["blocks"])
        only_headings = all(b.tag in HEADING_TAGS for b in raw["blocks"])
        if (
            only_headings and text_len < 200 and n < len(sections_raw) - 1 and not raw["forced"]
            and not raw["pre_toc"] and provisional[n].kind == "chapter" and provisional[n + 1].kind == "chapter"
        ):
            nxt = sections_raw[n + 1]
            trial = {**nxt, "outer": _title_parts(raw) + nxt["outer"], "carried": len(raw["blocks"]),
                     "blocks": raw["blocks"] + nxt["blocks"]}
            # ...unless the result would no longer read as a chapter (a title page's three
            # headings on top of a short chapter look like a printed table of contents).
            if _to_section(trial, n).kind == "chapter":
                carry = raw
                continue
            if not used_toc and n == 0:
                # The first page of a book without a table of contents, only short headings that
                # cannot open chapter one ("The Book / A Novel / Jane Doe"): a title page.
                raw["forced"], raw["reason"] = "front", "headings only, before the first chapter (title page)"
        merged.append(raw)
    if carry is not None:
        merged.append(carry)

    sections = [_to_section(raw, n) for n, raw in enumerate(merged)]

    # A valid metadata language is kept, even one the engines do not speak (the pipeline
    # reports it); only a missing or meaningless value ("und", "mul", "zz") is detected.
    sample = " ".join(p for s in sections if s.kind == "chapter" for p in s.paragraphs)[:200000]
    detected = detect_language(sample)
    if lang_meta is None:
        language, lang_source = (detected, "detected") if detected else ("en", "default")
        if not detected:
            warn.append("Language could not be determined; assuming English.")
    else:
        language, lang_source = lang_meta, "metadata"
        if detected and detected != language:
            warn.append(f"Metadata says '{language}' but the text looks like '{detected}'.")

    cover = _cover(book)
    if cover is None:
        warn.append("No cover image found; the first page will not be used for EPUBs.")

    if not any(s.include for s in sections):
        warn.append("No section was selected automatically; please choose sections manually.")

    return Book(
        source_path=str(path),
        format="epub",
        title=_clean(book_title),
        author=_clean(author),
        language=language,
        language_source=lang_source,
        sections=sections,
        cover=cover,
        warnings=warn,
        metadata={
            "publisher": _first_meta(book, "publisher"),
            "date": _first_meta(book, "date"),
            "description": _first_meta(book, "description"),
            "identifier": _first_meta(book, "identifier"),
            "toc_entries": len(toc),
        },
    )


def _first_meta(book: epub.EpubBook, name: str) -> str | None:
    try:
        vals = book.get_metadata("DC", name)
    except Exception:
        return None
    for val, _attrs in vals or []:
        if val and str(val).strip():
            return re.sub(r"<[^>]+>", "", str(val)).strip()
    return None
