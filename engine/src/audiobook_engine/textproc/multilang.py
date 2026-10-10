"""Text normalisation for the eleven languages beyond English and French.

es, de, it, pt, ru, zh, ja, ko, hi, ar, nl. `normalize.py` dispatches here when the language is one of
them; English and French never reach this module. Numbers are spelled by num2words (registry code in
languages.py) except Chinese (zhnum.py) and Hindi (left as digits: num2words has no Hindi). Every rule is
deterministic. Where a form could not be verified the text is left unchanged (see the notes at each table).
"""

from __future__ import annotations

import re
from functools import lru_cache

from num2words import num2words

from .. import languages as _languages
from . import normalize as N
from . import zhnum

NEW_LANGS = ("es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl")
_G = N._GROUP

# Languages that write 1.234,56 (thousands '.', decimal ','); the others write 1,234.56.
_COMMA_DEC = frozenset({"es", "de", "it", "pt", "ru", "nl"})
# Languages whose digits touch letters of another script ("3명", "2024年", "ال5"): numbers are cut at ASCII
# letters only. For the others a number glued to any letter ("5m", "A4", "5м") is left alone, as in English.
_ASCII_EDGE = frozenset({"zh", "ja", "ko", "ar", "hi"})


def resolve(lang: str | None) -> str | None:
    """The registry code when `lang` is one of the eleven new languages, else None (English/French path)."""
    if not lang or lang in ("en", "fr"):
        return None
    code = _languages.normalize_code(lang)
    return code if code in NEW_LANGS else None


# ----------------------------------------------------------------------------- cleanup

_BIDI = dict.fromkeys(map(ord, "\u200e\u200f\u061c\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069"))  # LRM RLM ALM LRE RLE PDF LRO RLO LRI RLI FSI PDI
_AR_DIGITS = {ord(c): str(i) for i, c in enumerate("٠١٢٣٤٥٦٧٨٩")}
_AR_DIGITS.update({ord(c): str(i) for i, c in enumerate("۰۱۲۳۴۵۶۷۸۹")})  # Persian / Urdu


def to_western_digits(text: str) -> str:
    """Arabic-Indic and Persian digits -> 0-9; the Arabic decimal and thousands marks between digits -> . ,"""
    text = text.translate(_AR_DIGITS)
    text = re.sub(r"(?<=\d)٫(?=\d)", ".", text)
    text = re.sub(r"(?<=\d)٬(?=\d)", ",", text)
    return text.replace("٪", "%")


def _fullwidth_to_ascii(text: str) -> str:
    """Full-width digits and Latin letters (and ％ ＋ ＝ ＄ ＆) -> ASCII; ．，： between digits too."""
    # a full-width comma, full stop or colon between full-width digits belongs to the number ("１，０００"),
    # between ASCII digits it is a list separator ("3.5，10%")
    text = re.sub(r"(?<=[０-９])([．，：])(?=[０-９])", lambda m: {"．": ".", "，": ",", "：": ":"}[m.group(1)], text)
    out = []
    for ch in text:
        o = ord(ch)
        if 0xFF10 <= o <= 0xFF19 or 0xFF21 <= o <= 0xFF3A or 0xFF41 <= o <= 0xFF5A or ch in "％＋＝＄＆":
            out.append(chr(o - 0xFEE0))
        else:
            out.append(ch)
    return "".join(out)


def cleanup_ml(text: str, lang: str) -> str:
    text = text.translate(_BIDI)
    if lang == "ar":
        text = text.replace("ـ", "")  # tatweel; the diacritics are kept
        text = to_western_digits(text)
    elif lang in ("zh", "ja"):
        text = _fullwidth_to_ascii(text)
        # the generic clean-up turns “ ” into one straight quote, which no longer tells an opening quote from
        # a closing one; without spaces to help, the segmenter needs the direction: corner brackets keep it
        text = text.replace("“", "「").replace("”", "」").replace("‘", "『").replace("’", "』")
    elif lang == "hi":
        # a vertical bar between Devanagari words is the danda typed on a Latin keyboard
        text = re.sub(r"(?<=[ऀ-ॿ0-9]) ?\|(?= ?[ऀ-ॿ]| ?$)", "।", text)
    return N.cleanup(text)


# ----------------------------------------------------------------------------- casing

_TERMINATORS = ".!?…。！？؟۔।॥"


def _upper_first(s: str) -> str:
    return s[:1].upper() + s[1:]


def sentence_case_ml(text: str) -> str:
    """Lower-case everything, then capitalise the first letter of each sentence (any cased script)."""
    low = text.lower()
    return re.sub(r"(^|[.!?¿¡]\s+)(\S)", lambda m: m.group(1) + m.group(2).upper(), low)


_ACRONYMS_ML = frozenset({
    "NASA", "NATO", "UNO", "USA", "EU", "UE", "UN", "ONU", "EUA", "FBI", "CIA", "BBC", "CNN", "KGB", "TV", "DNA",
    "EG", "UdSSR", "СССР", "США", "ООН", "НАТО", "ЕС", "РФ", "ДНК", "ТВ", "OTAN", "EEUU", "BRD", "DDR", "ZDF", "ARD",
    "OMS", "WHO", "UNESCO", "ФБР", "ЦРУ", "КГБ", "МИД", "МВД", "ВОЗ", "ЮНЕСКО",
})


def fix_small_caps_opening_ml(text: str) -> str:
    """'MIJN vader was' -> 'Mijn vader was': the opening run (1-4) of upper-case words before a lower-case one."""
    toks = text.split(" ")
    i = 0
    while i < len(toks) and i < 4:
        core = toks[i].strip("\"'(«„¿¡")
        letters = [c for c in core if c.isalpha()]
        if len(letters) >= 2 and core.isupper() and all(c.isalpha() or c in "'’.-" for c in core):
            i += 1
        else:
            break
    if i == 0 or i >= len(toks):
        return text
    nxt = next((c for c in toks[i] if c.isalpha()), "")
    if not nxt.islower():
        return text
    if i == 1 and toks[0].strip("\"'(«„¿¡") in _ACRONYMS_ML:
        return text
    fixed = [re.sub(r"[^\W\d_]+", lambda w: w.group(0).capitalize(), t) for t in toks[:i]]
    return " ".join(fixed + toks[i:])


# ----------------------------------------------------------------------------- number words

def _code(lang: str) -> str:
    return _languages.LANGUAGES[lang].num2words  # type: ignore[return-value]


def words(n: int, lang: str, to: str = "cardinal", **kw) -> str:
    if lang == "zh":
        return zhnum.cardinal(n) if to == "cardinal" else zhnum.ordinal_number(n)
    if lang == "ja":
        to = "cardinal"  # 第N章: the number is a plain cardinal in Japanese (num2words would add 番目)
    spoken = num2words(n, lang=_code(lang), to=to, **kw)
    # num2words writes Brazilian numbers with commas ("mil, duzentos e cinquenta"): not a spoken pause
    return spoken.replace(", ", " ") if lang == "pt" else spoken


def digit_names(lang: str) -> list[str]:
    if lang == "zh":
        return list(zhnum.DIGITS)
    return [words(d, lang) for d in range(10)]


def digit_by_digit(digits: str, lang: str) -> str:
    names = digit_names(lang)
    sep = "" if lang in ("zh", "ja") else " "
    return sep.join(names[int(d)] for d in digits if d.isdigit())


_MAX_DIGITS = N._MAX_DIGITS
_MAX_GROUPED_DIGITS = N._MAX_GROUPED_DIGITS


def say(digits: str, lang: str, grouped: bool = False, to: str = "cardinal", **kw) -> str:
    """Speak a written integer (digits only). Long digit strings are read digit by digit."""
    significant = digits.lstrip("0")
    limit = _MAX_GROUPED_DIGITS if grouped else _MAX_DIGITS
    if lang == "zh":
        limit = min(limit, 15)
    if len(significant) > limit:
        return digit_by_digit(digits, lang)
    try:
        return words(int(significant or "0"), lang, to, **kw)
    except (OverflowError, ValueError, KeyError, NotImplementedError):
        return digit_by_digit(digits, lang)


def parse_num(tok: str, lang: str):
    """A written number -> (integer digits, fraction digits or None, grouped) or None when it is not one
    number (a date "12.05.2024", an address "1.2.3", a list "1,2,3")."""
    grouped = _G in tok
    t = tok.replace(_G, "")
    if not re.fullmatch(r"[0-9]+(?:[.,][0-9]+)*", t):
        return None
    if "." not in t and "," not in t:
        return t, None, grouped
    cd = lang in _COMMA_DEC
    if "." in t and "," in t:
        last = max(t.rfind("."), t.rfind(","))
        dec = t[last]
        grp = "," if dec == "." else "."
        ip, fr = t[:last], t[last + 1:]
        if re.fullmatch(rf"[0-9]{{1,3}}(?:\{grp}[0-9]{{3}})+", ip) and fr:
            return ip.replace(grp, ""), fr, True
        return None
    seps = re.findall(r"[.,]", t)
    sep = seps[0]
    if len(seps) == 1:
        a, b = t.split(sep)
        group_like = len(b) == 3 and 1 <= len(a) <= 3 and not a.startswith("0")
        if cd:
            if sep == ",":
                return a, b, grouped
            return (a + b, None, True) if group_like else (a, b, grouped)
        if sep == ".":
            return a, b, grouped
        if group_like:
            return a + b, None, True
        return (a, b, grouped) if lang == "ar" else None
    if re.fullmatch(rf"[0-9]{{1,3}}(?:\{sep}[0-9]{{3}})+", t) and sep == ("." if cd else ","):
        return t.replace(sep, ""), None, True
    return None


def _fallback_parts(tok: str, lang: str) -> str:
    """Read the pieces of something that is not one number, keeping a comma as a pause."""
    parts = re.split(r"([.,])", tok.replace(_G, ""))
    out = ""
    for p in parts:
        if p.isdigit():
            out += say(p, lang)
        elif p == ",":
            out += ", "
        else:
            out += " "
    return out.strip()


_DEC_SEP = {"es": "coma", "de": "Komma", "it": "virgola", "pt": "vírgula", "nl": "komma", "ja": "点", "ko": "점",
            "zh": "点", "ar": "فاصلة"}


def decimal_words(ip: str, frac: str, lang: str, grouped: bool = False) -> str:
    """'3', '14' -> 'tres coma catorce' / 'drei Komma eins vier' / 'три целых четырнадцать сотых'."""
    ip = ip or "0"
    if lang == "ru":
        if len(frac) <= 6 and len(ip.lstrip("0")) <= _MAX_DIGITS:
            try:
                return num2words(f"{int(ip)}.{frac}", lang="ru")
            except (ValueError, OverflowError, KeyError, NotImplementedError):
                pass
        return f"{say(ip, 'ru', grouped, gender='f')} запятая {digit_by_digit(frac, 'ru')}"
    if lang == "zh":
        return zhnum.decimal(ip, frac) if len(ip.lstrip("0")) <= 15 else f"{say(ip, 'zh', grouped)}点{zhnum.digits(frac)}"
    whole = say(ip, lang, grouped)
    sep = _DEC_SEP[lang]
    rest = frac.lstrip("0")
    if lang in ("es", "it", "pt") and len(rest) <= 3:
        zero = words(0, lang)
        frac_words = " ".join([zero] * (len(frac) - len(rest)) + ([words(int(rest), lang)] if rest else []))
    else:
        frac_words = digit_by_digit(frac, lang)
    if lang == "ja":
        return f"{whole}{sep}{frac_words}"
    return f"{whole} {sep} {frac_words}"


def amount_words(ip: str, frac: str | None, lang: str, grouped: bool = False) -> str:
    return decimal_words(ip, frac, lang, grouped) if frac else say(ip, lang, grouped)


# Slavic plural: 1 -> one, 2-4 -> few, else many
def ru_plural(n: int, forms: tuple[str, str, str]) -> str:
    if 10 < n % 100 < 15:
        return forms[2]
    return forms[0] if n % 10 == 1 else forms[1] if 2 <= n % 10 <= 4 else forms[2]


def _int_or_none(digits: str) -> int | None:
    d = digits.lstrip("0")
    return int(d or "0") if len(d) <= 12 else None


# ----------------------------------------------------------------------------- abbreviations
#
# Only forms that are unambiguous in the language. Replacements keep the capital of the source
# ("Sr." -> "Señor", "z. B." -> "zum Beispiel", "Z. B." -> "Zum Beispiel"), so a sentence that starts with
# an abbreviation still starts with a capital letter and the segmenter still splits before it.

_ES_UP = "A-ZÁÉÍÓÚÑÜ"
_DE_UP = "A-ZÄÖÜ"
_IT_UP = "A-ZÀ-Ý"
_PT_UP = "A-ZÁÀÂÃÉÊÍÓÔÕÚÇ"
_RU_UP = "А-ЯЁ"
_NL_UP = "A-Z"


def _keep(pattern: str, rep: str, upper: str) -> list[tuple[str, str]]:
    """An abbreviation that can end a sentence ("etc.", "usw."): the period stays before a new sentence."""
    return [(rf"{pattern}(?=\s+[\"'(«¿¡—–-]?\s*[{upper}]|\s*$)", rep + "."), (pattern, rep)]


_ABBR: dict[str, list[tuple[str, str]]] = {
    "es": [
        (r"\bSres\.", "señores"), (r"\bSras\.", "señoras"), (r"\bSra\.", "señora"), (r"\bSrta\.", "señorita"),
        (r"\bSr\.", "señor"), (r"\bDña\.", "doña"), (r"\bDra\.(?=\s+[A-ZÁÉÍÓÚÑ])", "doctora"),
        (r"\bDr\.(?=\s+[A-ZÁÉÍÓÚÑ])", "doctor"), (r"\bProfa\.", "profesora"), (r"\bProf\.", "profesor"),
        (r"\bUds\.", "ustedes"), (r"\bUd\.", "usted"), (r"\bAvda\.", "avenida"), (r"\bAv\.", "avenida"),
        (r"\bGral\.", "general"), (r"\bExcmo\.", "excelentísimo"), (r"\bExcma\.", "excelentísima"),
        (r"\bIlmo\.", "ilustrísimo"), (r"\bLic\.(?=\s+[A-ZÁÉÍÓÚÑ])", "licenciado"),
        (r"\bIng\.(?=\s+[A-ZÁÉÍÓÚÑ])", "ingeniero"), (r"\bSta\.(?=\s+[A-ZÁÉÍÓÚÑ])", "santa"),
        (r"\bSto\.(?=\s+[A-ZÁÉÍÓÚÑ])", "santo"), (r"\bvs\.", "versus"),
        (r"\bpágs\.(?=\s*\d)", "páginas"), (r"\bpág\.(?=\s*\d)", "página"), (r"\bpp\.(?=\s*\d)", "páginas"),
        (r"\bp\.(?=\s*\d)", "página"), (r"\bcap\.(?=\s*[\dIVXLC])", "capítulo"), (r"\bart\.(?=\s*\d)", "artículo"),
        (r"\bnúm\.(?=\s*\d)", "número"), (r"\b[Nn]\.?[º°]\s*(?=\d)", "número "),
        (r"\bp\. ?ej\.", "por ejemplo"), (r"\baprox\.", "aproximadamente"),
        *_keep(r"\ba\. ?C\.", "antes de Cristo", _ES_UP), *_keep(r"\bd\. ?C\.", "después de Cristo", _ES_UP),
        *_keep(r"\bEE\. ?UU\.", "Estados Unidos", _ES_UP), *_keep(r"\betc\.", "etcétera", _ES_UP),
    ],
    "de": [
        (r"\bHrn\.", "Herrn"), (r"\bHr\.(?=\s+[A-ZÄÖÜ])", "Herr"), (r"\bFrl\.(?=\s+[A-ZÄÖÜ])", "Fräulein"),
        (r"\bFr\.(?=\s+[A-ZÄÖÜ])", "Frau"),
        (r"\bDr\. ?med\.", "Doktor der Medizin"), (r"\bDr\. ?phil\.", "Doktor der Philosophie"),
        (r"\bDr\. ?rer\. ?nat\.", "Doktor der Naturwissenschaften"), (r"\bDr\.(?=\s+[A-ZÄÖÜ])", "Doktor"),
        (r"\bProf\.(?=\s)", "Professor"), (r"\bSt\.(?=\s+[A-ZÄÖÜ])", "Sankt"),
        (r"\bz\. ?B\.", "zum Beispiel"), (r"\bd\. ?h\.", "das heißt"),
        (r"\bu\. ?U\.", "unter Umständen"), (r"\bi\. ?d\. ?R\.", "in der Regel"),
        (r"\bz\. ?T\.", "zum Teil"), (r"\bz\. ?Z\.", "zurzeit"),
        *_keep(r"\bu\. ?a\.", "unter anderem", _DE_UP), *_keep(r"\bo\. ?ä\.", "oder ähnliches", _DE_UP),
        *_keep(r"\bs\. ?o\.", "siehe oben", _DE_UP), *_keep(r"\bs\. ?u\.", "siehe unten", _DE_UP),
        *_keep(r"\bv\. ?Chr\.", "vor Christus", _DE_UP), *_keep(r"\bn\. ?Chr\.", "nach Christus", _DE_UP),
        (r"\bbzw\.", "beziehungsweise"), (r"\bca\.", "circa"), (r"\bvgl\.", "vergleiche"),
        (r"\bNr\.(?=\s*\d)", "Nummer"), (r"\bevtl\.", "eventuell"), (r"\binkl\.", "inklusive"),
        (r"\bggf\.", "gegebenenfalls"), (r"\bMio\.", "Millionen"), (r"\bMrd\.", "Milliarden"),
        *_keep(r"\bJh\.", "Jahrhundert", _DE_UP), (r"\bgeb\.(?=\s)", "geboren"), (r"\bgest\.(?=\s)", "gestorben"),
        (r"\bMwSt\.", "Mehrwertsteuer"), (r"(?<=[a-zäöüß])str\.", "straße"), (r"\bStr\.", "Straße"),
        *_keep(r"\bu\. ?s\. ?w\.", "und so weiter", _DE_UP), *_keep(r"\busw\.", "und so weiter", _DE_UP),
        *_keep(r"\betc\.", "et cetera", _DE_UP),
    ],
    "it": [
        (r"\bSig\. ?ra\b\.?", "signora"), (r"\bSig\. ?na\b\.?", "signorina"), (r"\bSig\.(?=\s+[A-ZÀ-Ý])", "signor"),
        (r"\bDott\. ?ssa\b\.?", "dottoressa"), (r"\bDott\.(?=\s+[A-ZÀ-Ý])", "dottor"),
        (r"\bProf\. ?ssa\b\.?", "professoressa"), (r"\bProf\.(?=\s+[A-ZÀ-Ý])", "professor"),
        (r"\bIng\.(?=\s+[A-ZÀ-Ý])", "ingegner"), (r"\bAvv\.(?=\s+[A-ZÀ-Ý])", "avvocato"),
        (r"\bGeom\.(?=\s+[A-ZÀ-Ý])", "geometra"), (r"\bcfr\.", "confronta"), (r"\bvs\.", "versus"),
        (r"\bp\. ?es\.", "per esempio"), (r"\bpagg\.(?=\s*\d)", "pagine"), (r"\bpag\.(?=\s*\d)", "pagina"),
        (r"\bcap\.(?=\s*[\dIVXLC])", "capitolo"), (r"\bsec\.(?=\s*[\dIVXLC])", "secolo"),
        (r"\bart\.(?=\s*\d)", "articolo"), (r"\bn\.(?=\s*\d)", "numero"), (r"\b[Nn][°º]\s*(?=\d)", "numero "),
        (r"\bca\.(?=\s*\d)", "circa"), *_keep(r"\ba\. ?C\.", "avanti Cristo", _IT_UP),
        *_keep(r"\bd\. ?C\.", "dopo Cristo", _IT_UP), *_keep(r"\becc\.", "eccetera", _IT_UP),
    ],
    "pt": [
        (r"\bSra\.", "senhora"), (r"\bSrta\.", "senhorita"), (r"\bSr\.", "senhor"),
        (r"\bDra\.(?=\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ])", "doutora"), (r"\bDr\.(?=\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ])", "doutor"),
        (r"\bProfa\.", "professora"), (r"\bProf\.", "professor"), (r"\bAv\.", "avenida"),
        (r"\bExmo\.", "excelentíssimo"), (r"\bExma\.", "excelentíssima"), (r"\bLtda\.", "limitada"),
        (r"\bCia\.", "companhia"), (r"\bSto\.(?=\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ])", "santo"),
        (r"\bSta\.(?=\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ])", "santa"), (r"\bvs\.", "versus"), (r"\baprox\.", "aproximadamente"),
        (r"\bp\. ?ex\.", "por exemplo"), (r"\bpágs\.(?=\s*\d)", "páginas"), (r"\bpág\.(?=\s*\d)", "página"),
        (r"\bpp\.(?=\s*\d)", "páginas"), (r"\bp\.(?=\s*\d)", "página"), (r"\bcap\.(?=\s*[\dIVXLC])", "capítulo"),
        (r"\bart\.(?=\s*\d)", "artigo"), (r"\b[Nn]\.?[º°]\s*(?=\d)", "número "),
        *_keep(r"\ba\. ?C\.", "antes de Cristo", _PT_UP), *_keep(r"\bd\. ?C\.", "depois de Cristo", _PT_UP),
        *_keep(r"\betc\.", "etcétera", _PT_UP),
    ],
    "nl": [
        (r"\bDhr\.", "de heer"), (r"\bMevr\.", "mevrouw"), (r"\bMw\.", "mevrouw"), (r"\bDrs\.", "doctorandus"),
        (r"\bDr\.(?=\s+[A-Z])", "doctor"), (r"\bIr\.(?=\s+[A-Z])", "ingenieur"), (r"\bProf\.", "professor"),
        (r"\bbijv\.", "bijvoorbeeld"), (r"\bbv\.", "bijvoorbeeld"),
        (r"\bd\. ?w\. ?z\.", "dat wil zeggen"), (r"\bm\. ?b\. ?t\.", "met betrekking tot"),
        (r"\bt\. ?o\. ?v\.", "ten opzichte van"), (r"\bn\. ?a\. ?v\.", "naar aanleiding van"),
        (r"\bi\. ?v\. ?m\.", "in verband met"), (r"\ba\. ?u\. ?b\.", "alstublieft"),
        (r"\bt\. ?a\. ?v\.", "ter attentie van"), (r"\bnr\.(?=\s*\d)", "nummer"), (r"\bblz\.(?=\s*\d)", "bladzijde"),
        (r"\bca\.", "circa"), (r"\bong\.", "ongeveer"),
        *_keep(r"\bv\. ?Chr\.", "voor Christus", _NL_UP), *_keep(r"\bn\. ?Chr\.", "na Christus", _NL_UP),
        *_keep(r"\bo\. ?a\.", "onder andere", _NL_UP), *_keep(r"\benz\.", "enzovoort", _NL_UP),
    ],
    "ru": [
        (r"\bг-н\b\.?", "господин"), (r"\bг-жа\b\.?", "госпожа"), (r"\bд-р\b\.?", "доктор"),
        (r"\bпроф\.", "профессор"), (r"\bакад\.", "академик"), (r"\bим\.(?=\s+[А-ЯЁ])", "имени"),
        (r"\bнапр\.", "например"), (r"\bстр\.(?=\s*\d)", "страница"), (r"\bрис\.(?=\s*\d)", "рисунок"),
        (r"\bгл\.(?=\s*\d)", "глава"), (r"\bт\.(?=\s*\d)", "том"),
        (r"\bт\. ?е\.", "то есть"), (r"\bт\. ?к\.", "так как"),
        *_keep(r"\bи т\. ?п\.", "и тому подобное", _RU_UP), *_keep(r"\bи др\.", "и другие", _RU_UP),
        *_keep(r"\bи пр\.", "и прочие", _RU_UP),
        *_keep(r"\bи т\. ?д\.", "и так далее", _RU_UP),
        # "г." is a city before a capitalised name (_ru_city) and a year after a number (_ru_years)
        (r"(?<!\d)(?<!\d\s)\bсм\.(?=\s+[\w«\"(])", "смотри"),
    ],
    "ja": [("㈱", "株式会社"), ("㈲", "有限会社")],
    "ko": [("㈜", "주식회사")],
    "ar": [(r"إلخ", "إلى آخره"), (r"(?<![ء-ي])الخ(?![ء-ي])", "إلى آخره")],
    "hi": [(r"डॉ\.", "डॉक्टर"), (r"प्रो\.", "प्रोफेसर")],
    "zh": [],
}


def _both_cases(pattern: str) -> str:
    r"""\bпроф\. -> \b[Пп]роф\. (a Russian abbreviation may open a sentence)."""
    m = re.match(r"\\b([а-яё])", pattern)
    return pattern if not m else pattern[:2] + f"[{m.group(1).upper()}{m.group(1)}]" + pattern[3:]


_ABBR_RE = {lang: [(re.compile(_both_cases(p) if lang == "ru" else p), r) for p, r in rules]
            for lang, rules in _ABBR.items()}


def _case_follow(m: re.Match, rep: str) -> str:
    return _upper_first(rep) if m.group(0)[:1].isupper() and rep[:1].islower() else rep


def expand_abbreviations_ml(text: str, lang: str) -> str:
    for rx, rep in _ABBR_RE.get(lang, ()):
        text = rx.sub(lambda m, rep=rep: _case_follow(m, rep), text)
    if lang == "es":
        text = _es_don(text)
    if lang == "ru":
        text = _ru_street(text)
        text = _ru_city(text)
    return text


def _es_don(text: str) -> str:
    """'D. Quijote' -> 'Don Quijote', but not a middle initial ('Pedro D. Fernández'): D. is a title only at
    the start of a sentence or after a lower-case word ('el D. Quijote', 'señor D. Pedro')."""

    def sub(m: re.Match) -> str:
        before = text[:m.start()].rstrip()
        prev = before.split(" ")[-1] if before else ""
        if prev and prev[-1] not in ".!?:;—«\"(¿¡" and not prev[0].islower():
            return m.group(0)
        return "Don"

    return re.sub(r"\bD\.(?=\s+[A-ZÁÉÍÓÚÑ][a-záéíóúñ]{2,})", sub, text)


_RU_STREET_GEN = frozenset({"с", "со", "от", "у", "до", "из", "около", "для", "без", "после"})
_RU_STREET_LOC = frozenset({"в", "на", "по", "о", "об", "при", "к", "ко"})


def _ru_city(text: str) -> str:
    """'г. Москва' -> 'город Москва'; the noun takes the case of the preposition before it: 'в г. Москве' ->
    'в городе Москве', 'из г. Москвы' -> 'из города Москвы'. 'г.' after a number is a year, not read here."""

    def sub(m: re.Match) -> str:
        words = text[:m.start()].split()
        prev = words[-1].lower().strip("«\"(") if words else ""
        nxt = m.group("next")
        if prev in ("в", "во", "на", "о", "об", "при") and nxt.endswith(("е", "и")):
            noun = "городе"
        elif prev in _RU_STREET_GEN:
            noun = "города"
        else:
            noun = "город"
        return f"{noun} {nxt}"

    return re.sub(r"(?<![\w.])(?<!\d)(?<!\d )г\. (?P<next>[А-ЯЁ][а-яё-]*)", sub, text)


def _ru_street(text: str) -> str:
    def sub(m: re.Match) -> str:
        words = text[:m.start()].split()
        prev = words[-1].lower().strip("«\"(") if words else ""
        return "улицы" if prev in _RU_STREET_GEN else "улице" if prev in _RU_STREET_LOC else "улица"

    return re.sub(r"(?<![\w.])ул\.(?=\s+[А-ЯЁ])", sub, text)


# ----------------------------------------------------------------------------- currency

# unit singular, plural, feminine?, subunit singular, plural (None: no spoken subunit)
_CUR: dict[str, dict[str, tuple]] = {
    "es": {"€": ("euro", "euros", False, "céntimo", "céntimos"), "$": ("dólar", "dólares", False, "centavo", "centavos"),
           "£": ("libra", "libras", True, "penique", "peniques"), "¥": ("yen", "yenes", False, None, None),
           "￥": ("yen", "yenes", False, None, None), "₩": ("won", "wones", False, None, None)},
    "de": {"€": ("Euro", "Euro", False, "Cent", "Cent"), "$": ("Dollar", "Dollar", False, "Cent", "Cent"),
           "£": ("Pfund", "Pfund", False, None, None), "¥": ("Yen", "Yen", False, None, None),
           "￥": ("Yen", "Yen", False, None, None), "₩": ("Won", "Won", False, None, None)},
    "it": {"€": ("euro", "euro", False, "centesimo", "centesimi"), "$": ("dollaro", "dollari", False, "centesimo", "centesimi"),
           "£": ("sterlina", "sterline", True, None, None), "¥": ("yen", "yen", False, None, None),
           "￥": ("yen", "yen", False, None, None), "₩": ("won", "won", False, None, None)},
    "pt": {"€": ("euro", "euros", False, "centavo", "centavos"), "$": ("dólar", "dólares", False, "centavo", "centavos"),
           "R$": ("real", "reais", False, "centavo", "centavos"), "£": ("libra", "libras", True, None, None),
           "¥": ("iene", "ienes", False, None, None), "￥": ("iene", "ienes", False, None, None),
           "₩": ("won", "wons", False, None, None)},
    "nl": {"€": ("euro", "euro", False, "cent", "cent"), "$": ("dollar", "dollar", False, "cent", "cent"),
           "£": ("pond", "pond", False, None, None), "¥": ("yen", "yen", False, None, None),
           "￥": ("yen", "yen", False, None, None), "₩": ("won", "won", False, None, None)},
}
# Languages without number agreement: unit word and subunit word, written after the amount.
_CUR_FLAT: dict[str, dict[str, tuple]] = {
    "ja": {"¥": ("円", None), "￥": ("円", None), "$": ("ドル", "セント"), "€": ("ユーロ", "セント"),
           "£": ("ポンド", "ペンス"), "₩": ("ウォン", None)},
    "ko": {"₩": ("원", None), "¥": ("엔", None), "￥": ("엔", None), "$": ("달러", "센트"), "€": ("유로", "센트"),
           "£": ("파운드", None)},
    "zh": {"¥": ("元", None), "￥": ("元", None), "$": ("美元", "美分"), "€": ("欧元", "欧分"),
           "£": ("英镑", "便士"), "₩": ("韩元", None)},
    "ar": {"$": ("دولار", None), "€": ("يورو", None), "£": ("جنيه إسترليني", None), "¥": ("ين", None),
           "￥": ("ين", None), "₩": ("وون", None)},
}
# A currency symbol left over (not next to a number): spoken as the plain currency name.
_CUR_LONE = {
    "es": {"€": "euros", "$": "dólares", "£": "libras", "¥": "yenes", "￥": "yenes", "₩": "wones"},
    "de": {"€": "Euro", "$": "Dollar", "£": "Pfund", "¥": "Yen", "￥": "Yen", "₩": "Won"},
    "it": {"€": "euro", "$": "dollari", "£": "sterline", "¥": "yen", "￥": "yen", "₩": "won"},
    "pt": {"€": "euros", "$": "dólares", "£": "libras", "¥": "ienes", "￥": "ienes", "₩": "wons"},
    "nl": {"€": "euro", "$": "dollar", "£": "pond", "¥": "yen", "￥": "yen", "₩": "won"},
    "ru": {"€": "евро", "$": "долларов", "£": "фунтов", "¥": "иен", "￥": "иен", "₩": "вон", "₽": "рублей"},
    "ja": {"€": "ユーロ", "$": "ドル", "£": "ポンド", "¥": "円", "￥": "円", "₩": "ウォン"},
    "ko": {"€": "유로", "$": "달러", "£": "파운드", "¥": "엔", "￥": "엔", "₩": "원"},
    "zh": {"€": "欧元", "$": "美元", "£": "英镑", "¥": "元", "￥": "元", "₩": "韩元"},
    "ar": {"€": "يورو", "$": "دولار", "£": "جنيه إسترليني", "¥": "ين", "￥": "ين", "₩": "وون"},
}
_BIG_NOUN = re.compile(r"(?:millón|millones|billón|billones|milhão|milhões|bilhão|bilhões|trilhão|trilhões|"
                       r"milione|milioni|miliardo|miliardi|bilione|bilioni)$")


def _es_apocope(spoken: str, fem: bool) -> str:
    """'veintiuno' -> 'veintiún', 'treinta y uno' -> 'treinta y un'; feminine 'una', 'doscientas'."""
    if fem:
        spoken = re.sub(r"(?<![a-zá-ú])(\w*?)uno(?= mil\b|$)", lambda m: m.group(1) + "una", spoken)
        return re.sub(r"\b(\w+)ientos\b", r"\1ientas", spoken)
    return re.sub(r"\b(veinti)uno(?= mil\b|$)", r"\1ún", re.sub(r"\buno(?= mil\b|$)", "un", spoken))


def _pt_fem(spoken: str) -> str:
    """Feminine agreement of the part after the last milhão: 'um' -> 'uma', 'dois' -> 'duas', 'duzentos' -> '-as'."""
    parts = re.split(r"(\b(?:milhão|milhões|bilhão|bilhões|trilhão|trilhões)\b)", spoken)
    tail = parts[-1]
    if len(parts) > 1 and not tail.strip():
        return spoken
    tail = re.sub(r"\bum\b", "uma", tail)
    tail = re.sub(r"\bdois\b", "duas", tail)
    parts[-1] = re.sub(r"\b(\w+)entos\b", r"\1entas", tail)
    return "".join(parts)


def _agree(spoken: str, lang: str, fem: bool) -> str:
    """The numeral as it stands before a counted noun: 'un euro', 'ein Euro', 'una libra', 'uma libra'."""
    if lang == "es":
        return _es_apocope(spoken, fem)
    if lang == "pt":
        return _pt_fem(spoken) if fem else spoken
    if lang == "de":
        return re.sub(r"eins$", "ein", spoken)
    if lang == "it":
        return re.sub(r"uno$", "una" if fem else "un", spoken)
    return spoken


def _of(spoken: str, lang: str) -> str:
    """'un millón de euros', 'un milione di euro': the linking preposition after a round million."""
    if _BIG_NOUN.search(spoken):
        return {"es": " de", "pt": " de", "it": " di"}.get(lang, "")
    return ""


def _flat_money(ip: str, frac: str | None, sym: str, lang: str, grouped: bool) -> str:
    unit, sub = _CUR_FLAT[lang][sym]
    glue = " " if lang in ("ko", "ar") else ""
    if lang == "zh" and sym in ("¥", "￥") and frac and len(frac) <= 2:
        # 元 角 分: 3.55 -> 三元五角五分, 3.05 -> 三元零五分, 0.50 -> 五角
        jiao, fen = int(frac[0]), int(frac[1]) if len(frac) == 2 else 0
        whole = int(ip.lstrip("0") or "0")
        out = zhnum.cardinal(whole) + "元" if whole or not (jiao or fen) else ""
        if jiao:
            out += zhnum.DIGITS[jiao] + "角"
        if fen:
            out += ("零" if not jiao and whole else "") + zhnum.DIGITS[fen] + "分"
        return out
    if frac and len(frac) == 2 and sub:
        cents = int(frac)
        whole = ip.lstrip("0")
        if not cents:
            return f"{say(ip, lang, grouped)}{glue}{unit}"
        c = f"{say(str(cents), lang)}{glue}{sub}"
        return c if not whole else f"{say(ip, lang, grouped)}{glue}{unit}{glue}{c}"
    return f"{amount_words(ip, frac, lang, grouped)}{glue}{unit}"


_RU_CUR = {
    "₽": ("рубль", "рубля", "рублей", False, ("копейка", "копейки", "копеек"), True),
    "$": ("доллар", "доллара", "долларов", False, ("цент", "цента", "центов"), False),
    "€": ("евро", "евро", "евро", False, ("цент", "цента", "центов"), False),
    "£": ("фунт", "фунта", "фунтов", False, None, False),
    "¥": ("иена", "иены", "иен", True, None, False), "￥": ("иена", "иены", "иен", True, None, False),
    "₩": ("вона", "воны", "вон", True, None, False),
}


def _ru_money(ip: str, frac: str | None, sym: str, grouped: bool) -> str:
    one, few, many, fem, sub, sub_fem = _RU_CUR[sym]

    def whole_text() -> str:
        n = _int_or_none(ip)
        spoken = say(ip, "ru", grouped, gender="f" if fem else "m")
        return f"{spoken} {ru_plural(n, (one, few, many)) if n is not None else many}"

    if frac and len(frac) == 2 and sub:
        cents = int(frac)
        parts = []
        if ip.lstrip("0") or not cents:
            parts.append(whole_text())
        if cents:
            parts.append(f"{say(str(cents), 'ru', gender='f' if sub_fem else 'm')} {ru_plural(cents, sub)}")
        return " ".join(parts)
    if frac:
        return f"{decimal_words(ip, frac, 'ru', grouped)} {few}"
    return whole_text()


def money_ml(ip: str, frac: str | None, sym: str, lang: str, grouped: bool = False) -> str | None:
    """An amount with its currency symbol, spoken; None when the language has no reading for that symbol."""
    if lang == "ru":
        return _ru_money(ip, frac, sym, grouped) if sym in _RU_CUR else None
    if lang in _CUR_FLAT:
        if sym not in _CUR_FLAT[lang]:
            return None
        if lang == "ar" and frac:
            return f"{decimal_words(ip, frac, lang, grouped)} {_CUR_FLAT[lang][sym][0]}"
        return _flat_money(ip, frac, sym, lang, grouped)
    table = _CUR.get(lang)
    if not table or sym not in table:
        return None
    one, many, fem, sub1, subn = table[sym]
    if frac and len(frac) == 2 and sub1:
        cents = int(frac)
        if not ip.lstrip("0") and cents:
            return f"{_agree(say(str(cents), lang), lang, False)} {sub1 if cents == 1 else subn}"
        main = _agree(say(ip, lang, grouped), lang, fem)
        out = f"{main}{_of(main, lang)} {one if ip.lstrip('0') == '1' else many}"
        if cents:
            c = say(str(cents), lang)
            if lang in ("de", "nl"):
                out += f" {c}"
            elif lang == "it":
                out += f" e {c}"
            else:
                out += f"{' con ' if lang == 'es' else ' e '}{c} {sub1 if cents == 1 else subn}"
        return out
    if frac:
        return f"{decimal_words(ip, frac, lang, grouped)} {many}"
    amt = _agree(say(ip, lang, grouped), lang, fem)
    return f"{amt}{_of(amt, lang)} {one if ip.lstrip('0') == '1' else many}"


# ----------------------------------------------------------------------------- patterns

@lru_cache(maxsize=None)
def _edges(lang: str) -> tuple[str, str]:
    if lang in _ASCII_EDGE:
        return r"(?<![A-Za-z0-9_])(?<![0-9][.,])", r"(?![A-Za-z0-9_])"
    return r"(?<!\w)(?<![0-9][.,])", r"(?!\w)"


def _num_re(lang: str) -> str:
    return rf"[0-9]+(?:[.,{_G}][0-9]+)*"


# ----------------------------------------------------------------------------- ordinals

_ES_ORD_FIX = {11: "undécimo", 12: "duodécimo"}


def ordinal_word(n: int, lang: str, fem: bool = False, apocope: bool = False) -> str | None:
    """n as an ordinal in es, pt, it (1..99) and nl (1..999); None when num2words has no reliable form
    (it spells 110th "centodiecesimo", es 40th with a q): the caller then reads a cardinal."""
    if n < 1 or n > (999 if lang == "nl" else 99) or lang not in ("es", "pt", "it", "nl"):
        return None
    try:
        w = _ES_ORD_FIX.get(n) if lang == "es" else None
        if w is None:
            w = words(n, lang, "ordinal")
    except (OverflowError, ValueError, KeyError, NotImplementedError):
        return None
    if lang == "es":
        w = w.replace("quadragésimo", "cuadragésimo")  # num2words spells 40th with a Latin q
    if fem and lang in ("es", "pt", "it"):
        w = re.sub(r"o\b", "a", w)
    elif apocope and lang == "es":
        w = re.sub(r"\b(primer|tercer)o$", r"\1", w)
    return w


_ES_NOUN_AFTER_IT = "piano|posto|anno|capitolo|anniversario|secolo|volume|episodio|livello|turno|classificato|giorno|lezione"


def _ordinal_pass(text: str, lang: str) -> str:
    L, R = _edges(lang)
    if lang in ("es", "pt", "it", "nl"):
        if lang == "es":
            tail = r"(?:(?P<er>\.er)|(?P<fem>\.?ª|\.a)|(?P<masc>\.?º|\.o))(?!\w)"
        elif lang == "pt":
            tail = r"(?:(?P<fem>\.?ª)|(?P<masc>\.?º))(?!\w)"
        elif lang == "it":
            tail = rf"(?:(?P<fem>ª)|(?P<masc>º|°(?=\s(?:{_ES_NOUN_AFTER_IT})\b)))"
        else:
            tail = r"(?P<suf>ste|de|e)(?!\w)"
        rx = re.compile(rf"{L}(?P<n>[0-9]{{1,3}}){tail}")

        def sub(m: re.Match) -> str:
            n = int(m.group("n"))
            gd = m.groupdict()
            w = ordinal_word(n, lang, fem=bool(gd.get("fem")), apocope=bool(gd.get("er")))
            if w is None:
                w = say(m.group("n"), lang)
            return w

        return _sub(rx, sub, text)
    if lang == "ru":
        return _ru_ordinal_suffix(text)
    if lang == "de":
        return _de_ordinal_dot(text)
    return text


_IT_MONTHS = "gennaio|febbraio|marzo|aprile|maggio|giugno|luglio|agosto|settembre|ottobre|novembre|dicembre"
_PT_MONTHS = "janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro"


def _first_of_month(text: str, lang: str) -> str:
    """Italian "1 maggio" and Portuguese "1 de maio" are "primo maggio" / "primeiro de maio"."""
    L, R = _edges(lang)
    if lang == "it":
        return _sub(rf"{L}1(?=\s+(?:{_IT_MONTHS})\b)", lambda m: "primo", text)
    if lang == "pt":
        return _sub(rf"{L}1(?=\s+de\s+(?:{_PT_MONTHS})\b)", lambda m: "primeiro", text)
    return text


_DE_MONTHS = "Januar|Jänner|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
_DE_ORD_NOUN = ("Jahrhundert|Jahrhunderts|Jahrtausend|Mal|Klasse|Platz|Stock|Etage|Kapitel|Geburtstag|Jahrestag|"
                "Weltkrieg|Auflage|Symphonie|Sinfonie|Akt|Szene|Satz|Runde|Spiel|Liga|Reihe|Zeile|Jahr")
# A word before the date that puts it in the dative, accusative or genitive: "am dritten Mai".
_DE_OBLIQUE = frozenset("am vom zum beim im den dem des einem einen diesem diesen jedem jeden zur bis seit ab "
                        "ins unterm überm vorm hinterm".split())
_DE_DET = frozenset("der die das ein eine".split())
# "in der 2. Etage": after one of these "der" is a dative feminine, whose ordinal ends in -n
_DE_DAT_PREP = frozenset("in an auf bei mit nach von zu vor über unter hinter neben zwischen aus seit gegenüber "
                         "bis ab".split())


def _de_ordinal_dot(text: str) -> str:
    """'am 3. Mai' -> 'am dritten Mai', 'das 19. Jahrhundert' -> 'das neunzehnte Jahrhundert'.

    A number and a period is an ordinal only after an article or preposition, or before a month or a noun
    that is counted ("3. Klasse"); anywhere else the period ends the sentence ("Zimmer 3. Er kam."). After a
    preposition or "den/dem/des" the adjective ends in -n, otherwise in -e.
    """
    L, R = _edges("de")
    rx = re.compile(rf"{L}(?P<n>[0-9]{{1,3}}|[IVXL]{{1,5}})\.(?=\s+(?P<next>[A-Za-zÄÖÜäöüß]+))")

    def sub(m: re.Match) -> str:
        tok = m.group("n")
        n = int(tok) if tok.isdigit() else N.roman_to_int(tok)
        if not n or n > 399:
            return m.group(0)
        if not tok.isdigit() and not re.fullmatch(_DE_ORD_NOUN, m.group("next")):
            return m.group(0)
        prev = N._prev_words(m.string, m.start(), 1)
        prev_w = prev[0].strip(".,;:!?") if prev else ""
        following = m.group("next")
        triggered = (prev_w in _DE_OBLIQUE or prev_w in _DE_DET or re.fullmatch(_DE_MONTHS, following)
                     or re.fullmatch(_DE_ORD_NOUN, following))
        if not triggered:
            return m.group(0)
        try:
            w = words(n, "de", "ordinal")
        except (OverflowError, ValueError, KeyError, NotImplementedError):
            return m.group(0)
        before = N._prev_words(m.string, m.start(), 2)
        dative_der = prev_w == "der" and len(before) == 2 and before[0].strip(".,;:!?") in _DE_DAT_PREP
        return w + ("n" if prev_w in _DE_OBLIQUE or dative_der else "")

    return _sub(rx, sub, text)


_RU_PREP = frozenset("из с со от до у для без после около в во на по к ко о об при за над под перед между через".split())
_RU_GEN_PREP = frozenset("из с со от до у для без после около".split())
_RU_SUFFIX = {
    "й": ("n", "m", False), "ый": ("n", "m", False), "ий": ("n", "m", False),
    "я": ("n", "f", False), "ая": ("n", "f", False),
    "го": ("g", "m", False), "ого": ("g", "m", False),
    "му": ("d", "m", False), "ому": ("d", "m", False),
    "ю": ("a", "f", False), "ую": ("a", "f", False),
    "х": ("g", "m", True), "ых": ("g", "m", True),
}


def _ru_ordinal_suffix(text: str) -> str:
    """'5-й' -> 'пятый', '5-го' -> 'пятого', '5-х' -> 'пятых'. Ambiguous suffixes (-е, -м, -й after a
    preposition) are left as written."""
    L, R = _edges("ru")

    def sub(m: re.Match) -> str:
        case, gender, plural = _RU_SUFFIX[m.group("suf")]
        if m.group("suf") == "й":
            prev = N._prev_words(m.string, m.start(), 1)
            if prev and prev[0] in _RU_PREP:
                return m.group(0)  # "из 5-й школы": feminine genitive; not guessed
        n = int(m.group("n"))
        try:
            return num2words(n, lang="ru", to="ordinal", case=case, gender=gender, plural=plural)
        except (OverflowError, ValueError, KeyError, NotImplementedError):
            return m.group(0)

    return _sub(rf"{L}(?P<n>[0-9]{{1,4}})-(?P<suf>ый|ий|ая|ого|ому|ую|ых|й|я|го|му|ю|х)(?![а-яё])", sub, text)


def _ar_ordinal(n: int) -> str | None:
    """Masculine ordinal 1..99 (الأول ... التاسع والتسعون)."""
    units = ["", "الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس", "السابع", "الثامن", "التاسع", "العاشر"]
    teens = {11: "الحادي عشر", 12: "الثاني عشر", 13: "الثالث عشر", 14: "الرابع عشر", 15: "الخامس عشر",
             16: "السادس عشر", 17: "السابع عشر", 18: "الثامن عشر", 19: "التاسع عشر"}
    tens = {20: "العشرون", 30: "الثلاثون", 40: "الأربعون", 50: "الخمسون", 60: "الستون", 70: "السبعون",
            80: "الثمانون", 90: "التسعون"}
    if 1 <= n <= 10:
        return units[n]
    if n in teens:
        return teens[n]
    if n in tens:
        return tens[n]
    if 20 < n < 100:
        unit = {1: "الحادي", 2: "الثاني", 3: "الثالث", 4: "الرابع", 5: "الخامس", 6: "السادس", 7: "السابع",
                8: "الثامن", 9: "التاسع"}[n % 10]
        return f"{unit} و{tens[n - n % 10]}"
    return None


# ----------------------------------------------------------------------------- Roman numerals

_NUMBERED_ML = {
    "es": r"[Cc]apítulo|[Pp]arte|[Ll]ibro|[Tt]omo|[Vv]olumen|[Aa]cto|[Ee]scena|[Cc]anto|[Ss]ección|[Aa]rtículo|[Aa]péndice|[Ss]almo",
    "pt": r"[Cc]apítulo|[Pp]arte|[Ll]ivro|[Tt]omo|[Vv]olume|[Aa]to|[Cc]ena|[Cc]anto|[Ss]eção|[Ss]ecção|[Aa]rtigo|[Aa]pêndice|[Ss]almo",
    "it": r"[Cc]apitolo|[Pp]arte|[Ll]ibro|[Vv]olume|[Tt]omo|[Aa]tto|[Ss]cena|[Cc]anto|[Ss]ezione|[Aa]rticolo|[Aa]ppendice|[Ss]almo",
    "de": r"[Kk]apitel|[Tt]eil|[Bb]uch|[Bb]and|[Aa]kt|[Ss]zene|[Aa]bschnitt|[Gg]esang|[Aa]rtikel|[Aa]nhang|[Pp]salm",
    "nl": r"[Hh]oofdstuk|[Dd]eel|[Bb]oek|[Aa]kte|[Ss]cène|[Zz]ang|[Pp]aragraaf|[Aa]rtikel|[Bb]ijlage|[Pp]salm",
    "ru": r"Глава|Часть|Книга|Том|Акт|Действие|Сцена|Раздел|Статья|Песнь|Псалом",
}
_RU_FEM_HEAD = frozenset({"глава", "часть", "книга", "песнь", "статья", "сцена"})
_RU_NEUT_HEAD = frozenset({"действие"})
# Given names of monarchs and popes. A trailing "*" marks a feminine name.
_REGNAL_ML = {
    "es": "Alfonso|Carlos|Felipe|Fernando|Juan Pablo|Juan|Pablo|Pío|Luis|Enrique|Benedicto|Clemente|Gregorio|León|"
          "Urbano|Inocencio|Alejandro|Napoleón|Ramsés|Jorge|Guillermo|Eduardo|Ricardo|Francisco|Nicolás|Pedro|"
          "Sixto|Isabel*|Juana*|Catalina*|María*|Victoria*",
    "pt": "Pedro|João Paulo|João|Afonso|Luís|Carlos|Henrique|Manuel|Sebastião|Filipe|Leão|Pio|Bento|Gregório|"
          "Paulo|Clemente|Napoleão|Fernando|José|Eduardo|Guilherme|Ricardo|Jorge|Francisco|Alexandre|Nicolau|"
          "Isabel*|Maria*|Catarina*|Vitória*|Joana*",
    "it": "Vittorio Emanuele|Umberto|Carlo|Luigi|Pio|Giovanni Paolo|Giovanni|Paolo|Leone|Gregorio|Benedetto|"
          "Clemente|Urbano|Innocenzo|Alessandro|Napoleone|Federico|Enrico|Filippo|Ferdinando|Francesco|Nicola|"
          "Alfonso|Ruggero|Elisabetta*|Caterina*|Vittoria*|Maria*|Giovanna*",
    "de": "Friedrich|Wilhelm|Ludwig|Karl|Heinrich|Otto|Johann|Franz|Joseph|Ferdinand|Leopold|Maximilian|Rudolf|"
          "Konrad|Albrecht|Georg|Eduard|Richard|Napoleon|Benedikt|Gregor|Leo|Pius|Paul|Johannes Paul|Alexander|"
          "Nikolaus|Peter|Philipp|Elisabeth*|Katharina*|Victoria*",
    "nl": "Willem|Lodewijk|Karel|Hendrik|Filips|Jan|Pieter|Albert|Leopold|Napoleon|Alexander|Nicolaas|Frederik|"
          "Maurits|Elizabeth*",
    "ru": "Пётр|Петр|Николай|Александр|Иван|Павел|Фридрих|Людовик|Наполеон|Карл|Генрих|Вильгельм|Георг|Эдуард|"
          "Ричард|Иоанн|Лев|Пий|Бенедикт|Климент|Григорий|Екатерина*|Елизавета*|Анна*|Виктория*|Мария*",
}


def _regnal_names(lang: str) -> tuple[str, frozenset]:
    names = _REGNAL_ML[lang].split("|")
    fem = frozenset(n[:-1] for n in names if n.endswith("*"))
    return "|".join(n.rstrip("*") for n in names), fem


@lru_cache(maxsize=None)
def _roman_patterns(lang: str):
    names, fem = _regnal_names(lang)
    regnal = re.compile(rf"\b(?P<name>{names}) (?P<rn>[IVXL]{{2,}}|[IVX])(?P<dot>\.)?(?!\w)(?!-\w)")
    digits = r"|[0-9]{1,3}" if lang == "ru" else ""
    numbered = re.compile(rf"\b(?P<word>{_NUMBERED_ML[lang]}) (?P<rn>[IVXLC]{{2,}}|[VXI]{digits})(?!\w)(?!-\w)")
    return regnal, numbered, fem


def _expand_roman_ml(text: str, lang: str) -> str:
    if lang not in _NUMBERED_ML:
        return text
    regnal, numbered, fem = _roman_patterns(lang)

    def value(tok: str, top: int) -> int | None:
        n = N.roman_to_int(tok)
        return n if n and n <= top else None

    def reg(m: re.Match) -> str:
        n = value(m.group("rn"), 40)
        if n is None:
            return m.group(0)
        name, f = m.group("name"), m.group("name") in fem
        if lang in ("es", "pt"):
            w = ordinal_word(n, lang, fem=f) if n <= 10 else say(str(n), lang)
        elif lang == "it":
            w = ordinal_word(n, lang, fem=f)
        elif lang == "de":
            w = words(n, "de", "ordinal")
            w = f"{'die' if f else 'der'} {_upper_first(w)}"
            dot = m.group("dot")
            end = m.string[m.end():m.end() + 2]
            keep = dot and (not end.strip() or (end[:1] == " " and end[1:2].isupper()))
            return f"{name} {w}" + ("." if keep else "")
        elif lang == "nl":
            w = f"de {_upper_first(words(n, 'nl', 'ordinal'))}"
        else:  # ru, nominative
            w = _upper_first(num2words(n, lang="ru", to="ordinal", gender="f" if f else "m"))
        if w is None:
            return m.group(0)
        return f"{name} {w}" + (m.group("dot") or "" if lang != "de" else "")

    text = _sub(regnal, reg, text)

    def num(m: re.Match) -> str:
        rn = m.group("rn")
        n = int(rn) if rn.isdigit() and 0 < int(rn) <= 399 else value(rn, 399) if not rn.isdigit() else None
        if n is None:
            return m.group(0)
        word = m.group("word")
        if lang == "ru":
            low = word.lower()
            g = "f" if low in _RU_FEM_HEAD else "n" if low in _RU_NEUT_HEAD else "m"
            return f"{word} {num2words(n, lang='ru', to='ordinal', gender=g)}"
        return f"{word} {say(str(n), lang)}"

    text = _sub(numbered, num, text)
    return _roman_centuries(text, lang)


def _roman_centuries(text: str, lang: str) -> str:
    def val(tok):
        n = N.roman_to_int(tok)
        return n if n and n <= 40 else None

    if lang == "es":
        return _sub(r"\b([Ss]iglos?) ([IVXL]+)(?!\w)",
                      lambda m: f"{m.group(1)} {say(str(val(m.group(2))), 'es')}" if val(m.group(2)) else m.group(0), text)
    if lang == "pt":
        return _sub(r"\b([Ss]éculos?) ([IVXL]+)(?!\w)",
                      lambda m: f"{m.group(1)} {say(str(val(m.group(2))), 'pt')}" if val(m.group(2)) else m.group(0), text)
    if lang == "it":
        def it_c(m):
            n = val(m.group("r"))
            w = ordinal_word(n, "it") if n else None
            return f"{m.group('w')} {w}" if w else m.group(0)

        text = _sub(r"\b(?P<w>[Ss]ecolo) (?P<r>[IVXL]+)(?!\w)", it_c, text)
        return _sub(r"\b(?P<r>[IVXL]+) (?P<w2>secolo)\b",
                      lambda m: f"{ordinal_word(val(m.group('r')), 'it')} secolo" if val(m.group("r")) else m.group(0),
                      text)
    if lang == "nl":
        return _sub(r"\b([IVXL]+)e eeuw\b",
                      lambda m: f"{ordinal_word(val(m.group(1)), 'nl')} eeuw" if val(m.group(1)) else m.group(0), text)
    if lang == "ru":
        def ru_c(m):
            n = val(m.group("r"))
            if not n:
                return m.group(0)
            noun = m.group("w")
            case = {"век": "n", "века": "g", "веку": "d", "веком": "i", "веке": "p"}.get(noun)
            if not case:
                return m.group(0)
            return f"{num2words(n, lang='ru', to='ordinal', case=case)} {noun}"

        return _sub(r"\b(?P<r>[IVXL]+) (?P<w>век|века|веку|веком|веке)\b", ru_c, text)
    return text


# ----------------------------------------------------------------------------- Korean native numerals

_KO_UNITS_ATTR = {1: "한", 2: "두", 3: "세", 4: "네", 5: "다섯", 6: "여섯", 7: "일곱", 8: "여덟", 9: "아홉"}
_KO_TENS = {1: "열", 2: "스물", 3: "서른", 4: "마흔", 5: "쉰", 6: "예순", 7: "일흔", 8: "여든", 9: "아흔"}


def ko_native(n: int) -> str | None:
    """Native Korean numeral in front of a counter (한 명, 두 개, 세 시, 스무 살, 스물한 개), 1..99."""
    if not 1 <= n <= 99:
        return None
    if n == 20:
        return "스무"
    tens, unit = divmod(n, 10)
    return (_KO_TENS[tens] if tens else "") + (_KO_UNITS_ATTR[unit] if unit else "")


_KO_COUNTERS = "번째|시간|송이|켤레|마리|가지|그루|병|잔|권|명|개(?!월)|살|시|채|곳|달"


def _ko_counters(text: str) -> str:
    def sub(m: re.Match) -> str:
        n = int(m.group("n"))
        w = ko_native(n)
        if w is None:
            return m.group(0)
        return f"{w} {m.group('c')}"

    return re.sub(rf"(?<![0-9A-Za-z])(?<!제)(?P<n>[0-9]{{1,2}})\s?(?P<c>{_KO_COUNTERS})", sub, text)


# ----------------------------------------------------------------------------- times

_TIME = re.compile(r"(?<![0-9:.,])(?P<h>[01]?[0-9]|2[0-3]):(?P<m>[0-5][0-9])(?![0-9:])")


def _time_words(h: int, mi: int, lang: str) -> str | None:
    if lang == "es":
        hw = "una" if h == 1 else words(h, "es")
        return hw if not mi else f"{hw} y {words(mi, 'es')}"
    if lang == "pt":
        hw = {1: "uma", 2: "duas"}.get(h) or words(h, "pt")
        return hw if not mi else f"{hw} e {words(mi, 'pt')}"
    if lang == "it":
        hw = "una" if h == 1 else words(h, "it")
        return hw if not mi else f"{hw} e {words(mi, 'it')}"
    if lang == "de":
        hw = re.sub(r"eins$", "ein", words(h, "de"))
        return f"{hw} Uhr" + (f" {words(mi, 'de')}" if mi else "")
    if lang == "nl":
        return f"{words(h, 'nl')} uur" + (f" {words(mi, 'nl')}" if mi else "")
    if lang == "ru":
        if not mi:
            return f"{words(h, 'ru')} {ru_plural(h, ('час', 'часа', 'часов'))}"
        hw = "час" if h == 1 else words(h, "ru")
        return f"{hw} {'ноль ' if mi < 10 else ''}{words(mi, 'ru')}"
    if lang == "ja":
        return f"{words(h, 'ja')}時" + (f"{words(mi, 'ja')}分" if mi else "")
    if lang == "zh":
        hw = "两" if h == 2 else zhnum.cardinal(h, two_form=False)
        if not mi:
            return f"{hw}点"
        return f"{hw}点{'零' if mi < 10 else ''}{zhnum.cardinal(mi, two_form=False)}分"
    if lang == "ko":
        hw = ko_native(h) if h else "영"
        return f"{hw} 시" + (f" {words(mi, 'ko')} 분" if mi else "")
    return None


def _time_pass(text: str, lang: str, protect) -> str:
    if lang in ("ar", "hi"):
        # no reliable reading: the time is kept as written and shielded from the number rules
        return _TIME.sub(lambda m: protect(m.group(0)), text)
    tail = {"de": r"(?:\s?Uhr\b)?", "es": r"(?:\s?h\b)?"}.get(lang, "")
    rx = re.compile(_TIME.pattern + tail)

    def sub(m: re.Match) -> str:
        spoken = _time_words(int(m.group("h")), int(m.group("m")), lang)
        return m.group(0) if spoken is None else spoken

    return _sub(rx, sub, text)


# ----------------------------------------------------------------------------- years

_DE_YEAR_PREV = frozenset("jahr jahre jahren jahres anno ende anfang mitte seit bis ab vor nach um von zwischen und im "
                          "in bis".split())
_DE_YEAR_PREV = _DE_YEAR_PREV | frozenset(m.lower() for m in
                                        "Januar Jänner Februar März April Mai Juni Juli August September Oktober "
                                        "November Dezember".split())
_DE_JAHR = frozenset("jahr jahre jahren jahres anno".split())
_NL_YEAR_PREV = frozenset("jaar sinds tot vanaf van voor na rond tussen en eind begin midden in anno".split())


def _year_pass(text: str, lang: str) -> str:
    L, R = _edges(lang)
    if lang in ("de", "nl"):
        rx = re.compile(rf"{L}(?P<y>1[1-9][0-9]{{2}}){R}(?![.,][0-9])(?!\s?[€$£%°])")

        def sub(m: re.Match) -> str:
            prev = N._prev_words(m.string, m.start(), 1)
            pw = prev[0].strip(".,;:!?") if prev else ""
            after = m.string[m.end():]
            nxt = re.match(r"\s+([^\W\d_][\w-]*)", after)
            if lang == "de":
                next_cap = bool(nxt and nxt.group(1)[:1].isupper())
                year = pw in _DE_JAHR or (pw in _DE_YEAR_PREV and not next_cap) or (not pw and not next_cap)
            else:
                year = pw in _NL_YEAR_PREV
            if not year:
                return m.group(0)
            return words(int(m.group("y")), lang, "year")

        return _sub(rx, sub, text)
    if lang == "zh":
        return re.sub(rf"{L}(?P<y>[12][0-9]{{3}})(?=\s?年)", lambda m: zhnum.digits(m.group("y")), text)
    if lang == "ru":
        return _ru_years(text)
    return text


_RU_MONTHS = "января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря"
_RU_YEAR_NOUN = {"год": "n", "года": "g", "году": "p", "годом": "i", "годе": "p"}


def _ru_years(text: str) -> str:
    """'в 1999 году' -> 'в тысяча девятьсот девяносто девятом году'; the case follows the noun or, for 'г.',
    the word before. A bare year is read as a cardinal by the number rules."""
    rx = re.compile(r"(?<![\w.,])(?<![0-9][.,])(?P<y>[0-9]{3,4})\s(?P<noun>год|года|году|годом|годе|г\.)(?!\w)")

    def sub(m: re.Match) -> str:
        noun = m.group("noun")
        prev = N._prev_words(m.string, m.start(), 1)
        pw = prev[0].strip(".,;:!?") if prev else ""
        if noun == "г.":
            if pw in ("в", "во", "на", "о", "об", "при"):
                case = "p"
            elif pw in _RU_GEN_PREP or pw in _RU_MONTHS.split("|"):
                case = "g"
            elif pw in ("к", "ко"):
                case = "d"
            else:
                case = "n"
            noun = {"n": "год", "g": "года", "d": "году", "p": "году"}[case]
        else:
            case = _RU_YEAR_NOUN[noun]
            if noun == "году" and pw in ("к", "ко"):
                case = "d"
        return f"{num2words(int(m.group('y')), lang='ru', to='ordinal', case=case)} {noun}"

    text = _sub(rx, sub, text)
    return _ru_dates(text)


_RU_MONTH_LIST = _RU_MONTHS.split("|")
_RU_DAY_DAT = frozenset({"к", "ко"})


def _ru_dates(text: str) -> str:
    """'5 мая' -> 'пятое мая'; 'с 5 мая' -> 'с пятого мая'; 'к 5 мая' -> 'к пятому мая'."""
    rx = re.compile(rf"(?<![\w.,])(?P<d>[0-3]?[0-9])\s(?P<mon>{_RU_MONTHS})(?!\w)")

    def sub(m: re.Match) -> str:
        d = int(m.group("d"))
        if not 1 <= d <= 31:
            return m.group(0)
        prev = N._prev_words(m.string, m.start(), 1)
        pw = prev[0].strip(".,;:!?") if prev else ""
        if pw in _RU_GEN_PREP:
            case = "g"
        elif pw in _RU_DAY_DAT:
            case = "d"
        elif pw in _RU_PREP:
            return m.group(0)  # other prepositions: left to the plain number reading
        else:
            case = "n"
        return f"{num2words(d, lang='ru', to='ordinal', case=case, gender='n')} {m.group('mon')}"

    return _sub(rx, sub, text)


# ----------------------------------------------------------------------------- percent, degrees

def percent_ml(ip: str, frac: str | None, lang: str, grouped: bool = False) -> str:
    amt = amount_words(ip, frac, lang, grouped)
    if lang == "ru":
        n = _int_or_none(ip)
        word = "процента" if frac or n is None else ru_plural(n, ("процент", "процента", "процентов"))
        return f"{amt} {word}"
    if lang == "zh":
        return "百分之百" if not frac and ip.lstrip("0") == "100" else "百分之" + amt
    if lang == "de" and not frac:
        amt = _agree(amt, "de", False)
    return amt + {"es": " por ciento", "de": " Prozent", "it": " per cento", "pt": " por cento", "nl": " procent",
                  "ja": "パーセント", "ko": " 퍼센트", "ar": " في المئة", "hi": " प्रतिशत"}[lang]


_DEG = {"es": ("grado", "grados"), "it": ("grado", "gradi"), "pt": ("grau", "graus"), "de": ("Grad", "Grad"),
        "nl": ("graad", "graden")}
_SCALE = {
    "es": {"C": " Celsius", "F": " Fahrenheit"}, "it": {"C": " Celsius", "F": " Fahrenheit"},
    "pt": {"C": " Celsius", "F": " Fahrenheit"}, "de": {"C": " Celsius", "F": " Fahrenheit"},
    "nl": {"C": " Celsius", "F": " Fahrenheit"}, "ru": {"C": " Цельсия", "F": " Фаренгейта"},
    "ar": {"C": " مئوية", "F": " فهرنهايت"},
}


_MINUS = {"es": "menos", "de": "minus", "it": "meno", "pt": "menos", "nl": "min", "ru": "минус", "ar": "ناقص"}


def degrees_ml(ip: str, frac: str | None, scale: str, lang: str, grouped: bool = False, neg: bool = False) -> str:
    """A temperature or an angle: '30 °C' -> 'treinta grados Celsius'; '-5 °C' -> 'menos cinco grados Celsius'."""
    amt = amount_words(ip, frac, lang, grouped)
    if lang == "zh":
        if neg:
            return f"零下{amt}{ {'C': '摄氏度', 'F': '华氏度'}.get(scale, '度') }"
        return f"{ {'C': '摄氏', 'F': '华氏'}.get(scale, '') }{amt}度"
    if lang == "ja":
        pre = {"C": "摂氏", "F": "華氏"}.get(scale, "")
        return f"{pre}{'マイナス' if neg else ''}{amt}度"
    if lang == "ko":
        pre = {"C": "섭씨 ", "F": "화씨 "}.get(scale, "")
        return f"{pre}{'영하 ' if neg else ''}{amt} 도"
    if neg:
        return f"{_MINUS[lang]} " + degrees_ml(ip, frac, scale, lang, grouped)
    if lang == "ar":
        n = _int_or_none(ip)
        unit = "درجات" if not frac and n is not None and 3 <= n <= 10 else "درجة"
        return f"{amt} {unit}{_SCALE['ar'].get(scale, '')}"
    if lang == "ru":
        n = _int_or_none(ip)
        unit = "градуса" if frac or n is None else ru_plural(n, ("градус", "градуса", "градусов"))
        return f"{amt} {unit}{_SCALE['ru'].get(scale, '')}"
    one, many = _DEG[lang]
    unit = one if not frac and ip.lstrip("0") == "1" else many
    if lang == "de" and not frac:
        amt = _agree(amt, "de", False)
    return f"{amt} {unit}{_SCALE[lang].get(scale, '')}"


# ----------------------------------------------------------------------------- numbers

_PRIV = 0xE100  # private-use code points that stand for text shielded from the number rules

# Russian: nouns that make 1 and 2 feminine / 1 neuter, and the prepositions that take the genitive.
_RU_FEM_NOUNS = frozenset(
    "минута минуты минуту секунда секунды секунду неделя недели неделю ночь ночи книга книги книгу страница страницы "
    "страницу женщина женщины женщину девочка девочки девочку девушка девушки девушку комната комнаты комнату "
    "копейка копейки копейку улица улицы улицу дверь двери".split()
)
_RU_NEUT_NOUNS = frozenset("окно слово дело место число письмо яблоко утро лицо сердце солнце море".split())
_ZH_MEASURE = ("个位只条本张件名次天岁倍辆间套双对支把种道层家所场座门封首块口头匹颗粒根片瓶杯碗盘篇页期项"
               "小时分钟秒周点")
_SYM_BEFORE = r"R\$|[$£€¥￥₩₽]"
_NEG_WORD = {"es": "menos", "de": "minus", "it": "meno", "pt": "menos", "nl": "min", "ru": "минус", "zh": "负",
             "ja": "マイナス", "ko": "마이너스", "ar": "ناقص", "hi": "-"}


def _sentence_initial(s: str, pos: int) -> bool:
    j = pos
    while j > 0 and s[j - 1] in " \"'«„¿¡—–-(":
        j -= 1
    return j == 0 or s[j - 1] in ".!?…"


def _sub(pattern, fn, text: str) -> str:
    """re.sub whose replacement keeps a capital letter when the match opened a sentence ("5 euros." read
    in words must still start with a capital, or the segmenter would not split before it)."""
    rx = re.compile(pattern) if isinstance(pattern, str) else pattern

    def wrapped(m: re.Match) -> str:
        out = fn(m)
        if out != m.group(0) and out[:1].islower() and _sentence_initial(m.string, m.start()):
            return _upper_first(out)
        return out

    return rx.sub(wrapped, text)


# A number ending in 1 (or, in Portuguese and Spanish, 2 and the hundreds) agrees with the noun that follows:
# "veintiún años", "una libra", "ein Mann" / "eine Frau". Gender is a suffix heuristic, masculine by default.
_FEM_EXC = {
    "es": "día días mapa mapas problema problemas tema temas sistema sistemas programa programas idioma idiomas "
          "planeta planetas poeta poetas clima climas drama dramas esquema esquemas diagrama diagramas papa papas "
          "pijama fantasma diploma cometa cura tranvía sofá",
    "pt": "dia dias mapa mapas problema problemas tema temas sistema sistemas programa programas idioma idiomas "
          "planeta planetas poeta poetas clima climas drama dramas cinema cinemas diploma fantasma pijama "
          "telefonema papa",
    "it": "problema problemi programma programmi sistema sistemi tema temi poeta poeti pianeta pianeti clima dramma "
          "cinema schema schemi diagramma panorama pigiama papa atleta collega",
}
_FEM_WORDS = {
    "es": "mujer mujeres noche noches clase clases flor flores vez veces parte partes calle calles carne leche sangre "
          "imagen imágenes luz luces cruz paz voz voces razón razones mano manos foto fotos moto motos",
    "it": "notte notti madre madri chiave chiavi parte parti volta volte",
    "pt": "mulher mulheres noite noites classe classes flor flores vez vezes parte partes rua ruas mão mãos foto fotos "
          "luz luzes cruz paz voz vozes",
    "de": "frau frauen zeit zeiten stunde stunden woche wochen minute minuten sekunde sekunden nacht nächte",
}
_FEM_SUFFIX = {
    "es": ("a", "as", "ión", "iones", "dad", "dades", "tad", "tades", "tud", "tudes", "ez", "umbre"),
    "pt": ("a", "as", "ção", "ções", "são", "sões", "dade", "dades", "gem", "gens", "tude"),
    "it": ("a", "zione", "sione", "gione", "ità", "tù"),
    "de": ("ung", "ungen", "heit", "heiten", "keit", "keiten", "schaft", "schaften", "tät", "tion", "tionen", "ei",
           "erin", "erinnen"),
}
_FUNCTION_WORDS = frozenset(
    "de del al a y e o u en por con para que como hasta desde entre sobre según sin tras se no ni el la los las un una "
    "es fue son era hay da do dos das di del dei delle della degli nel nella sul sulla per tra fra che come anche und "
    "oder bis von mit zu in im am um nach vor aus bei seit ab als wie".split())


def _is_fem(noun: str, lang: str) -> bool:
    w = noun.lower()
    if lang == "de":
        if not noun[:1].isupper():
            return False
        if w in _FEM_WORDS["de"].split() or w.endswith(_FEM_SUFFIX["de"]):
            return True
        return w.endswith("e") and w not in "junge name käse kollege neffe löwe hase affe gebäude ende auge interesse".split()
    if w in _FEM_EXC.get(lang, "").split():
        return False
    return w in _FEM_WORDS.get(lang, "").split() or w.endswith(_FEM_SUFFIX.get(lang, ()))


_DE_DATIVE_PREP = frozenset("mit von bei nach zu aus seit gegenüber samt außer ab".split())


def _agree_with_noun(spoken: str, noun: str, lang: str, prev: str = "") -> str:
    if len(noun) < 3 or noun.lower() in _FUNCTION_WORDS or not noun[0].isalpha():
        return spoken
    fem = _is_fem(noun, lang)
    if lang == "es":
        return _es_apocope(spoken, fem)
    if lang == "pt":
        return _pt_fem(spoken) if fem else spoken
    if lang == "it":
        return re.sub(r"uno$", "una" if fem else "un", spoken)
    if lang == "de" and noun[0].isupper():
        if prev in _DE_DATIVE_PREP:  # dative: einem / einer, whatever the gender
            return re.sub(r"eins$", "einer" if fem else "einem", spoken)
        return re.sub(r"eins$", "eine" if fem else "ein", spoken)
    return spoken


def _next_word(text: str, pos: int) -> str:
    m = re.match(r"\s*([^\W\d_]+)", text[pos:pos + 40])
    return m.group(1).lower() if m else ""


def expand_numbers_ml(text: str, lang: str) -> str:
    if lang == "hi":
        return text.replace(_G, " ")  # num2words cannot spell Hindi: digits are left for the speech model
    shielded: list[str] = []

    def protect(s: str) -> str:
        shielded.append(s)
        return chr(_PRIV + len(shielded) - 1)

    if lang == "ar":
        text = to_western_digits(text)
    text = text.replace("℃", "°C").replace("℉", "°F")
    text = re.sub(r"(?<=\d)(\s?)º(?=\s?[CF](?![A-Za-z]))", r"\1°", text)
    if lang in _COMMA_DEC:
        text = N._group_fr_thousands(text)
    L, R = _edges(lang)
    NUM = _num_re(lang)

    def parsed(m: re.Match, key: str = "num"):
        p = parse_num(m.group(key), lang)
        return p

    # --- currency
    def money(m: re.Match) -> str:
        p = parsed(m)
        if p is None:
            return m.group(0)
        spoken = money_ml(p[0], p[1], m.group("sym"), lang, p[2])
        return m.group(0) if spoken is None else spoken

    text = _sub(rf"(?P<sym>{_SYM_BEFORE})\s?(?P<num>{NUM}){R}", money, text)
    text = _sub(rf"{L}(?P<num>{NUM})\s?(?P<sym>[$£€¥￥₩₽])", money, text)
    if lang == "ru":
        text = _ru_word_money(text, NUM, L)

    # --- percent
    def pct(m: re.Match) -> str:
        p = parsed(m)
        return m.group(0) if p is None else percent_ml(p[0], p[1], lang, p[2])

    text = _sub(rf"{L}(?P<num>{NUM})\s?%", pct, text)

    # --- ordinals, Roman numerals, times, years
    text = _first_of_month(text, lang)
    text = _ordinal_pass(text, lang)
    text = _expand_roman_ml(text, lang)
    text = _time_pass(text, lang, protect)
    text = _year_pass(text, lang)

    # --- degrees
    def deg(m: re.Match) -> str:
        p = parsed(m)
        return m.group(0) if p is None else degrees_ml(p[0], p[1], m.group("sc") or "", lang, p[2],
                                                       bool(m.group("neg")))

    neg_before = r"(?<![A-Za-z0-9_.,])" if lang in _ASCII_EDGE else r"(?<![\w.,])"
    text = _sub(rf"(?:{neg_before}(?P<neg>[-−])|{L})(?P<num>{NUM})\s?°(?:\s?(?P<sc>[CF])(?![A-Za-z]))?", deg, text)

    if lang == "ar":
        text = re.sub(r"(?<![ء-ي])(ال(?:فصل|باب|جزء|قسم|كتاب)) ([0-9]{1,2})(?![0-9.,])",
                      lambda m: f"{m.group(1)} {_ar_ordinal(int(m.group(2))) or m.group(2)}", text)
    if lang == "ko":
        text = re.sub(r"(?<![0-9])(6|10)(?=\s?월)", lambda m: "유" if m.group(1) == "6" else "시", text)
        text = _ko_counters(text)
    if lang == "de":
        text = re.sub(r"(?<![0-9.,])1(?= Uhr\b)", "ein", text)

    # --- every other number
    text = _plain_numbers(text, lang, NUM, L, R)
    for i, s in enumerate(shielded):
        text = text.replace(chr(_PRIV + i), s)
    return text.replace(_G, " ")


def _ru_word_money(text: str, NUM: str, L: str) -> str:
    """'5 руб.', '3 коп.', '2 млн руб.' -> spelled with the right plural."""
    mags = (("тыс", 10 ** 3, ("тысяча", "тысячи", "тысяч")), ("млн", 10 ** 6, ("миллион", "миллиона", "миллионов")),
            ("млрд", 10 ** 9, ("миллиард", "миллиарда", "миллиардов")))
    mag_re = "|".join(m[0] for m in mags)

    def sub(m: re.Match) -> str:
        p = parse_num(m.group("num"), "ru")
        if p is None:
            return m.group(0)
        ip, frac, grouped = p
        mag = m.group("mag")
        word = m.group("cur")
        parts = []
        if mag:
            forms = next(x[2] for x in mags if x[0] == mag)
            n = _int_or_none(ip)
            if frac:
                parts.append(f"{decimal_words(ip, frac, 'ru', grouped)} {forms[1]}")
                if word:
                    parts.append("рублей" if word == "руб" else "копеек")
                return " ".join(parts)
            if n is None:
                return m.group(0)
            parts.append(f"{say(ip, 'ru', grouped, gender='f' if mag == 'тыс' else 'm')} {ru_plural(n, forms)}")
            if word:
                parts.append("рублей" if word == "руб" else "копеек")
            return " ".join(parts)
        if frac:
            return f"{decimal_words(ip, frac, 'ru', grouped)} {'рубля' if word == 'руб' else 'копейки'}"
        n = _int_or_none(ip)
        if word == "руб":
            return f"{say(ip, 'ru', grouped)} {ru_plural(n, ('рубль', 'рубля', 'рублей')) if n is not None else 'рублей'}"
        return f"{say(ip, 'ru', grouped, gender='f')} {ru_plural(n, ('копейка', 'копейки', 'копеек')) if n is not None else 'копеек'}"

    pat = rf"{L}(?P<num>{NUM})(?:\s?(?P<mag>{mag_re})\.?)?(?:\s?(?P<cur>руб|коп)\.?)?(?![\w])"

    def gated(m: re.Match) -> str:
        if not m.group("mag") and not m.group("cur"):
            return m.group(0)
        if m.group("mag") and not m.group("cur") and m.group("mag") in ("млн", "млрд", "тыс"):
            pass
        return sub(m)

    return re.sub(pat, gated, text)


def _plain_numbers(text: str, lang: str, NUM: str, L: str, R: str) -> str:
    extra = r"(?!-[а-яёА-ЯЁ])" if lang == "ru" else ""
    # a minus sign: U+2212, or a hyphen that follows a space or an opening mark but not a number ("5 -10")
    sign_lb = r"(?<![A-Za-z0-9_.,-])" if lang in _ASCII_EDGE else r"(?<![\w.,-])"
    rx = re.compile(rf"(?P<neg>{sign_lb}(?<![0-9] )-(?=[0-9])|−(?=[0-9]))?{L}(?P<tok>{NUM}){R}{extra}")

    def sub(m: re.Match) -> str:
        spoken = sub_number(m)
        if m.group("neg"):
            return f"{_NEG_WORD[lang]}{'' if lang in ('zh', 'ja') else ' '}{spoken}"
        return spoken

    def sub_number(m: re.Match) -> str:
        tok = m.group("tok")
        p = parse_num(tok, lang)
        if p is None:
            return _fallback_parts(tok, lang)
        ip, frac, grouped = p
        s, e = m.span("tok")
        if frac is not None:
            return decimal_words(ip, frac, lang, grouped)
        if lang == "ru":
            n = _int_or_none(ip)
            kw = {}
            prev = N._prev_words(m.string, s, 1)
            pw = prev[0].strip(".,;:!?") if prev else ""
            nw = _next_word(m.string, e)
            if n is not None:
                if n % 10 in (1, 2) and n % 100 not in (11, 12) and nw in _RU_FEM_NOUNS:
                    kw["gender"] = "f"
                elif n % 10 == 1 and n % 100 != 11 and nw in _RU_NEUT_NOUNS:
                    kw["gender"] = "n"
            # a year range ("с 1990 по 2000") is not put in the genitive: only numbers below 1000 are
            if n is not None and n < 1000:
                if pw in _RU_GEN_PREP:
                    kw["case"] = "g"
                elif pw in ("к", "ко"):
                    kw["case"] = "d"
            return say(ip, "ru", grouped, **kw)
        if lang == "zh":
            n = _int_or_none(ip)
            if m.string[s - 1:s] == "第":
                return say(ip, "zh", grouped, to="ordinal")
            if n == 2 and m.string[e:e + 2].startswith(tuple(_ZH_MEASURE)) and not frac:
                return "两"
            return say(ip, "zh", grouped)
        out = say(ip, lang, grouped)
        if lang in ("es", "pt", "it", "de"):
            noun = re.match(r" ([^\W\d_]+)", m.string[e:e + 40])
            if noun:
                prev = N._prev_words(m.string, s, 1)
                out = _agree_with_noun(out, noun.group(1), lang, prev[0].strip(".,;:!?") if prev else "")
        if lang == "ko" and re.match(r"[가-힣]", m.string[e:e + 1]) and m.string[s - 1:s] != "제":
            out += " "
        return out

    return _sub(rx, sub, text)


# ----------------------------------------------------------------------------- symbols

_SYMBOLS_ML = {
    "es": {"&": " y ", "%": " por ciento", "§": " párrafo ", "+": " más ", "=": " igual a ", "×": " por "},
    "de": {"&": " und ", "%": " Prozent", "§": " Paragraph ", "+": " plus ", "=": " gleich ", "×": " mal "},
    "it": {"&": " e ", "%": " per cento", "§": " paragrafo ", "+": " più ", "=": " uguale a ", "×": " per "},
    "pt": {"&": " e ", "%": " por cento", "§": " parágrafo ", "+": " mais ", "=": " igual a ", "×": " vezes "},
    "nl": {"&": " en ", "%": " procent", "§": " paragraaf ", "+": " plus ", "=": " is gelijk aan ", "×": " keer "},
    "ru": {"&": " и ", "%": " процентов", "§": " параграф ", "+": " плюс ", "=": " равно ", "×": " умножить на "},
    "ja": {"&": "アンド", "%": "パーセント", "+": "プラス", "=": "イコール", "×": "かける"},
    "zh": {"&": "和", "%": "百分", "+": "加", "=": "等于", "×": "乘"},
    "ko": {"&": " 앤드 ", "%": " 퍼센트", "+": " 플러스 ", "×": " 곱하기 "},
    "ar": {"&": " و ", "%": " في المئة", "+": " زائد ", "=": " يساوي ", "×": " ضرب "},
    "hi": {"%": " प्रतिशत"},
}
_DEG_LONE = {"es": " grados", "it": " gradi", "pt": " graus", "de": " Grad", "nl": " graden", "ru": " градусов",
             "ja": "度", "zh": "度", "ko": " 도", "ar": " درجة"}


def expand_symbols_ml(text: str, lang: str) -> str:
    if lang in _DEG_LONE:
        scale = _SCALE.get(lang, {})
        if lang in ("ja", "zh", "ko"):
            text = re.sub(r"\s?°(?:\s?([CF])(?![A-Za-z]))?",
                          lambda m: ({"C": {"ja": "摂氏", "zh": "摄氏", "ko": "섭씨"}, "F": {"ja": "華氏", "zh": "华氏", "ko": "화씨"}}
                                     .get(m.group(1) or "", {}).get(lang, "") + _DEG_LONE[lang]), text)
        else:
            text = re.sub(r"\s?°(?:\s?([CF])(?![A-Za-z]))?",
                          lambda m: _DEG_LONE[lang] + scale.get(m.group(1) or "", ""), text)
    for sym, word in _SYMBOLS_ML.get(lang, {}).items():
        if sym == "+":
            text = re.sub(r"(?<=\w)\s*\+\s*(?=\w)", word, text)
        elif sym == "=":
            text = re.sub(r"\s*=\s*", word, text)
        else:
            text = text.replace(sym, word)
    for sym, name in _CUR_LONE.get(lang, {}).items():
        text = text.replace(sym, f" {name} ")
    return re.sub(r"\s+", " ", text)


# ----------------------------------------------------------------------------- headings

_HEAD_WORDS = {
    "es": "capítulo|capitulo|parte|libro|tomo|volumen|acto|escena|canto|sección|seccion|artículo|apéndice",
    "pt": "capítulo|capitulo|parte|livro|tomo|volume|ato|cena|canto|seção|secção|artigo|apêndice",
    "it": "capitolo|parte|libro|volume|tomo|atto|scena|canto|sezione|articolo|appendice",
    "de": "kapitel|teil|buch|band|akt|szene|abschnitt|gesang|artikel|anhang",
    "nl": "hoofdstuk|deel|boek|akte|scène|zang|paragraaf|artikel|bijlage",
    "ru": "глава|часть|книга|том|акт|действие|сцена|раздел|статья|песнь",
    "ar": "الفصل|الباب|الجزء|القسم|الكتاب|فصل|باب|جزء|قسم|كتاب",
    "hi": "अध्याय|भाग|खंड|खण्ड|पर्व|सर्ग|कांड|काण्ड|प्रकरण",
}
_ROMAN_HEADING = frozenset({"es", "pt", "it", "de", "nl", "ru"})
_HEAD_RX: dict[str, re.Pattern] = {}


def _heading_rx(lang: str) -> re.Pattern:
    if lang not in _HEAD_RX:
        num = r"[IVXLCDM]+|[0-9]{1,3}" if lang in _ROMAN_HEADING else r"[0-9]{1,3}"
        _HEAD_RX[lang] = re.compile(
            rf"^(?P<word>(?i:{_HEAD_WORDS[lang]}))?\s*(?P<num>{num})(?P<punct>[.:—–-]?)(?=\s|$)\s*(?P<rest>.*)$")
    return _HEAD_RX[lang]


_CJK_UNITS_ZH = "章节節回部卷巻篇編集幕场場话話课課讲講期"
_CJK_NUM = "零〇一二三四五六七八九十百千两"


def _heading_cjk(t: str, lang: str) -> str:
    m = re.match(rf"^(?P<label>第\s?(?P<n>[0-9]{{1,4}}|[{_CJK_NUM}]+)\s?(?P<u>[{_CJK_UNITS_ZH}]))(?P<punct>[：:.。、，,\s—–-]*)(?P<rest>.*)$", t)
    if m:
        n = m.group("n")
        if n.isdigit():
            label = "第" + say(n, lang, to="ordinal") + m.group("u")
        else:
            label = m.group("label").replace(" ", "")
        rest = m.group("rest").strip()
        return label + "。" + rest
    m = re.match(r"^(?P<num>[0-9]{1,3})(?P<punct>[.:。])?(?=\s|$)\s*(?P<rest>.*)$", t)
    if m:
        return say(m.group("num"), lang) + "。" + m.group("rest").strip()
    return t


def _heading_ko(t: str) -> str:
    m = re.match(r"^(?P<pre>제\s?)?(?P<n>[0-9]{1,4})\s?(?P<u>장|부|권|편|화|절|막|회)(?P<punct>[：:.,\s—–-]*)(?P<rest>.*)$", t)
    if m:
        label = ("제" if m.group("pre") else "") + words(int(m.group("n")), "ko") + m.group("u")
        return label + "." + (" " + m.group("rest").strip() if m.group("rest").strip() else "")
    m = re.match(r"^(?P<num>[0-9]{1,3})(?P<punct>[.:])?(?=\s|$)\s*(?P<rest>.*)$", t)
    if m:
        return words(int(m.group("num")), "ko") + "." + (" " + m.group("rest").strip() if m.group("rest").strip() else "")
    return t


def heading_to_speech_ml(text: str, lang: str) -> str:
    """'Capítulo IV' -> 'Capítulo cuatro.'; 'Глава 5' -> 'Глава пятая.'; '第12章 风雪' -> '第十二章。风雪'."""
    t = text.strip()
    if lang == "ar":
        t = to_western_digits(t)
    elif lang in ("zh", "ja"):
        t = _fullwidth_to_ascii(t)
    if lang in ("zh", "ja"):
        return _heading_cjk(t, lang)
    if lang == "ko":
        return _heading_ko(t)
    m = _heading_rx(lang).match(t)
    if m:
        tok, word, punct, rest = m.group("num"), m.group("word"), m.group("punct"), m.group("rest").strip()
        n = int(tok) if tok.isdigit() else N.roman_to_int(tok)
        ok = n is not None and n > 0
        if ok and not word:
            if n > 100:
                ok = False
            elif tok == "I" and lang == "it" and rest and not punct:
                ok = False  # the Italian article "I"
        if ok:
            if N._mostly_upper(rest):
                rest = sentence_case_ml(rest)
            if lang == "hi":
                spoken = str(n)
            elif lang == "ar":
                spoken = (_ar_ordinal(n) if word else None) or say(str(n), "ar")
            elif lang == "ru" and word:
                low = word.lower()
                g = "f" if low in _RU_FEM_HEAD else "n" if low in _RU_NEUT_HEAD else "m"
                spoken = num2words(n, lang="ru", to="ordinal", gender=g)
            else:
                spoken = say(str(n), lang)
            head = f"{word.capitalize()} {spoken}" if word else _upper_first(spoken)
            end = "।" if lang == "hi" else "."
            return head + end + (" " + _upper_first(rest) if rest else "")
    return sentence_case_ml(t) if N._mostly_upper(t) else t


# ----------------------------------------------------------------------------- entry point

def normalize_paragraph_ml(text: str, lang: str, rules=None, is_heading: bool = False,
                           is_section_opening: bool = False) -> str:
    t = cleanup_ml(text, lang)
    if not t:
        return ""
    if is_heading:
        t = heading_to_speech_ml(t, lang)
    elif N._mostly_upper(t) and len(t.split()) >= 3:
        t = sentence_case_ml(t)
    elif is_section_opening:
        t = fix_small_caps_opening_ml(t)
    t = expand_abbreviations_ml(t, lang)
    t = expand_numbers_ml(t, lang)
    t = expand_symbols_ml(t, lang)
    if rules:
        t = rules.apply(t)
    t = re.sub(r"\s+([,.;:!?])", r"\1", t)
    t = re.sub(r"\s+", " ", t).strip()
    if lang in ("zh", "ja"):  # no spaces in Chinese or Japanese: drop those left around inserted words
        t = re.sub("(?<=[぀-ヿ㐀-鿿豈-﫿＀-￯]) | (?=[぀-ヿ㐀-鿿豈-﫿＀-￯])", "", t)
    if is_heading and t and t[-1] not in _TERMINATORS:
        t += {"zh": "。", "ja": "。", "hi": "।"}.get(lang, ".")
    return t
