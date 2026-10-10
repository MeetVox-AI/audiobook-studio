import Foundation
import Testing
@testable import AudiobookStudio

// EngineClient runs real subprocesses here: small shell scripts standing in for `audiobook-engine` that replay
// the real engine outputs from Fixtures/. The audiobook engine itself is never started.

/// Writes an executable `/bin/sh` script and returns its path.
private func stubEngine(_ body: String) throws -> String {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("stub-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("audiobook-engine")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

/// Shell command that prints a fixture file.
private func catFixture(_ name: String) -> String {
    "cat '\(Fixtures.directory.appendingPathComponent(name).path)'"
}

@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test func engineClientDecodesTheLastLineOfACommand() async throws {
    let path = try stubEngine("""
        echo '{"event": "model_loading"}'
        \(catFixture("engines.json"))
        """)
    let list = try await EngineClient(path: path).json(["engines"], as: EngineList.self)
    #expect(!list.engines.isEmpty)
    #expect(list.engines.contains { $0.id == "kokoro" })
}

@Test func engineFailureCarriesTheEngineMessageAndTheStderrTail() async throws {
    let path = try stubEngine("""
        echo 'Traceback: could not read the book' >&2
        sleep 0.3
        \(catFixture("error.json"))
        exit 2
        """)
    do {
        _ = try await EngineClient(path: path).json(["inspect", "/nonexistent.epub"], as: BookInfo.self)
        Issue.record("The command should have failed")
    } catch {
        let e = EngineError(error)
        #expect(e.message == "File not found: /nonexistent.epub")
        #expect(e.stderrTail.contains("Traceback: could not read the book"))
        #expect(!e.engineMissing)
    }
}

@Test func errorEventWithExitCodeZeroStillFails() async throws {
    let path = try stubEngine(catFixture("error.json"))
    await #expect(throws: EngineFailure.self) {
        _ = try await EngineClient(path: path).lines(["inspect", "/nonexistent.epub"])
    }
}

@Test func missingEngineIsReportedAsMissing() async throws {
    let path = "/nonexistent-\(UUID().uuidString)/audiobook-engine"
    do {
        _ = try await EngineClient(path: path).json(["engines"], as: EngineList.self)
        Issue.record("The command should have failed")
    } catch {
        #expect(EngineError(error).engineMissing)
    }
}

@MainActor
@Test func sampleRunFollowsTheEngineEventsToTheResult() async throws {
    let path = try stubEngine("""
        echo '{"event": "model_loading"}'
        echo '{"event": "model_loaded", "load_s": 1.0, "warmup_s": 0.5}'
        echo '{"event": "notice", "message": "Speech check skipped."}'
        \(catFixture("sample_events.jsonl"))
        """)
    let run = SampleRun(kind: .sample, voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart"), language: "en")
    var finishedRuns = 0
    run.onFinish = { _ in finishedRuns += 1 }
    run.start(client: EngineClient(path: path), arguments: ["sample", "/book.epub"])
    #expect(await eventually { !run.isRunning })
    #expect(run.phase == .finished)
    #expect(run.result?.event == "sample_done")
    #expect(run.modelLoadSeconds == 1.5)
    #expect(run.notices == ["Speech check skipped."])
    #expect(finishedRuns == 1)
}

@MainActor
@Test func stoppingAStreamStopsTheEngineProcess() async throws {
    // `exec` makes the long-running command keep the script's process id.
    let path = try stubEngine("""
        echo "{\\"event\\": \\"model_loading\\", \\"pid\\": $$}"
        exec sleep 20
        """)
    let (pids, pidSink) = AsyncStream<Int>.makeStream()
    let consumer = Task {
        for try await event in EngineClient(path: path).stream(["sample", "/book.epub"]) {
            if let pid = event.pid { pidSink.yield(pid) }
        }
    }
    var pid: Int?
    for await p in pids {
        pid = p
        break
    }
    let enginePid = try #require(pid)
    #expect(JobMonitor.isProcessAlive(enginePid))
    consumer.cancel()   // what EngineRun.cancel() does
    _ = await consumer.result
    #expect(await eventually { !JobMonitor.isProcessAlive(enginePid) })
}


@Test func childEnvironmentAddsHomebrewToFinderPath() {
    let env = EngineClient.childEnvironment(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me"])
    let path = env["PATH"]!.split(separator: ":").map(String.init)
    #expect(path.prefix(4) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])  // user order kept first
    #expect(path.contains("/opt/homebrew/bin") && path.contains("/usr/local/bin"))
    #expect(env["HOME"] == "/Users/me")
}

@Test func childEnvironmentDoesNotDuplicateFolders() {
    let env = EngineClient.childEnvironment(["PATH": "/opt/homebrew/bin:/usr/bin"])
    #expect(env["PATH"]!.components(separatedBy: "/opt/homebrew/bin").count == 2)
}

@Test func childEnvironmentWithoutPathStillHasSystemAndHomebrew() {
    let env = EngineClient.childEnvironment([:])
    #expect(env["PATH"]!.hasPrefix("/usr/bin:/bin") && env["PATH"]!.contains("/opt/homebrew/bin"))
}
