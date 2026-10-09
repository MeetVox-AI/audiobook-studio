"""Fish Audio S2 Pro (Fish Audio Research License, non-commercial) via mlx-audio.

Cloning only: without a reference clip the model picks a random speaker per
call, which would change voice between chunks. Verified against mlx-audio
0.5.8: ref_audio must be an mx.array at the model's 44.1 kHz rate, ref_text is
the clip transcript, and long text is chunked internally (chunk_length).
"""

from __future__ import annotations

import time

import numpy as np

from .base import EngineError, EngineSpec, VoiceChoice

CHECKPOINT = "mlx-community/fish-audio-s2-pro-8bit"
_NEEDS_CLIP = "Fish S2 Pro needs a reference clip (voice cloning) to keep one consistent voice."

SPEC = EngineSpec(
    id="fish",
    name="Fish Audio S2 Pro",
    checkpoint=CHECKPOINT,
    languages=("en", "fr"),
    license="Fish Audio Research License (non-commercial)",
    noncommercial=True,
    chunk_cap={"en": 400, "fr": 400},
    min_chunk=12,
    batch_size=1,
    supports_presets=False,
    supports_cloning=True,
    supports_speed=False,
    deterministic=False,
    download_gb=6.7,
    voices=[],
    notes="Highest-rated open model in blind tests. Clone-only: needs a 10-30 s reference clip with transcript. "
          "Speed on Apple Silicon is unpublished: run the benchmark first.",
)


class FishEngine:
    spec = SPEC
    temperature = 0.7
    top_p = 0.7
    top_k = 30

    def __init__(self):
        self.model = None
        self._ref_cache: dict[str, object] = {}

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate) if self.model is not None else 44100

    def load(self, voice: VoiceChoice | None = None) -> float:
        if voice is not None and not voice.ref_audio:
            raise EngineError(_NEEDS_CLIP)  # before loading 6.7 GB that synthesize() would then refuse
        t0 = time.perf_counter()
        from mlx_audio.tts.utils import load_model

        self.model = load_model(CHECKPOINT)
        return time.perf_counter() - t0

    def settings_fingerprint(self) -> str:
        return f"fish|{CHECKPOINT}|t{self.temperature}|k{self.top_k}|p{self.top_p}"

    def _ref(self, path: str):
        if path not in self._ref_cache:
            from mlx_audio.utils import load_audio

            self._ref_cache[path] = load_audio(path, sample_rate=self.sample_rate)
        return self._ref_cache[path]

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        import mlx.core as mx

        if self.model is None:
            raise EngineError("Model not loaded")
        if not voice.ref_audio:
            raise EngineError(_NEEDS_CLIP)
        if seed is not None:
            mx.random.seed(seed)
        ref = self._ref(voice.ref_audio)
        out = []
        for t in texts:
            # max_tokens left at the model default (1024): the codec frame rate is not
            # documented in the checkpoint config, and a wrong cap would truncate audio.
            parts = [np.asarray(r.audio, np.float32).reshape(-1)
                     for r in self.model.generate(text=t, ref_audio=ref, ref_text=voice.ref_text or "",
                                                  temperature=self.temperature, top_p=self.top_p, top_k=self.top_k,
                                                  chunk_length=400, verbose=False)]
            out.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
        return out
