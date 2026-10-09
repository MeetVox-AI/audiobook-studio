import Foundation
import Testing
@testable import AudiobookStudio

// Regression tests that go through entry points added with the fixes (the quit hook, the licence check
// before Resume). Engine commands are /bin/sh stubs; the audiobook engine itself is never started.

private func tempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func stubEngine(in folder: URL, _ body: String) throws -> String {
    let url = folder.appendingPathComponent("audiobook-engine")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

@MainActor
private func makeModel(enginePath: String) throws -> (AppModel, () -> Void) {
    let suite = "AudiobookStudioRegressionAPITests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RegressionAPITests-\(UUID().uuidString)")
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

private func lines(of file: URL) -> [String] {
    ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

/// What the app delegate calls when the app quits: samples, previews, benchmarks and model downloads exist
/// only for the app's screens, so their engine processes are stopped (detached conversions are not touched).
@MainActor
@Test func quittingStopsSamplesBenchmarksAndModelDownloads() async throws {
    let folder = try tempFolder("stub-quit")
    defer { try? FileManager.default.removeItem(at: folder) }
    let pids = folder.appendingPathComponent("pids.txt")
    let stub = try stubEngine(in: folder, """
        case "$1 $2" in
          "models list") echo '{"models": []}' ;;
          "models download"|sample*|benchmark*) echo "$1 $$" >> '\(pids.path)'; exec sleep 30 ;;
          *) echo '{"event": "error", "message": "not used in this test"}'; exit 2 ;;
        esac
        """)
    let (model, cleanup) = try makeModel(enginePath: stub)
    defer { cleanup() }
    let info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/Books/book.epub"), info: info, coverURL: nil)
    let voice = VoiceSelection(engineId: "kokoro", presetId: "af_heart")

    let sample = try #require(model.startSample(voice: voice, section: nil, seconds: 120))
    let benchmark = model.startBenchmark(voice: voice, language: "en")
    let download = Task { try await model.downloadModel("kokoro") }
    try await waitUntil { lines(of: pids).count == 3 }
    let all = lines(of: pids).compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }
    #expect(all.count == 3)
    #expect(all.allSatisfy(JobMonitor.isProcessAlive))
    #expect(model.modelDownloads["kokoro"] != nil)

    model.stopScreenEngineWork()
    #expect(sample.phase == .cancelled && benchmark.phase == .cancelled)
    try await waitUntil { !all.contains(where: JobMonitor.isProcessAlive) }
    #expect(!all.contains(where: JobMonitor.isProcessAlive))
    _ = await download.result
    #expect(model.modelDownloads["kokoro"] == nil)
}

/// Cancelling the caller of `downloadModel` still stops the download, as before the quit hook existed.
@MainActor
@Test func cancellingTheDownloadCallerStillStopsTheDownload() async throws {
    let folder = try tempFolder("stub-download")
    defer { try? FileManager.default.removeItem(at: folder) }
    let pids = folder.appendingPathComponent("pids.txt")
    let stub = try stubEngine(in: folder, """
        case "$1 $2" in
          "models list") echo '{"models": []}' ;;
          "models download") echo "$1 $$" >> '\(pids.path)'; exec sleep 30 ;;
          *) echo '{"event": "error", "message": "not used in this test"}'; exit 2 ;;
        esac
        """)
    let (model, cleanup) = try makeModel(enginePath: stub)
    defer { cleanup() }
    let download = Task { try await model.downloadModel("kokoro") }
    try await waitUntil { lines(of: pids).count == 1 }
    let pid = try #require(lines(of: pids).first?.split(separator: " ").last.flatMap { Int($0) })
    #expect(JobMonitor.isProcessAlive(pid))
    download.cancel()
    _ = await download.result
    try await waitUntil { !JobMonitor.isProcessAlive(pid) }
    #expect(!JobMonitor.isProcessAlive(pid))
}

/// Resume shows the licence sheet of the job's engine first (JobsView, JobStoppedPanel).
@MainActor
@Test func resumeLicenceLookupAndRelativeBookPaths() throws {
    let (model, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine-\(UUID().uuidString)")
    defer { cleanup() }
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self))
    let fishJob = JobStatus(jobId: "f1", book: "/Books/novel.epub", engine: "fish", state: "cancelled", jobDir: "/tmp/f1")
    let kokoroJob = JobStatus(jobId: "k1", book: "book.epub", engine: "kokoro", state: "cancelled", jobDir: "/tmp/k1")
    #expect(model.licenseToAcknowledge(beforeResuming: fishJob)?.id == "fish")
    #expect(model.licenseToAcknowledge(beforeResuming: kokoroJob) == nil)
    model.settings.acknowledgeLicense(engine: "fish")
    #expect(model.licenseToAcknowledge(beforeResuming: fishJob) == nil)

    #expect(!fishJob.hasRelativeBookPath && kokoroJob.hasRelativeBookPath)
    #expect(!JobStatus(jobId: "x", state: "done", jobDir: "/tmp/x").hasRelativeBookPath)   // no book recorded
}

/// The blocker shown while the engine list is missing, and the rule that decides when a listed run is newer.
@MainActor
@Test func licenceBlockerAndNewerRunRule() throws {
    let (model, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine-\(UUID().uuidString)")
    defer { cleanup() }
    #expect(model.bookBlocker(voice: VoiceSelection(engineId: "fish"), forConversion: false) == .licenseNotShownYet)
    #expect(BookBlocker.licenseNotShownYet.fixDestination == nil)

    let finished = JobMonitor(jobId: "abc", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 111, initialState: .cancelled,
                              client: nil, options: .testing)
    let live = JobMonitor(jobId: "abc", jobDir: URL(fileURLWithPath: "/nonexistent"), pid: 111, initialState: .running,
                          client: nil, options: .testing)
    let runningNew = JobStatus(jobId: "abc", state: "running", pid: 222, jobDir: "/nonexistent")
    let runningSame = JobStatus(jobId: "abc", state: "running", pid: 111, jobDir: "/nonexistent")
    let runningNoPid = JobStatus(jobId: "abc", state: "running", jobDir: "/nonexistent")
    let done = JobStatus(jobId: "abc", state: "done", pid: 222, jobDir: "/nonexistent")
    #expect(AppModel.isNewerRun(runningNew, than: finished))
    #expect(!AppModel.isNewerRun(runningSame, than: finished))
    #expect(!AppModel.isNewerRun(runningNoPid, than: finished))
    #expect(!AppModel.isNewerRun(done, than: finished))
    #expect(!AppModel.isNewerRun(runningNew, than: live))   // a live monitor reconciles a new pid itself
}
