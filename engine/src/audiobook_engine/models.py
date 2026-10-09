"""Core data model shared by ingest, text processing, synthesis and the CLI."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Literal

# Seconds of narrated audio per input character. Measured ratio quoted across
# several open-source tools (abogen ≈ 0.069, Mistral's 500 chars ≈ 33 s ≈ 0.066).
# Used only for *estimates* before real measurements exist.
SECONDS_PER_CHAR = 0.065

SectionKind = Literal["chapter", "front", "back"]


@dataclass
class Section:
    index: int
    title: str
    kind: SectionKind
    paragraphs: list[str]
    # True when the first paragraph is the section's own heading, so the
    # narrator should not prepend the title a second time.
    starts_with_heading: bool = False
    include: bool = True
    reasons: list[str] = field(default_factory=list)

    @property
    def chars(self) -> int:
        return sum(len(p) for p in self.paragraphs)

    @property
    def est_seconds(self) -> float:
        return self.chars * SECONDS_PER_CHAR

    @property
    def first_words(self) -> str:
        text = " ".join(self.paragraphs)
        words = text.split()
        return " ".join(words[:18]) + ("…" if len(words) > 18 else "")

    def to_json(self) -> dict:
        return {
            "index": self.index,
            "title": self.title,
            "kind": self.kind,
            "include": self.include,
            "chars": self.chars,
            "est_seconds": round(self.est_seconds, 1),
            "paragraphs": len(self.paragraphs),
            "first_words": self.first_words,
            "reasons": self.reasons,
        }


@dataclass
class Cover:
    data: bytes
    media_type: str  # e.g. image/jpeg, image/png
    source: str  # where it came from, for transparency


@dataclass
class Book:
    source_path: str
    format: Literal["epub", "pdf"]
    title: str
    author: str
    language: str  # "en", "fr", or other ISO 639-1 code
    language_source: str  # "metadata" or "detected"
    sections: list[Section]
    cover: Cover | None = None
    warnings: list[str] = field(default_factory=list)
    metadata: dict = field(default_factory=dict)

    @property
    def chars(self) -> int:
        return sum(s.chars for s in self.sections if s.include)

    def to_json(self) -> dict:
        return {
            "source_path": self.source_path,
            "format": self.format,
            "title": self.title,
            "author": self.author,
            "language": self.language,
            "language_source": self.language_source,
            "cover": None
            if self.cover is None
            else {"media_type": self.cover.media_type, "bytes": len(self.cover.data), "source": self.cover.source},
            "sections": [s.to_json() for s in self.sections],
            "included_chars": self.chars,
            "included_est_seconds": round(sum(s.est_seconds for s in self.sections if s.include), 1),
            "warnings": self.warnings,
            "metadata": self.metadata,
        }


class IngestError(Exception):
    """Raised when a book cannot be converted, with a user-facing message."""


__all__ = ["Book", "Cover", "IngestError", "Section", "SECONDS_PER_CHAR", "asdict"]
