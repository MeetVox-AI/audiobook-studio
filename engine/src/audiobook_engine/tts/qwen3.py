"""Qwen3-TTS 1.7B (Apache-2.0) via mlx-audio: default quality engine and cloning.

Verified against mlx-audio 0.5.8 source:
- presets need the CustomVoice checkpoint; cloning needs the Base checkpoint;
- batch_generate() batches presets per item, or one *shared* reference clip
  (ICL cloning, which requires the clip's transcript);
- there is no seed argument (we seed mx.random), no native speed control;
- the ICL path forces repetition_penalty >= 1.5 itself.
"""

from __future__ import annotations

import json
import time
from collections import defaultdict
from pathlib import Path

import numpy as np

from .base import EngineError, EngineSpec, Voice, VoiceChoice, check_preset

CUSTOM = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
BASE = "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit"
LANG = {"en": "english", "fr": "french"}
TOKENS_PER_SECOND = 12.5  # "12Hz" codec

SPEC = EngineSpec(
    id="qwen3",
    name="Qwen3-TTS 1.7B",
    checkpoint=CUSTOM,
    languages=("en", "fr"),
    license="Apache-2.0",
    noncommercial=False,
    chunk_cap={"en": 300, "fr": 300},   # long single prompts degrade; 1-2 sentences per item
    min_chunk=12,
    batch_size=8,  # measured on M4 Pro: batch 4 = 3.0x, 8 = 4.9x, 12 = 5.2x, 16 = 3.6x real time
    supports_presets=True,
    supports_cloning=True,
    supports_speed=False,
    deterministic=False,
    download_gb=6.2,
    voices=[
        Voice("ryan", "Ryan", "en", "male", "English", "Native English speaker"),
        Voice("aiden", "Aiden", "en", "male", "English", "Native English speaker"),
        Voice("vivian", "Vivian", "en", "female", "Chinese-native", "May carry an accent in English/French"),
        Voice("serena", "Serena", "en", "female", "Chinese-native", "May carry an accent in English/French"),
        Voice("ono_anna", "Ono Anna", "en", "female", "Japanese-native", "May carry an accent"),
        Voice("sohee", "Sohee", "en", "female", "Korean-native", "May carry an accent"),
    ],
    notes="Best open-model French accuracy. No native French preset: clone a French reference clip for French books.",
    # The CustomVoice config.json (spk_id, revision 41d3337) also has these Chinese-native speakers
    # (eric: Sichuan dialect, dylan: Beijing dialect; the dialect only applies to Chinese text).
    # Accepted, not listed. Any other speaker in the cached or loaded config is accepted too.
    extra_voice_ids=("uncle_fu", "eric", "dylan"),
    voice_ids_ignore_case=True,  # mlx-audio looks up speaker.lower() (qwen3_tts.py:385)
)


def _cached_speakers() -> tuple[str, ...]:
    """Speaker names in the CustomVoice config.json of the local Hugging Face cache (never downloads).

    Only lowercase keys: mlx-audio looks a speaker up as `name.lower() in spk_id`
    (qwen3_tts.py:385), so a mixed-case key can never be selected.
    """
    try:
        from huggingface_hub import try_to_load_from_cache

        path = try_to_load_from_cache(CUSTOM, "config.json")
        if not isinstance(path, str):  # not cached (None) or cached as missing
            return ()
        spk_id = (json.loads(Path(path).read_text()).get("talker_config") or {}).get("spk_id") or {}
        if not isinstance(spk_id, dict):  # a malformed config: a string would give one "speaker" per character
            return ()
        return tuple(k for k in spk_id if isinstance(k, str) and k == k.lower())
    except (ImportError, OSError, ValueError, AttributeError, TypeError):  # unreadable: curated + extra ids apply
        return ()


class Qwen3Engine:
    spec = SPEC

    # sampling defaults pinned to the model's own generation config (runaway clips otherwise)
    temperature = 0.9
    top_k = 50
    top_p = 1.0
    repetition_penalty = 1.05

    def __init__(self):
        self.models: dict[str, object] = {}

    @property
    def sample_rate(self) -> int:
        for m in self.models.values():
            return int(m.sample_rate)
        return 24000

    def _model(self, voice: VoiceChoice):
        repo = BASE if voice.ref_audio else CUSTOM
        if repo not in self.models:
            from mlx_audio.tts.utils import load_model

            self.models[repo] = load_model(repo)
        return self.models[repo]

    def _known_speakers(self) -> tuple[str, ...]:
        """Speakers of the CustomVoice checkpoint: the loaded model's, else the cached config's."""
        model = self.models.get(CUSTOM)
        if model is None:
            return _cached_speakers()
        return tuple(s for s in model.get_supported_speakers() if s == s.lower())

    def _check_voice(self, voice: VoiceChoice | None) -> None:
        """check_preset, also accepting any other speaker the checkpoint has (looked up only when needed)."""
        try:
            check_preset(self.spec, voice)
        except EngineError:
            if not (voice and voice.preset):
                raise
            check_preset(self.spec, voice, also=self._known_speakers())

    def load(self, voice: VoiceChoice | None = None) -> float:
        self._check_voice(voice)  # before the 3 GB load, so a typo fails fast
        t0 = time.perf_counter()
        self._model(voice or VoiceChoice("ryan"))
        return time.perf_counter() - t0

    @staticmethod
    def _check_speaker(model, preset: str) -> None:
        """The loaded checkpoint must know the speaker, exactly as mlx-audio will look it up.

        mlx-audio 0.5.8 batch_generate() does not validate speakers: the preset path
        (continuous_batching.py:113 -> _prepare_generation_inputs, qwen3_tts.py:385)
        tests `speaker.lower() in config.spk_id`. An unknown name leaves speaker_embed
        as None, and generation then runs with no speaker conditioning and no error.
        Only the requested name is lowercased, so a mixed-case spk_id key ("Serena")
        never matches: the check must not lowercase the keys.
        """
        speakers = list(model.get_supported_speakers())
        if preset.lower() in speakers:
            return
        listed = [s for s in speakers if s.lower() == preset.lower()]
        why = (f" The checkpoint lists it as '{listed[0]}', which mlx-audio cannot select "
               "(it lowercases only the requested name).") if listed else ""
        raise EngineError(f"Voice '{preset}' is not in the {CUSTOM} checkpoint "
                          f"(it has: {', '.join(sorted(speakers)) or 'no speakers'}).{why}")

    def settings_fingerprint(self) -> str:
        return f"qwen3|{CUSTOM}|{BASE}|t{self.temperature}|k{self.top_k}|p{self.top_p}|r{self.repetition_penalty}"

    def synthesize(self, texts: list[str], voice: VoiceChoice, lang: str, speed: float = 1.0,
                   seed: int | None = None) -> list[np.ndarray]:
        import mlx.core as mx

        if lang not in LANG:
            raise EngineError(f"Qwen3-TTS: unsupported language '{lang}'")
        self._check_voice(voice)
        if not texts:
            return []
        model = self._model(voice)
        if not voice.ref_audio:
            self._check_speaker(model, voice.preset)
        if seed is not None:
            mx.random.seed(seed)
        longest = max(len(t) for t in texts)
        max_tokens = int(max(75, 2.5 * TOKENS_PER_SECOND * longest * 0.062))
        common = {"lang_code": LANG[lang], "temperature": self.temperature, "top_k": self.top_k, "top_p": self.top_p,
                  "repetition_penalty": self.repetition_penalty, "max_tokens": max_tokens}
        if voice.ref_audio and not voice.ref_text:
            # x-vector cloning (no transcript): not batchable, weaker similarity.
            out = []
            for t in texts:
                parts = [np.asarray(r.audio, np.float32).reshape(-1)
                         for r in model.generate(text=t, ref_audio=voice.ref_audio, split_pattern="", **common)]
                out.append(np.concatenate(parts) if parts else np.zeros(0, np.float32))
            return out
        if voice.ref_audio:
            results = model.batch_generate(texts=texts, ref_audio=voice.ref_audio, ref_text=voice.ref_text, **common)
        else:
            results = model.batch_generate(texts=texts, voices=[voice.preset.lower()] * len(texts), **common)
        pieces: dict[int, list[np.ndarray]] = defaultdict(list)
        for r in results:
            pieces[r.sequence_idx].append(np.asarray(r.audio, np.float32).reshape(-1))
        return [np.concatenate(pieces[i]) if pieces.get(i) else np.zeros(0, np.float32) for i in range(len(texts))]
