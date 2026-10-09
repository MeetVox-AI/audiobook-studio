"""Split normalised paragraphs into sentence chunks sized for a TTS engine."""

from __future__ import annotations

import re
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


def _abbreviation_before(text: str, start: int, m: re.Match) -> bool:
    """True when the period before m ends an initial or an abbreviation, not a sentence."""
    end = m.start()
    lo = max(start, end - _LOOKBACK)
    # Searching from lo - 1 lets the pattern see the space before the window (text[start - 1] is
    # always the space that ended the previous sentence); "^" matches only at position 0.
    pos = lo - 1 if lo > 0 else 0
    if not _NO_BREAK.search(text, pos, end):
        return False
    return not (_DOTTED_ABBR.search(text, pos, end) and _STARTER.match(text, m.end()))


def split_sentences(text: str) -> list[str]:
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


def _split_long(sentence: str, cap: int) -> list[str]:
    """Split a sentence longer than cap at ; : , — then at spaces."""
    if len(sentence) <= cap:
        return [sentence]
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
                  first_is_heading: bool = True, min_chars: int = 0) -> list[Chunk]:
    """Pack whole sentences into chunks of at most `cap` characters.

    Chunks never cross a paragraph boundary, so paragraph pauses stay exact.
    `min_chars` merges very short trailing chunks into the previous one when
    possible (some models hallucinate on tiny inputs). A chunk with no letter
    or digit (a stray "»", a "* * *" scene break) is dropped.
    """
    chunks: list[Chunk] = []
    idx = 0
    for p_i, para in enumerate(paragraphs):
        heading = first_is_heading and p_i == 0
        sentences = [s for sent in split_sentences(para) for s in _split_long(sent, cap)]
        packed: list[str] = []
        buf = ""
        for s in sentences:
            cand = f"{buf} {s}".strip()
            if len(cand) <= cap:
                buf = cand
            else:
                if buf:
                    packed.append(buf)
                buf = s
        if buf:
            packed.append(buf)
        if min_chars and len(packed) > 1 and len(packed[-1]) < min_chars and len(packed[-2]) + len(packed[-1]) + 1 <= cap * 1.25:
            packed[-2] = f"{packed[-2]} {packed[-1]}"
            packed.pop()
        packed = [t for t in packed if _SPEAKABLE.search(t)]
        for k, text in enumerate(packed):
            chunks.append(Chunk(section_index, p_i, idx, text, k == len(packed) - 1, heading))
            idx += 1
    return chunks
