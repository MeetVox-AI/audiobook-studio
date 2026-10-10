"""Mistral Voxtral TTS 4B (CC BY-NC 4.0) via mlx-audio: native French preset voices.

Verified against mlx-audio 0.5.8: preset voices only (no reference-audio
parameter), 24 kHz, generate() yields GenerationResult. Decorative quote
characters are removed before synthesis (reported to trigger hallucinated
speech, mlx-audio issue #916).
"""

from __future__ import annotations

import importlib.metadata
import re
import time
import unicodedata

import numpy as np

from ..audio.validate import seconds_per_char
from .base import EngineError, EngineSpec, Voice, VoiceChoice, check_preset

CHECKPOINT = "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit"

SPEC = EngineSpec(
    id="voxtral",
    name="Voxtral TTS 4B",
    checkpoint=CHECKPOINT,
    languages=("en", "fr", "es", "de", "it", "pt", "nl", "hi", "ar"),
    license="CC BY-NC 4.0",
    noncommercial=True,
    chunk_cap={"en": 400, "fr": 400, "es": 400, "de": 400, "it": 400, "pt": 400, "nl": 400, "hi": 300, "ar": 300},
    min_chunk=12,
    batch_size=1,
    supports_presets=True,
    supports_cloning=False,
    supports_speed=False,
    deterministic=False,
    download_gb=2.5,
    voices=[
        Voice("fr_female", "French female", "fr", "female", "French"),
        Voice("fr_male", "French male", "fr", "male", "French"),
        Voice("neutral_female", "Neutral female", "en", "female", "English"),
        Voice("neutral_male", "Neutral male", "en", "male", "English"),
        Voice("casual_female", "Casual female", "en", "female", "English"),
        Voice("casual_male", "Casual male", "en", "male", "English"),
        Voice("cheerful_female", "Cheerful female", "en", "female", "English"),
        Voice("es_female", "Spanish female", "es", "female", "Spanish"),
        Voice("es_male", "Spanish male", "es", "male", "Spanish"),
        Voice("de_female", "German female", "de", "female", "German"),
        Voice("de_male", "German male", "de", "male", "German"),
        Voice("it_female", "Italian female", "it", "female", "Italian"),
        Voice("it_male", "Italian male", "it", "male", "Italian"),
        Voice("pt_female", "Portuguese female", "pt", "female", "Portuguese"),
        Voice("pt_male", "Portuguese male", "pt", "male", "Portuguese"),
        Voice("nl_female", "Dutch female", "nl", "female", "Dutch"),
        Voice("nl_male", "Dutch male", "nl", "male", "Dutch"),
        Voice("hi_female", "Hindi female", "hi", "female", "Hindi"),
        Voice("hi_male", "Hindi male", "hi", "male", "Hindi"),
        Voice("ar_male", "Arabic male", "ar", "male", "Arabic", "The only Arabic voice"),
    ],
    notes="Native presets in nine languages. Non-commercial license: personal use only.",
)

_DOUBLE = re.compile(r"[\"«»“”„]")
_SINGLE = re.compile(r"['’‘]")


def _is_letter(ch: str) -> bool:
    # Any Unicode letter (œ, Œ, ß, Greek...), plus combining marks so decomposed text (e + U+0301) counts too.
    return ch.isalpha() or unicodedata.category(ch).startswith("M")


def _single_quote(m: re.Match) -> str:
    s, i = m.string, m.start()
    inside_word = 0 < i < len(s) - 1 and _is_letter(s[i - 1]) and _is_letter(s[i + 1])
    return "'" if inside_word else " "


def strip_decorative_quotes(text: str) -> str:
    """Remove quote marks but keep apostrophes inside words (l'autre, qu'il, l'œil, don't)."""
    text = _DOUBLE.sub(" ", text)
    text = _SINGLE.sub(_single_quote, text)
    return re.sub(r"\s+", " ", text).strip()


# mlx-audio 0.5.8 errors that mean "this text gives no audio", not "the engine is broken":
# - text_preprocess.py:411-412, sanitize_tts_input_text_for_demo() on text that is empty after its cleanup;
# - voxtral_tts.py:713-714, when the first frame is END_AUDIO. Frame 0's semantic code is an argmax
#   (acoustic_head.py:179-192), so reseeding cannot change it and the same text fails on every resume.
# These return empty audio, so the pipeline flags the chunk ("empty audio") and carries on.
# Other errors (tokenizer missing, etc.) still propagate.
_NO_AUDIO_ERRORS = ("Speech input is empty after sanitization", "No audio frames generated")


# The mistral-common version this engine declares (pyproject.toml). 1.9.1 has no speech API; 1.12.0 has it.
MIN_MISTRAL_COMMON = "1.12"


def _check_speech_tokenizer() -> None:
    """Fail before loading 2.5 GB of weights if mlx-audio cannot build a Voxtral prompt.

    mlx-audio 0.5.8 needs exactly this, and otherwise fails on the first chunk:
    MistralTokenizer from mistral_common.tokens.tokenizers.mistral (voxtral_tts.py:333),
    a tokenizer with encode_speech_request (hasattr check, voxtral_tts.py:801), and
    SpeechRequest from mistral_common.protocol.speech.request (voxtral_tts.py:808).
    Any ImportError counts, not only a missing module: a broken install or a missing
    transitive dependency must give the same clear error. So does any other error raised
    while importing (e.g. a TypeError from mismatched pydantic packages).
    """
    try:
        from mistral_common.protocol.speech.request import SpeechRequest  # noqa: F401
        from mistral_common.tokens.tokenizers.mistral import MistralTokenizer

        if hasattr(MistralTokenizer, "encode_speech_request"):
            return
        detail = "MistralTokenizer has no encode_speech_request"
    except ImportError as exc:
        detail = str(exc) or type(exc).__name__
    except Exception as exc:  # broken install: the import itself crashed
        detail = f"{type(exc).__name__} while importing it: {exc}"
    try:
        have = f"mistral-common {importlib.metadata.version('mistral-common')} is installed"
    except importlib.metadata.PackageNotFoundError:
        have = "mistral-common is not installed"
    raise EngineError(f"Voxtral needs mistral-common[audio] {MIN_MISTRAL_COMMON} or newer, with speech support "
                      f"({have}; {detail}). Reinstall the engine's dependencies so that "
                      f"mistral-common[audio]>={MIN_MISTRAL_COMMON} is installed.")


class VoxtralEngine:
    spec = SPEC
    # No temperature/top_k/top_p: mlx-audio 0.5.8 accepts them in Model.generate()
    # (voxtral_tts.py:565-567) but never reads them. The semantic code is
    # mx.argmax (acoustic_head.py:192), and the only randomness is
    # mx.random.normal in decode_one_frame (acoustic_head.py:209), which the seed controls.
    # Keeping them in the fingerprint would only invalidate the cache for no audible change.

    def __init__(self):
        self.model = None

    @property
    def sample_rate(self) -> int:
        return int(self.model.sample_rate) if self.model is not None else 24000

    def load(self, voice: VoiceChoice | None = None) -> float:
        check_preset(self.spec, voice)  # before the model load, so a typo fails fast
        _check_speech_tokenizer()
        t0 = time.perf_counter()
        from mlx_audio.tts.utils import load_model

        self.model = load_model(CHECKPOINT)
        return time.perf_counter() - t0

    def settings_fingerprint(self) -> str:
        # "noquotes2" names the strip_decorative_quotes() version (2: Unicode-letter elisions such as l'œil).
        # Bump it whenever the text sent to the model changes for the same chunk text.
        return f"voxtral|{CHECKPOINT}|noquotes2"

    def _check_voice_installed(self, preset: str) -> None:
        # mlx-audio indexes voice_embedding/*.safetensors by stem (voxtral_tts.py:354-358). An unknown voice
        # gives None (362-370), and _build_input_embeddings then drops the voice conditioning without any
        # error (843-845). Private attribute, so skip the check if a future mlx-audio renames it.
        files = getattr(self.model, "_voice_embedding_files", None)
        if files is not None and preset not in files:
            raise EngineError(f"Voxtral voice '{preset}' is not in the {CHECKPOINT} checkpoint "
                              f"(it has: {', '.join(sorted(files)) or 'no voices'}).")

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        import mlx.core as mx

        if self.model is None:
            raise EngineError("Model not loaded")
        if not voice.preset:
            raise EngineError("Voxtral supports preset voices only (no cloning in mlx-audio).")
        check_preset(self.spec, voice)
        self._check_voice_installed(voice.preset)
        if seed is not None:
            mx.random.seed(seed)
        out = []
        for t in texts:
            clean = strip_decorative_quotes(t)
            if not any(ch.isalnum() for ch in clean):
                # Nothing to say (a paragraph that is only "»", or only punctuation once quotes are stripped).
                out.append(np.zeros(0, np.float32))
                continue
            max_tokens = int(max(60, 2.5 * len(t) * seconds_per_char(lang) / 0.08))  # 80 ms frames
            try:
                parts = [np.asarray(r.audio, np.float32).reshape(-1)
                         for r in self.model.generate(text=clean, voice=voice.preset, max_tokens=max_tokens)]
            except (ValueError, RuntimeError) as exc:
                if not str(exc).startswith(_NO_AUDIO_ERRORS):
                    raise
                parts = []
            out.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
        return out
