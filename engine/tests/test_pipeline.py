"""Conversion pipeline and CLI behaviour, with a fake TTS engine (no model is loaded).

The fake engine returns speech-like noise of the expected length, so chunk
validation, stitching, loudness, ffmpeg encoding and the job files all run for real.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time
import zlib
from pathlib import Path

import numpy as np
import pytest
from typer.testing import CliRunner

from audiobook_engine import cli, jobs, paths, pipeline
from audiobook_engine.audio import m4b
from audiobook_engine.cache import ChunkCache
from audiobook_engine.models import Book, Cover, IngestError, Section
from audiobook_engine.perf import save_rate
from audiobook_engine.pipeline import Cancelled, ConvertOptions
from audiobook_engine.tts import EngineError, VoiceChoice
from audiobook_engine.tts import kokoro as kokoro_mod
from audiobook_engine.tts.kokoro import SPEC as KOKORO

SR = 24000
WARMUP = {"This is a short warm up sentence.", "Ceci est une courte phrase de préchauffage."}

PARAGRAPHS = [
    ["The old man walked slowly to the window and looked out at the calm grey sea.",
     "He thought about the letter that had arrived that morning from his brother."],
    ["The harbour was quiet and the fishing boats rocked gently against the stone wall.",
     "A gull cried somewhere above the roofs while the bakery opened its blue shutters."],
    ["By evening the wind had turned and the first drops of rain struck the glass.",
     "She lit the lamp, sat down at the table and began to write her long reply."],
]


def speech(seconds: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = np.arange(max(1, int(seconds * SR))) / SR
    env = 0.5 * (1 + np.sin(2 * np.pi * 3 * t))
    return (0.1 * env * rng.standard_normal(t.size)).astype(np.float32)


class FakeEngine:
    """Stands in for an MLX engine. `hook(text)` runs before each text; `audio(text)` may override."""

    sample_rate = SR

    def __init__(self, spec=KOKORO):
        self.spec = spec
        self.calls: list[str] = []
        self.hook = None
        self.audio = None

    def load(self, voice=None) -> float:
        return 0.0

    def settings_fingerprint(self) -> str:
        return f"fake|{self.spec.id}|{self.spec.deterministic}"

    def synthesize(self, texts, voice, lang, speed=1.0, seed=None):
        out = []
        for text in texts:
            if text not in WARMUP:
                self.calls.append(text)
                if self.hook:
                    self.hook(text)
            custom = self.audio(text) if self.audio else None
            out.append(custom if custom is not None else speech(len(text) * 0.062 / speed, zlib.crc32(text.encode())))
        return out


def plain_paragraph(text, lang, rules=None, is_heading=False):
    return " ".join(text.split()) + ("." if is_heading else "")


def plain_section(paragraphs, lang, starts_with_heading, title, rules=None):
    head = [plain_paragraph(title, lang, is_heading=True)] if title and not starts_with_heading else []
    return head + [plain_paragraph(p, lang) for p in paragraphs]


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(pipeline, "keep_awake", lambda: None)
    monkeypatch.setattr(pipeline, "power_source", lambda: None)
    # Text normalisation has its own tests; keep these independent of its rules.
    monkeypatch.setattr(pipeline, "normalize_paragraph", plain_paragraph)
    monkeypatch.setattr(pipeline, "normalize_section", plain_section)


@pytest.fixture
def engine(monkeypatch):
    eng = FakeEngine()
    monkeypatch.setattr(pipeline, "get_engine", lambda engine_id: eng)
    return eng


def make_book(tmp_path, monkeypatch, paragraphs=PARAGRAPHS, include=True, name="book.epub") -> Path:
    path = tmp_path / name
    path.write_bytes(b"stand-in file: read_book is replaced in these tests")
    sections = [Section(i, f"Chapter {i + 1}", "chapter", list(p), include=include) for i, p in enumerate(paragraphs)]
    book = Book(str(path), "epub", "Test Book", "Jane Doe", "en", "metadata", sections)
    monkeypatch.setattr(pipeline, "read_book", lambda p: book)
    return path


def opts(**kw) -> ConvertOptions:
    kw.setdefault("verify", False)  # never load the real Whisper model in unit tests
    return ConvertOptions(engine="kokoro", **kw)


def run(book: Path, o: ConvertOptions, job_dir: Path | None = None) -> tuple[dict, list[dict]]:
    events: list[dict] = []
    result = pipeline.convert(book, o, events.append, job_dir)
    return result, events


def first(events: list[dict], kind: str) -> dict:
    return next(e for e in events if e["event"] == kind)


def job_dir_for(book: Path, o: ConvertOptions) -> Path:
    return paths.jobs_dir() / pipeline.prepare(book, o).job_id


def file_digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


# ----------------------------------------------------------------------------- happy path

def test_convert_with_fake_engine_produces_a_verified_m4b(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    result, events = run(book, opts())
    assert result["verification_problems"] == [] and result["chapters"] == 4  # intro + 3 chapters
    assert Path(result["output"]) == tmp_path / "Test Book - Jane Doe.m4b"
    assert events[0]["event"] == "run_start"
    assert jobs.status(job_dir_for(book, opts()))["state"] == "done"


# ----------------------------------------------------------------------------- cancel (Cancelled is a BaseException)

def test_cancelled_is_a_base_exception():
    assert issubclass(Cancelled, BaseException) and not issubclass(Cancelled, Exception)


def test_cancel_inside_a_cache_read_is_not_swallowed(tmp_path, monkeypatch):
    cache = ChunkCache(tmp_path / "cache")
    key = "ab" * 32
    cache.put(key, speech(1.0, 0), SR)

    def interrupted(*args, **kwargs):
        raise Cancelled()  # what the SIGTERM handler does at an arbitrary point

    monkeypatch.setattr("audiobook_engine.cache.sf.read", interrupted)
    with pytest.raises(Cancelled):
        cache.get(key)
    assert cache.path(key).exists()  # a valid chunk is not deleted as "corrupt"


def test_cancel_waits_for_running_assembly_and_resume_skips_finished_chapters(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    finished: list[str] = []
    real_assemble = pipeline._assemble_chapter

    def slow_assemble(*args):
        time.sleep(0.8)
        seconds = real_assemble(*args)
        finished.append(Path(args[4]).name)
        return seconds

    def cancel_in_chapter_two(text):
        if "harbour" in text:
            raise Cancelled()

    monkeypatch.setattr(pipeline, "_assemble_chapter", slow_assemble)
    engine.hook = cancel_in_chapter_two
    with pytest.raises(Cancelled):
        run(book, o)
    # The in-flight assemblies finished before convert returned (and before the GPU lock was released).
    assert sorted(finished) == ["000.flac", "001.flac"]
    assert not [t for t in threading.enumerate() if t.name.startswith("assemble") and t.is_alive()]
    assert json.loads((jd / "job.json").read_text())["state"] == "cancelled"
    assert not list((jd / "chapters").glob("*.tmp.flac"))

    engine.hook = None
    result, events = run(book, o)
    assert [e["n"] for e in events if e["event"] == "section_skip"] == [0, 1]
    assert result["chapters"] == 4 and result["verification_problems"] == []


def test_a_non_decoding_error_while_reading_a_cached_chunk_does_not_delete_it(tmp_path, monkeypatch):
    """Only decoding errors mean 'corrupt chunk'; anything else (here MemoryError) propagates."""
    cache = ChunkCache(tmp_path / "cache")
    key = "cd" * 32
    cache.put(key, speech(1.0, 0), SR)

    def out_of_memory(*args, **kwargs):
        raise MemoryError()

    monkeypatch.setattr("audiobook_engine.cache.sf.read", out_of_memory)
    with pytest.raises(MemoryError):
        cache.get(key)
    assert cache.path(key).exists()


def test_a_cancel_inside_code_that_catches_exception_still_stops_the_job(tmp_path, monkeypatch, engine):
    """The SIGTERM handler can fire inside any `except Exception` block (here: reading saved speeds)."""
    class CancelledWhileReading:
        def read_text(self, *args, **kwargs):
            raise Cancelled()

    monkeypatch.setattr("audiobook_engine.perf.perf_file", lambda: CancelledWhileReading())
    book = make_book(tmp_path, monkeypatch)
    with pytest.raises(Cancelled):
        run(book, opts())
    assert jobs.read_state(job_dir_for(book, opts()))["state"] == "cancelled" and engine.calls == []


@pytest.fixture
def harmless_sigterm():
    """Real SIGTERMs are sent to this process: outside convert() they must not kill pytest."""
    previous = signal.signal(signal.SIGTERM, lambda signum, frame: None)
    yield
    signal.signal(signal.SIGTERM, previous)


def _slow_assembly_that_sends_sigterm(monkeypatch, start: threading.Event, finished: list[str]):
    """Each running chapter assembly waits for `start`, then sends SIGTERM to this process while
    the main thread waits for it to finish (the app pressing Cancel again)."""
    real_assemble = pipeline._assemble_chapter

    def slow_assemble(*args):
        start.wait(10)
        time.sleep(0.3)  # the main thread is in pool.shutdown(wait=True) by now
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(0.5)
        seconds = real_assemble(*args)
        finished.append(Path(args[4]).name)
        return seconds

    monkeypatch.setattr(pipeline, "_assemble_chapter", slow_assemble)


def test_a_repeated_sigterm_does_not_cut_short_the_wait_for_running_assemblies(tmp_path, monkeypatch, engine,
                                                                               harmless_sigterm):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    cancelled, finished = threading.Event(), []
    _slow_assembly_that_sends_sigterm(monkeypatch, cancelled, finished)

    def jobs_cancel_in_chapter_two(text):
        if "harbour" in text:
            cancelled.set()
            os.kill(os.getpid(), signal.SIGTERM)  # 'jobs cancel': the handler raises Cancelled here
            time.sleep(5)

    engine.hook = jobs_cancel_in_chapter_two
    with pytest.raises(Cancelled):
        run(book, o)
    # Both in-flight assemblies finished before convert returned, i.e. before the locks were released.
    assert sorted(finished) == ["000.flac", "001.flac"]
    assert not [t for t in threading.enumerate() if t.name.startswith("assemble") and t.is_alive()]
    assert jobs.read_state(jd)["state"] == "cancelled" and jobs.lock_holder(jd) is None
    assert "error" not in jobs.read_state(jd)  # a plain cancel: nothing failed


def test_a_sigterm_while_a_failed_run_waits_for_assemblies_is_acted_on_after_the_wait(tmp_path, monkeypatch, engine,
                                                                                      harmless_sigterm):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    failing, finished = threading.Event(), []
    _slow_assembly_that_sends_sigterm(monkeypatch, failing, finished)

    def engine_crash(text):
        if "harbour" in text:
            failing.set()
            raise RuntimeError("engine crashed")

    engine.hook = engine_crash
    with pytest.raises(Cancelled):
        run(book, o)
    assert sorted(finished) == ["000.flac", "001.flac"]
    assert not [t for t in threading.enumerate() if t.name.startswith("assemble") and t.is_alive()]
    assert jobs.read_state(jd)["state"] == "cancelled"


def test_a_failed_run_cancelled_while_it_waits_for_assemblies_keeps_its_error(tmp_path, monkeypatch, engine,
                                                                              harmless_sigterm):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    failing, finished = threading.Event(), []
    _slow_assembly_that_sends_sigterm(monkeypatch, failing, finished)

    def engine_crash(text):
        if "harbour" in text:
            failing.set()
            raise RuntimeError("engine crashed: out of GPU memory")

    engine.hook = engine_crash
    with pytest.raises(Cancelled):
        run(book, o)
    state = jobs.read_state(jd)
    assert state["state"] == "cancelled" and state["error"] == "RuntimeError: engine crashed: out of GPU memory"
    logged = [json.loads(x) for x in (jd / "events.jsonl").read_text().splitlines()]
    assert logged[-1]["event"] == "cancelled" and logged[-1]["error"] == state["error"]
    assert "engine crashed: out of GPU memory" in logged[-1]["message"]  # what the app shows for a cancelled job


def test_a_cancel_that_lands_while_an_error_is_being_handled_is_a_plain_cancel(tmp_path, monkeypatch, engine,
                                                                              harmless_sigterm):
    """The handler can fire inside any `except` block: the error handled there did not stop the run."""
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)

    def cancel_while_handling_an_error(text):
        if "harbour" in text:
            try:
                raise ValueError("a recoverable problem")
            except ValueError:
                os.kill(os.getpid(), signal.SIGTERM)
                time.sleep(5)  # the handler raises Cancelled here

    engine.hook = cancel_while_handling_an_error
    with pytest.raises(Cancelled):
        run(book, o)
    state = jobs.read_state(jd)
    assert state["state"] == "cancelled" and "error" not in state


def _spin(seconds: float) -> None:
    """Busy Python code: a pending signal handler runs inside it (between bytecodes)."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pass


def test_a_repeated_sigterm_does_not_interrupt_recording_the_cancel(tmp_path, monkeypatch, engine, harmless_sigterm):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    real_update = jobs.update_state

    def update_state(job_dir, **fields):
        if fields.get("state") == "cancelled":
            os.kill(os.getpid(), signal.SIGTERM)  # 'jobs cancel' again while the first cancel is recorded
            _spin(0.3)
        real_update(job_dir, **fields)

    def jobs_cancel_in_chapter_two(text):
        if "harbour" in text:
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(5)  # the handler raises Cancelled here

    monkeypatch.setattr(jobs, "update_state", update_state)
    engine.hook = jobs_cancel_in_chapter_two
    with pytest.raises(Cancelled):
        run(book, o)
    assert jobs.read_state(jd)["state"] == "cancelled"
    assert json.loads((jd / "events.jsonl").read_text().splitlines()[-1])["event"] == "cancelled"


def test_a_sigterm_after_a_lost_cancel_still_stops_the_job(tmp_path, monkeypatch, engine, harmless_sigterm):
    """Python only prints an exception raised inside a finalizer: a Cancelled raised there is lost.
    The next 'jobs cancel', once the re-arm delay has passed, must still stop the job."""
    monkeypatch.setattr(pipeline, "CANCEL_REARM_S", 0.3, raising=False)
    lost: list[type] = []
    monkeypatch.setattr(sys, "unraisablehook", lambda unraisable: lost.append(unraisable.exc_type))

    class Finalizer:
        def __del__(self):
            os.kill(os.getpid(), signal.SIGTERM)  # the first 'jobs cancel' lands in a finalizer
            _spin(0.3)

    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)

    def cancel_twice_in_chapter_two(text):
        if "harbour" in text and not lost:
            Finalizer()  # dropped at once: __del__ runs here and its Cancelled is lost
            assert lost == [Cancelled]
            time.sleep(0.5)  # the job carries on; the user presses Cancel again
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(5)  # the handler raises Cancelled here

    engine.hook = cancel_twice_in_chapter_two
    with pytest.raises(Cancelled):
        run(book, o)
    assert jobs.read_state(jd)["state"] == "cancelled"


def _encode_unmarked_m4b(path: Path) -> None:
    """An audiobook made before job marks existed: its comment names no job."""
    import soundfile as sf

    work = path.parent / "legacy-work"
    work.mkdir()
    f = work / "000.flac"
    sf.write(str(f), speech(1.0, 1), SR, subtype="PCM_16")
    meta = work / "metadata.txt"
    m4b.write_metadata(meta, {"title": "Test Book", "comment": "Narrated locally."}, [m4b.ChapterMark("One", 0, 1000)])
    m4b.encode_m4b([f], meta, None, path, total_seconds=1.0, encoder=m4b.check_tools()["aac_encoder"])


def test_cancel_and_resume_still_replace_this_jobs_own_unmarked_audiobook(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    legacy = tmp_path / "Test Book - Jane Doe.m4b"
    _encode_unmarked_m4b(legacy)
    jd.mkdir(parents=True)
    jobs.update_state(jd, job_id=jd.name, state="done", output=str(legacy))  # this job made it

    def cancel_in_chapter_two(text):
        if "harbour" in text:
            raise Cancelled()

    engine.hook = cancel_in_chapter_two
    with pytest.raises(Cancelled):
        run(book, o)
    assert str(legacy) in jobs.read_state(jd)["outputs"]  # still owned after a cancelled run
    engine.hook = None
    result, _ = run(book, o)
    assert Path(result["output"]) == legacy
    assert [p.name for p in tmp_path.glob("*.m4b")] == [legacy.name]  # no duplicate '(af_heart)' file


def test_a_cancel_before_the_job_starts_is_recorded_as_cancelled_not_as_an_error(tmp_path, monkeypatch):
    book = tmp_path / "b.epub"
    book.write_bytes(b"x")

    def cancelled_while_reading(path):
        raise Cancelled()

    monkeypatch.setattr(pipeline, "read_book", cancelled_while_reading)
    jd = tmp_path / "job"
    with pytest.raises(Cancelled):
        pipeline.convert(book, opts(), lambda ev: None, jd)
    st = jobs.status(jd)
    assert st["state"] == "cancelled" and st["last_error"] is None and "error" not in st
    assert [json.loads(x)["event"] for x in (jd / "events.jsonl").read_text().splitlines()] == ["run_start", "cancelled"]


# A real conversion process (fake engine, no model) stopped with a real SIGTERM, like 'jobs cancel'.
CHILD = r"""
import os, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from audiobook_engine import cache as cache_mod, pipeline
from audiobook_engine.audio import m4b
from audiobook_engine.models import Book, Section
from tests.test_pipeline import PARAGRAPHS, FakeEngine, plain_paragraph, plain_section

book_path, job_dir, mode = Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
book = Book(str(book_path), "epub", "Test Book", "Jane Doe", "en", "metadata",
            [Section(i, f"Chapter {i + 1}", "chapter", list(p)) for i, p in enumerate(PARAGRAPHS)])
engine = FakeEngine()
pipeline.read_book = lambda p: book
pipeline.get_engine = lambda engine_id: engine
pipeline.normalize_paragraph, pipeline.normalize_section = plain_paragraph, plain_section
pipeline.keep_awake, pipeline.power_source = (lambda: None), (lambda: None)

if mode == "slow-cache":
    real_read = cache_mod.sf.read
    def slow_read(*args, **kwargs):
        print("reading", flush=True)
        time.sleep(0.3)
        return real_read(*args, **kwargs)
    cache_mod.sf.read = slow_read
elif mode == "slow-encode":
    real_encode, real_ffmpeg = m4b.encode_m4b, m4b.FFMPEG
    def slow_encode(*args, **kwargs):
        m4b.FFMPEG = sys.argv[5]  # writes the output file, then stalls like a long encode
        print("encoding", flush=True)
        try:
            return real_encode(*args, **kwargs)
        finally:
            m4b.FFMPEG = real_ffmpeg
    pipeline.m4b.encode_m4b = slow_encode
try:
    pipeline.convert(book_path, pipeline.ConvertOptions(engine="kokoro", verify=False), lambda ev: None, job_dir)
except pipeline.Cancelled:
    sys.exit(130)
"""

STALLING_FFMPEG = """#!{python}
import os, sys, time
with open(sys.argv[-1], "wb") as f:
    f.write(b"partial output")
with open(os.environ["STALL_PID_FILE"], "w") as f:
    f.write(str(os.getpid()))
time.sleep(60)
"""


def _run_child(tmp_path, book, jd, mode, *extra) -> subprocess.Popen:
    script = tmp_path / "child.py"
    script.write_text(CHILD)
    root = str(Path(__file__).resolve().parent.parent)
    return subprocess.Popen([sys.executable, str(script), root, str(book), str(jd), mode, *extra],
                            stdout=subprocess.PIPE, text=True)


def _wait_for_line(proc: subprocess.Popen, want: str, timeout: float = 60.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 0.2)
        if ready:
            line = proc.stdout.readline()
            if line.strip() == want:
                return
            if not line:
                break
    proc.kill()
    proc.wait()
    pytest.fail(f"the child never reported '{want}'")


def _cached_chunks() -> set[Path]:
    return set((paths.home() / "cache" / "chunks").rglob("*.flac"))


def test_sigterm_while_reading_cached_chunks_cancels_the_job_and_keeps_the_cache(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch)
    jd = tmp_path / "job"
    prime = _run_child(tmp_path, book, jd, "prime")
    assert prime.wait(timeout=120) == 0
    cached = _cached_chunks()
    assert cached and jobs.read_state(jd)["state"] == "done"

    child = _run_child(tmp_path, book, jd, "slow-cache")  # rebuilds the chapters from the cache
    _wait_for_line(child, "reading")
    time.sleep(0.1)  # inside a cache read
    child.send_signal(signal.SIGTERM)
    assert child.wait(timeout=60) == 130
    assert jobs.read_state(jd)["state"] == "cancelled"
    assert _cached_chunks() == cached  # no valid chunk was deleted as "corrupt"


def test_sigterm_while_encoding_stops_ffmpeg_and_leaves_no_partial_file(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch)
    jd = tmp_path / "job"
    stall = tmp_path / "stalling_ffmpeg.py"
    stall.write_text(STALLING_FFMPEG.replace("{python}", sys.executable))
    stall.chmod(0o755)
    pid_file = tmp_path / "ffmpeg.pid"
    monkeypatch.setenv("STALL_PID_FILE", str(pid_file))
    child = _run_child(tmp_path, book, jd, "slow-encode", str(stall))
    _wait_for_line(child, "encoding")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and not (pid_file.exists() and pid_file.read_text().strip()):
        time.sleep(0.05)
    ffmpeg_pid = int(pid_file.read_text())
    try:
        child.send_signal(signal.SIGTERM)
        assert child.wait(timeout=60) == 130
        assert jobs.read_state(jd)["state"] == "cancelled"
        assert not jobs._alive(ffmpeg_pid)
        assert not list(tmp_path.glob("*.partial.m4b")) and not list(tmp_path.glob("*.m4b"))
    finally:
        if jobs._alive(ffmpeg_pid):
            os.kill(ffmpeg_pid, signal.SIGKILL)


# ----------------------------------------------------------------------------- detached mode / job folder

def test_failure_before_the_event_log_exists_is_recorded_in_the_job_folder(tmp_path, monkeypatch):
    book = tmp_path / "broken.epub"
    book.write_bytes(b"x")

    def broken(path):
        raise IngestError("This EPUB is damaged.")

    monkeypatch.setattr(pipeline, "read_book", broken)
    jd = tmp_path / "job"
    with pytest.raises(IngestError):
        pipeline.convert(book, opts(), lambda ev: None, jd)
    lines = [json.loads(x) for x in (jd / "events.jsonl").read_text().splitlines()]
    assert [e["event"] for e in lines] == ["run_start", "error"]
    assert "This EPUB is damaged." in lines[-1]["message"]
    st = jobs.status(jd)
    assert st["state"] == "failed" and "damaged" in st["error"] and "damaged" in st["last_error"]["message"]


def test_empty_section_selection_fails_in_the_child_with_a_record(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch, include=False)
    jd = tmp_path / "job"
    with pytest.raises(IngestError, match="No sections selected"):
        pipeline.convert(book, opts(), lambda ev: None, jd)
    assert jobs.status(jd)["state"] == "failed"


def test_detach_parent_rejects_what_the_child_would_reject(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch, include=False)  # nothing selected automatically
    spawned = []
    monkeypatch.setattr(jobs, "spawn_detached", lambda argv, jd: spawned.append(jd) or 4242)
    res = CliRunner().invoke(cli.app, ["convert", str(book), "--detach"])
    ev = json.loads(res.stdout.strip().splitlines()[-1])
    assert ev["event"] == "error" and "No sections selected" in ev["message"]
    assert res.exit_code == 1 and spawned == []


def test_detach_spawns_with_absolute_job_dir_and_without_parent_flags(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch)
    spawned = []
    monkeypatch.setattr(jobs, "spawn_detached", lambda argv, jd: spawned.append((argv, jd)) or 4242)
    monkeypatch.setattr(sys, "argv", ["audiobook-engine", "convert", str(book), "--detach", "--job-dir=rel"])
    monkeypatch.chdir(tmp_path)
    res = CliRunner().invoke(cli.app, ["convert", str(book), "--detach", "--job-dir", "rel"])
    ev = json.loads(res.stdout.strip().splitlines()[-1])
    assert ev["event"] == "detached" and ev["pid"] == 4242
    argv, jd = spawned[0]
    assert argv == ["convert", str(book)] and jd == tmp_path / "rel"


def test_option_errors_in_a_job_child_are_recorded_in_the_job_folder(tmp_path):
    jd = tmp_path / "job"
    res = CliRunner().invoke(cli.app, ["convert", str(tmp_path / "b.epub"), "--engine", "nope", "--job-dir", str(jd)])
    assert res.exit_code == 2
    assert json.loads(res.stdout.strip().splitlines()[-1])["event"] == "error"
    st = jobs.status(jd)
    assert st["state"] == "failed" and "Unknown engine" in st["last_error"]["message"]


def test_detached_child_that_fails_early_leaves_a_record_and_stderr(tmp_path):
    """Real detached child process (no model is loaded: it fails while reading the book)."""
    bad = tmp_path / "bad.epub"
    bad.write_bytes(b"this is not a zip archive")
    jd = paths.jobs_dir() / "deadbeef0000"
    pid = jobs.spawn_detached(["convert", str(bad)], jd)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and jobs.read_state(jd).get("state") != "failed":
        time.sleep(0.2)
    for _ in range(100):  # let it exit before reading stderr.log
        if not jobs._alive(pid):
            break
        time.sleep(0.1)
    st = jobs.status(jd)
    assert st["state"] == "failed", st
    assert st["last_error"] and st["last_error"]["event"] == "error"
    assert st.get("stderr_tail"), "the traceback should be in stderr.log"


def test_duplicate_launch_does_not_take_over_a_running_job(tmp_path, monkeypatch, engine):
    monkeypatch.setattr(jobs, "JOB_LOCK_WAIT_S", 0.1, raising=False)
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    with jobs.job_lock(jd):  # the first process, still running this job
        jobs.update_state(jd, job_id=jd.name, state="running", pid=4242)
        before = (jd / "job.json").read_text()
        with pytest.raises(jobs.JobBusy):
            run(book, o)
        assert (jd / "job.json").read_text() == before
        assert not (jd / "events.jsonl").exists()
        # The CLI parent reports the running job instead of spawning a second one.
        spawned = []
        monkeypatch.setattr(jobs, "spawn_detached", lambda argv, d: spawned.append(d) or 1)
        res = CliRunner().invoke(cli.app, ["convert", str(book), "--detach"])
        ev = json.loads(res.stdout.strip().splitlines()[-1])
        assert ev["event"] == "detached" and ev["already_running"] is True and ev["job_id"] == jd.name
        assert spawned == []
    assert engine.calls == []


def test_a_second_detach_while_the_first_child_is_still_starting_does_not_spawn_again(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch)
    # Stands in for a child that has not taken job.lock yet (interpreter start-up, reading the book).
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "audiobook_engine"])
    spawned = []
    monkeypatch.setattr(jobs, "spawn_detached", lambda argv, jd: spawned.append(jd) or child.pid)
    monkeypatch.setattr(sys, "argv", ["audiobook-engine", "convert", str(book), "--detach"])

    def detach() -> dict:
        res = CliRunner().invoke(cli.app, ["convert", str(book), "--detach"])
        return json.loads(res.stdout.strip().splitlines()[-1])

    try:
        first, second = detach(), detach()
        assert len(spawned) == 1 and first["pid"] == child.pid and "already_running" not in first
        assert second["already_running"] is True and second["pid"] == child.pid
        assert second["job_id"] == first["job_id"]
    finally:
        child.kill()
        child.wait()
    third = detach()  # that child is gone: a new launch starts a new one
    assert len(spawned) == 2 and "already_running" not in third


def test_a_duplicate_child_leaves_no_traceback_in_the_running_jobs_stderr(tmp_path, monkeypatch, engine):
    monkeypatch.setattr(jobs, "JOB_LOCK_WAIT_S", 0.1, raising=False)
    book = make_book(tmp_path, monkeypatch)
    jd = tmp_path / "job"
    with jobs.job_lock(jd):  # the job is running
        res = CliRunner().invoke(cli.app, ["convert", str(book), "--job-dir", str(jd)])
    ev = json.loads(res.stdout.strip().splitlines()[-1])
    assert res.exit_code == 1 and ev["event"] == "error" and "already running" in ev["message"]
    assert "Traceback" not in res.stderr


def test_resume_clears_the_previous_runs_error(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    jd.mkdir(parents=True)
    jobs.update_state(jd, job_id=jd.name, state="failed", error="RuntimeError: boom", output="/x.m4b",
                      finished="2026-01-01T00:00:00")
    (jd / "events.jsonl").write_text(json.dumps({"event": "job_start"}) + "\n" +
                                     json.dumps({"event": "error", "message": "RuntimeError: boom"}) + "\n")
    result, _ = run(book, o)
    state = json.loads((jd / "job.json").read_text())
    assert "error" not in state and state["output"] == result["output"] and state["state"] == "done"
    st = jobs.status(jd)
    assert st["last_error"] is None and st["result"]["output"] == result["output"]


# ----------------------------------------------------------------------------- relative paths

def test_relative_job_dir_converts(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    monkeypatch.chdir(tmp_path)
    result, events = run(Path(book.name), opts(), Path("myjob"))
    assert result["verification_problems"] == []
    assert first(events, "job_start")["job_dir"] == str(tmp_path / "myjob")
    assert Path(result["output"]).is_absolute()


# ----------------------------------------------------------------------------- output name

def test_a_different_job_never_overwrites_an_existing_audiobook(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    a, _ = run(book, opts())
    a_path = Path(a["output"])
    assert a_path.name == "Test Book - Jane Doe.m4b"
    a_digest = file_digest(a_path)

    b, _ = run(book, opts(voice=VoiceChoice("am_adam")))
    assert Path(b["output"]).name == "Test Book - Jane Doe (am_adam).m4b"
    assert file_digest(a_path) == a_digest  # the first audiobook is untouched

    c, _ = run(book, opts(speed=1.1))  # same voice as the first job, other settings
    d, _ = run(book, opts(speed=1.2))
    assert Path(c["output"]).name == "Test Book - Jane Doe (af_heart).m4b"
    assert Path(d["output"]).name == "Test Book - Jane Doe (af_heart) 2.m4b"

    again, _ = run(book, opts())  # the first job again: replaces its own file
    assert Path(again["output"]) == a_path
    assert len(list(tmp_path.glob("*.m4b"))) == 4


def test_output_name_never_replaces_unknown_files(tmp_path):
    user_file = tmp_path / "T - A.m4b"
    user_file.write_bytes(b"the user's own file, not an mp4")
    got = pipeline.output_path(tmp_path, "T", "A", "af_heart", "0123456789ab")
    assert got.name == "T - A (af_heart).m4b"
    # Recorded by this job (file made before the job mark existed) but unreadable: still not reused.
    assert pipeline.output_path(tmp_path, "T", "A", "af_heart", "0123456789ab", {str(user_file)}) == got


def test_output_name_reuses_unmarked_file_this_job_recorded(tmp_path):
    f = tmp_path / "000.flac"
    import soundfile as sf

    sf.write(str(f), speech(1.0, 1), SR, subtype="PCM_24")
    meta = tmp_path / "metadata.txt"
    m4b.write_metadata(meta, {"title": "T", "comment": "Narrated locally."}, [m4b.ChapterMark("One", 0, 1000)])
    old = tmp_path / "T - A.m4b"
    m4b.encode_m4b([f], meta, None, old, total_seconds=1.0, encoder=m4b.check_tools()["aac_encoder"])
    assert pipeline.output_path(tmp_path, "T", "A", "v", "0123456789ab", {str(old)}) == old
    assert pipeline.output_path(tmp_path, "T", "A", "v", "0123456789ab").name == "T - A (v).m4b"


# ----------------------------------------------------------------------------- flagged chunks

def test_flagged_chunks_survive_cancel_and_resume(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    jd = job_dir_for(book, o)
    short = "letter that had arrived"  # this chunk comes back far too short: flagged

    def audio(text):
        return speech(0.3, 7) if short in text else None

    def cancel_in_chapter_three(text):
        if "evening" in text:
            raise Cancelled()

    engine.audio = audio
    engine.hook = cancel_in_chapter_three
    with pytest.raises(Cancelled):
        run(book, o)
    engine.hook = None
    result, events = run(book, o)  # resume: chapter 1 is skipped, its chunk is cached
    assert any(e["event"] == "section_skip" for e in events)
    flagged = json.loads((jd / "flagged.json").read_text())
    assert result["flagged_chunks"] == 1 and short in flagged[0]["text"]
    assert any("too short" in i for i in flagged[0]["issues"])

    for m in (jd / "chapters").glob("*.manifest"):
        m.unlink()  # rebuild every chapter from cached chunks: the flag is still reported
    result, _ = run(book, o)
    assert result["flagged_chunks"] == 1


# ----------------------------------------------------------------------------- ETA / work left

def test_work_left_ignores_assembled_chapters_and_counts_repeated_text_once(tmp_path, monkeypatch, engine):
    repeated = ["The same short paragraph appears in two different chapters of this book."]
    book = make_book(tmp_path, monkeypatch, paragraphs=[repeated, repeated, PARAGRAPHS[2]])
    o = opts(keep_work=True)  # this test is about reusing assembled chapters
    prep = pipeline.prepare(book, o)
    distinct = {c.text: c.chars for p in prep.plans for c in p.chunks}
    save_rate("kokoro", "af_heart", 1000, 100.0, 60.0, "test")  # a known prior: 10 chars/s
    _, events = run(book, o)
    start = first(events, "job_start")
    tail = round(pipeline.TAIL_FRACTION * start["total_chars"] * 0.062)
    assert start["chars_to_synthesize"] == sum(distinct.values()) < start["total_chars"]
    assert [e for e in events if e["event"] == "progress"][-1]["eta_s"] == tail  # nothing left at the end

    # The user deletes the chunk cache: assembled chapters still need no synthesis.
    for f in (paths.home() / "cache" / "chunks").rglob("*.flac"):
        f.unlink()
    save_rate("kokoro", "af_heart", 1000, 100.0, 60.0, "test")
    engine.calls.clear()
    _, events = run(book, o)
    start = first(events, "job_start")
    assert start["chars_to_synthesize"] == 0 and start["cached_chars"] == start["total_chars"]
    assert start["est_wall_s"] == tail
    assert engine.calls == []


# ----------------------------------------------------------------------------- empty audio

def test_empty_audio_from_a_stochastic_engine_is_retried_on_the_next_run(tmp_path, monkeypatch, engine):
    engine.spec = dataclasses.replace(KOKORO, deterministic=False)
    book = make_book(tmp_path, monkeypatch)
    o = opts()
    target = "bakery opened its blue shutters"
    engine.audio = lambda text: np.zeros(0, np.float32) if target in text else None
    first_run, _ = run(book, o)
    assert first_run["flagged_chunks"] == 1

    engine.audio = None  # the engine now succeeds
    engine.calls.clear()
    second_run, _ = run(book, o)
    assert any(target in t for t in engine.calls)
    assert second_run["flagged_chunks"] == 0
    assert second_run["duration_s"] > first_run["duration_s"]


def test_empty_audio_from_a_deterministic_engine_is_not_retried_but_stays_reported(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts(keep_work=True)  # this test is about reusing assembled chapters
    target = "bakery opened its blue shutters"
    engine.audio = lambda text: np.zeros(0, np.float32) if target in text else None
    assert run(book, o)[0]["flagged_chunks"] == 1
    engine.calls.clear()
    again, events = run(book, o)
    assert engine.calls == [] and len([e for e in events if e["event"] == "section_skip"]) == 4
    assert again["flagged_chunks"] == 1


# ----------------------------------------------------------------------------- CLI input errors

@pytest.mark.parametrize("spec, words", [("abc", "Invalid --sections"), ("2-x", "Invalid --sections"),
                                         ("-3", "Invalid --sections"), ("5-3", "start is after the end")])
def test_bad_sections_print_a_json_error(tmp_path, spec, words):
    res = CliRunner().invoke(cli.app, ["convert", str(tmp_path / "b.epub"), "--sections", spec])
    ev = json.loads(res.stdout.strip().splitlines()[-1])
    assert ev["event"] == "error" and words in ev["message"]
    assert res.exit_code == 2


def test_sections_parsing_still_accepts_ranges():
    assert cli._parse_sections("2-4, 7") == [2, 3, 4, 7]
    assert cli._parse_sections(None) is None


def test_an_enormous_sections_range_is_rejected_before_it_is_expanded(tmp_path):
    t = time.monotonic()
    with pytest.raises(cli.OptionError, match="more than"):
        cli._parse_sections("0-999999999")
    with pytest.raises(cli.OptionError, match="more than"):
        cli._parse_sections("0-6000,0-6000")
    assert time.monotonic() - t < 1.0
    res = CliRunner().invoke(cli.app, ["convert", str(tmp_path / "b.epub"), "--sections", "0-999999999"])
    assert res.exit_code == 2 and json.loads(res.stdout.strip().splitlines()[-1])["event"] == "error"


def test_unknown_section_indexes_are_listed_briefly(tmp_path, monkeypatch):
    book = make_book(tmp_path, monkeypatch)
    with pytest.raises(IngestError) as err:
        pipeline.prepare(book, opts(sections=list(range(100, 5100))))
    assert "and 4990 more" in str(err.value) and len(str(err.value)) < 200


@pytest.mark.parametrize("argv, words", [
    (["convert", "b.epub", "--speed", "3"], "--speed"),     # out of range
    (["convert", "b.epub", "--bitrate", "abc"], "--bitrate"),  # not an integer
    (["convert"], "Missing argument"),
    (["no-such-command"], "No such command"),
    (["engines", "--bogus"], "--bogus"),
    (["benchmark", "--batch", "0"], "--batch"),
    ([], "No command given"),
])
def test_parameter_errors_print_a_json_error_on_stdout(capsys, argv, words):
    code = cli.run_cli(argv)
    out = capsys.readouterr().out.strip().splitlines()
    ev = json.loads(out[-1])
    assert ev["event"] == "error" and words in ev["message"]
    assert code == 2


def test_run_cli_returns_the_commands_exit_code_and_reports_crashes_as_json(capsys, monkeypatch):
    assert cli.run_cli(["benchmark", "--lang", "de"]) == 2  # no passage for this language: no model is loaded
    assert "No benchmark passage" in json.loads(capsys.readouterr().out.strip().splitlines()[-1])["message"]

    def broken():
        raise RuntimeError("unexpected")

    monkeypatch.setattr("audiobook_engine.perf.load_rates", broken)
    assert cli.run_cli(["engines"]) == 1
    ev = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert ev == {"event": "error", "message": "RuntimeError: unexpected"}


# ----------------------------------------------------------------------------- work files / disk

def test_chapter_files_are_removed_after_success_but_chunks_stay_cached(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    result, _ = run(book, opts())
    jd = job_dir_for(book, opts())
    assert result["freed_work_mb"] >= 0 and list((jd / "chapters").glob("*.flac")) == []
    assert list((paths.home() / "cache" / "chunks").rglob("*.flac"))
    engine.calls.clear()
    again, _ = run(book, opts())  # rebuilt from cached chunks, no synthesis
    assert engine.calls == [] and again["duration_s"] == result["duration_s"]


def test_keep_work_keeps_chapter_files(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    o = opts(keep_work=True)
    result, _ = run(book, o)
    assert "freed_work_mb" not in result and list((job_dir_for(book, o) / "chapters").glob("*.flac"))


def test_conversion_refuses_to_start_without_disk_space(tmp_path, monkeypatch, engine):
    import shutil
    from collections import namedtuple

    book = make_book(tmp_path, monkeypatch)
    usage = namedtuple("usage", "total used free")
    monkeypatch.setattr(shutil, "disk_usage", lambda p: usage(10**12, 10**12 - 10**8, 10**8))
    with pytest.raises(pipeline.InsufficientDisk, match="Not enough disk space"):
        run(book, opts())
    assert engine.calls == []


def test_an_output_folder_that_does_not_exist_yet_is_created(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    out_dir = tmp_path / "Audiobooks" / "New shelf" / "Jane Doe"  # neither it nor its parent exists
    result, _ = run(book, opts(out_dir=out_dir))
    assert Path(result["output"]).parent == out_dir and Path(result["output"]).exists()


def test_disk_check_adds_up_needs_on_the_same_disk(tmp_path, monkeypatch):
    import shutil
    from collections import namedtuple

    (tmp_path / "job").mkdir()
    (tmp_path / "out").mkdir()
    todo_s = total_s = 1000.0
    need_work = (todo_s + total_s) * pipeline.BYTES_PER_AUDIO_SECOND
    need_out = total_s * pipeline.M4B_BYTES_PER_SECOND * 1.1
    free = 1e9 + max(need_work, need_out) + 0.5 * min(need_work, need_out)  # each fits alone, not both
    usage = namedtuple("usage", "total used free")
    monkeypatch.setattr(shutil, "disk_usage", lambda p: usage(10**12, 10**12 - free, free))
    with pytest.raises(pipeline.InsufficientDisk):
        pipeline.check_disk_space(tmp_path / "job", tmp_path / "out", todo_s, total_s)
    pipeline.check_disk_space(tmp_path / "job", tmp_path / "out", todo_s, 0.0)  # fits


def test_a_damaged_cover_image_does_not_fail_the_conversion(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    pipeline.read_book(book).cover = Cover(b"this is not an image", "image/jpeg", "test")
    result, events = run(book, opts())
    assert result["verification_problems"] == [] and result["chapters"] == 4
    assert any(e["event"] == "notice" and "cover" in e["message"] for e in events)


def test_sample_reports_unknown_or_missing_sections_clearly(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    with pytest.raises(IngestError, match="Unknown section index"):
        pipeline.sample(book, opts(), 99, 10.0, tmp_path / "s.m4a", lambda ev: None)
    nothing = make_book(tmp_path, monkeypatch, include=False, name="other.epub")
    with pytest.raises(IngestError, match="No sections selected"):
        pipeline.sample(nothing, opts(), None, 10.0, tmp_path / "s.m4a", lambda ev: None)
    assert engine.calls == []


# ----------------------------------------------------------------------------- speech check (QA)

class FakeScore:
    def __init__(self, bad: bool, cer: float):
        self.bad, self.cer = bad, cer
        self.max_deletion_run, self.max_insertion_run = (6, 0) if bad else (0, 0)

    def to_json(self):
        return {"bad": self.bad, "cer": self.cer}


class FakeVerifier:
    """Marks audio as bad while `bad_texts` says so; counts calls."""

    model = "loaded"

    def __init__(self, bad_texts):
        self.bad_texts = bad_texts  # callable(text, attempt) -> bool
        self.attempts: dict[str, int] = {}
        self.checked: list[str] = []

    def _score(self, text):
        n = self.attempts.get(text, 0)
        self.attempts[text] = n + 1
        self.checked.append(text)
        bad = self.bad_texts(text, n)
        return FakeScore(bad, 0.5 if bad else 0.02)

    def check(self, text, audio, sr):
        return self._score(text)

    def check_many(self, texts, audios, sr):
        return [self._score(t) for t in texts]


def _with_verifier(monkeypatch, verifier):
    monkeypatch.setattr(pipeline, "_make_verifier", lambda opts, spec, lang, emit: verifier)


def test_speech_check_regenerates_a_bad_chunk_and_keeps_the_good_take(tmp_path, monkeypatch, engine):
    engine.spec = dataclasses.replace(KOKORO, deterministic=False)
    target = "bakery opened its blue shutters"
    v = FakeVerifier(lambda text, n: target in text and n == 0)  # bad first, fine on retry
    _with_verifier(monkeypatch, v)
    book = make_book(tmp_path, monkeypatch)
    result, events = run(book, opts(verify=True))
    redo = [e for e in events if e["event"] == "qa_redo"]
    assert len(redo) == 1 and redo[0]["fixed"] is True
    assert result["qa"]["redone"] == 1 and result["qa"]["flagged"] == 0 and result["flagged_chunks"] == 0
    assert sum(1 for c in engine.calls if target in c) == 2  # original + one alternative


def test_speech_check_flags_a_chunk_that_never_matches(tmp_path, monkeypatch, engine):
    engine.spec = dataclasses.replace(KOKORO, deterministic=False)
    target = "bakery opened its blue shutters"
    _with_verifier(monkeypatch, FakeVerifier(lambda text, n: target in text))
    book = make_book(tmp_path, monkeypatch)
    result, events = run(book, opts(verify=True))
    assert result["qa"]["flagged"] == 1 and result["flagged_chunks"] == 1
    assert any("speech check" in i for i in json.loads((job_dir_for(book, opts(verify=True)) / "flagged.json").read_text())[0]["issues"])


def test_cached_chunks_are_checked_when_checks_are_turned_on_later(tmp_path, monkeypatch, engine):
    book = make_book(tmp_path, monkeypatch)
    run(book, opts())  # no speech check: chunks cached without a QA record
    v = FakeVerifier(lambda text, n: False)
    _with_verifier(monkeypatch, v)
    engine.calls.clear()
    result, _ = run(book, opts(verify=True))
    assert engine.calls == [] and result["qa"]["checked"] == len(set(v.checked)) > 0
    v.checked.clear()
    run(book, opts(verify=True))  # already checked: not checked again
    assert v.checked == []


def test_a_take_chosen_by_the_speech_check_is_judged_on_its_own_audio(tmp_path, monkeypatch, engine):
    """The first takes are too short (flagged); the speech check's new take is fine: nothing stays flagged."""
    engine.spec = dataclasses.replace(KOKORO, deterministic=False)
    target = "bakery opened its blue shutters"
    takes = []

    def audio(text):
        if target in text:
            takes.append(text)
            if len(takes) <= 3:  # the original and both repair attempts
                return speech(0.3, len(takes))
        return None

    engine.audio = audio
    _with_verifier(monkeypatch, FakeVerifier(lambda text, n: target in text and n == 0))
    book = make_book(tmp_path, monkeypatch)
    result, events = run(book, opts(verify=True))
    assert len(takes) == 4 and [e["fixed"] for e in events if e["event"] == "qa_redo"] == [True]
    assert result["flagged_chunks"] == 0 and result["qa"]["flagged"] == 0


class _PlaceholderRateEngine(FakeEngine):
    """Like the real engines: a placeholder sample rate until the model is loaded."""

    def __init__(self):
        super().__init__()
        self.loaded = False

    @property
    def sample_rate(self):
        return SR if self.loaded else 44100

    def load(self, voice=None) -> float:
        self.loaded = True
        return 0.0


def test_checking_cached_chunks_uses_their_sample_rate_and_does_not_rewrite_them(tmp_path, monkeypatch, engine):
    import soundfile as sf

    book = make_book(tmp_path, monkeypatch)
    run(book, opts())  # cached without a speech check
    files = sorted((paths.home() / "cache" / "chunks").rglob("*.flac"))
    before = {f: (f.stat().st_ino, f.stat().st_mtime_ns) for f in files}

    fresh = _PlaceholderRateEngine()  # a new process: the engine is not loaded
    monkeypatch.setattr(pipeline, "get_engine", lambda engine_id: fresh)
    rates = []

    class RecordingVerifier(FakeVerifier):
        def check_many(self, texts, audios, sr):
            rates.append(sr)
            return super().check_many(texts, audios, sr)

    _with_verifier(monkeypatch, RecordingVerifier(lambda text, n: False))
    result, _ = run(book, opts(verify=True))
    assert result["qa"]["checked"] > 0 and fresh.calls == [] and not fresh.loaded
    assert set(rates) == {SR}
    assert {f: (f.stat().st_ino, f.stat().st_mtime_ns) for f in files} == before  # not rewritten
    assert {sf.info(str(f)).samplerate for f in files} == {SR}


# ----------------------------------------------------------------------------- default voice

class _LanguageCheckingEngine(FakeEngine):
    """Like the real Kokoro adapter, refuses a voice made for another language (warm-up included)."""

    def __init__(self):
        super().__init__()
        self.voices: set[str] = set()

    def synthesize(self, texts, voice, lang, speed=1.0, seed=None):
        kokoro_mod._pipeline_code(voice.preset, lang)
        self.voices.add(voice.preset)
        return super().synthesize(texts, voice, lang, speed, seed)


def _french_book(tmp_path, monkeypatch) -> Path:
    book = make_book(tmp_path, monkeypatch)
    pipeline.read_book(book).language = "fr"
    return book


def test_without_a_voice_a_french_book_is_read_with_the_engines_french_preset(tmp_path, monkeypatch):
    eng = _LanguageCheckingEngine()
    monkeypatch.setattr(pipeline, "get_engine", lambda engine_id: eng)
    book = _french_book(tmp_path, monkeypatch)
    result, events = run(book, opts())
    assert first(events, "job_start")["voice"] == "ff_siwis" and eng.voices == {"ff_siwis"}
    assert jobs.read_state(job_dir_for(book, opts()))["voice"] == "ff_siwis"
    assert result["verification_problems"] == []
    sampled = pipeline.sample(book, opts(), None, 5.0, tmp_path / "s.wav", lambda ev: None)
    assert Path(sampled["output"]).exists()


def test_cli_convert_and_benchmark_without_a_voice_use_a_preset_for_the_language(tmp_path, monkeypatch):
    eng = _LanguageCheckingEngine()
    monkeypatch.setattr(pipeline, "get_engine", lambda engine_id: eng)
    book = _french_book(tmp_path, monkeypatch)
    jd = tmp_path / "job"
    res = CliRunner().invoke(cli.app, ["convert", str(book), "--job-dir", str(jd)])  # no flags at all
    assert res.exit_code == 0, res.stdout
    assert jobs.read_state(jd)["state"] == "done" and jobs.read_state(jd)["voice"] == "ff_siwis"

    benchmarked = []
    monkeypatch.setattr("audiobook_engine.benchmark.run",
                        lambda engine, voice, lang, *args: benchmarked.append((voice.preset, lang)))
    assert cli.run_cli(["benchmark", "--lang", "fr"]) == 0
    assert cli.run_cli(["benchmark"]) == 0
    assert cli.run_cli(["benchmark", "--lang", "fr", "--voice", "af_bella"]) == 0  # a chosen voice is kept
    assert benchmarked == [("ff_siwis", "fr"), ("af_heart", "en"), ("af_bella", "fr")]


@pytest.mark.parametrize("engine_id, lang, voice", [
    ("kokoro", "en", "af_heart"), ("kokoro", "fr", "ff_siwis"),
    ("voxtral", "en", "neutral_female"), ("voxtral", "fr", "fr_female"), ("qwen3", "en", "ryan"),
])
def test_the_default_voice_is_the_engines_first_preset_for_the_language(engine_id, lang, voice):
    assert pipeline.resolve_voice(ConvertOptions(engine=engine_id), lang) == VoiceChoice(voice)
    chosen = VoiceChoice("my_choice")
    assert pipeline.resolve_voice(ConvertOptions(engine=engine_id, voice=chosen), lang) is chosen


def test_without_a_voice_an_engine_with_no_preset_for_the_language_is_a_clear_error(tmp_path, monkeypatch, engine):
    book = _french_book(tmp_path, monkeypatch)
    with pytest.raises(EngineError, match=r"no French preset voice\. Choose a voice with --voice \(ryan, .*\) "
                                          r"or clone a French voice with --ref-voice or --ref"):
        pipeline.prepare(book, ConvertOptions(engine="qwen3", verify=False))
    assert pipeline.prepare(book, ConvertOptions(engine="qwen3", voice=VoiceChoice("ryan"))).opts.voice.preset == "ryan"
    assert engine.calls == []


def test_missing_ffmpeg_fails_before_any_narration(tmp_path, monkeypatch, engine):
    from audiobook_engine.audio import m4b

    book = make_book(tmp_path, monkeypatch)
    monkeypatch.setattr(m4b, "FFMPEG", str(tmp_path / "no-ffmpeg"))
    with pytest.raises(m4b.FFmpegError, match="brew install ffmpeg"):
        run(book, opts())
    assert engine.calls == []  # no GPU time wasted
