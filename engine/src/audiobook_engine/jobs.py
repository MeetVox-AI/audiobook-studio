"""Detached jobs: survive the app closing; one GPU job at a time.

A job is a folder (job.json state + events.jsonl progress). The app launches
`convert --detach`, gets the job folder back immediately, and tails events.
Only one process may use the GPU: running two MLX models at once is slower and
has been reported to hang, so later jobs wait on a lock file ("queued").
"""

from __future__ import annotations

import fcntl
import json
import os
import signal
import subprocess
import sys
import threading
import time
from contextlib import contextmanager, nullcontext
from pathlib import Path

from . import paths


@contextmanager
def gpu_lock(on_wait=None):
    lock_path = paths.home() / "gpu.lock"
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if on_wait:
                on_wait()
            fcntl.flock(fd, fcntl.LOCK_EX)  # wait for the running job
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class JobBusy(RuntimeError):
    """Another live process owns this job folder."""

    def __init__(self, job_dir: Path, pid: int | None):
        self.job_dir = job_dir
        self.pid = pid
        who = f"pid {pid}" if pid else "another process"
        super().__init__(f"This job is already running ({who}). Follow it with 'jobs status {job_dir.name}'.")


def _read_lock_pid(fd: int) -> int | None:
    try:
        raw = os.pread(fd, 32, 0).decode().strip()
        return int(raw) if raw else None
    except (OSError, ValueError):
        return None


# How long job_lock keeps trying before it reports JobBusy. A probe (lock_holder) or a
# process that is just releasing the lock holds it for an instant: that is not a running job.
JOB_LOCK_WAIT_S = 1.5


@contextmanager
def job_lock(job_dir: Path, wait_s: float | None = None):
    """Exclusive ownership of a job folder for one process.

    Raises JobBusy, without touching job.json or events.jsonl, when another
    process still holds the folder after `wait_s` seconds (default JOB_LOCK_WAIT_S).
    """
    job_dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(job_dir / "job.lock", os.O_CREAT | os.O_RDWR, 0o644)
    try:
        deadline = time.monotonic() + (JOB_LOCK_WAIT_S if wait_s is None else wait_s)
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise JobBusy(job_dir, _read_lock_pid(fd)) from None
                time.sleep(0.05)
        try:
            os.ftruncate(fd, 0)
            os.pwrite(fd, str(os.getpid()).encode(), 0)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def lock_holder(job_dir: Path) -> int | None:
    """pid of the process that currently runs this job (0 if unknown), or None when nobody does."""
    lock = job_dir / "job.lock"
    if not lock.exists():
        return None
    fd = os.open(lock, os.O_RDWR)
    try:
        try:
            # Shared: probes never block each other (job_lock also retries briefly).
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return _read_lock_pid(fd) or 0
        fcntl.flock(fd, fcntl.LOCK_UN)
        return None
    finally:
        os.close(fd)


# A child started by 'convert --detach' takes job.lock only once its interpreter is up and the
# book is read (about a second). Until then the launching parent's note says it is starting.
_LAUNCH_NOTE = "launched.json"
LAUNCH_GRACE_S = 120.0


@contextmanager
def launch_lock(job_dir: Path):
    """Serialises 'convert --detach' parents for one job folder while they check and spawn."""
    job_dir.mkdir(parents=True, exist_ok=True)
    fd = os.open(job_dir / "launch.lock", os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)  # held for milliseconds by another parent at most
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def note_launch(job_dir: Path, pid: int, job_id: str) -> None:
    f = job_dir / _LAUNCH_NOTE
    tmp = f.with_name(f".{_LAUNCH_NOTE}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"pid": pid, "job_id": job_id, "at": time.time()}))
    tmp.replace(f)


def starting_child(job_dir: Path) -> dict | None:
    """{pid, job_id} of a child launched moments ago that is still starting up, else None."""
    try:
        note = json.loads((job_dir / _LAUNCH_NOTE).read_text())
        pid, at = int(note["pid"]), float(note["at"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not (0 <= time.time() - at <= LAUNCH_GRACE_S) or not _alive(pid) or not _is_engine_process(pid):
        return None
    # The child writes its pid into job.json only while it holds job.lock. Once it has, and the lock
    # is free again, its run is over (it is only exiting): it is not starting any more.
    if read_state(job_dir).get("pid") == pid and lock_holder(job_dir) is None:
        return None
    return {"pid": pid, "job_id": note.get("job_id")}


def spawn_detached(argv: list[str], job_dir: Path) -> int:
    """Start `audiobook-engine <argv> --job-dir job_dir` in its own session."""
    job_dir.mkdir(parents=True, exist_ok=True)
    err = open(job_dir / "stderr.log", "ab")
    proc = subprocess.Popen(
        [sys.executable, "-m", "audiobook_engine.cli", *argv, "--job-dir", str(job_dir)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err,
        start_new_session=True, close_fds=True, env={**os.environ, "HF_HUB_OFFLINE": "1"},
    )
    err.close()
    return proc.pid


def _alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # An exited process not yet reaped by its parent ("zombie") is not running.
    try:
        stat = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    except Exception:
        return True
    return bool(stat) and not stat.startswith("Z")


def _is_engine_process(pid: int) -> bool:
    try:
        cmd = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    except Exception:
        return False
    return "audiobook_engine" in cmd or "audiobook-engine" in cmd


# First event of every run (events.jsonl is appended to across runs of the same job).
RUN_START = "run_start"


def _tail_lines(f: Path, limit_bytes: int) -> list[str]:
    with open(f, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - limit_bytes))
        return fh.read().decode("utf-8", errors="replace").splitlines()


def last_events(job_dir: Path, kinds: set[str] | None = None, limit_bytes: int = 65536) -> dict[str, dict]:
    """Latest event of each kind in the most recent run, read from the tail of events.jsonl."""
    f = job_dir / "events.jsonl"
    if not f.exists():
        return {}
    events = []
    for line in _tail_lines(f, limit_bytes):
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue  # partial first line
        if isinstance(ev, dict):
            events.append(ev)
    # Only the latest run counts: an error or result left by an earlier run is stale.
    # Logs written before runs were marked start each run with job_start.
    for boundary in (RUN_START, "job_start"):
        starts = [i for i, ev in enumerate(events) if ev.get("event") == boundary]
        if starts:
            events = events[starts[-1]:]
            break
    out: dict[str, dict] = {}
    for ev in events:
        if kinds is None or ev.get("event") in kinds:
            out[ev.get("event")] = ev
    return out


def stderr_tail(job_dir: Path, lines: int = 20, limit_bytes: int = 8192) -> list[str]:
    """Last lines the engine wrote to stderr.log (detached jobs): tracebacks, crashes."""
    f = job_dir / "stderr.log"
    try:
        return [ln for ln in _tail_lines(f, limit_bytes) if ln.strip()][-lines:]
    except OSError:
        return []


def status(job_dir: Path) -> dict:
    try:
        state = json.loads((job_dir / "job.json").read_text())
    except Exception:
        state = {"job_id": job_dir.name, "state": "unknown"}
    pid = state.get("pid")
    if state.get("state") in {"running", "queued"} and not _alive(pid):
        state["state"] = "interrupted"  # crashed or killed: resumable
    ev = last_events(job_dir, {"progress", "error", "done", "encoding", "assembling", "job_start", "queued"})
    state["last_progress"] = ev.get("progress")
    state["last_error"] = ev.get("error")
    state["result"] = ev.get("done")
    state["job_dir"] = str(job_dir)
    if state.get("state") in {"failed", "interrupted"}:
        tail = stderr_tail(job_dir)
        if tail:
            state["stderr_tail"] = tail
    return state


def list_jobs() -> list[dict]:
    jobs = [status(d) for d in paths.jobs_dir().iterdir() if d.is_dir() and (d / "job.json").exists()]
    return sorted(jobs, key=lambda j: j.get("started", ""), reverse=True)


def cancel(job_dir: Path) -> dict:
    st = status(job_dir)
    pid = st.get("pid")
    if st["state"] not in {"running", "queued"} or not _alive(pid):
        return {"cancelled": False, "reason": f"job is {st['state']}"}
    if not _is_engine_process(pid):
        return {"cancelled": False, "reason": "process does not look like an audiobook-engine job"}
    os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if not _alive(pid):
            break
        time.sleep(0.1)
    return {"cancelled": True, "pid": pid, "stopped": not _alive(pid)}


def read_state(job_dir: Path) -> dict:
    try:
        state = json.loads((job_dir / "job.json").read_text())
    except Exception:
        return {}
    return state if isinstance(state, dict) else {}


def update_state(job_dir: Path, *, clear: tuple[str, ...] = (), **fields) -> None:
    """Merge fields into job.json (and drop the `clear` keys), atomically."""
    f = job_dir / "job.json"
    state = read_state(job_dir)
    for k in clear:
        state.pop(k, None)
    state.update(fields)
    # Unique temporary name: two writers never share (and tear) one temp file.
    tmp = f.with_name(f".job.json.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(f)


def append_event(job_dir: Path, ev: dict) -> None:
    with open(job_dir / "events.jsonl", "a", encoding="utf-8") as fh:
        fh.write(json.dumps(ev, ensure_ascii=False) + "\n")


def record_failure(job_dir: Path, message: str, *, state: str = "failed", lock_held: bool = False,
                   **fields) -> bool:
    """Record a run that failed (or was cancelled) before its event log was open.

    Appends a run_start + error event (a 'cancelled' event for state='cancelled')
    to events.jsonl and marks job.json, so a detached job never disappears
    silently. Does nothing (returns False) when another live process owns the
    job, or when the folder cannot be written.
    """
    try:
        job_dir.mkdir(parents=True, exist_ok=True)
        with nullcontext() if lock_held else job_lock(job_dir):
            cancelled = state == "cancelled"
            append_event(job_dir, {"t": 0.0, "event": RUN_START, "pid": os.getpid()})
            append_event(job_dir, {"t": 0.0, "event": "cancelled" if cancelled else "error", "message": message})
            now = time.strftime("%Y-%m-%dT%H:%M:%S")
            current = read_state(job_dir)
            merged = {k: v for k, v in {"job_id": job_dir.name, "started": now}.items() if k not in current}
            # 'output' describes one run, but the job still owns that file (see pipeline.output_path).
            outputs = current.get("outputs")
            owned = sorted({str(o) for o in [*(outputs if isinstance(outputs, list) else []), current.get("output")] if o})
            if owned:
                merged["outputs"] = owned
            merged.update(fields)
            merged.update(state=state, pid=os.getpid(), finished=now)
            if not cancelled:
                merged["error"] = message
            update_state(job_dir, clear=("output", "error"), **merged)
        return True
    except (JobBusy, OSError):
        return False
