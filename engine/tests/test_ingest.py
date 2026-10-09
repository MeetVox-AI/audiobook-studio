from __future__ import annotations

import json
import subprocess
import sys

import pytest

from audiobook_engine.ingest import read_book
from audiobook_engine.models import IngestError

from . import fixtures as fx


def chapters(book):
    return [s for s in book.sections if s.include]


def all_text(book):
    return " ".join(p for s in book.sections for p in s.paragraphs)


def test_epub_chapters_as_anchors_in_one_file(tmp_path):
    book = read_book(fx.epub_anchors(tmp_path / "a.epub"))
    titles = [s.title for s in chapters(book)]
    assert titles == ["Chapter One", "Chapter Two", "Chapter Three"]
    # each chapter holds only its own text
    ch = chapters(book)
    assert ch[0].paragraphs[0] == "Chapter 1" and ch[0].starts_with_heading
    assert all("Chapter 2" not in p for p in ch[0].paragraphs)
    assert ch[1].paragraphs[0] == "Chapter 2"


def test_epub_front_matter_unticked_with_reason(tmp_path):
    book = read_book(fx.epub_anchors(tmp_path / "a.epub"))
    cp = [s for s in book.sections if s.title == "Copyright"][0]
    assert cp.kind == "front" and cp.include is False
    assert cp.reasons


def test_epub_drops_footnotes_tables_and_markers(tmp_path):
    book = read_book(fx.epub_anchors(tmp_path / "a.epub"))
    text = " ".join(p for s in chapters(book) for p in s.paragraphs)
    assert "TABLECELL" not in text
    assert "FOOTNOTE TEXT" not in text
    # the superscript note marker "1" must not be glued to the sentence
    assert "thirteen" in text
    assert "born. 1 Second" not in text and "born.1" not in text
    assert "born. Second sentence here." in text


def test_epub_cover_and_metadata(tmp_path):
    book = read_book(fx.epub_anchors(tmp_path / "a.epub"))
    assert book.title == "Anchored Book"
    assert book.author == "Test Author"
    assert book.language == "en" and book.language_source == "metadata"
    assert book.cover is not None and book.cover.data[:4] == b"\x89PNG"


def test_epub_chapter_split_across_files(tmp_path):
    book = read_book(fx.epub_split(tmp_path / "s.epub"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["The Beginning", "The Middle"]
    assert any("CONTINUED part of chapter one" in p for p in ch[0].paragraphs)
    assert not any("CONTINUED" in p for p in ch[1].paragraphs)


def test_epub_heading_only_part_merged_into_first_chapter(tmp_path):
    book = read_book(fx.epub_nested(tmp_path / "n.epub"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["Part One: Chapter 1", "Chapter 2"]
    assert ch[0].paragraphs[:2] == ["Part One", "Chapter 1"]


def test_epub_without_toc_falls_back_to_spine_and_headings(tmp_path):
    book = read_book(fx.epub_notoc(tmp_path / "x.epub"))
    assert [s.title for s in chapters(book)] == ["Alpha", "Beta"]
    assert any("table of contents" in w.lower() for w in book.warnings)


def test_epub_french_language_and_toc_page(tmp_path):
    book = read_book(fx.epub_french(tmp_path / "f.epub"))
    assert book.language == "fr"
    toc = [s for s in book.sections if s.title == "Table des matières"][0]
    assert toc.kind == "front" and not toc.include
    assert [s.title for s in chapters(book)] == ["Chapitre premier"]


def test_pdf_outline_headers_hyphens_and_page_continuation(tmp_path):
    book = read_book(fx.pdf_with_outline(tmp_path / "o.pdf"))
    assert book.title == "Outline PDF" and book.author == "PDF Author"
    ch = chapters(book)
    assert [s.title for s in ch] == ["Chapter One", "Chapter Two"]
    text = all_text(book)
    assert "Running Header Of The Book" not in text
    assert "An example of a hyphenated" in text
    assert "continues on the next page, as the reader can see." in text
    # chapter two text does not leak into chapter one
    assert ch[1].paragraphs[0].startswith("Chapter Two")
    assert book.cover is not None and book.cover.media_type == "image/png"


def test_pdf_without_outline_uses_large_headings(tmp_path):
    book = read_book(fx.pdf_no_outline(tmp_path / "n.pdf"))
    assert [s.title for s in chapters(book)] == ["First Heading", "Second Heading"]
    assert any("large-font headings" in w for w in book.warnings)


def test_scanned_pdf_is_rejected_with_ocr_message(tmp_path):
    with pytest.raises(IngestError, match="OCR"):
        read_book(fx.pdf_scanned(tmp_path / "s.pdf"))


def test_unsupported_and_missing_files(tmp_path):
    p = tmp_path / "book.txt"
    p.write_text("hello")
    with pytest.raises(IngestError, match="Unsupported"):
        read_book(p)
    with pytest.raises(IngestError, match="not found"):
        read_book(tmp_path / "nope.epub")


def test_section_estimates_are_consistent(tmp_path):
    book = read_book(fx.epub_anchors(tmp_path / "a.epub"))
    j = book.to_json()
    total = sum(s["est_seconds"] for s in j["sections"] if s["include"])
    assert abs(total - j["included_est_seconds"]) < 1.0
    assert j["included_chars"] == sum(s.chars for s in chapters(book))


def test_cli_inspect_outputs_json(tmp_path):
    path = fx.epub_anchors(tmp_path / "a.epub")
    cover = tmp_path / "cover.png"
    r = subprocess.run(
        [sys.executable, "-m", "audiobook_engine.cli", "inspect", str(path), "--cover-out", str(cover)],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(r.stdout)
    assert data["title"] == "Anchored Book"
    assert cover.exists() and cover.stat().st_size > 0


def test_cli_inspect_error_is_json(tmp_path):
    r = subprocess.run(
        [sys.executable, "-m", "audiobook_engine.cli", "inspect", str(tmp_path / "missing.epub")],
        capture_output=True, text=True,
    )
    assert r.returncode == 2
    assert json.loads(r.stdout)["event"] == "error"


# --- Regressions found on real Project Gutenberg books -------------------------

def _gut(tmp_path, **kw):
    return read_book(fx.epub_gutenberg_like(tmp_path / "g.epub", **kw))


def test_gutenberg_last_chapter_kept_and_license_excluded(tmp_path):
    book = _gut(tmp_path)
    ch = chapters(book)
    assert ch[-1].title == "CHAPTER VI."
    lic = [s for s in book.sections if "license" in s.title.lower()]
    assert lic and not lic[0].include and lic[0].kind == "back"
    text = all_text(book)
    assert "*** END" not in text and "*** START" not in text
    assert "Updated editions" not in " ".join(p for s in ch for p in s.paragraphs)


def test_gutenberg_drop_caps_captions_and_page_numbers(tmp_path):
    book = _gut(tmp_path)
    text = " ".join(p for s in chapters(book) for p in s.paragraphs)
    assert "WHEN chapter 1 begins." in text
    assert "A caption" not in text
    assert "[Pg" not in text and "{1}" not in text
    assert [s.title for s in chapters(book)][:3] == ["CHAPTER I.", "CHAPTER II.", "CHAPTER III."]


def test_gutenberg_header_title_page_and_printed_toc_are_front(tmp_path):
    book = _gut(tmp_path)
    front = [s for s in book.sections if s.kind == "front"]
    assert any("Gutenberg header" in ";".join(s.reasons) for s in front)
    assert any("table of contents" in ";".join(s.reasons) for s in front)
    assert all(not s.include for s in front)


def test_chapter_missing_from_toc_is_recovered_with_warning(tmp_path):
    book = _gut(tmp_path)
    titles = [s.title for s in chapters(book)]
    assert titles == ["CHAPTER I.", "CHAPTER II.", "CHAPTER III.", "CHAPTER IV.", "CHAPTER V.", "CHAPTER VI."]
    assert any("Recovered 'CHAPTER IV.'" in w for w in book.warnings)
    assert book.title == "Gutenberg Like"  # book title must never be replaced by a chapter title


def test_no_false_recovery_when_toc_title_has_a_caption(tmp_path):
    book = _gut(tmp_path, drop_from_toc=None, caption_titles=True)
    assert not any("Recovered" in w for w in book.warnings)
    assert [s.title for s in chapters(book)][3] == "CHAPTER IV."
    assert book.title == "Gutenberg Like"


def test_short_chapters_are_not_mistaken_for_title_pages(tmp_path):
    book = read_book(fx.epub_short_poems(tmp_path / "p.epub"))
    assert [s.title for s in chapters(book)] == [f"Poem {n}" for n in range(1, 6)]


@pytest.mark.parametrize("builder", ["epub_anchors", "epub_split", "epub_nested", "epub_notoc", "epub_french", "epub_short_poems"])
def test_book_title_comes_from_metadata(tmp_path, builder):
    book = read_book(getattr(fx, builder)(tmp_path / "b.epub"))
    expected = {"epub_anchors": "Anchored Book", "epub_split": "Split Book", "epub_nested": "Nested Book",
                "epub_notoc": "No TOC Book", "epub_french": "Livre Français", "epub_short_poems": "Short Poems"}[builder]
    assert book.title == expected


# --- Code-review regressions: ingest ---------------------------------------------

def _text_of(sections):
    return " ".join(p for s in sections for p in s.paragraphs)


def _containing(book, needle):
    return [s for s in book.sections if any(needle in p for p in s.paragraphs)]


def test_epub_kind_comes_from_section_start_not_every_block(tmp_path):
    book = read_book(fx.epub_typed_matter(tmp_path / "t.epub"))
    ch = chapters(book)
    # endnotes inside chapter 12 and a dedication before chapter 13 used to exclude both chapters
    assert [s.title for s in ch] == ["Chapter 12", "Chapter 13"]
    assert all(s.kind == "chapter" for s in ch)
    text = _text_of(ch)
    assert "ENDNOTE TEXT" not in text and "ACK TEXT" not in text and "For my mother" not in text
    notes = _containing(book, "ENDNOTE TEXT")[0]
    assert notes.kind == "back" and not notes.include
    ack = _containing(book, "ACK TEXT")[0]
    assert ack.kind == "back" and not ack.include and ack.title == "Thanks"
    ded = _containing(book, "For my mother")[0]
    assert ded.kind == "front" and not ded.include and ded.title == "Dedication"


@pytest.mark.parametrize(
    "value, expected",
    [("und", None), ("mul", None), ("zxx", None), ("eng", "en"), ("fre", "fr"), ("fra", "fr"), ("French", "fr"),
     ("Français", "fr"), ("English (US)", "en"), ("en-US", "en"), ("fr_CA", "fr"), ("deu", "de"), ("ja", "ja"),
     ("", None), (None, None), ("???", None), ("zz", None), ("x-unknown", None), ("UNK", None), ("en, fr", "en"),
     ("glg", "glg"), ("iw", "he"), ("jp", "ja")],
)
def test_normalize_language_codes_and_names(value, expected):
    from audiobook_engine.ingest.classify import normalize_language

    assert normalize_language(value) == expected


@pytest.mark.parametrize(
    "meta, french, expected, source",
    [("und", False, "en", "detected"), ("eng", False, "en", "metadata"), ("fre", True, "fr", "metadata"),
     ("French", True, "fr", "metadata"), ("zz", True, "fr", "detected")],
)
def test_epub_unusable_metadata_language_falls_back_to_detection(tmp_path, meta, french, expected, source):
    book = read_book(fx.epub_language(tmp_path / "l.epub", meta, french))
    assert (book.language, book.language_source) == (expected, source)


def test_epub_paragraph_styled_titles_count_as_headings(tmp_path):
    book = read_book(fx.epub_styled_titles(tmp_path / "s.epub"))
    swh = {s.title: s.starts_with_heading for s in book.sections}
    # <p class="chapter-title">, a <div> equal to the TOC title, and a <p> holding part of it
    assert swh == {"Chapter One": True, "Chapter Two": True, "3. Origins": True, "Chapter Four": False}


def test_looks_like_title_rejects_sentences_and_tiny_titles():
    from audiobook_engine.ingest.classify import looks_like_title

    assert looks_like_title("CHAPTER ONE", ["Chapter One: The Beginning"])
    assert looks_like_title("Chapter 1: Origins", ["Origins"])
    assert looks_like_title("Chapter I", ["I"])
    assert not looks_like_title("I was born in a small town.", ["I"])
    assert not looks_like_title("It was a dark night and the rain fell.", ["Chapter Four"])
    assert not looks_like_title("x" * 200, ["x" * 200])
    assert not looks_like_title("Some text", ["Other"], "chapter-text calibre5")


def test_epub_cross_references_exponents_and_content_classes_are_kept(tmp_path):
    book = read_book(fx.epub_note_markers(tmp_path / "n.epub"))
    ch = chapters(book)
    text = _text_of(ch)
    assert "As we saw in Chapter 2, the speed is 10 m/s2 here." in text
    assert "KEEP THIS PARAGRAPH" in text and "KEEP CAPTIONED TEXT" in text
    # real note calls are still removed: untyped endnote with a back-link, typed footnote target, symbol
    assert "An untyped endnote call and a footnote call and a star end." in text
    # a note body starting with its number, a bracketed citation; a page cross-reference is kept
    assert "A numbered note, a citation, and see page 12 for more." in text
    assert "FOOTNOTE TWO" not in text
    # a heading whose whole text is a link (back to a contents page) keeps its text
    assert ch[1].paragraphs[0] == "II"


def test_epub_heading_only_title_page_before_toc_is_not_merged_into_chapter_one(tmp_path):
    book = read_book(fx.epub_title_page_before_toc(tmp_path / "t.epub"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["Chapter One", "Chapter Two"]
    assert ch[0].paragraphs[0] == "Chapter One"
    title_page = _containing(book, "Jane Doe")[0]
    assert title_page.kind == "front" and not title_page.include


def test_epub_front_matter_heading_page_is_not_merged_into_next_section(tmp_path):
    book = read_book(fx.epub_title_page_then_dedication(tmp_path / "d.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter One"]
    kinds = {s.title: (s.kind, s.include) for s in book.sections}
    assert kinds["Title Page"] == ("front", False) and kinds["Dedication"] == ("front", False)


def test_epub_toc_anchors_inside_inline_skipped_and_name_anchors(tmp_path):
    book = read_book(fx.epub_anchor_variants(tmp_path / "a.epub"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["Chapter One", "Chapter Two", "Chapter Three", "Chapter Four"]
    for s, word in zip(ch, ["ONE.", "TWO.", "THREE.", "FOUR."]):
        assert word in _text_of([s]) and sum(w in _text_of([s]) for w in ["ONE.", "TWO.", "THREE.", "FOUR."]) == 1
    assert not any("anchors were not found" in w for w in book.warnings)


def test_epub_parent_and_child_sharing_a_target_keep_both_titles(tmp_path):
    book = read_book(fx.epub_shared_parent_target(tmp_path / "p.epub"))
    assert [s.title for s in chapters(book)] == ["Part I: Foundations: Chapter 1: Origins", "Chapter 2: Growth"]


def test_epub_text_html_spine_document_is_read_and_skips_are_reported(tmp_path):
    book = read_book(fx.epub_html_spine(tmp_path / "h.epub"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["First", "Second"]
    assert any("SECOND CHAPTER TEXT" in p and "more text" in p for p in ch[1].paragraphs)
    assert any("c3.dtb" in w and "not text documents" in w for w in book.warnings)
    assert not any("outside the reading order" in w for w in book.warnings)


def test_epub_stub_ncx_does_not_hide_the_nav_toc(tmp_path):
    book = read_book(fx.epub_stub_ncx(tmp_path / "s.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter 1", "Chapter 2", "Chapter 3"]


@pytest.mark.parametrize(
    "title, kind",
    [("À propos de l’auteur", "back"), ("A propos de l'auteur", "back"), ("L’auteur", "back"),
     ("Achevé d’imprimer", "front"), ("Achevé d'imprimer", "front"), ("L’homme qui rit", "chapter")],
)
def test_french_titles_with_typographic_apostrophes(title, kind):
    from audiobook_engine.ingest.classify import classify_section
    from audiobook_engine.models import Section

    sec = Section(index=3, title=title, kind="chapter", paragraphs=["Un texte assez long. " * 300])
    classify_section(sec)
    assert sec.kind == kind


def test_pdf_chapter_running_heads_removed_and_page_continuation_merged(tmp_path):
    book = read_book(fx.pdf_running_heads(tmp_path / "r.pdf"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["Chapter One", "Chapter Two", "Chapter Three", "Chapter Four"]
    for s in ch:
        # the chapter title is its own heading once, never repeated as a running head
        assert [p for p in s.paragraphs if p == s.title] == [s.title] and s.paragraphs[0] == s.title
    assert "The Book Title" not in all_text(book)
    assert "This sentence continues on the next page, as the reader can see." in _text_of([ch[1]])


def test_pdf_outline_parts_cut_at_chapters(tmp_path):
    book = read_book(fx.pdf_parts(tmp_path / "p.pdf"))
    ch = chapters(book)
    assert [s.title for s in ch] == ["Part One: Chapter 1", "Chapter 2", "Part Two: Chapter 3"]
    assert ch[0].paragraphs[:2] == ["Part One", "Chapter 1"]
    kinds = {s.title: s.kind for s in book.sections if not s.include}
    assert kinds == {"Title Page": "front", "Contents": "front", "Acknowledgments": "back"}


def test_pdf_outline_numbered_subsections_stay_inside_chapters(tmp_path):
    book = read_book(fx.pdf_subsections(tmp_path / "s.pdf"))
    assert [s.title for s in chapters(book)] == ["1 Introduction", "2 Methods", "3 Results"]


def test_pdf_line_end_hyphens_keep_french_inversions_and_compounds(tmp_path):
    book = read_book(fx.pdf_french_hyphens(tmp_path / "f.pdf"))
    text = all_text(book)
    assert "« Viendra-t-il demain ? » demanda-t-il. C'est peut-être vrai, dit-elle." in text
    assert "Voici un exemple de mot coupé." in text


def test_join_lines_uses_language_and_the_books_own_vocabulary():
    from collections import Counter

    from audiobook_engine.ingest.pdf import _join_lines, _vocabulary

    fr = ["« Viendra-t-il demain ? » demanda-", "t-il. C’est peut-", "être vrai, dit-", "elle."]
    expected = "« Viendra-t-il demain ? » demanda-t-il. C’est peut-être vrai, dit-elle."
    assert _join_lines(fr, "fr", Counter()) == expected
    assert _join_lines(["a well-", "known fact"], "en", Counter()) == "a well-known fact"
    assert _join_lines(["an exam-", "ple"], "en", Counter()) == "an example"
    assert _join_lines(["Jean-", "Pierre came"], "fr", Counter()) == "Jean-Pierre came"
    # the book's own spelling wins over the fallback rules
    vocab = _vocabulary(["they co-operate well", "self-ish"])
    assert _join_lines(["we co-", "operate"], "en", vocab) == "we co-operate"
    assert _join_lines(["la vil-", "le est belle"], "fr", _vocabulary(["la ville"])) == "la ville est belle"


_FRONT_MATTER = "Copyright © 2020 Some Author. All rights reserved. ISBN 978-0-00-000000-0\n" + "".join(
    f"Chapter {n}: A rather long chapter title here ..... {n * 7}\n" for n in range(1, 61)
)


_CONTENTS_LINES = "".join(f"Chapter {n}: A rather long chapter title here ..... {n * 7}\n" for n in range(1, 63))


@pytest.mark.parametrize(
    "opening, heading, include, long",
    [(_FRONT_MATTER, None, False, True),
     (_CONTENTS_LINES, "Contents", False, True),
     ("A short epigraph about the sea and the sky.", None, False, False),
     (fx.LOREM_EN * 14, None, True, True)],
    ids=["long-copyright", "long-printed-contents", "short-no-signal", "long-prose-preface"],
)
def test_pdf_opening_pages_before_outline_are_front_matter(tmp_path, opening, heading, include, long):
    book = read_book(fx.pdf_opening_pages(tmp_path / "o.pdf", opening, heading))
    first = book.sections[0]
    assert first.title == "Opening pages"
    # the long cases are past the 3000-char limit of the generic copyright rule
    assert (first.chars >= 3000) is long
    assert first.include is include
    if not include:
        assert first.kind == "front" and first.reasons[0].startswith("before the first outline entry")
    assert [s.title for s in chapters(book)][-2:] == ["Chapter One", "Chapter Two"]


def test_pdf_section_of_large_font_lines_is_a_printed_contents(tmp_path):
    book = read_book(fx.pdf_heading_list(tmp_path / "h.pdf"))
    overview = book.sections[0]
    assert overview.title == "Overview" and overview.kind == "front" and not overview.include
    assert [s.title for s in chapters(book)] == ["Chapter One", "Chapter Two"]


# --- Round-2 regressions: ingest ---------------------------------------------------

@pytest.mark.parametrize("lang, text", [("de", fx.LOREM_DE), ("nl", fx.LOREM_NL), ("es", fx.LOREM_ES),
                                        ("it", fx.LOREM_IT), ("pt", fx.LOREM_PT)])
def test_epub_valid_metadata_language_that_is_not_en_or_fr_is_kept(tmp_path, lang, text):
    # German/Dutch text used to become 'en' and Spanish/Italian 'fr' (the vote only knew en/fr)
    book = read_book(fx.epub_text_language(tmp_path / "l.epub", lang, text))
    assert (book.language, book.language_source) == (lang, "metadata")
    assert not any("looks like" in w for w in book.warnings)


@pytest.mark.parametrize("text, expected", [(fx.LOREM_EN, "en"), (fx.LOREM_FR, "fr"), (fx.LOREM_DE, "de"),
                                            (fx.LOREM_NL, "nl"), (fx.LOREM_ES, "es"), (fx.LOREM_IT, "it"),
                                            (fx.LOREM_PT, "pt")])
def test_detect_language_does_not_force_other_languages_into_en_or_fr(text, expected):
    from audiobook_engine.ingest.classify import detect_language

    assert detect_language(text * 5) == expected


def test_epub_undetermined_metadata_with_german_text_is_not_english(tmp_path):
    book = read_book(fx.epub_text_language(tmp_path / "l.epub", "und", fx.LOREM_DE))
    assert book.language == "de"  # the pipeline then reports an unsupported language


def test_epub_metadata_language_contradicted_by_the_text_is_kept_with_a_warning(tmp_path):
    book = read_book(fx.epub_text_language(tmp_path / "l.epub", "de", fx.LOREM_EN))
    assert (book.language, book.language_source) == ("de", "metadata")
    assert any("looks like 'en'" in w for w in book.warnings)


def test_pdf_small_font_notes_do_not_turn_chapters_into_a_printed_contents(tmp_path):
    book = read_book(fx.pdf_notes_heavy(tmp_path / "n.pdf"))
    assert book.metadata["body_font_size"] == 7.0  # the notes outweigh the main text
    assert [s.title for s in chapters(book)] == ["Chapter One", "Chapter Two", "Chapter Three"]
    assert all(s.starts_with_heading for s in chapters(book))


def test_pdf_warns_when_no_section_is_selected(tmp_path):
    pages = [("Contents", "".join(f"Chapter {n} ..... {6 * n}\n" for n in range(1, 6))),
             ("Notes", "1. Smith, op. cit., p. 12, on the history of the town and its harbour.")]
    book = read_book(fx._pdf_from_pages(tmp_path / "x.pdf", pages, [[1, "Contents", 1], [1, "Notes", 2]]))
    assert not chapters(book)
    assert any("No section was selected automatically" in w for w in book.warnings)


def test_epub_note_calls_on_headings_are_dropped_but_contents_links_kept(tmp_path):
    book = read_book(fx.epub_heading_notes(tmp_path / "h.epub"))
    first = {s.title: s.paragraphs[0] for s in book.sections}
    assert first["Chapter 1"] == "Chapter 1"  # was "Chapter 11", spoken "Chapter eleven"
    assert first["Introduction"] == "Introduction"  # was "Introduction2"
    assert first["Prologue"] == "Prologue"  # unlinked <sup>3</sup> on a heading
    assert first["III The Return"] == "III The Return"  # a link back to the contents keeps its text
    assert first["Why E = mc2"] == "Why E = mc2"  # an exponent after a one/two-letter symbol is kept
    assert first["The Beginning"] == "4 The Beginning"  # a contents back-link whose entry is a bare number


def test_skip_class_matches_glued_and_camel_case_note_classes():
    from audiobook_engine.ingest.epub import _skip_class

    for cls in ["MsoFootnoteText", "footnotetext", "footnoteText", "captiontext", "footnoteref", "x-ebookmaker-pageno",
                "imgcaption", "_idFootnotes", "footnote-text", "pagenum"]:
        assert _skip_class(cls), cls
    for cls in ["captioned-image", "pagebreak-before", "nopagebreak", "page-break-after", "chapter calibre5", ""]:
        assert not _skip_class(cls), cls


def test_epub_note_bodies_and_unlinked_calls_are_not_narrated(tmp_path):
    book = read_book(fx.epub_note_bodies(tmp_path / "n.epub"))
    text = _text_of(chapters(book))
    for body in ["WORD FOOTNOTE", "TEX FOOTNOTE", "CAMEL FOOTNOTE", "CAPTIONTEXT", "KINDLE NOTE BODY"]:
        assert body not in text, body
    assert "KEEP CAPTIONED TEXT." in text
    # an unlinked number after a full stop is a note call; an exponent after a digit is not
    assert "He was born. Second sentence here, at 106 volts." in text
    assert "Kindle call here." in text


@pytest.mark.parametrize(
    "text, titles",
    [("Mother came home late that night.", ["Mother"]), ("He walked toward the sea.", ["The Sea"]),
     ("The Letter arrived on Tuesday.", ["The Letter"]), ("“Let us go down to the sea.”", ["The Sea"]),
     ("I dream.", ["Dream"]), ("First night.", ["Night"]), ("12 men stood at the door of the house.", ["12"])],
)
def test_looks_like_title_rejects_first_sentences_containing_the_title(text, titles):
    from audiobook_engine.ingest.classify import looks_like_title

    assert not looks_like_title(text, titles)


def test_looks_like_title_label_forms_and_heading_classes():
    from audiobook_engine.ingest.classify import looks_like_title

    assert looks_like_title("Chapter One: Origins", ["Origins"])
    assert looks_like_title("Part II The Return", ["The Return"])
    assert looks_like_title("CHAPTER I. ORIGINS.", ["Origins"])
    assert looks_like_title("Chapter 1: The Beginning", ["Chapter 1"])
    assert looks_like_title("Anything", ["Other"], "chapter-title")
    assert not looks_like_title("From the Book of Days", ["Chapter Three"], "epigraph-title")
    assert not looks_like_title("A Novel", ["Chapter Three"], "subtitle")


def test_epub_first_sentence_starting_with_the_title_still_gets_the_title_announced(tmp_path):
    from audiobook_engine.textproc.normalize import normalize_section

    b = fx._base("Titles")
    items = [fx._html("c1.xhtml", f"<p>Mother came home late that night.</p><p>{fx.LOREM_EN}</p>", "c1"),
             fx._html("c2.xhtml", f'<p class="epigraph-title">From the Book of Days</p><p>{fx.LOREM_EN}</p>', "c2")]
    toc = [fx.epub.Link("c1.xhtml", "Mother", "c1"), fx.epub.Link("c2.xhtml", "Chapter Three", "c2")]
    book = read_book(fx._finish(b, items, tmp_path / "t.epub", toc))
    for s in book.sections:
        assert not s.starts_with_heading
        assert normalize_section(s.paragraphs[:1], "en", s.starts_with_heading, s.title)[0] == s.title + "."


def test_pdf_running_heads_removed_in_short_chapters(tmp_path):
    book = read_book(fx.pdf_short_chapter_heads(tmp_path / "r.pdf", pages_per_chapter=4))
    ch = chapters(book)
    assert len(ch) == 6
    for s in ch:
        # the recto head carrying the chapter title appears only twice per chapter
        assert [p for p in s.paragraphs if p == s.title] == [s.title], s.title
    assert "The Book Title" not in all_text(book)


def test_pdf_outline_numbered_scenes_stay_inside_named_chapters(tmp_path):
    L = fx.LOREM_EN * 2
    pages = [("The Boy", L), ("2", L), ("The Glass", L), ("2", L), ("The Letters", L), ("2", L)]
    toc = [[1, "The Boy", 1], [2, "1", 1], [2, "2", 2], [1, "The Glass", 3], [2, "1", 3], [2, "2", 4],
           [1, "The Letters", 5], [2, "1", 5], [2, "2", 6]]
    book = read_book(fx._pdf_from_pages(tmp_path / "s.pdf", pages, toc))
    assert [s.title for s in chapters(book)] == ["The Boy", "The Glass", "The Letters"]


def test_pdf_outline_named_parts_with_title_pages_cut_at_chapters(tmp_path):
    L = fx.LOREM_EN * 2
    book = read_book(fx.pdf_outline(tmp_path / "p.pdf", [
        (1, "Title", "The Book by Someone"), (1, "The Early Years", ""), (2, "Childhood", L), (2, "School", L),
        (1, "The War", ""), (2, "Enlisting", L), (2, "France", L)]))
    assert [s.title for s in chapters(book)][-4:] == ["The Early Years: Childhood", "School", "The War: Enlisting",
                                                      "France"]


def test_pdf_outline_chapters_numbered_through_named_parts(tmp_path):
    L = fx.LOREM_EN * 2
    pages = [("The Early Years", L), ("2", L), ("The War", L), ("4", L)]
    toc = [[1, "Title", 1], [1, "The Early Years", 1], [2, "1", 1], [2, "2", 2], [1, "The War", 3], [2, "3", 3],
           [2, "4", 4]]
    book = read_book(fx._pdf_from_pages(tmp_path / "c.pdf", pages, toc))
    assert len(chapters(book)) == 4


@pytest.mark.parametrize("case, expected", [
    ("glossary", [("Chapter One", "chapter"), ("Glossary", "back"), ("Chapter Two", "chapter")]),
    ("copyright", [("Copyright page", "front"), ("Chapter One", "chapter"), ("Chapter Two", "chapter")]),
    ("dedication", [("Dedication", "front"), ("13. The Return", "chapter"), ("Chapter Two", "chapter")]),
])
def test_epub_inline_matter_keeps_chapter_text_and_titles_together(tmp_path, case, expected):
    book = read_book(fx.epub_inline_matter(tmp_path / "m.epub", case))
    assert [(s.title, s.kind) for s in book.sections] == expected
    if case == "glossary":
        # the rest of chapter one is not a separate section titled with its first 60 characters
        assert any("REST OF CHAPTER ONE" in p for p in book.sections[0].paragraphs)
        assert not any("GLOSSARY" in p for p in book.sections[0].paragraphs)


def test_epub_text_after_inline_matter_that_opens_with_a_heading_is_its_own_section(tmp_path):
    book = read_book(fx.epub_notes_then_untitled_chapter(tmp_path / "m.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter 5", "Chapter 6", "Chapter 7"]
    assert not any("SIXTH CHAPTER" in p for p in chapters(book)[0].paragraphs)


def test_epub_without_toc_title_page_is_not_merged_into_chapter_one(tmp_path):
    book = read_book(fx.epub_title_page_no_toc(tmp_path / "t.epub"))
    ch1 = _containing(book, "Chapter One")[0]
    assert ch1.include and ch1.kind == "chapter" and ch1.paragraphs[0] == "Chapter One"
    assert "Jane Doe" not in ch1.paragraphs


def test_epub_legacy_html_document_is_decoded_with_its_declared_charset(tmp_path):
    book = read_book(fx.epub_legacy_html(tmp_path / "l.epub"))
    assert "Café ‘quoted’ naïve." in _text_of(chapters(book))


def test_epub_empty_document_in_the_spine_does_not_abort_ingest(tmp_path):
    book = read_book(fx.epub_empty_document(tmp_path / "e.epub"))
    assert [s.title for s in chapters(book)] == ["One", "Three"]


def test_epub_complete_ncx_is_kept_when_the_nav_only_adds_subsections(tmp_path):
    book = read_book(fx.epub_deep_nav(tmp_path / "d.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter 1", "Chapter 2"]
    assert not any("incomplete" in w for w in book.warnings)


def test_epub_drop_cap_with_opening_quote_is_kept(tmp_path):
    book = read_book(fx.epub_quoted_drop_cap(tmp_path / "d.epub"))
    assert chapters(book)[0].paragraphs[1].startswith("“I hope, my dear,” said Mr. Bennet.")


def test_skip_class_keeps_glued_break_modifiers_and_words_that_only_contain_a_skip_word():
    from audiobook_engine.ingest.epub import _skip_class

    for cls in ["pagebreakbefore", "PageBreakBefore", "pagebreakafter", "chapter-start pagebreakbefore", "pagebreaker",
                "pagenormal", "PageNormal", "pagenote", "captionless", "AfterCaptionText"]:
        assert not _skip_class(cls), cls
    for cls in ["pagebreak", "chapter-pagebreak", "pageno", "x-ebookmaker-pageno", "captiontext", "MsoFootnoteText",
                "_idFootnoteLink", "para-after-caption"]:
        assert _skip_class(cls), cls


def test_epub_chapter_wrapped_in_a_glued_page_break_class_is_kept(tmp_path):
    book = read_book(fx.epub_glued_break_classes(tmp_path / "g.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter One", "Chapter Two", "Chapter Three"]
    text = _text_of(chapters(book))
    for keep in ["KEEP ONE.", "KEEP TWO.", "KEEP THREE.", "KEEP PAGENORMAL.", "KEEP AFTERCAPTION.", "KEEP CAPTIONLESS.",
                 "KEEP PAGEBREAKER."]:
        assert keep in text, keep
    assert "DROP FOOTNOTE." not in text


@pytest.mark.parametrize(
    "text, titles",
    [("I. THE BEGINNING.", ["The Beginning"]), ("II. THE RETURN.", ["The Return"]),
     ("1. The Beginning.", ["The Beginning"]), ("XII. A NEW DAY.", ["A New Day"]),
     ("Lesson 3: Fractions", ["Fractions"]), ("Day 1: Arrival", ["Arrival"]),
     ("The Beginning: In Which Our Hero Is Born", ["The Beginning"]),
     ("LETTER IV. To Mrs. Saville, England.", ["Letter IV"])],
)
def test_looks_like_title_accepts_numbered_labelled_and_subtitled_paragraph_headings(text, titles):
    from audiobook_engine.ingest.classify import looks_like_title

    assert looks_like_title(text, titles)


@pytest.mark.parametrize(
    "text, titles",
    [("Rain. It had rained for days.", ["Rain"]), ("Mother. She came home late.", ["Mother"]),
     ("I dream.", ["Dream"]), ("First night.", ["Night"]), ("The Letter arrived on Tuesday.", ["The Letter"])],
)
def test_looks_like_title_still_rejects_sentences_that_open_or_close_with_the_title(text, titles):
    from audiobook_engine.ingest.classify import looks_like_title

    assert not looks_like_title(text, titles)


def test_epub_numbered_paragraph_title_is_spoken_once(tmp_path):
    from audiobook_engine.textproc.normalize import normalize_section

    book = read_book(fx.epub_numbered_paragraph_titles(tmp_path / "t.epub"))
    assert [s.title for s in chapters(book)] == ["The Beginning", "Fractions", "The Return", "Letter IV"]
    for s in chapters(book):
        assert s.starts_with_heading, s.title
        spoken = normalize_section(s.paragraphs, "en", s.starts_with_heading, s.title)
        assert len(spoken) == len(s.paragraphs), spoken[:2]  # no extra title line before the heading paragraph


def test_epub_nav_listing_chapters_beats_an_ncx_listing_only_parts(tmp_path):
    book = read_book(fx.epub_parts_only_ncx(tmp_path / "p.epub"))
    assert [s.title for s in chapters(book)] == ["Part 1: Chapter 1", "Chapter 2", "Chapter 3", "Part 2: Chapter 4",
                                                 "Chapter 5", "Chapter 6"]
    assert any("NCX table of contents is incomplete" in w for w in book.warnings)


def test_epub_paragraph_styled_heading_after_inline_matter_starts_its_own_section(tmp_path):
    book = read_book(fx.epub_notes_then_styled_chapter(tmp_path / "m.epub"))
    assert [s.title for s in chapters(book)] == ["Chapter 5", "Chapter 6", "Chapter 7"]
    assert not any("SIXTH CHAPTER" in p for p in chapters(book)[0].paragraphs)
    assert chapters(book)[1].starts_with_heading


def test_epub_heading_note_calls_whose_notes_quote_the_heading_are_dropped(tmp_path):
    book = read_book(fx.epub_heading_notes_quoting_the_heading(tmp_path / "q.epub"))
    first = {s.title: s.paragraphs[0] for s in chapters(book)}
    assert first == {"Introduction": "Introduction", "The Making of a Town": "The Making of a Town",
                     "Preface": "Preface"}


def test_epub_notes_in_one_shared_container_are_checked_in_linear_time(tmp_path, monkeypatch):
    from audiobook_engine.ingest import epub as epub_mod

    work = {"chars": 0}
    real_clean = epub_mod._clean

    def counting_clean(text):
        work["chars"] += len(text)
        return real_clean(text)

    monkeypatch.setattr(epub_mod, "_clean", counting_clean)
    cost = {}
    for n in (150, 300):
        work["chars"] = 0
        book = read_book(fx.epub_shared_notes_container(tmp_path / f"s{n}.epub", n))
        cost[n] = work["chars"]
        text = _text_of(chapters(book))
        assert "Call here." in text and "Call1 here" not in text
    # twice the notes: about twice the work, not four times
    assert cost[300] < 3 * cost[150], cost


def test_epub_utf8_html_document_with_a_stale_legacy_charset_is_read_as_utf8(tmp_path):
    book = read_book(fx.epub_mislabelled_utf8_html(tmp_path / "u.epub"))
    assert "Café ‘quoted’ naïve." in _text_of(chapters(book))


def test_epub_without_toc_heading_only_title_page_is_front_matter(tmp_path):
    book = read_book(fx.epub_title_page_no_toc(tmp_path / "t.epub"))
    title_page = book.sections[0]
    assert title_page.paragraphs == ["The Book", "A Novel", "Jane Doe"]
    assert title_page.kind == "front" and not title_page.include and title_page.reasons
    assert [s.title for s in chapters(book)] == ["Chapter One", "Chapter Two"]


def test_epub_contents_link_on_a_heading_is_kept_when_the_contents_page_is_headed_notes_something(tmp_path):
    book = read_book(fx.epub_contents_headed_by_a_notes_title(tmp_path / "c.epub"))
    assert chapters(book)[0].paragraphs[0] == "4 The Beginning"



def test_gutenberg_closing_formula_is_not_narrated(tmp_path):
    book = _gut(tmp_path)
    text = " ".join(p for s in chapters(book) for p in s.paragraphs)
    assert "End of Project Gutenberg" not in text
    assert chapters(book)[-1].paragraphs[-1].endswith(LOREM_TAIL)


LOREM_TAIL = fx.LOREM_EN.strip()
