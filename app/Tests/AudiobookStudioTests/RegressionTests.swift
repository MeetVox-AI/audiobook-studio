import Foundation
import Testing
@testable import AudiobookStudio

// Regression tests for review findings (job re-attach, cancelled loads, GPU wait phase, licence gate,
// relative book paths, median speed, time left, samples of a closed book). Engine commands are small
// /bin/sh stubs; the audiobook engine itself is never started. Every model gets its own UserDefaults suite
// and an engine path that is a stub or does not exist.

private func tempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes an executable `/bin/sh` script named audiobook-engine into `folder` and returns its path.
private func stubEngine(in folder: URL, _ body: String) throws -> String {
    let url = folder.appendingPathComponent("audiobook-engine")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

@MainActor
private func makeModel(enginePath: String? = nil) throws -> (AppModel, () -> Void) {
    let suite = "AudiobookStudioRegressionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath ?? "/nonexistent/audiobook-engine-\(UUID().uuidString)"
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RegressionTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    model.monitorOptions = .testing
    return (model, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    })
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { break }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func event(_ json: String) throws -> EngineEvent {
    try EngineJSON.decoder.decode(EngineEvent.self, from: Data(json.utf8))
}

private func appendLines(_ lines: [String], to url: URL) throws {
    let data = Data(lines.map { $0 + "\n" }.joined().utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        try h.seekToEnd()
        try h.write(contentsOf: data)
        try h.close()
    } else {
        try data.write(to: url)
    }
}

/// One run of job "abc" in events.jsonl, narrating up to `percent`.
private func runLines(pid: Int, percent: Double) -> [String] {
    [
        #"{"t": 0.0, "event": "run_start", "job_id": "abc", "pid": \#(pid)}"#,
        #"{"t": 0.1, "event": "job_start", "job_id": "abc", "title": "Book", "engine": "kokoro", "voice": "af_heart", "total_chars": 1000}"#,
        #"{"t": 0.2, "event": "section_start", "section": 3, "n": 0, "of": 1, "title": "I", "chunks": 10, "chars": 1000}"#,
        #"{"t": 1.0, "event": "progress", "section": 3, "n": 0, "of": 1, "chunk": 4, "chunks": 10, "percent": \#(percent), "rate_cps": 50.0, "eta_s": 100, "eta_low_s": 90, "eta_high_s": 120, "eta_basis": "measured", "elapsed_s": 1.0}"#,
    ]
}

private let cancelledLine = #"{"t": 9.0, "event": "cancelled", "message": "Stopped. Finished chunks are cached; run again to resume."}"#

/// Lines a stub wrote to `file` (one per call), empty when it was never run.
private func lines(of file: URL) -> [String] {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

// MARK: - Re-attach

/// A job viewed while cancelled (replay monitor), then resumed by another process (terminal, second app):
/// the next `jobs list` reports it running with a new pid, and the app must follow that run live.
@MainActor
@Test func reattachFollowsAJobThatRunsAgainAfterItsMonitorFinished() async throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    let dir = try tempFolder("job")
    defer { try? FileManager.default.removeItem(at: dir) }
    let events = dir.appendingPathComponent("events.jsonl")
    try appendLines(runLines(pid: 111, percent: 40) + [cancelledLine], to: events)

    let cancelled = JobStatus(jobId: "abc", title: "Book", engine: "kokoro", state: "cancelled", pid: 111, jobDir: dir.path)
    model.preload(jobs: [cancelled])
    let replay = try #require(model.attachMonitor(jobId: "abc"))
    try await waitUntil { replay.phase == .finished }
    #expect(model.liveState(of: cancelled) == .cancelled)

    try appendLines(runLines(pid: 222, percent: 45), to: events)
    var running = cancelled
    running.state = "running"
    running.pid = 222
    model.preload(jobs: [running])
    model.reattachRunningJobs()

    let live = try #require(model.monitors["abc"])
    #expect(live !== replay)
    #expect(live.isLive)
    try await waitUntil { live.latestProgress?.percent == 45 }
    #expect(live.latestProgress?.percent == 45)
    #expect(model.liveState(of: running) == .running)
    #expect(model.activeJobCount == 1)
    model.reattachRunningJobs()
    #expect(model.monitors["abc"] === live)     // still idempotent

    // That run ends; a job list read just before it ended still says running, with the same pid: kept.
    try appendLines([cancelledLine], to: events)
    try await waitUntil { live.state == .cancelled }
    model.preload(jobs: [running])
    model.reattachRunningJobs()
    #expect(model.monitors["abc"] === live)
    #expect(model.liveState(of: running) == .cancelled)
}

// MARK: - Loads cancelled by a screen

/// Leaving the Jobs / Models / Settings screen cancels its `.task`: that stops the engine, it is not an error.
@MainActor
@Test func leavingAScreenWhileItLoadsIsNotAnEngineError() async throws {
    let folder = try tempFolder("stub-slow")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (model, cleanup) = try makeModel(enginePath: try stubEngine(in: folder, "exec sleep 30"))
    defer { cleanup() }

    let load = Task { await model.refreshJobs() }
    try await waitUntil { model.loading.contains(.jobs) }
    try await Task.sleep(for: .milliseconds(200))   // the engine process is running
    load.cancel()
    await load.value
    #expect(model.errors[.jobs] == nil)
    #expect(!model.loading.contains(.jobs))

    // A real failure is still reported.
    let failing = try tempFolder("stub-failing")
    defer { try? FileManager.default.removeItem(at: failing) }
    model.settings.enginePath = try stubEngine(in: failing, """
        cat '\(Fixtures.directory.appendingPathComponent("error.json").path)'
        exit 2
        """)
    await model.refreshJobs()
    #expect(model.errors[.jobs]?.message == "File not found: /nonexistent.epub")
}

// MARK: - GPU wait

/// The engine writes `queued` while it waits for the GPU and `job_start` once it holds it. A resume with
/// every chapter already assembled has no section_start: the phase must not stay on "waiting".
@MainActor
@Test func gettingTheGPUEndsTheWaitingPhase() throws {
    let monitor = JobMonitor(jobId: "abc", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 5, initialState: .queued,
                             client: nil, options: .testing)
    monitor.apply(try event(#"{"event": "run_start", "pid": 5}"#))
    monitor.apply(try event(#"{"event": "queued", "message": "Another job is using the GPU; waiting."}"#))
    #expect(monitor.phase == .waitingForGPU("Another job is using the GPU; waiting."))
    monitor.apply(try event(#"{"event": "job_start", "title": "Book"}"#))
    #expect(monitor.state == .running)
    #expect(monitor.phase == .starting)
    #expect(monitor.statusText == "Starting…")
    monitor.apply(try event(#"{"event": "section_skip", "section": 3, "n": 0, "reason": "already assembled"}"#))
    #expect(monitor.phase == .starting)
    monitor.apply(try event(#"{"event": "assembling"}"#))
    #expect(monitor.phase == .assembling)

    // Only the wait is cleared: job_start leaves any other phase alone.
    let other = JobMonitor(jobId: "abc", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 5, initialState: .running,
                           client: nil, options: .testing)
    other.apply(try event(#"{"event": "model_loading"}"#))
    other.apply(try event(#"{"event": "job_start"}"#))
    #expect(other.phase == .loadingModel)
}

// MARK: - Licence gate

/// With the engine list not loaded (slow or failed `engines`), a saved Voxtral/Fish default must not run
/// unacknowledged; commercial engines are not held back.
@MainActor
@Test func nonCommercialEngineWaitsForTheEngineListBeforeItsFirstUse() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    let info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/Books/book.epub"), info: info, coverURL: nil)
    let fish = VoiceSelection(engineId: "fish", refVoiceId: "user-me")
    let voxtral = VoiceSelection(engineId: "voxtral", presetId: "fr_female")
    let kokoro = VoiceSelection(engineId: "kokoro", presetId: "af_heart")

    #expect(model.engineList == nil)
    #expect(model.bookBlocker(voice: fish, forConversion: false)?.message.contains("non-commercial") == true)
    #expect(model.bookBlocker(voice: fish, forConversion: true)?.message.contains("non-commercial") == true)
    #expect(model.bookBlocker(voice: voxtral, forConversion: true)?.message.contains("non-commercial") == true)
    #expect(model.bookBlocker(voice: kokoro, forConversion: true) == nil)
    model.settings.acknowledgeLicense(engine: "fish")
    #expect(model.bookBlocker(voice: fish, forConversion: true) == nil)

    // Once the engines are loaded, the licence sheet takes over.
    model.settings.acknowledgedLicenses = []
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self))
    #expect(model.bookBlocker(voice: fish, forConversion: true) == nil)
    #expect(model.bookLicenseToAcknowledge(voice: fish)?.id == "fish")
}

/// Resume is a first use too (e.g. a Fish job started from the terminal): it must not run the engine
/// before the licence is acknowledged, and runs it as before once it is.
@MainActor
@Test func resumeDoesNotRunANonCommercialEngineBeforeItsLicenceIsAcknowledged() async throws {
    let folder = try tempFolder("stub-resume")
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls.txt")
    let jobDir = folder.appendingPathComponent("f1").path
    let stub = try stubEngine(in: folder, """
        echo "$@" >> '\(calls.path)'
        echo '{"event": "detached", "job_id": "f1", "job_dir": "\(jobDir)", "pid": 999999, "events": "\(jobDir)/events.jsonl"}'
        """)
    let (model, cleanup) = try makeModel(enginePath: stub)
    defer { cleanup() }
    let job = JobStatus(jobId: "f1", book: "/Books/novel.epub", title: "Novel", engine: "fish", voice: "user-me",
                        state: "cancelled", argv: ["convert", "/Books/novel.epub", "--engine", "fish", "--ref-voice", "user-me"],
                        jobDir: jobDir)

    // Engines not loaded yet.
    await #expect(throws: EngineError.self) { try await model.resumeJob(job) }
    // Engines loaded, licence not acknowledged.
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self))
    await #expect(throws: EngineError.self) { try await model.resumeJob(job) }
    #expect(lines(of: calls).isEmpty)

    model.settings.acknowledgeLicense(engine: "fish")
    let monitor = try await model.resumeJob(job)
    monitor.stop()
    #expect(monitor.jobId == "f1")
    #expect(lines(of: calls).first?.hasPrefix("convert /Books/novel.epub --engine fish --ref-voice user-me") == true)
}

// MARK: - Relative book paths

/// `convert book.epub` typed in a terminal records "book.epub". The app runs the engine from another folder,
/// so it must not resume or reopen that path (it would be another file, or none).
@MainActor
@Test func jobsStartedWithARelativeBookPathAreNotResumedOrReopened() async throws {
    let folder = try tempFolder("stub-relative")
    defer { try? FileManager.default.removeItem(at: folder) }
    let calls = folder.appendingPathComponent("calls.txt")
    let jobDir = folder.appendingPathComponent("r1").path
    let stub = try stubEngine(in: folder, """
        echo "$@" >> '\(calls.path)'
        echo '{"event": "detached", "job_id": "r1", "job_dir": "\(jobDir)", "pid": 999999, "events": "\(jobDir)/events.jsonl"}'
        """)
    let (model, cleanup) = try makeModel(enginePath: stub)
    defer { cleanup() }
    let relative = JobStatus(jobId: "r1", book: "book.epub", title: "Book", engine: "kokoro", voice: "af_heart",
                             state: "interrupted", argv: ["convert", "book.epub", "--engine", "kokoro", "--voice", "af_heart"],
                             jobDir: jobDir)

    #expect(relative.bookURL == nil)
    do {
        _ = try await model.resumeJob(relative)
        Issue.record("Resuming a relative book path should be refused")
    } catch {
        #expect(EngineError(error).message.contains("“book.epub”"))
    }
    await model.convertAgain(relative)
    #expect(model.draft == nil && model.bookError == nil)
    #expect(lines(of: calls).isEmpty)

    // Absolute paths resume as before.
    var absolute = relative
    absolute.book = "/Books/book.epub"
    absolute.argv = ["convert", "/Books/book.epub", "--engine", "kokoro", "--voice", "af_heart"]
    #expect(absolute.bookURL?.path == "/Books/book.epub")
    let monitor = try await model.resumeJob(absolute)
    monitor.stop()
    #expect(lines(of: calls).first == "convert /Books/book.epub --engine kokoro --voice af_heart --detach")
}

// MARK: - Median speed

private func speed(_ cps: Double, _ x: Double) -> SpeedMeasurement { SpeedMeasurement(charsPerS: cps, realtimeX: x) }

/// The engine's `saved_rate` is Python's `statistics.median`: the mean of the two middle values for an even count.
@Test func medianSpeedMatchesTheEngineForAnEvenNumberOfVoices() {
    let list = EngineList(engines: [], measured: [
        "fish|a": speed(10, 0.5), "fish|b": speed(20, 0.9),
        "kokoro|x": speed(100, 6), "kokoro|y": speed(150, 9), "kokoro|z": speed(400, 20),
    ])
    #expect(list.rate(engine: "fish", voice: nil) == 15)
    #expect(list.rate(engine: "fish", voice: "unmeasured") == 15)
    #expect(list.rate(engine: "fish", voice: "a") == 10)       // the exact voice wins
    #expect(list.rate(engine: "kokoro", voice: nil) == 150)    // odd count: the middle value
    #expect(list.rate(engine: "qwen3", voice: nil) == nil)
}

/// The totals bar estimate and the slow-engine warning use that same median speed.
@MainActor
@Test func estimateAndSlowWarningUseTheEngineMedian() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    var engines = try Fixtures.decode("engines.json", as: EngineList.self)
    engines.measured = ["fish|a": speed(10, 0.5), "fish|b": speed(20, 0.9)]
    model.preload(engines: engines)
    let voice = VoiceSelection(engineId: "fish", refVoiceId: "unmeasured")

    let estimate = try #require(model.estimate(chars: 15_000, voice: voice))
    #expect(estimate.charsPerSecond == 15)
    #expect(estimate.seconds == 1_000)
    let warning = try #require(model.bookSlowEngineWarning(voice: voice, chars: 15_000))
    #expect(warning.message.contains("This selection would take \(Formatters.estimate(1_000))"))
}

// MARK: - Time left

/// Once narration ends no progress arrives: the last ETA must not stay on screen through assembling/encoding.
@MainActor
@Test func timeLeftIsOnlyShownWhileNarrating() throws {
    let monitor = JobMonitor(jobId: "abc", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 222, initialState: .running,
                             client: nil, options: .testing)
    for line in runLines(pid: 222, percent: 99) { monitor.apply(try event(line)) }
    #expect(monitor.phase == .synthesizing)
    #expect(monitor.etaText == "about 2 min")
    #expect(JobText.progressLine(monitor: monitor).contains("time left"))

    monitor.apply(try event(#"{"t": 2.0, "event": "assembling"}"#))
    #expect(monitor.etaText == nil)
    monitor.apply(try event(#"{"t": 3.0, "event": "encoding", "percent": 44}"#))
    #expect(monitor.etaText == nil)
    #expect(monitor.phase.title == "Encoding the audiobook (44%)")
}

// MARK: - Samples of a closed book

/// Closing the book stops its running sample (no screen shows it any more, and it holds the GPU);
/// a benchmark is not tied to the book and keeps running.
@MainActor
@Test func closingTheBookStopsItsRunningSample() async throws {
    let folder = try tempFolder("stub-sample")
    defer { try? FileManager.default.removeItem(at: folder) }
    let pids = folder.appendingPathComponent("pids.txt")
    let stub = try stubEngine(in: folder, """
        echo "$1 $$" >> '\(pids.path)'
        exec sleep 30
        """)
    let (model, cleanup) = try makeModel(enginePath: stub)
    defer { cleanup() }
    let info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/Books/book.epub"), info: info, coverURL: nil)
    let voice = VoiceSelection(engineId: "kokoro", presetId: "af_heart")

    let sample = try #require(model.startSample(voice: voice, section: nil, seconds: 120))
    let benchmark = model.startBenchmark(voice: voice, language: "en")
    try await waitUntil { lines(of: pids).count == 2 }
    func pid(_ command: String) -> Int? {
        lines(of: pids).first { $0.hasPrefix(command + " ") }.flatMap { Int($0.split(separator: " ")[1]) }
    }
    let samplePid = try #require(pid("sample"))
    let benchmarkPid = try #require(pid("benchmark"))
    #expect(JobMonitor.isProcessAlive(samplePid) && JobMonitor.isProcessAlive(benchmarkPid))

    model.closeBook()
    #expect(sample.phase == .cancelled)
    try await waitUntil { !JobMonitor.isProcessAlive(samplePid) }
    #expect(!JobMonitor.isProcessAlive(samplePid))
    #expect(benchmark.isRunning && JobMonitor.isProcessAlive(benchmarkPid))

    benchmark.cancel()
    try await waitUntil { !JobMonitor.isProcessAlive(benchmarkPid) }
    #expect(!JobMonitor.isProcessAlive(benchmarkPid))
}
