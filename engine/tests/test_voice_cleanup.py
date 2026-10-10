"""Voice isolation / enhancer and changing a voice's recording. The clean-up models and Whisper are faked,
except in the last tests, which use the real models when they are downloaded (skipped otherwise)."""

from __future__ import annotations

import json

import numpy as np
import pytest
import soundfile as sf

from audiobook_engine import modelstore, voices
from audiobook_engine.voices import cleanup

from .test_voices import _job, clip, digest, listing

calls: list[tuple[str, int]] = []


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))
    calls.clear()

    def no_whisper(path, lang):
        raise AssertionError("this test must not transcribe")

    monkeypatch.setattr(voices, "_transcribe", no_whisper)


@pytest.fixture
def fake_models(monkeypatch):
    """Both clean-up models 'installed'; isolation halves the level, the enhancer leaves audio as is."""
    monkeypatch.setattr(cleanup, "check_installed", lambda isolation, enhancer: None)

    def isolate(audio):
        calls.append(("isolate", audio.size))
        return (audio * 0.5).astype(np.float32)

    def enhance(audio):
        calls.append(("enhance", audio.size))
        return audio.astype(np.float32)

    monkeypatch.setattr(cleanup, "isolate", isolate)
    monkeypatch.setattr(cleanup, "enhance", enhance)


def whisper_says(monkeypatch, text):
    heard = []

    def fake(path, lang):
        heard.append(lang)
        return text

    monkeypatch.setattr(voices, "_transcribe", fake)
    return heard


def meta(voice_id):
    return json.loads((voices.voices_dir() / f"{voice_id}.json").read_text(encoding="utf-8"))


# --- adding a voice ---------------------------------------------------------------------------------------------

def test_adding_with_both_boxes_cleans_in_order_and_records_the_settings(tmp_path, fake_models):
    me = voices.add_user_clip(clip(tmp_path / "me.wav", seconds=6), "Me", "en", "Hello there.", isolate=True, enhance=True)
    assert [c[0] for c in calls] == ["isolate", "enhance"]
    assert calls[0][1] == 6 * cleanup.SR                       # isolation reads the whole (<60 s) recording at 48 kHz
    assert calls[1][1] <= voices.MAX_CLIP_S * cleanup.SR       # the enhancer only the kept part
    m = meta(me.id)
    assert (m["isolate"], m["enhance"], m["original"], m["original_name"]) == (True, True, "user-me.flac", "me.wav")
    assert sf.info(str(me.path)).samplerate == voices.CLIP_SR  # the clip format is unchanged


def test_adding_without_boxes_runs_no_model_and_keeps_the_start_of_the_recording(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "long.wav", seconds=75), "Long", "en", "Words.")
    assert calls == []
    kept = voices.originals_dir() / f"{me.id}.flac"
    info = sf.info(str(kept))
    assert (info.samplerate, info.channels, info.format) == (48000, 1, "FLAC")
    assert abs(info.duration - voices.SOURCE_S) < 0.1           # a long file is not copied whole
    assert meta(me.id)["isolate"] is False and meta(me.id)["enhance"] is False


def test_a_missing_model_is_named_and_leaves_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(modelstore, "_local_dir", lambda asset: None)
    with pytest.raises(cleanup.CleanupModelMissing, match="Voice isolation needs DeepFilterNet3"):
        voices.add_user_clip(clip(tmp_path / "me.wav"), "Me", "en", "Hello.", isolate=True)
    with pytest.raises(cleanup.CleanupModelMissing, match="voice enhancer needs MossFormer2-SE"):
        voices.add_user_clip(clip(tmp_path / "me.wav"), "Me", "en", "Hello.", enhance=True)
    assert listing() == set()


def test_models_list_offers_both_clean_up_models(monkeypatch):
    monkeypatch.setattr(modelstore, "_local_dir", lambda asset: None)
    rows = {e: modelstore.status(e) for e in modelstore.all_ids()}
    iso, enh = rows["voice-isolation"], rows["voice-enhancer"]
    assert iso["parts"][0]["repo"] == "mlx-community/DeepFilterNet-mlx" and iso["license"] == "MIT"
    assert enh["parts"][0]["repo"] == "starkdmi/MossFormer2-SE-fp16" and enh["license"] == "Apache-2.0"
    assert not iso["installed"] and not enh["installed"] and not iso["noncommercial"] and not enh["noncommercial"]


# --- changing the recording -------------------------------------------------------------------------------------

def test_a_new_recording_keeps_the_voice_and_is_transcribed_again(tmp_path, monkeypatch):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seed=1), "Me", "fr", "Bonjour.")
    old_wav, old_src = digest(me.path), digest(voices.originals_dir() / f"{me.id}.flac")
    heard = whisper_says(monkeypatch, "Nouveaux mots.")
    new = voices.replace_user_clip(me.id, clip(tmp_path / "b.wav", seed=2))
    assert (new.id, new.name, new.lang) == (me.id, "Me", "fr") and heard == ["fr"]
    assert (new.transcript, new.transcript_source) == ("Nouveaux mots.", "whisper")
    assert digest(new.path) != old_wav and digest(voices.originals_dir() / f"{me.id}.flac") != old_src
    assert meta(me.id)["original_name"] == "b.wav"
    assert listing() == {f"{me.id}.json", f"{me.id}.wav", f"originals/{me.id}.flac"}  # no staged leftovers


def test_a_new_recording_with_its_words_needs_no_whisper(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seed=1), "Me", "en", "Old words.")
    new = voices.replace_user_clip(me.id, clip(tmp_path / "b.wav", seed=2), transcript="  New words. ")
    assert (new.transcript, new.transcript_source) == ("New words.", "user")


def test_reprocessing_turns_isolation_on_and_keeps_the_transcript_when_the_clip_is_as_long(tmp_path, fake_models):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seconds=6), "Me", "en", "My corrected words.")
    new = voices.replace_user_clip(me.id, isolate=True)     # fake isolation keeps the length
    assert [c[0] for c in calls] == ["isolate"]
    assert (new.transcript, new.transcript_source) == ("My corrected words.", "user")
    assert meta(me.id)["isolate"] is True and meta(me.id)["enhance"] is False
    assert meta(me.id)["original_name"] == "a.wav"          # same recording


def test_reprocessing_that_shortens_the_clip_transcribes_again(tmp_path, monkeypatch, fake_models):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seconds=8), "Me", "en", "Eight seconds of words.")

    def silence_second_half(audio):  # clean-up turned the second half into silence: trimming now cuts it
        out = audio.copy()
        out[out.size // 2:] = 0
        return out

    monkeypatch.setattr(cleanup, "isolate", silence_second_half)
    whisper_says(monkeypatch, "Four seconds.")
    new = voices.replace_user_clip(me.id, isolate=True)
    assert new.meta["duration_s"] < 6
    assert (new.transcript, new.transcript_source) == ("Four seconds.", "whisper")


def test_none_keeps_each_setting(tmp_path, fake_models):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seconds=6), "Me", "en", "Words.", isolate=True)
    voices.replace_user_clip(me.id, enhance=True)
    assert meta(me.id)["isolate"] is True and meta(me.id)["enhance"] is True
    voices.replace_user_clip(me.id, isolate=False)
    assert meta(me.id)["isolate"] is False and meta(me.id)["enhance"] is True


def test_a_voice_without_a_kept_original_needs_a_new_file(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "a.wav"), "Me", "en", "Words.")
    (voices.originals_dir() / f"{me.id}.flac").unlink()     # as for a voice added before this feature
    with pytest.raises(ValueError, match="no saved original. Choose the recording again"):
        voices.replace_user_clip(me.id, isolate=True)
    assert voices.replace_user_clip(me.id, clip(tmp_path / "b.wav", seed=2), transcript="New.").transcript == "New."


def test_library_voices_cannot_change_their_recording(tmp_path):
    vid = "fr_test_voice"
    sf.write(str(voices.voices_dir() / f"{vid}.wav"), np.zeros(SR_24 := 24000, np.float32), SR_24)
    (voices.voices_dir() / f"{vid}.json").write_text(json.dumps({"id": vid, "name": "T", "lang": "fr"}))
    with pytest.raises(ValueError, match="Only voices you added yourself"):
        voices.replace_user_clip(vid, clip(tmp_path / "b.wav"))


def test_a_voice_narrating_a_job_cannot_change_its_recording(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "a.wav"), "Me", "en", "Words.")
    before = digest(me.path)
    _job("j1", "running", ["convert", "/b.epub", "--ref-voice", me.id], me.id, "Emma")
    with pytest.raises(voices.VoiceInUse, match='narrating "Emma".*then change the recording'):
        voices.replace_user_clip(me.id, clip(tmp_path / "b.wav", seed=2), transcript="x")
    assert digest(me.path) == before


def test_a_failed_change_leaves_the_voice_as_it_was(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "a.wav"), "Me", "en", "Words.")
    files = {n: digest(voices.voices_dir() / n) for n in listing()}
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"not audio")
    with pytest.raises(ValueError, match="Could not read this audio clip"):
        voices.replace_user_clip(me.id, bad, transcript="x")
    assert {n: digest(voices.voices_dir() / n) for n in listing()} == files


def test_deleting_a_voice_deletes_its_kept_original(tmp_path):
    me = voices.add_user_clip(clip(tmp_path / "a.wav"), "Me", "en", "Words.")
    assert voices.remove(me.id) and listing() == set()


# --- CLI --------------------------------------------------------------------------------------------------------

def _run(args):
    from typer.testing import CliRunner

    from audiobook_engine import cli

    res = CliRunner().invoke(cli.app, args)
    return res.exit_code, json.loads(res.stdout.strip().splitlines()[-1])


def test_cli_replace_needs_consent_only_for_a_new_file(tmp_path, fake_models):
    me = voices.add_user_clip(clip(tmp_path / "a.wav", seconds=6), "Me", "en", "Words.")
    code, ev = _run(["voices", "replace", me.id, "--file", str(clip(tmp_path / "b.wav")), "--transcript", "x"])
    assert code != 0 and "--i-have-rights" in ev["message"]
    code, ev = _run(["voices", "replace", me.id, "--isolate"])
    assert code == 0 and ev["event"] == "done" and ev["isolate"] is True and ev["id"] == me.id
    code, ev = _run(["voices", "replace", me.id, "--file", str(clip(tmp_path / "b.wav", seed=5)), "--transcript", "x",
                     "--i-have-rights", "--no-isolate", "--enhance"])
    assert code == 0 and (ev["isolate"], ev["enhance"], ev["transcript"]) == (False, True, "x")


def test_cli_add_passes_the_boxes_and_reports_a_missing_model_as_a_sentence(tmp_path, monkeypatch):
    monkeypatch.setattr(modelstore, "_local_dir", lambda asset: None)
    code, ev = _run(["voices", "add", str(clip(tmp_path / "a.wav")), "--name", "Me", "--lang", "en",
                     "--transcript", "x", "--i-have-rights", "--isolate"])
    assert code != 0 and ev["message"] == "Voice isolation needs DeepFilterNet3 (8.7 MB). Download it in Models."


# --- the real models (only when downloaded) ---------------------------------------------------------------------

def _installed(model_id):
    return modelstore._local_dir(modelstore.assets(model_id)[0]) is not None


def _noisy_tone(seconds=2.0):
    t = np.arange(int(seconds * cleanup.SR)) / cleanup.SR
    rng = np.random.default_rng(0)
    return (0.3 * np.sin(2 * np.pi * 220 * t) + 0.05 * rng.standard_normal(t.size)).astype(np.float32)


@pytest.mark.skipif(not _installed(modelstore.ISOLATION_ID), reason="DeepFilterNet3 not downloaded")
def test_real_isolation_returns_audio_of_the_same_length():
    x = _noisy_tone()
    y = cleanup.isolate(x)
    assert y.shape == x.shape and y.dtype == np.float32 and float(np.max(np.abs(y))) <= 1.0
    assert np.isfinite(y).all()


@pytest.mark.skipif(not _installed(modelstore.ENHANCER_ID), reason="MossFormer2-SE not downloaded")
def test_real_enhancer_returns_audio_of_the_same_length():
    x = _noisy_tone()
    y = cleanup.enhance(x)
    assert y.shape == x.shape and y.dtype == np.float32 and float(np.max(np.abs(y))) <= 1.0
    assert np.isfinite(y).all()
