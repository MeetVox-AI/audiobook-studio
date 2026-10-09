"""Content-addressed chunk cache: a chunk is synthesised once per (text, voice, settings)."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import numpy as np
import soundfile as sf

from .textproc.normalize import NORMALIZER_VERSION


def chunk_key(text: str, lang: str, engine_fp: str, voice_fp: str, speed: float, seed: int | None) -> str:
    raw = "\x1f".join([NORMALIZER_VERSION, engine_fp, voice_fp, lang, f"{speed:.3f}", str(seed), text])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


class ChunkCache:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)

    def path(self, key: str) -> Path:
        return self.root / key[:2] / f"{key}.flac"

    def has(self, key: str) -> bool:
        return self.path(key).exists()

    def issues_path(self, key: str) -> Path:
        return self.root / key[:2] / f"{key}.issues.json"

    def get(self, key: str) -> tuple[np.ndarray, int] | None:
        p = self.path(key)
        if not p.exists():
            return None
        try:
            audio, sr = sf.read(str(p), dtype="float32")
        except (sf.SoundFileError, RuntimeError, OSError, ValueError):
            # Corrupt (e.g. interrupted write): resynthesise. Only decoding errors are caught:
            # a cancel (BaseException) raised while reading must propagate, not delete a chunk.
            p.unlink(missing_ok=True)
            self.issues_path(key).unlink(missing_ok=True)
            self.qa_path(key).unlink(missing_ok=True)
            return None
        return audio, sr

    def put(self, key: str, audio: np.ndarray, sample_rate: int, issues: list[str] | None = None) -> None:
        """Store a chunk and the validation issues it was kept with (none = clean)."""
        p = self.path(key)
        p.parent.mkdir(parents=True, exist_ok=True)
        # Issues first: a crash in between leaves at worst an orphan note, never an unflagged chunk.
        self.put_issues(key, issues)
        tmp = p.with_suffix(".tmp.flac")
        # 16-bit is ample for TTS output and halves disk use (FLAC is lossless on top).
        sf.write(str(tmp), np.clip(audio, -1.0, 1.0), sample_rate, subtype="PCM_16", format="FLAC")
        os.replace(tmp, p)  # atomic: a crash never leaves a half-written chunk

    def put_issues(self, key: str, issues: list[str] | None) -> None:
        """Remember why a chunk was flagged, so the report survives resumes and reruns."""
        ip = self.issues_path(key)
        if not issues:
            ip.unlink(missing_ok=True)
            return
        ip.parent.mkdir(parents=True, exist_ok=True)
        tmp = ip.with_suffix(".tmp")
        tmp.write_text(json.dumps(list(issues), ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, ip)

    def issues(self, key: str) -> list[str]:
        try:
            got = json.loads(self.issues_path(key).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        return [str(i) for i in got] if isinstance(got, list) else []

    # --- speech-check (QA) results -------------------------------------------------------------

    def qa_path(self, key: str) -> Path:
        return self.root / key[:2] / f"{key}.qa.json"

    def put_qa(self, key: str, result: dict) -> None:
        qp = self.qa_path(key)
        qp.parent.mkdir(parents=True, exist_ok=True)
        tmp = qp.with_suffix(".tmp")
        tmp.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, qp)

    def qa(self, key: str) -> dict | None:
        try:
            got = json.loads(self.qa_path(key).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return got if isinstance(got, dict) else None

    # --- housekeeping ------------------------------------------------------------------------

    def size_bytes(self) -> int:
        return tree_bytes(self.root)

    def clear(self) -> int:
        freed = 0
        for f in list(self.root.rglob("*")):
            try:
                if f.is_file():
                    size = f.stat().st_size
                    f.unlink()
                    freed += size
            except FileNotFoundError:
                continue  # replaced or removed meanwhile (a temporary file being renamed)
        return freed


def tree_bytes(root: Path) -> int:
    """Total size of the files under root; files that vanish while counting are skipped."""
    total = 0
    for f in root.rglob("*"):
        try:
            if f.is_file():
                total += f.stat().st_size
        except OSError:
            continue
    return total
