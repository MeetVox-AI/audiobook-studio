import Foundation
import Testing
@testable import AudiobookStudio

// Voices screen logic: catalogue, filters, choosing a narrator, engine cards, licence gate, previews.

private struct VoiceFixtures {
    let list: EngineList
    let voices: [VoiceEntry]
    let models: [ModelStatus]
    var engines: [EngineInfo] { list.engines }

    init() throws {
        list = try Fixtures.decode("engines.json", as: EngineList.self)
        voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices
        models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    }
}

/// A model whose engine path does not exist, so nothing it starts can run the real engine.
@MainActor
private func makeModel(_ f: VoiceFixtures, book: String? = nil) throws -> (AppModel, UserDefaults, String) {
    let suite = "AudiobookStudioVoiceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = AppSettings(defaults: defaults)
    settings.enginePath = "/nonexistent/audiobook-engine-\(UUID().uuidString)"
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    if let book {
        let info = try Fixtures.decode(book, as: BookInfo.self)
        model.draft = BookDraft(url: URL(fileURLWithPath: "/books/\(book).epub"), info: info, coverURL: nil)
    }
    // Loading engines and voices picks a narrator for the book's language.
    model.preload(engines: f.list, models: f.models, voices: f.voices)
    return (model, defaults, suite)
}

// MARK: - Catalogue and filters

@Test func catalogueListsPresetsThenReferenceVoices() throws {
    let f = try VoiceFixtures()
    let options = VoiceCatalog.options(engines: f.engines, voices: f.voices)
    // 6 Qwen3 + 7 Voxtral + 21 Kokoro presets (Fish has none), then 11 library voices.
    #expect(options.filter { $0.kind == .preset }.count == 34)
    #expect(options.filter { $0.kind == .library }.count == 11)
    #expect(Set(options.map(\.id)).count == options.count)

    let ryan = try #require(options.first { $0.id == "preset:qwen3:ryan" })
    #expect(ryan.engineIds == ["qwen3"] && ryan.license == "Apache-2.0" && ryan.accent == "English")
    #expect(ryan.summary == "Native English speaker")
    let heart = try #require(options.first { $0.id == "preset:kokoro:af_heart" })
    #expect(heart.summary == nil)   // empty notes are dropped

    let siwis = try #require(options.first { $0.voiceId == "fr_siwis_female_book" })
    #expect(siwis.kind == .library && siwis.engineIds == ["qwen3", "fish"] && siwis.installed)
    #expect(siwis.allowsCommercialUse(engines: f.engines))
    #expect(!siwis.allowsCommercialUse(engines: f.engines, engineFilter: "fish"))   // Fish licence is non-commercial

    // A user clip without a commercial flag: the user confirmed the rights when adding it.
    var clip = f.voices[0]
    clip.id = "user-my-voice"
    clip.commercialOk = nil
    clip.license = nil
    let clipOption = try #require(VoiceCatalog.options(engines: f.engines, voices: [clip]).last)
    #expect(clipOption.kind == .userClip && clipOption.license == "Your recording" && clipOption.voiceAllowsCommercialUse)

    let groups = VoiceCatalog.groups(VoiceCatalog.options(engines: f.engines, voices: f.voices + [clip]), engines: f.engines)
    #expect(groups.map(\.title) == ["Your voices", "Reference voices for cloning", "Qwen3-TTS 1.7B presets",
                                    "Voxtral TTS 4B presets", "Kokoro 82M (fast draft) presets"])
}

@Test func filtersByLanguageGenderEngineLicenceAndSearch() throws {
    let f = try VoiceFixtures()
    let options = VoiceCatalog.options(engines: f.engines, voices: f.voices)
    func ids(_ filter: VoiceFilter, book: String? = "fr") -> Set<String> {
        Set(options.filter { filter.matches($0, engines: f.engines, bookLanguage: book) }.map(\.voiceId))
    }

    // Book language (French) and male voices.
    var filter = VoiceFilter()
    filter.gender = "male"
    #expect(ids(filter) == ["fr_male", "fr_cmltts_7142_male", "fr_kyutai_fabieng_male"])

    // No book open: the book-language filter keeps every language.
    #expect(ids(VoiceFilter(), book: nil).count == options.count)
    #expect(ids(VoiceFilter(language: .only("en")), book: "fr").contains("ryan"))

    // French voices usable commercially: Kokoro's Siwis and the five library voices (cloned by Qwen3).
    filter = VoiceFilter(license: .commercial)
    #expect(ids(filter) == ["ff_siwis", "fr_siwis_female_book", "fr_kyutai_estelle_female", "fr_cmltts_12205_female",
                            "fr_cmltts_7142_male", "fr_kyutai_fabieng_male"])
    filter.license = .personal
    #expect(ids(filter) == ["fr_female", "fr_male"])
    // Restricted to Fish, every reference voice becomes personal use only.
    filter.engineId = "fish"
    #expect(ids(filter).count == 5 && !ids(filter).contains("fr_female"))

    filter = VoiceFilter(language: .all, search: "librivox")
    #expect(ids(filter).contains("fr_cmltts_7142_male") && ids(filter).contains("en_librittsr_bill_boerst_male_us"))
    #expect(!ids(filter).contains("ryan"))
    #expect(ids(VoiceFilter(language: .all, search: "SÉRENA")) == ["serena"])   // case and accent insensitive

    #expect(!VoiceFilter().isNarrowed && VoiceFilter(gender: "female").isNarrowed)
}

// MARK: - Choosing a narrator

@MainActor
@Test func choosingVoicesAndEnginesFeedsTheSelection() throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f, book: "inspect_fr.json")
    defer { defaults.removePersistentDomain(forName: suite) }

    // French book: the suggestion clones the first French library voice with Qwen3.
    #expect(model.voiceSelection?.engineId == "qwen3" && model.voiceSelection?.refVoiceId == "fr_siwis_female_book")
    model.voiceSelection?.speed = 1.25

    // Switching to Voxtral picks its French preset and keeps the speed; speech check follows the engine default.
    let voxtral = try #require(model.voiceSelection(switchingTo: "voxtral"))
    #expect(voxtral.presetId == "fr_female" && voxtral.speed == 1.25 && voxtral.verify)
    // Fish clones too: the current reference voice is kept.
    let fish = try #require(model.voiceSelection(switchingTo: "fish"))
    #expect(fish.refVoiceId == "fr_siwis_female_book" && fish.speed == 1.25)
    // Kokoro: its only French voice, speech check off.
    let kokoro = try #require(model.voiceSelection(switchingTo: "kokoro"))
    #expect(kokoro.presetId == "ff_siwis" && !kokoro.verify)
    // The engine in use returns the current narrator unchanged.
    #expect(model.voiceSelection(switchingTo: "qwen3") == model.voiceSelection)
    #expect(model.voiceSelection(switchingTo: "nope") == nil)

    // A saved default for the language wins when it uses that engine.
    model.settings.defaultVoices["fr"] = VoiceSelection(engineId: "voxtral", presetId: "fr_male", speed: 0.9)
    #expect(model.voiceSelection(switchingTo: "voxtral")?.presetId == "fr_male")

    // A reference voice row: cloned by the current engine when it can clone.
    let options = model.voiceOptions
    let estelle = try #require(options.first { $0.voiceId == "fr_kyutai_estelle_female" })
    #expect(model.voiceSelection(for: estelle)?.engineId == "qwen3")
    #expect(model.voiceSelection(for: estelle, preferredEngine: "fish")?.engineId == "fish")
    // From an engine that cannot clone: the best cloning engine (installed, commercial use first).
    model.performVoiceAction(.select(kokoro))
    #expect(model.voiceSelection?.engineId == "kokoro")
    let cloned = try #require(model.voiceSelection(for: estelle))
    #expect(cloned.engineId == "qwen3" && cloned.refVoiceId == "fr_kyutai_estelle_female" && cloned.verify)
    #expect(estelle.isChosen(by: cloned) && !estelle.isChosen(by: kokoro))

    // A preset row keeps the speech-check choice when the engine does not change.
    model.voiceSelection?.verify = true
    let siwisPreset = try #require(options.first { $0.id == "preset:kokoro:ff_siwis" })
    #expect(model.voiceSelection(for: siwisPreset)?.verify == true)

    #expect(VoiceCatalog.cloningEngine(candidates: ["qwen3", "fish"], current: nil, preferred: nil,
                                       engines: f.engines, models: f.models) == "qwen3")
    var noQwen = f.models
    noQwen[0].installed = false
    #expect(VoiceCatalog.cloningEngine(candidates: ["qwen3", "fish"], current: nil, preferred: nil,
                                       engines: f.engines, models: noQwen) == "fish")
}

@MainActor
@Test func licenceGateAsksOncePerEngine() throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f, book: "inspect_en.json")
    defer { defaults.removePersistentDomain(forName: suite) }

    let ryan = VoiceSelection(engineId: "qwen3", presetId: "ryan")
    let voxtral = VoiceSelection(engineId: "voxtral", presetId: "neutral_male")
    let fish = VoiceSelection(engineId: "fish", refVoiceId: "en_vctk_p225_female_uk")
    #expect(model.engineNeedingLicense(for: .select(ryan)) == nil)
    #expect(model.engineNeedingLicense(for: .select(voxtral))?.id == "voxtral")
    #expect(model.engineNeedingLicense(for: .preview(fish))?.id == "fish")
    #expect(model.engineNeedingLicense(for: .compare(voxtral, fish))?.id == "voxtral")

    model.settings.acknowledgeLicense(engine: "voxtral")
    #expect(model.engineNeedingLicense(for: .select(voxtral)) == nil)
    #expect(model.engineNeedingLicense(for: .compare(voxtral, fish))?.id == "fish")
    model.settings.acknowledgeLicense(engine: "fish")
    #expect(model.engineNeedingLicense(for: .compare(voxtral, fish)) == nil)
    // Remembered in Settings.
    #expect(AppSettings(defaults: defaults).hasAcknowledgedLicense(engine: "fish"))
}

// MARK: - Engine cards

@MainActor
@Test func engineCardsShowInstallSpeedAndSlowWarning() throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f, book: "inspect_fr.json")
    defer { defaults.removePersistentDomain(forName: suite) }

    let fishCard = model.voiceEngineSummary(for: try #require(model.engineList?.engine("fish")))
    #expect(fishCard.rateIsExactVoice && fishCard.rate?.voice == "fr_siwis_female_book")
    #expect(fishCard.isSlowerThanRealTime)
    #expect(fishCard.slowWarning == "Slower than real time on this Mac (0.56×): one hour of audio takes about 1 h 47 min to make.")
    #expect(fishCard.install == .installed(bytes: 6_731_423_034))
    #expect(fishCard.capabilitiesText == "Voice cloning only" && fishCard.languagesText == "English, French")
    #expect(!fishCard.isChosen)
    // 412,027 characters at 10.02 characters/s.
    #expect(abs((fishCard.bookEstimate?.seconds ?? 0) - 412_027 / 10.02) < 0.01)

    let qwenCard = model.voiceEngineSummary(for: try #require(model.engineList?.engine("qwen3")))
    #expect(qwenCard.isChosen && qwenCard.rate?.measurement.charsPerS == 51.04 && qwenCard.slowWarning == nil)
    #expect(qwenCard.rateVoiceName == "SIWIS — studio narrator (F)")

    // Kokoro on an English voice that was never measured: the median of its measured voices.
    model.voiceSelection = VoiceSelection(engineId: "kokoro", presetId: "am_adam")
    let kokoroCard = model.voiceEngineSummary(for: try #require(model.engineList?.engine("kokoro")))
    #expect(!kokoroCard.rateIsExactVoice && kokoroCard.rate?.measurement.charsPerS == 188.33)
    #expect(kokoroCard.rateVoiceName == "Siwis")

    // Not installed / unknown install state.
    var models = f.models
    models[1].installed = false
    model.preload(models: models)
    #expect(model.voiceEngineSummary(for: try #require(model.engineList?.engine("voxtral"))).install == .notInstalled(downloadGb: 2.5))
    #expect(model.isEngineMissing("voxtral") && !model.isSpeechCheckModelMissing)
    #expect(model.voicePreviewProblem(VoiceSelection(engineId: "voxtral", presetId: "fr_female")) == "Voxtral TTS 4B is not installed. Download it first.")
}

// MARK: - Previews and A/B

@MainActor
@Test func previewProblemsExplainWhatIsMissing() throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f)
    defer { defaults.removePersistentDomain(forName: suite) }

    let ryan = VoiceSelection(engineId: "qwen3", presetId: "ryan")
    #expect(model.voicePreviewProblem(ryan) == "Open a book to hear voices reading it.")
    #expect(model.startVoicePreview(ryan) == nil)

    let info = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/books/verne.epub"), info: info, coverURL: nil)
    #expect(model.voicePreviewProblem(nil) == "Choose a voice first.")
    #expect(model.voicePreviewProblem(ryan) == "This voice does not read French, the book's language.")
    #expect(model.voicePreviewProblem(VoiceSelection(engineId: "fish")) == "Fish Audio S2 Pro needs a reference voice. Choose one in the list below.")
    #expect(model.voicePreviewProblem(VoiceSelection(engineId: "kokoro", presetId: "ff_siwis")) == nil)

    var voices = f.voices
    voices[1].installed = false
    model.preload(voices: voices)
    #expect(model.voicePreviewProblem(VoiceSelection(engineId: "qwen3", refVoiceId: voices[1].id)) == "Install “Estelle (F)” first.")
}

@MainActor
@Test func previewsAreKeptPerBookSectionAndVoice() async throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f, book: "inspect_fr.json")
    defer { defaults.removePersistentDomain(forName: suite) }
    let draft = try #require(model.draft)

    let siwis = VoiceSelection(engineId: "kokoro", presetId: "ff_siwis")
    let run = try #require(model.startVoicePreview(siwis))
    #expect(run.voice == siwis && run.section == nil && run.language == "fr")
    // The engine path does not exist, so the run fails without starting anything; until then it is reused.
    if run.isRunning { #expect(model.startVoicePreview(siwis) === run) }
    #expect(model.voicePreview(for: siwis) === run)
    #expect(model.samples.first === run)

    // Another section is another preview; the section is remembered per book.
    let section = try #require(draft.sections.first { $0.index == 5 })
    model.voiceLab.setPreviewSection(section.index, for: draft)
    #expect(model.voiceLab.previewSection(for: draft) == 5)
    #expect(model.voicePreview(for: siwis) == nil)
    let second = try #require(model.startVoicePreview(siwis))
    #expect(second !== run && second.section == 5)
    // An index the book does not have falls back to the first chapter.
    model.voiceLab.setPreviewSection(9_999, for: draft)
    #expect(model.voiceLab.previewSection(for: draft) == nil)
    #expect(model.voicePreview(for: siwis) === run)

    // The lab survives: the same object for the same model, another one for another model.
    #expect(model.voiceLab === model.voiceLab)
    let (other, otherDefaults, otherSuite) = try makeModel(f)
    defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
    #expect(other.voiceLab !== model.voiceLab)

    // A failed preview is not reused.
    let deadline = Date().addingTimeInterval(5)
    while run.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(run.phase == .failed && run.error?.engineMissing == true)
    #expect(!run.isReusablePreview)
    let retry = try #require(model.startVoicePreview(siwis))
    #expect(retry !== run)
}

@MainActor
@Test func comparisonReadsTheSamePassageWithTwoVoices() throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f, book: "inspect_fr.json")
    defer { defaults.removePersistentDomain(forName: suite) }

    let choices = model.voiceComparisonChoices
    // French: Qwen3 clones (5), Voxtral presets (2), Fish clones (5), Kokoro's Siwis (1).
    #expect(choices.count == 13)
    #expect(choices.first?.id == "qwen3|fr_siwis_female_book")
    #expect(choices.contains { $0.id == "voxtral|fr_female" && $0.label == "French female · Voxtral TTS 4B" })

    // Defaults: A is the narrator, B the next voice; picks that disappear fall back.
    var ids = model.resolvedComparisonIds(in: choices)
    #expect(ids.a == "qwen3|fr_siwis_female_book" && ids.b == "qwen3|fr_kyutai_estelle_female")
    model.voiceLab.compareAId = "kokoro|ff_siwis"
    model.voiceLab.compareBId = "kokoro|ff_siwis"
    ids = model.resolvedComparisonIds(in: choices)
    #expect(ids.a == "kokoro|ff_siwis" && ids.b == "qwen3|fr_siwis_female_book")

    // Both sides run at the narrator's speed.
    model.voiceSelection?.speed = 1.1
    let a = model.voiceSelection(for: try #require(choices.first { $0.id == "kokoro|ff_siwis" }))
    let b = model.voiceSelection(for: try #require(choices.first { $0.id == "qwen3|fr_siwis_female_book" }))
    #expect(a.speed == 1.1 && !a.verify && b == model.voiceSelection)

    #expect(model.startVoiceComparison(a, a) == nil)
    let started = model.performVoiceAction(.compare(a, b))
    #expect(started.count == 2 && started[0].section == started[1].section)
    let comparison = try #require(model.currentVoiceComparison)
    #expect(comparison.a.voice == a && comparison.b.voice == b && comparison.a.section == comparison.b.section)
    #expect(model.voiceComparisonRuns.a === started[0] && model.voiceComparisonRuns.b === started[1])
    // The comparison reuses the previews (same book, section and voice).
    #expect(model.voicePreview(for: a) === started[0])

    // Another book: the comparison is not shown.
    let info = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/books/pp.epub"), info: info, coverURL: nil)
    #expect(model.currentVoiceComparison == nil)
}

// MARK: - Add my voice and wording

@Test func addVoiceFormNeedsFileNameAndConsent() {
    var form = AddVoiceForm(language: "fr", languages: ["en", "fr"])
    #expect(form.language == "fr" && AddVoiceForm(language: "de", languages: ["en", "fr"]).language == "en")
    #expect(AddVoiceForm(language: "fr").language == "en")      // French is optional: not offered until it is turned on
    #expect(form.missingStep == "Choose a recording." && !form.canSubmit)
    form.chooseFile(URL(fileURLWithPath: "/clips/my_voice-take2.wav"))
    #expect(form.name == "My voice take2")
    form.name = "  "
    #expect(form.missingStep == "Give the voice a name.")
    form.chooseFile(URL(fileURLWithPath: "/clips/grand-pere.m4a"))
    #expect(form.name == "Grand pere")
    form.chooseFile(URL(fileURLWithPath: "/clips/other.wav"))
    #expect(form.name == "Grand pere")   // a typed or suggested name is kept
    #expect(form.missingStep == "Confirm that you have the right to use this voice.")
    form.hasRights = true
    #expect(form.canSubmit && form.transcriptArgument == nil)
    form.transcript = "  Bonjour à tous.\n"
    #expect(form.transcriptArgument == "Bonjour à tous.")
}

@MainActor
@Test func addVoiceRefusesWithoutConsent() async throws {
    let f = try VoiceFixtures()
    let (model, defaults, suite) = try makeModel(f)
    defer { defaults.removePersistentDomain(forName: suite) }
    await #expect(throws: EngineError.self) {
        try await model.addVoice(file: URL(fileURLWithPath: "/clips/me.wav"), name: "Me", language: "en",
                                 transcript: nil, hasRights: false)
    }
}

@Test func voiceWording() {
    #expect(VoiceText.speed(1) == "1×" && VoiceText.speed(1.25) == "1.25×" && VoiceText.speed(0.75) == "0.75×")
    #expect(VoiceText.gender("female") == "Female" && VoiceText.gender(nil) == nil && VoiceText.gender(" ") == nil)
    #expect(VoiceText.list(["A"]) == "A" && VoiceText.list(["A", "B"]) == "A and B")
    #expect(VoiceText.list(["A", "B", "C"], conjunction: "or") == "A, B or C" && VoiceText.list([]) == "")
    #expect(VoiceText.transcriptSource("whisper").hasPrefix("Transcribed automatically"))
    #expect(VoiceText.transcriptSource("user") == "Transcript corrected by you.")
    #expect(VoiceText.slowWarning(realtimeX: 0.5) == "Slower than real time on this Mac (0.5×): one hour of audio takes about 2 h to make.")
}
