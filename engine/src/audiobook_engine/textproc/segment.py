"""Split normalised paragraphs into sentence chunks sized for a TTS engine.

English and French text (and any pure Latin text with no language given) goes through the original rules,
unchanged. Text in another language or script (CJK, Arabic, Devanagari, Cyrillic, Spanish inverted marks...)
uses the extended rules at the bottom of the splitter: sentence ends without a following space (。 । ؟),
openers and capitals of other scripts, per-language no-break abbreviations, and a grapheme-safe hard split for
text without spaces.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

# A sentence ends at . ! ? (or ...) possibly followed by closing quotes/brackets,
# which French sets off with a space ("Bonjour. » Puis"), then whitespace and
# something that can start a sentence.
_SENT_END = re.compile(
    r"(?<=[.!?])(?:\s?[\"'»)\]])*\s+(?=[\"'«(\[—–-]?\s*[A-ZÀ-ÝÉ0-9])"
)
# A period that closes an initial or an abbreviation is not a sentence end:
# "J. K. Rowling", "J.K.", "J.-M. Le Pen", "the U.S. Army", "five p.m. Smith", "Gov. Smith".
_NO_BREAK = re.compile(
    r"(?:^|[\s(\"'«])(?:[A-Z]|(?:[A-Za-z]\.)+[A-Za-z]|(?:[A-ZÀ-Ý]\.-)+[A-ZÀ-Ý]"
    r"|Mr|Mrs|Ms|Messrs|Dr|Prof|Gov|Pres|Sen|Rep|Fr|Rev|Gen|Col|Capt|Lt|Sgt|Hon|St|Ste|Mt|vs|MM|Mme|Mlle|Mgr)\.$"
)
# After a dotted abbreviation ("U.S.", "p.m.") a word that usually opens a sentence does start
# one: "He moved to the U.S. The weather was better." A name does not: "the U.S. Army".
_DOTTED_ABBR = re.compile(r"(?:^|[\s(\"'«])(?:[A-Za-z]\.)+[A-Za-z]\.$")
_STARTER = re.compile(
    r"[\"'«(\[—–-]?\s*(?:The|He|She|It|We|They|You|His|Her|Its|Our|Their|My|Your|This|That|These|Those|"
    r"There|Then|But|So|Yet|Now|When|While|After|Before|If|What|Who|How|Why|Where|"
    r"Il|Elle|Ils|Elles|Je|Nous|Vous|On|Mais|Puis|Alors|Cependant)\b"
)
# The abbreviation checks look at the end of the pending sentence only, so splitting stays
# linear however many abbreviations a paragraph holds.
_LOOKBACK = 64
# A chunk must contain something to say: a lone "»" or "* * *" is never sent to a TTS engine.
_SPEAKABLE = re.compile(r"[^\W_]")


@dataclass
class Chunk:
    section: int          # section index in the book
    paragraph: int        # paragraph index within the normalised section
    index: int            # chunk index within the section
    text: str
    paragraph_end: bool   # last chunk of its paragraph (longer pause follows)
    is_heading: bool = False

    @property
    def chars(self) -> int:
        return len(self.text)


def _abbreviation_before(text: str, start: int, m: re.Match, no_break: re.Pattern = _NO_BREAK,
                         dotted: re.Pattern = _DOTTED_ABBR, starter: re.Pattern = _STARTER) -> bool:
    """True when the period before m ends an initial or an abbreviation, not a sentence."""
    end = m.start()
    lo = max(start, end - _LOOKBACK)
    # Searching from lo - 1 lets the pattern see the space before the window (text[start - 1] is
    # always the space that ended the previous sentence); "^" matches only at position 0.
    pos = lo - 1 if lo > 0 else 0
    if not no_break.search(text, pos, end):
        return False
    return not (dotted.search(text, pos, end) and starter.match(text, m.end()))


def split_sentences(text: str, lang: str | None = None) -> list[str]:
    if _extended(text, lang):
        return _split_sentences_ext(text, lang)
    parts: list[str] = []
    start = 0
    for m in _SENT_END.finditer(text):
        # A closing quote or bracket after the period confirms the sentence end ('the U.S." She').
        if not m.group(0).strip() and _abbreviation_before(text, start, m):
            continue
        parts.append((text[start:m.start()].rstrip() + text[m.start():m.end()].rstrip()).strip())
        start = m.end()
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return [p for p in parts if p]


def _split_long(sentence: str, cap: int, lang: str | None = None) -> list[str]:
    """Split a sentence longer than cap at ; : , — then at spaces."""
    if len(sentence) <= cap:
        return [sentence]
    if _extended(sentence, lang):
        return _split_long_ext(sentence, cap, lang)
    for sep in (r"(?<=[;:])\s+", r"(?<=,)\s+", r"\s+(?=—)"):
        pieces = re.split(sep, sentence)
        if len(pieces) > 1:
            out: list[str] = []
            buf = ""
            for p in pieces:
                cand = f"{buf} {p}".strip()
                if len(cand) <= cap:
                    buf = cand
                else:
                    if buf:
                        out.append(buf)
                    buf = p
            if buf:
                out.append(buf)
            if all(len(o) <= cap for o in out):
                return out
            return [x for o in out for x in _split_long(o, cap)]
    words = sentence.split()
    out, buf = [], ""
    for w in words:
        cand = f"{buf} {w}".strip()
        if len(cand) <= cap or not buf:
            buf = cand
        else:
            out.append(buf)
            buf = w
    if buf:
        out.append(buf)
    return out


def chunk_section(section_index: int, paragraphs: list[str], cap: int,
                  first_is_heading: bool = True, min_chars: int = 0, lang: str | None = None) -> list[Chunk]:
    """Pack whole sentences into chunks of at most `cap` characters.

    Chunks never cross a paragraph boundary, so paragraph pauses stay exact.
    `min_chars` merges very short trailing chunks into the previous one when
    possible (some models hallucinate on tiny inputs). A chunk with no letter
    or digit (a stray "»", a "* * *" scene break) is dropped. `lang` selects the language rules for
    non-English/French text; for those chunks never exceed `cap` (also when merging a short tail).
    """
    chunks: list[Chunk] = []
    idx = 0
    for p_i, para in enumerate(paragraphs):
        heading = first_is_heading and p_i == 0
        ext = _extended(para, lang)
        sentences = [s for sent in split_sentences(para, lang) for s in _split_long(sent, cap, lang)]
        packed: list[str] = []
        buf = ""
        for s in sentences:
            cand = (_join(buf, s) if ext else f"{buf} {s}").strip()
            if len(cand) <= cap:
                buf = cand
            else:
                if buf:
                    packed.append(buf)
                buf = s
        if buf:
            packed.append(buf)
        if min_chars and len(packed) > 1 and len(packed[-1]) < min_chars:
            merged = _join(packed[-2], packed[-1]) if ext else f"{packed[-2]} {packed[-1]}"
            if len(merged) <= (cap if ext else cap * 1.25) and (ext or len(packed[-2]) + len(packed[-1]) + 1 <= cap * 1.25):
                packed[-2] = merged
                packed.pop()
        packed = [t for t in packed if _SPEAKABLE.search(t)]
        for k, text in enumerate(packed):
            chunks.append(Chunk(section_index, p_i, idx, text, k == len(packed) - 1, heading))
            idx += 1
    return chunks


# ----------------------------------------------------------------------------- extended rules
#
# Languages other than English and French, and scripts other than Latin. A text takes this path when a
# language other than en/fr is given, or when it holds a character the original rules know nothing about.

_LEGACY_LANGS = (None, "en", "fr")
_EXT_CHARS = re.compile(
    "[Ѐ-ԯ֐-ࣿऀ-෿ᄀ-ᇿ　-鿿가-힯豈-﫿ﭐ-﷿"
    "ﹰ-﻿＀-￯¿¡„]")
_CJK = "　-〿぀-ヿ㐀-䶿一-鿿豈-﫿＀-￯"
_CJK_RX = re.compile(f"[{_CJK}]")
# Characters that can start a sentence besides a Latin capital or a digit: Cyrillic capitals and every
# character of the scripts without case (Arabic, Devanagari, Hangul, CJK).
_CASELESS = ("؀-ۿݐ-ݿࢠ-ࣿﭐ-﷿ﹰ-﻿ऀ-ॿᄀ-ᇿ"
             "㄰-㆏가-힯" + _CJK)
_STARTERS_EXT = rf"A-ZÀ-ÝÉ0-9А-ЯЁІЇЄҐ{_CASELESS}"
_CLOSERS_EXT = "\"'»)\\]“”‘’›」』）》】〉"
_OPENERS_EXT = "\"'«(\\[—–\\-¿¡„“‹「『（《【〈"
# Terminators that end a sentence even when no space follows them.
_TERM_NOSPACE = "。！？；｡।॥؟۔"
_SENT_END_EXT = re.compile(
    rf"(?P<A>(?<=[{_TERM_NOSPACE}])(?:\s?[{_CLOSERS_EXT}])*\s+"
    rf"|(?<=[.!?])(?:\s?[{_CLOSERS_EXT}])*\s+(?=[{_OPENERS_EXT}]?\s*[{_STARTERS_EXT}]))"
    rf"|(?P<B>(?<=[{_TERM_NOSPACE}])[{_CLOSERS_EXT}]*(?![\s{_CLOSERS_EXT}{_TERM_NOSPACE}.!?]))"
    rf"|(?P<C>(?<=[{_CJK}]\.\.\.)(?=[{_CJK}])|(?<=[{_CJK}…]…)(?=[{_CJK}]))")

_ABBREVIATIONS = {
    "es": "Sr|Sra|Srta|Sres|Sras|Dr|Dra|Dña|Prof|Profa|Ud|Uds|Av|Avda|Gral|Excmo|Excma|Ilmo|Lic|Ing|Sta|Sto|pág|págs|"
          "núm|art|cap|vs|aprox|D",
    "de": "Hr|Hrn|Fr|Frl|Dr|Prof|St|Nr|Str|bzw|ca|vgl|evtl|inkl|ggf|Mio|Mrd|Jh|geb|gest|max|Abb|Tel|Std",
    "it": "Sig|Dott|Prof|Ing|Avv|Geom|cfr|pag|pagg|cap|sec|art|ca|vs|Sig\\.ra|Sig\\.na|Dott\\.ssa|Prof\\.ssa",
    "pt": "Sr|Sra|Srta|Dr|Dra|Prof|Profa|Av|Exmo|Exma|Ltda|Cia|Sto|Sta|pág|págs|cap|art|vs|aprox",
    "nl": "Dhr|Mevr|Mw|Drs|Dr|Ir|Prof|bijv|bv|blz|nr|ca|ong",
    "ru": "проф|акад|стр|рис|гл|тыс|млн|млрд|руб|коп|напр|ул|пр|им|г|гг|в|вв|см|экз|обл|р|д|корп|кв|оф",
}
# Capitalised words that usually open a sentence (see _STARTER): after a dotted abbreviation they start one.
_STARTERS = {
    "es": "El|La|Los|Las|Un|Una|Él|Ella|Ellos|Ellas|Yo|Tú|Nosotros|Pero|Y|Entonces|Cuando|Mientras|Después|Antes|Si|"
          "Qué|Quién|Cómo|Dónde",
    "de": "Der|Die|Das|Er|Sie|Es|Wir|Ihr|Ich|Du|Aber|Und|Dann|Als|Wenn|Nach|Vor|Wie|Wer|Was|Warum|Wo|Dort|Hier",
    "it": "Il|Lo|La|I|Gli|Le|Un|Una|Lui|Lei|Loro|Io|Tu|Noi|Ma|E|Poi|Quando|Mentre|Dopo|Prima|Se|Che|Chi|Come|Dove",
    "pt": "O|A|Os|As|Um|Uma|Ele|Ela|Eles|Elas|Eu|Tu|Nós|Mas|E|Então|Quando|Enquanto|Depois|Antes|Se|Que|Quem|Como|Onde",
    "nl": "De|Het|Een|Hij|Zij|Ze|Wij|Ik|Jij|Maar|En|Toen|Als|Terwijl|Na|Voor|Wat|Wie|Hoe|Waarom|Waar",
    "ru": "Он|Она|Они|Оно|Мы|Вы|Я|Ты|Но|И|Потом|Когда|Пока|После|Перед|Если|Что|Кто|Как|Почему|Где|Это|Эти|Этот",
}
_CYR_NB = r"[А-ЯЁ]|(?:[а-яё]\.)+[а-яё]"
_LATIN_INITIAL = r"[A-ZÀ-Ý]|(?:[A-Za-zà-ÿ]\.)+[A-Za-zà-ÿ]|(?:[A-ZÀ-Ý]\.-)+[A-ZÀ-Ý]"


def _lang_key(lang: str | None) -> str | None:
    if not lang:
        return None
    from .. import languages

    return languages.normalize_code(lang)


def _legacy_lang(lang: str | None) -> bool:
    """No language, English or French in any spelling ("en-US", "FR"), or a code nobody knows (read as
    English, like the normaliser does)."""
    if lang in _LEGACY_LANGS:
        return True
    return _lang_key(lang) in (None, "en", "fr")


def _extended(text: str, lang: str | None) -> bool:
    """True when `text` needs the extended rules (see the block comment above)."""
    return not _legacy_lang(lang) or bool(_EXT_CHARS.search(text))


_NB_CACHE: dict = {}


def _abbr_patterns(lang: str | None, text: str):
    key = None if _legacy_lang(lang) else _lang_key(lang)
    if key is None and re.search("[А-Яа-яЁё]", text):
        key = "ru"
    if key in _NB_CACHE:
        return _NB_CACHE[key]
    names = "|".join(n if "\\" in n else f"[{n[0].upper()}{n[0].lower()}]{n[1:]}"
                     for n in _ABBREVIATIONS.get(key, "").split("|") if n)
    extra = f"|{names}" if names else ""
    # a single capital letter is an initial (Latin, accented, Cyrillic); in German and Dutch single lowercase
    # letters are the pieces of "z. B.", "d. h.", "o.a."
    lower_single = r"|[a-zäöü]" if key in ("de", "nl") else (r"|[а-яё]" if key == "ru" else "")
    nb = re.compile(rf"(?:^|[\s(\"'«„¿¡])(?:{_LATIN_INITIAL}|{_CYR_NB}{lower_single}{extra})\.$")
    dotted = re.compile(r"(?:^|[\s(\"'«„¿¡])(?:[A-Za-z]\.|[а-яё]\.)+[A-Za-zа-яё]\.$")
    starters = _STARTERS.get(key)
    starter = re.compile(rf"[\"'«„(\[—–¿¡-]?\s*(?:{starters})\b") if starters else _STARTER
    _NB_CACHE[key] = (nb, dotted, starter)
    return _NB_CACHE[key]


def _split_sentences_ext(text: str, lang: str | None) -> list[str]:
    nb, dotted, starter = _abbr_patterns(lang, text)
    parts: list[str] = []
    start = 0
    for m in _SENT_END_EXT.finditer(text):
        # a period closing an initial or an abbreviation is not a sentence end ("И. И. Иванов", "z. B. dies")
        if m.lastgroup == "A" and not m.group(0).strip() and text[m.start() - 1:m.start()] == "." \
                and _abbreviation_before(text, start, m, nb, dotted, starter):
            continue
        piece = (text[start:m.start()].rstrip() + text[m.start():m.end()].rstrip()).strip()
        if piece:
            parts.append(piece)
        start = m.end()
    tail = text[start:].strip()
    if tail:
        parts.append(tail)
    return [p for p in parts if p]


# --- grapheme-safe cutting

_JOINERS = "\u200c\u200d"


def _hangul_class(c: str) -> str:
    o = ord(c)
    if 0x1100 <= o <= 0x115F or 0xA960 <= o <= 0xA97C:
        return "L"
    if 0x1160 <= o <= 0x11A7 or 0xD7B0 <= o <= 0xD7C6:
        return "V"
    if 0x11A8 <= o <= 0x11FF or 0xD7CB <= o <= 0xD7FB:
        return "T"
    if 0xAC00 <= o <= 0xD7A3:
        return "LV" if (o - 0xAC00) % 28 == 0 else "LVT"
    return ""


def _hangul_joined(prev: str, cur: str) -> bool:
    """Unicode's rules for the jamo of one syllable (L V T): no cut between them."""
    p, c = _hangul_class(prev), _hangul_class(cur)
    return bool(p and c) and ((p == "L" and c in ("L", "V", "LV", "LVT")) or (p in ("LV", "V") and c in ("V", "T"))
                              or (p in ("LVT", "T") and c == "T"))


def _is_boundary(s: str, i: int) -> bool:
    """True when s may be cut between s[i-1] and s[i]: never inside a base letter with its combining marks,
    a Devanagari conjunct (consonant + virama + consonant), a ZWJ/ZWNJ sequence, a Hangul jamo syllable, a
    flag (two regional indicators) or an emoji with a skin-tone modifier or variation selector."""
    if i <= 0 or i >= len(s):
        return True
    prev, cur = s[i - 1], s[i]
    if cur in _JOINERS or prev == "\u200d":
        return False
    if unicodedata.category(cur).startswith("M") or unicodedata.combining(prev) == 9:
        return False
    o = ord(cur)
    if 0x1F3FB <= o <= 0x1F3FF or 0xE0020 <= o <= 0xE007F or 0xFE00 <= o <= 0xFE0F:
        return False
    if _hangul_joined(prev, cur):
        return False
    if 0x1F1E6 <= o <= 0x1F1FF and 0x1F1E6 <= ord(prev) <= 0x1F1FF:
        run = 0
        j = i - 1
        while j >= 0 and 0x1F1E6 <= ord(s[j]) <= 0x1F1FF:
            run += 1
            j -= 1
        return run % 2 == 0
    return True


def _hard_split(s: str, cap: int) -> list[str]:
    """Cut s into pieces of at most `cap` characters at grapheme boundaries, preferably after a space or a
    punctuation mark, and not in the middle of a Latin word or number."""
    out: list[str] = []
    s = s.strip()
    while len(s) > cap:
        cut = _best_cut(s, cap)
        # never leave a remainder that is only punctuation: it would be dropped as unspeakable
        if len(s) - cut < 3 and _only_punctuation(s[cut:]):
            earlier = next((c for c in range(cut - 1, 0, -1) if _is_boundary(s, c)), 0)
            cut = earlier or cut
        piece, s = s[:cut].rstrip(), s[cut:].lstrip()
        if piece:
            out.append(piece)
    if s:
        out.append(s)
    return out


def _only_punctuation(s: str) -> bool:
    return bool(s) and all(c.isspace() or unicodedata.category(c)[0] == "P" for c in s)


def _best_cut(s: str, cap: int) -> int:
    """The position (1..cap) at which to cut s: after a space or punctuation mark in the second half of the
    window; else the last grapheme boundary that is not inside a Latin word or number; else the last
    grapheme boundary; else `cap` itself (a single cluster longer than the cap cannot be kept whole)."""
    lo = max(1, cap // 2)
    inner = last = 0
    for i in range(cap, 0, -1):
        if not _is_boundary(s, i):
            continue
        a, b = s[i - 1], s[i] if i < len(s) else " "
        if i >= lo and (a.isspace() or b.isspace() or unicodedata.category(a).startswith("P")):
            return i
        last = last or i
        if not inner and not (a.isascii() and a.isalnum() and b.isascii() and b.isalnum()):
            inner = i
    return inner or last or cap


# --- splitting a long sentence

_CLAUSE_LEVELS = (
    re.compile(r"(?<=[;:؛])\s+|(?<=[；：])\s*"),
    re.compile(r"(?<=[,،])\s+|(?<=[，、])\s*"),
    re.compile(r"\s+(?=—)"),
)


def _join(a: str, b: str) -> str:
    """Join two pieces of text: with a space, except where either side touches Chinese or Japanese text."""
    if not a:
        return b
    if not b:
        return a
    if _CJK_RX.match(a[-1]) or _CJK_RX.match(b[0]):
        return a + b
    return f"{a} {b}"


def _pieces(sentence: str, rx: re.Pattern) -> list[str]:
    """Split at rx, keeping the separator out of the text but remembering whether it was empty."""
    out, last = [], 0
    for m in rx.finditer(sentence):
        if m.end() == last or m.start() >= len(sentence):
            continue
        out.append(sentence[last:m.start()])
        last = m.end()
    out.append(sentence[last:])
    return [p for p in out if p]


def _pack(pieces: list[str], cap: int) -> list[str]:
    out: list[str] = []
    buf = ""
    for p in pieces:
        cand = _join(buf, p)
        if len(cand) <= cap:
            buf = cand
        else:
            if buf:
                out.append(buf)
            buf = p
    if buf:
        out.append(buf)
    return out


def _split_long_ext(sentence: str, cap: int, lang: str | None = None) -> list[str]:
    if len(sentence) <= cap:
        return [sentence]
    for rx in _CLAUSE_LEVELS:
        pieces = _pieces(sentence, rx)
        if len(pieces) > 1:
            out = _pack(pieces, cap)
            if all(len(o) <= cap for o in out):
                return out
            return [x for o in out for x in _split_long_ext(o, cap, lang)]
    words = sentence.split()
    if len(words) > 1:
        out = _pack(words, cap)
        if all(len(o) <= cap for o in out):
            return out
        return [x for o in out for x in _split_long_ext(o, cap, lang)]
    return _hard_split(sentence, cap)
