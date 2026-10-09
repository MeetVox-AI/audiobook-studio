import Foundation
import Testing
@testable import AudiobookStudio

// MARK: - Job states

@Test func jobStateMapping() {
    let all = ["queued", "running", "done", "done_with_problems", "failed", "cancelled", "interrupted"]
    for value in all { #expect(JobState(engineValue: value).engineValue == value) }
    #expect(JobState(engineValue: "queued").isActive && JobState(engineValue: "running").isActive)
    #expect(!JobState(engineValue: "done").isActive && JobState(engineValue: "done").producedOutput)
    #expect(JobState(engineValue: "done_with_problems") == .doneWithProblems)
    #expect(JobState(engineValue: "done_with_problems").title == "Done with problems")
    #expect(JobState(engineValue: "interrupted").canResume && JobState(engineValue: "cancelled").canResume)
    #expect(!JobState(engineValue: "done").canResume)
    #expect(JobState(engineValue: "paused") == .unknown("paused") && !JobState(engineValue: "paused").isActive)
}

// MARK: - Book draft

@Test func draftStartsFromEngineSelection() throws {
    let info = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    var draft = BookDraft(url: URL(fileURLWithPath: "/books/verne.epub"), info: info, coverURL: nil)
    #expect(draft.sectionsArgument == "3-39")
    #expect(draft.includedChars == 412_027)
    #expect(abs(draft.includedEstSeconds - 26781.8) < 0.5)
    #expect(draft.languageSourceLabel == "from metadata")

    draft.setIncluded(10, false)
    draft.toggle(40)
    #expect(draft.sectionsArgument == "3-9,11-40")
    draft.setAll(false, kind: .chapter)
    #expect(draft.sectionsArgument == "40")
    draft.resetSelection()
    #expect(draft.sectionsArgument == "3-39")
    draft.setAll(false)
    #expect(!draft.hasSelection && draft.includedChars == 0)

    draft.language = "en"
    #expect(draft.languageSourceLabel == nil)
}

@Test func sectionSpecCompression() {
    #expect(BookDraft.sectionsSpec([2, 3, 4, 7]) == "2-4,7")
    #expect(BookDraft.sectionsSpec([20, 2, 14, 13, 3]) == "2-3,13-14,20")
    #expect(BookDraft.sectionsSpec([5]) == "5")
    #expect(BookDraft.sectionsSpec([Int]()) == "")
}

// MARK: - Voice selection and command lines

@Test func voiceSelectionArguments() {
    var v = VoiceSelection(engineId: "kokoro", presetId: "af_heart")
    #expect(!v.verify)   // kokoro does not sample: speech check off by default
    #expect(v.synthesisArguments == ["--engine", "kokoro", "--voice", "af_heart", "--no-verify"])
    v.speed = 1.25
    #expect(v.synthesisArguments == ["--engine", "kokoro", "--voice", "af_heart", "--speed", "1.25", "--no-verify"])

    var q = VoiceSelection(engineId: "qwen3", refVoiceId: "fr_siwis_female_book")
    #expect(q.verify && q.isClone && q.voiceId == "fr_siwis_female_book")
    #expect(q.voiceArguments == ["--engine", "qwen3", "--ref-voice", "fr_siwis_female_book"])
    q.choosePreset("ryan")
    #expect(q.refVoiceId == nil && q.voiceArguments == ["--engine", "qwen3", "--voice", "ryan"])
    q.switchEngine(to: "kokoro")
    #expect(q.voiceId == nil && !q.verify)
}

@Test func commandLines() {
    let voice = VoiceSelection(engineId: "qwen3", refVoiceId: "fr_cmltts_7142_male")
    let convert = ConvertRequest(bookPath: "/b/book.epub", voice: voice, language: "fr", sections: [4, 3, 5],
                                 outputFolder: "/out", bitrateKbps: 96, keepWork: true)
    #expect(convert.arguments == ["convert", "/b/book.epub", "--engine", "qwen3", "--ref-voice", "fr_cmltts_7142_male",
                                  "--verify", "--lang", "fr", "--sections", "3-5", "--bitrate", "96", "--keep-work",
                                  "--out-dir", "/out", "--detach"])
    let defaults = ConvertRequest(bookPath: "/b/book.epub", voice: voice, language: "fr", sections: [3],
                                  outputFolder: nil, bitrateKbps: 64, keepWork: false)
    #expect(!defaults.arguments.contains("--out-dir") && !defaults.arguments.contains("--keep-work"))

    let sample = SampleRequest(bookPath: "/b/book.epub", voice: voice, language: "fr", section: 3, seconds: 20,
                               outputPath: "/tmp/s.m4a")
    #expect(sample.arguments == ["sample", "/b/book.epub", "--engine", "qwen3", "--ref-voice", "fr_cmltts_7142_male",
                                 "--verify", "--lang", "fr", "--section", "3", "--seconds", "20", "--out", "/tmp/s.m4a"])

    let bench = BenchmarkRequest(voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart", speed: 1.2), language: "en")
    #expect(bench.arguments == ["benchmark", "--engine", "kokoro", "--voice", "af_heart", "--lang", "en"])
}

@Test func suggestedVoicePrefersCommercialInstalledEngines() throws {
    let engines = try Fixtures.decode("engines.json", as: EngineList.self).engines
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    let en = VoiceSelection.suggested(for: "en", engines: engines, voices: voices, models: models)
    #expect(en?.engineId == "qwen3" && en?.presetId == "ryan")
    // Qwen3 has no French preset: it clones the first installed French voice.
    let fr = VoiceSelection.suggested(for: "fr", engines: engines, voices: voices, models: models)
    #expect(fr?.engineId == "qwen3" && fr?.refVoiceId == "fr_siwis_female_book")
    #expect(fr?.fits(language: "fr", engines: engines, voices: voices) == true)
    #expect(en?.fits(language: "fr", engines: engines, voices: voices) == false)
    #expect(fr?.displayName(engines: engines, voices: voices) == "SIWIS — studio narrator (F) · Qwen3-TTS 1.7B (cloned)")
}

// MARK: - Settings and model

@MainActor
@Test func settingsPersist() throws {
    let suite = "AudiobookStudioTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let settings = AppSettings(defaults: defaults)
    #expect(settings.bitrateKbps == 64 && settings.notificationsEnabled && settings.outputFolder == nil)
    #expect(settings.enginePath == EngineClient.defaultPath && settings.enginePathOverride == nil)

    settings.enginePath = "/opt/engine/bin/audiobook-engine"
    settings.outputFolder = "/Users/me/Audiobooks"
    settings.bitrateKbps = 128
    settings.notificationsEnabled = false
    settings.keepWork = true
    settings.defaultVoices["fr"] = VoiceSelection(engineId: "qwen3", refVoiceId: "fr_siwis_female_book", speed: 1.1)
    settings.pacing.chapter = .long
    settings.acknowledgeLicense(engine: "voxtral")

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.enginePath == "/opt/engine/bin/audiobook-engine")
    #expect(reloaded.outputFolder == "/Users/me/Audiobooks" && reloaded.bitrateKbps == 128)
    #expect(!reloaded.notificationsEnabled && reloaded.keepWork)
    #expect(reloaded.defaultVoices["fr"]?.refVoiceId == "fr_siwis_female_book" && reloaded.defaultVoices["fr"]?.speed == 1.1)
    #expect(reloaded.pacing.chapter == .long && reloaded.hasAcknowledgedLicense(engine: "voxtral"))

    reloaded.enginePath = ""   // empty resets to the default location
    #expect(AppSettings(defaults: defaults).enginePathOverride == nil)
}

@MainActor
@Test func estimateUsesMeasuredRate() throws {
    let suite = "AudiobookStudioTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(settings: AppSettings(defaults: defaults))
    let info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    let engines = try Fixtures.decode("engines.json", as: EngineList.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/b/pp.epub"), info: info, coverURL: nil)

    #expect(model.estimate == nil)
    #expect(model.estimateSummary == "Run a benchmark or make a sample to get an estimate")

    model.voiceSelection = VoiceSelection(engineId: "kokoro", presetId: "af_bella")
    // Engines not loaded yet: still no estimate.
    #expect(model.estimate == nil)

    model.preload(engines: engines)
    #expect(model.voiceSelection?.presetId == "af_bella")   // still valid for English: kept
    let estimate = try #require(model.estimate)
    #expect(abs(estimate.seconds - 705_384 / 250.47) < 0.01 && estimate.exactVoice)
    #expect(model.estimateSummary == "On this Mac: ≈ 47 min")

    // An unmeasured voice falls back to the engine's median measurement.
    model.voiceSelection?.choosePreset("am_adam")
    #expect(model.estimate?.exactVoice == false && model.estimate?.charsPerSecond == 188.33)

    // Changing the language switches to a French voice (no voices loaded: Kokoro's French preset).
    model.setLanguage("fr")
    #expect(model.draft?.language == "fr" && model.voiceSelection?.engineId == "kokoro" && model.voiceSelection?.presetId == "ff_siwis")
}

@MainActor
@Test func sampleRunReducer() {
    let run = SampleRun(kind: .sample, voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart"), language: "en")
    var finished = 0
    run.onFinish = { _ in finished += 1 }
    #expect(run.isRunning && run.phase == .starting)
    run.apply(EngineEvent(event: "queued", message: "A conversion is using the GPU; waiting."))
    #expect(run.statusText == "A conversion is using the GPU; waiting.")
    run.apply(EngineEvent(event: "model_loading"))
    #expect(run.phase == .loadingModel)
    run.apply(EngineEvent(event: "model_loaded", loadS: 1.5, warmupS: 0.5))
    #expect(run.phase == .working && run.modelLoadSeconds == 2.0)
    run.apply(EngineEvent(event: "sample_done", output: "/tmp/s.m4a", audioS: 26))
    #expect(run.phase == .finished && !run.isRunning && run.result?.audioS == 26 && finished == 1)
    run.cancel()   // no effect once finished
    #expect(run.phase == .finished && finished == 1)
}

@Test func engineErrorWrapsFailures() {
    let missing = EngineError(EngineFailure.notFound("/nope"))
    #expect(missing.engineMissing && missing.message.contains("/nope"))
    let failed = EngineError(EngineFailure.failed(message: "Not enough disk space: 1 GB free", stderrTail: "trace"))
    #expect(failed.isDiskSpace && failed.stderrTail == "trace" && !failed.engineMissing)
    #expect(EngineError(failed).id == failed.id)
}
