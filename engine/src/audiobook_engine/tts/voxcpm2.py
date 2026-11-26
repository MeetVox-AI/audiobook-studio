"""VoxCPM2 4-bit (Apache-2.0) via mlx-audio: studio-quality narration from a cloned voice.

2B parameters, 48 kHz output and the strongest speaker likeness of the engines here, at about real time on an
Apple Silicon Mac (so the 4-bit checkpoint is the one that fits 16 GB beside the speech check).

Verified against mlx-audio 0.6.8 (models/voxcpm2):
- generate(text, ref_audio=..., ref_text=..., inference_timesteps=..., cfg_value=...) is a generator;
- no preset speakers: a reference clip is required (`instruct=` would design a voice from a description;
  this engine does not use it, so the app's 251 reference voices stay the source of truth);
- no speed parameter and no batching: the pipeline synthesises one chunk at a time.
"""

from __future__ import annotations

import time

import numpy as np

from .. import languages as _languages
from .base import EngineError, EngineSpec, VoiceChoice

CHECKPOINT = "mlx-community/VoxCPM2-4bit"
_NEEDS_CLIP = "VoxCPM2 needs a reference clip (voice cloning) to keep one consistent narrator."

SPEC = EngineSpec(
    id="voxcpm2",
    name="VoxCPM2 4-bit (studio)",
    checkpoint=CHECKPOINT,
    languages=tuple(_languages.LANGUAGES),
    license="Apache-2.0",
    noncommercial=False,
    chunk_cap={c: round(400 * lang.chunk_scale) for c, lang in _languages.LANGUAGES.items()},
    min_chunk=12,
    batch_size=1,
    supports_presets=False,
    supports_cloning=True,
    supports_speed=False,
    deterministic=False,
    download_gb=2.3,
    voices=[],
    notes="Studio quality: 48 kHz and the closest match to a reference voice, but about real time — a 6-hour "
          "book takes about 6 hours. Needs a reference clip; no built-in voices.",
)


class VoxCPM2Engine:
    spec = SPEC
    inference_timesteps = 10   # CFM steps: the checkpoint default (more is slower, not clearly better)
    cfg_value = 2.0

    def __init__(self):
        self.model = None

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate) if self.model is not None else 48000

    def load(self, voice: VoiceChoice | None = None) -> float:
        if voice is not None and not voice.ref_audio:
            raise EngineError(_NEEDS_CLIP)   # before 2.3 GB are read
        t0 = time.perf_counter()
        from mlx_audio.tts.utils import load_model

        self.model = load_model(CHECKPOINT)
        return time.perf_counter() - t0

    def settings_fingerprint(self) -> str:
        return f"voxcpm2|{CHECKPOINT}|steps{self.inference_timesteps}|cfg{self.cfg_value}"

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        if self.model is None:
            raise EngineError("Model not loaded")
        if not voice.ref_audio:
            raise EngineError(_NEEDS_CLIP)
        if not texts:
            return []
        if seed is not None:
            import mlx.core as mx

            mx.random.seed(seed)
        common = {"ref_audio": voice.ref_audio, "inference_timesteps": self.inference_timesteps,
                  "cfg_value": self.cfg_value}
        if voice.ref_text:
            common["ref_text"] = voice.ref_text
        out = []
        for text in texts:
            parts = [np.asarray(r.audio, np.float32).reshape(-1)
                     for r in self.model.generate(text=text, **common)]
            out.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
        return out
