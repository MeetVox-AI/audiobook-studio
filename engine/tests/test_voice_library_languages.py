"""The reference-voice library for every language: structure, licences, and the offline download logic.

No network and no Whisper: the library file is only read, and downloads are served from local fixtures.
"""

from __future__ import annotations

import hashlib
import io
import re
import tarfile

import numpy as np
import pytest
import soundfile as sf

from audiobook_engine import languages, voices

SR = 24000
NEW_LANGUAGES = ["es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"]
REQUIRED = ["id", "name", "lang", "gender", "description", "license", "license_detail", "commercial_ok",
            "attribution", "source_page", "audio_url", "transcript", "duration_s", "sample_rate", "verified"]


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))

    def no_whisper(path, lang):
        raise AssertionError("tests must not load Whisper")

    monkeypatch.setattr(voices, "_transcribe", no_whisper)


# --- the shipped library file -----------------------------------------------------------------

def test_every_entry_has_the_fields_the_app_and_downloader_read():
    for e in voices.library():
        missing = [k for k in REQUIRED if k not in e]
        assert not missing, f"{e.get('id')}: missing {missing}"
        assert isinstance(e["commercial_ok"], bool), e["id"]
        assert e["gender"] in {"female", "male"}, e["id"]
        assert isinstance(e["verified"], dict) and e["verified"].get("license_evidence"), e["id"]
        assert e["verified"].get("listened") in (True, False), e["id"]


def test_ids_are_unique_and_safe_file_names():
    ids = [e["id"] for e in voices.library()]
    assert len(ids) == len(set(ids))
    for i in ids:
        assert voices._check_id(i) == i


def test_every_entry_names_its_licence_and_credit_and_uses_https():
    for e in voices.library():
        for k in ("license", "license_detail", "attribution", "description", "name"):
            assert isinstance(e[k], str) and e[k].strip(), f"{e['id']}: empty {k}"
        for k in ("audio_url", "source_page"):
            assert e[k].startswith("https://"), f"{e['id']}: {k} is not https"
        # a licence we recognise, never a blank or "unknown"
        assert re.search(r"CC0|CC BY|Public domain", e["license"]), e["id"]
        assert "NC" not in e["license"] or e["commercial_ok"] is False, e["id"]
        if e["license"].startswith("CC BY"):
            assert "http" in e["attribution"] or "(" in e["attribution"], f"{e['id']}: CC BY needs a credit"


def test_every_entry_language_is_in_the_registry():
    for e in voices.library():
        assert languages.normalize_code(e["lang"]) == e["lang"], f"{e['id']}: {e['lang']} is not a registry code"


def test_every_new_language_has_a_voice_and_ids_follow_the_pattern():
    by_lang: dict[str, list[dict]] = {}
    for e in voices.library():
        by_lang.setdefault(e["lang"], []).append(e)
    for code in NEW_LANGUAGES:
        entries = by_lang.get(code, [])
        assert entries, f"no reference voice for {code}"
        for e in entries:
            assert re.fullmatch(rf"{code}_[a-z0-9]+_[a-z0-9]+_(female|male)", e["id"]), e["id"]
            assert e["id"].endswith(e["gender"]), e["id"]


def test_new_entries_carry_a_transcript_a_checksum_and_a_usable_length():
    for e in voices.library():
        if e["lang"] not in NEW_LANGUAGES:
            continue
        assert len(e["transcript"].strip()) >= 20, f"{e['id']}: a clone needs the exact words"
        assert re.fullmatch(r"[0-9a-f]{64}", e["source_sha256"]), e["id"]
        assert voices.MIN_CLIP_S <= e["duration_s"] <= voices.MAX_CLIP_S, e["id"]
        assert e["sample_rate"] >= 16000, e["id"]


def test_windows_and_archive_members_are_well_formed():
    for e in voices.library():
        if "start_s" in e or "end_s" in e:
            assert 0 <= e["start_s"] < e["end_s"], e["id"]
            assert e["end_s"] - e["start_s"] <= voices.MAX_CLIP_S + 1e-6, e["id"]
            assert abs((e["end_s"] - e["start_s"]) - e["duration_s"]) < 1.0, e["id"]
        member = e.get("archive_member")
        if member is not None:
            assert not member.startswith("/") and ".." not in member.split("/"), e["id"]
            assert re.search(r"\.tar(\.gz)?$|\.tgz$", e["audio_url"]), f"{e['id']}: only tar archives are supported"
        else:
            assert re.search(r"\.(mp3|wav|flac|ogg|opus|m4a)$", e["audio_url"]), e["id"]


# --- the download logic, offline ---------------------------------------------------------------

def tone(seconds, hz, amp=0.4):
    t = np.arange(int(seconds * SR)) / SR
    return (amp * np.sin(2 * np.pi * hz * t)).astype(np.float32)


def wav_bytes(audio) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, audio, SR, format="WAV", subtype="PCM_16")
    return buf.getvalue()


def dominant_hz(audio) -> float:
    spec = np.abs(np.fft.rfft(audio * np.hanning(audio.size)))
    return float(np.argmax(spec) * SR / audio.size)


def serve(monkeypatch, payload: bytes):
    monkeypatch.setattr(voices.urllib.request, "urlopen", lambda req, timeout=None: io.BytesIO(payload))


def entry(**extra) -> dict:
    base = {"id": "xx_test_clip_female", "name": "Test (F)", "lang": "es", "gender": "female",
            "description": "fixture", "license": "CC0", "license_detail": "fixture", "commercial_ok": True,
            "attribution": "fixture", "source_page": "https://example.org/p", "audio_url": "https://example.org/a.wav",
            "transcript": "texto exacto de la grabación", "duration_s": 8.0, "sample_rate": SR, "verified": {}}
    base.update(extra)
    return base


def use_library(monkeypatch, *entries):
    monkeypatch.setattr(voices, "library", lambda: list(entries))


def test_a_plain_clip_downloads_with_its_published_transcript(monkeypatch):
    payload = wav_bytes(tone(8.0, 300))
    use_library(monkeypatch, entry(source_sha256=hashlib.sha256(payload).hexdigest()))
    serve(monkeypatch, payload)
    iv = voices.download("xx_test_clip_female")
    assert iv.transcript == "texto exacto de la grabación" and iv.transcript_source == "published"
    audio, sr = sf.read(str(iv.path))
    assert audio.ndim == 1 and sr == SR and abs(audio.size / sr - 8.0) < 0.3


def test_a_segment_of_a_long_recording_is_cut_by_its_time_window(monkeypatch):
    # 0-10 s at 300 Hz, 10-20 s at 900 Hz, 20-30 s at 1500 Hz; the library asks for 11 s to 19 s
    long = np.concatenate([tone(10, 300), tone(10, 900), tone(10, 1500)])
    use_library(monkeypatch, entry(start_s=11.0, end_s=19.0, duration_s=8.0))
    serve(monkeypatch, wav_bytes(long))
    iv = voices.download("xx_test_clip_female")
    audio, sr = sf.read(str(iv.path))
    assert abs(audio.size / sr - 8.0) < 0.3
    assert abs(dominant_hz(audio) - 900) < 20  # nothing from the neighbouring stretches
    assert iv.transcript_source == "published"


def test_the_window_never_exceeds_the_clip_limit(monkeypatch):
    use_library(monkeypatch, entry(start_s=2.0, end_s=40.0, duration_s=18.0))
    serve(monkeypatch, wav_bytes(tone(45, 440)))
    iv = voices.download("xx_test_clip_female")
    audio, sr = sf.read(str(iv.path))
    assert audio.size / sr <= voices.MAX_CLIP_S + 0.1


def test_a_file_that_is_not_the_checked_one_is_refused_and_leaves_nothing(monkeypatch):
    good, other = wav_bytes(tone(8.0, 300)), wav_bytes(tone(8.0, 500))
    use_library(monkeypatch, entry(source_sha256=hashlib.sha256(good).hexdigest()))
    serve(monkeypatch, other)
    with pytest.raises(ValueError, match="checksum differs"):
        voices.download("xx_test_clip_female")
    assert list(voices.voices_dir().iterdir()) == []


def test_the_installed_note_records_the_checksum_of_what_was_downloaded(monkeypatch):
    payload = wav_bytes(tone(8.0, 300))
    use_library(monkeypatch, entry())
    serve(monkeypatch, payload)
    iv = voices.download("xx_test_clip_female")
    assert iv.meta["sha256"] == hashlib.sha256(payload).hexdigest()


def make_tar_gz(members: dict[str, bytes], pad_first: int = 0) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def archive_entry(member: str, payload: bytes) -> dict:
    return entry(audio_url="https://example.org/corpus/test.tar.gz", archive_member=member,
                 source_sha256=hashlib.sha256(payload).hexdigest())


def test_one_member_is_taken_from_a_corpus_archive(monkeypatch):
    wanted = wav_bytes(tone(8.0, 700))
    archive = make_tar_gz({"test/a.wav": wav_bytes(tone(8.0, 300)), "test/b.wav": wanted, "test/c.wav": wav_bytes(tone(8.0, 1100))})
    use_library(monkeypatch, archive_entry("test/b.wav", wanted))
    serve(monkeypatch, archive)
    iv = voices.download("xx_test_clip_female")
    audio, sr = sf.read(str(iv.path))
    assert abs(dominant_hz(audio) - 700) < 20
    assert iv.meta["sha256"] == hashlib.sha256(wanted).hexdigest()


def test_a_missing_archive_member_is_a_clear_error_and_leaves_nothing(monkeypatch):
    archive = make_tar_gz({"test/a.wav": wav_bytes(tone(8.0, 300))})
    use_library(monkeypatch, archive_entry("test/nope.wav", b"x"))
    serve(monkeypatch, archive)
    with pytest.raises(ValueError, match="not found in the archive"):
        voices.download("xx_test_clip_female")
    assert list(voices.voices_dir().iterdir()) == []


def test_reading_stops_after_the_streaming_limit(monkeypatch):
    rng = np.random.default_rng(1)  # noise does not compress, so the archive really is large
    noise = (rng.standard_normal(SR * 6) * 0.3).astype(np.float32)
    archive = make_tar_gz({"test/a.wav": wav_bytes(noise), "test/b.wav": wav_bytes(tone(8.0, 700))})
    use_library(monkeypatch, archive_entry("test/b.wav", b"x"))
    serve(monkeypatch, archive)
    monkeypatch.setattr(voices, "MAX_ARCHIVE_STREAM_BYTES", 100_000)
    with pytest.raises(ValueError, match="not within the first"):
        voices.download("xx_test_clip_female")
    assert list(voices.voices_dir().iterdir()) == []


def test_an_oversized_archive_member_is_refused(monkeypatch):
    archive = make_tar_gz({"test/big.wav": b"\0" * 4096})
    use_library(monkeypatch, archive_entry("test/big.wav", b"x"))
    serve(monkeypatch, archive)
    monkeypatch.setattr(voices, "MAX_DOWNLOAD_BYTES", 1024)
    with pytest.raises(ValueError, match="larger than 20 MB"):
        voices.download("xx_test_clip_female")
    assert list(voices.voices_dir().iterdir()) == []


def test_a_directory_with_the_member_name_is_not_taken_for_the_file(monkeypatch):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        d = tarfile.TarInfo("test/b.wav")
        d.type = tarfile.DIRTYPE
        tar.addfile(d)
    use_library(monkeypatch, archive_entry("test/b.wav", b"x"))
    serve(monkeypatch, buf.getvalue())
    with pytest.raises(ValueError, match="not found in the archive"):
        voices.download("xx_test_clip_female")
