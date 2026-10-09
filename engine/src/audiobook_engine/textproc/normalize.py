"""Deterministic text normalisation before TTS (English and French).

Small TTS models mispronounce numbers, symbols and abbreviations; fixing the
text is more reliable than hoping the model guesses. Every rule here is
deterministic so that the chunk cache stays valid. Bump NORMALIZER_VERSION
whenever a rule changes: it is part of every cache key.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

from num2words import num2words

NORMALIZER_VERSION = "5"


@dataclass
class Rules:
    """Per-book pronunciation rules: literal or regex replacements applied last."""

    replacements: list[tuple[str, str, bool]] = field(default_factory=list)  # (pattern, replacement, is_regex)

    def apply(self, text: str) -> str:
        for pat, rep, is_regex in self.replacements:
            if is_regex:
                text = re.sub(pat, rep, text)
            else:
                text = re.sub(rf"(?<!\w){re.escape(pat)}(?!\w)", rep, text)
        return text

    def fingerprint(self) -> str:
        return repr(self.replacements)


# ----------------------------------------------------------------------------- helpers

# Typographic thousands separator. cleanup() turns a no-break or thin space between
# digit groups ("10 000" typeset with U+00A0/U+202F/U+2009) into this private-use
# marker, so expand_numbers can tell one grouped number from numbers separated by
# an ordinary space ("chambres 101 102 103"). expand_numbers turns any leftover
# marker back into a space.
_GROUP = ""


# A longer digit string (a card number, a page of the digits of pi) is read digit by digit:
# as one number it is unreadable, num2words gives up past about 400 digits and int() past
# 4300. A number grouped by thousands is read as a number up to the nonillions.
_MAX_DIGITS = 15
_MAX_GROUPED_DIGITS = 30


def _words(n: int | float, lang: str, to: str = "cardinal") -> str:
    return num2words(n, lang=lang, to=to)


def _digits(s: str) -> str:
    return re.sub(rf"[,\s.{_GROUP}]", "", s)


def _int(s: str) -> int:
    return int(_digits(s))


def _cardinal(s: str, lang: str, to: str = "cardinal") -> str:
    """Speak a written integer ("1,250", "10 000", "007")."""
    digits = _digits(s)
    limit = _MAX_DIGITS if len(digits) == len(s) else _MAX_GROUPED_DIGITS
    significant = digits.lstrip("0")
    if len(significant) > limit:
        return _digit_by_digit(digits, lang)
    # int() is given the significant digits only: it refuses a string of more than 4300
    # digits, a long run of leading zeros included.
    return _words(int(significant or "0"), lang, to)


def _digit_by_digit(digits: str, lang: str) -> str:
    names = [_words(d, lang) for d in range(10)]
    return " ".join(names[int(d)] for d in digits)


def _decimal(int_part: str, frac: str, lang: str) -> str:
    whole = _cardinal(int_part, lang) if int_part else _words(0, lang)
    sep = "point" if lang == "en" else "virgule"
    rest = frac.lstrip("0")
    if lang == "en" or len(rest) > _MAX_DIGITS:
        frac_words = _digit_by_digit(frac, lang)
    else:
        lead = len(frac) - len(rest)
        frac_words = " ".join(["zéro"] * lead + ([_words(int(rest), lang)] if rest else []))
    return f"{whole} {sep} {frac_words}"


def _fr_fem(spoken: str) -> str:
    """Feminine agreement of a French number: 'un' → 'une', 'vingt et un' → 'vingt et une'."""
    return re.sub(r"\bun$", "une", spoken)


_ROMAN = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}


def roman_to_int(token: str) -> int | None:
    token = token.upper()
    if not token or any(c not in _ROMAN for c in token):
        return None
    total = 0
    for a, b in zip(token, token[1:] + " "):
        v = _ROMAN[a]
        total += -v if b != " " and _ROMAN[b] > v else v
    # reject non-canonical forms such as "IIII" or "VX" by round-tripping
    return total if _int_to_roman(total) == token else None


def _int_to_roman(n: int) -> str:
    vals = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
    out = ""
    for v, s in vals:
        while n >= v:
            out += s
            n -= v
    return out


# ----------------------------------------------------------------------------- cleanup

_FOOTNOTE_REF = re.compile(r"\[\s*(?:\d{1,3}|[a-z]|[ivx]{1,4}|\*)\s*\]|(?<=[a-zà-ÿ.,;:!?»”\"'])\*+(?=\s|$)", re.IGNORECASE)
_URL = re.compile(r"\b(?:https?://(?:www\.)?|www\.)\S+", re.IGNORECASE)
_URL_TRAILING = ".,;:!?)]\"'»"


def _url_to_domain(m: re.Match) -> str:
    """A URL is read as its bare domain.

    Punctuation that follows it ("Visit www.x.com. Then", "(see https://x.com/a.)") is not
    part of the URL and stays in the text, so the sentence keeps its period. A closing
    bracket that balances one inside the URL (".../wiki/Foo_(bar)") belongs to the URL.
    The URL is matched greedily and trimmed with str methods, in linear time: the brackets
    are counted once, and the count is updated as each closing bracket moves into the URL.
    """
    url = m.group(0)
    core = url.rstrip(_URL_TRAILING)
    trailing = url[len(core):]
    unclosed = {")": core.count("(") - core.count(")"), "]": core.count("[") - core.count("]")}
    i = 0
    while i < len(trailing) and unclosed.get(trailing[i], 0) > 0:
        unclosed[trailing[i]] -= 1
        i += 1
    core, trailing = core + trailing[:i], trailing[i:]
    domain = re.sub(r"^(?:https?://(?:www\.)?|www\.)", "", core, flags=re.IGNORECASE)
    domain = re.split(r"[/?#]", domain, maxsplit=1)[0].rstrip(_URL_TRAILING)
    return domain + trailing if domain else url


def cleanup(text: str) -> str:
    """Typographic clean-up. Every step is linear in the length of the text."""
    text = unicodedata.normalize("NFC", text)
    text = text.replace(_GROUP, "")
    text = re.sub(r"(?<=\d)[   ](?=\d{3}(?!\d))", _GROUP, text)
    # Collapse whitespace (no-break and thin spaces included) before any pattern that starts
    # with \s*: such a pattern is quadratic on a long run of spaces.
    text = re.sub(r"\s+", " ", text)
    text = text.replace("­", "")  # soft hyphen
    text = text.replace("’", "'").replace("‘", "'").replace("‚", "'")
    text = text.replace("“", '"').replace("”", '"').replace("„", '"')
    text = text.replace("…", "...")
    text = re.sub(r"\.{4,}", "...", text)
    text = re.sub(r"[‐‑]", "-", text)  # unicode hyphens
    text = re.sub(r" ?[—―] ?", " — ", text)
    text = re.sub(r"(?<=\w) – (?=\w)", " — ", text)  # spaced en dash used as a dash
    text = _FOOTNOTE_REF.sub("", text)
    text = _URL.sub(_url_to_domain, text)
    text = re.sub(r"[_~^`|<>{}\[\]]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


# ----------------------------------------------------------------------------- casing

_ALLCAPS_WORD = re.compile(r"\b[A-ZÀ-Ý][A-ZÀ-Ý'’-]+\b")
# Acronyms kept as they are when one of them is the only capitalised word opening a
# section ("US officials said", "AI models"). Ordinary words that small caps also
# produce ("IT was", "UN jour") are deliberately absent.
_ACRONYMS = frozenset({
    "AI", "BBC", "CEO", "CIA", "CNN", "DNA", "EU", "FBI", "NASA", "NATO", "NSA", "TV", "UK", "US", "USA", "USSR",
    "ADN", "ONU", "OTAN", "PDG", "RATP", "SNCF", "UE", "URSS",
})


def _mostly_upper(text: str) -> bool:
    letters = [c for c in text if c.isalpha()]
    return len(letters) >= 4 and sum(c.isupper() for c in letters) / len(letters) >= 0.8


def sentence_case(text: str) -> str:
    low = text.lower()
    return re.sub(r"(^|[.!?]\s+)([a-zà-ÿ])", lambda m: m.group(1) + m.group(2).upper(), low)


def fix_small_caps_opening(text: str) -> str:
    """'HAPPY for all' / 'MR. BENNET was' → 'Happy for all' / 'Mr. Bennet was'.

    Books set the first words of a chapter in small caps; models may spell
    upper-case words letter by letter. Only the opening run of capitalised
    words is touched, so acronyms later in the paragraph are preserved. Call
    it on a section's first body paragraph only: elsewhere an opening
    upper-case word is an acronym, not small caps.
    """
    m = re.match(r"^((?:[\"'(«]?\s*)?(?:[A-ZÀ-Ý][A-ZÀ-Ý'’.-]*\s+){1,4})(?=[a-zà-ÿ])", text)
    if not m:
        return text
    run = m.group(1)
    tokens = _ALLCAPS_WORD.findall(run)
    if len(tokens) == 1 and tokens[0] in _ACRONYMS:
        return text

    def fix(w: re.Match) -> str:
        tok = w.group(0)
        if tok == "MM" and run[w.end():w.end() + 1] == ".":
            return tok  # French "MM." (Messieurs) is expanded later from its upper-case form
        return tok.capitalize()

    return re.sub(r"[A-ZÀ-Ý][A-ZÀ-Ý'’-]+", fix, run) + text[len(run):]


# ----------------------------------------------------------------------------- abbreviations

# Capitalised words that usually open a new sentence. An abbreviation that can also end a
# sentence ("Jr.", street "St.") keeps its period only when one of these follows it.
_EN_STARTER = (r"(?:The|A|An|I|He|She|It|We|They|You|His|Her|Its|Our|Their|My|Your|This|That|These|Those|"
               r"There|Then|But|And|So|Yet|Now|When|While|After|Before|As|In|On|At|If|No|Yes|What|Who|How|"
               r"Why|Where)\b")
_EN_STREET_BEFORE = r"\b([A-Z][a-zà-ÿ]+|\d+[A-Za-z]*) St\."
_FR_PARTICLE = r"(?:[A-ZÀ-Ý]|d'|de\b|du\b|des\b|la\b|le\b|les\b|l')"
# "J. M. Barrie", "J.M. Barrie", "J.-M. Le Pen": M. is an initial there. A single capital
# letter is an initial, a longer word is not: "sous Louis XVI. M. de Villefort entra."
_NOT_AN_INITIAL = r"(?<!\b[A-ZÀ-Ý]\.\s)(?<!\b[A-ZÀ-Ý]\.)(?<!-)"
# "M. et Mme Thénardier", "Mr. et Mrs. Fogg": the title before a couple ("Mrs." is expanded
# to "Missis" before "Mr." is looked at).
_FR_COUPLE = r"(?=\s+et\s+(?:Mmes?|Madame|Mlles?|Mademoiselle|Mrs|Missis)\b)"

_ABBR_EN = [
    (r"\bMr\.", "Mister"), (r"\bMrs\.", "Missus"), (r"\bMs\.", "Miz"), (r"\bDr\.(?=\s+[A-Z])", "Doctor"),
    (r"\bProf\.", "Professor"), (r"\bCapt\.", "Captain"), (r"\bCol\.", "Colonel"), (r"\bGen\.", "General"),
    (r"\bLt\.", "Lieutenant"), (r"\bSgt\.", "Sergeant"), (r"\bRev\.", "Reverend"), (r"\bHon\.", "Honourable"),
    (rf"\bJr\.(?=\s+{_EN_STARTER}|\s*$)", "Junior."), (r"\bJr\.", "Junior"),
    (rf"\bSr\.(?=\s+{_EN_STARTER}|\s*$)", "Senior."), (r"\bSr\.", "Senior"),
    # "Baker St. The rooms…" ends a sentence on a street; "Baker St. was" / "Baker St.," is mid-sentence;
    # any other "St. Paul", "Mount St. Helens" is a saint.
    (rf"{_EN_STREET_BEFORE}(?=\s+{_EN_STARTER}|\s*[\"')]?\s*$)", r"\1 Street."),
    (rf"{_EN_STREET_BEFORE}(?=\s*[a-z,;:!?)—-])", r"\1 Street"),
    (r"\bSt\.(?=\s+[A-Z])", "Saint"), (r"\bMt\.", "Mount"),
    (r"\bvs\.", "versus"), (r"\be\.g\.", "for example"), (r"\bi\.e\.", "that is"),
    (r"\betc\.(?=\s+[\"'(]?[A-Z]|\s*$)", "et cetera."), (r"\betc\.", "et cetera"),
    (r"\bapprox\.", "approximately"), (r"\bNo\.(?=\s*\d)", "number"), (r"\b[Nn][°º]\s*(?=\d)", "number "),
    # "fig." and "vol." are also words ("He ate a fig."): expand them only before a number.
    (r"\b([Ff])ig\.(?=\s*\d)", r"\1igure"), (r"\b([Vv])ol\.(?=\s*(?:\d|[IVXLC]+(?![\w'’])))", r"\1olume"),
    (r"\bch\.(?=\s*\d)", "chapter"), (r"\bpp\.(?=\s*\d)", "pages"), (r"\bp\.(?=\s*\d)", "page"),
]
_ABBR_FR = [
    (rf"{_NOT_AN_INITIAL}\bMM\.(?=\s+{_FR_PARTICLE})", "Messieurs"),
    (rf"{_NOT_AN_INITIAL}\bM\.(?=\s+{_FR_PARTICLE}|{_FR_COUPLE})", "Monsieur"),
    # Verne and others write the English titles: "Mr. Fogg", "Mrs. Aouda".
    (r"\bMrs\b\.?(?=\s+[A-ZÀ-Ý])", "Missis"), (rf"\bMr\b\.?(?=\s+[A-ZÀ-Ý]|{_FR_COUPLE})", "Mister"),
    (r"\bMme\b\.?", "Madame"), (r"\bMmes\b\.?", "Mesdames"), (r"\bMlle\b\.?", "Mademoiselle"),
    (r"\bMlles\b\.?", "Mesdemoiselles"),
    (r"\bDr\b\.?(?=\s+[A-ZÀ-Ý])", "Docteur"), (r"\bMe\b\.?(?=\s+[A-ZÀ-Ý])", "Maître"),
    (r"\bMgr\b\.?", "Monseigneur"), (r"\bSte\b\.?(?=[\s-])", "Sainte"), (r"\bSt\b\.?(?=[\s-])", "Saint"),
    (r"\b[nN][°ºo]\s*(?=\d)", "numéro "),
    (r"\betc\.(?=\s+[\"'«(—–-]?\s*[A-ZÀ-Ý]|\s*$)", "et cetera."), (r"\betc\.", "et cetera"),
    (r"\bp\. ?ex\.", "par exemple"), (r"\bc\.-à-d\.", "c'est-à-dire"), (r"\bcf\.", "confer"),
    # "vol." is also a word ("accusé de vol."): "volume" only before a number.
    (r"\b([Vv])ol\.(?=\s*(?:\d|[IVXLC]+(?![\w'’])))", r"\1olume"),
    (r"\bchap\.(?=\s*[\dIVXLC])", "chapitre"), (r"\bp\.(?=\s*\d)", "page"),
]


def expand_abbreviations(text: str, lang: str) -> str:
    for pat, rep in _ABBR_FR if lang == "fr" else _ABBR_EN:
        text = re.sub(pat, rep, text)
    return text


# ----------------------------------------------------------------------------- numbers

_UNITS = {
    "en": {"$": ("dollar", "dollars"), "£": ("pound", "pounds"), "€": ("euro", "euros"), "¥": ("yen", "yen")},
    "fr": {"$": ("dollar", "dollars"), "£": ("livre", "livres"), "€": ("euro", "euros"), "¥": ("yen", "yens")},
}
_SUBUNITS = {
    "en": {"$": ("cent", "cents"), "€": ("cent", "cents"), "£": ("penny", "pence")},
    "fr": {"$": ("cent", "cents"), "€": ("centime", "centimes"), "£": ("penny", "pence")},
}
_SYMBOLS = {
    "en": {"&": " and ", "%": " percent", "§": " section ", "+": " plus ", "=": " equals ", "×": " times "},
    "fr": {"&": " et ", "%": " pour cent", "§": " paragraphe ", "+": " plus ", "=": " égale ", "×": " fois "},
}
_DEGREE = {"en": ("degree", "degrees"), "fr": ("degré", "degrés")}  # "°", see expand_symbols
# A magnitude between the amount and the currency: "$5 million", "£2bn", "1,5 million €", "3 M€".
_MAGNITUDE = {
    "en": r"\s?(?P<mag>(?i:thousand|million|billion|trillion))\b|\s?(?P<suf>bn|mn|tn)\b|(?P<suf1>[kKmMbB])\b",
    "fr": r"\s?(?P<mag>(?i:mille|millions?|milliards?))\b|\s?(?P<suf>Mds|Md|M|k)\b",
}
_MAG_SUFFIX = {
    "en": {"k": "thousand", "K": "thousand", "m": "million", "M": "million", "mn": "million",
           "b": "billion", "B": "billion", "bn": "billion", "tn": "trillion"},
    "fr": {"k": "mille", "M": "million", "Md": "milliard", "Mds": "milliard"},
}

_MONTHS = "January|February|March|April|May|June|July|August|September|October|November|December"
# Words after a number that make it a measure, not a time of day: "by 1.50 metres", "at 1.45 million",
# "won by 2.15 seconds", "stood at 1.15 against the dollar". "against" alone is not one: "Kick-off
# was at 3.00 against Leeds" is a time.
_AGAINST_CURRENCY = (r"against (?:the )?(?:[A-Z][A-Za-z.]* )?(?:dollar|euro|pound|yen|franc|mark|sterling|yuan|"
                     r"rouble|ruble|rupee|peso|lira|greenback)s?")
_UNIT_WORD = (r"(?:%|°|(?:percent|per|percentage|times|points?|degrees?|metres?|meters?|m|km|cm|mm|kg|g|lbs?|oz|"
              r"miles?|mph|inch(?:es)?|feet|ft|yards?|kilos?|grams?|litres?|liters?|pounds?|dollars?|euros?|pence|"
              r"cents?|thousand|million|billion|trillion|bn|mn|k|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|"
              rf"weeks?|months?|years?|lengths?|goals?|runs?|{_AGAINST_CURRENCY}|apiece|a (?:head|piece|share|dozen)|"
              r"each(?! (?:day|morning|afternoon|evening|night|week|time)))\b)")
# A word before "by", "from" or "between" that makes the number after it a change in a
# quantity, not a time: "rose by 1.25", "cut from 2.50 to 1.75". Before "at" these verbs
# usually tell a time ("He rose at 6.30"), so only price words count there.
_CHANGE_VERBS = frozenset(
    "rose risen rise rises rising fell fallen fall falls falling grew grown grow grows growing increased increase "
    "increases decreased decrease decreases dropped drop drops climbed climb climbs declined decline declines "
    "gained gain gains lost lose loses won win wins beat beaten cut cuts reduced reduce reduces raised raise raises "
    "lowered slipped jumped shrank shrunk expanded multiplied multiply divided divide higher exceeded varied varies "
    "ranged ranges fluctuated".split()
)
_PRICE_VERBS = frozenset("valued priced traded trading quoted pegged rated capped averaged averaging".split())
# Before "between", a measurement noun shortly before makes the range a value, not a time
# ("The pH was between 6.50 and 7.25", "a ratio between 1.10 and 1.30"). Without one, a range
# such as "Visiting hours are between 2.30 and 4.30" is read as times, the common case in prose.
_MEASURE_NOUNS = frozenset(
    "ph ratio ratios rate rates level levels temperature temperatures value values score scores percentage "
    "proportion concentration density index price prices odds factor coefficient average reading readings "
    "dose doses dosage weight weights height heights length lengths speed speeds pressure voltage frequency "
    "yield yields margin margins grade grades".split()
)
# Given names of monarchs and popes: "Louis XIV" is "Louis the Fourteenth" / "Louis quatorze".
_REGNAL_NAMES = (
    "John Paul|Jean-Paul|Victor-Emmanuel|Alexander|Alexandre|Alfonso|Alphonse|Amenhotep|Anne|Antiochus|Benedict|"
    "Benoît|Boniface|Carlos|Casimir|Catherine|Charles|Christian|Clement|Clément|Constantine|Constantin|Darius|"
    "Edward|Édouard|Elizabeth|Élisabeth|Elisabeth|Eugene|Eugène|Ferdinand|Francis|François|Frederick|Frédéric|"
    "George|Georges|Gregory|Grégoire|Gustav|Gustave|Gustavus|Haakon|Henri|Henry|Innocent|Isabella|Isabelle|Ivan|"
    "James|Jacques|Jean|John|Joseph|Leo|Léon|Leopold|Léopold|Louis|Ludwig|Napoleon|Napoléon|Nicholas|Nicolas|"
    "Olav|Otto|Othon|Paul|Pedro|Peter|Philip|Philippe|Pie|Pius|Ptolemy|Ptolémée|Ramesses|Ramsès|Richard|"
    "Rudolf|Rodolphe|Sixtus|Sixte|Stanislas|Umberto|Urban|Urbain|Victoria|Wilhelm|William|Guillaume"
)
# Capitalised French words that usually open a sentence (see _EN_STARTER).
_FR_STARTER = (r"(?:Le|La|Les|Il|Elle|Ils|Elles|On|Un|Une|Ce|Cet|Cette|Ces|Mais|Et|Puis|Alors|Quand|Lorsque|"
               r"Dans|En|Au|Aux|Son|Sa|Ses|Sur|Sous|Après|Avant|Depuis|Pendant|Je|Nous|Vous|Ainsi|Cependant)\b")
# Words after which a Roman numeral is a plain number: "Chapter XIV" → "Chapter fourteen".
_NUMBERED = {
    "en": r"[Cc]hapter|[Bb]ook|[Pp]art|[Vv]olume|[Aa]ct|[Ss]cene|[Cc]anto|[Ss]ection|[Aa]rticle|[Aa]ppendix|"
          r"[Pp]salm|War",
    "fr": r"[Cc]hapitre|[Ll]ivre|[Pp]artie|[Tt]ome|[Vv]olume|[Aa]cte|[Ss]cène|[Cc]hant|[Ss]ection|[Aa]rticle|"
          r"[Aa]nnexe|[Pp]saume",
}
# A unit word that repeats the currency symbol: "$5 million dollars", "$5 millions de dollars".
_MONEY_TAIL = r"(?P<tail>\s(?:de\s|d')?(?i:dollars?|pounds?|euros?|yens?|livres?)\b)?"


def _prev_words(s: str, pos: int, n: int) -> list[str]:
    """The last n words before s[pos], lower-cased, without opening quotes or brackets.

    Trailing punctuation is kept: "rose." ends a sentence, "rose" does not. Looks back
    40 characters only, so callers stay linear.
    """
    lo = max(0, pos - 40)
    words = s[lo:pos].split()
    if lo and words and not s[lo - 1].isspace() and not s[lo].isspace():
        words = words[1:]  # the window cut a word in two
    return [w.lstrip("\"'«([").lower() for w in words[-n:]]


def _amount(int_part: str, frac: str | None, lang: str) -> str:
    if frac:
        return _decimal(int_part, frac, lang)
    return _cardinal(int_part, lang)


def _plural(n_text: str, unit: tuple[str, str]) -> str:
    return unit[0] if n_text.strip() in {"one", "un", "une"} else unit[1]


def _fr_de(unit: str) -> str:
    """'un million d'euros', 'deux milliards de dollars'."""
    return f"d'{unit}" if unit[0] in "aeiouéèêàâ" else f"de {unit}"


def _money(int_part: str, frac: str | None, sym: str, mag: str | None, lang: str) -> str:
    unit = _UNITS[lang][sym]
    # The pound sterling is feminine in French: "une livre", "vingt et une livres".
    fem = _fr_fem if lang == "fr" and sym == "£" else (lambda spoken: spoken)
    if mag:
        amt = _amount(int_part, frac, lang)
        if lang == "fr" and mag != "mille":
            return f"{amt} {mag} {_fr_de(unit[1])}"
        return f"{amt} {mag} {unit[1]}"
    if frac and len(frac) == 2 and sym in _SUBUNITS[lang]:
        cents = int(frac)
        sub = _SUBUNITS[lang][sym]
        sub_word = sub[0] if cents == 1 else sub[1]
        main = fem(_cardinal(int_part, lang))
        if lang == "en":
            s = f"{main} {_plural(main, unit)}"
            return s + (f" and {_words(cents, lang)} {sub_word}" if cents else "")
        # French says "trois euros cinquante", or "cinquante centimes" below one euro
        if not _digits(int_part).strip("0") and cents:
            return f"{_words(cents, lang)} {sub_word}"
        return f"{main} {_plural(main, unit)}" + (f" {_words(cents, lang)}" if cents else "")
    amt = _amount(int_part, frac, lang)
    if lang == "fr" and re.search(r"\b(?:millions?|milliards?)$", amt):
        return f"{amt} {_fr_de(unit[1])}"
    amt = fem(amt)
    return f"{amt} {_plural(amt, unit)}"


# French also groups thousands with an ordinary space ("10 000", "1 500 000", "123 456 789").
# A run of three or more 3-digit groups is read as a list of numbers only when it looks like
# one: no group starts with 0 (a number written on its own never does, "123 100 000") and
# each group is within 10 of the previous one but not equal to it ("chambres 101 102 103",
# not "999 999 999 francs"). A number before the run with 4 digits or more is never part of
# it ("En 1870 300 000 soldats").
_FR_SPACED_RUN = re.compile(rf"(?<![\d{_GROUP}])(?<!\d[.,])\d{{1,3}}(?:[ {_GROUP}]\d{{3}})+(?!\d)")


def _group_fr_thousands(text: str) -> str:
    def group(m: re.Match) -> str:
        groups = re.split(rf"[ {_GROUP}]", m.group(0))
        if len(groups) >= 3 and len(groups[0]) == 3 and all(g[0] != "0" for g in groups) and all(
                0 < abs(int(a) - int(b)) <= 10 for a, b in zip(groups, groups[1:])):
            return m.group(0)
        return _GROUP.join(groups)

    return _FR_SPACED_RUN.sub(group, text)


def _number_pattern(lang: str) -> str:
    """A written integer. Thousands are grouped with commas in English, and in French with the
    typographic space that cleanup() and _group_fr_thousands() turn into _GROUP."""
    sep = f",{_GROUP}" if lang == "en" else _GROUP
    # A match never starts on a later group of a grouped number ("456" in "123,456"): a rule
    # that fails on the whole number would otherwise retry it from every group, which is
    # quadratic on a long run of groups.
    return rf"(?!(?<=\d[{sep}])\d{{3}}(?!\d))(?:\d{{1,3}}(?:[{sep}]\d{{3}})+(?!\d)|\d+)"


def _expand_roman(text: str, lang: str) -> str:
    """Roman numerals in running text: centuries, monarchs and numbered parts."""

    def value(tok: str, top: int) -> int | None:
        n = roman_to_int(tok)
        return n if n and n <= top else None

    if lang == "fr":
        # XIXe siècle, IIIe Reich, Ve République. Values above 40 are refused: "Le" and "Ce" are
        # L+e and C+e.
        def fr_roman_ord(m: re.Match) -> str:
            n = value(m.group(1), 40)
            if n is None:
                return m.group(0)
            return "premier" if n == 1 else _words(n, "fr", "ordinal")

        text = re.sub(r"\b([IVXL]+)(?:e|ème)\b", fr_roman_ord, text)
        text = re.sub(r"\b([A-ZÀ-Ý][a-zà-ÿ]+) Ier\b", r"\1 premier", text)  # François Ier

    def regnal(m: re.Match) -> str:
        n = value(m.group(2), 40)
        if n is None:
            return m.group(0)
        if lang == "fr":
            return f"{m.group(1)} {_words(n, 'fr')}"
        return f"{m.group(1)} the {_words(n, 'en', 'ordinal').title()}"

    # A lone I after a name is the pronoun ("when John I met") and a lone X is often an
    # anonymous person ("Marie X"), so single letters other than V are left alone. A lone V
    # followed by a period and a capitalised name is a middle initial ("George V. Higgins"),
    # unless that word opens a sentence ("under George V. He was king").
    starter = _EN_STARTER if lang == "en" else _FR_STARTER
    lone_v = rf"V(?!\.\s+(?!{starter}(?!\.))[A-ZÀ-Ý])"
    text = re.sub(rf"\b({_REGNAL_NAMES}) ([IVXL]{{2,}}|{lone_v})(?!\w)(?!-\w)", regnal, text)

    def numbered(m: re.Match) -> str:
        n = value(m.group(2), 399)
        return f"{m.group(1)} {_words(n, lang)}" if n else m.group(0)

    # English "part I think" is a pronoun, so a lone I needs punctuation after it ("Act I, Scene II").
    single_i = r"I(?=\s*[.,;:!?)]|\s*$)" if lang == "en" else "I"
    return re.sub(rf"\b({_NUMBERED[lang]}) ([IVXLC]{{2,}}|[VX]|{single_i})(?!\w)(?!-\w)", numbered, text)


def _en_time(h: int, mi: int, before_am_pm: bool = False) -> str:
    hour = _words(h, "en")
    if mi == 0:
        return hour if before_am_pm else f"{hour} o'clock"
    return f"{hour} {'oh ' + _words(mi, 'en') if mi < 10 else _words(mi, 'en')}"


_AM_PM = r"(?i:[ap]\.?m)\b"


def _expand_en_times(text: str) -> str:
    """10:30, 7pm, 10.30am, 10.30 p.m., at 4.50, from 9.15 to 10.45, the 4.50 from Paddington.

    A British dotted time ("at 10.30") is told from a decimal ("by 1.50 metres") by what
    surrounds it. Where the context is unclear the number is left to be read as a decimal.
    """

    def clock(m: re.Match) -> str:
        am_pm = re.match(rf"\s?{_AM_PM}", m.string[m.end():m.end() + 5]) is not None
        return (m.groupdict().get("pre") or "") + _en_time(int(m.group("h")), int(m.group("mi") or 0), am_pm)

    def in_context(m: re.Match) -> str:
        trigger = m.group("pre").strip().lower()
        verbs = _CHANGE_VERBS if trigger == "by" else _PRICE_VERBS if trigger == "at" else frozenset()
        words = _prev_words(m.string, m.start(), 1)
        if words and words[-1] in verbs:
            return m.group(0)
        return clock(m)

    def link(mid: str) -> str:
        return " to " if mid.strip() in {"-", "–"} else mid

    def pair(m: re.Match) -> str:
        words = _prev_words(m.string, m.start(), 1)
        if words and words[-1] in _CHANGE_VERBS:
            return m.group(0)
        if m.group("pre").strip().lower() == "between" and any(
                w.strip(".,;:!?") in _MEASURE_NOUNS for w in _prev_words(m.string, m.start(), 4)):
            return m.group(0)
        return (m.group("pre") + _en_time(int(m.group("h")), int(m.group("mi"))) + link(m.group("mid"))
                + _en_time(int(m.group("h2")), int(m.group("mi2"))))

    # In the contexts below the hour is never 0: "fell by 0.25" is a decimal.
    hour = r"(?:0?[1-9]|1\d|2[0-3])"
    pair_pre = rf"(?P<pre>\b(?i:from|between) )\b(?P<h>{hour})\.(?P<mi>[0-5]\d)"
    pair_mid = r"(?P<mid>\s?[-–]\s?|\s(?:to|till|until|and)\s)"
    # "from 10.30 to 11am", "between 2.30 and 4pm", "from 9.30-5.30pm": the am/pm of the second
    # half makes the first one a time too. Only the first half is read here, before the am/pm
    # rules below read the second.
    text = re.sub(rf"{pair_pre}{pair_mid}(?=(?:0?[1-9]|1[0-2])(?:[.:][0-5]\d)?\s?{_AM_PM})",
                  lambda m: m.group("pre") + _en_time(int(m.group("h")), int(m.group("mi"))) + link(m.group("mid")),
                  text)
    # glued am/pm: "10.30am" → "ten thirty am", "7pm" → "seven pm"
    text = re.sub(rf"(?<![\d.,:])\b(?P<h>0?[1-9]|1[0-2])(?:[:.](?P<mi>[0-5]\d))?(?={_AM_PM})",
                  lambda m: clock(m) + " ", text)
    text = re.sub(r"\b(?P<h>[01]?\d|2[0-3])[:h](?P<mi>[0-5]\d)\b", clock, text)
    dotted = r"\b(?P<h>[01]?\d|2[0-3])\.(?P<mi>[0-5]\d)\b(?![.,]\d)"
    text = re.sub(rf"{dotted}(?=\s?(?:{_AM_PM}|o'clock))", clock, text)
    not_measure = rf"(?!\s?{_UNIT_WORD})"
    text = re.sub(rf"{pair_pre}{pair_mid}\b(?P<h2>{hour})\.(?P<mi2>[0-5]\d)\b(?![.,]\d){not_measure}", pair, text)
    text = re.sub(rf"(?P<pre>\b(?i:at|by|until|till|past) )\b(?P<h>{hour})\.(?P<mi>[0-5]\d)\b(?![.,]\d)"
                  rf"{not_measure}", in_context, text)
    return re.sub(rf"(?P<pre>\b[Tt]he ){dotted}(?=\s+(?:from|to|train|express)\b)", clock, text)


# Words before "80s" that make it a decade: "the 80s", "his 30s", "the mid-80s", "the high 70s".
_DECADE_BEFORE = frozenset(
    "the his her their its my your our early mid late mid- early- late- high low upper lower roaring swinging".split()
)
# Words before "2000's" that make it a possessive ("the year 2000's events", "June 1940's
# armistice"). Anywhere else "1920's" is a decade: "the 1920's and 1930's", "his 1920's novels".
_YEAR_POSSESSIVE_BEFORE = frozenset(["year", *_MONTHS.lower().split("|")])


def _decade_context(m: re.Match) -> bool:
    """'80s, the 80s, his 30s, the mid-80s, the 1960s and 70s: a decade. "He gave me 10s" may be
    ten shillings, and "Route 80's" is a possessive, so a bare number is left alone."""
    words = _prev_words(m.string, m.start(), 2)
    last = words[-1] if words else ""
    if last in _DECADE_BEFORE:
        return True
    if re.fullmatch(r"'?\d0'?s,|\w+ties,", last):  # "the 30s, 40s and 50s"
        return True
    # "the 1960s–70s", "the 1950's-60's": the first decade was read by the year rule
    if re.fullmatch(r"(?:tens|twenties|thirties|forties|fifties|sixties|seventies|eighties|nineties)[-–/]", last):
        return True
    return (last in {"and", "or"} and len(words) == 2
            and re.fullmatch(r"'?\d*\d0'?s,?|\w+ties,?", words[0]) is not None)


def expand_numbers(text: str, lang: str) -> str:
    dec = r"\." if lang == "en" else r","
    num = _number_pattern(lang)
    mag_re = _MAGNITUDE[lang]
    if lang == "fr":
        text = _group_fr_thousands(text)

    def magnitude(m: re.Match) -> str | None:
        if m.group("mag"):
            return m.group("mag").lower()
        suf = m.group("suf") or m.groupdict().get("suf1")
        if not suf:
            return None
        word = _MAG_SUFFIX[lang][suf]
        if lang == "fr" and word != "mille" and _digits(m.group("ip")).lstrip("0") not in {"", "1"}:
            word += "s"
        return word

    def money(m: re.Match) -> str:
        spoken = _money(m.group("ip"), m.group("fr"), m.group("sym"), magnitude(m), lang)
        tail = m.groupdict().get("tail")
        if tail and re.sub(r"^\s(?:de\s|d')?", "", tail).lower() not in _UNITS[lang][m.group("sym")]:
            spoken += tail  # "$5 pounds" is not a repetition: keep the word
        return spoken

    if lang == "fr":
        # "5 €50" is five euros fifty (before the "€50" below is read as fifty euros)
        text = re.sub(rf"\b({num})\s?€(\d{{2}})\b", lambda m: _money(m.group(1), m.group(2), "€", None, lang), text)

    # currency before the amount ($5, £1,000.50, $5 million) and after (5 €, 10 $, 1,5 million €)
    text = re.sub(rf"(?P<sym>[$£€¥])\s?(?P<ip>{num})(?:{dec}(?P<fr>\d+))?(?:{mag_re})?{_MONEY_TAIL}", money, text)
    text = re.sub(rf"\b(?P<ip>{num})(?:{dec}(?P<fr>\d+))?(?:{mag_re})?\s?(?P<sym>[€$£¥])", money, text)

    # percentages
    def pct(m):
        return _amount(m.group(1), m.group(2), lang) + _SYMBOLS[lang]["%"]

    text = re.sub(rf"\b({num})(?:{dec}(\d+))?\s?%", pct, text)

    # ordinals
    if lang == "en":
        text = re.sub(rf"\b({num})(st|nd|rd|th)\b", lambda m: _cardinal(m.group(1), "en", "ordinal"), text)
    else:
        def fr_ord(m):
            if _digits(m.group(1)).lstrip("0") == "1":
                return "première" if m.group(2).lower() in {"re", "ère"} else "premier"
            return _cardinal(m.group(1), "fr", "ordinal")

        text = re.sub(rf"\b({num})(er|re|ère|e|ème|è)\b", fr_ord, text)
    text = _expand_roman(text, lang)

    # times: English in _expand_en_times; French 10:30, 10h30, 8 h 30, 10h
    if lang == "en":
        text = _expand_en_times(text)
    else:
        def fr_clock(m):
            h, mi = int(m.group("h")), int(m.group("mi") or 0)
            hs = "heure" if h <= 1 else "heures"
            return f"{_fr_fem(_words(h, 'fr'))} {hs}" + (f" {_fr_fem(_words(mi, 'fr'))}" if mi else "")

        text = re.sub(r"\b(?P<h>[01]?\d|2[0-3]):(?P<mi>[0-5]\d)\b", fr_clock, text)
        text = re.sub(rf"(?<![\d{_GROUP}]\s)(?<!{_GROUP})\b(?P<h>\d{{1,3}})\s?h(?:\s?(?P<mi>[0-5]\d))?\b",
                      fr_clock, text)

    # years (English reads 1873 as "eighteen seventy-three")
    if lang == "en":
        def year(m):
            w = _words(int(m.group("y")), "en", "year")
            s = m.group("s")
            if s == "'s" and _YEAR_POSSESSIVE_BEFORE.intersection(_prev_words(m.string, m.start(), 1)):
                w += "'s"  # a possessive ("the year 2000's events"); "the 1920's" is a decade
            elif s:  # decades: 1920s, the 1920's → nineteen twenties
                w = w[:-1] + "ies" if w.endswith("y") else w + "s"
            return (m.groupdict().get("pre") or "") + w

        text = re.sub(r"(?<![\d,.])\b(?P<y>1[1-9]\d\d|20\d\d)(?P<s>s|(?<=0)'s)?\b(?![\d,.]\d)", year, text)
        # 1000-1099 is read as a year only where a year is expected ("in 1066", "October 1066",
        # "1066 AD"); elsewhere it is a count ("1050 men").
        text = re.sub(rf"(?P<pre>\b(?:[Ii]n|[Ss]ince|[Uu]ntil|circa|AD|A\.D\.|{_MONTHS}) )"
                      r"(?P<y>10\d\d)(?P<s>s)?\b(?![\d,.]\d)", year, text)
        text = re.sub(r"(?<![\d,.])\b(?P<y>10\d\d)(?P<s>s)?\b(?=\s+(?:AD|A\.D\.|BC|B\.C\.|CE|BCE)(?!\w))",
                      year, text)

        # '80s, the 80s, his 30s → eighties, thirties; "10s 6d" (shillings and pence) is left alone
        decade_end = -1  # where the last number read as a decade ends

        def decade(m):
            nonlocal decade_end
            if re.match(r"\.?\s?\d{1,2}d\b", m.string[m.end():m.end() + 6]):
                return m.group(0)
            # "the 60s-70s", "the 60s/70s": the second half of a range is a decade when the first one was
            in_range = decade_end >= 0 and m.start() == decade_end + 1 and m.string[decade_end] in "-–/"
            if not m.group("apos") and not in_range and not _decade_context(m):
                return m.group(0)
            decade_end = m.end()
            w = _words(int(m.group("d")), "en")
            return w[:-1] + "ies" if w.endswith("y") else w + "s"

        text = re.sub(r"(?<![\w'])(?P<apos>')?(?P<d>[1-9]0)'?s\b", decade, text)

    # degrees: 30°C, 20 °F, 1°, 45°angle (after the years: "1200°C" is "twelve hundred degrees").
    # The scale is a separate word, never glued to "degrees". English uses the singular for one
    # only ("one degree", "a hundred and one degrees"); French for any amount below two ("un
    # degré", "un virgule cinq degré", "zéro degré").
    one, many = _DEGREE[lang]

    def degrees(m: re.Match) -> str:
        whole = _digits(m.group("ip")).lstrip("0")
        singular = whole in {"", "1"} if lang == "fr" else whole == "1" and not m.group("fr")
        scale = {"C": " Celsius", "F": " Fahrenheit"}.get(m.group("sc") or "", "")
        glue = " " if m.string[m.end():m.end() + 1].isalnum() else ""
        return f"{_amount(m.group('ip'), m.group('fr'), lang)} {one if singular else many}{scale}{glue}"

    text = re.sub(rf"\b(?P<ip>{num})(?:{dec}(?P<fr>\d+))?\s?°(?:\s?(?P<sc>[CF])\b)?", degrees, text)

    # decimals then plain integers
    text = re.sub(rf"\b({num}){dec}(\d+)\b", lambda m: _decimal(m.group(1), m.group(2), lang), text)
    text = re.sub(rf"\b({num})\b", lambda m: _cardinal(m.group(1), lang), text)
    # _number_pattern never starts on a 3-digit group after "digit,", so a group that was not part
    # of a grouped number ("In 1990,500 soldiers") is still left: read it on its own.
    text = re.sub(r"\b\d+\b", lambda m: _cardinal(m.group(0), lang), text)
    return text.replace(_GROUP, " ")


def expand_symbols(text: str, lang: str) -> str:
    many = _DEGREE[lang][1]

    def degrees(m: re.Match) -> str:
        scale = {"C": " Celsius", "F": " Fahrenheit"}.get(m.group(1) or "", "")
        glue = " " if m.string[m.end():m.end() + 1].isalnum() else ""
        return f" {many}{scale}{glue}"

    # A degree sign after a number is read in expand_numbers; any other one is a plain "degrees".
    text = re.sub(r"\s?°(?:\s?([CF])\b)?", degrees, text)
    for sym, word in _SYMBOLS[lang].items():
        if sym == "+":
            text = re.sub(r"(?<=\w)\s*\+\s*(?=\w)", word, text)
        elif sym == "=":
            text = re.sub(r"\s*=\s*", word, text)
        else:
            text = text.replace(sym, word)
    return re.sub(r"\s+", " ", text)


# ----------------------------------------------------------------------------- headings

_HEADING_NUM = re.compile(
    r"^(?P<word>(?i:chapter|chapitre|book|livre|part|partie|volume|tome|canto|act|acte|scene|scène))?\s*"
    r"(?P<num>[IVXLCDM]+|\d{1,3})(?P<punct>[.:—–-]?)(?=\s|$)\s*(?P<rest>.*)$"
)


def heading_to_speech(text: str, lang: str) -> str:
    """'CHAPTER XLV.' → 'Chapter forty-five.'; 'XII OÙ PHILEAS…' → 'Douze. Où Phileas…'.

    Roman numerals must be upper case in the source. Without a word such as
    "Chapter", only values up to 100 count, and an English bare "I" needs
    punctuation after it, so "I Remember Mama" or "DIX ANS" stay words.
    """
    t = text.strip()
    m = _HEADING_NUM.match(t)
    if m:
        tok, word, punct, rest = m.group("num"), m.group("word"), m.group("punct"), m.group("rest").strip()
        n = int(tok) if tok.isdigit() else roman_to_int(tok)
        ok = n is not None and n > 0
        if ok and not word:
            if n > 100:
                ok = False
            elif tok == "I" and lang == "en" and rest and not punct:
                ok = False
        if ok:
            if _mostly_upper(rest):
                rest = sentence_case(rest)
            spoken = _words(n, lang)
            head = f"{word.capitalize()} {spoken}" if word else spoken.capitalize()
            return head + "." + (" " + rest[0].upper() + rest[1:] if rest else "")
    return sentence_case(t) if _mostly_upper(t) else t


# ----------------------------------------------------------------------------- entry points

def normalize_paragraph(text: str, lang: str, rules: Rules | None = None, is_heading: bool = False,
                        is_section_opening: bool = False) -> str:
    """Normalise one paragraph.

    is_section_opening marks the first body paragraph of a section, the only
    place where books set the opening words in small caps ("HAPPY for all").
    """
    lang = "fr" if lang == "fr" else "en"
    t = cleanup(text)
    if not t:
        return ""
    if is_heading:
        t = heading_to_speech(t, lang)
    elif _mostly_upper(t) and len(t.split()) >= 3:
        t = sentence_case(t)
    elif is_section_opening:
        t = fix_small_caps_opening(t)
    t = expand_abbreviations(t, lang)
    t = expand_numbers(t, lang)
    t = expand_symbols(t, lang)
    if rules:
        t = rules.apply(t)
    t = re.sub(r"\s+([,.;:!?])", r"\1", t) if lang == "en" else t
    t = re.sub(r"\s+", " ", t).strip()
    if is_heading and t and t[-1] not in ".!?…":
        t += "."
    return t


def _fold(text: str) -> str:
    """Words only, case-folded: 'CHAPTER I.' and 'Chapter I' fold to the same string."""
    return " ".join(re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", text).casefold()))


def _is_title(paragraph: str, title: str, lang: str, rules: Rules | None) -> bool:
    if not _fold(title):
        return False
    if _fold(paragraph) == _fold(title):
        return True
    # "CHAPTER III" in the text, "Chapter 3" in the table of contents
    spoken = normalize_paragraph(paragraph, lang, rules, is_heading=True)
    return _fold(spoken) == _fold(normalize_paragraph(title, lang, rules, is_heading=True))


# Ingest names an untitled section after the first 60 characters of its text. A shorter
# title that is a prefix of the first word is a real one ("Spring" before "Springfield…").
_CUT_TITLE_MIN = 40


def _is_cut_from(paragraph: str, title: str) -> bool:
    """True for a title made of the paragraph's opening characters, cut anywhere: mid-word ("…the
    clocks were strik"), between words or after punctuation ("…III., IV.,"). The paragraph says
    such a title in full, so nothing is lost when it is not spoken on its own."""
    if len(title) < _CUT_TITLE_MIN:
        return False
    p, t = " ".join(paragraph.split()), " ".join(title.split())
    return bool(t) and len(p) > len(t) and p.startswith(t)


def normalize_section(paragraphs: list[str], lang: str, starts_with_heading: bool, title: str,
                      rules: Rules | None = None) -> list[str]:
    """Normalise a section; speak the title first when the text does not start with it."""
    out: list[str] = []
    if not starts_with_heading and title and paragraphs:
        if _is_title(paragraphs[0], title, lang, rules):
            starts_with_heading = True  # the title is styled as an ordinary paragraph: speak it once, as a heading
        elif _is_cut_from(paragraphs[0], title):
            title = ""  # a fallback title cut from the text itself: the paragraph says it in full
    if not starts_with_heading and title:
        h = normalize_paragraph(title, lang, rules, is_heading=True)
        if h:
            out.append(h)
    opening = True
    for i, p in enumerate(paragraphs):
        heading = i == 0 and starts_with_heading
        n = normalize_paragraph(p, lang, rules, is_heading=heading, is_section_opening=opening and not heading)
        if n:
            out.append(n)
            if not heading:
                opening = False  # small caps only open the first body paragraph
    return out
