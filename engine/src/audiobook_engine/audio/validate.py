"""Sanity checks on every synthesised chunk."""

from __future__ import annotations

import numpy as np

# Measured on this machine for Kokoro (0.058–0.063 s/char); other engines are
# in the same range. Used only for the duration-ratio check.
EXPECTED_SECONDS_PER_CHAR = 0.062


def check_chunk(audio: np.ndarray, sample_rate: int, chars: int, speed: float = 1.0) -> list[str]:
    issues: list[str] = []
    if audio.size == 0:
        return ["empty audio"]
    if not np.all(np.isfinite(audio)):
        return ["invalid samples (NaN/Inf)"]
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    if rms < 1e-3:
        issues.append("silent audio")
    if chars >= 25:
        dur = audio.size / sample_rate
        expected = chars * EXPECTED_SECONDS_PER_CHAR / max(speed, 0.1)
        ratio = dur / expected
        if ratio < 0.4:
            issues.append(f"too short ({dur:.1f}s for ~{expected:.1f}s expected): words may be missing")
        elif ratio > 2.5:
            issues.append(f"too long ({dur:.1f}s for ~{expected:.1f}s expected): possible runaway or repetition")
    return issues
