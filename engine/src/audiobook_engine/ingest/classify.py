"""Heuristics shared by EPUB and PDF ingest: front/back matter and language.

Everything here is a heuristic. The app shows the result and lets the user
re-tick any section, so a wrong guess costs a click, not a ruined audiobook.
"""

from __future__ import annotations

import re
import unicodedata
from collections import Counter
from collections.abc import Iterable

from .. import languages
from ..models import Section
from . import vocab

# epub:type / role values (EPUB 3 Structural Semantics, DPUB-ARIA).
FRONT_TYPES = {
    "cover", "titlepage", "halftitlepage", "copyright-page", "toc", "dedication",
    "frontispiece", "imprint", "colophon", "landmarks", "loi", "lot", "seriespage",
    "doc-toc", "doc-dedication", "doc-colophon", "doc-cover",
}
BACK_TYPES = {
    "index", "endnotes", "rearnotes", "footnotes", "bibliography", "glossary",
    "acknowledgments", "contributors", "other-credits", "errata", "appendix-index",
    "doc-index", "doc-endnotes", "doc-bibliography", "doc-glossary",
    "doc-acknowledgments",
}

# Titles are matched after typographic apostrophes are folded to "'".
_APOSTROPHES = str.maketrans({"’": "'", "ʼ": "'", "‘": "'", "´": "'"})

_FRONT_TITLE = re.compile(
    r"^\s*(cover|couverture|title page|page de titre|half title|copyright|"
    r"mentions l[ée]gales|table of contents|contents|table des mati[èe]res|sommaire|"
    r"d[ée]dicace|dedication|also by|du m[êe]me auteur|by the same author|"
    r"praise for .*|colophon|imprint|achev[ée] d'imprimer|list of (illustrations|figures|tables))"
    r"\s*[\W\d]*$",
    re.IGNORECASE,
)
_BACK_TITLE = re.compile(
    r"^\s*(index|notes|endnotes|footnotes|bibliograph(y|ie)|glossa(ry|ire)|"
    r"acknowledge?ments|remerciements|about the author|[àa] propos de l'auteur|"
    r"l'auteur|about the publisher|credits|cr[ée]dits|further reading|"
    r"the full project gutenberg license)"
    r"\s*[\W\d]*$",
    re.IGNORECASE,
)
_COPYRIGHT_TEXT = re.compile(
    r"(©|\(c\)\s*\d{4}|all rights reserved|tous droits r[ée]serv[ée]s|\bISBN\b|"
    + "|".join(re.escape(p) for p in vocab.COPYRIGHT_PHRASES) + ")",
    re.IGNORECASE,
)
# A printed contents page: the heading, optionally followed by its entries (but not prose).
_CONTENTS_HEAD = re.compile(
    r"^\s*(?i:table of contents|contents|table des mati[èe]res|sommaire)\b(?!\s+[a-zà-ÿ])"
)
_GUTENBERG = re.compile(r"project gutenberg", re.IGNORECASE)


def classify_section(
    section: Section, epub_types: set[str] | None = None, heading_ratio: float = 0.0
) -> None:
    """Set section.kind/include/reasons in place.

    heading_ratio is the share of the section's paragraphs that are headings;
    a printed table of contents is mostly headings.
    """
    reasons: list[str] = []
    kind = "chapter"
    types = {t.lower() for t in (epub_types or set())}
    title = section.title.translate(_APOSTROPHES)

    if types & FRONT_TYPES:
        kind = "front"
        reasons.append(f"marked as {sorted(types & FRONT_TYPES)[0]} in the EPUB")
    elif types & BACK_TYPES:
        kind = "back"
        reasons.append(f"marked as {sorted(types & BACK_TYPES)[0]} in the EPUB")
    elif _FRONT_TITLE.search(title):
        kind = "front"
        reasons.append("title looks like front matter")
    elif _BACK_TITLE.search(title):
        kind = "back"
        reasons.append("title looks like back matter")
    elif (role := vocab.matter_role(title)) is not None:
        kind = role[0]
        reasons.append(f"title looks like {'front' if kind == 'front' else 'back'} matter ({role[1].replace('_', ' ')})")
    elif heading_ratio >= 0.7 and len(section.paragraphs) >= 5:
        kind = "front"
        reasons.append("mostly headings: looks like a printed table of contents")
    else:
        text = " ".join(section.paragraphs[:40])
        if section.chars < 3000 and _COPYRIGHT_TEXT.search(text):
            kind = "front"
            reasons.append("short section with copyright notice")
        elif _GUTENBERG.search(text) and (
            "license" in text.lower() or "www.gutenberg.org" in text.lower()
        ):
            kind = "back" if section.index > 0 else "front"
            reasons.append("Project Gutenberg boilerplate")

    if section.chars == 0:
        reasons.append("no readable text")
        kind = "front" if kind == "chapter" and section.index == 0 else kind

    section.kind = kind  # type: ignore[assignment]
    section.include = kind == "chapter" and section.chars > 0
    section.reasons = reasons


def matter_title(title: str) -> str | None:
    """'front' or 'back' when a title names front or back matter ("Dedication", "Notes"), else None."""
    title = (title or "").translate(_APOSTROPHES)
    if _FRONT_TITLE.search(title):
        return "front"
    if _BACK_TITLE.search(title):
        return "back"
    role = vocab.matter_role(title)
    return role[0] if role else None


def notes_title(title: str) -> bool:
    """A whole heading that names a page of notes in any supported language ("Notes", "Anmerkungen", "注釈")."""
    return bool(vocab.is_role_title(title, "notes"))


def front_matter_signals(paragraphs: list[str]) -> list[str]:
    """Reasons a block of opening pages looks like front matter, whatever its length."""
    signals: list[str] = []
    if _COPYRIGHT_TEXT.search(" ".join(paragraphs)):
        signals.append("copyright notice")
    if any(_CONTENTS_HEAD.match(p) or vocab.contents_heading(p) for p in paragraphs):
        signals.append("printed table of contents")
    return signals


# --------------------------------------------------------------------------- headings

# A class on a <p>/<div> that marks it as a heading: "chapter-title", "heading",
# "chapter", "chapnum"... but not "chapter-text" or "chapterFirstPara".
_TITLE_CLASS = re.compile(
    r"title|heading|(?:^|[-_])chap(?:ter)?(?:[-_]?(?:head|num(?:ber)?|no|label|name))?\d*$"
)
# ...nor the title of something else inside the chapter: "epigraph-title", "fig-title",
# "box-heading", "chapter-subtitle", "poem-title"...
_OTHER_TITLE_CLASS = re.compile(
    r"epigraph|fig|table|tbl|box|sidebar|caption|quot|illus|image|img|photo|poem|verse|attrib|cite|source"
    r"|note|author|byline|signature|dedication|sub-?(?:title|head)"
)
_LABEL_WORDS = {
    "chapter", "chapitre", "ch", "part", "partie", "book", "livre", "section", "volume", "tome",
    "prologue", "epilogue", "épilogue", "interlude", "appendix", "annexe", "act", "acte", "scene", "scène",
} | vocab.LABEL_WORDS
# Digits or a well-formed roman numeral ("xiv", not "lid" or "dim").
_NUMBER_TOKEN = re.compile(r"\d{1,4}|(?=[ivxlcdm])m{0,3}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})")
_NUMBER_WORDS = {
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
    "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    "eleventh", "twelfth",
    "un", "une", "deux", "trois", "quatre", "cinq", "sept", "huit", "neuf", "dix", "onze", "douze",
    "treize", "quatorze", "quinze", "seize", "vingt", "trente", "quarante", "cinquante", "soixante", "cent",
    "premier", "première", "deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième",
    "huitième", "neuvième", "dixième", "seconde",
}
# A paragraph that ends a sentence ("The Letter arrived on Tuesday.") or opens with a quote.
# (。！？ end Chinese/Japanese sentences, ؟ Arabic questions, । Hindi sentences.)
_SENTENCE_END = re.compile(r"[.!?…。！？｡।؟۔][\"'”’»)\]」』）]*\s*$")
_OPENING_QUOTE = re.compile(r"^\s*[\"“‘«„—–「『（-]")
# A heading number set off by a full stop or colon: "I. THE BEGINNING.", "1. The Beginning."
# (Chinese headings also number with "一、概述".)
_NUMBER_PREFIX = re.compile(r"\s*(?:\d{1,4}|[IVXLCDM]+)[.:]\s|\s*[一二三四五六七八九十百]+[、．]\s*\S")
# Any capitalised word with a number, set off the same way: "Lesson 3: Fractions", "Day 1: Arrival".
_WORD_NUMBER_PREFIX = re.compile(r"\s*(?=[A-ZÀ-ÖØ-ÞА-ЯЁ])[^\W\d_]+\s+(?:\d{1,4}|[IVXLCDM]+)[.:]\s")


def _fold(text: str) -> str:
    # Words, keeping combining marks (Devanagari vowel signs, Arabic vowels) and dropping the invisible
    # bidirectional marks right-to-left text carries; for Latin text this is exactly \w+.
    words: list[str] = []
    cur: list[str] = []
    for ch in text.casefold():
        if ch.isalnum() or ch == "_" or unicodedata.category(ch)[0] == "M":
            cur.append(ch)
        elif unicodedata.category(ch) == "Cf":
            continue
        elif cur:
            words.append("".join(cur))
            cur = []
    if cur:
        words.append("".join(cur))
    return " ".join(words)


def _label_or_number(word: str) -> bool:
    return (
        word in _LABEL_WORDS or word in _NUMBER_WORDS or bool(_NUMBER_TOKEN.fullmatch(word))
        or word in vocab.NUMBER_WORDS or vocab.is_number_word(word) or vocab.label_only(word)  # "第三章"
    )


def _labels_and_numbers(words: list[str]) -> bool:
    """Every word is a label or a number; "dos"/"once" count only right after a label ("Capítulo dos")."""
    for i, w in enumerate(words):
        if _label_or_number(w):
            continue
        if i > 0 and w in vocab.AFTER_LABEL_NUMBERS and words[i - 1] in _LABEL_WORDS:
            continue
        return False
    return True


def _is_label_title(folded: str, raw: str = "") -> bool:
    """'chapter 1', 'part two', 'chapitre premier', '第三章': a label word followed by a number."""
    words = folded.split()
    if len(words) >= 2 and words[0] in _LABEL_WORDS and _labels_and_numbers(words[1:]):
        return True
    return bool(raw) and vocab.label_only(raw)


def _title_then_subtitle(text: str, title: str) -> bool:
    """The block opens with the title set off by a colon ("The Beginning: In Which Our Hero
    Is Born"), or by a full stop when the title ends with a number ("LETTER IV. To Mrs.
    Saville, England." for "Letter IV"); not "Rain. It had rained for days." for "Rain"."""
    words = re.findall(r"\w+", title)
    if not words:
        return False
    m = re.match(r"\W*" + r"\W+".join(map(re.escape, words)) + r"\s*([:.])\s", text, re.IGNORECASE)
    return bool(m) and (m.group(1) == ":" or bool(_NUMBER_TOKEN.fullmatch(words[-1].casefold())))


def looks_like_title(text: str, titles: Iterable[str], css_class: str = "") -> bool:
    """True when a block that is not <h1>-<h6> is nonetheless the section's own heading.

    Used so the narrator does not speak the title twice ("Chapter One. CHAPTER
    ONE."). A block counts when it carries a chapter title/heading class, or
    when it is the title, part of the title ("CHAPTER ONE" for "Chapter One:
    The Beginning"), the title after a label ("Chapter 1: Origins" for
    "Origins", "I. THE BEGINNING." or "Lesson 3: Fractions" for the name), a
    label title followed by its name ("Chapter 1: The Beginning" for "Chapter
    1"), or the title set off from a subtitle ("The Beginning: In Which Our
    Hero Is Born"). An ordinary first sentence that happens to
    start or end with the title ("The Letter arrived on Tuesday.", "He walked
    toward the sea.") is not a heading, and long blocks never are.
    """
    if not text or len(text) > 150:
        return False
    block = _fold(text)
    if not block:
        return False
    if any(_TITLE_CLASS.search(tok) and not _OTHER_TITLE_CLASS.search(tok) for tok in css_class.lower().split()):
        return True
    sentence = bool(_SENTENCE_END.search(text)) or bool(_OPENING_QUOTE.match(text))
    for title in titles:
        t = _fold(title or "")
        if not t:
            continue
        if block == t:
            return True
        if len(block) < len(t):
            short_ok = (
                len(block) >= 4 or _NUMBER_TOKEN.fullmatch(block) or vocab.label_only(text)
                or (len(block) >= 2 and vocab.CJK_RE.search(block))  # "夜の海": three characters are a word
            )
            if short_ok and (t.startswith(block + " ") or t.endswith(" " + block)):
                return True
            continue
        if block.endswith(" " + t):
            # only labels and numbers before the title: "Chapter 1: Origins", "Part II The Return",
            # "I. THE BEGINNING." (but "I dream." or "First night." is a sentence, not "Dream" or
            # "Night" with a number)
            extra = block[: -len(t) - 1].split()
            labelled = any(w in _LABEL_WORDS for w in extra)
            numbered = bool(_NUMBER_PREFIX.match(text))
            if len(extra) <= 4 and _labels_and_numbers(extra) and (labelled or numbered or not sentence):
                return True
            if len(extra) == 2 and _NUMBER_TOKEN.fullmatch(extra[1]) and _WORD_NUMBER_PREFIX.match(text):
                return True  # "Lesson 3: Fractions", "Day 1: Arrival"
        if block.startswith(t + " "):
            extra = block[len(t) + 1:].split()
            if _is_label_title(t, title or ""):
                # a label title followed by its name: "Chapter 1: The Beginning" for "Chapter 1"
                if len(extra) <= 6 and not (sentence and len(extra) > 3):
                    return True
            elif len(extra) <= 6 and _title_then_subtitle(text, title):
                return True
    return False


# --------------------------------------------------------------------------- language

# Frequent function words per Latin-script language. A word that several languages share counts for each of
# them, so a language wins only on its own words ("el", "und", "het"); the lists lean on words that exist in
# one language. English and French keep their original words; the others are there so that German, Dutch,
# Spanish, Italian or Portuguese text is not taken for English or French.
_STOP_WORDS: dict[str, frozenset[str]] = {
    "en": frozenset({"the", "and", "of", "to", "is", "that", "in", "it", "was", "with", "he", "she", "his",
                     "her", "you", "for",
                     "they", "but", "not", "this", "have", "were", "from", "which", "would", "there", "what",
                     "been", "are", "by", "at", "be", "had", "their", "them", "said"}),
    "fr": frozenset({"le", "la", "les", "des", "est", "une", "et", "que", "qui", "dans", "pour", "pas", "il",
                     "elle", "du", "au",
                     "nous", "vous", "ils", "elles", "avec", "sur", "sont", "était", "cette", "ses", "aux",
                     "comme", "tout", "avait", "été", "je", "ne", "ce", "lui", "leur"}),
    "de": frozenset({"und", "der", "die", "das", "nicht", "ist", "ein", "eine", "sich", "mit", "auf", "dem",
                     "den", "zu", "ich", "sie",
                     "auch", "aber", "dass", "wie", "von", "für", "als", "wird", "wurde", "hatte", "noch",
                     "nach", "bei", "aus", "oder", "wenn", "einen", "einem", "einer", "im", "zum", "zur",
                     "über", "hat", "sind", "werden", "kann", "nur", "schon", "mehr", "dann", "doch", "wir",
                     "ihr", "ihm", "ihn", "ihre"}),
    "nl": frozenset({"het", "een", "van", "niet", "ook", "maar", "zijn", "voor", "naar", "hij", "zij", "wat",
                     "werd", "heeft", "deze", "dat", "en",
                     "als", "bij", "met", "om", "op", "aan", "nog", "door", "geen", "kan", "wordt", "waren",
                     "zich", "mijn", "dit", "dan", "toen", "uit", "meer", "hun", "haar", "hem", "hen", "veel",
                     "wel", "zou", "zal", "kon", "moet", "worden"}),
    "es": frozenset({"el", "los", "las", "del", "por", "con", "una", "para", "como", "pero", "su", "lo", "más",
                     "muy", "sus", "está", "y", "en", "es",
                     "hay", "fue", "había", "también", "sin", "cuando", "porque", "todo", "así", "donde",
                     "desde", "hasta", "ya", "tenía", "estaba", "ese", "esa", "han", "qué"}),
    "it": frozenset({"di", "che", "è", "e", "della", "del", "nel", "sono", "gli", "anche", "questo", "più",
                     "una", "come", "non", "per",
                     "degli", "delle", "dei", "nei", "sul", "alla", "dal", "dalla", "questa", "quella", "quello",
                     "erano", "stato", "molto", "ancora", "sempre", "senza", "ma", "ci", "lui", "lei", "loro",
                     "cosa", "tutto", "tutti", "perché", "dove", "già", "poi", "ha", "hanno", "aveva", "fu",
                     "suo", "sua", "uno", "nella", "nello"}),
    "pt": frozenset({"não", "uma", "ele", "ela", "com", "isso", "seu", "sua", "ao", "em", "pelo", "pela",
                     "muito", "também", "e", "os", "das", "dos", "no", "na",
                     "mas", "foi", "são", "você", "já", "só", "há", "quando", "tinha", "havia", "depois",
                     "ainda", "sem", "nem", "até", "estava", "uns", "umas", "meu", "minha", "eles", "elas"}),
}
# A word of the text counts for a language when it is one of its function words; the characters below
# belong to a single language of the Latin-script group and add a vote for it.
_LATIN_HINTS: dict[str, re.Pattern] = {
    "es": re.compile(r"[ñ¿¡]"),
    "pt": re.compile(r"[ãõ]"),
    "de": re.compile(r"ß"),
}

# Unicode ranges counted as letters of each script.
_SCRIPT_RANGES = {
    "latin": "A-Za-zÀ-ÖØ-öø-ɏ",
    "han": "㐀-䶿一-鿿豈-﫿々〆\U00020000-\U0002fa1f",
    "kana": "ぁ-ゟァ-ヺヽ-ヿㇰ-ㇿｦ-ﾟ",
    "hangul": "가-힯ᄀ-ᇿ㄰-㆏",
    "cyrillic": "Ѐ-ԯ",
    "devanagari": "ऄ-हऽॐक़-ॡ",
    "arabic": "ؠ-يٮ-ۓەۮ-ۿݐ-ݿࢠ-ࣿ",
    "greek": "Ͱ-Ͽἀ-῿",
    "hebrew": "א-ת",
    "thai": "ก-ะาำเ-ๆ",
    "armenian": "Ա-Ֆա-ֆ",
    "georgian": "ა-ჺ",
    "bengali": "অ-হ", "gurmukhi": "ਅ-ਹ", "gujarati": "અ-હ",
    "tamil": "அ-ஹ", "telugu": "అ-హ", "kannada": "ಅ-ಹ", "malayalam": "അ-ഺ",
    "sinhala": "අ-ෆ", "khmer": "ក-ឳ", "lao": "ກ-ຮ",
}
_SCRIPT_RX = {name: re.compile(f"[{rng}]") for name, rng in _SCRIPT_RANGES.items()}
# Scripts that (almost) identify one language; the languages outside the registry are still reported
# so that the caller can say "unsupported" instead of guessing.
_SCRIPT_LANGUAGE = {
    "greek": "el", "hebrew": "he", "thai": "th", "armenian": "hy", "georgian": "ka", "bengali": "bn",
    "gurmukhi": "pa", "gujarati": "gu", "tamil": "ta", "telugu": "te", "kannada": "kn", "malayalam": "ml",
    "sinhala": "si", "khmer": "km", "lao": "lo",
}
# Letters per script needed before the script decides (Han and Hangul carry a word in 1-2 characters).
_SCRIPT_MIN = {"han": 30, "kana": 30, "hangul": 30}
_DEFAULT_SCRIPT_MIN = 60


def _count(rx: re.Pattern, text: str, chars: str = "") -> int:
    return len(rx.findall(text))


def _letters(text: str, chars: str) -> int:
    return sum(text.count(c) for c in chars)


def _cyrillic_language(text: str) -> str | None:
    """ru for Russian; uk, be, bg, sr, mk when their own letters show; None when it is some other Cyrillic."""
    low = text.lower()
    n = len(_SCRIPT_RX["cyrillic"].findall(low))
    ru = _letters(low, "ыэё")
    if _letters(low, "әғқңөұүһ") >= 0.01 * n:
        return None  # Kazakh, Mongolian, Kyrgyz...: not guessed
    if _letters(low, "ў") >= 0.005 * n:
        return "be"
    ukr = _letters(low, "іїєґ")
    if ukr >= 0.01 * n and ru < 0.5 * ukr:
        return "uk"
    if _letters(low, "ђћљњџј") >= 0.01 * n:
        return "mk" if _letters(low, "ѓќѕ") else "sr"
    if n >= 150 and ru == 0 and _letters(low, "ъ") >= 0.03 * n:
        return "bg"
    return "ru"


def _arabic_language(text: str) -> str | None:
    """ar for Arabic; fa and ur when the Persian/Urdu letters show; None for Pashto, Kurdish, Uyghur..."""
    n = len(_SCRIPT_RX["arabic"].findall(text))
    if _letters(text, "ړډځښڼەۆێڭۇڵ") >= 0.01 * n:
        return None
    if _letters(text, "ٹڈڑںے") >= 0.01 * n:
        return "ur"
    persian = _letters(text, "کی")  # Persian/Urdu kaf and yeh; Arabic writes ك and ي
    arabic = _letters(text, "كي")
    if (_letters(text, "پچژگ") >= 0.005 * n or persian >= 0.03 * n) and persian > 2 * arabic:
        return "fa"
    return "ar"


def _script_language(text: str) -> tuple[bool, str | None]:
    """(decided, language): the script settles the language when non-Latin letters outnumber Latin ones."""
    sample = unicodedata.normalize("NFKC", text[:200000])
    counts = {name: len(rx.findall(sample)) for name, rx in _SCRIPT_RX.items()}
    groups = {
        "cjk": counts["han"] + counts["kana"],
        "hangul": counts["hangul"],
        "cyrillic": counts["cyrillic"],
        "devanagari": counts["devanagari"],
        "arabic": counts["arabic"],
        **{s: counts[s] for s in _SCRIPT_LANGUAGE},
    }
    group, n = max(groups.items(), key=lambda kv: kv[1])
    if n == 0 or n <= counts["latin"]:
        return False, None
    if group == "cjk":
        if n < _SCRIPT_MIN["han"]:
            return True, None
        kana = counts["kana"]
        return True, "ja" if kana >= 3 and kana >= 0.08 * n else "zh"
    if n < _SCRIPT_MIN.get(group, _DEFAULT_SCRIPT_MIN):
        return True, None
    if group == "hangul":
        return True, "ko"
    if group == "cyrillic":
        return True, _cyrillic_language(sample)
    if group == "devanagari":
        return True, "mr" if _letters(sample, "ळ") >= 0.003 * n else "hi"
    if group == "arabic":
        return True, _arabic_language(sample)
    return True, _SCRIPT_LANGUAGE[group]


def detect_language(text: str) -> str | None:
    """Detect a book's language from its text; None when there is too little text or the answer is unclear.

    Non-Latin scripts decide on their own letters: Cyrillic is Russian (Ukrainian, Belarusian,
    Bulgarian, Serbian and Macedonian when their own letters show), Han alone is Chinese and any
    kana makes it Japanese, Hangul is Korean, Devanagari is Hindi (Marathi when it uses ळ), Arabic
    script is Arabic (Persian or Urdu when their letters show). A script wins when its letters
    outnumber the Latin ones, so a Russian book with Latin names is Russian and an English book with
    a Chinese phrase is English. Latin-script text takes a small stop-word vote among English,
    French, Spanish, German, Italian, Portuguese and Dutch: the winner must account for at least 5%
    of the words and beat the runner-up by half again, over at least 50 words. Callers then fall back
    to English and record a warning.
    """
    decided, language = _script_language(text)
    if decided:
        return language
    words = re.findall(r"[a-zà-ÿßœ']+", text.lower())[:20000]
    if len(words) < 50:
        return None
    counts = Counter(w for w in words if any(w in s for s in _STOP_WORDS.values()))
    sample = text[:200000].lower()
    hints = {lang: len(rx.findall(sample)) for lang, rx in _LATIN_HINTS.items()}
    scores = sorted(
        ((sum(counts[w] for w in stop) + hints.get(lang, 0), lang) for lang, stop in _STOP_WORDS.items()),
        reverse=True,
    )
    (best, lang), (second, _) = scores[0], scores[1]
    if best == 0 or best < 0.05 * len(words) or best <= second * 1.5:
        return None
    return lang


# "No language" codes (ISO 639-2 special codes and common placeholders).
_NO_LANGUAGE = {"und", "mul", "zxx", "mis", "xx", "xxx", "unk", "unknown", "none", "null", "nil", "n/a", "na"}
# ISO 639-1 codes; a two-letter value outside this list is not a language.
_ISO_639_1 = frozenset(
    "aa ab ae af ak am an ar as av ay az ba be bg bh bi bm bn bo br bs ca ce ch co cr cs cu cv cy da de dv dz "
    "ee el en eo es et eu fa ff fi fj fo fr fy ga gd gl gn gu gv ha he hi ho hr ht hu hy hz ia id ie ig ii ik "
    "io is it iu ja jv ka kg ki kj kk kl km kn ko kr ks ku kv kw ky la lb lg li ln lo lt lu lv mg mh mi mk ml "
    "mn mr ms mt my na nb nd ne ng nl nn no nr nv ny oc oj om or os pa pi pl ps pt qu rm rn ro ru rw sa sc sd "
    "se sg sh si sk sl sm sn so sq sr ss st su sv sw ta te tg th ti tk tl tn to tr ts tt tw ty ug uk ur uz ve "
    "vi vo wa wo xh yi yo za zh zu".split()
)
# Deprecated ISO 639-1 codes, and country codes often written instead of the language's.
_DEPRECATED_639_1 = {"iw": "he", "in": "id", "ji": "yi", "jw": "jv", "mo": "ro",
                     "jp": "ja", "cn": "zh", "gr": "el", "dk": "da", "ua": "uk", "cz": "cs"}
# ISO 639-2/B, 639-2/T and language names (English and native) -> ISO 639-1.
_LANGUAGE_ALIASES = {
    "eng": "en", "english": "en", "anglais": "en",
    "fre": "fr", "fra": "fr", "french": "fr", "français": "fr", "francais": "fr",
    "ger": "de", "deu": "de", "german": "de", "deutsch": "de", "allemand": "de",
    "spa": "es", "spanish": "es", "español": "es", "espanol": "es", "espagnol": "es", "castellano": "es",
    "castilian": "es",
    "ita": "it", "italian": "it", "italiano": "it", "italien": "it",
    "dut": "nl", "nld": "nl", "dutch": "nl", "nederlands": "nl", "néerlandais": "nl", "flemish": "nl",
    "vlaams": "nl",
    "por": "pt", "portuguese": "pt", "português": "pt", "portugues": "pt", "portugais": "pt",
    "brazilian": "pt",
    "rus": "ru", "russian": "ru", "russe": "ru", "русский": "ru",
    "chi": "zh", "zho": "zh", "chinese": "zh", "chinois": "zh", "cmn": "zh", "mandarin": "zh",
    "中文": "zh", "汉语": "zh", "漢語": "zh", "普通话": "zh", "普通話": "zh", "国语": "zh", "國語": "zh",
    "简体中文": "zh", "繁體中文": "zh", "繁体中文": "zh", "simplified chinese": "zh", "traditional chinese": "zh",
    "jpn": "ja", "japanese": "ja", "japonais": "ja", "日本語": "ja", "日本语": "ja",
    "kor": "ko", "korean": "ko", "coréen": "ko", "한국어": "ko", "한국말": "ko",
    "ara": "ar", "arb": "ar", "arabic": "ar", "arabe": "ar", "العربية": "ar", "عربي": "ar",
    "pol": "pl", "polish": "pl",
    "swe": "sv", "swedish": "sv",
    "dan": "da", "danish": "da",
    "nor": "no", "nob": "nb", "nno": "nn", "norwegian": "no",
    "fin": "fi", "finnish": "fi",
    "gre": "el", "ell": "el", "greek": "el",
    "lat": "la", "latin": "la",
    "cat": "ca", "catalan": "ca",
    "tur": "tr", "turkish": "tr",
    "heb": "he", "hebrew": "he",
    "hin": "hi", "hindi": "hi", "हिन्दी": "hi", "हिंदी": "hi",
    "cze": "cs", "ces": "cs", "czech": "cs",
    "per": "fa", "fas": "fa", "persian": "fa", "farsi": "fa",
    "urd": "ur", "urdu": "ur",
    "ukr": "uk", "ukrainian": "uk",
}
# Keys are compared folded (case, accents and punctuation ignored) so "Português" and "portugues" are one.
_ALIASES_FOLDED = {vocab.fold(k): v for k, v in _LANGUAGE_ALIASES.items()}


def normalize_language(value: str | None) -> str | None:
    """Map an EPUB/PDF language value to an ISO 639-1 code, or None when it names no language.

    Handles BCP 47 tags ("en-US", "fr_CA", "pt-BR", "zh-Hans-CN", "es-419"), ISO 639-2 codes ("eng",
    "fre", "fra", "por", "chi", "jpn", "nld") and language names in English or in the language itself
    ("French", "Français", "Deutsch", "中文", "日本語", "한국어", "हिन्दी", "العربية", "Русский").
    "und", "mul", "zxx" and unrecognisable values ("zz", "???") return None so the caller detects the
    language from the text. A valid code for a language outside the registry ("pl", "el") and an
    unmapped but well-formed 3-letter code are kept as is, so the pipeline can report the language
    as unsupported instead of guessing.
    """
    if not value:
        return None
    v = "".join(c for c in value if unicodedata.category(c) != "Cf").strip().lower().replace("_", "-")
    if not v or v in _NO_LANGUAGE:
        return None
    primary = v.split("-")[0].strip()
    if primary in _NO_LANGUAGE:
        return None
    registry = languages.normalize_code(v)
    if registry:
        return registry
    folded_all = vocab.fold(v)
    if folded_all in _ALIASES_FOLDED:
        return _ALIASES_FOLDED[folded_all]
    token = re.split(r"[\s,;()/\[\]]+", v.strip(" ,;()[]"))[0]
    for code in (primary, token, (re.match(r"[^\W\d_]+", v) or [""])[0]):
        if not code:
            continue
        key = vocab.fold(code)
        if key in _ALIASES_FOLDED:
            return _ALIASES_FOLDED[key]
        if code in _ISO_639_1:
            return code
        if code in _DEPRECATED_639_1:
            return _DEPRECATED_639_1[code]
        if code == primary and re.fullmatch(r"[a-z]{3}", code):
            return code
    return None


def is_supported_language(code: str | None) -> bool:
    """True when `code` is one of the languages of the registry (en fr es de it pt ru zh ja ko hi ar nl)."""
    return bool(code) and languages.normalize_code(code) is not None


def unsupported_language_message(code: str) -> str:
    """The warning for a book whose language Audiobook Studio cannot narrate."""
    names = ", ".join(f"{lang.name} ({lang.code})" for lang in languages.LANGUAGES.values())
    return (
        f"The book's language ('{code}') is not one Audiobook Studio can narrate. "
        f"Supported languages: {names}. Set the language by hand if the detection is wrong."
    )
