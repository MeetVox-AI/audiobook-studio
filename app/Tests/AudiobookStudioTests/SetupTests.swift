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
@Test func languageStepOffersTheWholeRegistryAndStartsWithEnglish() {
    // English is the only language on by default: the Mac's language is not used.
    let flow = makeModel().setup
    #expect(flow.languages == ["en"])
    #expect(LanguageRegistry.codes.count == 13 && LanguageRegistry.codes.allSatisfy { LanguageRegistry.builtin[$0] != nil })
    flow.toggleLanguage("xx")                       // not a registry language: ignored
    #expect(flow.languages == ["en"])
    flow.toggleLanguage("ar"); flow.toggleLanguage("ru")
    #expect(flow.languages == ["en", "ar", "ru"])
}

@MainActor
@Test func reopeningTheSetupStartsFromTheEnabledLanguages() throws {
    let model = makeModel()
    model.preload(languages: try Fixtures.decode("languages_list_variant.json", as: LanguageList.self).languages)
    let flow = model.setup
    flow.present()
    #expect(flow.languages == ["en", "fr", "es", "ru"])
    // An edit made in this session is kept when the window is reopened.
    flow.toggleLanguage("ru")
    flow.dismiss(); flow.present()
    #expect(flow.languages == ["en", "fr", "es"])
}

@Test func languagePlanAddsChosenThenRemovesTheRest() {
    #expect(SetupCatalog.languagePlan(selected: ["fr"], enabled: ["en"]) == .init(add: ["fr"], remove: ["en"]))
    #expect(SetupCatalog.languagePlan(selected: ["en"], enabled: ["en"]) == .init(add: ["en"], remove: []))
    #expect(SetupCatalog.languagePlan(selected: ["ru", "es", "en"], enabled: ["fr", "en", "ar"])
            == .init(add: ["en", "es", "ru"], remove: ["fr", "ar"]))
    // Never empty: a selection always has at least one language to add.
    #expect(!SetupCatalog.languagePlan(selected: ["nl"], enabled: ["en"]).add.isEmpty)
}

@Test func engineCoverageAndNotes() {
    #expect(SetupCatalog.uncovered(["en", "fr"], engines: ["kokoro"]).isEmpty)
    #expect(SetupCatalog.uncovered(["ru", "ar", "en"], engines: ["kokoro"]) == ["ru", "ar"])
    #expect(SetupCatalog.uncovered(["ru"], engines: []) == ["ru"])
    // Suggestions: the cheapest set that speaks everything missing.
    #expect(SetupCatalog.suggestion(for: ["ru"]) == ["qwen3"])
    #expect(SetupCatalog.suggestion(for: ["ar"]) == ["voxtral"])
    #expect(SetupCatalog.suggestion(for: ["nl"]) == ["voxtral"])
    #expect(Set(SetupCatalog.suggestion(for: ["ru", "ar"])) == ["qwen3", "voxtral"])
    #expect(SetupCatalog.suggestion(for: ["de"]) == ["voxtral"])        // smaller than qwen3
    #expect(SetupCatalog.suggestion(for: []).isEmpty)
    #expect(SetupCatalog.coverageMessage(uncovered: ["ru"], suggestion: ["qwen3"])
            == "Russian needs Best quality (Qwen3-TTS); add it here or later in Models.")
    #expect(SetupCatalog.coverageMessage(uncovered: ["ru", "ar", "ja"], suggestion: ["qwen3", "voxtral"])
            == "Russian, Japanese and Arabic need Best quality (Qwen3-TTS) and Voxtral; add it here or later in Models.")
    #expect(SetupCatalog.coverageMessage(uncovered: [], suggestion: []) == nil)
}

@MainActor
@Test func theFlowWarnsAboutUncoveredLanguagesAndNeverChoosesForThePerson() {
    let flow = makeModel().setup
    flow.languages = ["en", "ru"]
    flow.chosen = ["kokoro"]
    #expect(flow.uncoveredLanguages == ["ru"] && flow.suggestedEngines == ["qwen3"])
    #expect(flow.coverageNote?.hasPrefix("Russian needs Best quality (Qwen3-TTS)") == true)
    #expect(flow.chosen == ["kokoro"])                                   // only a suggestion
    #expect(flow.coverage(of: "kokoro")?.missing == ["ru"] && flow.coverage(of: "qwen3")?.missing == [])
    flow.acceptSuggestion()
    #expect(flow.chosen == ["kokoro", "qwen3"] && flow.coverageNote == nil)
    // A model already on disk counts as available.
    flow.chosen = []
    flow.languages = ["ar"]
    #expect(flow.coverageNote != nil)
}

@MainActor
@Test func installedModelsCountAsCoverage() throws {
    let model = makeModel()
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models)   // all installed
    model.setup.languages = ["ru", "ar"]
    model.setup.chosen = []
    #expect(model.setup.uncoveredLanguages.isEmpty)
}

@Test func engineTableMatchesTheEngineFixtures() throws {
    // engines.json: every engine, its size and its languages (the fixture lists only en and fr).
    for engine in try Fixtures.decode("engines.json", as: EngineList.self).engines {
        let spoken = try #require(SetupCatalog.engineLanguages[engine.id], "\(engine.id) missing from the catalog")
        #expect(Set(engine.languages).isSubset(of: Set(spoken)), "\(engine.id)")
        if let choice = SetupCatalog.choice(engine.id), let gb = engine.downloadGb { #expect(abs(choice.gb - gb) < 0.001, "\(engine.id) size") }
    }
    // languages_list.json: for each language, exactly the engines that speak it (all 13 languages).
    for info in try Fixtures.decode("languages_list.json", as: LanguageList.self).languages {
        let fromCatalog = Set(SetupCatalog.engineLanguages.filter { $0.value.contains(info.code) }.keys)
        #expect(fromCatalog == Set(info.engines.map(\.id)), "\(info.code)")
    }
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

// MARK: - Working step (fake engine)

private func engineStub(_ body: String, list: String) throws -> (path: String, log: URL, folder: URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("setup-engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = folder.appendingPathComponent("args.txt")
    let url = folder.appendingPathComponent("audiobook-engine")
    let script = """
    #!/bin/sh
    echo "$@" >> '\(log.path)'
    case "$1 $2" in
    \(body)
      "languages list") cat '\(Fixtures.directory.appendingPathComponent(list).path)' ;;
      *) echo '{}' ;;
    esac

    """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (url.path, log, folder)
}

@MainActor
private func flowWithStub(_ stub: String, list: String, selected: Set<String>) throws -> (AppModel, URL, URL) {
    let (path, log, folder) = try engineStub(stub, list: list)
    let model = makeModel()
    model.settings.enginePath = path
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models,
                  languages: try Fixtures.decode(list, as: LanguageList.self).languages)
    model.setup.languages = selected
    model.setup.chosen = ["kokoro"]
    return (model, log, folder)
}

@MainActor
@Test func workingStepAddsTheChosenLanguagesThenRemovesTheOthers() async throws {
    let (model, log, folder) = try flowWithStub("""
      "languages add") echo '{"event": "language_done", "code": "'"$3"'", "enabled": true, "ready": true, "voices_installed": 2}' ;;
      "languages remove") echo '{"event": "language_done", "code": "'"$3"'", "enabled": false}' ;;
    """, list: "languages_list_variant.json", selected: ["es", "fr"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let flow = model.setup
    #expect(flow.languagePlan == .init(add: ["fr", "es"], remove: ["en", "ru"]))
    flow.start()
    await flow.waitForWork()
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        .filter { $0.hasPrefix("languages add") || $0.hasPrefix("languages remove") }
    #expect(calls == ["languages add fr", "languages add es", "languages remove en", "languages remove ru"])
    #expect(flow.step == .done && flow.error == nil && flow.languageIssues.isEmpty)
    #expect(flow.items.allSatisfy { $0.state == .done })
    #expect(flow.items.map(\.id) == ["model-kokoro", "language-fr", "language-es", "language-off-en", "language-off-ru"])
}

@MainActor
@Test func aLanguageThatFailsDoesNotBlockFinishingAndIsKeptOnWhenItIsTheOnlyOne() async throws {
    let (model, log, folder) = try flowWithStub("""
      "languages add") echo '{"event": "error", "message": "Could not reach the voice library."}'; exit 2 ;;
      "languages remove") echo '{"event": "language_done", "code": "'"$3"'", "enabled": false}' ;;
    """, list: "languages_list.json", selected: ["es"])      // es is off in this list: nothing chosen is on
    defer { try? FileManager.default.removeItem(at: folder) }
    let flow = model.setup
    flow.start()
    await flow.waitForWork()
    let text = try String(contentsOf: log, encoding: .utf8)
    #expect(text.contains("languages add es") && !text.contains("languages remove"))   // never leaves zero languages on
    #expect(flow.step == .done && flow.error == nil)
    #expect(flow.languageIssues.map(\.id) == ["language-es", "language-off-en", "language-off-fr"])
    #expect(flow.languageIssues.first?.note == "Could not reach the voice library.")
    #expect(flow.model?.settings.setupState == .completed)
}

@MainActor
@Test func missingVoicesAreReportedWithARetry() async throws {
    let (model, _, folder) = try flowWithStub("""
      "languages add") echo '{"event": "language_done", "code": "'"$3"'", "enabled": true, "ready": true, "voice_errors": [{"id": "es_bad", "error": "offline"}], "voices_installed": 1}' ;;
    """, list: "languages_list_variant.json", selected: ["en", "fr", "es", "ru"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let flow = model.setup
    flow.start()
    await flow.waitForWork()
    #expect(flow.step == .done && flow.error == nil)
    let failed = flow.languageIssues
    #expect(failed.count == 4 && failed.allSatisfy { $0.note?.contains("es_bad") == true })
    // Try Again runs the unfinished steps again.
    flow.start()
    await flow.waitForWork()
    #expect(flow.step == .done)
}
