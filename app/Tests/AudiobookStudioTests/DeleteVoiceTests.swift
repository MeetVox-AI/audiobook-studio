import Foundation
import Testing
@testable import AudiobookStudio

// Deleting a cloned voice: the app forgets it everywhere (narrator, saved defaults, playback),
// and an engine refusal (voice narrating a running job) is reported, not swallowed.
// Engine commands are /bin/sh stubs; the real engine never runs.

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

/// A user clip (French) on top of the fixture voices.
private func userClip(_ id: String = "user-ma-voix") -> VoiceEntry {
    VoiceEntry(id: id, name: "Ma voix", lang: "fr", gender: nil, description: "Your own reference clip",
               license: "user-provided", commercialOk: nil, attribution: nil, sourcePage: nil, installed: true,
               transcript: "Bonjour, ceci est ma voix.", transcriptSource: "user", durationS: 8,
               path: "/tmp/voices/\(id).wav")
}

@MainActor
private func makeModel(enginePath: String) throws -> (AppModel, AppSettings, () -> Void) {
    let suite = "AudiobookStudioDeleteVoiceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = enginePath
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DeleteVoiceTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    let info = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/books/fr.epub"), info: info, coverURL: nil)
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices + [userClip()]
    model.preload(engines: list, models: models, voices: voices)
    return (model, settings, {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    })
}

@Test @MainActor func forgettingAVoiceResetsTheNarratorAndSavedDefaults() throws {
    let (model, settings, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine")
    defer { cleanup() }
    let mine = VoiceSelection(engineId: "qwen3", refVoiceId: "user-ma-voix")
    model.voiceSelection = mine
    settings.defaultVoices["fr"] = mine
    let english = VoiceSelection(engineId: "kokoro", presetId: "af_heart")
    settings.defaultVoices["en"] = english

    model.forgetVoice("user-ma-voix", file: nil)

    #expect(settings.defaultVoices["fr"] == nil)
    #expect(settings.defaultVoices["en"] == english)            // other defaults untouched
    #expect(model.voiceSelection?.refVoiceId != "user-ma-voix")
    #expect(model.voiceSelection != nil)                        // falls back to a French narrator
}

@Test @MainActor func forgettingAnotherVoiceKeepsTheNarrator() throws {
    let (model, _, cleanup) = try makeModel(enginePath: "/nonexistent/audiobook-engine")
    defer { cleanup() }
    let mine = VoiceSelection(engineId: "qwen3", refVoiceId: "user-ma-voix")
    model.voiceSelection = mine
    model.forgetVoice("fr_siwis_female_book", file: nil)
    #expect(model.voiceSelection == mine)
}

@Test @MainActor func deletingAVoiceCallsTheEngineAndForgetsIt() async throws {
    let folder = try tempFolder("DeleteVoice")
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = folder.appendingPathComponent("args.txt")
    let engine = try stubEngine(in: folder, """
    echo "$@" >> '\(log.path)'
    case "$1 $2" in
      "voices remove") echo '{"event": "done", "id": "'"$3"'", "removed": true}' ;;
      "voices list") echo '{"voices": []}' ;;
      *) echo '{}' ;;
    esac
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    model.voiceSelection = VoiceSelection(engineId: "qwen3", refVoiceId: "user-ma-voix")

    try await model.removeVoice("user-ma-voix")

    let calls = try String(contentsOf: log, encoding: .utf8)
    #expect(calls.contains("voices remove user-ma-voix"))
    #expect(model.voiceSelection?.refVoiceId != "user-ma-voix")
    #expect(!model.busyVoiceIds.contains("user-ma-voix"))
}

@Test @MainActor func aVoiceInUseIsNotForgottenAndTheReasonIsShown() async throws {
    let folder = try tempFolder("DeleteVoiceInUse")
    defer { try? FileManager.default.removeItem(at: folder) }
    let engine = try stubEngine(in: folder, """
    echo '{"event": "error", "message": "This voice is narrating \\\\"Emma\\\\" right now. Stop that conversion or wait for it to finish, then delete the voice."}'
    exit 2
    """)
    let (model, _, cleanup) = try makeModel(enginePath: engine)
    defer { cleanup() }
    let mine = VoiceSelection(engineId: "qwen3", refVoiceId: "user-ma-voix")
    model.voiceSelection = mine

    var message: String?
    do {
        try await model.removeVoice("user-ma-voix")
    } catch {
        message = EngineError(error).message
    }
    #expect(message?.contains("narrating") == true)
    #expect(model.voiceSelection == mine)                       // nothing forgotten on failure
    #expect(model.voices.contains { $0.id == "user-ma-voix" })
}
