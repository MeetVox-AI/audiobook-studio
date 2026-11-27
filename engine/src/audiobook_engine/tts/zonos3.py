"""ZONOS3-Mini (Apache-2.0) via mlx-audio: the default narrator.

886M parameters, 100M active (MoE), 44.1 kHz, 43 languages, 27 built-in speaker embeddings and cloning
from a reference clip without a transcript. Real time on an M3 MacBook Air, so it fits a 16 GB Mac with room
for the speech check beside it.

Verified against mlx-audio 0.6.8 (models/zonos3):
- generate(text, voice=..., lang_code=..., speed=..., ref_audio=..., seed=..., text_normalization=...)
  is a generator; without `stream` it yields the finished audio once;
- `voice` is a key of the checkpoint's voices.json, `ref_audio` a path or 44.1 kHz mono array (no transcript);
- the model normalises text itself unless told not to; this engine normalises it already, so it passes False.

The checkpoint ships 27 voices; the two Telugu ones are left out because the app does not narrate Telugu.
There are no built-in voices for Russian, Japanese, Arabic or Dutch: for those languages the app falls back
to an installed reference voice and clones it (see VoiceSelection.suggested).
"""

from __future__ import annotations

import time

import numpy as np

from .. import languages as _languages
from .base import EngineError, EngineSpec, Voice, VoiceChoice, check_preset

CHECKPOINT = "mlx-community/ZONOS3-Mini"

# Curated from the checkpoint's voices.json: name, language, gender, accent, note. Narrator-like voices first
# because the first voice of a language is the one the app picks by default.
_VOICES = [
    ("thaddeus", "Thaddeus", "en", "male", "Announcer", "Calm announcer"),
    ("savannah", "Savannah", "en", "female", "American"),
    ("wyatt", "Wyatt", "en", "male", "American"),
    ("imogen", "Imogen", "en", "female", "British"),
    ("rupert", "Rupert", "en", "male", "British"),
    ("jett", "Jett", "en", "male", "Energetic"),
    ("willow", "Willow", "en", "female", "Soft", "ASMR-style delivery"),
    ("morgana", "Morgana", "en", "female", "Stylised", "Character voice"),
    ("sakura", "Sakura", "en", "female", "Stylised", "Anime-style delivery"),
    ("cillian", "Cillian", "en", "male", "Irish"),
    ("gaspard", "Gaspard", "fr", "male", "French"),
    ("liesel", "Liesel", "de", "female", "German"),
    ("wolfgang", "Wolfgang", "de", "male", "German"),
    ("ximena", "Ximena", "es", "female", "Spanish"),
    ("rodrigo", "Rodrigo", "es", "male", "Spanish"),
    ("ginevra", "Ginevra", "it", "female", "Italian"),
    ("lorenzo", "Lorenzo", "it", "male", "Italian"),
    ("leonor", "Leonor", "pt", "female", "Portuguese"),
    ("thiago", "Thiago", "pt", "male", "Portuguese"),
    ("haoran", "Haoran", "zh", "male", "Chinese", "Energetic delivery"),
    ("meilin", "Meilin", "zh", "female", "Chinese", "Energetic delivery"),
    ("seoyeon", "Seoyeon", "ko", "female", "Korean"),
    ("minjun", "Minjun", "ko", "male", "Korean"),
    ("ananya", "Ananya", "hi", "female", "Hindi"),
    ("arjun", "Arjun", "hi", "male", "Hindi"),
]


def _voice(row: tuple) -> Voice:
    preset, name, lang, gender, accent, *note = row
    return Voice(preset, name, lang, gender, accent, note[0] if note else "")


SPEC = EngineSpec(
    id="zonos3",
    name="ZONOS3-Mini",
    checkpoint=CHECKPOINT,
    languages=tuple(_languages.LANGUAGES),
    license="Apache-2.0",
    noncommercial=False,
    chunk_cap={c: round(400 * lang.chunk_scale) for c, lang in _languages.LANGUAGES.items()},
    min_chunk=12,
    batch_size=1,  # generate() takes one text; the pipeline batches for engines that support it
    supports_presets=True,
    supports_cloning=True,
    supports_speed=True,
    deterministic=False,
    download_gb=1.4,
    voices=[_voice(row) for row in _VOICES],
    notes="Fast multilingual narrator (44.1 kHz): 25 built-in voices in nine languages, any language by cloning. "
          "Russian, Japanese, Arabic and Dutch use a cloned reference voice.",
)


class Zonos3Engine:
    spec = SPEC
    # Defaults from the checkpoint's generation config; kept explicit so the chunk cache invalidates when they
    # change.
    temperature = 0.75
    top_k = 80
    top_p = 0.69
    repetition_penalty = 2.4

    def __init__(self):
        self.model = None

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate) if self.model is not None else 44100

    def load(self, voice: VoiceChoice | None = None) -> float:
        check_preset(self.spec, voice)  # a typo fails before 1.4 GB are read
        t0 = time.perf_counter()
        from mlx_audio.tts.utils import load_model

        self.model = load_model(CHECKPOINT)
        return time.perf_counter() - t0

    def settings_fingerprint(self) -> str:
        return (f"zonos3|{CHECKPOINT}|t{self.temperature}|k{self.top_k}|p{self.top_p}"
                f"|r{self.repetition_penalty}|norm0")

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        if self.model is None:
            raise EngineError("Model not loaded")
        check_preset(self.spec, voice)
        if not texts:
            return []
        if seed is not None:
            import mlx.core as mx

            mx.random.seed(seed)
        common = {"lang_code": lang, "speed": speed, "temperature": self.temperature, "top_k": self.top_k,
                  "top_p": self.top_p, "repetition_penalty": self.repetition_penalty,
                  "text_normalization": False}
        out = []
        for text in texts:
            if voice.ref_audio:
                results = self.model.generate(text=text, ref_audio=voice.ref_audio, **common)
            else:
                results = self.model.generate(text=text, voice=voice.preset, **common)
            parts = [np.asarray(r.audio, np.float32).reshape(-1) for r in results]
            out.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
        return out
