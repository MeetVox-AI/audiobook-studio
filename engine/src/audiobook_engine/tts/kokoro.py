"""Kokoro-82M via mlx-audio: fast draft engine, Apache-2.0.

Calls the cached per-language KokoroPipeline directly instead of
Model.generate(): generate() resets the voice cache and calls mx.clear_cache()
on every call, both of which cost time when called once per chunk.
Assumption (verified against mlx-audio 0.5.8 source): Model._get_pipeline(lang)
exists and the pipeline yields results with an `.audio` mx.array of shape [1, N].
"""

from __future__ import annotations

import time

import numpy as np

from .base import EngineError, EngineSpec, Voice, VoiceChoice, check_preset

_EN_VOICES = [
    ("af_heart", "Heart", "female", "American"), ("af_bella", "Bella", "female", "American"),
    ("af_nicole", "Nicole", "female", "American"), ("af_sarah", "Sarah", "female", "American"),
    ("af_sky", "Sky", "female", "American"), ("af_nova", "Nova", "female", "American"),
    ("am_michael", "Michael", "male", "American"), ("am_fenrir", "Fenrir", "male", "American"),
    ("am_puck", "Puck", "male", "American"), ("am_adam", "Adam", "male", "American"),
    ("am_echo", "Echo", "male", "American"), ("am_eric", "Eric", "male", "American"),
    ("bf_emma", "Emma", "female", "British"), ("bf_isabella", "Isabella", "female", "British"),
    ("bf_alice", "Alice", "female", "British"), ("bf_lily", "Lily", "female", "British"),
    ("bm_george", "George", "male", "British"), ("bm_fable", "Fable", "male", "British"),
    ("bm_lewis", "Lewis", "male", "British"), ("bm_daniel", "Daniel", "male", "British"),
]

# The other English voices of the checkpoint (lower-graded on the Kokoro voice card): accepted, not
# listed, so hand-typed ids and jobs started with them before voices were validated keep working.
_EXTRA_EN = ("af_alloy", "af_aoede", "af_jessica", "af_kore", "af_river", "am_liam", "am_onyx", "am_santa")

# A Kokoro voice id starts with the code of the one language it was made for (a = American English,
# b = British English, f = French). The same letter selects the KokoroPipeline (phonemizer), and
# mlx-audio warns "Language mismatch" when they differ (pipeline.py:201-206); passing a file path, as
# this adapter does, skips even that warning. A mismatched pair reads the text with the wrong accent.
_VOICE_LANG = {"a": "en", "b": "en", "f": "fr", "e": "es", "i": "it", "p": "pt", "h": "hi"}
# Voices of the checkpoint for the other languages (espeak-based phonemisation; Japanese and Chinese voices
# exist too but need extra libraries and are not offered).
_OTHER_VOICES = [
    ("ef_dora", "Dora", "es", "female", "Spanish"), ("em_alex", "Alex", "es", "male", "Spanish"),
    ("if_sara", "Sara", "it", "female", "Italian"), ("im_nicola", "Nicola", "it", "male", "Italian"),
    ("pf_dora", "Dora", "pt", "female", "Brazilian Portuguese"),
    ("pm_alex", "Alex", "pt", "male", "Brazilian Portuguese"),
    ("hf_alpha", "Alpha", "hi", "female", "Hindi"), ("hf_beta", "Beta", "hi", "female", "Hindi"),
    ("hm_omega", "Omega", "hi", "male", "Hindi"), ("hm_psi", "Psi", "hi", "male", "Hindi"),
]

SPEC = EngineSpec(
    id="kokoro",
    name="Kokoro 82M (fast draft)",
    checkpoint="mlx-community/Kokoro-82M-bf16",
    languages=("en", "fr", "es", "it", "pt", "hi"),
    license="Apache-2.0",
    noncommercial=False,
    # The non-English paths do no phoneme chunking (510-phoneme truncation), so their chunks are shorter.
    chunk_cap={"en": 320, "fr": 300, "es": 300, "it": 300, "pt": 300, "hi": 260},
    supports_presets=True,
    supports_cloning=False,
    supports_speed=True,
    deterministic=True,
    download_gb=0.35,
    voices=[Voice(v, n, "en", g, a) for v, n, g, a in _EN_VOICES]
    + [Voice("ff_siwis", "Siwis", "fr", "female", "French", "Only French voice; draft quality")]
    + [Voice(v, n, lang, g, a, "Draft quality") for v, n, lang, g, a in _OTHER_VOICES],
    notes="Fastest engine. English is very good; the other languages have draft-quality voices.",
    extra_voice_ids=_EXTRA_EN,
)


def _pipeline_code(voice: str, lang: str) -> str:
    """The KokoroPipeline code for this voice, or EngineError when the voice is not for `lang`."""
    code = voice[:1]
    if _VOICE_LANG.get(code) == lang:
        return code
    from .. import languages

    try:
        name = languages.get(lang).name
    except KeyError:
        name = f"'{lang}'"
    article = "an" if name[:1] in "AEIOU" else "a"
    fits = [v.id for v in SPEC.voices if v.lang == lang]
    raise EngineError(f"Kokoro voice '{voice}' is not {article} {name} voice: it would read {name} text with the "
                      f"wrong accent. {name} voices: {', '.join(fits) or 'none'}.")


class KokoroEngine:
    spec = SPEC

    def __init__(self, checkpoint: str | None = None):
        self.checkpoint = checkpoint or SPEC.checkpoint
        self.model = None
        self._voice_files: dict[str, str] = {}

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate) if self.model is not None else 24000

    def load(self, voice: VoiceChoice | None = None) -> float:
        check_preset(self.spec, voice)  # before the model load, so a typo fails fast
        t0 = time.perf_counter()
        from mlx_audio.tts.utils import load_model

        self.model = load_model(self.checkpoint)
        if not hasattr(self.model, "_get_pipeline"):
            raise EngineError("Unsupported mlx-audio version: Kokoro model has no _get_pipeline().")
        return time.perf_counter() - t0

    def voice_path(self, voice_id: str) -> str:
        """Local voice file from the checkpoint snapshot (never downloads during synthesis).

        mlx-audio would otherwise fetch voices lazily from another repository
        (prince-canuma/Kokoro-82M); the tensors are identical (verified), so
        cached audio stays valid.
        """
        if voice_id in self._voice_files:
            return self._voice_files[voice_id]
        from huggingface_hub import snapshot_download

        try:
            root = snapshot_download(self.checkpoint, allow_patterns=[f"voices/{voice_id}.safetensors"],
                                     local_files_only=True)
        except Exception as exc:
            raise EngineError(f"Kokoro voice '{voice_id}' is not installed. Run: audiobook-engine models download kokoro") from exc
        from pathlib import Path

        f = Path(root) / "voices" / f"{voice_id}.safetensors"
        if not f.exists():
            raise EngineError(f"Kokoro voice '{voice_id}' is not installed. Run: audiobook-engine models download kokoro")
        self._voice_files[voice_id] = str(f)
        return str(f)

    def settings_fingerprint(self) -> str:
        return f"kokoro|{self.checkpoint}"

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        if self.model is None:
            raise EngineError("Model not loaded")
        if not voice.preset:
            raise EngineError("Kokoro only supports preset voices (no cloning).")
        check_preset(self.spec, voice)
        pipeline = self.model._get_pipeline(_pipeline_code(voice.preset, lang))
        voice_file = self.voice_path(voice.preset)
        out: list[np.ndarray] = []
        for text in texts:
            pieces = []
            for result in pipeline(text, voice=voice_file, speed=speed, split_pattern=None):
                audio = result.audio
                if audio is None:
                    continue
                arr = np.asarray(audio, dtype=np.float32).reshape(-1)
                pieces.append(arr)
            out.append(np.concatenate(pieces) if pieces else np.zeros(0, dtype=np.float32))
        return out
