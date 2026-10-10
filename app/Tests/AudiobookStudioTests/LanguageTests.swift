import Foundation
import SwiftUI
import Testing
@testable import AudiobookStudio

// Languages on demand: decoding `languages list`, the enabled list that drives every picker, add / remove with
// engine stubs (/bin/sh scripts; the real engine never runs), blockers for a book in a language that is off
// or not ready, the Settings rows and the voices that speak a language with an accent.

private func tempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func stubEngine(in folder: URL, _ body: String) throws -> String {
    let url = folder.appendingPathComponent("audiobook-engine")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

private func languages(_ fixture: String = "languages_list.json") throws -> [LanguageInfo] {
    try Fixtures.decode(fixture, as: LanguageList.self).languages
}

@MainActor
private func makeModel(enginePath: String = "/nonexistent/audiobook-engine",
                       fixture: String? = "languages_list.json") throws -> (AppModel, AppSettings, () -> Void) {
    let suite = "AudiobookStudioLanguageTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LanguageTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self),
                  models: try Fixtures.decode("models_list.json", as: ModelList.self).models,
                  voices: try Fixtures.decode("voices_list.json", as: VoiceList.self).voices,
                  languages: try fixture.map { try languages($0) })
    return (model, settings, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    })
}

/// A book whose language is `code` (both the detected and the chosen one).
private func book(language code: String) throws -> BookDraft {
    var info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    info.language = code
    var d = BookDraft(url: URL(fileURLWithPath: "/books/\(code).epub"), info: info, coverURL: nil)
    d.language = code
    return d
}

// MARK: - Decoding

@Test func languagesListFixtureDecodes() throws {
    let all = try languages()
    #expect(all.map(\.code) == ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"])
    #expect(all.filter(\.enabled).map(\.code) == ["en", "fr"])
    let es = try #require(all.first { $0.code == "es" })
    #expect(es.name == "Spanish" && es.native == "Español" && !es.rtl && es.ready && es.recommended == "qwen3")
    #expect(es.engines.map(\.id) == ["qwen3", "kokoro", "voxtral"])
    let voxtral = try #require(es.engines.last)
    #expect(voxtral.noncommercial == true && voxtral.downloadGb == 2.5 && voxtral.nativePresets == true && voxtral.cloning == false)
    #expect(all.first { $0.code == "en" }?.voices == LanguageVoices(available: 6, installed: 0, bytes: 0, downloadMb: 3.1))
    #expect(es.needText == nil)                                   // ready
}

@Test func arabicIsRightToLeftWhereTheEngineSaysSo() throws {
    // The fixture was captured with rtl false for every language; the built-in registry knows Arabic is RTL.
    #expect(LanguageRegistry.builtin["ar"]?.rtl == true)
    let ar = LanguageInfo(code: "ar")
    #expect(ar.rtl && ar.native == "العربية" && ar.name == "Arabic")
}

@Test func languageDecodingToleratesMissingAndUnknownFields() throws {
    let json = #"{"languages":[{"code":"ko","future_field":{"a":1}},{"code":"xx","name":"Xish","enabled":true,"engines":[{"id":"e","name":"E","installed":false,"new":1}],"voices":{"available":2}}]}"#
    let list = try EngineJSON.decoder.decode(LanguageList.self, from: Data(json.utf8)).languages
    #expect(list[0].name == "Korean" && list[0].native == "한국어" && !list[0].enabled && list[0].ready)
    #expect(list[1].native == "Xish" && list[1].enabled && list[1].voices.available == 2 && list[1].voices.bytes == 0)
}

@Test func variantFixtureHasANotReadyLanguageAndInstalledVoices() throws {
    let all = try languages("languages_list_variant.json")
    let de = try #require(all.first { $0.code == "de" })
    #expect(!de.ready && !de.enabled && de.recommended == "voxtral")
    #expect(de.needText == "Needs Voxtral TTS 4B (2.5 GB, non-commercial)")
    let es = try #require(all.first { $0.code == "es" })
    #expect(es.enabled && es.voices.installed == 3)
}

@Test func presetVoicesDecodeAlsoAndOldEnginesWithoutIt() throws {
    let json = #"{"id":"v","name":"V","lang":"fr","also":["es","it"],"extra":true}"#
    let voice = try EngineJSON.decoder.decode(PresetVoice.self, from: Data(json.utf8))
    #expect(voice.also == ["es", "it"] && voice.speaksWithAccent("es") && !voice.speaksWithAccent("fr") && voice.speaks("fr"))
    let old = try EngineJSON.decoder.decode(PresetVoice.self, from: Data(#"{"id":"v","name":"V","lang":"fr"}"#.utf8))
    #expect(old.also == nil && !old.speaksWithAccent("es"))
}

// MARK: - Enabled languages

@MainActor
@Test func enabledLanguagesComeFromTheEngineList() throws {
    let (model, _, cleanup) = try makeModel(fixture: nil)
    defer { cleanup() }
    #expect(!model.languagesKnown && model.enabledLanguageCodes == ["en"])      // before the list is loaded
    model.preload(languages: try languages("languages_list_variant.json"))
    #expect(model.enabledLanguageCodes == ["en", "fr", "es", "ru"])
    #expect(model.isEnabled("es") && model.isEnabled("ES") && !model.isEnabled("de"))
    #expect(model.fallbackLanguage == "en")
}

@MainActor
@Test func formattersUseTheEnginesNames() throws {
    let (_, _, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(Formatters.languageName("pt") == "Portuguese" && Formatters.languageName("ZH") == "Chinese")
    #expect(Formatters.languageName("nl") == "Dutch")
    #expect(Formatters.languageName("sv") == "Swedish")          // outside the registry: the system's name
    #expect(Formatters.languageName("zz") == "zz" || !Formatters.languageName("zz").isEmpty)
}

@MainActor
@Test func pickersListOnlyEnabledLanguagesPlusTheBooks() throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(model.bookLanguageChoices == ["en", "fr"])
    #expect(model.voiceLanguages == ["en", "fr"])
    #expect(model.opsLanguages == ["en", "fr"])
    model.draft = try book(language: "es")
    #expect(model.bookLanguageChoices == ["en", "fr", "es"])     // sorted by English name: English, French, Spanish
    #expect(model.voiceLanguages == ["en", "fr", "es"])
    model.preload(languages: try languages("languages_list_variant.json"))
    #expect(model.opsLanguages == ["en", "fr"])                  // no engine lists Spanish or Russian here
}

@MainActor
@Test func benchmarkAndDefaultVoiceLanguagesAreTheEnabledOnesAnEngineSpeaks() throws {
    let (model, cleanup) = try accentModel()
    defer { cleanup() }
    #expect(model.opsLanguages == ["en", "fr", "es", "ru"])
}

@MainActor
@Test func addVoiceFormOffersEveryLanguageACloningEngineSpeaks() throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(model.cloningLanguageCodes == ["en", "fr"])                       // fixture engines speak only these
    var list = try Fixtures.decode("engines.json", as: EngineList.self)
    let q = try #require(list.engines.firstIndex { $0.id == "qwen3" })
    let k = try #require(list.engines.firstIndex { $0.id == "kokoro" })
    list.engines[q].languages = ["en", "fr", "es", "de", "ko"]
    list.engines[k].languages = ["en", "hi"]                                  // Kokoro cannot clone: Hindi stays out
    model.preload(engines: list)
    #expect(model.cloningLanguageCodes == ["en", "fr", "es", "de", "ko"])    // registry order; Spanish is off in Settings
    var form = AddVoiceForm(language: "es", languages: model.cloningLanguageCodes)
    #expect(form.language == "es")
    form.file = URL(fileURLWithPath: "/tmp/a.wav"); form.name = "Me"; form.hasRights = true
    #expect(form.canSubmit)
    form.language = "hi"
    #expect(form.missingStep == "Choose one of the listed languages.")
}

@MainActor
@Test func engineCardsShowOnlyEnabledLanguages() throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    var list = try Fixtures.decode("engines.json", as: EngineList.self)
    let k = try #require(list.engines.firstIndex { $0.id == "kokoro" })
    list.engines[k].languages = LanguageRegistry.codes
    model.preload(engines: list)
    let card = model.voiceEngineSummary(for: list.engines[k])
    #expect(card.languagesText == "English, French")
    model.draft = try book(language: "de")
    #expect(model.voiceEngineSummary(for: list.engines[k]).languagesText == "English, French, German")   // the book's own
}

// MARK: - Settings rows

@MainActor
@Test func settingsRowsDescribeWhatEachLanguageCosts() throws {
    let (model, _, cleanup) = try makeModel(fixture: "languages_list_variant.json")
    defer { cleanup() }
    let rows = model.languageRows
    #expect(rows.count == 13)
    let es = try #require(rows.first { $0.code == "es" })
    #expect(es.isOn && es.detail == "3 voices, 6.4 MB on disk" && es.need == nil)
    #expect(es.removalMessage == "Deletes the 3 voices downloaded for Spanish. The voice models are shared with other languages and stay.")
    let en = try #require(rows.first { $0.code == "en" })
    #expect(en.detail == "No extra voices on disk")
    #expect(en.removalMessage.hasPrefix("No voices were downloaded for English."))
    let de = try #require(rows.first { $0.code == "de" })
    #expect(!de.isOn && de.detail == "No voices to download" && de.need == "Needs Voxtral TTS 4B (2.5 GB, non-commercial)")
    let (plain, _, cleanup2) = try makeModel()
    defer { cleanup2() }
    let fr = try #require(plain.languageRows.first { $0.code == "fr" })
    #expect(fr.detail == "No extra voices on disk")
    var off = LanguageInfo(code: "it", enabled: false, voices: LanguageVoices(available: 2, installed: 0, bytes: 0, downloadMb: 3.1))
    #expect(LanguageRowState(info: off).detail == "Voices: ~3.1 MB download")
    off.voices.installed = 1; off.voices.bytes = 1_000_000; off.enabled = true
    #expect(LanguageRowState(info: off).removalMessage.hasPrefix("Deletes the 1 voice downloaded for Italian."))
}

// MARK: - Blockers

@MainActor
@Test func aBookInALanguageThatIsOffIsBlockedWithABanner() throws {
    let (model, _, cleanup) = try makeModel()
    defer { cleanup() }
    model.draft = try book(language: "es")
    let blocker = model.bookBlocker(voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart"), forConversion: true)
    #expect(blocker == .languageOff(language: "Spanish"))
    #expect(blocker?.message == "This book is in Spanish, which is off. Add Spanish to choose a narrator and convert it.")
    #expect(blocker?.fixDestination == nil)
    #expect(model.bookBlocker(voice: nil, forConversion: false) == .languageOff(language: "Spanish"))   // before "choose a voice"
    #expect(model.bookLanguageToAdd?.code == "es")
    #expect(model.languageAddHint(try #require(model.bookLanguageToAdd)) == "No voices to download. Nothing else is downloaded.")
}

@MainActor
@Test func aLanguageNoInstalledEngineSpeaksNamesTheEngineToInstall() throws {
    let (model, _, cleanup) = try makeModel(fixture: "languages_list_variant.json")
    defer { cleanup() }
    model.draft = try book(language: "ru")                        // on, but not ready
    let blocker = model.bookBlocker(voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart"), forConversion: false)
    #expect(blocker == .languageNotReady(language: "Russian", engine: "Qwen3-TTS 1.7B (6.2 GB)"))
    #expect(blocker?.message.hasPrefix("Russian needs Qwen3-TTS 1.7B (6.2 GB). Download it in Models first") == true)
    #expect(blocker?.fixDestination == .models && blocker?.fixTitle == "Open Models")
    #expect(model.bookLanguageToAdd == nil)                       // already on: no "Add" banner
}

@MainActor
@Test func enabledReadyAndUnsupportedLanguagesAreNotBlocked() throws {
    let (model, _, cleanup) = try makeModel(fixture: "languages_list_variant.json")
    defer { cleanup() }
    let narrator = VoiceSelection(engineId: "kokoro", presetId: "af_heart")
    for code in ["en", "fr", "es"] {
        model.draft = try book(language: code)
        #expect(model.bookBlocker(voice: narrator, forConversion: true) == nil, "\(code)")
    }
    model.draft = try book(language: "sv")                        // not in the registry: today's behaviour
    #expect(model.bookBlocker(voice: narrator, forConversion: true) == nil)
    #expect(model.bookLanguageToAdd == nil)
    // No list (older engine): nothing is blocked either.
    let (old, _, cleanup2) = try makeModel(fixture: nil)
    defer { cleanup2() }
    old.draft = try book(language: "es")
    #expect(old.bookBlocker(voice: narrator, forConversion: true) == nil)
}

// MARK: - Add and remove (engine stubs)

private func languageStub(in folder: URL, log: URL, fixture: String = "languages_list_variant.json") throws -> String {
    try stubEngine(in: folder, """
    echo "$@" >> '\(log.path)'
    case "$1 $2" in
      "languages add")
        echo '{"event": "language_voice", "code": "'"$3"'", "id": "es_lucia", "name": "Lucía"}'
        sleep 0.4
        echo '{"event": "language_done", "code": "'"$3"'", "enabled": true, "ready": true, "needs": null, "voice_errors": [{"id": "es_bad", "error": "offline"}], "voices_installed": 3}' ;;
      "languages remove")
        echo '{"event": "language_done", "code": "'"$3"'", "enabled": false, "removed_voices": ["es_lucia"], "kept_voices": [{"id": "es_pablo", "reason": "narrating a running job"}]}' ;;
      "languages list") cat '\(Fixtures.directory.appendingPathComponent(fixture).path)' ;;
      "voices list") echo '{"voices": []}' ;;
      *) echo '{}' ;;
    esac
    """)
}

@Test @MainActor func addingALanguageShowsProgressAndRefreshesTheList() async throws {
    let folder = try tempFolder("AddLanguage")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("args.txt")
    let (model, _, cleanup) = try makeModel(enginePath: try languageStub(in: folder, log: log))
    defer { cleanup() }
    #expect(!model.isEnabled("es"))

    let adding = Task { try await model.addLanguage("es") }
    for _ in 0..<150 where model.languageDownloads["es"]?.currentVoiceName == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.languageDownloads["es"]?.currentVoiceName == "Lucía")
    #expect(model.languageDownloads["es"]?.statusText == "Downloading the voice Lucía…")
    #expect(model.isChangingLanguage)

    // No concurrent duplicates: the same language is ignored, another one is refused with a message.
    let duplicate = try await model.addLanguage("es")
    #expect(duplicate == nil)
    var refused: String?
    do { _ = try await model.addLanguage("de") } catch { refused = EngineError(error).message }
    #expect(refused == "Another language is being changed. Wait for it to finish.")
    var refusedRemoval: String?
    do { _ = try await model.removeLanguage("fr") } catch { refusedRemoval = EngineError(error).message }
    #expect(refusedRemoval != nil)

    let result = try #require(try await adding.value)
    #expect(result.enabled && result.ready && result.needs == nil && result.voicesInstalled == 3)
    #expect(result.voiceErrors == [LanguageVoiceError(id: "es_bad", error: "offline")])
    #expect(result.summary(languageName: "Spanish") == "Spanish is on. 3 voices are on disk.")
    #expect(result.notes == ["Could not download es_bad: offline."])
    #expect(model.languageDownloads.isEmpty && !model.isChangingLanguage)
    #expect(model.isEnabled("es") && model.languageResults["es"] == result)
    let calls = try String(contentsOf: log, encoding: .utf8)
    #expect(calls.contains("languages add es") && calls.contains("languages list") && calls.contains("voices list"))
    #expect(!calls.contains("languages add de"))
}

@Test @MainActor func addingALanguageReportsWhatItNeedsWhenNoEngineSpeaksIt() async throws {
    let folder = try tempFolder("AddLanguageNeeds")
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try stubEngine(in: folder, """
    case "$1 $2" in
      "languages add") echo '{"event": "language_done", "code": "de", "enabled": true, "ready": false, "needs": "voxtral", "voice_errors": [], "voices_installed": 0}' ;;
      *) echo '{"languages": []}' ;;
    esac
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    let result = try #require(try await model.addLanguage("de"))
    #expect(result.enabled && !result.ready && result.needs == "voxtral" && result.notes.isEmpty)
}

@Test @MainActor func aFailedAddKeepsTheEnginesMessage() async throws {
    let folder = try tempFolder("AddLanguageFails")
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try stubEngine(in: folder, """
    case "$1 $2" in
      "languages add") echo '{"event": "error", "message": "Could not reach the voice library."}'; exit 1 ;;
      *) echo '{"languages": []}' ;;
    esac
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    var message: String?
    do { _ = try await model.addLanguage("es") } catch { message = EngineError(error).message }
    #expect(message == "Could not reach the voice library.")
    #expect(model.languageErrors["es"]?.message == message)
    #expect(model.languageDownloads.isEmpty)
    model.clearLanguageMessages("es")
    #expect(model.languageErrors["es"] == nil)
}

@Test @MainActor func removingALanguageForgetsItsVoicesAndReportsKeptOnes() async throws {
    let folder = try tempFolder("RemoveLanguage")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("args.txt")
    let (model, settings, cleanup) = try makeModel(enginePath: try languageStub(in: folder, log: log, fixture: "languages_list.json"),
                                                   fixture: "languages_list_variant.json")
    defer { cleanup() }
    let mine = VoiceSelection(engineId: "qwen3", refVoiceId: "es_lucia")
    settings.defaultVoices["es"] = mine
    settings.defaultVoices["en"] = VoiceSelection(engineId: "kokoro", presetId: "af_heart")
    model.voiceLab.filter.language = .only("es")
    #expect(model.isEnabled("es"))

    let result = try #require(try await model.removeLanguage("es"))

    #expect(!result.enabled && result.removedVoices == ["es_lucia"] && result.keptVoices.map(\.id) == ["es_pablo"])
    #expect(result.summary(languageName: "Spanish") == "Spanish is off. Deleted 1 voice.")
    #expect(result.notes == ["Kept es_pablo: narrating a running job."])                  // reported, not an error
    #expect(model.languageErrors["es"] == nil)
    #expect(!model.isEnabled("es"))                                                         // list refreshed
    #expect(settings.defaultVoices["es"] == nil && settings.defaultVoices["en"] != nil)
    #expect(model.voiceLab.filter.language == .book)
    #expect(model.languageRemovals.isEmpty)
    #expect(try String(contentsOf: log, encoding: .utf8).contains("languages remove es"))
}

@Test @MainActor func theLastLanguageCannotBeRemoved() async throws {
    let folder = try tempFolder("RemoveLastLanguage")
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try stubEngine(in: folder, """
    echo '{"event": "error", "message": "At least one language must stay on."}'
    exit 2
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    var message: String?
    do { _ = try await model.removeLanguage("en") } catch { message = EngineError(error).message }
    #expect(message == "At least one language must stay on.")
    #expect(model.languageErrors["en"]?.message == message)
    #expect(model.isEnabled("en"))                                                          // nothing changed
}

// MARK: - Voices that speak a language with an accent

@MainActor
private func accentModel() throws -> (AppModel, () -> Void) {
    let (model, _, cleanup) = try makeModel(fixture: "languages_list_variant.json")
    var list = try Fixtures.decode("engines.json", as: EngineList.self)
    let k = try #require(list.engines.firstIndex { $0.id == "kokoro" })
    list.engines[k].languages = LanguageRegistry.codes
    list.engines[k].voices += [
        PresetVoice(id: "ef_dora", name: "Dora", lang: "es", gender: "female", accent: nil, note: "Native Spanish voice"),
        PresetVoice(id: "ff_siwis2", name: "Siwis 2", lang: "fr", gender: "female", accent: nil,
                    note: "Speaks Spanish with a French accent", also: ["es"]),
    ]
    model.preload(engines: list)
    return (model, cleanup)
}

@MainActor
@Test func accentedVoicesFollowTheNativeOnes() throws {
    let (model, cleanup) = try accentModel()
    defer { cleanup() }
    model.draft = try book(language: "es")
    let options = model.filteredVoiceOptions
    #expect(options.map(\.voiceId) == ["ef_dora", "ff_siwis2"])
    let groups = VoiceCatalog.groups(options, engines: model.engines, accentLanguage: "es")
    #expect(groups.map(\.title) == ["Kokoro 82M (fast draft) presets",
                                    "Kokoro 82M (fast draft) · speaks Spanish with an accent"])
    #expect(groups[0].options.map(\.voiceId) == ["ef_dora"] && groups[1].options.map(\.voiceId) == ["ff_siwis2"])
    #expect(groups[1].options[0].summary == "Speaks Spanish with a French accent")          // the engine's note
    // Without a browsed language the same voice is simply a French one.
    #expect(VoiceCatalog.groups(options, engines: model.engines).count == 1)
}

@MainActor
@Test func voicesOfALanguageThatIsOffAreHiddenFromTheBrowser() throws {
    let (model, cleanup) = try accentModel()
    defer { cleanup() }
    model.voiceLab.filter.language = .all
    let langs = Set(model.filteredVoiceOptions.filter { $0.kind == .preset }.map(\.language))
    #expect(langs.isSuperset(of: ["en", "fr", "es"]))
    model.preload(languages: try languages("languages_list.json"))                          // Spanish off again
    let after = Set(model.filteredVoiceOptions.filter { $0.kind == .preset }.map(\.language))
    #expect(after == ["en", "fr"])
}

@MainActor
@Test func anAccentedPresetFitsTheBookAndOnlyWarnsSoftly() throws {
    let (model, cleanup) = try accentModel()
    defer { cleanup() }
    let accented = VoiceSelection(engineId: "kokoro", presetId: "ff_siwis2")
    #expect(accented.fits(language: "es", engines: model.engines, voices: model.voices))
    #expect(!VoiceSelection(engineId: "kokoro", presetId: "ff_siwis").fits(language: "es", engines: model.engines, voices: model.voices))
    let warning = model.bookVoiceWarning(voice: accented, language: "es")
    #expect(warning?.message == "Siwis 2 is a French voice that speaks Spanish with an accent.")
    // Suggestions still prefer native voices.
    #expect(VoiceSelection.suggested(for: "es", engines: model.engines, voices: [])?.presetId == "ef_dora")
}

// MARK: - Palette

@Test func everyRegistryLanguageHasItsOwnHue() {
    let others = LanguageRegistry.codes.filter { $0 != "en" && $0 != "fr" }
    #expect(others.allSatisfy { VoiceStyle.hues[$0] != nil })
    #expect(Set(others.compactMap { VoiceStyle.hues[$0] }).count == others.count)
}
