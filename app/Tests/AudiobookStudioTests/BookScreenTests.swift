import Foundation
import Testing
@testable import AudiobookStudio

// Logic behind the "New audiobook" screen (State/AppModel+Book.swift), driven by the real engine fixtures.

@MainActor
private func makeModel() throws -> (AppModel, () -> Void) {
    let suite = "AudiobookStudioBookTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(settings: AppSettings(defaults: defaults))
    return (model, { defaults.removePersistentDomain(forName: suite) })
}

private func draft(_ fixture: String, path: String = "/Books/Austen/book.epub") throws -> BookDraft {
    let info = try Fixtures.decode(fixture, as: BookInfo.self)
    return BookDraft(url: URL(fileURLWithPath: path), info: info, coverURL: nil)
}

// MARK: - Draft helpers

@Test func draftSelectionHelpers() throws {
    var en = try draft("inspect_en.json")
    #expect(en.isEngineSelection && en.isAllChaptersSelection)
    #expect(en.selectionSummary == "62 of 66 sections")
    #expect(en.detailsLine == "EPUB · 66 sections · 1998")
    #expect(en.publicationYear == "1998" && en.formatName == "EPUB")

    en.setIncluded(0, true)          // tick the Gutenberg header
    en.setIncluded(10, false)        // untick a chapter
    #expect(!en.isEngineSelection && !en.isAllChaptersSelection)
    en.selectAllChapters()
    #expect(en.sectionsArgument == "2-63" && en.isEngineSelection)

    // The French book's printed table of contents is front matter: "all chapters" leaves it out.
    var fr = try draft("inspect_fr.json")
    fr.setAll(true)
    #expect(fr.sectionsArgument == "0-41")
    fr.selectAllChapters()
    #expect(fr.sectionsArgument == "3-39" && fr.isEngineSelection)

    fr.setAll(false)
    #expect(fr.sampleSourceSections.count == fr.sections.count)   // nothing ticked: every section is offered
    fr.setIncluded(5, true)
    #expect(fr.sampleSourceSections.map(\.index) == [5])
}

@Test func publicationYearNeedsADate() throws {
    var en = try draft("inspect_en.json")
    en.info.metadata?.date = "circa 1813"
    #expect(en.publicationYear == nil)
    en.info.metadata?.publisher = "  T. Egerton  "
    #expect(en.detailsLine == "EPUB · 66 sections · T. Egerton")
    en.info.metadata = nil
    #expect(en.detailsLine == "EPUB · 66 sections")
}

// MARK: - Sample projection

@Test func sampleProjectionUsesEngineNumbersForTheSuggestedSelection() throws {
    let result = try #require(try Fixtures.events("sample_events.jsonl").last)
    var en = try draft("inspect_en.json")

    let engine = BookSampleProjection(result: result, draft: en)
    #expect(!engine.coversCustomSelection)
    #expect(engine.projectedSeconds == 5961 && engine.projectedChars == 708_164)
    #expect(engine.reusedCachedAudio)              // chars_synthesized 0: speed saved earlier
    #expect(engine.realtimeX == nil)               // realtime_x is null in the fixture
    #expect(engine.speedText == "119 characters/s")
    #expect(engine.note.hasPrefix("Projection from this sample"))
    #expect(engine.projectionText(sectionCount: nil) == "≈ 1 h 39 min for the book (708,164 characters)")

    // A custom selection is projected from the sample's measured speed.
    en.selectAllChapters()
    en.setAll(false)
    en.setIncluded(3, true)
    let custom = BookSampleProjection(result: result, draft: en)
    #expect(custom.coversCustomSelection && custom.projectedChars == 4_417)
    #expect(abs((custom.projectedSeconds ?? 0) - 4_417 / 118.8) < 0.001)
    #expect(custom.projectionText(sectionCount: 1) == "≈ 37 s for the selected section (4,417 characters)")
}

@Test func sampleProjectionWithoutSpeed() {
    let result = EngineEvent(event: "sample_done", audioS: 118, charsSynthesized: 1500, note: "  ")
    let p = BookSampleProjection(result: result, draft: nil)
    #expect(p.projectedSeconds == nil && p.projectionText(sectionCount: nil) == nil && p.speedText == nil)
    #expect(!p.reusedCachedAudio && p.note == BookSampleProjection.defaultNote)

    let measured = EngineEvent(event: "sample_done", rateCps: 43.5, realtimeX: 3.34, bookChars: 1000)
    let q = BookSampleProjection(result: measured, draft: nil)
    #expect(q.speedText == "44 characters/s · 3.3× real time")
    #expect(abs((q.projectedSeconds ?? 0) - 1000 / 43.5) < 0.001)   // no engine projection: chars ÷ speed
}

// MARK: - Problems before a sample or a conversion

@MainActor
@Test func blockersBeforeSampleAndConvert() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    var models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self),
                  models: models, voices: try Fixtures.decode("voices_list.json", as: VoiceList.self).voices)
    model.draft = try draft("inspect_en.json")

    #expect(model.bookBlocker(voice: nil, forConversion: false) == .noVoice)
    let ryan = VoiceSelection(engineId: "qwen3", presetId: "ryan")
    #expect(model.bookBlocker(voice: ryan, forConversion: true) == nil)

    model.draft?.setAll(false)
    #expect(model.bookBlocker(voice: ryan, forConversion: true) == .noSelection)
    #expect(model.bookBlocker(voice: ryan, forConversion: false) == nil)   // a sample needs no selection
    model.draft?.resetSelection()

    let clone = VoiceSelection(engineId: "qwen3", refVoiceId: "user-gone")
    #expect(model.bookBlocker(voice: clone, forConversion: true) == .voiceNotInstalled(voiceName: "user-gone"))

    let index = try #require(models.firstIndex { $0.engine == "qwen3" })
    models[index].installed = false
    model.preload(models: models)
    let blocker = model.bookBlocker(voice: ryan, forConversion: true)
    #expect(blocker == .modelMissing(engineName: "Qwen3-TTS 1.7B", downloadGb: 6.2))
    #expect(blocker?.message == "The Qwen3-TTS 1.7B model is not downloaded yet (6.2 GB). Download it in Models first.")
    #expect(blocker?.fixDestination == .models && BookBlocker.noVoice.fixDestination == .voices)
}

@MainActor
@Test func voiceLanguageWarnings() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    var list = try Fixtures.decode("engines.json", as: EngineList.self)
    model.preload(engines: list, voices: try Fixtures.decode("voices_list.json", as: VoiceList.self).voices)

    let ryan = VoiceSelection(engineId: "qwen3", presetId: "ryan")
    #expect(model.bookVoiceWarning(voice: ryan, language: "en") == nil)
    let warning = model.bookVoiceWarning(voice: ryan, language: "fr")
    #expect(warning?.message == "Ryan is an English voice and this book is in French.")
    let siwis = VoiceSelection(engineId: "qwen3", refVoiceId: "fr_siwis_female_book")
    #expect(model.bookVoiceWarning(voice: siwis, language: "fr") == nil)
    #expect(model.bookVoiceWarning(voice: siwis, language: "en")?.message
        == "SIWIS — studio narrator (F) is a French voice and this book is in English.")

    let k = try #require(list.engines.firstIndex { $0.id == "kokoro" })
    list.engines[k].languages = ["en"]
    model.preload(engines: list)
    #expect(model.bookVoiceWarning(voice: VoiceSelection(engineId: "kokoro", presetId: "ff_siwis"), language: "fr")
        == .engineLanguage(engineName: "Kokoro 82M (fast draft)", language: "fr"))
    #expect(model.bookVoiceWarning(voice: nil, language: "fr") == nil)
}

@MainActor
@Test func licenceAcknowledgedOncePerEngine() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self),
                  voices: try Fixtures.decode("voices_list.json", as: VoiceList.self).voices)
    let voxtral = VoiceSelection(engineId: "voxtral", presetId: "fr_female")
    #expect(model.bookLicenseToAcknowledge(voice: voxtral)?.id == "voxtral")
    #expect(model.bookLicenseToAcknowledge(voice: VoiceSelection(engineId: "kokoro", presetId: "af_heart")) == nil)
    model.settings.acknowledgeLicense(engine: "voxtral")
    #expect(model.bookLicenseToAcknowledge(voice: voxtral) == nil)
    #expect(!model.bookVoiceIsPersonalUseOnly(VoiceSelection(engineId: "qwen3", refVoiceId: "fr_siwis_female_book")))
}

@MainActor
@Test func slowEngineWarningUsesMeasuredSpeed() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    var list = try Fixtures.decode("engines.json", as: EngineList.self)
    model.preload(engines: list)

    // Fish measured at 0.56× real time with this voice.
    let fish = VoiceSelection(engineId: "fish", refVoiceId: "fr_siwis_female_book")
    let warning = try #require(model.bookSlowEngineWarning(voice: fish, chars: 412_027))
    #expect(warning.title == "Fish Audio S2 Pro is slower than real time")
    #expect(warning.message.contains("0.56× real time"))
    #expect(warning.message.contains(Formatters.estimate(412_027 / 10.02)))

    // Faster than real time: no warning.
    #expect(model.bookSlowEngineWarning(voice: VoiceSelection(engineId: "kokoro", presetId: "af_bella"), chars: 705_384) == nil)
    #expect(model.bookSlowEngineWarning(voice: VoiceSelection(engineId: "qwen3", presetId: "ryan"), chars: 705_384) == nil)

    // Never measured: Fish is still known to be slow, other engines are not warned about.
    list.measured = [:]
    model.preload(engines: list)
    let unmeasured = try #require(model.bookSlowEngineWarning(voice: fish, chars: 412_027))
    #expect(unmeasured.message.contains("has not been measured on this Mac"))
    #expect(model.bookSlowEngineWarning(voice: VoiceSelection(engineId: "voxtral", presetId: "fr_female"), chars: 1000) == nil)
}

// MARK: - Language, output folder, estimate basis

@MainActor
@Test func languageChoicesIncludeTheBookLanguage() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(model.bookLanguageChoices == ["en", "fr"])          // engines not loaded yet
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self))
    var book = try draft("inspect_fr.json")
    book.info.language = "de"
    book.language = "de"
    model.draft = book
    #expect(model.bookLanguageChoices == ["en", "fr", "de"])    // English, French, German
}

@MainActor
@Test func outputLocation() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(model.bookOutputLocation == nil)
    model.draft = try draft("inspect_en.json", path: "/Books/Austen/book.epub")
    let nextToBook = try #require(model.bookOutputLocation)
    #expect(nextToBook.title == "Next to the book" && !nextToBook.isCustom)
    #expect(nextToBook.folderURL.path == "/Books/Austen" && nextToBook.detail == "/Books/Austen")

    model.settings.outputFolder = NSHomeDirectory() + "/Audiobooks"
    let custom = try #require(model.bookOutputLocation)
    #expect(custom.isCustom && custom.title == "Audiobooks" && custom.detail == "~/Audiobooks")
}

@Test func estimateBasisText() throws {
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let exact = try #require(list.measurement(engine: "kokoro", voice: "af_bella"))
    let estimate = ConversionEstimate(seconds: 2816, charsPerSecond: exact.measurement.charsPerS,
                                      exactVoice: exact.exactVoice, measurement: exact.measurement)
    #expect(estimate.bookBasisText == "Speed measured on this Mac with this voice: 250 characters/s (conversion, Oct 9)")

    let other = try #require(list.measurement(engine: "kokoro", voice: "am_adam"))
    let fallback = ConversionEstimate(seconds: 1, charsPerSecond: other.measurement.charsPerS,
                                      exactVoice: other.exactVoice, measurement: other.measurement)
    #expect(fallback.bookBasisText == "Speed measured on this Mac with another voice of this engine: 188 characters/s (sample, Oct 9)")
}

@MainActor
@Test func sampleMenuTitles() throws {
    let en = try draft("inspect_en.json")
    #expect(BookSamplePanel.menuTitle(en.sections[3]) == "Chapter I.")
    #expect(BookSamplePanel.menuTitle(en.sections[64]) == "Project Gutenberg license (back)")
    #expect(BookSamplePanel.menuTitle(en.sections[1]) == en.sections[1].title + " (front)")   // 60 characters fit
    let fr = try draft("inspect_fr.json")
    #expect(BookSamplePanel.menuTitle(fr.sections[3]) == "Chapter I")        // bare Roman numeral
    #expect(BookSamplePanel.menuTitle(fr.sections[1]) == "LE TOUR DU MONDE EN QUATRE-VINGTS JOURS (front)")
    var long = en.sections[1]
    long.title = String(repeating: "a", count: 80)
    #expect(BookSamplePanel.menuTitle(long) == String(repeating: "a", count: 59) + "… (front)")
}

@MainActor
@Test func bookSampleNeedsABookAndAVoice() throws {
    let (model, cleanup) = try makeModel()
    defer { cleanup() }
    #expect(model.startBookSample(section: nil) == nil)      // no book open
    model.draft = try draft("inspect_en.json")
    model.voiceSelection = nil
    #expect(model.startBookSample(section: 3) == nil)        // no voice (engines not loaded)
    #expect(AppModel.bookSampleSeconds == 120)
}
