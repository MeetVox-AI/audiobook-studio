import Foundation
import Testing
@testable import AudiobookStudio

// Updating an engine that is older than the app needs: detection from the engine's API level, the silent update
// when automatic updates are on, and running the installer. The installer and the engine are /bin/sh stubs;
// nothing is downloaded, and the real installer can never run (every model gets a stub script).

private func tempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func executable(_ url: URL, _ body: String) throws {
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// An engine stub: `engines` reports API 2 once `updated` exists (the installer stub creates it), else no API
/// (an engine from before API levels). Every other command answers with an empty list.
private func stubEngine(in folder: URL) throws -> (path: String, updatedFlag: URL) {
    let flag = folder.appendingPathComponent("updated")
    let engine = folder.appendingPathComponent("audiobook-engine")
    try executable(engine, """
    case "$1 $2" in
      engines*) if [ -f '\(flag.path)' ]; then echo '{"engines": [], "measured": {}, "api": 3}'; else echo '{"engines": [], "measured": {}}'; fi ;;
      "models list") echo '{"models": []}' ;;
      "voices list") echo '{"voices": []}' ;;
      "jobs list") echo '{"jobs": []}' ;;
      "languages list") echo '{"languages": []}' ;;
      "cache info") echo '{"chunks_bytes": 0, "jobs_bytes": 0, "path": "/tmp"}' ;;
      *) echo '{}' ;;
    esac
    """)
    return (engine.path, flag)
}

@MainActor
private func makeModel(enginePath: String, managed: Bool = true) throws -> (AppModel, AppSettings, () -> Void) {
    let suite = "AudiobookStudioEngineUpdateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("EngineUpdateTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    model.managedEnginePath = managed ? enginePath : "/somewhere/else/audiobook-engine"
    model.automaticUpdates = { false }
    model.engineInstallerScript = URL(fileURLWithPath: "/usr/bin/false")   // never the real installer
    return (model, settings, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    })
}

private func engineList(api: Int?) -> EngineList { EngineList(engines: [], measured: [:], api: api) }

// MARK: - Detection

@Test func engineListsDecodeWithAndWithoutAnAPILevel() throws {
    let old = try EngineJSON.decoder.decode(EngineList.self, from: Data(#"{"engines": [], "measured": {}}"#.utf8))
    let new = try EngineJSON.decoder.decode(EngineList.self, from: Data(#"{"engines": [], "measured": {}, "api": 2}"#.utf8))
    #expect(old.api == nil && new.api == 2)
}

@Test @MainActor func anEngineWithoutAnAPILevelNeedsAnUpdate() throws {
    let (model, _, cleanup) = try makeModel(enginePath: "/e/audiobook-engine")
    defer { cleanup() }
    #expect(!model.engineNeedsUpdate)                          // nothing known yet: no false alarm
    model.preload(engines: engineList(api: nil))
    #expect(model.engineAPI == 1 && model.engineNeedsUpdate)  // the 0.3.3 engines already installed
    model.preload(engines: engineList(api: AppModel.requiredEngineAPI))
    #expect(!model.engineNeedsUpdate)
    model.preload(engines: engineList(api: AppModel.requiredEngineAPI + 1))
    #expect(!model.engineNeedsUpdate)                          // a newer engine is fine
}

// MARK: - Silent update

@Test func automaticUpdatesFollowThePersonsChoice() throws {
    let suite = "AudiobookStudioAutoUpdateTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!AppModel.automaticUpdatesEnabled(defaults: defaults))   // the test bundle has no update feed
    defaults.set(true, forKey: "SUAutomaticallyUpdate")
    #expect(AppModel.automaticUpdatesEnabled(defaults: defaults))
    defaults.set(false, forKey: "SUAutomaticallyUpdate")              // turned off in Settings
    #expect(!AppModel.automaticUpdatesEnabled(defaults: defaults))
}

@Test @MainActor func withAutomaticUpdatesTheEngineUpdatesSilentlyOnceNothingRuns() async throws {
    let folder = try tempFolder("EngineAutoUpdate")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, flag) = try stubEngine(in: folder)
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, "echo '==> Getting the engine'; touch '\(flag.path)'")
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    model.engineInstallerScript = script
    await model.refreshEngines()
    #expect(model.engineNeedsUpdate)

    model.autoUpdateEngineIfNeeded()                          // automatic updates off: nothing happens
    try await Task.sleep(for: .milliseconds(300))             // the update would start in a task: give it time
    #expect(!model.isUpdatingEngine && !FileManager.default.fileExists(atPath: flag.path))

    model.automaticUpdates = { true }
    var raw = try JSONSerialization.jsonObject(with: Fixtures.data("jobs_list.json")) as! [String: Any]
    var jobs = raw["jobs"] as! [[String: Any]]
    jobs[0]["state"] = "running"
    raw["jobs"] = jobs
    let running = try EngineJSON.decoder.decode(JobList.self, from: JSONSerialization.data(withJSONObject: raw)).jobs
    model.preload(jobs: running)
    model.autoUpdateEngineIfNeeded()                          // a conversion runs: it waits
    try await Task.sleep(for: .milliseconds(300))
    #expect(!model.isUpdatingEngine && !FileManager.default.fileExists(atPath: flag.path))

    model.preload(jobs: [])                                   // the conversion finished
    model.autoUpdateEngineIfNeeded()
    for _ in 0..<200 where model.engineNeedsUpdate || model.isUpdatingEngine { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.engineNeedsUpdate && model.engineUpdateError == nil)
}

@Test @MainActor func aFailedSilentUpdateIsNotRetriedOnItsOwn() async throws {
    let folder = try tempFolder("EngineAutoUpdateFail")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, _) = try stubEngine(in: folder)
    let count = folder.appendingPathComponent("runs")
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, "echo x >> '\(count.path)'; echo 'Error: Could not reach github.com.' >&2; exit 1")
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    model.engineInstallerScript = script
    model.automaticUpdates = { true }
    await model.refreshEngines()
    model.autoUpdateEngineIfNeeded()
    for _ in 0..<200 where model.engineUpdateError == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.engineUpdateError?.message == "Could not reach github.com.")
    model.autoUpdateEngineIfNeeded()                          // the banner offers Try Again instead of looping
    try await Task.sleep(for: .milliseconds(200))
    #expect(try String(contentsOf: count, encoding: .utf8).split(separator: "\n").count == 1)
}

@Test @MainActor func anEngineTheAppDidNotInstallIsNeverUpdatedByIt() async throws {
    let folder = try tempFolder("EngineUpdateUnmanaged")
    defer { try? FileManager.default.removeItem(at: folder) }
    let ran = folder.appendingPathComponent("installer-ran")
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, "touch '\(ran.path)'")
    let (model, _, cleanup) = try makeModel(enginePath: "/dev/checkout/audiobook-engine", managed: false)
    defer { cleanup() }
    model.preload(engines: engineList(api: nil))
    model.automaticUpdates = { true }
    model.autoUpdateEngineIfNeeded()                          // not even silently
    try await Task.sleep(for: .milliseconds(300))
    await model.updateEngine(script: script)
    #expect(model.engineUpdateError?.message.contains("not installed by Audiobook Studio") == true)
    #expect(!FileManager.default.fileExists(atPath: ran.path))
}

// MARK: - Running the update

@Test @MainActor func updatingRunsTheInstallerThenReloadsTheEngine() async throws {
    let folder = try tempFolder("EngineUpdateRun")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, flag) = try stubEngine(in: folder)
    let env = folder.appendingPathComponent("env.txt")
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, """
    echo "NO_MODELS=$NO_MODELS" > '\(env.path)'
    echo "==> Installing tools"; echo "==> Getting the engine"; echo "==> Setting up the Python environment"
    touch '\(flag.path)'
    echo "==> Done. Open Audiobook Studio."
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    await model.refreshEngines()
    #expect(model.engineNeedsUpdate)

    await model.updateEngine(script: script)

    #expect(model.engineUpdateError == nil)
    #expect(!model.engineNeedsUpdate && model.engineAPI == AppModel.requiredEngineAPI)
    #expect(!model.isUpdatingEngine)
    #expect(try String(contentsOf: env, encoding: .utf8).contains("NO_MODELS=1"))   // never re-downloads models
}

@Test @MainActor func aFailedUpdateKeepsTheInstallersReason() async throws {
    let folder = try tempFolder("EngineUpdateFail")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, _) = try stubEngine(in: folder)
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, """
    echo "==> Getting the engine"
    echo "Error: Could not reach github.com." >&2
    exit 1
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    await model.refreshEngines()

    await model.updateEngine(script: script)

    #expect(model.engineUpdateError?.message == "Could not reach github.com.")
    #expect(model.engineNeedsUpdate)                           // still offered
}

@Test @MainActor func anUpdateThatLeavesAnOldEngineSaysSo() async throws {
    let folder = try tempFolder("EngineUpdateStillOld")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, _) = try stubEngine(in: folder)
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, "echo '==> Getting the engine'")    // succeeds but changes nothing
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    await model.refreshEngines()

    await model.updateEngine(script: script)

    #expect(model.engineUpdateError?.message.hasPrefix("The engine was updated but is still older") == true)
}

@Test @MainActor func noUpdateWhileAConversionRuns() async throws {
    let folder = try tempFolder("EngineUpdateBusy")
    defer { try? FileManager.default.removeItem(at: folder) }
    let ran = folder.appendingPathComponent("installer-ran")
    let script = folder.appendingPathComponent("install.sh")
    try executable(script, "touch '\(ran.path)'")
    let (model, _, cleanup) = try makeModel(enginePath: "/e/audiobook-engine")
    defer { cleanup() }
    var raw = try JSONSerialization.jsonObject(with: Fixtures.data("jobs_list.json")) as! [String: Any]
    var jobs = raw["jobs"] as! [[String: Any]]
    jobs[0]["state"] = "running"
    raw["jobs"] = jobs
    let list = try EngineJSON.decoder.decode(JobList.self, from: JSONSerialization.data(withJSONObject: raw))
    model.preload(engines: engineList(api: nil), jobs: list.jobs)
    #expect(model.activeJobCount == 1)
    #expect(model.engineUpdateBlocker == "A conversion is running. The engine can be updated when it finishes.")

    await model.updateEngine(script: script)

    #expect(!FileManager.default.fileExists(atPath: ran.path))
    #expect(model.engineUpdateError?.message.hasPrefix("A conversion is running") == true)
}
