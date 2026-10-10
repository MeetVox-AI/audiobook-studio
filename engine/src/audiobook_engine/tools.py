"""Locate the external command-line tools the engine needs (ffmpeg, ffprobe).

An app opened from Finder or the Dock gets launchd's minimal PATH
(/usr/bin:/bin:/usr/sbin:/sbin), which does not include Homebrew. So besides
PATH, look in the standard Homebrew and MacPorts locations. AUDIOBOOK_FFMPEG /
AUDIOBOOK_FFPROBE override the location explicitly.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

FALLBACK_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")


class ToolMissing(RuntimeError):
    pass


def find_tool(name: str) -> str | None:
    override = os.environ.get(f"AUDIOBOOK_{name.upper().replace('-', '_')}")
    if override:
        return override if os.access(override, os.X_OK) else None
    found = shutil.which(name)
    if found:
        return found
    for d in FALLBACK_DIRS:
        candidate = Path(d) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def require_tool(name: str, brew_formula: str | None = None) -> str:
    path = find_tool(name)
    if path is None:
        raise ToolMissing(f"{name} was not found. Install it with: brew install {brew_formula or name}")
    return path
