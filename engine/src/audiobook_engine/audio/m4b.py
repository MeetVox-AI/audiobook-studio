"""ffmpeg helpers: loudness normalisation, cover, chapters metadata, M4B encode, verification."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from ..tools import find_tool

# Resolved once: PATH first, then Homebrew/MacPorts (apps launched from Finder lack Homebrew on PATH).
FFMPEG = find_tool("ffmpeg") or "ffmpeg"
FFPROBE = find_tool("ffprobe") or "ffprobe"

TARGET_I = -20.0   # LUFS, middle of the ACX -23..-18 window
TARGET_TP = -3.0   # dBTP


class FFmpegError(RuntimeError):
    pass


MISSING_MESSAGE = "ffmpeg/ffprobe not found. Install with: brew install ffmpeg"


def _run(args: list[str]) -> subprocess.CompletedProcess:
    try:
        proc = subprocess.run(args, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise FFmpegError(MISSING_MESSAGE) from exc
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.strip().splitlines()[-8:])
        raise FFmpegError(f"{Path(args[0]).name} failed ({proc.returncode}): {tail}")
    return proc


def check_tools() -> dict:
    """Fail fast (before any narration) when ffmpeg/ffprobe are unusable."""
    out = {}
    for name, path in (("ffmpeg", FFMPEG), ("ffprobe", FFPROBE)):
        out[name] = path if (os.path.isabs(path) and os.access(path, os.X_OK)) else shutil.which(path)
    if not out["ffmpeg"] or not out["ffprobe"]:
        raise FFmpegError(MISSING_MESSAGE)
    enc = _run([FFMPEG, "-hide_banner", "-encoders"]).stdout
    out["aac_encoder"] = "aac_at" if re.search(r"\baac_at\b", enc) else "aac"
    return out


def prepare_cover(data: bytes, media_type: str, work: Path) -> Path:
    """Write the cover as a JPEG whose longest side is at most 1600 px."""
    ext = {"image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/gif": ".gif",
           "image/webp": ".webp"}.get(media_type, ".img")
    raw = work / f"cover_src{ext}"
    raw.write_bytes(data)
    out = work / "cover.jpg"
    _run([FFMPEG, "-hide_banner", "-y", "-i", str(raw), "-frames:v", "1",
          "-vf", "scale='min(1600,iw)':'min(1600,ih)':force_original_aspect_ratio=decrease,format=yuvj420p",
          "-q:v", "3", str(out)])
    return out


def _esc(value: str) -> str:
    return re.sub(r"([=;#\\\n])", r"\\\1", value)


@dataclass
class ChapterMark:
    title: str
    start_ms: int
    end_ms: int


def write_metadata(path: Path, tags: dict[str, str], chapters: list[ChapterMark]) -> None:
    lines = [";FFMETADATA1"]
    for k, v in tags.items():
        if v:
            lines.append(f"{k}={_esc(str(v))}")
    for c in chapters:
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={c.start_ms}", f"END={c.end_ms}", f"title={_esc(c.title)}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _concat_entry(path: Path) -> str:
    # The concat demuxer resolves relative entries against the list file's folder, not the
    # current directory, so always write absolute paths.
    return "file '" + os.path.abspath(path).replace("'", "'\\''") + "'\n"


def _drain(stream, keep: deque) -> None:
    try:
        for line in stream:
            keep.append(line)
    except (OSError, ValueError):
        pass  # pipe closed under us: nothing more to keep


def _reap(proc: subprocess.Popen) -> None:
    """Kill the child and wait for it; never leaves an orphan ffmpeg behind."""
    if proc.poll() is None:
        proc.kill()
    proc.wait()


def encode_m4b(chapter_files: list[Path], metadata: Path, cover: Path | None, out: Path, *,
               bitrate_k: int = 64, total_seconds: float = 0.0, encoder: str = "aac_at",
               on_progress: Callable[[float], None] | None = None) -> None:
    work = metadata.parent
    listing = work / "concat.txt"
    listing.write_text("".join(_concat_entry(Path(p)) for p in chapter_files), encoding="utf-8")
    tmp = out.with_suffix(".partial.m4b")
    # -loglevel error: the info-level dump lists every chapter (input and output) and can
    # exceed a pipe buffer on long books; stderr is still drained concurrently below.
    args = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-nostats", "-progress", "pipe:1",
            "-f", "concat", "-safe", "0", "-i", str(listing), "-i", str(metadata)]
    if cover:
        args += ["-i", str(cover)]
    args += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
    if cover:
        args += ["-map", "2:v", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
    args += ["-c:a", encoder]
    if encoder == "aac_at":
        args += ["-aac_at_mode", "cbr"]
    args += ["-b:a", f"{bitrate_k}k", "-ac", "1", "-ar", "44100", "-sample_fmt", "s16" if encoder == "aac_at" else "fltp",
             "-metadata", "media_type=2", "-brand", "M4B ", "-movflags", "+faststart", "-f", "mp4", str(tmp)]
    err_tail: deque[str] = deque(maxlen=200)
    try:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace")
    except FileNotFoundError as exc:
        raise FFmpegError(MISSING_MESSAGE) from exc
    assert proc.stdout is not None and proc.stderr is not None
    # stderr is read on its own thread: if nobody reads it, a full pipe blocks ffmpeg while
    # this thread waits on stdout, and both hang forever.
    drainer = threading.Thread(target=_drain, args=(proc.stderr, err_tail), name="ffmpeg-stderr", daemon=True)
    drainer.start()
    try:
        for line in proc.stdout:
            if on_progress and total_seconds > 0 and line.startswith("out_time_us="):
                try:
                    on_progress(min(1.0, int(line.split("=", 1)[1]) / 1e6 / total_seconds))
                except ValueError:
                    pass
        code = proc.wait()
    except BaseException:
        # Cancelled (SIGTERM), a failing progress callback, ...: stop ffmpeg and drop the partial file.
        try:
            _reap(proc)
        finally:
            tmp.unlink(missing_ok=True)
        raise
    finally:
        drainer.join(timeout=5)  # ffmpeg has exited: stderr is at EOF
        proc.stdout.close()
        if not drainer.is_alive():
            proc.stderr.close()
    if code != 0:
        tmp.unlink(missing_ok=True)
        raise FFmpegError("M4B encode failed: " + "\n".join("".join(err_tail).strip().splitlines()[-8:]))
    tmp.replace(out)


def probe(path: Path) -> dict:
    p = _run([FFPROBE, "-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", str(path)])
    return json.loads(p.stdout)


def verify_m4b(path: Path, expected_chapters: int, expected_seconds: float, has_cover: bool) -> list[str]:
    """Return a list of problems (empty when the file looks right)."""
    info = probe(path)
    problems = []
    chapters = info.get("chapters", [])
    if len(chapters) != expected_chapters:
        problems.append(f"expected {expected_chapters} chapters, file has {len(chapters)}")
    dur = float(info.get("format", {}).get("duration", 0) or 0)
    if expected_seconds and abs(dur - expected_seconds) > max(2.0, 0.01 * expected_seconds):
        problems.append(f"duration {dur:.1f}s differs from expected {expected_seconds:.1f}s")
    streams = info.get("streams", [])
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    if not audio or audio[0].get("codec_name") != "aac":
        problems.append("no AAC audio stream")
    pics = [s for s in streams if s.get("disposition", {}).get("attached_pic") == 1]
    if has_cover and not pics:
        problems.append("cover image missing")
    brand = info.get("format", {}).get("tags", {}).get("major_brand", "")
    if brand.strip() != "M4B":
        problems.append(f"major brand is '{brand}', expected 'M4B'")
    return problems
