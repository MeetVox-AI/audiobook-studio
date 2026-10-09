"""Book ingest: EPUB and PDF to the shared Book model."""

from __future__ import annotations

from pathlib import Path

from ..models import Book, IngestError


def read_book(path: str | Path) -> Book:
    p = Path(path)
    if not p.exists():
        raise IngestError(f"File not found: {p}")
    suffix = p.suffix.lower()
    if suffix == ".epub":
        from .epub import read_epub

        return read_epub(p)
    if suffix == ".pdf":
        from .pdf import read_pdf

        return read_pdf(p)
    raise IngestError(f"Unsupported file type '{suffix}'. Use .epub or .pdf.")
