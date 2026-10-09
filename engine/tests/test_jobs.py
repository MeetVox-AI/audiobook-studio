from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import threading
import time

import pytest

from audiobook_engine import jobs, paths


@pytest.fixture(autouse=True)
def isolated_home(tmp_path, monkeypatch):
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", str(tmp_path / "home"))
    yield


def make_job(job_id: str, state: str, pid: int | None, events: list[dict]):
    jd = paths.jobs_dir() / job_id
    jd.mkdir(parents=True)
    jobs.update_state(jd, job_id=job_id, state=state, pid=pid, started=time.strftime("%Y-%m-%dT%H:%M:%S"))
    (jd / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    return jd


def test_status_reads_latest_progress_and_detects_dead_process():
    jd = make_job("a1", "running", 999999, [
        {"event": "progress", "percent": 10.0}, {"event": "progress", "percent": 42.5}])
    st = jobs.status(jd)
    assert st["state"] == "interrupted"  # pid not alive: resumable
    assert st["last_progress"]["percent"] == 42.5


def test_status_tolerates_partial_last_line():
    jd = make_job("a2", "done", None, [{"event": "done", "output": "x.m4b"}])
    with open(jd / "events.jsonl", "a") as f:
        f.write('{"event": "prog')  # writer was mid-line
    assert jobs.status(jd)["result"]["output"] == "x.m4b"


def test_list_jobs_sorted_newest_first():
    make_job("old", "done", None, [])
    time.sleep(1.1)
    make_job("new", "done", None, [])
    assert [j["job_id"] for j in jobs.list_jobs()][:2] == ["new", "old"]


def test_cancel_refuses_foreign_processes_and_stops_engine_ones():
    foreign = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        jd = make_job("f", "running", foreign.pid, [])
        assert jobs.cancel(jd)["cancelled"] is False
    finally:
        foreign.kill()
    engine_like = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "audiobook_engine"])
    jd = make_job("e", "running", engine_like.pid, [])
    res = jobs.cancel(jd)
    assert res["cancelled"] is True and res["stopped"] is True
    engine_like.wait(timeout=5)


def test_gpu_lock_serialises_and_reports_waiting():
    order, waited = [], []

    def second():
        with jobs.gpu_lock(on_wait=lambda: waited.append(True)):
            order.append("second")

    with jobs.gpu_lock():
        t = threading.Thread(target=second)
        t.start()
        time.sleep(0.3)
        order.append("first")
    t.join(timeout=5)
    assert order == ["first", "second"] and waited == [True]


def test_status_reports_only_the_latest_run():
    jd = make_job("r1", "done", None, [
        {"event": "run_start"}, {"event": "job_start"}, {"event": "error", "message": "old failure"},
        {"event": "run_start"}, {"event": "job_start"}, {"event": "progress", "percent": 100.0},
        {"event": "done", "output": "new.m4b"}])
    st = jobs.status(jd)
    assert st["last_error"] is None and st["result"]["output"] == "new.m4b"

    # A rerun that is still going does not show the previous run's result.
    with open(jd / "events.jsonl", "a") as f:
        f.write(json.dumps({"event": "run_start"}) + "\n" + json.dumps({"event": "job_start"}) + "\n")
    assert jobs.status(jd)["result"] is None


def test_status_scopes_logs_written_before_run_markers_by_job_start():
    jd = make_job("r2", "done", None, [
        {"event": "job_start"}, {"event": "error", "message": "old failure"},
        {"event": "job_start"}, {"event": "done", "output": "x.m4b"}])
    st = jobs.status(jd)
    assert st["last_error"] is None and st["result"]["output"] == "x.m4b"


def test_status_shows_stderr_tail_when_failed_or_interrupted():
    failed = make_job("s1", "failed", None, [{"event": "error", "message": "boom"}])
    (failed / "stderr.log").write_text("noise\n" * 50 + "Traceback (most recent call last):\nValueError: boom\n")
    st = jobs.status(failed)
    assert st["stderr_tail"][-1] == "ValueError: boom" and len(st["stderr_tail"]) <= 20

    crashed = make_job("s2", "running", 999999, [])  # dead pid: interrupted
    (crashed / "stderr.log").write_text("Segmentation fault\n")
    st = jobs.status(crashed)
    assert st["state"] == "interrupted" and st["stderr_tail"] == ["Segmentation fault"]

    done = make_job("s3", "done", None, [])
    (done / "stderr.log").write_text("harmless library chatter\n")
    assert "stderr_tail" not in jobs.status(done)


def test_update_state_survives_concurrent_writers():
    jd = paths.jobs_dir() / "w"
    jd.mkdir()
    errors = []

    def writer(n):
        try:
            for i in range(300):
                jobs.update_state(jd, **{f"w{n}": i})
        except Exception as exc:  # e.g. a shared temp file replaced by the other writer
            errors.append(exc)

    threads = [threading.Thread(target=writer, args=(n,)) for n in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    json.loads((jd / "job.json").read_text())
    assert not list(jd.glob("*.tmp"))


def test_job_lock_is_exclusive_and_names_its_holder(monkeypatch):
    monkeypatch.setattr(jobs, "JOB_LOCK_WAIT_S", 0.1, raising=False)
    jd = paths.jobs_dir() / "l"
    assert jobs.lock_holder(jd) is None
    with jobs.job_lock(jd):
        assert jobs.lock_holder(jd) == os.getpid()
        with pytest.raises(jobs.JobBusy) as busy:
            with jobs.job_lock(jd):
                pass
        assert busy.value.pid == os.getpid()
        # A failure report from a second process must not touch the running job's files.
        assert jobs.record_failure(jd, "duplicate") is False
        assert not (jd / "events.jsonl").exists() and not (jd / "job.json").exists()
    assert jobs.lock_holder(jd) is None


def test_record_failure_creates_a_readable_job():
    jd = paths.jobs_dir() / "f1"
    assert jobs.record_failure(jd, "IngestError: bad book", book="/b.epub") is True
    st = jobs.status(jd)
    assert st["state"] == "failed" and st["job_id"] == "f1" and st["book"] == "/b.epub"
    assert st["last_error"]["message"] == "IngestError: bad book"
    assert [j["job_id"] for j in jobs.list_jobs()] == ["f1"]


def test_home_from_a_relative_environment_path_is_absolute(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("AUDIOBOOK_STUDIO_HOME", "relhome")
    assert paths.home() == tmp_path / "relhome"
    assert paths.jobs_dir().is_absolute()


def test_job_lock_waits_briefly_for_a_holder_that_lets_go():
    """A status probe (or a process just releasing the job) holds job.lock for an instant:
    a starting child must not give up on its own job because of that."""
    jd = paths.jobs_dir() / "brief"
    jd.mkdir()
    fd = os.open(jd / "job.lock", os.O_CREAT | os.O_RDWR)
    fcntl.flock(fd, fcntl.LOCK_SH)

    def let_go():
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    timer = threading.Timer(0.3, let_go)
    timer.start()
    try:
        with jobs.job_lock(jd):
            assert jobs.lock_holder(jd) == os.getpid()
    finally:
        timer.join()


def test_lock_probes_do_not_see_each_other_as_a_running_job():
    jd = paths.jobs_dir() / "probe"
    jd.mkdir()
    (jd / "job.lock").write_text("4242")  # the pid of an earlier run, long gone
    fd = os.open(jd / "job.lock", os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)  # another process probing at this very moment
        assert jobs.lock_holder(jd) is None
    finally:
        os.close(fd)


def test_a_cancel_recorded_before_the_log_opens_is_not_an_error():
    jd = paths.jobs_dir() / "c1"
    jd.mkdir()
    jobs.update_state(jd, job_id="c1", state="failed", error="RuntimeError: old")
    assert jobs.record_failure(jd, "Cancelled", state="cancelled") is True
    st = jobs.status(jd)
    assert st["state"] == "cancelled" and "error" not in st and st["last_error"] is None
    events = [json.loads(x) for x in (jd / "events.jsonl").read_text().splitlines()]
    assert [e["event"] for e in events] == ["run_start", "cancelled"]


def test_record_failure_keeps_the_jobs_earlier_output_as_owned():
    jd = paths.jobs_dir() / "o1"
    jd.mkdir()
    jobs.update_state(jd, job_id="o1", state="done", output="/books/T - A.m4b", outputs=["/books/T - A (v).m4b"])
    jobs.record_failure(jd, "IngestError: the book changed", book="/books/b.epub")
    state = jobs.read_state(jd)
    assert "output" not in state and state["outputs"] == ["/books/T - A (v).m4b", "/books/T - A.m4b"]
    assert state["state"] == "failed" and state["error"] == "IngestError: the book changed"


def test_launch_note_names_a_starting_child_only_while_it_lives():
    jd = paths.jobs_dir() / "n1"
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "audiobook_engine"])
    try:
        with jobs.launch_lock(jd):
            jobs.note_launch(jd, child.pid, "n1")
        assert jobs.starting_child(jd) == {"pid": child.pid, "job_id": "n1"}
    finally:
        child.kill()
        child.wait()
    assert jobs.starting_child(jd) is None
    foreign = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])  # not an engine process
    try:
        jobs.note_launch(jd, foreign.pid, "n1")
        assert jobs.starting_child(jd) is None
    finally:
        foreign.kill()
        foreign.wait()


def test_a_launched_child_whose_run_is_over_is_not_starting_while_it_exits():
    jd = paths.jobs_dir() / "n2"
    jd.mkdir(parents=True)
    # Still alive (model and interpreter shutdown), but its run already took and released job.lock.
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "audiobook_engine"])
    try:
        jobs.note_launch(jd, child.pid, "n2")
        jobs.update_state(jd, job_id="n2", state="running", pid=4242)  # an earlier run's record
        assert jobs.starting_child(jd) == {"pid": child.pid, "job_id": "n2"}  # not started its run yet
        with jobs.job_lock(jd):  # its run: it holds the lock and records its pid
            jobs.update_state(jd, state="running", pid=child.pid)
            assert jobs.starting_child(jd) == {"pid": child.pid, "job_id": "n2"}
        jobs.update_state(jd, state="failed")  # the run is over, the lock is free
        assert jobs.lock_holder(jd) is None and jobs.starting_child(jd) is None
    finally:
        child.kill()
        child.wait()
