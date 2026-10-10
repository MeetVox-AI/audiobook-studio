import Foundation
import Testing
@testable import AudiobookStudio

// Voice clean-up (isolation, enhancer) and changing a voice's recording. Engine commands are /bin/sh stubs that
// log their arguments; the real engine never runs.

private func tempFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An engine stub that logs each command line and answers `voices add/replace` with a user voice; `voices list`
/// still lists that voice afterwards, as the real engine does.
private func loggingEngine(in folder: URL) throws -> (path: String, log: URL) {
    let log = folder.appendingPathComponent("args.txt")
    let url = folder.appendingPathComponent("audiobook-engine")
    let body = """
    #!/bin/sh
    echo "$@" >> '\(log.path)'
    case "$1 $2" in
      "voices add"|"voices replace") echo '{"event": "done", "id": "user-ma-voix", "name": "Ma voix", "lang": "fr", "installed": true, "isolate": true, "enhance": false, "original": "user-ma-voix.flac", "original_name": "new.wav"}' ;;
      "voices list") echo '{"voices": [{"id": "user-ma-voix", "name": "Ma voix", "lang": "fr", "installed": true, "path": "/tmp/voices/user-ma-voix.wav", "transcript": "Bonjour.", "isolate": true, "original": "user-ma-voix.flac"}]}' ;;
      "languages list") echo '{"languages": []}' ;;
      *) echo '{}' ;;
    esac
    """
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (url.path, log)
}

private func userClip(isolate: Bool? = nil, enhance: Bool? = nil, original: String? = "user-ma-voix.flac") -> VoiceEntry {
    VoiceEntry(id: "user-ma-voix", name: "Ma voix", lang: "fr", gender: nil, description: "Your own reference clip",
               license: "user-provided", commercialOk: nil, attribution: nil, sourcePage: nil, installed: true,
               transcript: "Bonjour.", transcriptSource: "user", durationS: 8, path: "/tmp/voices/user-ma-voix.wav",
               isolate: isolate, enhance: enhance, original: original, originalName: original == nil ? nil : "me.wav")
}

private func cleanupStatus(_ id: String, installed: Bool) -> ModelStatus {
    ModelStatus(engine: id, name: id, installed: installed, downloadGb: id == "voice-isolation" ? 0.009 : 0.111,
                license: "MIT", noncommercial: false,
                parts: [ModelPart(repo: "r/\(id)", purpose: "p", installed: installed, bytes: installed ? 1 : 0, path: nil)])
}

@MainActor
private func makeModel(enginePath: String, extraModels: [ModelStatus] = []) throws -> (AppModel, () -> Void) {
    let suite = "AudiobookStudioChangeRecordingTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ChangeRecordingTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    let info = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/books/fr.epub"), info: info, coverURL: nil)
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models + extraModels
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices + [userClip()]
    model.preload(engines: list, models: models, voices: voices)
    return (model, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    })
}

// MARK: - Engine arguments

@Test @MainActor func addVoicePassesTheCleanUpBoxesOnlyWhenTicked() async throws {
    let folder = try tempFolder("AddVoiceCleanup")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, log) = try loggingEngine(in: folder)
    let (model, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }

    try await model.addVoice(file: URL(fileURLWithPath: "/clips/a.wav"), name: "A", language: "fr", transcript: nil,
                             hasRights: true)
    try await model.addVoice(file: URL(fileURLWithPath: "/clips/b.wav"), name: "B", language: "fr", transcript: nil,
                             hasRights: true, isolate: true, enhance: true)
    let adds = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("voices add") }
    #expect(adds.count == 2)
    #expect(!adds[0].contains("--isolate") && !adds[0].contains("--enhance"))
    #expect(adds[1].contains("--isolate") && adds[1].contains("--enhance") && adds[1].hasSuffix("--i-have-rights"))
}

@Test @MainActor func reprocessingSendsTheBoxesAndNoFileOrConsent() async throws {
    let folder = try tempFolder("Reprocess")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, log) = try loggingEngine(in: folder)
    let (model, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }

    try await model.replaceVoice(id: "user-ma-voix", file: nil, isolate: true, enhance: false, transcript: "ignored",
                                 hasRights: false)
    let line = try #require(try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        .first { $0.hasPrefix("voices replace") })
    #expect(line == "voices replace user-ma-voix --isolate --no-enhance")
    #expect(!model.busyVoiceIds.contains("user-ma-voix"))
}

@Test @MainActor func aNewRecordingSendsTheFileTranscriptAndConsent() async throws {
    let folder = try tempFolder("ReplaceFile")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, log) = try loggingEngine(in: folder)
    let (model, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }

    try await model.replaceVoice(id: "user-ma-voix", file: URL(fileURLWithPath: "/clips/new.wav"), isolate: false,
                                 enhance: true, transcript: "  Nouveaux mots. ", hasRights: true)
    let line = try #require(try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        .first { $0.hasPrefix("voices replace") })
    #expect(line == "voices replace user-ma-voix --no-isolate --enhance --file=/clips/new.wav --transcript=Nouveaux mots. --i-have-rights")
}

@Test @MainActor func aNewRecordingWithoutConsentNeverReachesTheEngine() async throws {
    let folder = try tempFolder("ReplaceNoConsent")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, log) = try loggingEngine(in: folder)
    let (model, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }

    await #expect(throws: EngineError.self) {
        try await model.replaceVoice(id: "user-ma-voix", file: URL(fileURLWithPath: "/clips/new.wav"), isolate: false,
                                     enhance: false, transcript: nil, hasRights: false)
    }
    #expect(!FileManager.default.fileExists(atPath: log.path))
}

// MARK: - Old audio is not replayed

@Test @MainActor func changingARecordingDropsItsPreviewsAndSamplesOnly() async throws {
    let folder = try tempFolder("ReplaceForgets")
    defer { try? FileManager.default.removeItem(at: folder) }
    let (engine, _) = try loggingEngine(in: folder)
    let (model, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }

    let mine = VoiceSelection(engineId: "qwen3", refVoiceId: "user-ma-voix")
    let other = VoiceSelection(engineId: "qwen3", refVoiceId: "fr_siwis_female_book")
    let keyMine = VoiceLab.PreviewKey(bookPath: "/books/fr.epub", language: "fr", section: nil, voice: mine)
    let keyOther = VoiceLab.PreviewKey(bookPath: "/books/fr.epub", language: "fr", section: nil, voice: other)
    model.voiceLab.store(SampleRun(kind: .sample, voice: mine, language: "fr"), for: keyMine)
    model.voiceLab.store(SampleRun(kind: .sample, voice: other, language: "fr"), for: keyOther)
    model.voiceLab.setComparison(VoiceComparison(a: keyMine, b: keyOther))
    model.voiceSelection = mine

    try await model.replaceVoice(id: "user-ma-voix", file: nil, isolate: true, enhance: false, transcript: nil,
                                 hasRights: false)
    #expect(model.voiceLab.preview(for: keyMine) == nil)
    #expect(model.voiceLab.preview(for: keyOther) != nil)
    #expect(model.voiceLab.comparison == nil)
    #expect(model.voiceSelection == mine)                       // still the narrator: same voice, new recording
}

// MARK: - Clean-up models

@Test @MainActor func onlyMissingCleanUpModelsAreDownloadedFirst() throws {
    let (model, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine",
                                         extraModels: [cleanupStatus("voice-isolation", installed: false),
                                                       cleanupStatus("voice-enhancer", installed: true)])
    defer { cleanup() }
    #expect(model.missingCleanupModels(isolate: true, enhance: true) == ["voice-isolation"])
    #expect(model.missingCleanupModels(isolate: false, enhance: true) == [])
    #expect(model.missingCleanupModels(isolate: false, enhance: false) == [])
    #expect(model.cleanupModelNote("voice-isolation")?.installed == false)
    #expect(model.cleanupModelNote("voice-isolation")?.text == "Not installed: 9 MB will be downloaded first.")
    #expect(model.cleanupModelNote("voice-enhancer")?.text == "Installed on this Mac.")
}

@Test @MainActor func anOlderEngineWithoutCleanUpModelsAsksForNoDownload() throws {
    let (model, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine")
    defer { cleanup() }
    #expect(model.missingCleanupModels(isolate: true, enhance: true) == [])  // the engine itself says what is missing
    #expect(model.cleanupModelNote("voice-isolation") == nil)
}

@Test func modelsScreenGroupsCleanUpModelsApart() throws {
    let base = try Fixtures.decode("models_list.json", as: ModelList.self).models
    let all = base + [cleanupStatus("voice-enhancer", installed: false), cleanupStatus("voice-isolation", installed: true)]
    let engines = try Fixtures.decode("engines.json", as: EngineList.self).engines.map(\.id)
    let g = OpsModelInfo.groups(all, engineIds: engines)
    #expect(g.narration.map(\.engine) == engines)
    #expect(g.cleanup.map(\.engine) == ["voice-isolation", "voice-enhancer"])   // isolation first
    #expect(g.other.map(\.engine) == ["whisper"])
    let early = OpsModelInfo.groups(all, engineIds: [])                          // engine list not loaded yet
    #expect(!early.narration.contains { $0.engine.hasPrefix("voice-") || $0.engine == "whisper" })
    #expect(early.cleanup.count == 2 && early.other.map(\.engine) == ["whisper"])
}

// MARK: - The Change Recording form

@Test func reprocessingNeedsAChangedBoxAndAKeptOriginal() {
    var form = ChangeRecordingForm(entry: userClip(isolate: true, enhance: false))
    #expect(form.isolate && !form.enhance && form.actionTitle == "Reprocess")
    #expect(form.missingStep == "Choose a new recording or change a box.")
    form.enhance = true
    #expect(form.canSubmit)

    var old = ChangeRecordingForm(entry: userClip(original: nil))   // added before originals were kept
    old.isolate = true
    #expect(old.missingStep == "Choose the recording again: this voice was added before originals were kept.")
}

@Test func aNewRecordingNeedsConsentButNoBoxChange() {
    var form = ChangeRecordingForm(entry: userClip(original: nil))
    form.chooseFile(URL(fileURLWithPath: "/clips/new.wav"))
    #expect(form.actionTitle == "Replace Recording")
    #expect(form.missingStep == "Confirm that you have the right to use this voice.")
    form.hasRights = true
    #expect(form.canSubmit && form.transcriptArgument == nil)
    form.transcript = "  Mots.  "
    #expect(form.transcriptArgument == "Mots.")
}

@Test func voiceEntriesDecodeTheCleanUpFields() throws {
    let json = #"{"id": "user-a", "name": "A", "lang": "en", "isolate": true, "enhance": false, "original": "user-a.flac", "original_name": "a take.wav"}"#
    let entry = try EngineJSON.decoder.decode(VoiceEntry.self, from: Data(json.utf8))
    #expect(entry.isolate == true && entry.enhance == false && entry.hasOriginal && entry.originalName == "a take.wav")
    let old = try EngineJSON.decoder.decode(VoiceEntry.self, from: Data(#"{"id": "user-b", "name": "B", "lang": "en"}"#.utf8))
    #expect(!old.hasOriginal && old.isolate == nil)
}
