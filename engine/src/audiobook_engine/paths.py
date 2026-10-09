"""Where the engine keeps jobs, caches and measurements."""

from __future__ import annotations

import os
from pathlib import Path


def home() -> Path:
    base = os.environ.get("AUDIOBOOK_STUDIO_HOME")
    # Absolute: job folders are handed to ffmpeg and to detached children, which must not
    # depend on the current directory.
    p = Path(base).expanduser().absolute() if base else Path.home() / "Library" / "Application Support" / "AudiobookStudio"
    p.mkdir(parents=True, exist_ok=True)
    return p


def jobs_dir() -> Path:
    p = home() / "jobs"
    p.mkdir(parents=True, exist_ok=True)
    return p


def perf_file() -> Path:
    return home() / "perf.json"
