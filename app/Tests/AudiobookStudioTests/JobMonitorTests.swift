import Foundation
import Testing
@testable import AudiobookStudio

/// Builds events.jsonl files in a temporary job folder.
private struct JobFolder {
    let dir: URL
    var events: URL { dir.appendingPathComponent("events.jsonl") }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func write(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: events)
    }

    func append(_ lines: [String]) throws {
        let h = try FileHandle(forWritingTo: events)
        try h.seekToEnd()
        try h.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try h.close()
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

/// A run of job "abc": run_start, job_start, section_start, model events and progress at the given percents.
private func run(pid: Int, title: String, percents: [Double], rate: Double, flagged: Bool = false) -> [String] {
    var lines = [
        #"{"t": 0.0, "event": "run_start", "job_id": "abc", "pid": \#(pid)}"#,
        #"{"t": 0.1, "event": "job_start", "job_id": "abc", "title": "\#(title)", "author": "A. Writer", "lang": "en", "engine": "kokoro", "engine_name": "Kokoro 82M", "voice": "af_heart", "total_chars": 1000, "sections": [{"index": 3, "title": "I", "chars": 1000, "chunks": 10}]}"#,
        #"{"t": 0.2, "event": "section_start", "section": 3, "n": 0, "of": 1, "title": "I", "chunks": 10, "chars": 1000}"#,
        #"{"t": 0.3, "event": "model_loading", "engine": "kokoro"}"#,
        #"{"t": 1.0, "event": "model_loaded", "load_s": 0.5, "warmup_s": 0.2}"#,
    ]
    for (i, p) in percents.enumerated() {
        let t = 2.0 + Double(i)
        lines.append(#"{"t": \#(t), "event": "progress", "section": 3, "n": 0, "of": 1, "chunk": \#(i + 1), "chunks": 10, "chars_done": \#(Int(p * 10)), "total_chars": 1000, "percent": \#(p), "rate_cps": \#(rate), "run_rate_cps": \#(rate), "realtime_x": 5.0, "eta_s": 100, "eta_low_s": 90, "eta_high_s": 120, "eta_basis": "measured", "elapsed_s": \#(t), "qa": {"checked": \#(i + 1), "redone": 0, "flagged": 0}}"#)
    }
    if flagged {
        lines.append(#"{"t": 9.0, "event": "chunk_flagged", "section": 3, "chunk": 2, "issues": ["missing words"], "text": "It is a truth"}"#)
    }
    return lines
}

private let cancelledLine = #"{"t": 9.5, "event": "cancelled", "message": "Stopped. Finished chunks are cached; run again to resume."}"#
private let doneLine = #"{"t": 20.0, "event": "done", "output": "/tmp/Book.m4b", "duration_s": 600.0, "chapters": 1, "wall_s": 20.0, "flagged_chunks": 0, "verification_problems": [], "size_mb": 5.0, "qa": {"checked": 10, "redone": 1, "flagged": 0}}"#

/// Polls (on the main actor, letting the monitor's tasks run) until `condition` holds or times out.
@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { break }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// events.jsonl holds two runs of the same job: the first was cancelled, the second is running.
/// The monitor must follow the second run, not stop at the first run's `cancelled` event.
@MainActor
@Test func monitorFollowsLatestRunByPid() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write(run(pid: 111, title: "Old run", percents: [10, 20], rate: 50, flagged: true) + [cancelledLine]
                     + run(pid: 222, title: "New run", percents: [40], rate: 60))

    let monitor = JobMonitor(jobId: "abc", jobDir: folder.dir, pid: 222, initialState: .running,
                             client: nil, options: .testing)
    monitor.start()
    try await waitUntil { monitor.latestProgress?.percent == 40 }

    #expect(monitor.isLive)
    #expect(monitor.state == .running && monitor.phase == .synthesizing)
    #expect(monitor.title == "New run" && monitor.engineName == "Kokoro 82M")
    #expect(monitor.cancelMessage == nil)
    #expect(monitor.rateHistory.map(\.rateCps) == [60])     // nothing from the old run
    #expect(monitor.flaggedChunks.isEmpty)                    // the flagged chunk belonged to the old run
    #expect(monitor.chapterText == "Chapter 1 of 1 — “I”")
    #expect(monitor.chunkText == "Chunk 1 of 10")
    #expect(monitor.etaText == "about 2 min")

    // The new run continues and finishes.
    try folder.append([
        #"{"t": 5.0, "event": "progress", "section": 3, "n": 0, "of": 1, "chunk": 9, "chunks": 10, "percent": 90.0, "rate_cps": 70.0, "eta_basis": "measured", "eta_s": 10, "elapsed_s": 5.0}"#,
        #"{"t": 6.0, "event": "chunk_flagged", "section": 3, "chunk": 9, "issues": ["repeated words"], "text": "said she"}"#,
        #"{"t": 7.0, "event": "encoding", "percent": 50}"#,
        doneLine,
    ])
    try await waitUntil { monitor.state == .done }

    #expect(monitor.state == .done && monitor.phase == .finished)
    #expect(monitor.result?.output == "/tmp/Book.m4b" && monitor.outputURL?.lastPathComponent == "Book.m4b")
    #expect(monitor.percent == 100)
    #expect(monitor.rateHistory.map(\.rateCps) == [60, 70])
    #expect(monitor.flaggedChunks.map(\.id) == ["3-9"])
    #expect(monitor.qa == QAStats(checked: 10, redone: 1, flagged: 0))
    #expect(monitor.encodingPercent == 50)
    #expect(monitor.etaText == nil)
    #expect(!monitor.isKeepingAwake)
}

/// Same file, pid unknown (old job status without pid): start at the latest run boundary.
@MainActor
@Test func monitorFollowsLatestRunWithoutPid() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write(run(pid: 111, title: "Old run", percents: [10], rate: 50) + [cancelledLine]
                     + run(pid: 222, title: "New run", percents: [40, 50], rate: 60))

    let monitor = JobMonitor(jobId: "abc", jobDir: folder.dir, pid: nil, initialState: .queued,
                             client: nil, options: .testing)
    monitor.start()
    try await waitUntil { monitor.latestProgress?.percent == 50 }
    #expect(monitor.state == .running && monitor.title == "New run")
    #expect(monitor.rateHistory.count == 2 && monitor.cancelMessage == nil)
    #expect(monitor.pid == 222)   // learned from run_start
}

/// A run just started with `convert --detach` (pid 333) has not written anything yet; the file still ends
/// with the previous run's terminal event. The monitor must wait for run 333 instead of reporting "done".
@MainActor
@Test func monitorWaitsForItsOwnRun() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write(run(pid: 222, title: "Previous run", percents: [100], rate: 60) + [doneLine])

    let monitor = JobMonitor(jobId: "abc", jobDir: folder.dir, pid: 333, initialState: .queued,
                             title: "Book", client: nil, options: .testing)
    monitor.start()
    try await Task.sleep(for: .milliseconds(150))
    #expect(monitor.state == .queued && monitor.result == nil && monitor.latestProgress == nil)

    try folder.append(run(pid: 333, title: "Book", percents: [5], rate: 40)
                      + [#"{"t": 3.0, "event": "error", "message": "Not enough disk space: 2 GB free, about 5 GB needed."}"#])
    try await waitUntil { monitor.state == .failed }
    #expect(monitor.state == .failed)
    #expect(monitor.errorMessage == "Not enough disk space: 2 GB free, about 5 GB needed.")
    #expect(monitor.rateHistory.map(\.rateCps) == [40])
}

/// A finished job is replayed once (latest run only) and keeps the engine's final state.
@MainActor
@Test func monitorReplaysFinishedJob() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write(run(pid: 1, title: "Old", percents: [10], rate: 50, flagged: true) + [cancelledLine]
                     + run(pid: 2, title: "Book", percents: [50, 100], rate: 80) + [doneLine])
    let status = JobStatus(jobId: "abc", title: "Book", state: "done", jobDir: folder.dir.path)

    let monitor = JobMonitor(status: status, client: nil, options: .testing)
    #expect(!monitor.isLive)
    monitor.start()
    try await waitUntil { monitor.phase == .finished }
    #expect(monitor.state == .done && monitor.result?.durationS == 600)
    #expect(monitor.rateHistory.map(\.rateCps) == [80, 80] && monitor.flaggedChunks.isEmpty)
}

/// A job killed mid-run has no terminal event: the replay keeps the engine's "interrupted" state.
@MainActor
@Test func monitorReplayOfInterruptedJob() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write(run(pid: 7, title: "Book", percents: [30], rate: 55))
    let status = JobStatus(jobId: "abc", title: "Book", state: "interrupted", jobDir: folder.dir.path)

    let monitor = JobMonitor(status: status, client: nil, options: .testing)
    monitor.start()
    try await waitUntil { monitor.phase == .finished }
    #expect(monitor.state == .interrupted)
    #expect(monitor.latestProgress?.percent == 30)
    #expect(monitor.errorMessage == JobMonitor.interruptedMessage)
}

/// Feeding the real convert fixture through the reducer.
@MainActor
@Test func monitorAppliesConvertFixture() throws {
    let monitor = JobMonitor(jobId: "e8800d406374", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 73938,
                             initialState: .running, client: nil, options: .testing)
    var phases: [JobPhase] = []
    for ev in try Fixtures.events("convert_events.jsonl") {
        monitor.apply(ev)
        if phases.last != monitor.phase { phases.append(monitor.phase) }
    }
    #expect(monitor.state == .done)
    #expect(monitor.plan?.sections?.count == 3)
    #expect(monitor.rateHistory.count == 13)     // the first progress has no rate yet (basis "saved")
    #expect(monitor.qa?.checked == 99 && monitor.flaggedCount == 0)
    #expect(phases.contains(.loadingModel) && phases.contains(.assembling) && phases.last == .finished)
    #expect(monitor.result?.freedWorkMb == 26.4)
}

// MARK: - Tailer start points

@Test func runStartIndexPrefersRunStartThenJobStart() throws {
    func ev(_ name: String, pid: Int? = nil) -> EngineEvent { EngineEvent(event: name, pid: pid) }
    let modern = [ev("run_start", pid: 1), ev("job_start"), ev("cancelled"), ev("run_start", pid: 2), ev("job_start"), ev("progress")]
    #expect(EventTailer.runStartIndex(in: modern) == 3)
    #expect(EventTailer.runStartIndex(in: modern, pid: 1) == 0)
    #expect(EventTailer.runStartIndex(in: modern, pid: 9) == nil)
    let legacy = [ev("job_start"), ev("error"), ev("job_start"), ev("progress")]
    #expect(EventTailer.runStartIndex(in: legacy) == 2)
    #expect(EventTailer.latestRun(of: legacy).map(\.event) == ["job_start", "progress"])
    #expect(EventTailer.latestRun(of: [ev("progress")]).count == 1)
}

@Test func tailerLatestRunSkipsOldTerminalEvent() async throws {
    let folder = try JobFolder()
    defer { folder.remove() }
    try folder.write([
        #"{"event": "run_start", "pid": 1}"#, #"{"event": "error", "message": "old"}"#,
        #"{"event": "run_start", "pid": 2}"#, #"{"event": "progress", "percent": 10}"#,
    ])
    let tailer = EventTailer(url: folder.events, pollInterval: .milliseconds(20))
    let writer = Task {
        try await Task.sleep(for: .milliseconds(100))
        try folder.append([#"{"event": "done", "output": "/x.m4b"}"#])
    }
    var seen: [String] = []
    for await ev in tailer.events(from: .latestRun) { seen.append(ev.event ?? "?") }
    try await writer.value
    #expect(seen == ["run_start", "progress", "done"])
}
