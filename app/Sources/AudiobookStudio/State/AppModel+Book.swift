import AppKit
import Foundation

// Logic behind the "New audiobook" screen (Views/Book): what stops a sample or a conversion, warnings
// about the chosen voice, the licence and slow-engine checks before converting, the sample projection
// and the output folder. Kept out of the views so it can be unit tested.

// MARK: - Problems and warnings

/// Something that stops the book's sample or conversion from starting, and where to fix it.
enum BookBlocker: Hashable, Sendable {
    /// No narrator is chosen.
    case noVoice
    /// The chosen engine's model files are not downloaded (the engine never downloads during a job).
    case modelMissing(engineName: String, downloadGb: Double?)
    /// The chosen cloned voice is not installed (or no longer exists).
    case voiceNotInstalled(voiceName: String)
    /// Every section is unticked (conversion only).
    case noSelection
    /// A non-commercial engine's licence has not been acknowledged and cannot be shown yet: the engine
    /// list (which holds the licence) is not loaded (`AppModel.licenseWaitsForEngineList`).
    case licenseNotShownYet

    var message: String {
        switch self {
        case .noVoice:
            return "Choose a narrator voice first."
        case let .modelMissing(name, gb):
            let size = gb.map { " (\(Formatters.gigabytes($0)))" } ?? ""
            return "The \(name) model is not downloaded yet\(size). Download it in Models first."
        case .voiceNotInstalled(let name):
            return "The voice “\(name)” is not installed. Install it or choose another voice."
        case .noSelection:
            return "Tick at least one section to convert."
        case .licenseNotShownYet:
            return "This engine is for non-commercial use only, and its licence is shown before the first use. "
                + "Waiting for the engine list to load."
        }
    }

    /// Title of the button that leads to the fix (nil when it is fixed on this screen).
    var fixTitle: String? {
        switch self {
        case .noVoice, .voiceNotInstalled: return "Choose Voice…"
        case .modelMissing: return "Open Models"
        case .noSelection, .licenseNotShownYet: return nil
        }
    }

    /// Screen that fixes the problem.
    var fixDestination: SidebarItem? {
        switch self {
        case .noVoice, .voiceNotInstalled: return .voices
        case .modelMissing: return .models
        case .noSelection, .licenseNotShownYet: return nil
        }
    }
}

/// A non-blocking problem with the chosen voice for this book (the engine does not check languages).
enum BookVoiceWarning: Hashable, Sendable {
    /// The engine does not list the book's language.
    case engineLanguage(engineName: String, language: String)
    /// The preset or cloned voice speaks another language than the book.
    case voiceLanguage(voiceName: String, voiceLanguage: String, bookLanguage: String)

    var message: String {
        switch self {
        case let .engineLanguage(engine, language):
            return "\(engine) does not list \(Formatters.languageName(language)) among its languages."
        case let .voiceLanguage(voice, voiceLanguage, bookLanguage):
            return "\(voice) is a\(Self.article(for: voiceLanguage)) \(Formatters.languageName(voiceLanguage)) voice "
                + "and this book is in \(Formatters.languageName(bookLanguage))."
        }
    }

    private static func article(for language: String) -> String {
        let first = Formatters.languageName(language).lowercased().first
        return first.map { "aeiou".contains($0) } == true ? "n" : ""
    }
}

/// Confirmation shown before converting with an engine that is slower than real time.
struct BookSlowEngineWarning: Hashable, Sendable, Identifiable {
    var title: String
    var message: String
    var id: String { title + message }
}

// MARK: - Output folder

/// Where the finished audiobook goes, for the "Save to" row.
struct BookOutputLocation: Hashable, Sendable {
    /// "Next to the book" or the chosen folder's name.
    var title: String
    /// Folder path with "~" for the home folder.
    var detail: String
    /// The folder the audiobook will be written to.
    var folderURL: URL
    /// True when the user chose a folder in Settings or here (false: next to the book).
    var isCustom: Bool

    init(outputFolder: URL?, bookURL: URL) {
        if let outputFolder {
            folderURL = outputFolder
            title = outputFolder.lastPathComponent.isEmpty ? outputFolder.path : outputFolder.lastPathComponent
            isCustom = true
        } else {
            folderURL = bookURL.deletingLastPathComponent()
            title = "Next to the book"
            isCustom = false
        }
        detail = (folderURL.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Sample projection

/// What a finished 2-minute sample says about this Mac: measured speed and projected conversion time.
/// Only engine numbers are shown: the engine's own projection when the selection is the engine's
/// suggestion, otherwise the selection's characters divided by the speed the sample measured.
struct BookSampleProjection: Hashable, Sendable {
    /// Length of the sample audio.
    var audioSeconds: Double?
    /// Narration speed measured by the sample (characters per second).
    var charsPerSecond: Double?
    /// Speed as a multiple of real time (nil when nothing was narrated).
    var realtimeX: Double?
    /// The engine reused audio cached from an earlier run: the speed is the one saved earlier on this Mac.
    var reusedCachedAudio: Bool
    /// Projected conversion time and the number of characters it covers (nil without a speed).
    var projectedSeconds: Double?
    var projectedChars: Int?
    /// True when the projection covers the user's own selection rather than the engine's suggested one.
    var coversCustomSelection: Bool
    /// The engine's caveat ("Projection from this sample; ... expect it to be optimistic.").
    var note: String

    static let defaultNote = "Projection from this sample; long jobs run warmer, expect it to be a little optimistic."

    init(result: EngineEvent, draft: BookDraft?) {
        let cps = result.rateCps.flatMap { $0 > 0 ? $0 : nil }
        audioSeconds = result.audioS
        charsPerSecond = cps
        realtimeX = result.realtimeX.flatMap { $0 > 0 ? $0 : nil }
        reusedCachedAudio = result.charsSynthesized == 0
        let note = result.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = note.isEmpty ? BookSampleProjection.defaultNote : note
        if let draft, !draft.isEngineSelection {
            coversCustomSelection = true
            projectedChars = draft.includedChars
            projectedSeconds = cps.map { Double(draft.includedChars) / $0 }
        } else {
            coversCustomSelection = false
            projectedChars = result.bookChars
            if let engineProjection = result.bookEstWallS {
                projectedSeconds = engineProjection
            } else if let chars = result.bookChars, let cps {
                projectedSeconds = Double(chars) / cps
            } else {
                projectedSeconds = nil
            }
        }
    }

    /// "43.5 characters/s · 3.3× real time".
    var speedText: String? {
        guard let cps = charsPerSecond else { return nil }
        let x = realtimeX.map { " · \(Formatters.realtime($0))" } ?? ""
        return Formatters.charsPerSecond(cps) + x
    }

    /// "≈ 4 h 30 min for the 61 selected sections (705,384 characters)"; `sectionCount` nil: "for the book".
    func projectionText(sectionCount: Int?) -> String? {
        guard let seconds = projectedSeconds else { return nil }
        var text = Formatters.estimate(seconds)
        switch sectionCount {
        case nil: text += " for the book"
        case 1?: text += " for the selected section"
        case let n?: text += " for the \(Formatters.count(n)) selected sections"
        }
        if let chars = projectedChars { text += " (\(Formatters.characters(chars)))" }
        return text
    }
}

// MARK: - Estimate basis

extension ConversionEstimate {
    /// Where the estimate's speed comes from, e.g.
    /// "Speed measured on this Mac with this voice: 250 characters/s (conversion, Oct 9)".
    var bookBasisText: String {
        let who = exactVoice ? "with this voice" : "with another voice of this engine"
        var details: [String] = []
        switch measurement.source {
        case "sample"?: details.append("sample")
        case "convert"?: details.append("conversion")
        case "benchmark"?: details.append("benchmark")
        case let other?: details.append(other)
        case nil: break
        }
        if let date = JobStatus.parseLocalDate(measurement.updated) {
            details.append(date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US"))))
        }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "Speed measured on this Mac \(who): \(Formatters.charsPerSecond(charsPerSecond))\(suffix)"
    }
}

// MARK: - BookDraft helpers

extension BookDraft {
    /// The engine's suggested selection (front and back matter unticked).
    var engineSelection: Set<Int> { Set(sections.filter(\.include).map(\.index)) }

    /// True while the selection is still the engine's suggestion.
    var isEngineSelection: Bool { included == engineSelection }

    /// Ticks every chapter and unticks front and back matter.
    mutating func selectAllChapters() {
        included = Set(sections.filter { $0.sectionKind == .chapter }.map(\.index))
    }

    /// True when every chapter and nothing else is ticked.
    var isAllChaptersSelection: Bool {
        included == Set(sections.filter { $0.sectionKind == .chapter }.map(\.index))
    }

    /// "EPUB", "PDF".
    var formatName: String { info.format.uppercased() }

    /// The year of the book's metadata date ("1998-06-01" → "1998"), when it starts with one.
    var publicationYear: String? {
        guard let date = info.metadata?.date?.trimmingCharacters(in: .whitespaces), date.count >= 4 else { return nil }
        let year = date.prefix(4)
        return year.allSatisfy(\.isNumber) ? String(year) : nil
    }

    /// "EPUB · 66 sections · 1998 · Penguin".
    var detailsLine: String {
        var parts = [formatName, sections.count == 1 ? "1 section" : "\(Formatters.count(sections.count)) sections"]
        if let year = publicationYear { parts.append(year) }
        if let publisher = info.metadata?.publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !publisher.isEmpty {
            parts.append(publisher)
        }
        return parts.joined(separator: " · ")
    }

    /// "61 of 66 sections".
    var selectionSummary: String {
        "\(Formatters.count(included.count)) of \(Formatters.count(sections.count)) sections"
    }

    /// Sections offered as sample sources: the ticked ones (all sections when none is ticked).
    var sampleSourceSections: [SectionInfo] {
        let ticked = includedSections
        return ticked.isEmpty ? sections : ticked
    }
}

// MARK: - AppModel

extension AppModel {
    /// Length of "Make a 2-minute sample".
    static let bookSampleSeconds: Double = 120

    /// Engines known to be slower than real time on Apple silicon (warned about before a conversion when
    /// this Mac has no measurement yet). Measured speeds always take precedence.
    static let bookSlowEngines: Set<String> = ["fish"]

    /// Languages offered in the book's language picker: every language an engine speaks plus the book's
    /// own, sorted by English name. English and French when the engines are not loaded yet.
    var bookLanguageChoices: [String] {
        var codes = engines.flatMap(\.languages)
        if codes.isEmpty { codes = ["en", "fr"] }
        if let draft { codes += [draft.info.language, draft.language] }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
            .sorted { Formatters.languageName($0) < Formatters.languageName($1) }
    }

    /// The engine card of the chosen voice.
    var bookSelectedEngine: EngineInfo? {
        voiceSelection.flatMap { engineList?.engine($0.engineId) }
    }

    /// The first problem that stops a sample (`forConversion: false`) or a conversion of the current book.
    /// Model and voice checks only apply once the model and voice lists are loaded.
    func bookBlocker(voice: VoiceSelection?, forConversion: Bool) -> BookBlocker? {
        guard let voice else { return .noVoice }
        if let status = models.first(where: { $0.engine == voice.engineId }), !status.installed {
            let name = engineList?.engine(voice.engineId)?.name ?? status.name
            return .modelMissing(engineName: name, downloadGb: status.downloadGb ?? engineList?.engine(voice.engineId)?.downloadGb)
        }
        if let ref = voice.refVoiceId, !voices.isEmpty {
            let entry = voices.first { $0.id == ref }
            if !(entry?.isInstalled ?? false) { return .voiceNotInstalled(voiceName: entry?.name ?? ref) }
        }
        if licenseWaitsForEngineList(voice.engineId) { return .licenseNotShownYet }
        if forConversion, !(draft?.hasSelection ?? false) { return .noSelection }
        return nil
    }

    /// A language mismatch between the chosen voice and the book (shown, but the engine is not stopped).
    func bookVoiceWarning(voice: VoiceSelection?, language: String) -> BookVoiceWarning? {
        guard let voice, let engine = engineList?.engine(voice.engineId) else { return nil }
        if !engine.languages.contains(language) {
            return .engineLanguage(engineName: engine.name, language: language)
        }
        guard let voiceLanguage = voice.language(engines: engines, voices: voices), voiceLanguage != language else {
            return nil
        }
        let name: String
        if let preset = voice.presetId {
            name = engine.voices.first { $0.id == preset }?.name ?? preset
        } else {
            name = voices.first { $0.id == voice.refVoiceId }?.name ?? voice.refVoiceId ?? "This voice"
        }
        return .voiceLanguage(voiceName: name, voiceLanguage: voiceLanguage, bookLanguage: language)
    }

    /// The non-commercial engine whose licence must be acknowledged before `voice` is used (nil when none).
    func bookLicenseToAcknowledge(voice: VoiceSelection?) -> EngineInfo? {
        guard let voice, let engine = engineList?.engine(voice.engineId), engine.noncommercial,
              !settings.hasAcknowledgedLicense(engine: engine.id) else { return nil }
        return engine
    }

    /// The licence to acknowledge before resuming `job` (nil when none): a job started from the terminal can
    /// use a non-commercial engine whose licence the app never showed.
    func licenseToAcknowledge(beforeResuming job: JobStatus) -> EngineInfo? {
        bookLicenseToAcknowledge(voice: job.engine.map { VoiceSelection(engineId: $0) })
    }

    /// Engines known to be for non-commercial use only. Consulted only while the engine list (which says
    /// so for every engine) is not loaded, so that their licence gate does not let them run unacknowledged.
    static let knownNoncommercialEngines: Set<String> = ["voxtral", "fish"]

    /// True while the engine list is not loaded and `engineId` is a known non-commercial engine whose licence
    /// is not acknowledged: the licence sheet cannot be shown yet, so the engine must not run.
    func licenseWaitsForEngineList(_ engineId: String) -> Bool {
        engineList == nil && AppModel.knownNoncommercialEngines.contains(engineId)
            && !settings.hasAcknowledgedLicense(engine: engineId)
    }

    /// True when the chosen cloned voice's licence does not allow commercial use.
    func bookVoiceIsPersonalUseOnly(_ voice: VoiceSelection?) -> Bool {
        guard let ref = voice?.refVoiceId, let entry = voices.first(where: { $0.id == ref }) else { return false }
        return entry.commercialOk == false
    }

    /// Asked before converting `chars` characters with an engine slower than real time on this Mac
    /// (measured), or, without a measurement, with an engine known to be slow. nil when no warning is due.
    func bookSlowEngineWarning(voice: VoiceSelection, chars: Int) -> BookSlowEngineWarning? {
        let name = engineList?.engine(voice.engineId)?.name ?? voice.engineId
        let title = "\(name) is slower than real time"
        if let measured = engineList?.measurement(engine: voice.engineId, voice: voice.voiceId) {
            guard let x = measured.measurement.realtimeX, x > 0, x < 1 else { return nil }
            var message = "On this Mac it narrates at \(Formatters.realtime(x)), so converting takes longer than listening."
            // The same speed as the totals bar estimate (`rate`: the median when the voice was not measured).
            if let cps = engineList?.rate(engine: voice.engineId, voice: voice.voiceId), cps > 0 {
                let seconds = Double(chars) / cps
                message += " This selection would take \(Formatters.estimate(seconds)), and long jobs tend to run a little slower."
            }
            message += " The conversion runs in the background and you can cancel it at any time."
            return BookSlowEngineWarning(title: title, message: message)
        }
        guard AppModel.bookSlowEngines.contains(voice.engineId) else { return nil }
        return BookSlowEngineWarning(
            title: title,
            message: "\(name) usually narrates slower than real time, so converting a whole book takes longer than "
                + "listening to it. Its speed has not been measured on this Mac yet: make a 2-minute sample first "
                + "to get an estimate.")
    }

    /// "Make a 2-minute sample" of the current book with the chosen voice (`section` nil: the engine
    /// picks the first chapter). nil when no book is open or no voice is chosen.
    @discardableResult
    func startBookSample(section: Int?) -> SampleRun? {
        startSample(section: section, seconds: AppModel.bookSampleSeconds)
    }

    /// Where the current book's audiobook will be saved.
    var bookOutputLocation: BookOutputLocation? {
        draft.map { BookOutputLocation(outputFolder: settings.outputFolderURL, bookURL: $0.url) }
    }

    /// Shows a folder picker and saves the choice as the output folder (also used for later books).
    func chooseBookOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolderURL ?? draft?.url.deletingLastPathComponent()
        panel.message = "Choose the folder where finished audiobooks are saved."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputFolderURL = url
    }
}
