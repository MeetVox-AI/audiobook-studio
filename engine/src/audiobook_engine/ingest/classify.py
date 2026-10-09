"""Heuristics shared by EPUB and PDF ingest: front/back matter and language.

Everything here is a heuristic. The app shows the result and lets the user
re-tick any section, so a wrong guess costs a click, not a ruined audiobook.
"""

from __future__ import annotations

import re
from collections import Counter
from collections.abc import Iterable

from ..models import Section

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
    r"(©|\(c\)\s*\d{4}|all rights reserved|tous droits r[ée]serv[ée]s|\bISBN\b)", re.IGNORECASE
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
    return None


def front_matter_signals(paragraphs: list[str]) -> list[str]:
    """Reasons a block of opening pages looks like front matter, whatever its length."""
    signals: list[str] = []
    if _COPYRIGHT_TEXT.search(" ".join(paragraphs)):
        signals.append("copyright notice")
    if any(_CONTENTS_HEAD.match(p) for p in paragraphs):
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
}
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
_SENTENCE_END = re.compile(r"[.!?…][\"'”’»)\]]*\s*$")
_OPENING_QUOTE = re.compile(r"^\s*[\"“‘«„—–-]")
# A heading number set off by a full stop or colon: "I. THE BEGINNING.", "1. The Beginning."
_NUMBER_PREFIX = re.compile(r"\s*(?:\d{1,4}|[IVXLCDM]+)[.:]\s")
# Any capitalised word with a number, set off the same way: "Lesson 3: Fractions", "Day 1: Arrival".
_WORD_NUMBER_PREFIX = re.compile(r"\s*(?=[A-ZÀ-ÖØ-Þ])[^\W\d_]+\s+(?:\d{1,4}|[IVXLCDM]+)[.:]\s")


def _fold(text: str) -> str:
    return " ".join(re.findall(r"\w+", text.casefold()))


def _label_or_number(word: str) -> bool:
    return word in _LABEL_WORDS or word in _NUMBER_WORDS or bool(_NUMBER_TOKEN.fullmatch(word))


def _is_label_title(folded: str) -> bool:
    """'chapter 1', 'part two', 'chapitre premier': a label word followed by a number."""
    words = folded.split()
    return len(words) >= 2 and words[0] in _LABEL_WORDS and all(_label_or_number(w) for w in words[1:])


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
            short_ok = len(block) >= 4 or _NUMBER_TOKEN.fullmatch(block)
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
            if len(extra) <= 4 and all(_label_or_number(w) for w in extra) and (labelled or numbered or not sentence):
                return True
            if len(extra) == 2 and _NUMBER_TOKEN.fullmatch(extra[1]) and _WORD_NUMBER_PREFIX.match(text):
                return True  # "Lesson 3: Fractions", "Day 1: Arrival"
        if block.startswith(t + " "):
            extra = block[len(t) + 1:].split()
            if _is_label_title(t):
                # a label title followed by its name: "Chapter 1: The Beginning" for "Chapter 1"
                if len(extra) <= 6 and not (sentence and len(extra) > 3):
                    return True
            elif len(extra) <= 6 and _title_then_subtitle(text, title):
                return True
    return False


# --------------------------------------------------------------------------- language

# Frequent function words per language. English and French are the languages the
# engines speak; the others are only there so that German, Dutch, Spanish, Italian
# or Portuguese text is not taken for English or French (German "in"/"was" are
# English stop words, Spanish and Italian "la"/"il"/"que" are French ones). Words
# that are common in English or French are left out of the other lists.
_STOP_WORDS: dict[str, frozenset[str]] = {
    "en": frozenset({"the", "and", "of", "to", "is", "that", "in", "it", "was", "with", "he", "she", "his",
                     "her", "you", "for"}),
    "fr": frozenset({"le", "la", "les", "des", "est", "une", "et", "que", "qui", "dans", "pour", "pas", "il",
                     "elle", "du", "au"}),
    "de": frozenset({"und", "der", "die", "das", "nicht", "ist", "ein", "eine", "sich", "mit", "auf", "dem",
                     "den", "zu", "ich", "sie"}),
    "nl": frozenset({"het", "een", "van", "niet", "ook", "maar", "zijn", "voor", "naar", "hij", "zij", "wat",
                     "werd", "heeft", "deze", "dat", "en"}),
    "es": frozenset({"el", "los", "las", "del", "por", "con", "una", "para", "como", "pero", "su", "lo", "más",
                     "muy", "sus", "está", "y", "en", "es"}),
    "it": frozenset({"di", "che", "è", "e", "della", "del", "nel", "sono", "gli", "anche", "questo", "più",
                     "una", "come", "non", "per"}),
    "pt": frozenset({"não", "uma", "ele", "ela", "com", "isso", "seu", "sua", "ao", "em", "pelo", "pela",
                     "muito", "também", "e", "os", "das", "dos", "no", "na"}),
}


def detect_language(text: str) -> str | None:
    """Very small stop-word vote: English, French, or another language they could be confused with.

    The winner must account for at least 5% of the words and beat the runner-up
    by half again. Returns None when there is too little text or the vote is
    unclear; callers then fall back to English and record a warning.
    """
    words = re.findall(r"[a-zà-ÿ']+", text.lower())[:20000]
    if len(words) < 50:
        return None
    counts = Counter(w for w in words if any(w in s for s in _STOP_WORDS.values()))
    scores = sorted(
        ((sum(counts[w] for w in stop), lang) for lang, stop in _STOP_WORDS.items()), reverse=True
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
    "spa": "es", "spanish": "es", "español": "es", "espanol": "es", "espagnol": "es",
    "ita": "it", "italian": "it", "italiano": "it", "italien": "it",
    "dut": "nl", "nld": "nl", "dutch": "nl", "nederlands": "nl", "néerlandais": "nl",
    "por": "pt", "portuguese": "pt", "português": "pt", "portugues": "pt", "portugais": "pt",
    "rus": "ru", "russian": "ru", "russe": "ru",
    "chi": "zh", "zho": "zh", "chinese": "zh", "chinois": "zh",
    "jpn": "ja", "japanese": "ja", "japonais": "ja",
    "kor": "ko", "korean": "ko",
    "ara": "ar", "arabic": "ar", "arabe": "ar",
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
    "hin": "hi", "hindi": "hi",
    "cze": "cs", "ces": "cs", "czech": "cs",
}


def normalize_language(value: str | None) -> str | None:
    """Map an EPUB/PDF language value to an ISO 639-1 code, or None when it names no language.

    Handles BCP 47 tags ("en-US", "fr_CA"), ISO 639-2 codes ("eng", "fre",
    "fra") and language names ("French", "Français"). "und", "mul", "zxx" and
    unrecognisable values ("zz", "???") return None so the caller detects the
    language from the text. A valid code for another language ("de", "ja") and
    an unmapped but well-formed 3-letter code are kept as is, so the pipeline
    can report the language as unsupported instead of guessing.
    """
    if not value:
        return None
    v = value.strip().lower().replace("_", "-")
    if not v or v in _NO_LANGUAGE:
        return None
    primary = v.split("-")[0].strip()
    if primary in _NO_LANGUAGE:
        return None
    for code in (primary, (re.match(r"[^\W\d_]+", v) or [""])[0]):
        if code in _LANGUAGE_ALIASES:
            return _LANGUAGE_ALIASES[code]
        if code in _ISO_639_1:
            return code
        if code in _DEPRECATED_639_1:
            return _DEPRECATED_639_1[code]
        if code == primary and re.fullmatch(r"[a-z]{3}", code):
            return code
    return None
