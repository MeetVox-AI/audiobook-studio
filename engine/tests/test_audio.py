from __future__ import annotations

import json
import re
import subprocess
import sys
import threading
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

from audiobook_engine.audio import loudness, m4b
from audiobook_engine.audio.stitch import Pacing, assemble, trim_silence
from audiobook_engine.audio.validate import check_chunk
from audiobook_engine.cache import ChunkCache, chunk_key, tree_bytes
from audiobook_engine.perf import RateTracker

SR = 24000


def speechlike(seconds: float, amp: float = 0.1, seed: int = 0) -> np.ndarray:
    """Amplitude-modulated noise: a stand-in for speech with pauses."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(seconds * SR)) / SR
    env = 0.5 * (1 + np.sin(2 * np.pi * 3 * t)) * (np.sin(2 * np.pi * 0.25 * t) > -0.3)
    return (amp * env * rng.standard_normal(t.size)).astype(np.float32)


def ffmpeg_loudnorm_i(audio: np.ndarray) -> float:
    proc = subprocess.run(
        [m4b.FFMPEG, "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", "pipe:0",
         "-af", "loudnorm=print_format=json", "-f", "null", "-"],
        input=audio.astype("<f4").tobytes(), capture_output=True)
    return float(json.loads(re.search(r"\{[^{}]*\}", proc.stderr.decode(), re.S).group(0))["input_i"])


def test_measure_agrees_with_ffmpeg_loudnorm():
    a = speechlike(20, 0.05)
    assert abs(loudness.measure(a, SR).integrated_lufs - ffmpeg_loudnorm_i(a)) < 0.3


@pytest.mark.parametrize("amp", [0.01, 0.1, 0.5])
def test_normalize_hits_target_without_exceeding_peak(amp):
    out, info = loudness.normalize(speechlike(20, amp), SR)
    after = loudness.measure(out, SR)
    assert after.true_peak_db <= m4b.TARGET_TP + 0.2
    if not info["peak_limited"]:
        assert abs(after.integrated_lufs - m4b.TARGET_I) < 0.3


def test_normalize_silence_is_untouched():
    a = np.zeros(SR * 3, np.float32)
    out, info = loudness.normalize(a, SR)
    assert info.get("skipped") == "silent" and np.array_equal(out, a)


def test_tempo_changes_duration_only():
    a = speechlike(10)
    fast = loudness.change_tempo(a, SR, 1.25)
    assert abs(fast.size / a.size - 1 / 1.25) < 0.02
    assert loudness.change_tempo(a, SR, 1.0) is a


def test_trim_and_assemble_pauses():
    voice = speechlike(1.0, 0.2)
    padded = np.concatenate([np.zeros(SR, np.float32), voice, np.zeros(SR, np.float32)])
    trimmed = trim_silence(padded, SR)
    assert trimmed.size < voice.size + int(0.2 * SR)
    p = Pacing(chapter_lead_in=0.5, after_heading=1.0, sentence=0.25, paragraph=0.6, chapter_tail=1.5)
    pieces = [(padded, True, True), (padded, False, False), (padded, False, True), (padded, False, True)]
    out = assemble(pieces, SR, p)
    t = trim_silence(padded, SR).size
    expected = 0.5 + 1.0 + 0.25 + 0.6 + 1.5
    assert abs(out.size / SR - (4 * t / SR + expected)) < 0.01


def test_validate_flags_bad_chunks():
    assert check_chunk(np.zeros(0, np.float32), SR, 50) == ["empty audio"]
    assert "invalid" in check_chunk(np.array([np.nan] * 100, np.float32), SR, 50)[0]
    assert "silent audio" in check_chunk(np.zeros(SR, np.float32), SR, 10)
    assert any("too short" in i for i in check_chunk(speechlike(1, 0.2), SR, 200))
    assert any("too long" in i for i in check_chunk(speechlike(60, 0.2), SR, 100))
    assert check_chunk(speechlike(200 * 0.062, 0.2), SR, 200) == []


def test_cache_roundtrip_and_corruption(tmp_path):
    c = ChunkCache(tmp_path)
    k = chunk_key("Hello.", "en", "kokoro|x", "preset:af_heart", 1.0, None)
    assert k != chunk_key("Hello.", "en", "kokoro|x", "preset:af_heart", 1.1, None)
    assert c.get(k) is None
    a = speechlike(1.0, 0.2)
    c.put(k, a, SR)
    got, sr = c.get(k)
    assert sr == SR and np.max(np.abs(got - a)) < 1e-4
    c.path(k).write_bytes(b"not a flac")
    assert c.get(k) is None and not c.path(k).exists()


def test_cache_size_and_clear_skip_files_that_vanish_meanwhile(tmp_path, monkeypatch):
    """A running job renames its temporary files while 'cache info' counts them."""
    c = ChunkCache(tmp_path)
    k = chunk_key("Hello.", "en", "kokoro|x", "preset:af_heart", 1.0, None)
    c.put(k, speechlike(1.0, 0.2), SR)
    gone = c.path(k).with_suffix(".tmp.flac")
    gone.write_bytes(b"being renamed")
    real_stat = Path.stat
    seen = [0]

    def stat(self, *, follow_symlinks=True):
        if self.name == gone.name:
            seen[0] += 1
            if seen[0] % 2 == 0:  # is_file() saw it; it was renamed before its size was read
                raise FileNotFoundError(str(self))
        return real_stat(self, follow_symlinks=follow_symlinks)

    monkeypatch.setattr(Path, "stat", stat)
    assert tree_bytes(tmp_path) == c.size_bytes() > 0
    assert c.clear() > 0


def test_saved_rates_ignore_damaged_entries(tmp_path, monkeypatch):
    from audiobook_engine import perf

    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))
    perf.perf_file().write_text(json.dumps({"kokoro|a": {"chars_per_s": "fast"}, "kokoro|b": 5,
                                            "kokoro|c": {"chars_per_s": 0}}))
    assert perf.saved_rate("kokoro", "a") is None and perf.saved_rate("kokoro") is None
    perf.perf_file().write_text(json.dumps([1, 2, 3]))
    assert perf.saved_rate("kokoro") is None and perf.load_rates() == {}
    perf.save_rate("kokoro", "a", 1000, 10.0, 60.0, "test")
    assert perf.saved_rate("kokoro", "a") == 100.0


def test_rate_tracker_eta():
    t = RateTracker(window_s=100)
    assert t.eta(1000) == (None, None, None)
    exp, lo, hi = t.eta(1000, fallback_rate=50)
    assert exp == 20.0 and lo < exp < hi
    for i in range(10):
        t.add(100, 1.0, now=float(i))      # 100 chars/s early on
    for i in range(10, 20):
        t.add(100, 2.0, now=float(i * 2))  # slows to 50 chars/s (thermal drift)
    exp, lo, hi = t.eta(1000, tail_s=5)
    assert lo <= exp <= hi
    assert abs(exp - (1000 / t.window_rate + 5)) < 1e-6          # expected follows the recent window
    assert abs(hi - (1000 / min(t.window_rate, t.run_rate) + 5)) < 1e-6
    assert t.eta(0, tail_s=3) == (3, 3, 3)


def test_metadata_escaping(tmp_path):
    p = tmp_path / "meta.txt"
    m4b.write_metadata(p, {"title": "A=B; C#1\\"}, [m4b.ChapterMark("One; =two", 0, 1000)])
    text = p.read_text()
    assert r"title=A\=B\; C\#1\\" in text and r"title=One\; \=two" in text


def test_build_m4b_with_chapters_and_cover(tmp_path):
    files, marks, pos = [], [], 0.0
    for n, secs in enumerate([2.0, 3.5, 1.5]):
        f = tmp_path / f"{n:03d}.flac"
        sf.write(str(f), speechlike(secs, 0.1, seed=n), SR, subtype="PCM_24")
        files.append(f)
        marks.append(m4b.ChapterMark(f"Chapter {n + 1}: l'été", int(pos * 1000), int((pos + secs) * 1000)))
        pos += secs
    from tests.fixtures import png_bytes

    cover = m4b.prepare_cover(png_bytes(300, 450), "image/png", tmp_path)
    meta = tmp_path / "metadata.txt"
    m4b.write_metadata(meta, {"title": "Test Book", "artist": "Someone", "genre": "Audiobook"}, marks)
    out = tmp_path / "Test Book - Someone.m4b"
    seen = []
    tools = m4b.check_tools()
    m4b.encode_m4b(files, meta, cover, out, total_seconds=pos, encoder=tools["aac_encoder"], on_progress=seen.append)
    assert seen and max(seen) > 0.5  # -progress still reports with -loglevel error
    assert m4b.verify_m4b(out, 3, pos, True) == []
    info = m4b.probe(out)
    assert [c["tags"]["title"] for c in info["chapters"]] == [m.title for m in marks]
    assert info["format"]["tags"]["title"] == "Test Book"
    assert info["format"]["tags"].get("media_type") == "2"
    assert not out.with_suffix(".partial.m4b").exists()


def peaky(seconds: float) -> np.ndarray:
    """Quiet speech-like signal with rare sharp peaks (like TTS plosives)."""
    a = speechlike(seconds, 0.02)
    a[:: SR // 2] = 0.9
    return a


def test_peaky_audio_reaches_target_with_limiter():
    out, info = loudness.normalize(peaky(30), SR)
    after = loudness.measure(out, SR)
    assert info["peak_limited"] is True
    assert abs(after.integrated_lufs - m4b.TARGET_I) < 0.5
    assert after.true_peak_db <= m4b.TARGET_TP + 0.3


# ----------------------------------------------------------------------------- encode_m4b robustness

FAKE_FFMPEG = """#!{python}
import os, sys, time
with open(sys.argv[-1], "wb") as f:  # ffmpeg creates its output file first
    f.write(b"partial output")
mode = os.environ["FAKE_FFMPEG_MODE"]
if mode == "noisy":
    for i in range(20000):  # about 1 MB of log, far more than a pipe buffer
        sys.stderr.write("    Chapter #0:%d: start 1.000000, end 2.000000 (title of the chapter)\\n" % i)
    sys.stderr.flush()
    sys.stdout.write("out_time_us=500000\\nprogress=continue\\nout_time_us=1000000\\nprogress=end\\n")
    sys.exit(0)
if mode == "slow":
    for i in range(1200):
        sys.stdout.write("out_time_us=%d\\nprogress=continue\\n" % (i * 100000))
        sys.stdout.flush()
        time.sleep(0.05)
if mode == "fail":
    sys.stderr.write("noise\\n" * 50000 + "Something broke at the end\\n")
    sys.exit(1)
"""


@pytest.fixture
def popen_log(monkeypatch):
    """Records the processes encode_m4b starts; kills any left running after the test."""
    started: list[subprocess.Popen] = []
    real = subprocess.Popen

    class Recording(real):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            started.append(self)

    monkeypatch.setattr(m4b.subprocess, "Popen", Recording)
    yield started
    for proc in started:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


@pytest.fixture
def fake_ffmpeg(tmp_path, monkeypatch):
    script = tmp_path / "fake_ffmpeg.py"
    script.write_text(FAKE_FFMPEG.replace("{python}", sys.executable))
    script.chmod(0o755)
    monkeypatch.setattr(m4b, "FFMPEG", str(script))

    def use(mode: str):
        monkeypatch.setenv("FAKE_FFMPEG_MODE", mode)
    return use


def encode_inputs(tmp_path: Path) -> tuple[list[Path], Path, Path]:
    work = tmp_path / "job"
    work.mkdir(exist_ok=True)
    meta = work / "metadata.txt"
    m4b.write_metadata(meta, {"title": "T"}, [m4b.ChapterMark("One", 0, 1000)])
    return [work / "000.flac"], meta, tmp_path / "T - A.m4b"


def run_with_timeout(fn, popen_log, timeout: float = 30.0):
    box: dict = {}

    def target():
        try:
            box["result"] = fn()
        except BaseException as exc:  # noqa: BLE001 - re-raised in the test thread
            box["error"] = exc

    t = threading.Thread(target=target, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        for proc in popen_log:
            proc.kill()
        t.join(5)
        pytest.fail("encode_m4b hung: ffmpeg blocked on a full stderr pipe")
    if "error" in box:
        raise box["error"]
    return box.get("result")


def test_encode_does_not_hang_when_ffmpeg_logs_a_lot(tmp_path, fake_ffmpeg, popen_log):
    fake_ffmpeg("noisy")
    files, meta, out = encode_inputs(tmp_path)
    seen = []
    run_with_timeout(lambda: m4b.encode_m4b(files, meta, None, out, total_seconds=1.0, on_progress=seen.append),
                     popen_log)
    assert out.read_bytes() == b"partial output" and seen[-1] == 1.0
    assert "-loglevel" in popen_log[0].args and popen_log[0].args[popen_log[0].args.index("-loglevel") + 1] == "error"


def test_encode_failure_keeps_the_end_of_the_log_and_removes_the_partial_file(tmp_path, fake_ffmpeg, popen_log):
    fake_ffmpeg("fail")
    files, meta, out = encode_inputs(tmp_path)
    with pytest.raises(m4b.FFmpegError, match="Something broke at the end"):
        run_with_timeout(lambda: m4b.encode_m4b(files, meta, None, out, total_seconds=1.0), popen_log)
    assert not out.with_suffix(".partial.m4b").exists() and not out.exists()


class _Cancel(BaseException):
    """Stands in for pipeline.Cancelled, raised by the SIGTERM handler mid-encode."""


def test_encode_interrupted_kills_ffmpeg_and_removes_the_partial_file(tmp_path, fake_ffmpeg, popen_log):
    fake_ffmpeg("slow")
    files, meta, out = encode_inputs(tmp_path)

    def cancel_on_progress(fraction):
        if fraction > 0:
            raise _Cancel()

    with pytest.raises(_Cancel):
        m4b.encode_m4b(files, meta, None, out, total_seconds=60.0, on_progress=cancel_on_progress)
    assert popen_log[0].returncode is not None  # killed and reaped, not left running
    assert not out.with_suffix(".partial.m4b").exists() and not out.exists()


def test_encode_with_relative_paths(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    work = Path("job")
    (work / "chapters").mkdir(parents=True)
    files = []
    for n, secs in enumerate([1.0, 1.5]):
        f = work / "chapters" / f"{n:03d}.flac"
        sf.write(str(f), speechlike(secs, 0.1, seed=n), SR, subtype="PCM_24")
        files.append(f)
    meta = work / "metadata.txt"
    m4b.write_metadata(meta, {"title": "T"}, [m4b.ChapterMark("One", 0, 1000), m4b.ChapterMark("Two", 1000, 2500)])
    out = Path("T - A.m4b")
    m4b.encode_m4b(files, meta, None, out, total_seconds=2.5, encoder=m4b.check_tools()["aac_encoder"])
    assert m4b.verify_m4b(out, 2, 2.5, False) == []
    entries = (work / "concat.txt").read_text().splitlines()
    assert all(Path(e[len("file '"):-1]).is_absolute() for e in entries)


def test_encode_book_with_hundreds_of_long_chapter_titles(tmp_path, popen_log):
    """At ffmpeg's default log level this chapter dump alone exceeds a 64 KiB pipe."""
    n, secs = 400, 8.0
    f = tmp_path / "000.flac"
    sf.write(str(f), speechlike(secs, 0.1), SR, subtype="PCM_24")
    step = int(secs * 1000 / n)
    marks = [m4b.ChapterMark(f"Chapitre {i + 1} — Où l'on voit comment le jeune homme quitta la ville pour toujours",
                             i * step, (i + 1) * step) for i in range(n)]
    meta = tmp_path / "metadata.txt"
    m4b.write_metadata(meta, {"title": "Long Book"}, marks)
    out = tmp_path / "Long Book - Someone.m4b"
    encoder = m4b.check_tools()["aac_encoder"]
    run_with_timeout(lambda: m4b.encode_m4b([f], meta, None, out, total_seconds=secs, encoder=encoder),
                     popen_log, timeout=120)
    assert m4b.verify_m4b(out, n, secs, False) == []

