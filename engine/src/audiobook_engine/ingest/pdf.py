"""PDF → Book using PyMuPDF (AGPL-3.0; fine for a personal local tool).

PDFs have no semantic structure, so everything here is heuristic:
- chapters come from the PDF outline (bookmarks), else from large-font headings;
- running headers/footers are removed when the same text recurs in the page
  margins on many pages of the book, or on several nearby pages (a running
  head carrying the chapter title);
- hyphenated line breaks are rejoined and paragraphs that continue across a
  page break are merged.
Scanned PDFs (no text layer) are rejected: OCR is not part of v1.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from ..models import Book, Cover, IngestError, Section
from .classify import classify_section, detect_language, front_matter_signals, looks_like_title, normalize_language

MARGIN_FRACTION = 0.08
# A margin text seen on LOCAL_MIN of any LOCAL_WINDOW consecutive pages is a running head.
LOCAL_WINDOW = 10
LOCAL_MIN = 3
_PAGE_NUM = re.compile(r"^\s*([\divxlcdmIVXLCDM]{1,6}|page\s+\d+|\d+\s*/\s*\d+|[-–—]\s*\d+\s*[-–—])\s*$", re.IGNORECASE)
_END_PUNCT = re.compile(r"[.!?…:»”\"')\]]\s*$")
# Synthetic sections shorter than this, before the first outline entry, are front matter.
OPENING_PAGES_MAX_CHARS = 3000


@dataclass
class _Block:
    page: int
    y0: float
    y1: float
    text: str
    size: float  # dominant font size
    lines: int


def _norm_margin(text: str) -> str:
    return re.sub(r"\d+", "#", re.sub(r"\s+", " ", text.strip().lower()))


def _in_margin(b: _Block) -> bool:
    return b.y1 <= MARGIN_FRACTION or b.y0 >= 1 - MARGIN_FRACTION


def _head_key(text: str) -> str:
    """A running head's words, without a page number or separator at either end ("The Letter · 45")."""
    return re.sub(r"^[\W_]+|[\W_]+$", "", _norm_margin(text))


def _is_heading_block(b: _Block, body_size: float) -> bool:
    """A large-font, short block: a heading or a contents line, not a paragraph set in a larger font."""
    return b.size >= body_size * 1.2 and b.lines <= 3 and len(b.text) <= 150


def _recurs_locally(pages: list[int]) -> bool:
    """pages (ascending) holds LOCAL_MIN entries within LOCAL_WINDOW consecutive pages."""
    return any(pages[k + LOCAL_MIN - 1] - pages[k] < LOCAL_WINDOW for k in range(len(pages) - LOCAL_MIN + 1))


def _block_lines(block: dict) -> tuple[list[str], float]:
    lines_out: list[str] = []
    sizes: Counter = Counter()
    for line in block.get("lines", []):
        spans = line.get("spans", [])
        t = "".join(s.get("text", "") for s in spans)
        for s in spans:
            sizes[round(s.get("size", 0), 1)] += len(s.get("text", ""))
        if t.strip():
            lines_out.append(t.strip())
    size = sizes.most_common(1)[0][0] if sizes else 0.0
    return lines_out, size


# --------------------------------------------------------------------------- hyphenation

_WORD = re.compile(r"[^\W\d_]+(?:['’-][^\W\d_]+)*")
_HEAD_WORD = re.compile(r"([^\W\d_]+(?:['’-][^\W\d_]+)*)-$")
_HYPHEN_BREAK = re.compile(r"[^\W\d_]-$")
# French inversions and clitics written with a hyphen: dit-il, allez-vous, celui-ci...
_FR_CLITICS = {
    "il", "ils", "elle", "elles", "on", "je", "tu", "nous", "vous", "ce", "ci", "là", "la", "le", "les",
    "lui", "leur", "leurs", "moi", "toi", "eux", "en", "y", "même", "mêmes",
}
# First halves of French compounds that are not themselves word fragments: peut-être, c'est-à-dire...
# (Not "porte", "garde", "beau": porte-rait, garde-rait and beau-coup are ordinary line breaks.)
_FR_COMPOUND_HEADS = {
    "peut", "c'est", "c’est", "qu'est", "qu’est", "vis", "après", "avant", "arrière", "demi", "grand",
    "chef", "celui", "celle", "ceux", "celles", "quelques", "rendez", "vice", "sous", "saint", "sainte",
}
_EN_COMPOUND_HEADS = {
    "well", "self", "half", "ill", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
}
_EN_SUFFIXES = {"ness", "ish", "less", "ly", "er", "est", "ed", "ing", "ings", "ful", "ment", "ments"}


def _vocabulary(lines) -> Counter:
    """Word counts over the whole document, hyphenated compounds included ("peut-être")."""
    vocab: Counter = Counter()
    for ln in lines:
        vocab.update(_WORD.findall(ln.lower()))
    return vocab


def _soft_hyphen(head: str, tail: str, lang: str | None, vocab: Counter) -> bool:
    """True when a hyphen at the end of `head` only splits a word across lines.

    The book itself is the best dictionary: if the word is written elsewhere
    with (or without) the hyphen, follow that. Otherwise a one-letter piece
    ("demanda-t-il", "e-mail") means a real hyphen, and so do French clitics
    and compound heads (dit-elle, peut-être) and English compound heads.
    """
    m1, m2 = _HEAD_WORD.search(head), _WORD.match(tail)
    if not m1 or not m2:
        return True
    w1, w2 = m1.group(1).lower(), m2.group(0).lower()
    joined, hyphenated = vocab.get(w1 + w2, 0), vocab.get(f"{w1}-{w2}", 0)
    if joined != hyphenated:
        return joined > hyphenated
    last1, first2 = w1.rsplit("-", 1)[-1], w2.split("-", 1)[0]
    if len(last1) == 1 or len(first2) == 1:
        return False  # line-breaking never leaves a single letter: "demanda-t-" / "t-il", "e-" / "mail"
    if lang == "fr":
        return not (first2 in _FR_CLITICS or last1 in _FR_COMPOUND_HEADS)
    if lang == "en":
        return not (last1 in _EN_COMPOUND_HEADS and first2 not in _EN_SUFFIXES)
    return True


def _join(head: str, tail: str, lang: str | None, vocab: Counter) -> str:
    """Join text split by a line or page break, rejoining or keeping a line-end hyphen."""
    if _HYPHEN_BREAK.search(head) and tail[:1].isalpha():
        if head[-2].islower() and tail[0].isupper():
            return head + tail  # Jean-Pierre, anti-American: never a split word
        return head[:-1] + tail if _soft_hyphen(head, tail, lang, vocab) else head + tail
    return head + " " + tail


def _join_lines(lines: list[str], lang: str | None, vocab: Counter) -> str:
    text = ""
    for ln in lines:
        text = _join(text, ln, lang, vocab) if text else ln
    return re.sub(r"\s+", " ", text).strip()


# --------------------------------------------------------------------------- outline

_PART_TITLE = re.compile(r"^\s*(?:part|partie|book|livre|volume|tome)\b", re.IGNORECASE)
_SUBSECTION_TITLE = re.compile(r"^\s*\d+\.\d+")
_LABELLED_CHAPTER = re.compile(r"^\s*(?i:chapter|chapitre|ch\.)\s*(?:\d+|[IVXLCDMivxlcdm]+)\b")
# A bare number: "3", "3. The Boy", "III", "IV The Return"; not "I Am Here" (the pronoun).
_BARE_NUMBER = re.compile(r"^\s*(?:(\d{1,3})\b(?![.,]\d)|(?!I\s+[A-Za-z])([IVXLCDM]+)\b(?![.,]?\d))")
_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}
# A part's own page(s) before its first chapter hold little more than its title (and an epigraph).
PART_PAGE_MAX_CHARS = 600


def _chapter_like(title: str) -> bool:
    return bool(_LABELLED_CHAPTER.match(title) or _BARE_NUMBER.match(title))


def _bare_number(title: str) -> int | None:
    m = _BARE_NUMBER.match(title)
    if not m:
        return None
    if m.group(1):
        return int(m.group(1))
    vals = [_ROMAN[c] for c in m.group(2)]
    return sum(-v if k + 1 < len(vals) and vals[k + 1] > v else v for k, v in enumerate(vals))


def _outline_level(toc: list, page_chars: list[int] | None = None) -> int:
    """Deepest outline level whose entries are chapters.

    Starts from the first level with at least three entries, then descends
    while the entries with children are parts and their children chapters:
    parents titled Part/Book, children titled "Chapter 3", parents with a page
    of their own before their first child that holds little text (a part title
    page), or children numbered 1, 2, 3... continuing across parents. It stops
    at numbered subsections ("1.1"), under chapter-like parents (Chapter 3, 3,
    III), and at numbered scenes or tips that restart at 1 under each named
    chapter. page_chars holds the number of characters on each page (0-based).

    Known limit: named parts and named chapters are told apart only by those
    signals. Named parts that start on the same page as their first chapter
    stay whole (cut at the parts), and named chapters that open with a short
    page of their own (title and epigraph) are cut at their named subsections.
    The two outline shapes are otherwise identical, so no rule gets both right.
    """
    levels = sorted({lvl for lvl, _, _ in toc})
    use = levels[0]
    for lvl in levels[:2]:
        if sum(1 for l, _, _ in toc if l <= lvl) >= 3:
            use = lvl
            break
    while use + 1 in levels:
        children = [t for l, t, _ in toc if l == use + 1]
        groups: list[tuple[int, int, list[str]]] = []  # (parent page, first child page, child titles)
        for k, (lvl, _, page) in enumerate(toc):
            if lvl == use and k + 1 < len(toc) and toc[k + 1][0] > use:
                kids = []
                for l2, t2, _ in toc[k + 1:]:
                    if l2 <= use:
                        break
                    if l2 == use + 1:
                        kids.append(t2)
                groups.append((page, toc[k + 1][2], kids))
        parents = [t for k, (l, t, _) in enumerate(toc) if l == use and k + 1 < len(toc) and toc[k + 1][0] > use]
        if not children or not parents:
            break
        if sum(1 for c in children if _SUBSECTION_TITLE.match(c)) * 2 > len(children):
            break
        if sum(1 for p in parents if _PART_TITLE.match(p)) * 2 >= len(parents):
            use += 1  # Part One, Book II
            continue
        if sum(1 for p in parents if _chapter_like(p)) * 2 > len(parents):
            break  # Chapter 3 {sections}, 3 {sections}
        if sum(1 for c in children if _LABELLED_CHAPTER.match(c)) >= 0.6 * len(children):
            use += 1  # The Early Years {Chapter 1, Chapter 2}
            continue
        if page_chars is not None:
            part_pages = sum(
                1 for p0, c0, _ in groups
                if 1 <= p0 < c0 <= len(page_chars) and sum(page_chars[p0 - 1:c0 - 1]) <= PART_PAGE_MAX_CHARS
            )
            if part_pages * 2 >= len(groups):
                use += 1  # The Early Years (a title page) {Childhood, School}
                continue
        numbers = [[n for n in map(_bare_number, kids) if n is not None] for _, _, kids in groups]
        numbers = [ns for ns in numbers if ns]
        if sum(1 for c in children if _BARE_NUMBER.match(c)) >= 0.6 * len(children):
            if len(numbers) >= 2 and all(b[0] > a[-1] for a, b in zip(numbers, numbers[1:])):
                use += 1  # The Early Years {1, 2, 3}, The War {4, 5, 6}: chapters numbered through the book
                continue
            if len(numbers) == 1 and len(children) >= 3 and len(children) > sum(1 for l, _, _ in toc if l == use):
                use += 1  # Title, The Novel {1 .. 30}, Afterword: one parent holding the chapters
                continue
        break
    return use


def read_pdf(path: str | Path) -> Book:
    path = Path(path)
    try:
        doc = pymupdf.open(str(path))
    except Exception as exc:
        raise IngestError(f"Could not open PDF: {exc}") from exc
    if doc.needs_pass:
        raise IngestError("The PDF is password-protected.")
    if doc.page_count == 0:
        raise IngestError("The PDF has no pages.")

    warn: list[str] = []
    raw_pages: list[list[tuple[list[str], float, tuple, float]]] = []
    text_pages = 0
    for pno in range(doc.page_count):
        page = doc[pno]
        d = page.get_text("dict", sort=True)
        raw: list[tuple[list[str], float, tuple, float]] = []
        page_chars = 0
        for b in d.get("blocks", []):
            if b.get("type") != 0:
                continue
            lines, size = _block_lines(b)
            if not lines:
                continue
            page_chars += sum(len(ln) for ln in lines)
            raw.append((lines, size, b.get("bbox", (0, 0, 0, 0)), page.rect.height))
        if page_chars > 50:
            text_pages += 1
        raw_pages.append(raw)

    if text_pages < max(1, 0.2 * doc.page_count):
        raise IngestError(
            "This PDF looks scanned (little or no text layer). It needs OCR, which is not supported yet. "
            "Tip: run it through an OCR tool first, or use the EPUB edition if you have one."
        )

    # Line-end hyphens are resolved with the book's language and vocabulary.
    all_lines = [ln for raw in raw_pages for lines, _, _, _ in raw for ln in lines]
    lang_hint = detect_language(" ".join(all_lines)[:200000])
    vocab = _vocabulary(all_lines)
    pages_blocks: list[list[_Block]] = []
    for pno, raw in enumerate(raw_pages):
        blocks = []
        for lines, size, bbox, height in raw:
            text = _join_lines(lines, lang_hint, vocab)
            if text:
                blocks.append(_Block(pno, bbox[1] / height, bbox[3] / height, text, size, len(lines)))
        pages_blocks.append(blocks)

    # Running headers/footers: margin text that recurs on many pages of the book, or
    # on several nearby pages (a running head carrying the current chapter's title).
    margin_pages: dict[str, list[int]] = {}
    size_all: Counter = Counter()
    for pno, blocks in enumerate(pages_blocks):
        for t in {_norm_margin(b.text) for b in blocks if _in_margin(b)}:
            margin_pages.setdefault(t, []).append(pno)
        for b in blocks:
            size_all[b.size] += len(b.text)
    threshold = max(3, int(0.3 * doc.page_count))
    repeated = {t for t, pages in margin_pages.items() if len(pages) >= threshold}
    local = {t for t, pages in margin_pages.items() if t not in repeated and _recurs_locally(pages)}
    # A one-line margin text that is an outline title, the book title or the author is a running
    # head however few pages carry it (a short chapter's recto heads). The outline still names
    # the chapter, so nothing is lost if it was the chapter's own small-font heading.
    toc = doc.get_toc(simple=True)
    meta = doc.metadata or {}
    known_heads = {_head_key(t) for _, t, _ in toc}
    known_heads |= {_head_key(meta.get("title") or ""), _head_key(meta.get("author") or "")}
    known_heads.discard("")
    heading_size = size_all.most_common(1)[0][0] * 1.2 if size_all else float("inf")
    removed = 0
    for i, blocks in enumerate(pages_blocks):
        kept = []
        for b in blocks:
            if _in_margin(b):
                key = _norm_margin(b.text)
                # a large-font chapter heading that happens to sit high on its page is not a running head
                small = b.size < heading_size
                if (
                    key in repeated or _PAGE_NUM.match(b.text) or (key in local and small)
                    or (small and b.lines == 1 and _head_key(b.text) in known_heads)
                ):
                    removed += 1
                    continue
            kept.append(b)
        pages_blocks[i] = kept

    flat: list[_Block] = [b for blocks in pages_blocks for b in blocks]
    if not flat:
        raise IngestError("No readable text found in the PDF.")

    # Body font size = size covering the most characters.
    size_chars: Counter = Counter()
    for b in flat:
        size_chars[b.size] += len(b.text)
    body_size = size_chars.most_common(1)[0][0]

    # Merge paragraphs that continue across a page break (the first block left on the
    # page after running heads and page numbers are removed).
    merged: list[_Block] = []
    for b in flat:
        if (
            merged
            and b.page == merged[-1].page + 1
            and b is pages_blocks[b.page][0]
            and abs(b.size - merged[-1].size) < 0.6
            and not _END_PUNCT.search(merged[-1].text)
            and re.match(r"[a-zà-ÿ,;]", b.text)
        ):
            merged[-1].text = _join(merged[-1].text, b.text, lang_hint, vocab)
            continue
        merged.append(b)

    # Chapter cut points: block index -> (title, outline level).
    cut_map: dict[int, tuple[str, int]] = {}
    if toc:
        use_level = _outline_level(toc, [sum(len(b.text) for b in blocks) for blocks in pages_blocks])
        for lvl, title, page1 in toc:
            if lvl > use_level or page1 < 1:
                continue
            idx = _locate(merged, page1 - 1, title)
            if idx is None:
                continue
            title = title.strip()
            if idx in cut_map and lvl > cut_map[idx][1]:
                # a part and its first chapter start at the same place: keep both names
                title = f"{cut_map[idx][0]}: {title}"
            cut_map[idx] = (title, lvl)
        if not cut_map:
            warn.append("PDF outline entries could not be matched to the text.")
    from_outline = bool(cut_map)
    if not cut_map:
        heads = [
            i for i, b in enumerate(merged)
            if b.size >= body_size * 1.3 and len(b.text) <= 100 and b.lines <= 3
        ]
        if len(heads) >= 2:
            cut_map = {i: (merged[i].text, 0) for i in heads}
            warn.append("No PDF outline; chapters were detected from large-font headings.")
        else:
            warn.append("No PDF outline and no clear headings; the whole document is one section.")

    # Raw sections: (title, level, blocks, synthetic).
    cuts = sorted(cut_map.items())
    raws: list[dict] = []
    if not cuts or cuts[0][0] != 0:
        end = cuts[0][0] if cuts else len(merged)
        title = "Opening pages" if cuts else (doc.metadata or {}).get("title") or path.stem
        raws.append({"title": title, "level": None, "blocks": merged[:end], "synthetic": bool(cuts)})
    for n, (start, (title, lvl)) in enumerate(cuts):
        end = cuts[n + 1][0] if n + 1 < len(cuts) else len(merged)
        raws.append({"title": title, "level": lvl, "blocks": merged[start:end], "synthetic": False})

    # A part's own heading page ("Part One") is merged into its first chapter, as for EPUBs.
    joined: list[dict] = []
    for raw in raws:
        prev = joined[-1] if joined else None
        if (
            prev is not None and prev["level"] is not None and raw["level"] is not None
            and prev["level"] < raw["level"] and sum(len(b.text) for b in prev["blocks"]) < 200
        ):
            raw = {**raw, "title": f"{prev['title']}: {raw['title']}", "blocks": prev["blocks"] + raw["blocks"]}
            joined[-1] = raw
            continue
        joined.append(raw)

    sections: list[Section] = []
    for n, raw in enumerate(joined):
        blocks = raw["blocks"]
        title = raw["title"] or f"Section {n + 1}"
        sec = Section(
            index=n,
            title=title,
            kind="chapter",
            paragraphs=[b.text for b in blocks],
            starts_with_heading=bool(blocks) and (
                _is_heading_block(blocks[0], body_size) or looks_like_title(blocks[0].text, [title])
            ),
        )
        # Short large-font lines, not long paragraphs: when notes in a small font outweigh the
        # main text, the body size is the notes' and every paragraph is "large".
        heading_ratio = sum(1 for b in blocks if _is_heading_block(b, body_size)) / len(blocks) if blocks else 0.0
        classify_section(sec, heading_ratio=heading_ratio)
        if raw["synthetic"] and sec.kind == "chapter":
            signals = front_matter_signals(sec.paragraphs)
            if signals or sec.chars < OPENING_PAGES_MAX_CHARS:
                where = "outline entry" if from_outline else "detected heading"
                sec.kind, sec.include = "front", False
                sec.reasons = [f"before the first {where}" + (f" ({', '.join(signals)})" if signals else "")]
        sections.append(sec)

    title = (meta.get("title") or "").strip() or path.stem
    author = (meta.get("author") or "").strip() or "Unknown"
    sample = " ".join(b.text for b in merged)[:200000]
    detected = detect_language(sample)
    language = normalize_language(detected) or "en"
    if detected is None:
        warn.append("Language could not be determined; assuming English.")
    if removed:
        warn.append(f"Removed {removed} running header/footer/page-number lines.")
    if not any(s.include for s in sections):
        warn.append("No section was selected automatically; please choose sections manually.")

    cover = None
    try:
        page = doc[0]
        zoom = 1400 / max(page.rect.width, 1)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        cover = Cover(pix.tobytes("png"), "image/png", "rendered first page")
    except Exception as exc:  # rendering failures should not block ingest
        warn.append(f"Could not render a cover from page 1: {exc}")

    return Book(
        source_path=str(path),
        format="pdf",
        title=title,
        author=author,
        language=language,
        language_source="detected" if detected else "default",
        sections=sections,
        cover=cover,
        warnings=warn,
        metadata={"pages": doc.page_count, "outline_entries": len(toc), "body_font_size": body_size},
    )


def _locate(blocks: list[_Block], page0: int, title: str) -> int | None:
    """Index of the first block on page0 whose text starts with the title, else the page's first block."""
    want = re.sub(r"\W+", " ", title.lower()).strip()
    first_on_page = None
    for i, b in enumerate(blocks):
        if b.page < page0:
            continue
        if b.page > page0:
            break
        if first_on_page is None:
            first_on_page = i
        have = re.sub(r"\W+", " ", b.text.lower()).strip()
        if want and have and (have.startswith(want) or want.startswith(have)):
            return i
    if first_on_page is None:
        # Title page might have no text blocks; use first block after it.
        for i, b in enumerate(blocks):
            if b.page >= page0:
                return i
    return first_on_page
