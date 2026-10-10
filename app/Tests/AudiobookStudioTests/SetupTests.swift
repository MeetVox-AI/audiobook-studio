import Foundation
import Testing
@testable import AudiobookStudio

@MainActor
private func makeModel() -> AppModel {
    let defaults = UserDefaults(suiteName: "setup-tests-\(UUID().uuidString)")!
    let model = AppModel(settings: AppSettings(defaults: defaults))
    model.setup.commandRunner = { _, _, _ in CommandResult(status: 0, output: "") }   // never a real command
    return model
}

/// A fake runner that records the commands it was asked to run.
private final class FakeCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var select = CommandResult(status: 0, output: "/Library/Developer/CommandLineTools")
    var git = CommandResult(status: 0, output: "git version 2.50.1")
    var called: [String] { lock.withLock { calls } }
    var runner: CommandRunner {
        { [self] exe, args, _ in
            lock.withLock { calls.append(([exe] + args).joined(separator: " ")) }
            return exe.hasSuffix("xcode-select") ? select : git
        }
    }
}

private let licenseText = "You have not agreed to the Xcode license. Please resolve this by running: sudo xcodebuild -license accept"

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
            == "Russian needs High quality (Qwen3-TTS 1.7B); add it here or later in Models.")
    #expect(SetupCatalog.coverageMessage(uncovered: ["ru", "ar", "ja"], suggestion: ["qwen3", "voxtral"])
            == "Russian, Japanese and Arabic need High quality (Qwen3-TTS 1.7B) and Voxtral 4B; add it here or later in Models.")
    #expect(SetupCatalog.coverageMessage(uncovered: [], suggestion: []) == nil)
}

@MainActor
@Test func aLanguageNoTickedVoiceSpeaksAddsItsEngineAutomatically() {
    // Coverage is enforced: the old "warn and suggest" note can no longer appear because the engine is added.
    let flow = makeModel().setup
    flow.languages = ["en", "ru"]
    flow.chosen = ["kokoro"]
    #expect(flow.autoEngines == ["qwen3"] && flow.chosen == ["kokoro", "qwen3"] && flow.userChosen == ["kokoro"])
    #expect(flow.uncoveredLanguages.isEmpty && flow.coverageNote == nil)
    #expect(flow.coverage(of: "kokoro")?.missing == ["ru"] && flow.coverage(of: "qwen3")?.missing == [])
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
    // Models + engine tools + the reference voices of English (3 MB; the total now includes them).
    #expect(abs(flow.neededGB - (0.35 + 6.2 + SetupCatalog.engineGB + 0.003)) < 0.001)
    // Every model of the fixture is installed: nothing left to download but the engine and the voices.
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models)
    #expect(flow.modelsToDownload.isEmpty)
    #expect(abs(flow.neededGB - (SetupCatalog.engineGB + 0.003)) < 0.001)
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

// MARK: - Tiers, sizes and licences

@Test func theThreeTiersAreNamedSizedAndLicensed() {
    let tiers = SetupCatalog.tiers
    #expect(tiers.map(\.title) == ["Quick", "High quality", "Very high quality"])
    #expect(tiers.map(\.id) == ["kokoro", "qwen3", "fish"])
    #expect(tiers.map(\.modelName) == ["Kokoro 82M", "Qwen3-TTS 1.7B", "Fish Audio S2 Pro"])
    #expect(tiers.map(\.gb) == [0.35, 6.2, 6.7])
    #expect(tiers.map(\.licenseName) == ["Apache-2.0", "Apache-2.0", "Fish Audio Research Licence"])
    #expect(tiers.map(\.noncommercial) == [false, false, true])
    #expect(tiers.map(\.licenseSummary) == ["Free for any use", "Free for any use", "Personal use only"])
    // Other options and the quality check.
    let voxtral = SetupCatalog.other.first
    #expect(SetupCatalog.other.count == 1 && voxtral?.id == "voxtral" && voxtral?.gb == 2.5)
    #expect(voxtral?.noncommercial == true && voxtral?.licenseName == "CC BY-NC 4.0")
    #expect(SetupCatalog.quality.id == "whisper" && SetupCatalog.quality.gb == 1.6 && SetupCatalog.quality.licenseName == "MIT")
    #expect(SetupCatalog.quality.noncommercial == false && SetupCatalog.engineGB == 1.5)
    #expect(SetupCatalog.all.map(\.id) == ["kokoro", "qwen3", "fish", "whisper", "voxtral"])
    // The wording of the old setup is gone.
    let text = SetupCatalog.all.flatMap { [$0.title, $0.detail, $0.listTitle ?? ""] } + Array(SetupCatalog.engineNames.values)
    #expect(!text.contains { $0.contains("Fast") || $0.contains("Best quality") || $0.contains("More voices") })
    // Each tier names its model in the progress list and in sentences.
    #expect(SetupCatalog.engineNames["qwen3"] == "High quality (Qwen3-TTS 1.7B)")
    #expect(tiers.allSatisfy { $0.listTitle?.contains($0.modelName) == true })
}

@Test func timeEstimatesAreStatedForEachTier() {
    let t = SetupCatalog.tiers
    #expect(t[0].speed == "About 14-18x faster than listening" && t[0].bookTime == "A 10-hour book takes about 40 minutes.")
    #expect(t[1].speed?.contains("3-5x") == true && t[1].speed?.contains("2.4x when cloning") == true)
    #expect(t[1].bookTime == "A 10-hour book takes about 2-4 hours.")
    #expect(t[2].speed == "Slower than listening (about 0.56x)" && t[2].bookTime == "A 10-hour book takes about 18 hours.")
    #expect(SetupCatalog.other[0].speed?.contains("1.7-1.9x") == true)
    #expect(SetupCatalog.benchmarkNote.contains("M4 Pro") && SetupCatalog.benchmarkNote.contains("10-hour"))
}

@Test func sizesAreWrittenInGigabytes() {
    #expect(SetupCatalog.sizeText(0.35) == "0.35 GB" && SetupCatalog.sizeText(6.2) == "6.2 GB" && SetupCatalog.sizeText(1.5) == "1.5 GB")
    #expect(SetupCatalog.sizeText(0.003) == "3 MB" && SetupCatalog.sizeText(14.253) == "14.3 GB")
}

@Test func totalDownloadCountsOnlyWhatIsNotInstalled() {
    func total(_ chosen: Set<String>, installed: Set<String> = [], engine: Bool = true, languages: Int = 0) -> Double {
        SetupCatalog.downloadGB(chosen: chosen, installed: installed, engineInstalled: engine, languageCount: languages)
    }
    #expect(total([]) == 0)
    #expect(abs(total(["kokoro"]) - 0.35) < 1e-9)
    #expect(abs(total(["kokoro", "qwen3"]) - 6.55) < 1e-9)
    // Nothing installed: the engine tools are part of it.
    #expect(abs(total(["qwen3"], engine: false) - 7.7) < 1e-9)
    // Some installed: they are skipped.
    #expect(abs(total(["kokoro", "qwen3"], installed: ["qwen3"]) - 0.35) < 1e-9)
    #expect(total(["kokoro"], installed: ["kokoro"]) == 0)
    // With the quality check and the reference voices of three languages.
    #expect(abs(total(["qwen3", "whisper"], engine: false, languages: 3) - (6.2 + 1.6 + 1.5 + 0.009)) < 1e-9)
    #expect(abs(total(["fish", "voxtral", "whisper", "kokoro", "qwen3"]) - (6.7 + 2.5 + 1.6 + 0.35 + 6.2)) < 1e-9)
    // Models only: the quality check is not a voice model.
    #expect(abs(SetupCatalog.narrationGB(chosen: ["qwen3", "whisper"], installed: []) - 6.2) < 1e-9)
}

@MainActor
@Test func theFlowTotalFollowsTheChoices() throws {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    flow.languages = ["en", "fr"]
    flow.chosen = ["qwen3", "whisper"]
    #expect(abs(flow.neededGB - (6.2 + 1.6 + 1.5 + 0.006)) < 1e-9)
    #expect(abs(flow.modelsGB - 6.2) < 1e-9)
    flow.chosen = []
    // English and French need some voice: High quality is added as the default (6.2 GB).
    #expect(flow.chosen == ["qwen3"] && abs(flow.neededGB - (6.2 + 1.5 + 0.006)) < 1e-9)
}

@Test func freeSpaceWarningWhenItWillNotFit() {
    #expect(SetupCatalog.spaceWarning(neededGB: 8.1, freeGB: 5) == "Not enough free space: the download needs 8.1 GB and 5 GB is free.")
    #expect(SetupCatalog.spaceWarning(neededGB: 8.1, freeGB: 9) == nil)
    #expect(SetupCatalog.spaceWarning(neededGB: 0, freeGB: 0) == nil)
}

@MainActor
@Test func theFlowWarnsWhenTheDownloadDoesNotFit() throws {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    flow.chosen = ["qwen3", "fish"]
    #expect(flow.spaceWarning == nil || flow.prerequisites.freeGB < Int(flow.neededGB))   // depends on this Mac's free space
    #expect(SetupCatalog.spaceWarning(neededGB: flow.neededGB, freeGB: 1)?.contains("1 GB is free") == true)
}

@MainActor
@Test func nonCommercialModelsNeedOneAcknowledgementBeforeInstall() {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    // The install itself is otherwise possible on a prepared Mac.
    func ready() -> Bool { SetupPrerequisites(appleSilicon: true, homebrew: true, freeGB: 500).blocker(neededGB: flow.neededGB) == nil }
    flow.chosen = ["kokoro", "qwen3"]
    #expect(flow.modelsNeedingAcknowledgement.isEmpty && !flow.acknowledgementPending && ready())   // free licences: no box
    flow.chosen = ["qwen3", "fish"]
    #expect(flow.modelsNeedingAcknowledgement.map(\.id) == ["fish"])
    #expect(flow.acknowledgementPending && !flow.canInstall)
    flow.setLicenseAcknowledged(true)
    #expect(flow.licenseAcknowledged && !flow.acknowledgementPending)
    // Adding another non-commercial model needs the box again.
    flow.chosen.insert("voxtral")
    #expect(flow.acknowledgementPending)
    flow.setLicenseAcknowledged(true)
    #expect(!flow.acknowledgementPending)
    flow.setLicenseAcknowledged(false)
    #expect(flow.acknowledgementPending)
}

@MainActor
@Test func aNonCommercialModelAlreadyOnDiskNeedsNoAcknowledgement() throws {
    let model = makeModel()
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models)   // all installed
    model.setup.chosen = ["fish", "voxtral"]
    #expect(model.setup.modelsNeedingAcknowledgement.isEmpty && !model.setup.acknowledgementPending)
}

@MainActor
@Test func startingTheInstallRecordsTheAcknowledgement() async throws {
    let (model, _, folder) = try flowWithStub("", list: "languages_list.json", selected: ["en"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let flow = model.setup
    // Fixture models are installed: make fish "not installed" so it is downloaded and acknowledged.
    var models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    for i in models.indices where models[i].engine == "fish" { models[i].installed = false }
    model.preload(models: models)
    flow.chosen = ["fish"]
    #expect(flow.acknowledgementPending && !model.settings.hasAcknowledgedLicense(engine: "fish"))
    flow.setLicenseAcknowledged(true)
    flow.start()
    #expect(model.settings.hasAcknowledgedLicense(engine: "fish"))   // the licence sheet is not shown again
    flow.cancel()
    await flow.waitForWork()
}

@MainActor
@Test func nothingIsAcknowledgedWithoutTheBox() async throws {
    let (model, _, folder) = try flowWithStub("", list: "languages_list.json", selected: ["en"])
    defer { try? FileManager.default.removeItem(at: folder) }
    model.setup.chosen = ["kokoro"]            // a free licence: no box, nothing recorded
    model.setup.start()
    await model.setup.waitForWork()
    #expect(model.settings.acknowledgedLicenses.isEmpty)
}

// MARK: - Languages decide the models

@Test func singleCoverLanguagesForceTheirEngine() {
    func need(_ langs: Set<String>, have: Set<String> = []) -> Set<String> { Set(SetupCatalog.required(languages: langs, have: have)) }
    #expect(need(["nl"]) == ["voxtral"] && need(["ar"]) == ["voxtral"])
    for code in ["ru", "zh", "ja", "ko"] { #expect(need([code]) == ["qwen3"], "\(code)") }
    #expect(need(["nl", "ru"]) == ["voxtral", "qwen3"])
    #expect(need(["en", "ar", "ja", "nl"]) == ["voxtral", "qwen3"])
    // Voxtral forced for Dutch also speaks Hindi: Quick is not added for it.
    #expect(need(["nl", "hi"]) == ["voxtral"])
    #expect(need(["en"]) == ["qwen3"] && need(["en", "fr"]) == ["qwen3"])
}

@Test func severalCandidatesFollowThePreferenceOrder() {
    func need(_ langs: Set<String>, have: Set<String> = []) -> [String] { SetupCatalog.required(languages: langs, have: have) }
    #expect(SetupCatalog.candidates(for: "de") == ["qwen3", "voxtral"] && need(["de"]) == ["qwen3"])
    #expect(SetupCatalog.candidates(for: "hi") == ["kokoro", "voxtral"] && need(["hi"]) == ["kokoro"])
    for code in ["es", "it", "pt"] { #expect(SetupCatalog.candidates(for: code) == ["qwen3", "kokoro", "voxtral"] && need([code]) == ["qwen3"]) }
    #expect(SetupCatalog.candidates(for: "fr") == ["qwen3", "kokoro", "voxtral", "fish"])
    // A narrator that is already there covers it: nothing is added.
    #expect(need(["de"], have: ["voxtral"]).isEmpty && need(["hi"], have: ["voxtral"]).isEmpty)
    // Russian forces Qwen3-TTS, which also covers German: no second engine.
    #expect(need(["ru", "de"]) == ["qwen3"])
}

@MainActor
@Test func forcedEnginesAreSelectedAndLocked() {
    let flow = makeModel().setup
    flow.userChosen = ["kokoro"]
    flow.languages = ["en", "nl", "ar"]
    #expect(flow.chosen == ["kokoro", "voxtral"] && flow.autoEngines == ["voxtral"])
    #expect(flow.lockLabel("voxtral") == "Required for Arabic and Dutch")
    // Unticking is refused, with the reason (also kept for VoiceOver).
    let why = flow.toggleModel("voxtral")
    #expect(why?.contains("Arabic and Dutch can only be narrated by Voxtral 4B") == true && flow.notice == why)
    #expect(flow.chosen.contains("voxtral"))
    // Even when the person ticked it themselves.
    flow.userChosen.insert("voxtral")
    #expect(flow.toggleModel("voxtral") != nil && flow.chosen.contains("voxtral"))
    // Other cards can still be toggled; a successful change clears the message.
    #expect(flow.toggleModel("kokoro") == nil && flow.notice == nil && !flow.chosen.contains("kokoro"))
    // Dropping the languages unlocks it, unless it is then the only voice for English: tick another first.
    flow.toggleLanguage("nl"); flow.toggleLanguage("ar")
    #expect(flow.lockLabel("voxtral") == "Needed for English")
    flow.toggleModel("kokoro")
    #expect(flow.lockLabel("voxtral") == nil && flow.toggleModel("voxtral") == nil && !flow.chosen.contains("voxtral"))
}

@MainActor
@Test func theLastNarratorOfAMultiCoverLanguageCannotBeRemovedButCanBeSwapped() {
    let flow = makeModel().setup
    flow.userChosen = []
    flow.languages = ["de"]
    #expect(flow.chosen == ["qwen3"] && flow.lockLabel("qwen3") == "Needed for German")
    #expect(flow.toggleModel("qwen3")?.contains("German would have no voice without High quality") == true)
    // Select another engine that speaks German first: the automatic one is released, and can then be unticked.
    #expect(flow.toggleModel("voxtral") == nil)
    #expect(flow.chosen == ["voxtral"] && flow.autoEngines.isEmpty)
    #expect(flow.lockLabel("voxtral") == "Needed for German")
}

@MainActor
@Test func automaticEnginesAreReleasedAndTickedOnesAreKept() {
    let flow = makeModel().setup
    flow.userChosen = ["kokoro"]
    flow.languages = ["en", "ru", "ar"]
    #expect(flow.chosen == ["kokoro", "qwen3", "voxtral"])
    flow.toggleLanguage("ar")
    #expect(flow.chosen == ["kokoro", "qwen3"])                    // Voxtral released
    flow.toggleLanguage("ru")
    #expect(flow.chosen == ["kokoro"] && flow.userChosen == ["kokoro"])   // Qwen3-TTS released; Quick was ticked and stays
    // A ticked engine is never removed by a language change, even when no language needs it.
    flow.toggleModel("fish")
    flow.languages = ["en", "nl"]
    flow.languages = ["en"]
    #expect(flow.chosen == ["kokoro", "fish"])
}

@MainActor
@Test func installedEnginesForceNothing() throws {
    let model = makeModel()
    model.preload(models: try Fixtures.decode("models_list.json", as: ModelList.self).models)   // all installed
    let flow = model.setup
    flow.userChosen = []
    flow.languages = ["nl", "ru", "ar"]
    #expect(flow.autoEngines.isEmpty && flow.chosen.isEmpty && flow.lockedLanguages("voxtral").isEmpty)
    // Uninstalled Voxtral: Dutch and Arabic need it again, Russian is still covered by the installed Qwen3-TTS.
    var models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    for i in models.indices where models[i].engine == "voxtral" { models[i].installed = false }
    model.preload(models: models)
    #expect(flow.autoEngines == ["voxtral"])
}

@MainActor
@Test func anAutoAddedVoxtralNeedsTheLicenceAcknowledgementAndTotalsFollow() {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    flow.userChosen = ["qwen3"]
    flow.languages = ["en"]
    let before = flow.neededGB
    #expect(flow.modelsNeedingAcknowledgement.isEmpty && !flow.acknowledgementPending)
    flow.toggleLanguage("nl")
    #expect(flow.chosen == ["qwen3", "voxtral"])
    #expect(flow.modelsNeedingAcknowledgement.map(\.id) == ["voxtral"] && flow.acknowledgementPending && !flow.canInstall)
    // 2.5 GB for Voxtral plus 3 MB of Dutch voices.
    #expect(abs(flow.neededGB - (before + 2.5 + 0.003)) < 1e-9)
    #expect(flow.lockedLanguages("voxtral") == ["nl"])
    flow.setLicenseAcknowledged(true)
    #expect(!flow.acknowledgementPending)
    // Removing Dutch releases Voxtral: the requirement and the size go away at once.
    flow.toggleLanguage("nl")
    #expect(flow.modelsNeedingAcknowledgement.isEmpty && !flow.acknowledgementPending)
    #expect(abs(flow.neededGB - before) < 1e-9)
}

@MainActor
@Test func quickForANonEnglishLanguageIsMarkedDraftQuality() {
    let flow = makeModel().setup
    flow.userChosen = []
    flow.languages = ["hi"]
    #expect(flow.chosen == ["kokoro"] && flow.lockLabel("kokoro") == "Needed for Hindi")
    #expect(flow.quickDraftNote == "Draft quality for Hindi. Voxtral 4B (under Other options) gives better voices.")
    flow.languages = ["es"]
    #expect(flow.chosen == ["qwen3"] && flow.quickDraftNote == nil)
    flow.userChosen = ["kokoro"]
    #expect(flow.chosen == ["kokoro"])      // Qwen3-TTS is not added: Quick covers Spanish
    #expect(flow.quickDraftNote == "Draft quality for Spanish. High quality or Voxtral 4B (under Other options) gives better voices.")
    flow.languages = ["fr"]
    #expect(flow.quickDraftNote == "Draft quality for French. High quality or Voxtral 4B (under Other options) gives better voices.")
}

@Test func theLanguagesStepSummarisesWhatTheSelectionNeeds() {
    func text(_ langs: Set<String>, installed: Set<String> = []) -> String { SetupCatalog.needsSummary(languages: langs, installed: installed) }
    #expect(text(["en"]) == "Any voice quality works for English.")
    #expect(text(["en", "fr"]) == "Any voice quality works for English and French.")
    #expect(text(["en", "ru", "ja", "nl"])
            == "Your languages need: Qwen3-TTS 1.7B (6.2 GB) for Russian and Japanese; Voxtral 4B (2.5 GB, personal use only) for Dutch. You can review this before anything downloads.")
    #expect(text(["nl", "ar"]) == "Your languages need: Voxtral 4B (2.5 GB, personal use only) for Arabic and Dutch. You can review this before anything downloads.")
    #expect(text(["hi"]) == "Your languages need: Kokoro 82M (0.35 GB, draft quality) for Hindi. You can review this before anything downloads.")
    #expect(text(["ru"], installed: ["qwen3"]) == "Voices already on this Mac cover Russian. You can review this before anything downloads.")
}

@MainActor
@Test func theFlowExposesTheLanguageSummary() {
    let flow = makeModel().setup
    #expect(flow.languageNeedsSummary == "Any voice quality works for English.")
    flow.toggleLanguage("ar")
    #expect(flow.languageNeedsSummary.contains("Voxtral 4B (2.5 GB, personal use only) for Arabic") && !flow.languageNeedsSummary.contains("English"))
}

@MainActor
@Test func progressListNamesTheTiersWithTheirSizes() async throws {
    let (model, _, folder) = try flowWithStub("", list: "languages_list.json", selected: ["en"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let flow = model.setup
    flow.chosen = ["kokoro"]
    flow.start()
    await flow.waitForWork()
    let item = try #require(flow.items.first { $0.id == "model-kokoro" })
    #expect(item.title == "Quick (Kokoro 82M)" && item.sizeLabel == "0.35 GB")
    #expect(flow.downloadedSummary == "Quick (Kokoro 82M)")
}


// MARK: - Developer tools preflight

@Test func preflightRecognisesTheDeveloperToolsState() {
    let fake = FakeCommands()
    #expect(SetupPrerequisites.developerToolsState(run: fake.runner).state == .ready)
    #expect(fake.called == ["/usr/bin/xcode-select -p", "/usr/bin/git --version"])

    let missing = FakeCommands()
    missing.select = CommandResult(status: 2, output: "xcode-select: error: unable to get active developer directory")
    #expect(SetupPrerequisites.developerToolsState(run: missing.runner).state == .commandLineToolsMissing)
    #expect(missing.called == ["/usr/bin/xcode-select -p"])   // git is never run: its shim would open Apple's installer

    let license = FakeCommands()
    license.git = CommandResult(status: 69, output: licenseText)
    let result = SetupPrerequisites.developerToolsState(run: license.runner)
    #expect(result.state == .licenseNotAccepted && result.note == licenseText)

    let other = FakeCommands()
    other.git = CommandResult(status: 1, output: "dyld: Library not loaded")
    let unknown = SetupPrerequisites.developerToolsState(run: other.runner)
    #expect(unknown.state == .ready && unknown.note == "dyld: Library not loaded")   // does not block, keeps the message

    let shout = FakeCommands()
    shout.git = CommandResult(status: 69, output: "XCODEBUILD -LICENSE required")
    #expect(SetupPrerequisites.developerToolsState(run: shout.runner).state == .licenseNotAccepted)
}

@Test func currentUsesTheInjectedRunner() {
    let fake = FakeCommands()
    fake.git = CommandResult(status: 69, output: licenseText)
    #expect(SetupPrerequisites.current(run: fake.runner).developerTools == .licenseNotAccepted)
    let skipped = FakeCommands()
    _ = SetupPrerequisites.current(run: skipped.runner, checkTools: false)
    #expect(skipped.called.isEmpty)
}

@MainActor
@Test func developerToolsGateTheInstallInOrder() {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    flow.chosen = ["kokoro"]
    func set(tools: DeveloperTools, brew: Bool) {
        flow.overridePrerequisitesForTesting(SetupPrerequisites(appleSilicon: true, homebrew: brew, freeGB: 500, developerTools: tools))
    }
    set(tools: .ready, brew: true)
    #expect(flow.canInstall && flow.firstNotice == nil)
    set(tools: .ready, brew: false)
    #expect(!flow.canInstall && flow.firstNotice == .homebrew)
    set(tools: .licenseNotAccepted, brew: true)
    #expect(!flow.canInstall && flow.firstNotice == .license)
    set(tools: .commandLineToolsMissing, brew: true)
    #expect(!flow.canInstall && flow.firstNotice == .commandLineTools)
    set(tools: .licenseNotAccepted, brew: false)
    #expect(!flow.canInstall && flow.firstNotice == .license)   // the licence before Homebrew
    set(tools: .commandLineToolsMissing, brew: false)
    #expect(!flow.canInstall && flow.firstNotice == .commandLineTools)   // the tools before everything
}

@MainActor
@Test func checkAgainUpdatesTheStateThroughTheRunner() {
    let model = makeModel()
    model.settings.enginePathOverride = "/nonexistent/audiobook-engine"
    let flow = model.setup
    let fake = FakeCommands()
    fake.git = CommandResult(status: 69, output: licenseText)
    flow.commandRunner = fake.runner
    flow.recheckPrerequisites()
    #expect(flow.prerequisites.developerTools == .licenseNotAccepted && flow.needsDeveloperTools)
    fake.git = CommandResult(status: 0, output: "git version 2.50.1")   // the person accepted the licence
    flow.recheckPrerequisites()
    #expect(flow.prerequisites.developerTools == .ready && !flow.needsDeveloperTools)
}

@Test func installFailuresAreClassified() {
    #expect(DeveloperTools.issue(message: licenseText) == .licenseNotAccepted)
    #expect(DeveloperTools.issue(message: "The setup stopped before it finished.", logTail: "x\n" + licenseText) == .licenseNotAccepted)
    #expect(DeveloperTools.issue(message: "YOU HAVE NOT AGREED TO THE XCODE LICENSE. RUN SUDO XCODEBUILD -LICENSE ACCEPT") == .licenseNotAccepted)
    #expect(DeveloperTools.issue(message: "git is missing. Run: xcode-select --install") == .commandLineToolsMissing)
    #expect(DeveloperTools.issue(message: "No developer tools were found") == .commandLineToolsMissing)
    #expect(DeveloperTools.issue(message: "Install the Command Line Tools first") == .commandLineToolsMissing)
    #expect(DeveloperTools.issue(message: "Only 3 GB free; the voice models need about 12 GB.") == nil)
    #expect(DeveloperTools.issue(message: "Homebrew is missing.", logTail: "curl: (6) Could not resolve host") == nil)
    #expect(DeveloperTools.issue(message: "Accept the licence", logTail: "") == nil)   // a licence of something else
}

@MainActor
@Test func theFailureScreenExplainsTheLicenseAndTryAgainChecksFirst() async throws {
    let model = makeModel()
    let flow = model.setup
    flow.overrideErrorForTesting(EngineError(message: licenseText, stderrTail: "==> Installing tools\n" + licenseText))
    let fake = FakeCommands()
    fake.git = CommandResult(status: 69, output: licenseText)
    flow.commandRunner = fake.runner
    #expect(flow.failureIssue == .licenseNotAccepted)

    flow.tryAgain()   // still blocked: the preflight ran, nothing was started
    #expect(fake.called.count == 2 && !flow.isWorking && flow.error != nil && flow.failureIssue == .licenseNotAccepted)

    fake.git = CommandResult(status: 0, output: "git version 2.50.1")
    flow.tryAgain()   // fixed: the install is retried
    #expect(fake.called.count == 4)
    // The retry's task cannot start before this main-actor test suspends: cancelling now stops it before any work.
    flow.cancel()
    await flow.waitForWork()

    flow.overrideErrorForTesting(EngineError(message: "Only 3 GB free."))
    #expect(flow.failureIssue == nil)
}

@Test func theSystemRunnerIsInertInsideTests() {
    #expect(SystemCommands.isUnderTest)
}
