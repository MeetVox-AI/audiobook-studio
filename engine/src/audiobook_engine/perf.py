"""Throughput tracking and time-remaining estimates.

Rates are characters of text synthesised per wall-clock second. The ETA uses
the slower of a recent window (follows thermal drift) and the run average
(prevents a cool-start burst from under-promising), and reports the faster
one as the optimistic bound. Rates are saved per engine/voice so the next job
starts from a measured number instead of a guess.
"""

from __future__ import annotations

import json
import statistics
import time
from collections import deque
from dataclasses import dataclass, field

from .paths import perf_file


@dataclass
class RateTracker:
    window_s: float = 300.0
    trim_outliers: bool = False
    _samples: deque = field(default_factory=deque)  # (t_end, chars, wall)
    total_chars: int = 0
    total_wall: float = 0.0

    def add(self, chars: int, wall: float, now: float | None = None) -> None:
        if chars <= 0 or wall <= 0:
            return
        now = time.monotonic() if now is None else now
        self._samples.append((now, chars, wall))
        self.total_chars += chars
        self.total_wall += wall
        while self._samples and now - self._samples[0][0] > self.window_s:
            self._samples.popleft()

    def _window(self) -> list[tuple[float, int, float]]:
        s = list(self._samples)
        if self.trim_outliers and len(s) >= 10:
            spc = sorted(w / c for _, c, w in s)
            med = statistics.median(spc)
            s = [x for x in s if x[2] / x[1] <= 3 * med]
        return s

    @property
    def window_rate(self) -> float | None:
        s = self._window()
        chars = sum(c for _, c, _ in s)
        wall = sum(w for _, _, w in s)
        return chars / wall if wall > 0 else None

    @property
    def run_rate(self) -> float | None:
        return self.total_chars / self.total_wall if self.total_wall > 0 else None

    def eta(self, remaining_chars: int, fallback_rate: float | None = None,
            tail_s: float = 0.0) -> tuple[float | None, float | None, float | None]:
        """(expected, low, high) seconds for the remaining characters, plus a fixed tail.

        Expected follows the recent window (validated on a 6.5 h book: within
        +1..+10% from 25% onwards). The range runs from the faster rate +10%
        to the slower of window and run average.
        """
        if remaining_chars <= 0:
            return tail_s, tail_s, tail_s
        rates = [r for r in (self.window_rate, self.run_rate) if r]
        if not rates:
            if not fallback_rate:
                return None, None, None
            base = remaining_chars / fallback_rate + tail_s
            return base, base * 0.8, base * 1.3
        expected_rate = self.window_rate or self.run_rate
        return (remaining_chars / expected_rate + tail_s,
                remaining_chars / (max(rates) * 1.1) + tail_s,
                remaining_chars / min(rates) + tail_s)


def _key(engine_id: str, voice_label: str) -> str:
    return f"{engine_id}|{voice_label}"


def load_rates() -> dict:
    """Saved measurements; entries without a usable rate are dropped (hand-edited or damaged file)."""
    p = perf_file()
    try:
        data = json.loads(p.read_text())
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, dict) and _rate(v) is not None}


def _rate(entry: dict) -> float | None:
    r = entry.get("chars_per_s")
    return float(r) if isinstance(r, (int, float)) and not isinstance(r, bool) and r > 0 else None


def saved_rate(engine_id: str, voice_label: str | None = None) -> float | None:
    """Best known chars/s for an engine (voice-specific if available)."""
    data = load_rates()
    if voice_label and _key(engine_id, voice_label) in data:
        return _rate(data[_key(engine_id, voice_label)])
    rates = [_rate(v) for k, v in data.items() if k.startswith(engine_id + "|")]
    return statistics.median(rates) if rates else None


def save_rate(engine_id: str, voice_label: str, chars: int, wall: float, audio_s: float, source: str) -> None:
    if chars < 200 or wall <= 0:
        return  # too little data to be meaningful
    data = load_rates()
    data[_key(engine_id, voice_label)] = {
        "chars_per_s": round(chars / wall, 2),
        "realtime_x": round(audio_s / wall, 2) if wall else None,
        "seconds_per_char": round(audio_s / chars, 4) if chars else None,
        "chars": chars,
        "source": source,
        "updated": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    p = perf_file()
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    tmp.replace(p)
