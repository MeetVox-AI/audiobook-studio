from __future__ import annotations

import pytest

from audiobook_engine.textproc.segment import chunk_section, split_sentences


def test_split_sentences_basic_and_quotes():
    s = 'He left. "Where?" she asked! It was late... Then J. K. Rowling arrived.'
    assert split_sentences(s) == ["He left.", '"Where?" she asked!', "It was late...", "Then J. K. Rowling arrived."]


def test_split_french_guillemets_and_dashes():
    s = "Il partit. « Où allez-vous ? » demanda-t-elle. — Nulle part."
    out = split_sentences(s)
    assert out[0] == "Il partit."
    assert out[-1] == "— Nulle part."


def test_chunks_respect_cap_and_paragraphs():
    paras = ["Chapter one.", "A short sentence. " * 30, "Another paragraph here."]
    chunks = chunk_section(3, paras, cap=120)
    assert all(c.chars <= 120 for c in chunks)
    assert chunks[0].is_heading and chunks[0].text == "Chapter one." and chunks[0].paragraph_end
    assert {c.paragraph for c in chunks} == {0, 1, 2}
    # no chunk mixes paragraphs, and every paragraph's last chunk is flagged
    for p in (0, 1, 2):
        pc = [c for c in chunks if c.paragraph == p]
        assert pc[-1].paragraph_end and not any(c.paragraph_end for c in pc[:-1])
    assert [c.index for c in chunks] == list(range(len(chunks)))
    assert all(c.section == 3 for c in chunks)


def test_long_sentence_split_at_clauses_then_words():
    long = "First clause goes here, " * 20 + "and it ends."
    chunks = chunk_section(0, [long], cap=100, first_is_heading=False)
    assert all(c.chars <= 100 for c in chunks)
    assert " ".join(c.text for c in chunks) == long.strip()
    nospace = "word " * 100
    chunks = chunk_section(0, [nospace.strip()], cap=50, first_is_heading=False)
    assert all(c.chars <= 50 for c in chunks)


def test_text_is_preserved_exactly():
    paras = ['He said "Go." Then: she left; they ran, fast — very fast! Done?']
    chunks = chunk_section(0, paras, cap=25, first_is_heading=False)
    assert " ".join(c.text for c in chunks) == paras[0]


def test_min_chars_merges_tiny_tail():
    para = "This is a reasonably long first sentence that fills the chunk. Ok."
    chunks = chunk_section(0, [para], cap=64, first_is_heading=False, min_chars=10)
    assert len(chunks) == 1 or chunks[-1].chars >= 10


def test_display_title():
    from audiobook_engine.pipeline import display_title

    assert display_title("CHAPTER II.") == "Chapter II."
    assert display_title("Chapter I.") == "Chapter I."
    assert display_title("XII") == "XII"
    assert display_title("THE FULL STORY") == "The Full Story"


# ----------------------------------------------------------------------------- regression tests (review findings)


@pytest.mark.parametrize("text", [
    "J.K. Rowling wrote it.",
    "The U.S. Army landed.",
    "J.R.R. Tolkien wrote it.",
    "At five p.m. Smith left.",
    "Gov. Smith and Fr. Brown came.",
    "Mr. Fogg partit.",
])
def test_initials_and_abbreviations_do_not_end_a_sentence(text):
    assert split_sentences(text) == [text]


def test_closing_quote_after_an_abbreviation_still_ends_the_sentence():
    assert split_sentences('He works for the "U.S." Then he left.') == ['He works for the "U.S."', "Then he left."]


def test_initials_never_end_a_chunk():
    para = "First sentence here. In the spring the U.S. Army landed."
    cap = len("First sentence here. In the spring the U.S.")
    chunks = chunk_section(0, [para], cap=cap, first_is_heading=False)
    assert [c.text for c in chunks] == ["First sentence here.", "In the spring the U.S. Army landed."]


@pytest.mark.parametrize("text, want", [
    ("« Bonjour. » Puis il partit.", ["« Bonjour. »", "Puis il partit."]),
    ("Il dit : « Viens ! » Elle vint.", ["Il dit : « Viens ! »", "Elle vint."]),
    ("« Où allez-vous ? » demanda-t-elle.", ["« Où allez-vous ? » demanda-t-elle."]),
])
def test_french_spaced_closing_guillemets_end_a_sentence(text, want):
    assert split_sentences(text) == want


def test_punctuation_only_chunks_are_dropped():
    paras = ["Chapter one.", "»", "Il partit. »", "* * *", "— …", "Fin."]
    chunks = chunk_section(0, paras, cap=100)
    assert [c.text for c in chunks] == ["Chapter one.", "Il partit. »", "Fin."]
    assert [c.paragraph for c in chunks] == [0, 2, 5]
    assert all(c.paragraph_end for c in chunks)
    assert [c.index for c in chunks] == [0, 1, 2]
    assert chunk_section(0, ["»"], cap=100, first_is_heading=False) == []


def test_punctuation_only_tail_of_a_paragraph_is_dropped_and_flags_move():
    # a word-level split leaves a lone "»" as the last piece; the previous chunk ends the paragraph
    para = "aaaa bbbb cccc dddd »"
    chunks = chunk_section(0, [para], cap=19, first_is_heading=False)
    assert [c.text for c in chunks] == ["aaaa bbbb cccc dddd"]
    assert chunks[-1].paragraph_end


# ----------------------------------------------------------------------------- regression tests (round 2)


@pytest.mark.parametrize("text, want", [
    ("He moved to the U.S. The weather was better.", ["He moved to the U.S.", "The weather was better."]),
    ("Born in the U.K. His father was Scottish.", ["Born in the U.K.", "His father was Scottish."]),
    ("We left at ten thirty p.m. The house was quiet.", ["We left at ten thirty p.m.", "The house was quiet."]),
    ("The U.S. Army landed.", ["The U.S. Army landed."]),
    ("J.K. Rowling wrote it.", ["J.K. Rowling wrote it."]),
    ("Il vit J.M. Le Clézio.", ["Il vit J.M. Le Clézio."]),
])
def test_a_sentence_starter_after_a_dotted_abbreviation_starts_a_sentence(text, want):
    assert split_sentences(text) == want


def test_hyphenated_french_initials_do_not_end_a_sentence():
    assert split_sentences("J.-M. Le Pen parla. Il partit.") == ["J.-M. Le Pen parla.", "Il partit."]


def test_split_sentences_is_linear_in_the_number_of_abbreviations():
    import time

    text = " ".join(["A."] * 20000) + " Z."
    t = time.perf_counter()
    assert split_sentences(text) == [text]
    assert time.perf_counter() - t < 0.5
