"""Builders for small synthetic EPUB/PDF fixtures (deterministic, no downloads)."""

from __future__ import annotations

from pathlib import Path

import pymupdf
from ebooklib import epub

LOREM_EN = (
    "It was a bright cold day in the town and the clocks were striking thirteen. "
    "The old man walked to the window and looked at the sea, which was grey and calm. "
    "He thought of the letter that had come that morning, and of the house where he was born. "
)
LOREM_FR = (
    "Le soleil se levait sur la ville et les cloches de l'église sonnaient dans le silence. "
    "Il marchait le long du quai, pensant à la lettre qu'elle lui avait écrite pour son retour. "
    "Les enfants jouaient dans la rue et le marchand ouvrait sa boutique pour la journée. "
)


def png_bytes(w: int = 60, h: int = 90) -> bytes:
    pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, w, h), False)
    pix.set_rect(pix.irect, (200, 30, 30))
    return pix.tobytes("png")


def _base(title: str, lang: str = "en") -> epub.EpubBook:
    b = epub.EpubBook()
    b.set_identifier(f"test-{title}")
    b.set_title(title)
    b.set_language(lang)
    b.add_author("Test Author")
    return b


def _html(file_name: str, body: str, title: str = "x", lang: str = "en") -> epub.EpubHtml:
    item = epub.EpubHtml(title=title, file_name=file_name, lang=lang)
    item.content = f"<html><head><title>{title}</title></head><body>{body}</body></html>"
    return item


def _finish(b: epub.EpubBook, items, path: Path, toc) -> Path:
    for it in items:
        b.add_item(it)
    b.toc = toc
    b.add_item(epub.EpubNcx())
    b.add_item(epub.EpubNav())
    b.spine = ["nav", *items]
    epub.write_epub(str(path), b)
    return path


def epub_anchors(path: Path) -> Path:
    """Three chapters inside ONE xhtml file, plus copyright page, footnote and table."""
    b = _base("Anchored Book")
    b.set_cover("cover.png", png_bytes(), create_page=False)
    copyright_page = _html(
        "copyright.xhtml",
        '<section epub:type="copyright-page"><p>Copyright © 2020 Test Author. All rights reserved.</p>'
        "<p>ISBN 978-0-00-000000-0</p></section>",
        "Copyright",
    )
    body = ""
    for n in (1, 2, 3):
        body += f'<h2 id="ch{n}">Chapter {n}</h2>'
        body += f"<p>{LOREM_EN}<sup><a href='#fn{n}' epub:type='noteref'>{n}</a></sup> Second sentence here.</p>"
        body += f"<p>{LOREM_EN}</p>"
        if n == 2:
            body += "<table><tr><td>TABLECELL should not be read</td></tr></table>"
    body += '<aside epub:type="footnote" id="fn1"><p>FOOTNOTE TEXT should not be read.</p></aside>'
    text = _html("text.xhtml", body, "Text")
    toc = [
        epub.Link("copyright.xhtml", "Copyright", "c"),
        epub.Link("text.xhtml#ch1", "Chapter One", "ch1"),
        epub.Link("text.xhtml#ch2", "Chapter Two", "ch2"),
        epub.Link("text.xhtml#ch3", "Chapter Three", "ch3"),
    ]
    return _finish(b, [copyright_page, text], path, toc)


def epub_split(path: Path) -> Path:
    """Chapter 1 spans two files; the TOC only points at the first one."""
    b = _base("Split Book")
    a = _html("ch1a.xhtml", f"<h1>The Beginning</h1><p>{LOREM_EN}</p>", "1a")
    a2 = _html("ch1b.xhtml", f"<p>CONTINUED part of chapter one. {LOREM_EN}</p>", "1b")
    c2 = _html("ch2.xhtml", f"<h1>The Middle</h1><p>{LOREM_EN}</p>", "2")
    toc = [epub.Link("ch1a.xhtml", "The Beginning", "1"), epub.Link("ch2.xhtml", "The Middle", "2")]
    return _finish(b, [a, a2, c2], path, toc)


def epub_nested(path: Path) -> Path:
    """Part pages containing only a heading, with chapters nested under them."""
    b = _base("Nested Book")
    p1 = _html("part1.xhtml", "<h1>Part One</h1>", "Part One")
    c1 = _html("c1.xhtml", f"<h2>Chapter 1</h2><p>{LOREM_EN}</p>", "c1")
    c2 = _html("c2.xhtml", f"<h2>Chapter 2</h2><p>{LOREM_EN}</p>", "c2")
    toc = [(epub.Section("Part One", "part1.xhtml"), [epub.Link("c1.xhtml", "Chapter 1", "c1"), epub.Link("c2.xhtml", "Chapter 2", "c2")])]
    return _finish(b, [p1, c1, c2], path, toc)


def epub_notoc(path: Path) -> Path:
    b = _base("No TOC Book")
    c1 = _html("a.xhtml", f"<h1>Alpha</h1><p>{LOREM_EN}</p>", "a")
    c2 = _html("b.xhtml", f"<h1>Beta</h1><p>{LOREM_EN}</p>", "b")
    return _finish(b, [c1, c2], path, [])


def epub_french(path: Path) -> Path:
    b = _base("Livre Français", lang="fr")
    c1 = _html("c1.xhtml", f"<h1>Chapitre premier</h1><p>{LOREM_FR * 3}</p>", "c1", "fr")
    c2 = _html("c2.xhtml", "<h1>Table des matières</h1><p>Chapitre premier ..... 1</p>", "toc", "fr")
    toc = [epub.Link("c2.xhtml", "Table des matières", "t"), epub.Link("c1.xhtml", "Chapitre premier", "c1")]
    return _finish(b, [c2, c1], path, toc)


def _textbox(page, rect, text, size):
    rc = page.insert_textbox(rect, text, fontsize=size, fontname="helv")
    assert rc >= 0, f"text did not fit ({rc})"


def pdf_with_outline(path: Path) -> Path:
    doc = pymupdf.open()
    w, h = 595, 842
    titles = ["Chapter One", "Chapter Two"]
    for n in range(6):
        page = doc.new_page(width=w, height=h)
        page.insert_text((60, 30), "Running Header Of The Book", fontsize=9)
        page.insert_text((290, 825), str(n + 1), fontsize=9)
        y = 90
        if n in (0, 3):
            t = titles[0 if n == 0 else 1]
            page.insert_text((60, y), t, fontsize=24)
            y += 40
        body = LOREM_EN * 2
        if n == 1:
            body = "An exam-\nple of a hyphenated line break. " + body + "This sentence continues on the next"
        if n == 2:
            body = "page, as the reader can see. " + body
        _textbox(page, pymupdf.Rect(60, y, w - 60, y + 400), body, 11)
    doc.set_toc([[1, "Chapter One", 1], [1, "Chapter Two", 4]])
    doc.set_metadata({"title": "Outline PDF", "author": "PDF Author"})
    doc.save(str(path))
    return path


def pdf_no_outline(path: Path) -> Path:
    doc = pymupdf.open()
    for n, t in enumerate(["First Heading", "Second Heading"]):
        page = doc.new_page()
        page.insert_text((60, 90), t, fontsize=22)
        _textbox(page, pymupdf.Rect(60, 120, 535, 600), LOREM_EN * 3, 11)
    doc.save(str(path))
    return path


def pdf_scanned(path: Path) -> Path:
    doc = pymupdf.open()
    for _ in range(3):
        page = doc.new_page()
        page.insert_image(pymupdf.Rect(50, 50, 500, 750), stream=png_bytes(400, 600))
    doc.save(str(path))
    return path


def epub_gutenberg_like(path: Path, drop_from_toc: int | None = 4, caption_titles: bool = False) -> Path:
    """Mimics Project Gutenberg EPUB3 quirks seen in real books."""
    b = _base("Gutenberg Like")
    head = (
        "<p>The Project Gutenberg eBook of Gutenberg Like. This eBook is for the use of anyone "
        "anywhere at no cost. www.gutenberg.org</p>"
        "<div><span>*** START OF THE PROJECT GUTENBERG EBOOK GUTENBERG LIKE ***</span></div>"
        "<p>Produced by volunteers</p><h5>GUTENBERG LIKE</h5><p>Table of Contents</p>"
        + "".join(f"<h5>{r} A CHAPTER TITLE</h5>" for r in ["I", "II", "III", "IV", "V", "VI"])
    )
    romans = ["I", "II", "III", "IV", "V", "VI"]
    body = ""
    for n, r in enumerate(romans, start=1):
        tag = "h5" if n == drop_from_toc else "h2"  # source typo: one chapter heading is h5
        body += (
            f'<p><span class="x-ebookmaker-pageno" title="{{{n}}}"><a id="page_{n}"/></span></p>'
            f'<{tag} id="ch{n}"><img alt="" src="x.png"/><span class="caption">A caption {n}.</span>'
            f"<br/>CHAPTER {r}.</{tag}>"
            f'<p><span class="letra"><img alt="W" src="w.png"/></span>HEN chapter {n} begins. '
            f"<span class=\"pagenum\">[Pg {n}]</span>{LOREM_EN * 2}</p>"
        )
    tail = (
        "<p>End of Project Gutenberg's Gutenberg Like, by Test Author</p>"
        "<div><span>*** END OF THE PROJECT GUTENBERG EBOOK GUTENBERG LIKE ***</span></div>"
        "<p>Updated editions will replace the previous one. Project Gutenberg license text.</p>"
    )
    f0 = _html("g0.xhtml", head + body[: body.index('<p><span class="x-ebookmaker-pageno" title="{4}')], "g0")
    f1 = _html("g1.xhtml", body[body.index('<p><span class="x-ebookmaker-pageno" title="{4}'):] + tail, "g1")
    toc = []
    for n, r in enumerate(romans, start=1):
        if n == drop_from_toc:
            continue
        fn = "g0.xhtml" if n < 4 else "g1.xhtml"
        title = f"A caption {n}. CHAPTER {r}." if (caption_titles and n == 4) else f"CHAPTER {r}."
        toc.append(epub.Link(f"{fn}#ch{n}", title, f"c{n}"))
    toc.insert(0, epub.Link("g0.xhtml#printed", "Contents", "pc"))  # dangling anchor on purpose
    return _finish(b, [f0, f1], path, toc)


def epub_short_poems(path: Path) -> Path:
    b = _base("Short Poems")
    items = [_html(f"p{n}.xhtml", f"<h2>Poem {n}</h2><p>Roses are red and the sky is wide, poem number {n}.</p>", f"p{n}")
             for n in range(1, 6)]
    toc = [epub.Link(f"p{n}.xhtml", f"Poem {n}", f"p{n}") for n in range(1, 6)]
    return _finish(b, items, path, toc)


# --- Fixtures for code-review regressions (ingest) -----------------------------

def epub_typed_matter(path: Path) -> Path:
    """Typed containers inside chapter files: endnotes in a chapter, a dedication before
    a chapter in the same file, and acknowledgments the TOC does not list."""
    b = _base("Typed Matter")
    c1 = _html(
        "c1.xhtml",
        f'<section epub:type="bodymatter chapter"><h1>Chapter 12</h1><p>{LOREM_EN}</p>'
        '<section role="doc-endnotes"><h2>Notes</h2><ol><li><p>A note about the chapter, ENDNOTE TEXT.</p></li></ol>'
        "</section></section>",
        "c1",
    )
    c2 = _html(
        "c2.xhtml",
        '<section epub:type="dedication"><p>For my mother.</p></section>'
        f'<section epub:type="chapter"><h1>Chapter 13</h1><p>{LOREM_EN}</p></section>',
        "c2",
    )
    ack = _html(
        "ack.xhtml",
        '<section epub:type="acknowledgments"><h1>Thanks</h1><p>ACK TEXT: thanks to everyone who helped.</p></section>',
        "ack",
    )
    toc = [epub.Link("c1.xhtml", "Chapter 12", "c1"), epub.Link("c2.xhtml", "Chapter 13", "c2")]
    return _finish(b, [c1, c2, ack], path, toc)


def epub_language(path: Path, lang: str, french: bool = False) -> Path:
    b = _base("Language Book", lang=lang)
    text = LOREM_FR if french else LOREM_EN
    c1 = _html("c1.xhtml", f"<h1>One</h1><p>{text * 3}</p>", "c1")
    return _finish(b, [c1], path, [epub.Link("c1.xhtml", "One", "c1")])


def epub_styled_titles(path: Path) -> Path:
    """Chapter titles styled as <p>/<div> instead of <h1>-<h6> (InDesign, Calibre)."""
    b = _base("Styled Titles")
    c1 = _html("c1.xhtml", f'<p class="chapter-title">CHAPTER ONE</p><p>{LOREM_EN}</p>', "c1")
    c2 = _html("c2.xhtml", f'<div class="calibre7">Chapter Two</div><p>{LOREM_EN}</p>', "c2")
    c3 = _html("c3.xhtml", f'<p class="calibre3">Origins</p><p>{LOREM_EN}</p>', "c3")
    c4 = _html("c4.xhtml", f"<p>It was a dark night and the rain fell.</p><p>{LOREM_EN}</p>", "c4")
    toc = [epub.Link("c1.xhtml", "Chapter One", "c1"), epub.Link("c2.xhtml", "Chapter Two", "c2"),
           epub.Link("c3.xhtml", "3. Origins", "c3"), epub.Link("c4.xhtml", "Chapter Four", "c4")]
    return _finish(b, [c1, c2, c3, c4], path, toc)


def epub_note_markers(path: Path) -> Path:
    """Numeric cross-references, exponents and content classes next to real note calls."""
    b = _base("Note Markers")
    c1 = _html(
        "c1.xhtml",
        '<h2 id="ch1">Chapter 1</h2>'
        '<p>As we saw in Chapter <a href="c2.xhtml#ch2">2</a>, the speed is 10 m/s<sup>2</sup> here.</p>'
        '<p class="pagebreak-before">KEEP THIS PARAGRAPH about the sea.</p>'
        '<div class="captioned-image"><p>KEEP CAPTIONED TEXT.</p></div>'
        '<p>An untyped endnote call<a id="r1" href="notes.xhtml#n1">1</a> and a footnote call<a href="#fn2">2</a>'
        " and a star<sup>*</sup> end.</p>"
        '<p>A numbered note<a href="notes.xhtml#n5">5</a>, a citation<a href="#nowhere">[6]</a>, and see page'
        ' <a href="#p12">12</a> for more.</p>'
        '<aside epub:type="footnote" id="fn2"><p>FOOTNOTE TWO.</p></aside>'
        f'<p>{LOREM_EN}<span class="pagenum" id="p12">12</span></p>',
        "c1",
    )
    c2 = _html("c2.xhtml", f'<h2 id="ch2"><a href="contents.xhtml#c2">II</a></h2><p>{LOREM_EN}</p>', "c2")
    notes = _html("notes.xhtml", '<h1>Notes</h1><p id="n1"><a href="c1.xhtml#r1">1</a>. NOTE ONE TEXT.</p>'
                  '<p id="n5">5. NOTE FIVE, without a link back.</p>', "notes")
    toc = [epub.Link("c1.xhtml#ch1", "Chapter 1", "c1"), epub.Link("c2.xhtml#ch2", "Chapter 2", "c2"),
           epub.Link("notes.xhtml", "Notes", "n")]
    return _finish(b, [c1, c2, notes], path, toc)


def epub_title_page_before_toc(path: Path) -> Path:
    """A heading-only title page that the TOC does not list, before chapter one."""
    b = _base("Title Page Book")
    tp = _html("title.xhtml", "<h1>The Book</h1><h2>A Novel</h2><h3>Jane Doe</h3>", "title")
    c1 = _html("c1.xhtml", f"<h2>Chapter One</h2><p>{LOREM_EN}</p>", "c1")
    c2 = _html("c2.xhtml", f"<h2>Chapter Two</h2><p>{LOREM_EN}</p>", "c2")
    toc = [epub.Link("c1.xhtml", "Chapter One", "c1"), epub.Link("c2.xhtml", "Chapter Two", "c2")]
    return _finish(b, [tp, c1, c2], path, toc)


def epub_title_page_then_dedication(path: Path) -> Path:
    """A TOC-listed heading-only title page followed by an untyped dedication."""
    b = _base("Dedication Book")
    tp = _html("tp.xhtml", "<h1>The Book</h1>", "tp")
    ded = _html("ded.xhtml", "<p>For my mother, who read to me.</p>", "ded")
    c1 = _html("c1.xhtml", f"<h2>Chapter One</h2><p>{LOREM_EN}</p>", "c1")
    toc = [epub.Link("tp.xhtml", "Title Page", "tp"), epub.Link("ded.xhtml", "Dedication", "ded"),
           epub.Link("c1.xhtml", "Chapter One", "c1")]
    return _finish(b, [tp, ded, c1], path, toc)


def epub_anchor_variants(path: Path) -> Path:
    """TOC anchors on an <a> inside a <span>, on a skipped <img>, and as a legacy a@name."""
    b = _base("Anchor Variants")
    body = (
        "<div>"
        f"<h2>Chapter One</h2><p>{LOREM_EN} ONE.</p>"
        f'<span><a id="ch2"></a>Chapter Two begins here.</span><p>{LOREM_EN} TWO.</p>'
        f'<img id="ch3" src="x.png" alt=""/><h2>Chapter Three</h2><p>{LOREM_EN} THREE.</p>'
        f'<p><a name="ch4"></a>Chapter Four opens.</p><p>{LOREM_EN} FOUR.</p>'
        "</div>"
    )
    text = _html("text.xhtml", body, "text")
    toc = [epub.Link("text.xhtml", "Chapter One", "c1"), epub.Link("text.xhtml#ch2", "Chapter Two", "c2"),
           epub.Link("text.xhtml#ch3", "Chapter Three", "c3"), epub.Link("text.xhtml#ch4", "Chapter Four", "c4")]
    return _finish(b, [text], path, toc)


def epub_shared_parent_target(path: Path) -> Path:
    """A part entry whose target is its first chapter's file."""
    b = _base("Shared Target")
    c1 = _html("c1.xhtml", f"<h2>Chapter 1: Origins</h2><p>{LOREM_EN}</p>", "c1")
    c2 = _html("c2.xhtml", f"<h2>Chapter 2: Growth</h2><p>{LOREM_EN}</p>", "c2")
    toc = [(epub.Section("Part I: Foundations", "c1.xhtml"),
            [epub.Link("c1.xhtml", "Chapter 1: Origins", "c1"), epub.Link("c2.xhtml", "Chapter 2: Growth", "c2")])]
    return _finish(b, [c1, c2], path, toc)


def epub_html_spine(path: Path) -> Path:
    """A spine document declared text/html, and a spine item that is not a text document."""
    b = _base("Html Spine")
    c1 = _html("c1.xhtml", f"<h1>First</h1><p>{LOREM_EN}</p>", "c1")
    c2 = epub.EpubItem(
        uid="c2", file_name="c2.html", media_type="text/html",
        content=f"<html><head><title>c2</title></head><body><h1>Second</h1><p>SECOND CHAPTER TEXT. {LOREM_EN}<br>"
                "more text</p></body></html>".encode(),
    )
    c3 = epub.EpubItem(uid="c3", file_name="c3.dtb", media_type="application/x-dtbook+xml", content=b"<dtbook/>")
    toc = [epub.Link("c1.xhtml", "First", "c1"), epub.Link("c2.html", "Second", "c2")]
    return _finish(b, [c1, c2, c3], path, toc)


def epub_stub_ncx(path: Path) -> Path:
    """A complete EPUB 3 nav, but an NCX holding a single entry (the NCX wins in ebooklib)."""
    import zipfile

    b = _base("Stub NCX")
    items = [_html(f"c{n}.xhtml", f"<h2>Chapter {n}</h2><p>{LOREM_EN}</p>", f"c{n}") for n in (1, 2, 3)]
    toc = [epub.Link(f"c{n}.xhtml", f"Chapter {n}", f"c{n}") for n in (1, 2, 3)]
    tmp = path.with_suffix(".tmp.epub")
    _finish(b, items, tmp, toc)
    stub = (
        "<?xml version='1.0' encoding='utf-8'?>\n"
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<head><meta name="dtb:uid" content="test-Stub NCX"/></head><docTitle><text>Stub NCX</text></docTitle>'
        '<navMap><navPoint id="np1"><navLabel><text>Start</text></navLabel><content src="c1.xhtml"/></navPoint>'
        "</navMap></ncx>"
    )
    with zipfile.ZipFile(tmp) as src, zipfile.ZipFile(path, "w") as dst:
        for info in src.infolist():
            data = stub.encode() if info.filename.endswith(".ncx") else src.read(info.filename)
            dst.writestr(info, data)
    tmp.unlink()
    return path


def pdf_running_heads(path: Path) -> Path:
    """24 pages, 4 chapters; recto heads carry the chapter title, verso heads the book title.

    The chapter heads appear on 3 pages each, far below the 30%-of-pages threshold.
    """
    doc = pymupdf.open()
    w, h = 595, 842
    titles = ["Chapter One", "Chapter Two", "Chapter Three", "Chapter Four"]
    for n in range(24):
        ch, off = divmod(n, 6)
        page = doc.new_page(width=w, height=h)
        if off:
            head = titles[ch] if off % 2 else "The Book Title"
            page.insert_text((60, 30), head, fontsize=9)
        page.insert_text((290, 825), str(n + 1), fontsize=9)
        y = 90
        if off == 0:
            page.insert_text((60, y), titles[ch], fontsize=24)
            y += 40
        body = LOREM_EN * 2
        if ch == 1 and off == 2:
            body = body + "This sentence continues on the next"
        if ch == 1 and off == 3:
            body = "page, as the reader can see. " + body
        _textbox(page, pymupdf.Rect(60, y, w - 60, y + 400), body, 11)
    doc.set_toc([[1, t, 1 + 6 * k] for k, t in enumerate(titles)])
    doc.save(str(path))
    return path


def _pdf_from_pages(path: Path, pages: list[tuple[str | None, str]], toc: list, body_size: float = 11) -> Path:
    doc = pymupdf.open()
    w, h = 595, 842
    for heading, body in pages:
        page = doc.new_page(width=w, height=h)
        y = 90
        if heading:
            page.insert_text((60, y), heading, fontsize=22)
            y += 40
        if body:
            _textbox(page, pymupdf.Rect(60, y, w - 60, h - 80), body, body_size)
    doc.set_toc(toc)
    doc.save(str(path))
    return path


def pdf_parts(path: Path) -> Path:
    """Outline with parts at level 1 and chapters at level 2, plus front/back matter."""
    pages = [
        (None, "The Book\nby Some Author"),
        ("Contents", "Part One\nChapter 1\nChapter 2\nPart Two\nChapter 3"),
        ("Part One", ""),
        ("Chapter 1", LOREM_EN * 2),
        ("Chapter 2", LOREM_EN * 2),
        ("Part Two", ""),
        ("Chapter 3", LOREM_EN * 2),
        ("Acknowledgments", "Thanks to my editor."),
    ]
    toc = [[1, "Title Page", 1], [1, "Contents", 2], [1, "Part One", 3], [2, "Chapter 1", 4], [2, "Chapter 2", 5],
           [1, "Part Two", 6], [2, "Chapter 3", 7], [1, "Acknowledgments", 8]]
    return _pdf_from_pages(path, pages, toc)


def pdf_subsections(path: Path) -> Path:
    """Outline with chapters at level 1 and numbered subsections at level 2."""
    pages = [("1 Introduction", LOREM_EN * 2), ("1.2 Scope", LOREM_EN * 2), ("2 Methods", LOREM_EN * 2),
             ("3 Results", LOREM_EN * 2)]
    toc = [[1, "1 Introduction", 1], [2, "1.1 Background", 1], [2, "1.2 Scope", 2], [1, "2 Methods", 3],
           [2, "2.1 Data", 3], [1, "3 Results", 4]]
    return _pdf_from_pages(path, pages, toc)


def pdf_french_hyphens(path: Path) -> Path:
    """French text whose line breaks fall on real hyphens (inversions, compounds) and on a soft one."""
    lines = (
        "« Viendra-t-il demain ? » demanda-\n"
        "t-il. C'est peut-\n"
        "être vrai, dit-\n"
        "elle. Voici un exem-\n"
        "ple de mot coupé.\n"
    )
    pages = [("Chapitre un", lines + LOREM_FR * 2)]
    return _pdf_from_pages(path, pages, [[1, "Chapitre un", 1]])


def pdf_opening_pages(path: Path, opening: str, heading: str | None = None) -> Path:
    """`opening` text (under an optional large heading) on page 1, before the first outline entry (page 2)."""
    pages = [(heading, opening), ("Chapter One", LOREM_EN * 3), ("Chapter Two", LOREM_EN * 3)]
    return _pdf_from_pages(path, pages, [[1, "Chapter One", 2], [1, "Chapter Two", 3]], body_size=7)


def pdf_heading_list(path: Path) -> Path:
    """An outline entry whose page is a list of large-font lines (a printed contents)."""
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    for k in range(6):
        page.insert_text((60, 120 + 70 * k), f"Part {k + 1} of the story", fontsize=20)
    for t in ("Chapter One", "Chapter Two"):
        page = doc.new_page(width=595, height=842)
        page.insert_text((60, 90), t, fontsize=22)
        _textbox(page, pymupdf.Rect(60, 130, 535, 700), LOREM_EN * 3, 11)
    doc.set_toc([[1, "Overview", 1], [1, "Chapter One", 2], [1, "Chapter Two", 3]])
    doc.save(str(path))
    return path


# --- Fixtures for round-2 regressions (ingest) ---------------------------------

LOREM_DE = (
    "Es war ein heller, kalter Tag in der Stadt, und die Uhren schlugen dreizehn. Der alte Mann ging zum Fenster "
    "und sah auf das Meer, das grau und ruhig war. Er dachte an den Brief, der an diesem Morgen gekommen war, und an "
    "das Haus, in dem er geboren wurde. Was er in diesem Moment fühlte, wusste er nicht. In der Ferne sah er ein Schiff. "
)
LOREM_ES = (
    "Era un día frío y brillante en la ciudad y los relojes daban las trece. El viejo caminó hacia la ventana y miró "
    "el mar, que estaba gris y tranquilo. Pensó en la carta que había llegado esa mañana y en la casa donde nació. "
)
LOREM_NL = (
    "Het was een heldere, koude dag in de stad en de klokken sloegen dertien. De oude man liep naar het raam en keek "
    "naar de zee, die grijs en kalm was. Hij dacht aan de brief die die ochtend was gekomen. "
)
LOREM_IT = (
    "Era una giornata fredda e luminosa in città e gli orologi battevano le tredici. Il vecchio andò alla finestra e "
    "guardò il mare, che era grigio e calmo. Pensò alla lettera che era arrivata quella mattina e alla casa dove era nato. "
)
LOREM_PT = (
    "Era um dia frio e claro na cidade e os relógios batiam treze horas. O velho foi até a janela e olhou para o mar, "
    "que estava cinzento e calmo. Ele pensou na carta que tinha chegado naquela manhã e na casa onde nasceu. "
    "Não sabia o que sentia, mas era muito estranho para ele. "
)


def epub_text_language(path: Path, lang: str, text: str) -> Path:
    """One chapter of `text` with the given dc:language."""
    b = _base("Language Book", lang=lang)
    c1 = _html("c1.xhtml", f"<h1>Eins</h1><p>{text * 5}</p>", "c1")
    return _finish(b, [c1], path, [epub.Link("c1.xhtml", "Eins", "c1")])


def epub_heading_notes(path: Path) -> Path:
    """Note calls on chapter headings (Calibre-style back-linked, unlinked <sup>) next to
    heading links that go back to a printed contents page."""
    b = _base("Heading Notes")
    c1 = _html("c1.xhtml", f'<h2>Chapter 1<a id="r1" href="notes.xhtml#n1">1</a></h2><p>{LOREM_EN}</p>', "c1")
    c2 = _html("c2.xhtml", f'<h2>Introduction<a id="r2" class="calibre5" href="notes.xhtml#n2">2</a></h2><p>{LOREM_EN}</p>',
               "c2")
    c3 = _html("c3.xhtml", f'<h2><a id="ch3" href="contents.xhtml#c3">III</a> The Return</h2><p>{LOREM_EN}</p>', "c3")
    c4 = _html("c4.xhtml", f"<h2>Prologue<sup>3</sup></h2><p>{LOREM_EN}</p>", "c4")
    c5 = _html("c5.xhtml", f"<h2>Why E = mc<sup>2</sup></h2><p>{LOREM_EN}</p>", "c5")
    c6 = _html("c6.xhtml", f'<h2><a id="x6" href="contents.xhtml#c6">4</a> The Beginning</h2><p>{LOREM_EN}</p>', "c6")
    contents = _html("contents.xhtml", '<h1>Contents</h1><p id="c3"><a href="c3.xhtml#ch3">III</a></p>'
                     '<p id="c6"><a href="c6.xhtml#x6">4</a></p>', "contents")
    notes = _html("notes.xhtml", '<h1>Notes</h1><p id="n1"><a href="c1.xhtml#r1">1</a>. First published 1990.</p>'
                  '<p id="n2"><a href="c2.xhtml#r2">2</a>. A talk given in 1991.</p>', "notes")
    toc = [epub.Link("contents.xhtml", "Contents", "t"), epub.Link("c1.xhtml", "Chapter 1", "c1"),
           epub.Link("c2.xhtml", "Introduction", "c2"), epub.Link("c3.xhtml#ch3", "III The Return", "c3"),
           epub.Link("c4.xhtml", "Prologue", "c4"), epub.Link("c5.xhtml", "Why E = mc2", "c5"),
           epub.Link("c6.xhtml", "The Beginning", "c6"), epub.Link("notes.xhtml", "Notes", "n")]
    return _finish(b, [contents, c1, c2, c3, c4, c5, c6, notes], path, toc)


def epub_note_bodies(path: Path) -> Path:
    """Footnote/caption classes glued to other words, an unlinked note call after a full stop,
    an exponent, and an untyped (Kindle-style) note body in the chapter's own file."""
    b = _base("Note Bodies")
    c1 = _html(
        "c1.xhtml",
        "<h2>Chapter One</h2>"
        "<p>He was born.<sup>1</sup> Second sentence here, at 10<sup>6</sup> volts.</p>"
        f"<p>{LOREM_EN}</p>"
        '<p class="MsoFootnoteText">WORD FOOTNOTE BODY.</p>'
        '<p class="footnotetext">TEX FOOTNOTE BODY.</p>'
        '<p class="footnoteText">CAMEL FOOTNOTE BODY.</p>'
        '<p class="captiontext">CAPTIONTEXT BODY.</p>'
        '<div class="captioned-image"><p>KEEP CAPTIONED TEXT.</p></div>'
        '<p>Kindle call<a id="filepos1" href="#filepos9">3</a> here.</p>'
        f"<p>{LOREM_EN}</p>"
        '<p id="filepos9"><a href="#filepos1">3</a> KINDLE NOTE BODY.</p>',
        "c1",
    )
    toc = [epub.Link("c1.xhtml", "Chapter One", "c1")]
    return _finish(b, [c1], path, toc)


def epub_inline_matter(path: Path, case: str) -> Path:
    """Typed front/back-matter containers that do not start a TOC entry's text.

    "glossary": a glossary list in the middle of chapter one.
    "copyright": a copyright section, then chapter one's untitled text, under one TOC entry.
    "dedication": a dedication, then a chapter whose heading differs from its TOC title.
    """
    b = _base("Inline Matter")
    toc_title = "Chapter One"
    if case == "glossary":
        body = (f'<section epub:type="chapter"><h2>Chapter One</h2><p>{LOREM_EN}</p>'
                '<dl epub:type="glossary"><dt>Term</dt><dd>GLOSSARY DEF.</dd></dl>'
                f"<p>REST OF CHAPTER ONE. {LOREM_EN}</p></section>")
    elif case == "copyright":
        body = ('<section epub:type="copyright-page"><p>Copyright 2020. All rights reserved.</p></section>'
                f"<p>FIRST CHAPTER TEXT. {LOREM_EN}</p>")
    else:
        body = ('<section epub:type="dedication"><p>For my mother.</p></section>'
                f'<section epub:type="chapter"><h1>Chapter Thirteen</h1><p>{LOREM_EN}</p></section>')
        toc_title = "13. The Return"
    c1 = _html("c1.xhtml", body, "c1")
    c2 = _html("c2.xhtml", f"<h2>Chapter Two</h2><p>{LOREM_EN}</p>", "c2")
    toc = [epub.Link("c1.xhtml", toc_title, "c1"), epub.Link("c2.xhtml", "Chapter Two", "c2")]
    return _finish(b, [c1, c2], path, toc)


def epub_notes_then_untitled_chapter(path: Path) -> Path:
    """Chapter 5's endnotes, then chapter 6 in the same file, which the TOC leaves out."""
    b = _base("Missing Chapter")
    c5 = _html("c5.xhtml", f"<h2>Chapter 5</h2><p>{LOREM_EN}</p>"
               '<section epub:type="endnotes"><ol><li><p>ENDNOTE FIVE.</p></li></ol></section>'
               f"<h2>Chapter 6</h2><p>SIXTH CHAPTER. {LOREM_EN}</p>", "c5")
    c7 = _html("c7.xhtml", f"<h2>Chapter 7</h2><p>{LOREM_EN}</p>", "c7")
    toc = [epub.Link("c5.xhtml", "Chapter 5", "c5"), epub.Link("c7.xhtml", "Chapter 7", "c7")]
    return _finish(b, [c5, c7], path, toc)


def epub_title_page_no_toc(path: Path) -> Path:
    """No table of contents; a heading-only title page file before chapter one."""
    b = _base("No TOC Title Page")
    tp = _html("t.xhtml", "<h1>The Book</h1><h2>A Novel</h2><h3>Jane Doe</h3>", "t")
    c1 = _html("c1.xhtml", f"<h2>Chapter One</h2><p>{LOREM_EN}</p>", "c1")
    c2 = _html("c2.xhtml", f"<h2>Chapter Two</h2><p>{LOREM_EN}</p>", "c2")
    return _finish(b, [tp, c1, c2], path, [])


def epub_legacy_html(path: Path) -> Path:
    """A text/html spine document in windows-1252 that declares its charset in a <meta>."""
    b = _base("Legacy Html")
    c1 = _html("c1.xhtml", f"<h1>First</h1><p>{LOREM_EN}</p>", "c1")
    html_doc = (
        '<html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252">'
        "<title>c2</title></head><body><h1>Second</h1>"
        f"<p>Café ‘quoted’ naïve. {LOREM_EN}</p></body></html>"
    )
    c2 = epub.EpubItem(uid="c2", file_name="c2.html", media_type="text/html", content=html_doc.encode("cp1252"))
    toc = [epub.Link("c1.xhtml", "First", "c1"), epub.Link("c2.html", "Second", "c2")]
    return _finish(b, [c1, c2], path, toc)


def epub_empty_document(path: Path) -> Path:
    """An empty (zero-byte) document in the reading order between two chapters."""
    b = _base("Empty Document")
    c1 = _html("c1.xhtml", f"<h1>One</h1><p>{LOREM_EN}</p>", "c1")
    c2 = epub.EpubItem(uid="c2", file_name="c2.xhtml", media_type="application/xhtml+xml", content=b"")
    c3 = _html("c3.xhtml", f"<h1>Three</h1><p>{LOREM_EN}</p>", "c3")
    return _finish(b, [c1, c2, c3], path, [epub.Link("c1.xhtml", "One", "1"), epub.Link("c3.xhtml", "Three", "3")])


def epub_deep_nav(path: Path) -> Path:
    """A complete NCX listing chapters; the EPUB 3 nav also lists each chapter's subsections."""
    import zipfile

    b = _base("Deep Nav")
    items = [_html(f"c{n}.xhtml", f'<h2>Chapter {n}</h2><p>{LOREM_EN}</p><h3 id="s{n}a">Section {n}.1</h3>'
                   f'<p>{LOREM_EN}</p><h3 id="s{n}b">Section {n}.2</h3><p>{LOREM_EN}</p>', f"c{n}") for n in (1, 2)]
    toc = [(epub.Section(f"Chapter {n}", f"c{n}.xhtml"),
            [epub.Link(f"c{n}.xhtml#s{n}a", f"Section {n}.1", f"s{n}a"),
             epub.Link(f"c{n}.xhtml#s{n}b", f"Section {n}.2", f"s{n}b")]) for n in (1, 2)]
    tmp = path.with_suffix(".tmp.epub")
    _finish(b, items, tmp, toc)
    ncx = (
        "<?xml version='1.0' encoding='utf-8'?>\n"
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<head><meta name="dtb:uid" content="test-Deep Nav"/></head><docTitle><text>Deep Nav</text></docTitle><navMap>'
        + "".join(f'<navPoint id="np{n}"><navLabel><text>Chapter {n}</text></navLabel><content src="c{n}.xhtml"/>'
                  "</navPoint>" for n in (1, 2))
        + "</navMap></ncx>"
    )
    with zipfile.ZipFile(tmp) as src, zipfile.ZipFile(path, "w") as dst:
        for info in src.infolist():
            dst.writestr(info, ncx.encode() if info.filename.endswith(".ncx") else src.read(info.filename))
    tmp.unlink()
    return path


def epub_quoted_drop_cap(path: Path) -> Path:
    """A decorative first-letter image whose alt text carries the opening quote (Gutenberg)."""
    b = _base("Drop Cap")
    c1 = _html("c1.xhtml", '<h2>Chapter XIII</h2><p><img alt="“I" src="i.png"/> hope, my dear,” said Mr. Bennet. '
               f"{LOREM_EN}</p>", "c1")
    return _finish(b, [c1], path, [epub.Link("c1.xhtml", "Chapter XIII", "c1")])


def pdf_notes_heavy(path: Path) -> Path:
    """Three chapters of 11pt paragraphs, then a longer 7pt notes section (so 7pt is the commonest size)."""
    doc = pymupdf.open()
    w, h = 595, 842
    toc = []
    for t in ("Chapter One", "Chapter Two", "Chapter Three"):
        page = doc.new_page(width=w, height=h)
        page.insert_text((60, 90), t, fontsize=22)
        y = 130
        for _ in range(6):
            _textbox(page, pymupdf.Rect(60, y, w - 60, y + 100), LOREM_EN, 11)
            y += 105
        toc.append([1, t, len(doc)])
    start = len(doc) + 1
    for n in range(6):
        page = doc.new_page(width=w, height=h)
        _textbox(page, pymupdf.Rect(60, 60, w - 60, h - 60), (f"{n}. Smith, op. cit., p. 12. " + LOREM_EN) * 9, 7)
    toc.append([1, "Notes", start])
    doc.set_toc(toc)
    doc.save(str(path))
    return path


def pdf_short_chapter_heads(path: Path, pages_per_chapter: int = 4) -> Path:
    """Short chapters whose recto heads carry the chapter title (only twice per chapter)."""
    doc = pymupdf.open()
    w, h = 595, 842
    titles = ["The Arrival", "The Storm", "The Letter", "The Return", "The Garden", "The End"]
    for n in range(pages_per_chapter * len(titles)):
        ch, off = divmod(n, pages_per_chapter)
        page = doc.new_page(width=w, height=h)
        if off:
            page.insert_text((60, 30), titles[ch] if off % 2 else "The Book Title", fontsize=9)
        page.insert_text((290, 825), str(n + 1), fontsize=9)
        y = 90
        if off == 0:
            page.insert_text((60, y), titles[ch], fontsize=24)
            y += 40
        _textbox(page, pymupdf.Rect(60, y, w - 60, y + 400), LOREM_EN * 2, 11)
    doc.set_toc([[1, t, 1 + pages_per_chapter * k] for k, t in enumerate(titles)])
    doc.save(str(path))
    return path


def pdf_outline(path: Path, entries: list[tuple[int, str, str]]) -> Path:
    """One page per outline entry: (level, title, body); an empty body makes a title-only page."""
    pages = [(title, body) for _, title, body in entries]
    toc = [[lvl, title, k + 1] for k, (lvl, title, _) in enumerate(entries)]
    return _pdf_from_pages(path, pages, toc)


def epub_glued_break_classes(path: Path) -> Path:
    """Chapters wrapped in glued CSS page-break classes, and content classes that merely contain
    a skip word ("PageNormal", "AfterCaptionText", "captionless", "pagebreaker")."""
    b = _base("Glued Breaks")
    c1 = _html("c1.xhtml", f'<div class="pagebreakbefore"><h2>Chapter One</h2><p>KEEP ONE. {LOREM_EN}</p></div>', "c1")
    c2 = _html("c2.xhtml", f'<div class="chapter-start PageBreakBefore"><h2>Chapter Two</h2><p>KEEP TWO. {LOREM_EN}</p>'
               '</div>', "c2")
    c3 = _html("c3.xhtml", f'<div class="pagebreakafter"><h2>Chapter Three</h2><p>KEEP THREE. {LOREM_EN}</p></div>'
               '<p class="PageNormal">KEEP PAGENORMAL.</p><p class="AfterCaptionText">KEEP AFTERCAPTION.</p>'
               '<div class="captionless"><p>KEEP CAPTIONLESS.</p></div><p class="pagebreaker">KEEP PAGEBREAKER.</p>'
               '<p class="MsoFootnoteText">DROP FOOTNOTE.</p>', "c3")
    toc = [epub.Link("c1.xhtml", "Chapter One", "c1"), epub.Link("c2.xhtml", "Chapter Two", "c2"),
           epub.Link("c3.xhtml", "Chapter Three", "c3")]
    return _finish(b, [c1, c2, c3], path, toc)


def epub_numbered_paragraph_titles(path: Path) -> Path:
    """Chapters whose heading is an ordinary paragraph: a numbered title ending with a full stop,
    a "Lesson 3:" label, a "Title: Subtitle" line and a "LETTER IV." letter heading."""
    b = _base("Paragraph Titles")
    heads = [("I. THE BEGINNING.", "The Beginning"), ("Lesson 3: Fractions", "Fractions"),
             ("The Return: In Which Our Hero Comes Home", "The Return"),
             ("LETTER IV. To Mrs. Saville, England.", "Letter IV")]
    items = [_html(f"c{n}.xhtml", f"<p>{head}</p><p>{LOREM_EN}</p>", f"c{n}") for n, (head, _) in enumerate(heads)]
    toc = [epub.Link(f"c{n}.xhtml", title, f"c{n}") for n, (_, title) in enumerate(heads)]
    return _finish(b, items, path, toc)


def epub_parts_only_ncx(path: Path) -> Path:
    """The NCX lists only the two parts; the EPUB 3 nav lists the parts and their chapters, each in its own file."""
    import zipfile

    b = _base("Parts Ncx")
    items, toc = [], []
    for p in (1, 2):
        items.append(_html(f"p{p}.xhtml", f"<h1>Part {p}</h1>", f"p{p}"))
        kids = []
        for n in (3 * p - 2, 3 * p - 1, 3 * p):
            items.append(_html(f"c{n}.xhtml", f"<h2>Chapter {n}</h2><p>{LOREM_EN}</p>", f"c{n}"))
            kids.append(epub.Link(f"c{n}.xhtml", f"Chapter {n}", f"c{n}"))
        toc.append((epub.Section(f"Part {p}", f"p{p}.xhtml"), kids))
    tmp = path.with_suffix(".tmp.epub")
    _finish(b, items, tmp, toc)
    ncx = (
        "<?xml version='1.0' encoding='utf-8'?>\n"
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
        '<head><meta name="dtb:uid" content="test-Parts Ncx"/></head><docTitle><text>Parts Ncx</text></docTitle><navMap>'
        + "".join(f'<navPoint id="np{p}"><navLabel><text>Part {p}</text></navLabel><content src="p{p}.xhtml"/>'
                  "</navPoint>" for p in (1, 2))
        + "</navMap></ncx>"
    )
    with zipfile.ZipFile(tmp) as src, zipfile.ZipFile(path, "w") as dst:
        for info in src.infolist():
            dst.writestr(info, ncx.encode() if info.filename.endswith(".ncx") else src.read(info.filename))
    tmp.unlink()
    return path


def epub_notes_then_styled_chapter(path: Path) -> Path:
    """Chapter 5's endnotes, then chapter 6 in the same file, which the TOC leaves out and whose
    heading is a <p class="chapter-title">."""
    b = _base("Missing Styled Chapter")
    c5 = _html("c5.xhtml", f"<h2>Chapter 5</h2><p>{LOREM_EN}</p>"
               '<section epub:type="endnotes"><ol><li><p>ENDNOTE FIVE.</p></li></ol></section>'
               f'<p class="chapter-title">Chapter 6</p><p>SIXTH CHAPTER. {LOREM_EN}</p>', "c5")
    c7 = _html("c7.xhtml", f"<h2>Chapter 7</h2><p>{LOREM_EN}</p>", "c7")
    toc = [epub.Link("c5.xhtml", "Chapter 5", "c5"), epub.Link("c7.xhtml", "Chapter 7", "c7")]
    return _finish(b, [c5, c7], path, toc)


def epub_heading_notes_quoting_the_heading(path: Path) -> Path:
    """Back-linked note calls on headings whose notes, on a page headed "Notes", quote the heading,
    or put the note number on a line of its own."""
    b = _base("Quoting Notes")
    c1 = _html("c1.xhtml", f'<h2>Introduction<a id="r1" href="notes.xhtml#n1">1</a></h2><p>{LOREM_EN}</p>', "c1")
    c2 = _html("c2.xhtml", f'<h2>The Making of a Town<a id="r2" href="notes.xhtml#n2">2</a></h2><p>{LOREM_EN}</p>', "c2")
    c3 = _html("c3.xhtml", f'<h2>Preface<a id="r3" href="notes.xhtml#n3">3</a></h2><p>{LOREM_EN}</p>', "c3")
    notes = _html("notes.xhtml", '<h1>Notes</h1>'
                  '<p id="n1"><a href="c1.xhtml#r1">1</a>. An earlier version of this introduction appeared in 1990.</p>'
                  '<p id="n2"><a href="c2.xhtml#r2">2</a>. Parts of The Making of a Town were given as a lecture.</p>'
                  '<p id="n3"><a href="c3.xhtml#r3">3</a></p><p>Written in 1991.</p>', "notes")
    toc = [epub.Link("c1.xhtml", "Introduction", "c1"), epub.Link("c2.xhtml", "The Making of a Town", "c2"),
           epub.Link("c3.xhtml", "Preface", "c3"), epub.Link("notes.xhtml", "Notes", "n")]
    return _finish(b, [c1, c2, c3, notes], path, toc)


def epub_shared_notes_container(path: Path, n: int) -> Path:
    """n note calls, and all n untyped notes in one container separated by <br/> (Calibre)."""
    b = _base("Shared Notes")
    paras = "".join(f'<p>It was a cold day. Call<a id="r{k}" href="#n{k}">{k}</a> here.</p>' for k in range(1, n + 1))
    notes = ('<div class="calibre3">'
             + "".join(f'<a id="n{k}"></a><a href="#r{k}">{k}</a> Note number {k} text.<br/>' for k in range(1, n + 1))
             + "</div>")
    c1 = _html("c1.xhtml", f"<h2>Chapter One</h2>{paras}{notes}", "c1")
    return _finish(b, [c1], path, [epub.Link("c1.xhtml", "Chapter One", "c1")])


def epub_mislabelled_utf8_html(path: Path) -> Path:
    """A text/html spine document whose bytes are UTF-8 but whose <meta> still says iso-8859-1."""
    b = _base("Mislabelled Html")
    c1 = _html("c1.xhtml", f"<h1>First</h1><p>{LOREM_EN}</p>", "c1")
    html_doc = (
        '<html><head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">'
        f"<title>c2</title></head><body><h1>Second</h1><p>Café ‘quoted’ naïve. {LOREM_EN}</p></body></html>"
    )
    c2 = epub.EpubItem(uid="c2", file_name="c2.html", media_type="text/html", content=html_doc.encode("utf-8"))
    toc = [epub.Link("c1.xhtml", "First", "c1"), epub.Link("c2.html", "Second", "c2")]
    return _finish(b, [c1, c2], path, toc)


def epub_contents_headed_by_a_notes_title(path: Path) -> Path:
    """A printed contents page whose first heading is the book title "Notes from Underground",
    and a chapter heading whose number links back to its bare-number contents line."""
    b = _base("Notes from Underground")
    contents = _html("contents.xhtml", '<h1>Notes from Underground</h1><h2>Contents</h2>'
                     '<p id="c1"><a href="c1.xhtml#x1">4</a></p>', "contents")
    c1 = _html("c1.xhtml", f'<h2><a id="x1" href="contents.xhtml#c1">4</a> The Beginning</h2><p>{LOREM_EN}</p>', "c1")
    toc = [epub.Link("contents.xhtml", "Contents", "t"), epub.Link("c1.xhtml", "The Beginning", "c1")]
    return _finish(b, [contents, c1], path, toc)
