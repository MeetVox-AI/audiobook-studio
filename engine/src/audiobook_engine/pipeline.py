"""Book → M4B conversion pipeline (and short samples).

One process owns the GPU. Chunks are synthesised in reading order; each
finished chapter is stitched and loudness-normalised on a background thread
(ffmpeg subprocesses) while the GPU moves on. Every chunk is cached on disk,
so cancelling, crashing or re-running only redoes what is missing.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable

import numpy as np
import soundfile as sf

from . import jobs, paths
from .audio import loudness, m4b
from .audio.stitch import Pacing, assemble
from . import languages
from .audio.validate import check_chunk, seconds_per_char
from .cache import ChunkCache, chunk_key
from .ingest import read_book
from .models import Book, IngestError
from .perf import RateTracker, save_rate, saved_rate
from .textproc.normalize import NORMALIZER_VERSION, Rules, normalize_paragraph, normalize_section
from .textproc.segment import Chunk, chunk_section, split_sentences
from .tts import EngineError, VoiceChoice, default_preset, get_engine, specs

Emit = Callable[[dict], None]

# Bump when stitching/loudness changes so previously assembled chapters are rebuilt.
ASSEMBLY_VERSION = "3"
# Final assembly + encode after the last chunk, as a fraction of audio length
# (measured: 55 s for a 6.6 h book on an M4 Pro = 0.0023).
TAIL_FRACTION = 0.0025


class Cancelled(BaseException):
    """Raised by the SIGTERM handler ('jobs cancel').

    A BaseException, like KeyboardInterrupt: the handler can fire inside any code,
    and library code that catches Exception (cache reads, model loading hooks)
    must not swallow a cancel.
    """


JobBusy = jobs.JobBusy


@dataclass
class ConvertOptions:
    engine: str = "kokoro"
    voice: VoiceChoice | None = None         # None = the engine's first preset for the book language (resolve_voice)
    lang: str | None = None
    speed: float = 1.0
    sections: list[int] | None = None       # None = the automatically included ones
    out_dir: Path | None = None
    bitrate_k: int = 64
    pacing: Pacing = field(default_factory=Pacing)
    intro: bool = True
    rules: Rules | None = None
    keep_work: bool = False               # keep chapter FLACs in the job folder after success
    verify: bool | None = None            # speech check with Whisper; None = on for sampling engines


@dataclass
class SectionPlan:
    index: int          # book section index, or -1 for the spoken intro
    title: str
    chunks: list[Chunk]

    @property
    def chars(self) -> int:
        return sum(c.chars for c in self.chunks)


# ----------------------------------------------------------------------------- planning

def _warmup_sentence(lang: str) -> str:
    try:
        return languages.get(lang).warmup or languages.get("en").warmup
    except KeyError:
        return languages.get("en").warmup


def resolve_lang(book: Book, opts: ConvertOptions) -> str:
    lang = opts.lang or book.language
    lang = languages.normalize_code(lang) or lang  # "pt-BR" -> "pt"; unknown codes fall through to the error below
    spec = specs()[opts.engine]
    if lang not in spec.languages:
        raise EngineError(f"{spec.name} does not support language '{lang}'. Supported: {', '.join(spec.languages)}.")
    return lang


def resolve_voice(opts: ConvertOptions, lang: str) -> VoiceChoice:
    """The chosen voice; with none chosen, the engine's first preset made for `lang`.

    The default is picked only once the language is known: a fixed default would give a
    French book an English voice (and Kokoro refuses that pair).
    """
    if opts.voice is not None:
        return opts.voice
    return VoiceChoice(default_preset(specs()[opts.engine], lang))


def select_sections(book: Book, wanted: list[int] | None) -> list[int]:
    if wanted is None:
        return [s.index for s in book.sections if s.include]
    valid = {s.index for s in book.sections}
    bad = list(dict.fromkeys(i for i in wanted if i not in valid))
    if bad:
        shown = ", ".join(map(str, bad[:10])) + (f" and {len(bad) - 10} more" if len(bad) > 10 else "")
        raise IngestError(f"Unknown section index: {shown}. Use 'inspect' to list sections.")
    return list(dict.fromkeys(wanted))


def intro_text(book: Book, lang: str) -> str:
    if book.author and book.author != "Unknown":
        return languages.announce(lang, book.title, book.author)
    return f"{book.title}."


def plan_book(book: Book, opts: ConvertOptions, lang: str, sections: list[int]) -> list[SectionPlan]:
    spec = specs()[opts.engine]
    cap = spec.cap_for(lang)
    plans: list[SectionPlan] = []
    if opts.intro:
        text = normalize_paragraph(intro_text(book, lang), lang, opts.rules)
        plans.append(SectionPlan(-1, languages.get(lang).credits,
                                 chunk_section(-1, [text], cap, first_is_heading=True, min_chars=spec.min_chunk, lang=lang)))
    by_index = {s.index: s for s in book.sections}
    for i in sections:
        s = by_index[i]
        paras = normalize_section(s.paragraphs, lang, s.starts_with_heading, s.title, opts.rules)
        chunks = chunk_section(i, paras, cap, first_is_heading=True, min_chars=spec.min_chunk, lang=lang)
        if chunks:
            plans.append(SectionPlan(i, s.title, chunks))
    return plans


@dataclass
class Prepared:
    book: Book
    lang: str
    sections: list[int]
    plans: list[SectionPlan]
    job_id: str
    opts: ConvertOptions  # the options with the voice resolved (resolve_voice)


def prepare(book_path: Path, opts: ConvertOptions) -> Prepared:
    """Read, validate and plan a conversion. Raises for anything that would stop it from starting.

    `convert --detach` runs this in the parent too, so an invalid request is reported
    on stdout instead of dying in a detached child.
    """
    m4b.check_tools()  # before any narration: a missing ffmpeg must not surface hours later
    book_path = Path(book_path)
    book = read_book(book_path)
    lang = resolve_lang(book, opts)
    opts = replace(opts, voice=resolve_voice(opts, lang))
    sections = select_sections(book, opts.sections)
    if not sections:
        raise IngestError("No sections selected. Choose some with --sections (see 'inspect').")
    plans = plan_book(book, opts, lang, sections)
    if not plans:
        raise IngestError("The selected sections contain no text to narrate.")
    return Prepared(book, lang, sections, plans, job_id_for(book_path, opts, lang, sections), opts)


def job_id_for(book_path: Path, opts: ConvertOptions, lang: str, sections: list[int]) -> str:
    st = book_path.stat()
    raw = json.dumps([str(book_path.resolve()), st.st_size, int(st.st_mtime), opts.engine, opts.voice.fingerprint(),
                      opts.speed, lang, sections, opts.pacing.to_json(), NORMALIZER_VERSION, opts.intro,
                      opts.rules.fingerprint() if opts.rules else ""], sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:12]


def display_title(title: str) -> str:
    """'CHAPTER II.' → 'Chapter II.' (Roman numerals stay upper case); mixed case is left alone."""
    letters = [c for c in title if c.isalpha()]
    if not letters or sum(c.isupper() for c in letters) / len(letters) < 0.8:
        return title.strip()
    words = []
    for w in title.split():
        core = w.strip(".,:;!?()[]«»\"'")
        if core and all(c in "IVXLCDM" for c in core):
            words.append(w)
        else:
            words.append(w[:1].upper() + w[1:].lower())
    return " ".join(words)


def _safe_name(text: str) -> str:
    text = re.sub(r"[/\\:*?\"<>|\x00-\x1f]", " ", text)
    return re.sub(r"\s+", " ", text).strip()[:120] or "Audiobook"


# Written into the M4B comment so a later job can tell its own file from another job's.
_JOB_MARK = re.compile(r"audiobook-engine job ([0-9a-f]+)")


def _job_comment(spec_name: str, license_: str, job_id: str) -> str:
    return f"Narrated locally by {spec_name} ({license_}). [audiobook-engine job {job_id}]"


def _output_owner(path: Path) -> str | None:
    """Job id recorded in an existing M4B: '' when it has none, None when it cannot be read."""
    try:
        tags = m4b.probe(path).get("format", {}).get("tags", {})
    except (m4b.FFmpegError, OSError, ValueError):
        return None
    found = _JOB_MARK.search(str({k.lower(): v for k, v in tags.items()}.get("comment", "")))
    return found.group(1) if found else ""


def output_path(out_dir: Path, title: str, author: str, voice_label: str, job_id: str,
                owned: set[str] | frozenset[str] = frozenset()) -> Path:
    """'Title - Author.m4b', unless that file belongs to another job (or to the user).

    Then 'Title - Author (voice).m4b', then 'Title - Author (voice) 2.m4b', ... An
    existing file is replaced only when it was made by this same job: its comment
    names this job id, or (files made before the mark existed) this job recorded it.
    """
    base = f"{_safe_name(title)} - {_safe_name(author)}"

    def usable(p: Path) -> bool:
        if not p.exists():
            return True
        owner = _output_owner(p)
        if owner:
            return owner == job_id
        return owner == "" and str(p) in owned

    first = out_dir / f"{base}.m4b"
    if usable(first):
        return first
    label = f" ({_safe_name(voice_label)})"
    base = base[:max(40, 200 - len(label))].rstrip()  # stay well under the 255-byte file name limit
    n = 1
    while True:
        cand = out_dir / f"{base}{label}{'' if n == 1 else f' {n}'}.m4b"
        if usable(cand):
            return cand
        n += 1


# ----------------------------------------------------------------------------- machine care

def keep_awake() -> subprocess.Popen | None:
    """Prevent idle sleep for as long as this process lives (macOS caffeinate)."""
    if sys.platform != "darwin":
        return None
    try:
        return subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return None


def power_source() -> str | None:
    if sys.platform != "darwin":
        return None
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return None
    if "Battery Power" in out:
        return "battery"
    if "AC Power" in out:
        return "ac"
    return None


# ----------------------------------------------------------------------------- synthesis core

class Synthesizer:
    """Wraps an engine with caching, validation and repair."""

    def __init__(self, engine_id: str, voice: VoiceChoice, lang: str, speed: float, emit: Emit, verifier=None):
        self.verifier = verifier  # qa.verify.Verifier-like: check(text, audio, sr), check_many(texts, audios, sr)
        self.qa_stats = {"checked": 0, "redone": 0, "flagged": 0}
        self.engine = get_engine(engine_id)
        self.spec = self.engine.spec
        self.voice = voice
        self.voice_fp = voice.fingerprint()
        self.lang = lang
        self.speed = speed
        self.native_speed = speed if self.spec.supports_speed else 1.0
        self.emit = emit
        self.cache = ChunkCache(paths.home() / "cache" / "chunks")
        self.loaded = False
        self.sample_rate = self.engine.sample_rate

    def key(self, text: str) -> str:
        return chunk_key(text, self.lang, self.engine.settings_fingerprint(), self.voice_fp, self.native_speed, None)

    def ensure_loaded(self) -> None:
        if self.loaded:
            return
        self.emit({"event": "model_loading", "engine": self.spec.id, "checkpoint": self.spec.checkpoint})
        load_s = self.engine.load(self.voice)
        t = time.perf_counter()
        self.engine.synthesize([_warmup_sentence(self.lang)],
                               self.voice, self.lang, self.native_speed)
        self.sample_rate = self.engine.sample_rate
        self.loaded = True
        self.emit({"event": "model_loaded", "load_s": round(load_s, 2), "warmup_s": round(time.perf_counter() - t, 2),
                   "sample_rate": self.sample_rate})
        self._load_verifier()

    def _load_verifier(self) -> None:
        if self.verifier is not None and getattr(self.verifier, "model", "loaded") is None:
            t = time.perf_counter()
            self.verifier.load()
            self.emit({"event": "qa_model_loaded", "load_s": round(time.perf_counter() - t, 2)})

    def cached(self, chunk: Chunk) -> np.ndarray | None:
        got = self.cache.get(self.key(chunk.text))
        if got is None:
            return None
        audio, sr = got
        self.sample_rate = sr
        return audio

    def synthesize(self, chunks: list[Chunk]) -> tuple[list[np.ndarray], list[list[str]]]:
        """Synthesise uncached chunks; returns audio and remaining issues per chunk."""
        self.ensure_loaded()
        audios = self.engine.synthesize([c.text for c in chunks], self.voice, self.lang, self.native_speed)
        issues_all = []
        for i, (c, a) in enumerate(zip(chunks, audios)):
            issues = check_chunk(a, self.engine.sample_rate, c.chars, self.native_speed, lang=self.lang)
            if issues:
                fixed, issues = self._repair(c, a, issues)
                audios[i] = fixed
            issues_all.append(issues)
        qa = self._speech_check(chunks, audios, issues_all, self.engine.sample_rate)
        for i, c in enumerate(chunks):
            self._store(c, audios[i], issues_all[i], qa[i])
        return audios, issues_all

    def verify_cached(self, chunks: list[Chunk], audios: list[np.ndarray]) -> tuple[list[np.ndarray], list[list[str]]]:
        """Speech-check cached chunks that were never checked (e.g. cached before checks were on).

        `audios` come from the cache (at self.sample_rate, set by cached()); the engine may not
        be loaded. Only chunks replaced by a better take are written again.
        """
        issues_all = [self.cache.issues(self.key(c.text)) for c in chunks]
        if self.verifier is None or not chunks:
            return audios, issues_all
        self._load_verifier()
        original = list(audios)
        audios = list(audios)
        qa = self._speech_check(chunks, audios, issues_all, self.sample_rate)
        for i, c in enumerate(chunks):
            if audios[i] is original[i]:
                k = self.key(c.text)
                self.cache.put_issues(k, issues_all[i])
                if qa[i] is not None:
                    self.cache.put_qa(k, qa[i])
            else:
                self._store(c, audios[i], issues_all[i], qa[i])
        return audios, issues_all

    def needs_check(self, chunk: Chunk) -> bool:
        return self.verifier is not None and self.cache.qa(self.key(chunk.text)) is None

    def _store(self, c: Chunk, audio: np.ndarray, issues: list[str], qa: dict | None) -> None:
        k = self.key(c.text)
        if audio.size:
            self.cache.put(k, audio, self.engine.sample_rate, issues)
        else:
            self.cache.put_issues(k, issues)  # keeps the flag for the report
        if qa is not None:
            self.cache.put_qa(k, qa)

    def _speech_check(self, chunks: list[Chunk], audios: list[np.ndarray], issues_all: list[list[str]],
                      sr: int) -> list[dict | None]:
        """Whisper check; regenerate chunks whose speech does not match the text. Mutates audios/issues.

        `sr` is the sample rate of `audios`; alternatives come from the engine at its own rate.
        """
        if self.verifier is None:
            return [None] * len(chunks)
        scores = self.verifier.check_many([c.text for c in chunks], audios, sr)
        out: list[dict | None] = []
        for i, (c, sc) in enumerate(zip(chunks, scores)):
            self.qa_stats["checked"] += 1
            best_audio, best = audios[i], sc
            if sc.bad and _speakable(c.text):
                self.qa_stats["redone"] += 1
                for cand in self._alternatives(c):
                    if not cand.size:
                        continue
                    cs = self.verifier.check(c.text, cand, self.engine.sample_rate)
                    if (cs.bad, cs.cer) < (best.bad, best.cer):
                        best_audio, best = cand, cs
                    if not cs.bad:
                        break
                self.emit({"event": "qa_redo", "section": c.section, "chunk": c.index, "before_cer": round(sc.cer, 3),
                           "after_cer": round(best.cer, 3), "fixed": not best.bad})
                if best_audio is not audios[i]:
                    # The issues found earlier belong to the take that was just replaced.
                    issues_all[i] = check_chunk(best_audio, self.engine.sample_rate, c.chars, self.native_speed, lang=self.lang)
            audios[i] = best_audio
            if best.bad and _speakable(c.text):
                self.qa_stats["flagged"] += 1
                issues_all[i] = [*issues_all[i], _describe_speech(best)]
            out.append(best.to_json())
        return out

    def _alternatives(self, chunk: Chunk):
        """Different attempts at a chunk: new random seeds, or sentence-by-sentence for deterministic engines."""
        self.ensure_loaded()
        sr = self.engine.sample_rate
        if self.spec.deterministic:
            parts = split_sentences(chunk.text, self.lang)
            if len(parts) > 1:
                pieces = self.engine.synthesize(parts, self.voice, self.lang, self.native_speed)
                gap = np.zeros(int(0.2 * sr), dtype=np.float32)
                yield np.concatenate([x for p in pieces for x in (p, gap)][:-1])
            return
        for seed in (11, 23):
            yield self.engine.synthesize([chunk.text], self.voice, self.lang, self.native_speed, seed=seed)[0]

    def _repair(self, chunk: Chunk, audio: np.ndarray, issues: list[str]) -> tuple[np.ndarray, list[str]]:
        sr = self.engine.sample_rate
        attempts: list[tuple[np.ndarray, list[str]]] = [(audio, issues)]
        if self.spec.deterministic:
            # Same input gives the same output: change the input by synthesising sentence by sentence.
            parts = split_sentences(chunk.text, self.lang)
            if len(parts) > 1:
                pieces = self.engine.synthesize(parts, self.voice, self.lang, self.native_speed)
                gap = np.zeros(int(0.2 * sr), dtype=np.float32)
                joined = np.concatenate([x for p in pieces for x in (p, gap)][:-1]) if pieces else audio
                attempts.append((joined, check_chunk(joined, sr, chunk.chars, self.native_speed, lang=self.lang)))
        else:
            for seed in (1, 2):
                a = self.engine.synthesize([chunk.text], self.voice, self.lang, self.native_speed, seed=seed)[0]
                attempts.append((a, check_chunk(a, sr, chunk.chars, self.native_speed, lang=self.lang)))
                if not attempts[-1][1]:
                    break
        best = min(attempts, key=lambda x: (len(x[1]), 0 if x[0].size else 1))
        return best


# ----------------------------------------------------------------------------- convert

class _Emitter:
    def __init__(self, sink: Emit, log_path: Path | None):
        self.sink = sink
        self.lock = threading.Lock()
        self.log = open(log_path, "a", encoding="utf-8") if log_path else None
        self.t0 = time.monotonic()

    def __call__(self, ev: dict) -> None:
        ev = {"t": round(time.monotonic() - self.t0, 2), **ev}
        with self.lock:
            if self.log:
                self.log.write(json.dumps(ev, ensure_ascii=False) + "\n")
                self.log.flush()
            self.sink(ev)

    def close(self):
        if self.log:
            self.log.close()


# A SIGTERM this long after the last Cancelled is acted on again: by then that Cancelled was lost
# (Python only prints an exception raised inside a finalizer or weakref callback) or the stop is stuck.
CANCEL_REARM_S = 10.0


class _CancelState:
    def __init__(self):
        self.stopping = False   # Cancelled was raised: SIGTERMs in the next CANCEL_REARM_S change nothing
        self.stopped_at = 0.0   # time.monotonic() of the last Cancelled raised
        self.deferred = 0       # inside _cancel_deferred(): remember a SIGTERM, raise at the end
        self.pending = False

    def cancel(self) -> Cancelled:
        self.stopping = True
        self.stopped_at = time.monotonic()
        return Cancelled()


_cancel_state: _CancelState | None = None


@contextmanager
def _sigterm_cancels():
    """While active, SIGTERM ('jobs cancel') raises Cancelled in the main thread.

    Once: a repeated SIGTERM (the app cancelling again because the first stop takes a
    while) must not interrupt the clean-up of the first one, e.g. waiting for chapter
    assemblies before the job and GPU locks are released. Only a SIGTERM that comes
    CANCEL_REARM_S after the last Cancelled counts again, so a lost Cancelled does not
    leave the job impossible to stop.
    """
    global _cancel_state
    state = _CancelState()

    def handler(signum, frame):
        if state.stopping and time.monotonic() - state.stopped_at < CANCEL_REARM_S:
            return
        if state.deferred:
            state.pending = True
            return
        raise state.cancel()

    try:
        previous = signal.signal(signal.SIGTERM, handler)
    except ValueError:
        yield  # not in the main thread (tests)
        return
    outer, _cancel_state = _cancel_state, state
    try:
        yield
    finally:
        _cancel_state = outer
        signal.signal(signal.SIGTERM, previous)


@contextmanager
def _cancel_deferred():
    """A SIGTERM during this block is acted on when the block ends, not inside it."""
    state = _cancel_state
    if state is None:
        yield
        return
    state.deferred += 1
    try:
        yield
    finally:
        state.deferred -= 1
    # Reached only when the block itself succeeded.
    if not state.deferred and state.pending:
        state.pending = False
        cancel = state.cancel()
        # The block may be the clean-up of a run that already failed (a 'finally'): keep that
        # error, so the cancel does not hide why the run stopped.
        cancel.failure = sys.exc_info()[1]
        raise cancel


def _describe(exc: BaseException) -> str:
    if isinstance(exc, Cancelled):
        return "Cancelled"
    return f"{type(exc).__name__}: {exc}"


def _failure_state(exc: BaseException) -> str:
    return "cancelled" if isinstance(exc, Cancelled) else "failed"


def convert(book_path: Path, opts: ConvertOptions, sink: Emit, job_dir: Path | None = None) -> dict:
    book_path = Path(book_path)
    explicit_dir = Path(job_dir).expanduser().absolute() if job_dir else None
    with _sigterm_cancels():
        try:
            prep = prepare(book_path, opts)
        except BaseException as exc:
            # A detached child's stdout goes nowhere: the job folder is the only place to report.
            if explicit_dir is not None:
                jobs.record_failure(explicit_dir, _describe(exc), state=_failure_state(exc), book=str(book_path))
            raise
        job_dir = explicit_dir or paths.jobs_dir() / prep.job_id
        # One process per job: a duplicate launch must not take over job.json (pid, state).
        with jobs.job_lock(job_dir):
            return _run_job(prep, book_path, prep.opts, sink, job_dir)


def _run_job(prep: Prepared, book_path: Path, opts: ConvertOptions, sink: Emit, job_dir: Path) -> dict:
    book = prep.book
    try:
        (job_dir / "chapters").mkdir(parents=True, exist_ok=True)
        emit = _Emitter(sink, job_dir / "events.jsonl")
    except BaseException as exc:
        jobs.record_failure(job_dir, _describe(exc), state=_failure_state(exc), lock_held=True,
                            job_id=prep.job_id, book=str(book_path))
        raise
    caffeinate = None
    try:
        emit({"event": jobs.RUN_START, "job_id": prep.job_id, "pid": os.getpid()})
        previous = jobs.read_state(job_dir)
        prev_outputs = previous.get("outputs")
        owned = {str(o) for o in (prev_outputs if isinstance(prev_outputs, list) else []) if o}
        if previous.get("output"):
            owned.add(str(previous["output"]))
        # error/output/finished describe one run: a resumed run starts without them. The files
        # this job made stay its own ('outputs'), even if this run is cancelled or fails.
        jobs.update_state(job_dir, clear=("error", "output", "finished"), outputs=sorted(owned),
                          job_id=prep.job_id, book=str(book_path),
                          title=book.title, author=book.author, lang=prep.lang, engine=opts.engine,
                          voice=opts.voice.label(), speed=opts.speed, state="queued", pid=os.getpid(),
                          started=time.strftime("%Y-%m-%dT%H:%M:%S"), argv=sys.argv[1:])
        caffeinate = keep_awake()
        with jobs.gpu_lock(on_wait=lambda: emit({"event": "queued", "message": "Another job is using the GPU; waiting."})):
            jobs.update_state(job_dir, state="running")
            result = _convert(book, book_path, opts, prep.plans, prep.lang, prep.job_id, job_dir, emit, owned)
        jobs.update_state(job_dir, state="done" if not result["verification_problems"] else "done_with_problems",
                          output=result["output"], outputs=sorted(owned | {result["output"]}),
                          finished=time.strftime("%Y-%m-%dT%H:%M:%S"))
        return result
    except Cancelled as exc:
        failure = getattr(exc, "failure", None)
        if isinstance(failure, Exception):
            # The run had already failed; the cancel came while it waited for chapter assemblies.
            error = _describe(failure)
            jobs.update_state(job_dir, state="cancelled", error=error)
            emit({"event": "cancelled", "error": error,
                  "message": f"Stopped after an error: {error}. Finished chunks are cached; run again to resume."})
        else:
            jobs.update_state(job_dir, state="cancelled")
            emit({"event": "cancelled", "message": "Stopped. Finished chunks are cached; run again to resume."})
        raise
    except BaseException as exc:
        jobs.update_state(job_dir, state="failed", error=_describe(exc))
        emit({"event": "error", "message": _describe(exc)})
        raise
    finally:
        emit.close()
        if caffeinate:
            caffeinate.terminate()


def _chapter_manifest(plan: SectionPlan, keys: dict, opts: ConvertOptions, tempo: float) -> str:
    return hashlib.sha256(json.dumps([keys[(plan.index, c.index)] for c in plan.chunks] +
                                     [opts.pacing.to_json(), tempo, ASSEMBLY_VERSION]).encode()).hexdigest()


def _assembled_seconds(chapter_path: Path, manifest_path: Path, manifest: str) -> float | None:
    """Duration of a chapter already assembled from exactly these chunks and settings, else None."""
    if not (chapter_path.exists() and manifest_path.exists()):
        return None
    try:
        if manifest_path.read_text() != manifest:
            return None
        return sf.info(str(chapter_path)).duration
    except (sf.SoundFileError, RuntimeError, OSError, ValueError):
        return None  # unreadable: rebuild it


def _speakable(text: str) -> bool:
    return any(ch.isalnum() for ch in text)


def _describe_speech(score) -> str:
    from .qa.verify import MAX_DELETION_RUN, MAX_INSERTION_RUN

    parts = [f"speech check: {round(100 * score.cer)}% different from the text"]
    if score.max_deletion_run >= MAX_DELETION_RUN:
        parts.append(f"{score.max_deletion_run} words in a row missing")
    if score.max_insertion_run >= MAX_INSERTION_RUN:
        parts.append(f"{score.max_insertion_run} extra words in a row")
    return ", ".join(parts)


def _make_verifier(opts: ConvertOptions, spec, lang: str, emit: Emit):
    """Whisper verifier when checks are on and the model is installed; None otherwise (with a notice)."""
    want = opts.verify if opts.verify is not None else not spec.deterministic
    if not want:
        return None
    from . import modelstore
    from .qa.verify import Verifier

    if not modelstore.status(modelstore.QA_ID)["installed"]:
        emit({"event": "notice", "message": "Speech check skipped: the Whisper model is not installed "
                                            "(audiobook-engine models download whisper)."})
        return None
    return Verifier(lang)


def _convert(book, book_path, opts, plans, lang, job_id, job_dir, emit, owned: set[str] | frozenset[str] = frozenset()) -> dict:
    t_start = time.monotonic()
    synth = Synthesizer(opts.engine, opts.voice, lang, opts.speed, emit)
    spec = synth.spec
    synth.verifier = _make_verifier(opts, spec, lang, emit)
    tempo = 1.0 if spec.supports_speed else opts.speed

    keys = {(p.index, c.index): synth.key(c.text) for p in plans for c in p.chunks}
    chapters = []  # (n, plan, chapter_path, manifest_path, manifest, seconds if already assembled)
    for n, plan in enumerate(plans):
        chapter_path = job_dir / "chapters" / f"{n:03d}.flac"
        manifest_path = chapter_path.with_suffix(".manifest")
        manifest = _chapter_manifest(plan, keys, opts, tempo)
        chapters.append((n, plan, chapter_path, manifest_path, manifest,
                         _assembled_seconds(chapter_path, manifest_path, manifest)))
    total_chars = sum(p.chars for p in plans)
    # Work left = distinct uncached chunks of the chapters that still have to be assembled.
    todo: dict[str, int] = {}
    for _n, plan, _cp, _mp, _m, done_s in chapters:
        if done_s is not None:
            continue
        for c in plan.chunks:
            k = keys[(plan.index, c.index)]
            if k not in todo and not synth.cache.has(k):
                todo[k] = c.chars
    todo_chars = sum(todo.values())
    prior = saved_rate(spec.id, opts.voice.label())
    est_audio = total_chars * seconds_per_char(lang) / max(opts.speed, 0.1)
    warnings = list(book.warnings)
    if power_source() == "battery":
        warnings.append("Running on battery: plug in for long conversions (sleep is blocked only while awake).")
    emit({
        "event": "job_start", "job_id": job_id, "job_dir": str(job_dir), "title": book.title, "author": book.author,
        "lang": lang, "engine": spec.id, "engine_name": spec.name, "voice": opts.voice.label(),
        "license": spec.license, "noncommercial": spec.noncommercial,
        "sections": [{"index": p.index, "title": p.title, "chars": p.chars, "chunks": len(p.chunks)} for p in plans],
        "total_chars": total_chars, "chars_to_synthesize": todo_chars, "cached_chars": total_chars - todo_chars,
        "est_audio_s": round(est_audio), "saved_rate_cps": prior,
        "est_wall_s": round(todo_chars / prior + TAIL_FRACTION * est_audio) if prior else None,
        "warnings": warnings,
    })

    out_dir_pre = Path(opts.out_dir).expanduser().absolute() if opts.out_dir else book_path.absolute().parent
    check_disk_space(job_dir, out_dir_pre, todo_chars * seconds_per_char(lang), est_audio)

    tracker = RateTracker(trim_outliers=not spec.deterministic)
    audio_tracker = RateTracker(trim_outliers=not spec.deterministic)  # audio seconds per wall second
    remaining_todo = todo_chars
    first_batch = True
    CALIBRATION_CHARS = 800
    pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="assemble")
    futures: list[tuple[int, Future]] = []
    fresh_issues: dict[str, list[str]] = {}  # chunk key -> issues, for chunks synthesised in this run
    chars_done = 0
    audio_done = 0.0
    sections_meta: list[dict] = []

    try:
        for n, plan, chapter_path, manifest_path, manifest, done_s in chapters:
            if done_s is not None:
                sections_meta.append({"n": n, "title": plan.title, "path": chapter_path, "seconds": done_s})
                chars_done += plan.chars
                emit({"event": "section_skip", "section": plan.index, "n": n, "title": plan.title,
                      "reason": "already assembled"})
                continue

            emit({"event": "section_start", "section": plan.index, "n": n, "of": len(plans), "title": plan.title,
                  "chunks": len(plan.chunks), "chars": plan.chars})
            pieces: list[np.ndarray | None] = [None] * len(plan.chunks)
            pending: list[int] = []
            unchecked: list[int] = []
            for i, c in enumerate(plan.chunks):
                a = synth.cached(c)
                if a is None:
                    pending.append(i)
                else:
                    pieces[i] = a
                    chars_done += c.chars
                    if synth.needs_check(c):
                        unchecked.append(i)
            if unchecked:
                checked, checked_issues = synth.verify_cached([plan.chunks[i] for i in unchecked],
                                                              [pieces[i] for i in unchecked])
                for i, a, iss in zip(unchecked, checked, checked_issues):
                    pieces[i] = a
                    fresh_issues[keys[(plan.index, plan.chunks[i].index)]] = iss
                    if iss:
                        emit({"event": "chunk_flagged", "section": plan.index, "chunk": i, "issues": iss,
                              "text": plan.chunks[i].text[:200]})
            bs = max(1, spec.batch_size)
            for b in range(0, len(pending), bs):
                idxs = pending[b:b + bs]
                batch = [plan.chunks[i] for i in idxs]
                t0 = time.monotonic()
                audios, issues = synth.synthesize(batch)
                wall = time.monotonic() - t0
                bchars = sum(c.chars for c in batch)
                if first_batch:
                    first_batch = False  # first call after load carries one-off overhead: not representative
                else:
                    tracker.add(bchars, wall)
                    audio_tracker.add(sum(a.size for a in audios) / synth.sample_rate, wall)
                chars_done += bchars
                for i, a, iss in zip(idxs, audios, issues):
                    k = keys[(plan.index, plan.chunks[i].index)]
                    remaining_todo -= todo.pop(k, 0)
                    fresh_issues[k] = iss
                    pieces[i] = a
                    audio_done += a.size / synth.sample_rate
                    if iss:
                        emit({"event": "chunk_flagged", "section": plan.index, "chunk": i, "issues": iss,
                              "text": plan.chunks[i].text[:200]})
                tail = TAIL_FRACTION * est_audio  # assembly of the last chapter + encode (measured)
                if tracker.total_chars >= CALIBRATION_CHARS:
                    eta, eta_low, eta_high = tracker.eta(max(remaining_todo, 0), prior, tail)
                elif prior:
                    eta, eta_low, eta_high = RateTracker().eta(max(remaining_todo, 0), prior, tail)
                else:
                    eta = eta_low = eta_high = None  # "calibrating"
                wr = tracker.window_rate
                emit({
                    "event": "progress", "section": plan.index, "n": n, "of": len(plans),
                    "chunk": idxs[-1] + 1, "chunks": len(plan.chunks),
                    "chars_done": chars_done, "total_chars": total_chars,
                    "percent": round(100 * chars_done / total_chars, 2),
                    "rate_cps": round(wr, 1) if wr else None,
                    "run_rate_cps": round(tracker.run_rate, 1) if tracker.run_rate else None,
                    "realtime_x": round(audio_tracker.window_rate, 2) if audio_tracker.window_rate else None,
                    "eta_s": round(eta) if eta is not None else None,
                    "eta_low_s": round(eta_low) if eta_low is not None else None,
                    "eta_high_s": round(eta_high) if eta_high is not None else None,
                    "eta_basis": "measured" if tracker.total_chars >= CALIBRATION_CHARS else ("saved" if prior else "calibrating"),
                    "elapsed_s": round(time.monotonic() - t_start),
                    "qa": dict(synth.qa_stats) if synth.verifier is not None else None,
                })

            sr = synth.sample_rate
            ready = [(p if p is not None else np.zeros(0, np.float32), c.is_heading, c.paragraph_end)
                     for p, c in zip(pieces, plan.chunks)]
            # Empty audio for real text is not cached. A non-deterministic engine may succeed next
            # time, so such a chapter gets no manifest and the next run re-attempts the chunk.
            # (A deterministic engine would return the same empty audio: no point retrying.)
            retry_later = not spec.deterministic and any(
                (p is None or p.size == 0) and _speakable(c.text) for p, c in zip(pieces, plan.chunks))
            fut = pool.submit(_assemble_chapter, ready, sr, opts.pacing, tempo, chapter_path, manifest_path,
                              None if retry_later else manifest)
            futures.append((n, fut))
            sections_meta.append({"n": n, "title": plan.title, "path": chapter_path, "seconds": None, "future": fut})

        # Measured rate for future estimates.
        if tracker.total_chars:
            save_rate(spec.id, opts.voice.label(), tracker.total_chars, tracker.total_wall,
                      audio_tracker.total_chars, "convert")

        emit({"event": "assembling", "message": "Waiting for chapter loudness normalisation"})
        for n, fut in futures:
            secs = fut.result()
            for m in sections_meta:
                if m["n"] == n:
                    m["seconds"] = secs
    finally:
        # On cancel or failure too: drop queued assemblies and wait for running ones while this
        # process still holds the GPU lock, so a resumed run never assembles the same chapter
        # concurrently. A SIGTERM must not cut this wait short.
        with _cancel_deferred():
            pool.shutdown(wait=True, cancel_futures=True)

    # Chunks flagged in any run (issues are stored with each cached chunk), not just this one.
    flagged: list[dict] = []
    for plan in plans:
        for i, c in enumerate(plan.chunks):
            k = keys[(plan.index, c.index)]
            iss = fresh_issues[k] if k in fresh_issues else synth.cache.issues(k)
            if iss:
                flagged.append({"section": plan.index, "chunk": i, "issues": iss, "text": c.text[:200]})

    # Chapters and M4B.
    marks, pos = [], 0.0
    for m in sections_meta:
        start = pos
        pos += m["seconds"]
        marks.append(m4b.ChapterMark(display_title(m["title"]), int(round(start * 1000)), int(round(pos * 1000))))
    tools = m4b.check_tools()
    out_dir = Path(opts.out_dir).expanduser().absolute() if opts.out_dir else book_path.absolute().parent
    out_dir.mkdir(parents=True, exist_ok=True)
    out = output_path(out_dir, book.title, book.author, opts.voice.label(), job_id, owned)
    work = job_dir
    cover = None
    if book.cover:
        try:
            cover = m4b.prepare_cover(book.cover.data, book.cover.media_type, work)
        except m4b.FFmpegError:
            # A damaged cover must not throw away hours of narration (and fail again on every resume).
            emit({"event": "notice", "message": "The book's cover image could not be read; "
                                                "the audiobook is made without a cover."})
    meta = work / "metadata.txt"
    m4b.write_metadata(meta, {
        "title": book.title, "album": book.title, "artist": book.author, "album_artist": book.author,
        "composer": f"{spec.name} — {opts.voice.label()}", "genre": "Audiobook",
        "date": (book.metadata.get("date") or "")[:4], "comment": _job_comment(spec.name, spec.license, job_id),
        "language": lang,
    }, marks)
    emit({"event": "encoding", "percent": 0, "output": str(out), "encoder": tools["aac_encoder"]})
    last = [0.0]

    def on_progress(f: float):
        if f - last[0] >= 0.05:
            last[0] = f
            emit({"event": "encoding", "percent": round(100 * f)})

    m4b.encode_m4b([m["path"] for m in sections_meta], meta, cover, out, bitrate_k=opts.bitrate_k,
                   total_seconds=pos, encoder=tools["aac_encoder"], on_progress=on_progress)
    problems = m4b.verify_m4b(out, len(marks), pos, cover is not None)
    wall = time.monotonic() - t_start
    result = {
        "event": "done", "output": str(out), "duration_s": round(pos, 1), "chapters": len(marks),
        "wall_s": round(wall, 1), "synth_chars": tracker.total_chars,
        "synth_wall_s": round(tracker.total_wall, 1),
        "realtime_x": round(pos / wall, 2) if wall else None,
        "flagged_chunks": len(flagged), "verification_problems": problems,
        "size_mb": round(out.stat().st_size / 1e6, 1),
        "qa": dict(synth.qa_stats) if synth.verifier is not None else None,
    }
    (job_dir / "flagged.json").write_text(json.dumps(flagged, indent=2, ensure_ascii=False))
    if not problems and not opts.keep_work:
        # The M4B holds the audio; chapter FLACs are only needed to resume, so free the space.
        # (The chunk cache stays: re-running with other settings reuses it. 'cache clear' empties it.)
        freed = 0
        for f in (job_dir / "chapters").glob("*"):
            freed += f.stat().st_size
            f.unlink()
        result["freed_work_mb"] = round(freed / 1e6, 1)
    emit(result)
    return result


BYTES_PER_AUDIO_SECOND = 24000 * 2 * 0.6  # 16-bit 24 kHz FLAC, ~60% of raw for speech
M4B_BYTES_PER_SECOND = 64000 / 8


def _existing_ancestor(p: Path) -> Path:
    p = Path(p).absolute()
    while not p.exists() and p != p.parent:
        p = p.parent
    return p


def check_disk_space(job_dir: Path, out_dir: Path, todo_audio_s: float, total_audio_s: float) -> None:
    """Refuse to start when the conversion would fill the disk (cache + chapters + M4B + 1 GB margin).

    The output folder may not exist yet (it is created at the end); when the job folder and
    the output folder are on the same disk, both needs come out of the same free space.
    """
    import shutil as _shutil

    need_work = todo_audio_s * BYTES_PER_AUDIO_SECOND + total_audio_s * BYTES_PER_AUDIO_SECOND
    need_out = total_audio_s * M4B_BYTES_PER_SECOND * 1.1
    margin = 1e9
    per_disk: dict[int, tuple[Path, Path, float]] = {}  # device -> (folder named, folder measured, need)
    for where, need in ((job_dir, need_work), (out_dir, need_out)):
        base = _existing_ancestor(where)
        dev = os.stat(base).st_dev
        named, measured, before = per_disk.get(dev, (where, base, 0.0))
        per_disk[dev] = (named, measured, before + need)
    for where, measured, need in per_disk.values():
        free = _shutil.disk_usage(measured).free
        if free < need + margin:
            raise InsufficientDisk(
                f"Not enough disk space at {where}: this conversion needs about {(need + margin) / 1e9:.1f} GB "
                f"and only {free / 1e9:.1f} GB is free. Free some space or run 'audiobook-engine cache clear'.")


class InsufficientDisk(RuntimeError):
    pass


def _assemble_chapter(ready, sr, pacing, tempo, chapter_path: Path, manifest_path: Path, manifest: str | None) -> float:
    """Stitch, retime and normalise one chapter. manifest=None: incomplete, rebuild on the next run."""
    if manifest is None:
        manifest_path.unlink(missing_ok=True)
    audio = assemble(ready, sr, pacing)
    audio = loudness.change_tempo(audio, sr, tempo)
    audio, _info = loudness.normalize(audio, sr)
    # Per-writer temp name: two processes can never interleave writes into one file.
    tmp = chapter_path.with_name(f"{chapter_path.stem}.{os.getpid()}.{threading.get_ident()}.tmp.flac")
    try:
        sf.write(str(tmp), np.clip(audio, -1, 1), sr, subtype="PCM_16", format="FLAC")
        os.replace(tmp, chapter_path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    if manifest is not None:
        manifest_path.write_text(manifest)
    return audio.size / sr


# ----------------------------------------------------------------------------- sample

def sample(book_path: Path, opts: ConvertOptions, section: int | None, seconds: float, out: Path, sink: Emit) -> dict:
    """Synthesise the first `seconds` of a section and project the full-book time."""
    m4b.check_tools()
    book = read_book(book_path)
    lang = resolve_lang(book, opts)
    opts = replace(opts, voice=resolve_voice(opts, lang))
    all_secs = select_sections(book, opts.sections)
    if section is None:
        section = next((s.index for s in book.sections if s.include and s.kind == "chapter"),
                       all_secs[0] if all_secs else None)
        if section is None:
            raise IngestError("No sections selected. Choose one with --section (see 'inspect').")
    else:
        select_sections(book, [section])  # unknown index: a clear error
    o = ConvertOptions(**{**opts.__dict__, "intro": False})
    plans = plan_book(book, o, lang, [section])
    if not plans:
        raise IngestError(f"Section {section} contains no text to narrate.")
    plan = plans[0]
    chunks, est = [], 0.0
    for c in plan.chunks:
        chunks.append(c)
        est += c.chars * seconds_per_char(lang)
        if est >= seconds:
            break
    emit = _Emitter(sink, None)
    with jobs.gpu_lock(on_wait=lambda: emit({"event": "queued", "message": "A conversion is using the GPU; waiting."})):
        return _sample(book, book_path, opts, lang, all_secs, plan, chunks, out, emit)


def _sample(book, book_path, opts, lang, all_secs, plan, chunks, out, emit) -> dict:
    synth = Synthesizer(opts.engine, opts.voice, lang, opts.speed, emit)
    synth.verifier = _make_verifier(opts, synth.spec, lang, emit)
    chars_synth, wall, audio_synth = 0, 0.0, 0.0
    synth.ensure_loaded() if any(synth.cached(c) is None for c in chunks) else None
    got: dict[int, np.ndarray] = {}
    pending = []
    for i, c in enumerate(chunks):
        a = synth.cached(c)
        if a is None:
            pending.append(i)
        else:
            got[i] = a
    bs = max(1, synth.spec.batch_size)  # same batching as convert, so the projection is representative
    for b in range(0, len(pending), bs):
        idxs = pending[b:b + bs]
        t0 = time.monotonic()
        audios, _ = synth.synthesize([chunks[i] for i in idxs])
        wall += time.monotonic() - t0
        for i, a in zip(idxs, audios):
            got[i] = a
            chars_synth += chunks[i].chars
            audio_synth += a.size / synth.sample_rate
    pieces = [(got[i], c.is_heading, c.paragraph_end) for i, c in enumerate(chunks)]
    sr = synth.sample_rate
    tempo = 1.0 if synth.spec.supports_speed else opts.speed
    audio = loudness.change_tempo(assemble(pieces, sr, opts.pacing), sr, tempo)
    audio, _ = loudness.normalize(audio, sr)
    out.parent.mkdir(parents=True, exist_ok=True)
    norm = out.with_suffix(".norm.flac")
    sf.write(str(norm), np.clip(audio, -1, 1), sr, subtype="PCM_16", format="FLAC")
    codec = []
    if out.suffix.lower() in {".m4a", ".m4b", ".mp4", ".aac"}:
        codec = ["-c:a", m4b.check_tools()["aac_encoder"], "-b:a", "96k"]
    subprocess.run([m4b.FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(norm), *codec, str(out)], check=True)
    norm.unlink(missing_ok=True)
    audio_s = audio.size / sr
    rate = chars_synth / wall if wall > 0 else saved_rate(synth.spec.id, opts.voice.label())
    if chars_synth:
        save_rate(synth.spec.id, opts.voice.label(), chars_synth, wall, audio_synth, "sample")
    included = sum(p.chars for p in plan_book(book, opts, lang, all_secs))
    result = {
        "event": "sample_done", "output": str(out), "section": plan.index, "title": plan.title,
        "audio_s": round(audio_s, 1), "synth_wall_s": round(wall, 2), "chars_synthesized": chars_synth,
        "rate_cps": round(rate, 1) if rate else None,
        "realtime_x": round(audio_synth / wall, 2) if wall > 0 else None,
        "book_chars": included, "book_est_audio_s": round(included * seconds_per_char(lang) / max(opts.speed, 0.1)),
        "book_est_wall_s": round(included / rate) if rate else None,
        "note": "Projection from this sample; short samples run cooler than long jobs, expect it to be optimistic.",
        "qa": dict(synth.qa_stats) if synth.verifier is not None else None,
    }
    emit(result)
    return result
