import Foundation
import Testing
@testable import AudiobookStudio

@MainActor
private func makeModel() -> AppModel {
    let defaults = UserDefaults(suiteName: "setup-tests-\(UUID().uuidString)")!
    return AppModel(settings: AppSettings(defaults: defaults))
}

@MainActor
@Test func languagesKeepAtLeastOne() {
    let flow = makeModel().setup
    flow.languages = ["en"]
    flow.toggleLanguage("en")
    #expect(flow.languages == ["en"])
    flow.toggleLanguage("fr")
    #expect(flow.languages == ["en", "fr"])
    flow.toggleLanguage("en")
    #expect(flow.languages == ["fr"])
}

@MainActor
@Test func referenceVoicesFollowLanguagesAndCloningEngines() {
    let flow = makeModel().setup
    flow.languages = ["en", "fr"]
    flow.chosen = ["kokoro"]
    #expect(flow.voiceIds.isEmpty)
    flow.chosen = ["kokoro", "qwen3"]
    #expect(Set(flow.voiceIds) == Set(SetupCatalog.referenceVoices["en"]! + SetupCatalog.referenceVoices["fr"]!))
    flow.languages = ["fr"]
    #expect(flow.voiceIds == SetupCatalog.referenceVoices["fr"])
}

@MainActor
@Test func downloadSizeCountsOnlyWhatIsMissing() throws {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    flow.chosen = ["kokoro", "qwen3"]
    #expect(!flow.engineInstalled)
    #expect(abs(flow.neededGB - (0.35 + 6.2 + SetupCatalog.engineGB)) < 0.001)
    // Every model of the fixture is installed: nothing left to download but the engine.
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models)
    #expect(flow.modelsToDownload.isEmpty)
    #expect(abs(flow.neededGB - SetupCatalog.engineGB) < 0.001)
}

@Test func prerequisitesExplainWhatIsInTheWay() {
    let ok = SetupPrerequisites(appleSilicon: true, homebrew: true, freeGB: 100)
    #expect(ok.blocker(neededGB: 8) == nil)
    #expect(SetupPrerequisites(appleSilicon: false, homebrew: true, freeGB: 100).blocker(neededGB: 8)?.contains("Apple silicon") == true)
    let tight = SetupPrerequisites(appleSilicon: true, homebrew: true, freeGB: 5).blocker(neededGB: 7.2)
    #expect(tight?.contains("5 GB free") == true && tight?.contains("8 GB") == true)
}

@MainActor
@Test func skippingTheSetupIsRememberedAndFinishingIsNot() {
    let defaults = UserDefaults(suiteName: "setup-tests-\(UUID().uuidString)")!
    let model = AppModel(settings: AppSettings(defaults: defaults))
    #expect(model.settings.setupState == .notStarted)
    model.setup.present()
    #expect(model.setup.isPresented)
    model.setup.dismiss()
    #expect(!model.setup.isPresented && model.settings.setupState == .skipped)
    #expect(AppSettings(defaults: defaults).setupState == .skipped)
    // A skipped setup can be opened again.
    model.setup.present(from: .models)
    #expect(model.setup.isPresented && model.setup.step == .models)
}

@MainActor
@Test func noInstalledModelMeansSetupIsNeeded() throws {
    let model = makeModel()
    #expect(!model.hasNoModels)   // the engine has not answered yet: nothing to say
    var models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self), models: models)
    #expect(!model.hasNoModels)
    for i in models.indices { models[i].installed = false }
    model.preload(models: models)
    #expect(model.hasNoModels && model.needsSetup)
}

// MARK: - Installer

private func stubScript(_ body: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stub-install-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("install-engine.sh")
    try Data("#!/bin/bash\n\(body)\n".utf8).write(to: url)
    return url
}

@MainActor
@Test func installerCountsStepsAndPassesTheEnvironment() async throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)")
    let script = try stubScript("""
    echo "==> one"; echo "==> two"; echo "==> three"
    echo "$NO_MODELS $AUDIOBOOK_PREFIX" > '\(marker.path)'
    echo "==> Done. Open Audiobook Studio."
    """)
    let installer = EngineInstaller()
    try await installer.install(script: script)
    #expect(installer.markers == EngineInstaller.stepTitles.count + 1 && !installer.isRunning)
    let seen = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(seen == "1 \(EngineClient.installPrefix)")
}

@MainActor
@Test func installerReportsTheScriptsOwnError() async throws {
    let script = try stubScript(#"echo "==> one"; echo "Error: Homebrew is missing." >&2; exit 1"#)
    do {
        try await EngineInstaller().install(script: script)
        Issue.record("The install should have failed")
    } catch {
        let e = EngineError(error)
        #expect(e.message == "Homebrew is missing." && e.stderrTail.contains("Error: Homebrew"))
    }
}

@MainActor
@Test func installerCanBeCancelled() async throws {
    let script = try stubScript("echo '==> one'; sleep 30")
    let installer = EngineInstaller()
    let run = Task { try await installer.install(script: script) }
    try await Task.sleep(for: .milliseconds(600))
    installer.cancel()
    await #expect(throws: CancellationError.self) { try await run.value }
}
