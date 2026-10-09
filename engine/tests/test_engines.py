"""Engine adapter logic that does not need model weights."""

from __future__ import annotations

import builtins
import importlib.metadata
import json
import re
import sys
import types
import unicodedata

import numpy as np
import pytest

from audiobook_engine.tts import (
    EngineError,
    VoiceChoice,
    check_preset,
    get_engine,
    specs,
)
from audiobook_engine.tts import fish as fish_mod
from audiobook_engine.tts import qwen3 as qwen3_mod
from audiobook_engine.tts import voxtral as voxtral_mod
from audiobook_engine.tts.voxtral import strip_decorative_quotes

PRESET_ENGINES = ("kokoro", "qwen3", "voxtral")
# voices/*.safetensors of the cached mlx-community/Kokoro-82M-bf16 that are English but not listed
KOKORO_EXTRA_EN = ("af_alloy", "af_aoede", "af_jessica", "af_kore", "af_river", "am_liam", "am_onyx", "am_santa")


@pytest.fixture(autouse=True)
def real_cached_speakers(monkeypatch):
    """Keep tests independent of this machine's Hugging Face cache; returns the real lookup for its own test."""
    real = getattr(qwen3_mod, "_cached_speakers", None)
    monkeypatch.setattr(qwen3_mod, "_cached_speakers", lambda: (), raising=False)
    return real


@pytest.fixture
def fake_loader(monkeypatch):
    """Stands in for mlx_audio.tts.utils so no test can load real weights; records each load."""
    calls: list[str] = []

    def load_model(repo):
        calls.append(repo)
        return types.SimpleNamespace(sample_rate=24000, _get_pipeline=lambda lang: None)

    mod = types.ModuleType("mlx_audio.tts.utils")
    mod.load_model = load_model
    monkeypatch.setitem(sys.modules, "mlx_audio.tts.utils", mod)
    return calls


class FakeVoxtralModel:
    """Behaves like mlx-audio 0.5.8 Voxtral Model.generate(), without weights.

    Like the real generator, it raises on first iteration when the text is empty
    (sanitize_tts_input_text_for_demo, text_preprocess.py:411-412).
    """

    sample_rate = 24000

    def __init__(self, error: Exception | None = None, voices: list[str] | None = None):
        self.calls: list[dict] = []
        self.error = error
        if voices is not None:
            self._voice_embedding_files = {v: f"voice_embedding/{v}.safetensors" for v in voices}

    def generate(self, text, voice="casual_male", **kwargs):
        self.calls.append({"text": text, "voice": voice, **kwargs})
        if not text.strip():
            raise ValueError(f"Speech input is empty after sanitization, got raw_text={text!r}")
        if self.error is not None:
            raise self.error
        yield types.SimpleNamespace(audio=np.ones(2400, np.float32))


class FakeQwen3Model:
    sample_rate = 24000
    # spk_id keys of the cached mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit config.json
    SPEAKERS = ("serena", "vivian", "uncle_fu", "ryan", "aiden", "ono_anna", "sohee", "eric", "dylan")

    def __init__(self, speakers: list[str] | None = None):
        self.spk_id = {s: i for i, s in enumerate(self.SPEAKERS if speakers is None else speakers)}
        self.calls: list[dict] = []

    def get_supported_speakers(self):
        return list(self.spk_id)  # mlx-audio: list(config.talker_config.spk_id.keys())

    def batch_generate(self, texts, **kwargs):
        # mlx-audio 0.5.8 preset lookup (qwen3_tts.py:385): `speaker.lower() in config.spk_id`
        conditioned = [bool(v) and v.lower() in self.spk_id for v in kwargs.get("voices") or []]
        self.calls.append({"texts": texts, "conditioned": conditioned, **kwargs})
        for i, _ in enumerate(texts):
            yield types.SimpleNamespace(sequence_idx=i, audio=np.ones(100, np.float32))


class FakeKokoroModel:
    """mlx-audio Kokoro Model: _get_pipeline(code) returns a callable KokoroPipeline."""

    sample_rate = 24000

    def __init__(self):
        self.pipelines: list[str] = []

    def _get_pipeline(self, code):
        self.pipelines.append(code)

        def pipeline(text, voice, speed, split_pattern):
            yield types.SimpleNamespace(audio=np.ones((1, 10), np.float32))

        return pipeline


@pytest.mark.parametrize("src, want", [
    ("« Où allez-vous ? » dit-il.", "Où allez-vous ? dit-il."),
    ("L'autre qu'il aimait.", "L'autre qu'il aimait."),
    ("He said 'go' and didn't wait.", "He said go and didn't wait."),
    ('"Quoted," she said.', "Quoted, she said."),
    ("L’été dernier", "L'été dernier"),
    # œ/Œ are outside the old [A-Za-zÀ-ÿ] class: elisions before them used to be split ("l œil").
    ("Il ferma l’œil.", "Il ferma l'œil."),
    ("C'est un chef-d’œuvre.", "C'est un chef-d'œuvre."),
    ("L'Œdipe de Sophocle.", "L'Œdipe de Sophocle."),
    ("un coup d'œil", "un coup d'œil"),
    # decomposed accent (NFD) right before the apostrophe still counts as part of the word
    (unicodedata.normalize("NFD", "é") + "'a", unicodedata.normalize("NFD", "é") + "'a"),
    ("« ' »", ""),
])
def test_voxtral_quote_stripping_keeps_elisions(src, want):
    assert strip_decorative_quotes(src) == want


def test_registry_lists_all_engines_with_licenses():
    s = specs()
    assert set(s) == {"kokoro", "qwen3", "voxtral", "fish"}
    assert s["voxtral"].noncommercial and s["fish"].noncommercial
    assert not s["kokoro"].noncommercial and not s["qwen3"].noncommercial
    for spec in s.values():
        assert "en" in spec.languages and "fr" in spec.languages
        assert spec.cap_for("fr") > 0


def test_unknown_engine_is_a_clear_error():
    with pytest.raises(EngineError, match="Unknown engine"):
        get_engine("nope")


def test_clone_only_engines_reject_presets_before_loading():
    fish = get_engine("fish")
    fish.model = object()  # pretend loaded; must refuse before touching it
    with pytest.raises(EngineError, match="reference clip"):
        fish.synthesize(["Hello."], VoiceChoice("anything"), "en")


def test_voice_fingerprints_differ_for_clips(tmp_path):
    a, b = tmp_path / "a.wav", tmp_path / "b.wav"
    a.write_bytes(b"one")
    b.write_bytes(b"two")
    assert VoiceChoice(ref_audio=str(a), ref_text="x").fingerprint() != VoiceChoice(ref_audio=str(b), ref_text="x").fingerprint()
    assert VoiceChoice(ref_audio=str(a), ref_text="x").fingerprint() != VoiceChoice(ref_audio=str(a), ref_text="y").fingerprint()
    assert VoiceChoice("af_heart").fingerprint() == "preset:af_heart"


# ----------------------------------------------------------------------------- preset validation

@pytest.mark.parametrize("engine_id, bad", [("kokoro", "george"), ("qwen3", "af_heart"), ("voxtral", "fr_femme")])
def test_unknown_preset_is_rejected_before_loading_weights(engine_id, bad, fake_loader):
    engine = get_engine(engine_id)
    with pytest.raises(EngineError, match=f"Unknown voice '{bad}'") as err:
        engine.load(VoiceChoice(bad))
    for v in engine.spec.voices:  # the error lists every valid id
        assert v.id in str(err.value)
    assert fake_loader == []


@pytest.mark.parametrize("engine_id", PRESET_ENGINES)
def test_every_listed_preset_is_accepted(engine_id, fake_loader, monkeypatch):
    monkeypatch.setattr(voxtral_mod, "_check_speech_tokenizer", lambda: None)
    spec = specs()[engine_id]
    assert spec.voices
    for v in spec.voices:
        check_preset(spec, VoiceChoice(v.id))
    get_engine(engine_id).load(VoiceChoice(spec.voices[0].id))
    assert len(fake_loader) == 1


def test_preset_rules_for_missing_presets_and_clips(fake_loader):
    for engine_id in ("kokoro", "voxtral"):
        with pytest.raises(EngineError, match="needs a preset voice .it cannot clone"):
            get_engine(engine_id).load(VoiceChoice(ref_audio="clip.wav", ref_text="x"))
    with pytest.raises(EngineError, match="needs a preset voice or a reference clip"):
        get_engine("qwen3").load(VoiceChoice())
    assert fake_loader == []
    get_engine("qwen3").load(VoiceChoice(ref_audio="clip.wav", ref_text="x"))  # cloning engine: clip is fine
    assert fake_loader == [qwen3_mod.BASE]
    get_engine("kokoro").load(None)  # no voice yet: nothing to check
    assert len(fake_loader) == 2


def test_kokoro_rejects_unknown_preset_at_synthesis():
    engine = get_engine("kokoro")
    pipelines = []
    engine.model = types.SimpleNamespace(sample_rate=24000, _get_pipeline=pipelines.append)
    with pytest.raises(EngineError, match="Unknown voice 'george'"):
        engine.synthesize(["Hello."], VoiceChoice("george"), "en")
    assert pipelines == []


def test_qwen3_unknown_preset_is_not_synthesised_without_a_speaker():
    engine = get_engine("qwen3")
    model = engine.models[qwen3_mod.CUSTOM] = FakeQwen3Model()
    with pytest.raises(EngineError, match="Unknown voice 'george'"):
        engine.synthesize(["Hello there."], VoiceChoice("george"), "en")
    assert model.calls == []
    out = engine.synthesize(["Hello there.", "Again."], VoiceChoice("ryan"), "en")
    assert [a.size for a in out] == [100, 100]
    assert model.calls[0]["voices"] == ["ryan", "ryan"]


def test_qwen3_preset_missing_from_checkpoint_is_an_error():
    engine = get_engine("qwen3")
    model = engine.models[qwen3_mod.CUSTOM] = FakeQwen3Model(speakers=["serena", "vivian"])
    with pytest.raises(EngineError, match=r"'ryan' is not in the .* checkpoint \(it has: serena, vivian\)"):
        engine.synthesize(["Hello there."], VoiceChoice("ryan"), "en")
    assert model.calls == []
    engine.synthesize(["Hello there."], VoiceChoice("Serena"), "en")  # mlx-audio lowercases the requested name
    assert model.calls[0]["voices"] == ["serena"] and model.calls[0]["conditioned"] == [True]


def test_qwen3_mixed_case_checkpoint_key_is_rejected_like_the_mlx_audio_lookup():
    # mlx-audio lowercases only the requested name, so a "Serena" key is never matched: synthesising
    # "serena" would run with no speaker conditioning and no error.
    engine = get_engine("qwen3")
    model = engine.models[qwen3_mod.CUSTOM] = FakeQwen3Model(speakers=["Serena", "vivian"])
    for name in ("serena", "Serena"):
        with pytest.raises(EngineError, match="lists it as 'Serena', which mlx-audio cannot select"):
            engine.synthesize(["Hello there."], VoiceChoice(name), "en")
    assert model.calls == []
    engine.synthesize(["Hello there."], VoiceChoice("Vivian"), "en")
    assert model.calls[0]["conditioned"] == [True]


def test_qwen3_accepts_every_checkpoint_speaker_in_any_case_but_lists_only_the_curated_ones(fake_loader):
    spec = specs()["qwen3"]
    assert [v["id"] for v in spec.to_json()["voices"]] == ["ryan", "aiden", "vivian", "serena", "ono_anna", "sohee"]
    names = [*FakeQwen3Model.SPEAKERS, "Ryan", "RYAN", "Uncle_Fu", "ERIC"]
    for name in names:
        check_preset(spec, VoiceChoice(name))
        get_engine("qwen3").load(VoiceChoice(name))
    assert fake_loader == [qwen3_mod.CUSTOM] * len(names)
    engine = get_engine("qwen3")
    model = engine.models[qwen3_mod.CUSTOM] = FakeQwen3Model()
    for name in names:
        engine.synthesize(["Hello there."], VoiceChoice(name), "en")
    assert [c["voices"] for c in model.calls] == [[n.lower()] for n in names]
    assert all(c["conditioned"] == [True] for c in model.calls)


def test_qwen3_accepts_other_speakers_found_in_the_checkpoint_config(monkeypatch, fake_loader):
    monkeypatch.setattr(qwen3_mod, "_cached_speakers", lambda: ("newvoice",))
    get_engine("qwen3").load(VoiceChoice("NewVoice"))
    assert fake_loader == [qwen3_mod.CUSTOM]
    with pytest.raises(EngineError, match="Unknown voice 'george'.*Also accepted: uncle_fu, eric, dylan, newvoice"):
        get_engine("qwen3").load(VoiceChoice("george"))
    assert len(fake_loader) == 1


def test_qwen3_reads_checkpoint_speakers_from_the_local_cache_only(monkeypatch, tmp_path, real_cached_speakers):
    import huggingface_hub

    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"talker_config": {"spk_id": {"ryan": 1, "Serena": 2, "newvoice": 3}}}))
    asked = []

    def from_cache(repo_id, filename, **kwargs):
        asked.append((repo_id, filename))
        return str(cfg)

    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", from_cache)
    assert real_cached_speakers() == ("ryan", "newvoice")  # a mixed-case key can never be selected
    assert asked == [(qwen3_mod.CUSTOM, "config.json")]
    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", lambda *a, **k: None)  # not downloaded
    assert real_cached_speakers() == ()
    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", lambda *a, **k: str(cfg))
    for broken in ("{not json", "[1, 2]", '{"talker_config": {"spk_id": [1]}}'):
        cfg.write_text(broken)
        assert real_cached_speakers() == ()


def test_qwen3_a_malformed_string_speaker_table_gives_no_speakers(monkeypatch, tmp_path, real_cached_speakers,
                                                                   fake_loader):
    import huggingface_hub

    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"talker_config": {"spk_id": "abc"}}))  # not a name -> id table
    monkeypatch.setattr(huggingface_hub, "try_to_load_from_cache", lambda *a, **k: str(cfg))
    assert real_cached_speakers() == ()  # not ('a', 'b', 'c')
    monkeypatch.setattr(qwen3_mod, "_cached_speakers", real_cached_speakers)
    with pytest.raises(EngineError, match="Unknown voice 'a'"):
        get_engine("qwen3").load(VoiceChoice("a"))
    assert fake_loader == []  # rejected before loading the checkpoint


def test_qwen3_empty_batch_gives_no_audio():
    engine = get_engine("qwen3")
    model = engine.models[qwen3_mod.CUSTOM] = FakeQwen3Model()
    assert engine.synthesize([], VoiceChoice("ryan"), "en") == []
    assert model.calls == []


# ----------------------------------------------------------------------------- kokoro

def test_kokoro_accepts_the_other_english_voices_of_the_checkpoint_without_listing_them(fake_loader):
    spec = specs()["kokoro"]
    listed = {v["id"] for v in spec.to_json()["voices"]}
    for v in KOKORO_EXTRA_EN:
        assert v not in listed
        get_engine("kokoro").load(VoiceChoice(v))
    assert len(fake_loader) == len(KOKORO_EXTRA_EN)
    with pytest.raises(EngineError, match="Unknown voice 'jf_alpha'"):  # Japanese voice: not for en/fr
        get_engine("kokoro").load(VoiceChoice("jf_alpha"))


@pytest.mark.parametrize("voice, lang, fits", [
    ("af_heart", "fr", "ff_siwis"), ("bm_george", "fr", "ff_siwis"), ("af_jessica", "fr", "ff_siwis"),
    ("ff_siwis", "en", "af_heart"),
])
def test_kokoro_refuses_a_voice_made_for_another_language(voice, lang, fits, monkeypatch):
    engine = get_engine("kokoro")
    engine.model = FakeKokoroModel()
    monkeypatch.setattr(engine, "voice_path", lambda v: f"/voices/{v}.safetensors")
    named = "an English" if lang == "en" else "a French"  # the article agrees with the language name
    with pytest.raises(EngineError, match=f"'{voice}' is not {named} voice.*voices: .*{fits}"):
        engine.synthesize(["Bonjour." if lang == "fr" else "Hello."], VoiceChoice(voice), lang)
    assert engine.model.pipelines == []


@pytest.mark.parametrize("voice, lang, code", [
    ("af_heart", "en", "a"), ("af_jessica", "en", "a"), ("bm_george", "en", "b"), ("ff_siwis", "fr", "f"),
])
def test_kokoro_uses_the_pipeline_of_the_voice_language(voice, lang, code, monkeypatch):
    engine = get_engine("kokoro")
    engine.model = FakeKokoroModel()
    monkeypatch.setattr(engine, "voice_path", lambda v: f"/voices/{v}.safetensors")
    out = engine.synthesize(["Text."], VoiceChoice(voice), lang)
    assert engine.model.pipelines == [code]
    assert out[0].shape == (10,) and out[0].dtype == np.float32


# ----------------------------------------------------------------------------- fish

def test_fish_refuses_a_preset_before_loading_weights(fake_loader):
    with pytest.raises(EngineError, match="reference clip"):
        get_engine("fish").load(VoiceChoice("anything"))
    assert fake_loader == []
    get_engine("fish").load(VoiceChoice(ref_audio="clip.wav", ref_text="x"))
    assert fake_loader == [fish_mod.CHECKPOINT]


def test_voxtral_preset_missing_from_checkpoint_is_an_error():
    engine = get_engine("voxtral")
    engine.model = FakeVoxtralModel(voices=["fr_male", "casual_male"])
    with pytest.raises(EngineError, match="'fr_female' is not in the .* checkpoint"):
        engine.synthesize(["Bonjour."], VoiceChoice("fr_female"), "fr")
    assert engine.model.calls == []
    assert engine.synthesize(["Bonjour."], VoiceChoice("fr_male"), "fr")[0].size == 2400


# ----------------------------------------------------------------------------- voxtral

def test_voxtral_quote_only_chunk_gives_empty_audio_instead_of_failing_the_job():
    engine = get_engine("voxtral")
    engine.model = FakeVoxtralModel()
    out = engine.synthesize(["»", "« »", "''", "« … »", "Bonjour."], VoiceChoice("fr_female"), "fr")
    assert [a.size for a in out] == [0, 0, 0, 0, 2400]
    assert all(a.dtype == np.float32 and a.ndim == 1 for a in out)
    assert [c["text"] for c in engine.model.calls] == ["Bonjour."]


def test_voxtral_no_audio_frames_is_empty_audio_but_other_errors_propagate():
    engine = get_engine("voxtral")
    engine.model = FakeVoxtralModel(error=RuntimeError("No audio frames generated"))
    out = engine.synthesize(["Bonjour.", "Encore."], VoiceChoice("fr_female"), "fr")
    assert [a.size for a in out] == [0, 0] and out[0].dtype == np.float32
    engine.model = FakeVoxtralModel(error=RuntimeError("Voxtral TTS requires mistral-common[audio] so ..."))
    with pytest.raises(RuntimeError, match="mistral-common"):
        engine.synthesize(["Bonjour."], VoiceChoice("fr_female"), "fr")


def test_voxtral_does_not_pass_or_fingerprint_ignored_sampling_params():
    engine = get_engine("voxtral")
    engine.model = FakeVoxtralModel()
    engine.synthesize(["Hello there."], VoiceChoice("neutral_female"), "en")
    assert set(engine.model.calls[0]) == {"text", "voice", "max_tokens"}
    fp = engine.settings_fingerprint()
    assert voxtral_mod.CHECKPOINT in fp
    assert not re.search(r"\|[tkp]\d", fp)
    assert fp != f"voxtral|{voxtral_mod.CHECKPOINT}|t0.8|k50|p0.95|noquotes"  # quote handling changed


def _fake_mistral_common(monkeypatch, *, speech_api: bool) -> None:
    """mistral-common modules as mlx-audio imports them; speech_api=False is 1.9.1 (no encode_speech_request)."""
    tokenizers = types.ModuleType("mistral_common.tokens.tokenizers.mistral")
    tokenizers.MistralTokenizer = type("MistralTokenizer", (), {})
    if speech_api:
        tokenizers.MistralTokenizer.encode_speech_request = lambda self, request: None
    request = types.ModuleType("mistral_common.protocol.speech.request")
    request.SpeechRequest = type("SpeechRequest", (), {})
    monkeypatch.setitem(sys.modules, tokenizers.__name__, tokenizers)
    monkeypatch.setitem(sys.modules, request.__name__, request)


def test_voxtral_load_fails_fast_without_the_speech_tokenizer_method(monkeypatch, fake_loader):
    # mlx-audio checks hasattr(tokenizer, "encode_speech_request") (voxtral_tts.py:801) on every chunk
    _fake_mistral_common(monkeypatch, speech_api=False)
    monkeypatch.setattr(importlib.metadata, "version", lambda dist: "1.9.1")
    with pytest.raises(EngineError, match=r"mistral-common\[audio\] 1\.12 or newer.*"
                                          r"mistral-common 1\.9\.1 is installed; .*no encode_speech_request"):
        get_engine("voxtral").load(VoiceChoice("fr_female"))
    assert fake_loader == []
    _fake_mistral_common(monkeypatch, speech_api=True)
    get_engine("voxtral").load(VoiceChoice("fr_female"))
    assert fake_loader == [voxtral_mod.CHECKPOINT]


def test_voxtral_load_fails_fast_on_a_broken_mistral_common(monkeypatch, fake_loader):
    real_import = builtins.__import__

    def broken(name, *args, **kwargs):
        if name.startswith("mistral_common"):
            raise ImportError("cannot import name 'Foo' from partially initialized module 'mistral_common'")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", broken)
    with pytest.raises(EngineError, match="mistral-common.*speech support.*partially initialized"):
        get_engine("voxtral").load(VoiceChoice("fr_female"))
    assert fake_loader == []


def test_voxtral_load_fails_fast_when_importing_mistral_common_crashes(monkeypatch, fake_loader):
    real_import = builtins.__import__

    def crashing(name, *args, **kwargs):
        if name.startswith("mistral_common"):
            raise TypeError("model_fields() takes 1 positional argument")  # e.g. pydantic packages that disagree
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", crashing)
    with pytest.raises(EngineError, match="mistral-common.*speech support.*TypeError.*model_fields"):
        get_engine("voxtral").load(VoiceChoice("fr_female"))
    assert fake_loader == []


def test_voxtral_load_fails_fast_without_mistral_common(monkeypatch, fake_loader):
    def not_installed(dist):
        raise importlib.metadata.PackageNotFoundError(dist)

    monkeypatch.setitem(sys.modules, "mistral_common.protocol.speech.request", None)  # import raises
    monkeypatch.setattr(importlib.metadata, "version", not_installed)
    with pytest.raises(EngineError, match="mistral-common is not installed"):
        get_engine("voxtral").load(VoiceChoice("fr_female"))
    assert fake_loader == []


def test_voxtral_speech_check_passes_with_the_declared_mistral_common():
    voxtral_mod._check_speech_tokenizer()  # the installed mistral-common[audio]>=1.12 (pyproject.toml)
