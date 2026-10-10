"""Listening-time estimates that follow the book's language.

`Section.est_seconds` in models.py uses one rate for every language (0.065 s per character, measured on
English and French). A character of Chinese or Japanese holds far more speech than one of English, so
sections made by ingest are `LangSection`s: a Section that carries its own seconds-per-character,
taken from the language registry (`languages.get(lang).sec_per_char`). English and French keep 0.065.
"""

from __future__ import annotations

from dataclasses import dataclass

from .. import languages
from ..models import SECONDS_PER_CHAR, Book, Section


def seconds_per_char(lang: str | None) -> float:
    """Audio seconds per source character for `lang` (any spelling the registry accepts); 0.065 if unknown."""
    try:
        return languages.get(lang or "").sec_per_char
    except KeyError:
        return SECONDS_PER_CHAR


def estimate_seconds(chars: int, lang: str | None) -> float:
    return chars * seconds_per_char(lang)


@dataclass
class LangSection(Section):
    sec_per_char: float = SECONDS_PER_CHAR

    @property
    def est_seconds(self) -> float:
        return self.chars * self.sec_per_char

    @property
    def first_words(self) -> str:
        text = " ".join(self.paragraphs)
        words = text.split()
        head = " ".join(words[:18])
        if len(head) > 200:  # no spaces between words (Chinese, Japanese): cut by characters
            return head[:90].rstrip() + "…"
        return head + ("…" if len(words) > 18 else "")


def apply_language(book: Book, lang: str | None = None) -> float:
    """Give every section of `book` the listening-time rate of `lang` (default: the book's language).

    Returns the rate. Also records it in book.metadata with the estimated minutes of the included sections.
    """
    rate = seconds_per_char(lang or book.language)
    for sec in book.sections:
        if isinstance(sec, LangSection):
            sec.sec_per_char = rate
    book.metadata["sec_per_char"] = rate
    book.metadata["est_minutes"] = round(sum(s.chars for s in book.sections if s.include) * rate / 60, 1)
    return rate
