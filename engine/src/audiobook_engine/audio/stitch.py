"""Assemble chunk waveforms into a chapter with deliberate pauses."""

from __future__ import annotations

from dataclasses import asdict, dataclass

import numpy as np


@dataclass
class Pacing:
    """Silence (seconds) inserted between pieces. Set once per book."""

    chapter_lead_in: float = 0.5
    after_heading: float = 1.2
    sentence: float = 0.25
    paragraph: float = 0.65
    chapter_tail: float = 1.5

    def to_json(self) -> dict:
        return asdict(self)


def trim_silence(audio: np.ndarray, sample_rate: int, threshold_db: float = -45.0, margin_s: float = 0.03) -> np.ndarray:
    if audio.size == 0:
        return audio
    peak = float(np.max(np.abs(audio)))
    if peak <= 0:
        return audio[:0]
    thr = peak * (10 ** (threshold_db / 20))
    idx = np.nonzero(np.abs(audio) > thr)[0]
    if idx.size == 0:
        return audio[:0]
    m = int(margin_s * sample_rate)
    return audio[max(0, idx[0] - m): min(audio.size, idx[-1] + m + 1)]


def _fade(audio: np.ndarray, sample_rate: int, ms: float = 5.0) -> np.ndarray:
    n = min(int(sample_rate * ms / 1000), audio.size // 2)
    if n <= 1:
        return audio
    out = audio.copy()
    ramp = np.linspace(0.0, 1.0, n, dtype=np.float32)
    out[:n] *= ramp
    out[-n:] *= ramp[::-1]
    return out


def assemble(pieces: list[tuple[np.ndarray, bool, bool]], sample_rate: int, pacing: Pacing) -> np.ndarray:
    """pieces: (audio, is_heading, paragraph_end) in reading order."""
    sil = lambda s: np.zeros(int(round(s * sample_rate)), dtype=np.float32)  # noqa: E731
    out = [sil(pacing.chapter_lead_in)]
    for i, (audio, is_heading, paragraph_end) in enumerate(pieces):
        a = _fade(trim_silence(audio.astype(np.float32), sample_rate), sample_rate)
        out.append(a)
        if i == len(pieces) - 1:
            break
        if is_heading and paragraph_end:
            out.append(sil(pacing.after_heading))
        elif paragraph_end:
            out.append(sil(pacing.paragraph))
        else:
            out.append(sil(pacing.sentence))
    out.append(sil(pacing.chapter_tail))
    return np.concatenate(out)
