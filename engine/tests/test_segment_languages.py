"""Segmentation of the languages beyond English and French: sentence ends of other scripts (no space needed after
。 । ؟), Spanish inverted marks, Russian and German quotes, per-language abbreviations, chunk packing under a
character cap with a grapheme-safe hard split. The GOLDEN_* tables pin the English/French behaviour as it was
before these languages were added."""

from __future__ import annotations

import random
import re
import time
import unicodedata

import pytest

from audiobook_engine.textproc.segment import _hard_split, _is_boundary, chunk_section, split_sentences

NEW = ["es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"]


def squash(text: str) -> str:
    return re.sub(r"\s+", "", text)


# ----------------------------------------------------------------------------- sentences


@pytest.mark.parametrize("lang, text, want", [
    ("zh", "你好。我很好！你呢？我也是；再见……好吧。他说：「你好。」然后离开了。",
     ["你好。", "我很好！", "你呢？", "我也是；", "再见……", "好吧。", "他说：「你好。」", "然后离开了。"]),
    ("ja", "今日は晴れです。明日は雨でしょう！本当ですか？はい。",
     ["今日は晴れです。", "明日は雨でしょう！", "本当ですか？", "はい。"]),
    ("ar", "هل أنت هنا؟ نعم، أنا هنا. ما اسمك؟ اسمي علي۔ حسنا",
     ["هل أنت هنا؟", "نعم، أنا هنا.", "ما اسمك؟", "اسمي علي۔", "حسنا"]),
    ("ar", "هل أنت هنا؟نعم.", ["هل أنت هنا؟", "نعم."]),
    ("hi", "वह घर गया। फिर वह लौटा॥ उसने पूछा, \"क्या हुआ?\" कुछ नहीं।अगला वाक्य",
     ["वह घर गया।", "फिर वह लौटा॥", "उसने पूछा, \"क्या हुआ?\"", "कुछ नहीं।", "अगला वाक्य"]),
    ("es", "¿Qué quieres? ¡Nada! Dijo el Sr. García. Luego se fue. ¿Y tú? Sí.",
     ["¿Qué quieres?", "¡Nada!", "Dijo el Sr. García.", "Luego se fue.", "¿Y tú?", "Sí."]),
    ("es", "Dijo: ¿qué quieres? Y nada más. Fin.", ["Dijo: ¿qué quieres?", "Y nada más.", "Fin."]),
    ("ru", "— Привет! — сказал он. — Как дела? Он ушёл. «Хорошо». Потом И. И. Иванов пришёл. Это т.е. всё. Он вернулся.",
     ["— Привет! — сказал он.", "— Как дела?", "Он ушёл.", "«Хорошо».", "Потом И. И. Иванов пришёл.",
      "Это т.е. всё.", "Он вернулся."]),
    ("de", 'Er sagte: "Hallo." Sie ging. Dr. Müller kam z. B. früh. Dann ging er.',
     ['Er sagte: "Hallo."', "Sie ging.", "Dr. Müller kam z. B. früh.", "Dann ging er."]),
    ("de", "Er sagte: „Hallo.“ Sie ging. Es war d. h. spät.", ["Er sagte: „Hallo.“", "Sie ging.", "Es war d. h. spät."]),
    ("it", "Il Sig. Rossi parlò. Poi uscì. Cap. 5 è lungo.", ["Il Sig. Rossi parlò.", "Poi uscì.", "Cap. 5 è lungo."]),
    ("nl", "Dhr. Jansen kwam. Hij ging weg. Het was o.a. leuk. Daarna niets.",
     ["Dhr. Jansen kwam.", "Hij ging weg.", "Het was o.a. leuk.", "Daarna niets."]),
    ("pt", "O Sr. Silva chegou. Ela saiu. Depois partiu.", ["O Sr. Silva chegou.", "Ela saiu.", "Depois partiu."]),
    ("ko", "그는 집에 갔다. 그리고 돌아왔다! 정말입니까? 네.", ["그는 집에 갔다.", "그리고 돌아왔다!", "정말입니까?", "네."]),
])
def test_sentences(lang, text, want):
    assert split_sentences(text, lang) == want


def test_without_a_language_the_script_is_recognised():
    assert split_sentences("你好。我很好！") == ["你好。", "我很好！"]
    assert split_sentences("Привет. Как дела? Хорошо.") == ["Привет.", "Как дела?", "Хорошо."]
    assert split_sentences("¿Qué? ¡Nada! Bien.") == ["¿Qué?", "¡Nada!", "Bien."]
    assert split_sentences("वह गया। वह आया।") == ["वह गया।", "वह आया।"]


def test_a_terminator_without_a_space_still_ends_the_sentence_in_cjk_and_indic_scripts():
    assert split_sentences("一。二！三？四；五", "zh") == ["一。", "二！", "三？", "四；", "五"]
    assert split_sentences("a。b", "ja") == ["a。", "b"]
    assert split_sentences("क।ख॥ग", "hi") == ["क।", "ख॥", "ग"]
    # closing quotes and brackets stay with their sentence
    assert split_sentences("他说「走吧。」我们走了。", "zh") == ["他说「走吧。」", "我们走了。"]
    assert split_sentences("（真的吗？）他问。", "zh") == ["（真的吗？）", "他问。"]
    # an ellipsis between Chinese characters ends the sentence, in either spelling
    assert split_sentences("好吧...我走了", "zh") == ["好吧...", "我走了"]
    assert split_sentences("好吧……我走了", "zh") == ["好吧……", "我走了"]


def test_latin_text_with_an_ordinary_period_is_not_split_without_a_space():
    assert split_sentences("Version 3.5 of www.example.com is out.", "es") == ["Version 3.5 of www.example.com is out."]
    assert split_sentences("U.S.A. Cap. 5", "es") == ["U.S.A. Cap. 5"]


@pytest.mark.parametrize("lang, text", [
    ("de", "Das ist z. B. so. Es geht d. h. weiter."), ("nl", "Zie o.a. blz. 5 en t.o.v. hem. Klaar."),
    ("it", "Il Dott. Verdi e l'Avv. Neri arrivarono. Poi partirono."), ("es", "El Dr. Pérez y la Dra. Gómez llegaron. Se fueron."),
    ("pt", "O Dr. Silva e a Dra. Costa chegaram. Foram embora."), ("ru", "Т.е. так и было. И. И. Иванов ушёл."),
])
def test_abbreviations_do_not_end_a_sentence(lang, text):
    parts = split_sentences(text, lang)
    assert len(parts) == 2, parts
    assert parts[1][0].isupper()


def test_a_starter_after_a_dotted_abbreviation_starts_a_sentence():
    assert split_sentences("Vive en los EE.UU. Allí trabaja.", "es") == ["Vive en los EE.UU.", "Allí trabaja."]
    assert split_sentences("Он жил в г. Москве. Он умер.", "ru") == ["Он жил в г. Москве.", "Он умер."]


def test_sentence_splitting_is_linear_in_the_number_of_abbreviations():
    for lang, unit in (("ru", "И."), ("de", "z. B."), ("zh", "。")):
        text = " ".join([unit] * 20000) + " Z."
        t = time.perf_counter()
        split_sentences(text, lang)
        assert time.perf_counter() - t < 2, lang


# ----------------------------------------------------------------------------- hard split and graphemes


def test_hard_split_keeps_clusters_whole():
    family = "👨\u200d👩\u200d👧\u200d👦"
    assert _hard_split(family * 5, 10) == [family] * 5
    assert _hard_split("🇫🇷🇩🇪🇪🇸", 3) == ["🇫🇷", "🇩🇪", "🇪🇸"]
    assert _hard_split("é" * 10, 5) == ["éé"] * 5
    thumbs = "👍🏽"
    assert all(len(p) % 2 == 0 for p in _hard_split(thumbs * 9, 5))
    nfd = unicodedata.normalize("NFD", "한국어" * 2)
    pieces = _hard_split(nfd, 4)
    assert [unicodedata.normalize("NFC", p) for p in pieces] == list("한국어한국어")
    assert _hard_split("あいうえお。", 5) == ["あいうえ", "お。"]


def test_hard_split_keeps_devanagari_conjuncts_whole():
    word = "क्षत्रिय"
    pieces = _hard_split(word * 30, 7)
    assert "".join(pieces) == word * 30
    for piece in pieces:
        assert len(piece) <= 7
        assert not unicodedata.category(piece[0]).startswith("M") and piece[0] not in "\u200c\u200d"
        assert unicodedata.combining(piece[-1]) != 9  # never ends on a virama
    # a ZWJ/ZWNJ sequence is not cut either
    text = "क्\u200dष" * 12
    for piece in _hard_split(text, 5):
        assert not piece.startswith(("\u200d", "\u200c")) and not piece.endswith("\u200d")


def test_hard_split_prefers_spaces_and_punctuation_and_never_exceeds_the_cap():
    assert _hard_split("abcdefghij klmnopqrst", 12) == ["abcdefghij", "klmnopqrst"]
    assert _hard_split("a" * 25, 10) == ["a" * 10, "a" * 10, "a" * 5]
    assert _hard_split("你好，世界你好世界", 5) == ["你好，", "世界你好世", "界"]
    for cap in (1, 2, 3, 7):
        text = "ab́c" * 20 + "。"
        assert all(len(p) <= cap for p in _hard_split(text, cap) if cap >= 3) or cap < 3


def test_is_boundary_basics():
    assert _is_boundary("ab", 1) and _is_boundary("ab", 0) and _is_boundary("ab", 2)
    assert not _is_boundary("é", 1)
    assert not _is_boundary("क्ष", 2)
    assert not _is_boundary("a\u200db", 1) and not _is_boundary("a\u200db", 2)


# ----------------------------------------------------------------------------- chunks


def test_chinese_without_spaces_is_cut_at_clause_marks_then_at_the_cap():
    text = "这是一个很长的句子，没有任何空格，" * 15 + "最后一句话。"
    chunks = chunk_section(0, [text], cap=40, first_is_heading=False, lang="zh")
    assert all(c.chars <= 40 for c in chunks)
    assert "".join(c.text for c in chunks) == text
    assert all(c.text.endswith(("，", "。")) for c in chunks)  # clause marks are used before any hard cut
    unbroken = "漢字" * 100
    chunks = chunk_section(0, [unbroken], cap=33, first_is_heading=False, lang="ja")
    assert [c.chars for c in chunks] == [33] * 6 + [2]
    assert "".join(c.text for c in chunks) == unbroken


def test_sentences_are_packed_without_spaces_between_chinese_sentences():
    chunks = chunk_section(0, ["你好。我很好！你呢？"], cap=100, first_is_heading=False, lang="zh")
    assert [c.text for c in chunks] == ["你好。我很好！你呢？"]
    chunks = chunk_section(0, ["Hello. 你好。"], cap=100, first_is_heading=False, lang="zh")
    assert [c.text for c in chunks] == ["Hello.你好。"]  # no space is written next to Chinese text


def test_chunks_for_other_languages_never_exceed_the_cap_even_with_min_chars():
    para = "Это первое предложение. Это второе! Да? Нет."
    chunks = chunk_section(0, [para], cap=30, first_is_heading=False, min_chars=25, lang="ru")
    assert all(c.chars <= 30 for c in chunks)
    assert squash("".join(c.text for c in chunks)) == squash(para)


def test_a_chunk_never_ends_a_paragraph_with_only_punctuation():
    chunks = chunk_section(0, ["あいうえお。"], cap=5, first_is_heading=False, lang="ja")
    assert [c.text for c in chunks] == ["あいうえ", "お。"]
    assert chunks[-1].paragraph_end and not chunks[0].paragraph_end


_BANK = {
    "es": (" ", "El gato negro duerme sobre la mesa grande y nadie lo molesta hoy tarde".split(), ".!?"),
    "de": (" ", "Der große Hund läuft schnell durch den dunklen Wald und niemand sieht ihn".split(), ".!?"),
    "it": (" ", "Il piccolo gatto dorme sul tavolo grande e nessuno lo disturba oggi".split(), ".!?"),
    "pt": (" ", "O gato preto dorme sobre a mesa grande e ninguém o incomoda hoje".split(), ".!?"),
    "nl": (" ", "De grote hond rent snel door het donkere bos en niemand ziet hem".split(), ".!?"),
    "ru": (" ", "Большой чёрный кот спит на столе и никто его не беспокоит сегодня".split(), ".!?"),
    "zh": ("", "我们今天去公园玩得很开心天气很好他说你好吗我想回家".split("的"), "。！？；"),
    "ja": ("", "今日は公園へ行って楽しく遊びましたがとても疲れました".split("が"), "。！？"),
    "ko": (" ", "그는 오늘 공원에 가서 즐겁게 놀았고 아주 피곤했습니다".split(), ".!?"),
    "hi": (" ", "वह आज पार्क गया और बहुत खुश था क्योंकि मौसम अच्छा था".split(), "।॥"),
    "ar": (" ", "ذهب الولد إلى الحديقة اليوم وكان سعيدا جدا لأن الطقس جميل".split(), ".؟۔"),
}


def _random_paragraph(lang: str, rnd: random.Random) -> str:
    joiner, words, ends = _BANK[lang]
    sentences = []
    for _ in range(rnd.randint(1, 8)):
        body = joiner.join(rnd.choice(words) for _ in range(rnd.randint(1, 30)))
        comma = "，" if lang in ("zh", "ja") else "،" if lang == "ar" else ","
        if rnd.random() < 0.5 and len(body) > 6:
            k = rnd.randint(1, len(body) - 1)
            body = body[:k] + comma + body[k:] if joiner == "" else body
        sentences.append(body + rnd.choice(ends))
    return (joiner or "").join(sentences) if joiner == "" else " ".join(sentences)


@pytest.mark.parametrize("lang", NEW)
def test_chunk_properties(lang):
    rnd = random.Random(sum(map(ord, lang)) * 7)
    for _ in range(120):
        paras = [_random_paragraph(lang, rnd) for _ in range(rnd.randint(1, 3))]
        cap = rnd.choice([6, 10, 20, 45, 120])
        min_chars = rnd.choice([0, 8])
        chunks = chunk_section(4, paras, cap, first_is_heading=False, min_chars=min_chars, lang=lang)
        assert chunks
        assert [c.index for c in chunks] == list(range(len(chunks)))
        for c in chunks:
            assert c.text and c.text == c.text.strip()
            assert c.chars <= cap, (lang, cap, c.text)  # never exceeds the cap
            assert re.search(r"[^\W_]", c.text)  # something to say
        for p_i, para in enumerate(paras):
            mine = [c for c in chunks if c.paragraph == p_i]
            assert squash("".join(c.text for c in mine)) == squash(para), (lang, cap, para)
            assert mine[-1].paragraph_end and not any(c.paragraph_end for c in mine[:-1])
        # no chunk starts inside a cluster or ends in the middle of one
        for c in chunks:
            assert not unicodedata.category(c.text[0]).startswith("M") and c.text[0] not in "\u200c\u200d"
            assert c.text[-1] != "\u200d" and unicodedata.combining(c.text[-1]) != 9


def test_chunk_properties_with_marks_and_conjuncts():
    rnd = random.Random(5)
    atoms = ["क्ष", "त्र", "ज्ञ", "श्री", "प्र", "é", "ạ̀", "한", "国", "👍🏽", "🇫🇷", "का", "कं", " ", ",", "。", "।"]
    for _ in range(300):
        text = "".join(rnd.choice(atoms) for _ in range(rnd.randint(1, 80))) + "x"
        cap = rnd.choice([6, 9, 30])  # a cluster longer than the cap cannot be kept whole
        for lang in ("hi", "zh", "ko", None):
            for c in chunk_section(0, [text], cap, first_is_heading=False, lang=lang):
                assert c.chars <= cap, (text, cap, c.text)
                assert not unicodedata.category(c.text[0]).startswith("M"), (text, cap, c.text)
                assert c.text[-1] != "\u200d" and unicodedata.combining(c.text[-1]) != 9, (text, cap, c.text)


def test_oversized_words_are_cut_only_for_other_languages():
    word = "a" * 50
    legacy = chunk_section(0, [word], cap=20, first_is_heading=False)
    assert [c.chars for c in legacy] == [50]  # English/French keep their behaviour: a long word is left whole
    other = chunk_section(0, [word], cap=20, first_is_heading=False, lang="de")
    assert [c.chars for c in other] == [20, 20, 10]


# ----------------------------------------------------------------------------- English and French unchanged


GOLDEN_SEG = [('He left. "Where?" she asked! It was late... Then J. K. Rowling arrived.',
  ['He left.', '"Where?" she asked!', 'It was late...', 'Then J. K. Rowling arrived.']),
 ('Il partit. « Où allez-vous ? » demanda-t-elle. — Nulle part.',
  ['Il partit.', '« Où allez-vous ? » demanda-t-elle.', '— Nulle part.']),
 ('The U.S. Army landed. He moved to the U.S. The weather was better.',
  ['The U.S. Army landed.', 'He moved to the U.S.', 'The weather was better.']),
 ('J.-M. Le Pen parla. Il partit. M. Fogg arriva. Mr. Fogg sat. At five p.m. Smith left.',
  ['J.-M. Le Pen parla.', 'Il partit.', 'M. Fogg arriva.', 'Mr. Fogg sat.', 'At five p.m. Smith left.']),
 ('« Bonjour. » Puis il partit. Il dit : « Viens ! » Elle vint.',
  ['« Bonjour. »', 'Puis il partit.', 'Il dit : « Viens ! »', 'Elle vint.']),
 ('A first clause, and a second; a third: and then — a dash. The end.',
  ['A first clause, and a second; a third: and then — a dash.', 'The end.'])]

GOLDEN_CHUNK = [(['Chapter one.',
   'A short sentence. A short sentence. A short sentence. A short sentence. A short sentence. A short sentence. A '
   'short sentence. A short sentence. A short sentence. A short sentence. A short sentence. A short sentence. ',
   'Another paragraph here, with a clause; and more.'],
  60,
  0,
  [('Chapter one.', 0, 0, True, True),
   ('A short sentence. A short sentence. A short sentence.', 1, 1, False, False),
   ('A short sentence. A short sentence. A short sentence.', 1, 2, False, False),
   ('A short sentence. A short sentence. A short sentence.', 1, 3, False, False),
   ('A short sentence. A short sentence. A short sentence.', 1, 4, True, False),
   ('Another paragraph here, with a clause; and more.', 2, 5, True, False)]),
 (['Il était une fois, dans un pays lointain, un roi qui avait trois fils ; le plus jeune était le plus sage. Fin.'],
  50,
  10,
  [('Il était une fois, dans un pays lointain,', 0, 0, False, True),
   ('un roi qui avait trois fils ;', 0, 1, False, True),
   ('le plus jeune était le plus sage. Fin.', 0, 2, True, True)]),
 (['word word word word word word word word word word word word word word word word word word word word word word word '
   'word word word word word word word word word word word word word word word word word ',
   'J. K. Rowling wrote it. The U.S. Army landed. Fin.'],
  30,
  0,
  [('word word word word word word', 0, 0, False, True),
   ('word word word word word word', 0, 1, False, True),
   ('word word word word word word', 0, 2, False, True),
   ('word word word word word word', 0, 3, False, True),
   ('word word word word word word', 0, 4, False, True),
   ('word word word word word word', 0, 5, False, True),
   ('word word word word', 0, 6, True, True),
   ('J. K. Rowling wrote it.', 1, 7, False, False),
   ('The U.S. Army landed. Fin.', 1, 8, True, False)]),
 (['First sentence here. In the spring the U.S. Army landed.', '»', '* * *', 'Fin.'],
  44,
  5,
  [('First sentence here.', 0, 0, False, True),
   ('In the spring the U.S. Army landed.', 0, 1, True, True),
   ('Fin.', 3, 2, True, False)])]



@pytest.mark.parametrize("text, want", GOLDEN_SEG)
def test_english_and_french_sentences_are_unchanged(text, want):
    assert split_sentences(text) == want
    assert split_sentences(text, "en") == want
    assert split_sentences(text, "fr") == want


@pytest.mark.parametrize("paras, cap, min_chars, want", GOLDEN_CHUNK)
def test_english_and_french_chunks_are_unchanged(paras, cap, min_chars, want):
    for lang in (None, "en", "fr"):
        chunks = chunk_section(2, paras, cap, first_is_heading=True, min_chars=min_chars, lang=lang)
        assert [(c.text, c.paragraph, c.index, c.paragraph_end, c.is_heading) for c in chunks] == want


@pytest.mark.parametrize("lang", ["en-US", "EN", "fr-CA", "xx", None])
def test_english_french_and_unknown_codes_keep_the_original_splitter(lang):
    text = "Mr. Fogg sat. J. K. Rowling wrote it. The U.S. Army landed."
    assert split_sentences(text, lang) == ["Mr. Fogg sat.", "J. K. Rowling wrote it.", "The U.S. Army landed."]
    word = "a" * 50
    assert [c.chars for c in chunk_section(0, [word], cap=20, first_is_heading=False, lang=lang)] == [50]
