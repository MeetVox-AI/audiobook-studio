"""Loudness normalisation using ffmpeg's EBU R128 meter (ebur128) on in-memory audio.

The audio never touches disk here: float32 samples are piped to ffmpeg, which
only measures. The gain is applied in numpy. This is ~6x faster than ffmpeg's
two-pass `loudnorm` (which resamples to 192 kHz) and, for a single steady TTS
voice, equivalent to loudnorm's linear mode: one gain per chapter.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

import numpy as np

from .m4b import FFMPEG, FFmpegError, TARGET_I, TARGET_TP


@dataclass
class Loudness:
    integrated_lufs: float
    true_peak_db: float


def _pipe(audio: np.ndarray, sr: int, filters: str, want_audio: bool) -> tuple[bytes, str]:
    args = [FFMPEG, "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(sr), "-ac", "1", "-i", "pipe:0", "-af", filters]
    args += ["-f", "f32le", "-ac", "1", "pipe:1"] if want_audio else ["-f", "null", "-"]
    try:
        proc = subprocess.run(args, input=np.ascontiguousarray(audio, dtype="<f4").tobytes(), capture_output=True)
    except FileNotFoundError as exc:
        raise FFmpegError("ffmpeg not found. Install with: brew install ffmpeg") from exc
    if proc.returncode != 0:
        raise FFmpegError("ffmpeg failed: " + proc.stderr.decode(errors="replace")[-600:])
    return proc.stdout, proc.stderr.decode(errors="replace")


def measure(audio: np.ndarray, sr: int) -> Loudness:
    _, err = _pipe(audio, sr, "ebur128=peak=true:framelog=quiet", want_audio=False)
    summary = err[err.rfind("Summary:"):] if "Summary:" in err else err
    mi = re.search(r"I:\s+(-?[\d.]+|-inf)\s+LUFS", summary)
    mp = re.search(r"True peak:\s+Peak:\s+(-?[\d.]+|-inf)\s+dBFS", summary, flags=re.S)
    if not mi or not mp:
        raise FFmpegError("could not parse ebur128 summary")
    to_f = lambda s: float("-inf") if s == "-inf" else float(s)  # noqa: E731
    return Loudness(to_f(mi.group(1)), to_f(mp.group(1)))


def change_tempo(audio: np.ndarray, sr: int, factor: float) -> np.ndarray:
    """Pitch-preserving speed change (for engines without native speed control)."""
    if abs(factor - 1.0) < 1e-3 or audio.size == 0:
        return audio
    out, _ = _pipe(audio, sr, f"atempo={factor:.4f}", want_audio=True)
    return np.frombuffer(out, dtype="<f4").copy()


def normalize(audio: np.ndarray, sr: int, target_i: float = TARGET_I, max_tp: float = TARGET_TP) -> tuple[np.ndarray, dict]:
    """Gain to the loudness target; a brick-wall limiter keeps peaks under the ceiling.

    TTS speech often has peaks 20+ dB above its loudness, so a plain peak-safe
    gain would leave the book several LU too quiet. Limiting only the rare
    peaks lets the whole chapter reach the target.
    """
    if audio.size == 0:
        return audio, {"skipped": "empty"}
    before = measure(audio, sr)
    if before.integrated_lufs < -60 or not np.isfinite(before.integrated_lufs):
        return audio, {"skipped": "silent", "input_i": before.integrated_lufs}
    gain_db = target_i - before.integrated_lufs
    peak_after = before.true_peak_db + gain_db if np.isfinite(before.true_peak_db) else -99.0
    if peak_after <= max_tp:
        out = (audio * (10 ** (gain_db / 20))).astype(np.float32)
        limited = False
    else:
        # Sample-peak limit 1 dB under the true-peak ceiling (room for inter-sample peaks).
        # Limiting lowers loudness a little, so re-measure and add make-up gain (max 3 passes).
        limit = 10 ** ((max_tp - 1.0) / 20)  # 1 dB margin: AAC encoding adds inter-sample peaks
        limited = True
        for _ in range(3):
            raw, _ = _pipe(audio, sr, f"volume={gain_db:.3f}dB,alimiter=limit={limit:.4f}:level=false:attack=5:release=60:asc=1",
                           want_audio=True)
            out = np.frombuffer(raw, dtype="<f4").copy()
            after = measure(out, sr)
            miss = target_i - after.integrated_lufs
            if abs(miss) <= 0.3:
                break
            gain_db += miss
    return out, {"input_i": before.integrated_lufs, "input_tp": before.true_peak_db, "gain_db": round(gain_db, 2),
                 "peak_limited": limited}
