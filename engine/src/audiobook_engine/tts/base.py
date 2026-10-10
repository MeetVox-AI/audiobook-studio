"""TTS engine protocol and shared types."""

from __future__ import annotations

import hashlib
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

import numpy as np


@dataclass(frozen=True)
class Voice:
    id: str
    name: str
    lang: str            # "en", "fr", ...
    gender: str = ""     # "female" / "male" / ""
    accent: str = ""     # "American", "British", ...
    note: str = ""
    also: tuple[str, ...] = ()   # other languages this voice can speak, with an accent (Qwen3 speakers)

    def speaks(self, lang: str) -> bool:
        return lang == self.lang or lang in self.also


@dataclass(frozen=True)
class VoiceChoice:
    """Either a preset voice id, or a reference clip (+ transcript) to clone."""

    preset: str | None = None
    ref_audio: str | None = None
    ref_text: str | None = None

    def fingerprint(self) -> str:
        if self.ref_audio:
            digest = hashlib.sha256(Path(self.ref_audio).read_bytes()).hexdigest()[:16]
            return f"ref:{digest}:{hashlib.sha256((self.ref_text or '').encode()).hexdigest()[:8]}"
        return f"preset:{self.preset}"

    def label(self) -> str:
        return self.preset or (Path(self.ref_audio).stem if self.ref_audio else "default")


@dataclass
class EngineSpec:
    id: str
    name: str
    checkpoint: str
    languages: tuple[str, ...]
    license: str
    noncommercial: bool
    chunk_cap: dict[str, int]          # max characters per chunk, per language
    min_chunk: int = 0                 # merge tinier tail chunks (hallucination guard)
    batch_size: int = 1
    supports_presets: bool = True
    supports_cloning: bool = False
    supports_speed: bool = False       # native speed control
    deterministic: bool = False        # same input -> same audio (retries must change the input)
    download_gb: float = 0.0
    voices: list[Voice] = field(default_factory=list)   # curated list: what `engines` and the app show
    notes: str = ""
    # Other preset ids the checkpoint ships and the adapter accepts, but does not list (other accents,
    # lower-graded voices). Accepted so that hand-typed ids and jobs started with them keep working.
    extra_voice_ids: tuple[str, ...] = ()
    # True when the engine itself matches a requested preset case-insensitively (Qwen3: mlx-audio
    # lowercases the requested speaker name before looking it up).
    voice_ids_ignore_case: bool = False

    def cap_for(self, lang: str) -> int:
        return self.chunk_cap.get(lang, self.chunk_cap.get("*", 300))

    def to_json(self) -> dict:
        return {
            "id": self.id, "name": self.name, "checkpoint": self.checkpoint, "languages": list(self.languages),
            "license": self.license, "noncommercial": self.noncommercial, "batch_size": self.batch_size,
            "supports_presets": self.supports_presets, "supports_cloning": self.supports_cloning,
            "supports_speed": self.supports_speed, "download_gb": self.download_gb, "notes": self.notes,
            "voices": [v.__dict__ for v in self.voices],
        }


class TTSEngine(Protocol):
    spec: EngineSpec

    @property
    def sample_rate(self) -> int: ...

    def load(self, voice: VoiceChoice | None = None) -> float:
        """Load the weights needed for this voice; return seconds taken."""

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        """Return one float32 mono waveform per input text, in order."""

    def settings_fingerprint(self) -> str:
        """Everything besides text/voice/speed that changes the audio (sampling params, checkpoint)."""


class EngineError(Exception):
    pass


def _lang_name(lang: str) -> str:
    from .. import languages

    try:
        return languages.get(lang).name
    except KeyError:
        return f"'{lang}'"


def default_preset(spec: EngineSpec, lang: str) -> str:
    """The voice used when none is chosen: the engine's first listed preset made for `lang`.

    Raises EngineError when the engine has no such preset, rather than reading the book
    with a voice made for another language.
    """
    if not spec.supports_presets:
        raise EngineError(f"{spec.name} has no preset voices: give a reference clip with --ref-voice or --ref.")
    for v in spec.voices:
        if v.lang == lang:
            return v.id
    name = _lang_name(lang)
    clone = f" or clone a {name} voice with --ref-voice or --ref" if spec.supports_cloning else ""
    raise EngineError(f"{spec.name} has no {name} preset voice. Choose a voice with --voice "
                      f"({', '.join(v.id for v in spec.voices)}){clone}.")


def check_preset(spec: EngineSpec, voice: VoiceChoice | None, also: Iterable[str] = ()) -> None:
    """Raise EngineError unless `voice` is usable with this engine's preset voices.

    Preset-capable adapters call this before loading weights and before
    synthesising. Without it a typo ("george" for "bm_george") is not caught
    early: Qwen3 and Voxtral then synthesise with no speaker conditioning and
    give no error, and Kokoro wrongly asks for a model download.
    Accepted ids: `spec.voices` (the list the app shows), `spec.extra_voice_ids`,
    and `also` (ids the adapter knows the checkpoint has, e.g. from its config).
    With `spec.voice_ids_ignore_case` the requested id is lowercased first, as the
    engine does; the accepted ids are compared as they are.
    A voice with a reference clip is left to the adapter when the engine can clone.
    """
    if voice is None or (voice.ref_audio and spec.supports_cloning):
        return
    listed = [v.id for v in spec.voices]
    extra = [x for x in dict.fromkeys((*spec.extra_voice_ids, *also)) if x not in listed]
    if voice.preset:
        wanted = voice.preset.lower() if spec.voice_ids_ignore_case else voice.preset
        if wanted in listed or wanted in extra:
            return
    listing = f"Valid voices for {spec.name}: {', '.join(listed) or '(none)'}."
    if extra:
        listing += f" Also accepted: {', '.join(extra)}."
    if not voice.preset:
        how = " or a reference clip" if spec.supports_cloning else " (it cannot clone a reference clip)"
        raise EngineError(f"{spec.name} needs a preset voice{how}. {listing}")
    raise EngineError(f"Unknown voice '{voice.preset}' for {spec.name}. {listing}")
