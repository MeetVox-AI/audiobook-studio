"""Reference voices and model removal. No network, no Whisper: downloads and transcription are faked."""

from __future__ import annotations

import hashlib
import io
import json

import numpy as np
import pytest
import soundfile as sf

from audiobook_engine import modelstore, voices

SR = 24000


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))

    def no_whisper(path, lang):
        raise AssertionError("tests must not load Whisper")

    monkeypatch.setattr(voices, "_transcribe", no_whisper)


def clip(path, seconds=4.0, seed=0):
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * SR)) / SR
    sf.write(str(path), (0.2 * (0.5 + 0.5 * np.sin(2 * np.pi * 3 * t)) * rng.standard_normal(t.size)).astype(np.float32),
             SR, subtype="PCM_16")
    return path


def digest(p) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def listing() -> set[str]:
    return {p.name for p in voices.voices_dir().iterdir()}


def test_adding_a_clip_under_an_existing_name_keeps_the_first_voice(tmp_path):
    first = voices.add_user_clip(clip(tmp_path / "a.wav", seed=1), "Me", "en", "Hello there, this is me.")
    kept = digest(first.path)
    second = voices.add_user_clip(clip(tmp_path / "b.wav", seed=2), "Me", "en", "A different recording.")
    assert first.id == "user-me" and second.id == "user-me-2"
    assert digest(first.path) == kept and voices.get("user-me").transcript == "Hello there, this is me."
    assert {v.id for v in voices.installed()} == {"user-me", "user-me-2"}


def test_a_failed_transcription_leaves_no_half_installed_voice(tmp_path, monkeypatch):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seed=1), "Me", "en", "Hello there, this is me.")
    kept, before = digest(me.path), listing()

    def whisper_missing(path, lang):
        raise RuntimeError("Whisper is not installed")

    monkeypatch.setattr(voices, "_transcribe", whisper_missing)
    for name in ("Me", "Someone else"):
        with pytest.raises(RuntimeError):
            voices.add_user_clip(clip(tmp_path / "b.wav", seed=2), name, "en")
    assert listing() == before  # no orphan clip without its note
    assert digest(me.path) == kept  # and the existing voice was not touched


def test_an_unreadable_clip_is_a_clear_error_and_leaves_nothing(tmp_path):
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"not audio at all")
    with pytest.raises(ValueError, match="Could not read this audio clip"):
        voices.add_user_clip(bad, "Broken", "en", "words")
    assert listing() == set()


def test_voice_ids_cannot_reach_outside_the_voices_folder(tmp_path):
    outside = voices.voices_dir().parent / "precious.json"
    outside.write_text("{}")
    for bad_id in ("../precious", "..", "a/b", ".hidden", ""):
        with pytest.raises(ValueError):
            voices.remove(bad_id)
        with pytest.raises(ValueError):
            voices.set_transcript(bad_id, "x")
    assert outside.exists()
    with pytest.raises(KeyError):
        voices.set_transcript("user-nobody", "x")


def test_a_damaged_voice_note_does_not_break_the_other_voices(tmp_path):
    voices.add_user_clip(clip(tmp_path / "a.wav"), "Me", "en", "Hello there, this is me.")
    (voices.voices_dir() / "user-broken.json").write_text(json.dumps({"name": "no id"}))
    clip(voices.voices_dir() / "user-broken.wav")
    assert [v.id for v in voices.installed()] == ["user-me"]


def test_a_refused_download_cleans_up_its_work_folder(monkeypatch):
    entry = voices.library()[0]

    class Endless(io.RawIOBase):
        def read(self, n=-1):
            return b"\0" * (1 << 16)

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    monkeypatch.setattr(voices.urllib.request, "urlopen", lambda req, timeout=None: Endless())
    with pytest.raises(ValueError, match="larger than 20 MB"):
        voices.download(entry["id"])
    assert listing() == set()


def test_removing_a_model_without_any_download_cache(monkeypatch):
    import huggingface_hub

    def no_cache():
        raise huggingface_hub.CacheNotFound("no cache", "/nowhere")

    monkeypatch.setattr(huggingface_hub, "scan_cache_dir", no_cache)
    assert modelstore.remove("kokoro") == {"engine": "kokoro", "freed_bytes": 0, "removed": False}
