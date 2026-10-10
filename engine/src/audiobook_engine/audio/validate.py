"""Sanity checks on every synthesised chunk."""

from __future__ import annotations

import numpy as np

# Measured on this machine for Kokoro (0.058–0.063 s/char); other engines are
# in the same range. Used only for the duration-ratio check.
EXPECTED_SECONDS_PER_CHAR = 0.062


def seconds_per_char(lang: str | None = None) -> float:
    """Expected audio seconds per source character in `lang`: 0.062 for English and French, scaled by the
    language's registry speed for the others (Chinese and Japanese characters hold much more speech)."""
    if lang:
        from .. import languages

        try:
            return EXPECTED_SECONDS_PER_CHAR * (languages.get(lang).sec_per_char / 0.065)
        except KeyError:
            pass
    return EXPECTED_SECONDS_PER_CHAR


def check_chunk(audio: np.ndarray, sample_rate: int, chars: int, speed: float = 1.0,
                lang: str | None = None) -> list[str]:
    issues: list[str] = []
    if audio.size == 0:
        return ["empty audio"]
    if not np.all(np.isfinite(audio)):
        return ["invalid samples (NaN/Inf)"]
    rms = float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))
    if rms < 1e-3:
        issues.append("silent audio")
    expected = chars * seconds_per_char(lang) / max(speed, 0.1)
    if expected >= 25 * EXPECTED_SECONDS_PER_CHAR / max(speed, 0.1):   # long enough to judge (25 characters of English)
        dur = audio.size / sample_rate
        ratio = dur / expected
        if ratio < 0.4:
            issues.append(f"too short ({dur:.1f}s for ~{expected:.1f}s expected): words may be missing")
        elif ratio > 2.5:
            issues.append(f"too long ({dur:.1f}s for ~{expected:.1f}s expected): possible runaway or repetition")
    return issues
