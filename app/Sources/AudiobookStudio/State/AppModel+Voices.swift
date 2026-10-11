import Foundation

// State and rules behind the "Voices" screen: the voice catalogue and its filters, engine card facts,
// choosing a narrator (which always ends in `AppModel.voiceSelection`, so the Book screen, samples and
// conversions use it), licence acknowledgement for non-commercial engines, and ~20 s previews / A-B
// comparisons made with `AppModel.startSample`.

// MARK: - Voice catalogue

/// One voice the browser lists: an engine preset, or a reference voice that cloning engines imitate.
struct VoiceOption: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Built into an engine (`engines` → voices); used with `--voice`.
        case preset
        /// From the licence-checked library (`voices list`); used with `--ref-voice` once installed.
        case library
        /// The user's own clip (`voices add`, id "user-…").
        case userClip
    }

    /// Unique row id: "preset:<engine>:<voice>" or "ref:<voice>".
    var id: String
    /// The engine's voice id (`--voice` / `--ref-voice` value).
    var voiceId: String
    var name: String
    var language: String
    var gender: String?
    var accent: String?
    /// Preset note or reference voice description.
    var summary: String?
    var kind: Kind
    /// Engines that can speak with this voice: the preset's engine, or every cloning engine.
    var engineIds: [String]
    /// Licence of the voice itself; presets carry their engine's licence.
    var license: String?
    /// The voice's own licence allows commercial use (presets: true, the engine licence decides).
    var voiceAllowsCommercialUse: Bool
    /// Presets are always available; reference voices once downloaded or added.
    var installed: Bool
    /// The `voices list` entry of a reference voice.
    var entry: VoiceEntry?

    /// Other languages a preset can speak with an accent (the engine's `also`).
    var alsoLanguages: [String] = []

    var isReference: Bool { kind != .preset }

    /// True when the voice speaks `language` natively.
    func isNative(to language: String) -> Bool { self.language == language }

    /// True when the voice is another language's but can speak `language` with an accent.
    func speaksWithAccent(_ language: String) -> Bool { self.language != language && alsoLanguages.contains(language) }

    /// True when the voice and at least one engine that can use it (restricted to `engineFilter`) allow
    /// commercial use.
    func allowsCommercialUse(engines: [EngineInfo], engineFilter: String? = nil) -> Bool {
        guard voiceAllowsCommercialUse else { return false }
        return engineIds
            .filter { engineFilter == nil || $0 == engineFilter }
            .contains { id in engines.first { $0.id == id }.map { !$0.noncommercial } ?? false }
    }

    /// True when `selection` uses this voice (a reference voice is chosen whatever engine clones it).
    func isChosen(by selection: VoiceSelection?) -> Bool {
        guard let selection else { return false }
        switch kind {
        case .preset: return selection.presetId == voiceId && selection.engineId == engineIds.first
        case .library, .userClip: return selection.refVoiceId == voiceId
        }
    }
}

/// A titled group of browser rows ("Your voices", "Reference voices for cloning", "Kokoro 82M presets").
struct VoiceOptionGroup: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var options: [VoiceOption]
}

enum VoiceCatalog {
    /// Every preset of every engine (engine order), then the library and the user's clips (`voices list` order).
    static func options(engines: [EngineInfo], voices: [VoiceEntry]) -> [VoiceOption] {
        var out: [VoiceOption] = []
        for engine in engines where engine.supportsPresets {
            for preset in engine.voices {
                out.append(VoiceOption(
                    id: "preset:\(engine.id):\(preset.id)", voiceId: preset.id, name: preset.name, language: preset.lang,
                    gender: preset.gender, accent: preset.accent.flatMap(nonEmpty), summary: preset.note.flatMap(nonEmpty),
                    kind: .preset, engineIds: [engine.id], license: engine.license, voiceAllowsCommercialUse: true,
                    installed: true, entry: nil, alsoLanguages: preset.also ?? []))
            }
        }
        let cloning = engines.filter(\.supportsCloning).map(\.id)
        for voice in voices {
            out.append(VoiceOption(
                id: "ref:\(voice.id)", voiceId: voice.id, name: voice.name, language: voice.lang, gender: voice.gender,
                accent: nil, summary: voice.description.flatMap(nonEmpty), kind: voice.isUserClip ? .userClip : .library,
                engineIds: cloning, license: voice.license ?? (voice.isUserClip ? "Your recording" : nil),
                // The user confirmed their rights when adding a clip; library voices state it explicitly.
                voiceAllowsCommercialUse: voice.commercialOk ?? voice.isUserClip,
                installed: voice.isInstalled, entry: voice))
        }
        return out
    }

    /// Browser sections: the user's clips, the reference library, then one group per engine's presets.
    /// With `accentLanguage` (the language being browsed), presets of another language that speak it with an
    /// accent follow the native groups in groups of their own ("<Engine> · speaks Spanish with an accent").
    /// Starred voices (`favorites`, as `VoiceOption.id`) come first inside each group, keeping the catalogue order otherwise.
    static func groups(_ options: [VoiceOption], engines: [EngineInfo], accentLanguage: String? = nil,
                       favorites: Set<String> = []) -> [VoiceOptionGroup] {
        let options = favorites.isEmpty ? options
            : options.filter { favorites.contains($0.id) } + options.filter { !favorites.contains($0.id) }
        let isAccented: (VoiceOption) -> Bool = { o in accentLanguage.map(o.speaksWithAccent) ?? false }
        var groups: [VoiceOptionGroup] = []
        let clips = options.filter { $0.kind == .userClip }
        if !clips.isEmpty { groups.append(VoiceOptionGroup(id: "user", title: "Your voices", options: clips)) }
        let library = options.filter { $0.kind == .library }
        if !library.isEmpty {
            groups.append(VoiceOptionGroup(id: "library", title: "Reference voices for cloning", options: library))
        }
        for engine in engines {
            let presets = options.filter { $0.kind == .preset && $0.engineIds.first == engine.id && !isAccented($0) }
            if !presets.isEmpty {
                groups.append(VoiceOptionGroup(id: "preset:\(engine.id)", title: "\(engine.name) presets", options: presets))
            }
        }
        if let accentLanguage {
            let name = Formatters.languageName(accentLanguage)
            for engine in engines {
                let accented = options.filter { $0.kind == .preset && $0.engineIds.first == engine.id && isAccented($0) }
                if !accented.isEmpty {
                    groups.append(VoiceOptionGroup(id: "accent:\(engine.id)",
                                                   title: "\(engine.name) · speaks \(name) with an accent", options: accented))
                }
            }
        }
        return groups
    }

    /// The engine that clones a reference voice: `preferred` (the engine filter) when it can, else the
    /// current engine when it can, else installed engines first, commercial-use engines first, engine order.
    static func cloningEngine(candidates: [String], current: String?, preferred: String?,
                              engines: [EngineInfo], models: [ModelStatus]) -> String? {
        if let preferred, candidates.contains(preferred) { return preferred }
        if let current, candidates.contains(current) { return current }
        let installed = Set(models.filter(\.installed).map(\.engine))
        let ordered = engines.enumerated().filter { candidates.contains($0.element.id) }.sorted { a, b in
            let ai = models.isEmpty || installed.contains(a.element.id)
            let bi = models.isEmpty || installed.contains(b.element.id)
            if ai != bi { return ai }
            if a.element.noncommercial != b.element.noncommercial { return !a.element.noncommercial }
            return a.offset < b.offset
        }
        return ordered.first?.element.id
    }

    /// The measurement shown for an engine: the exact voice when measured, otherwise the middle one of the
    /// engine's measured voices, shown with that voice's name (the same row as `EngineList.measurement`).
    static func measuredRate(engine: String, voice: String?, in list: EngineList?) -> (rate: MeasuredRate, exactVoice: Bool)? {
        guard let list else { return nil }
        let all = list.measuredRates.filter { $0.engine == engine }
        if let voice, let exact = all.first(where: { $0.voice == voice }) { return (exact, true) }
        let sorted = all.sorted { $0.measurement.charsPerS < $1.measurement.charsPerS }
        guard !sorted.isEmpty else { return nil }
        return (sorted[sorted.count / 2], false)
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Filters

enum VoiceLanguageFilter: Hashable, Sendable {
    /// Follow the open book's language (all languages when no book is open).
    case book
    case all
    case only(String)
}

enum VoiceLicenseFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
    case any, commercial, personal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: return "Any licence"
        case .commercial: return "Commercial use allowed"
        case .personal: return "Personal use only"
        }
    }
}

/// Voice browser filters (language, gender, engine, licence, text search).
struct VoiceFilter: Hashable, Sendable {
    var language: VoiceLanguageFilter = .book
    /// "female" / "male"; nil = any.
    var gender: String?
    /// Only voices this engine can speak with; nil = all engines.
    var engineId: String?
    var license: VoiceLicenseFilter = .any
    var search = ""
    /// Only the voices the user starred (`AppSettings.favoriteVoices`).
    var favoritesOnly = false

    static let genders = ["female", "male"]

    /// The language code to keep, or nil for every language.
    func languageCode(bookLanguage: String?) -> String? {
        switch language {
        case .book: return bookLanguage
        case .all: return nil
        case .only(let code): return code
        }
    }

    /// True when something other than the default (book language) narrows the list.
    var isNarrowed: Bool { self != VoiceFilter() }

    func matches(_ option: VoiceOption, engines: [EngineInfo], bookLanguage: String?, favorites: Set<String> = []) -> Bool {
        if favoritesOnly, !favorites.contains(option.id) { return false }
        if let code = languageCode(bookLanguage: bookLanguage), option.language != code, !option.speaksWithAccent(code) { return false }
        if let gender, option.gender?.lowercased() != gender { return false }
        if let engineId, !option.engineIds.contains(engineId) { return false }
        switch license {
        case .any: break
        case .commercial: if !option.allowsCommercialUse(engines: engines, engineFilter: engineId) { return false }
        case .personal: if option.allowsCommercialUse(engines: engines, engineFilter: engineId) { return false }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let haystack = [option.name, option.voiceId, option.accent, option.summary, option.license]
                .compactMap { $0 }.joined(separator: " ")
            if haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }
        return true
    }
}

// MARK: - Engine cards

/// What an engine card shows: install state, speed measured on this Mac and the book estimate.
struct VoiceEngineSummary: Hashable, Sendable {
    enum Install: Hashable, Sendable {
        /// `models list` not loaded.
        case unknown
        case installed(bytes: Int64)
        case notInstalled(downloadGb: Double?)
    }

    var engine: EngineInfo
    var install: Install
    /// The narrator this card selects (the current one when it already uses this engine).
    var selection: VoiceSelection?
    /// Speed measured on this Mac (exact voice, or the engine's median).
    var rate: MeasuredRate?
    var rateIsExactVoice: Bool
    /// Display name of the measured voice.
    var rateVoiceName: String?
    /// Conversion time of the open book's selected sections at the measured speed.
    var bookEstimate: ConversionEstimate?
    var isChosen: Bool

    var isSlowerThanRealTime: Bool { (rate?.measurement.realtimeX ?? 1) < 1 }

    /// "Slower than real time on this Mac (0.56×): one hour of audio takes about 1 h 47 min to make."
    var slowWarning: String? {
        guard isSlowerThanRealTime, let x = rate?.measurement.realtimeX, x > 0 else { return nil }
        return VoiceText.slowWarning(realtimeX: x)
    }

    /// The languages to list on the card: the engine's, restricted to the enabled ones when `shownLanguages` is set.
    var shownLanguages: [String]?

    var languagesText: String { VoiceText.languages(shownLanguages ?? engine.languages) }
    var capabilitiesText: String { VoiceText.capabilities(engine) }
}

// MARK: - Actions and licence gate

/// Something the Voices screen does with an engine. Non-commercial engines need their licence
/// acknowledged once before any of these (`AppModel.engineNeedingLicense(for:)`).
enum VoiceAction: Hashable, Sendable {
    /// Make this the narrator (`AppModel.voiceSelection`).
    case select(VoiceSelection)
    /// ~20 s sample of the book with this voice.
    case preview(VoiceSelection)
    /// Samples of the same passage with two voices.
    case compare(VoiceSelection, VoiceSelection)

    var engineIds: [String] {
        switch self {
        case .select(let v), .preview(let v): return [v.engineId]
        case .compare(let a, let b): return a.engineId == b.engineId ? [a.engineId] : [a.engineId, b.engineId]
        }
    }
}

/// An A/B candidate: an engine + voice pair that reads the book's language.
struct VoiceChoice: Identifiable, Hashable, Sendable {
    /// "<engine>|<voice>".
    var id: String
    var engineId: String
    var presetId: String?
    var refVoiceId: String?
    var label: String
}

/// The last A/B comparison: two previews of the same passage.
struct VoiceComparison: Hashable, Sendable {
    var a: VoiceLab.PreviewKey
    var b: VoiceLab.PreviewKey
}

// MARK: - Add my voice

/// The "Add my voice" form. `--i-have-rights` is passed only when `hasRights` (the consent checkbox) is on.
struct AddVoiceForm: Hashable, Sendable {
    var file: URL?
    var name = ""
    var language = "en"
    var transcript = ""
    var hasRights = false
    /// Clean the recording first: remove background noise and music / restore speech clarity.
    var isolate = false
    var enhance = false

    /// Languages the form offers: the ones a cloning engine can speak (`AppModel.cloningLanguageCodes`).
    var languages: [String]

    init(language: String? = nil, languages: [String] = LanguageRegistry.defaultEnabled) {
        self.languages = languages
        if let language, languages.contains(language) { self.language = language } else if let first = languages.first {
            self.language = first
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// nil when empty: the engine then transcribes the clip with Whisper.
    var transcriptArgument: String? {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// What still blocks "Add Voice", in form order; nil when it can be submitted.
    var missingStep: String? {
        if file == nil { return "Choose a recording." }
        if trimmedName.isEmpty { return "Give the voice a name." }
        if !languages.contains(language) { return languageMessage }
        if !hasRights { return "Confirm that you have the right to use this voice." }
        return nil
    }

    var canSubmit: Bool { missingStep == nil }

    /// "Choose English or French." (up to three languages are named; more are described).
    var languageMessage: String {
        guard languages.count <= 3, !languages.isEmpty else { return "Choose one of the listed languages." }
        return "Choose " + VoiceText.list(languages.map(Formatters.languageName), conjunction: "or") + "."
    }

    /// Picks a file and, when the name is still empty, names the voice after it.
    mutating func chooseFile(_ url: URL) {
        file = url
        if trimmedName.isEmpty { name = AddVoiceForm.suggestedName(for: url) }
    }

    /// "my_voice-take2.wav" → "My voice take2".
    static func suggestedName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard let first = stem.first else { return "" }
        return first.uppercased() + stem.dropFirst()
    }
}

// MARK: - Change a voice's recording

/// The "Change Recording" form for one of the user's voices: a new file, or the kept original processed again
/// with other clean-up boxes. `--i-have-rights` is passed only with a new file, when `hasRights` is on.
struct ChangeRecordingForm: Hashable, Sendable {
    let voiceId: String
    /// The engine kept the start of the recording (voices added before that have no original).
    let hasOriginal: Bool
    /// Settings the voice has now.
    let currentIsolate: Bool
    let currentEnhance: Bool

    var file: URL?
    var isolate: Bool
    var enhance: Bool
    var transcript = ""
    var hasRights = false

    init(entry: VoiceEntry) {
        voiceId = entry.id
        hasOriginal = entry.hasOriginal
        currentIsolate = entry.isolate ?? false
        currentEnhance = entry.enhance ?? false
        isolate = currentIsolate
        enhance = currentEnhance
    }

    var isNewFile: Bool { file != nil }

    /// nil when empty: the engine then transcribes the new recording with Whisper.
    var transcriptArgument: String? {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// What still blocks the button; nil when it can be submitted.
    var missingStep: String? {
        if file == nil {
            if !hasOriginal { return "Choose the recording again: this voice was added before originals were kept." }
            if isolate == currentIsolate && enhance == currentEnhance { return "Choose a new recording or change a box." }
            return nil
        }
        if !hasRights { return "Confirm that you have the right to use this voice." }
        return nil
    }

    var canSubmit: Bool { missingStep == nil }

    /// "Replace Recording" for a new file, else "Reprocess".
    var actionTitle: String { isNewFile ? "Replace Recording" : "Reprocess" }

    mutating func chooseFile(_ url: URL) { file = url }
}

// MARK: - Wording

/// Voice screen wording built from engine values (numbers go through `Formatters`).
enum VoiceText {
    /// "1×", "1.25×", "0.75×".
    static func speed(_ speed: Double) -> String { Formatters.trimmed(speed, digits: 2) + "×" }

    /// "Female", "Male", or the engine's word capitalised.
    static func gender(_ gender: String?) -> String? {
        guard let g = gender?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
        return g.prefix(1).uppercased() + g.dropFirst().lowercased()
    }

    /// "English, French".
    static func languages(_ codes: [String]) -> String { codes.map(Formatters.languageName).joined(separator: ", ") }

    /// "A", "A and B", "A, B and C" (or "or" with `conjunction: "or"`).
    static func list(_ items: [String], conjunction: String = "and") -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }

    static func capabilities(_ engine: EngineInfo) -> String {
        switch (engine.supportsPresets, engine.supportsCloning) {
        case (true, true): return "Preset voices and voice cloning"
        case (true, false): return "Preset voices"
        case (false, true): return "Voice cloning only"
        case (false, false): return "Default voice only"
        }
    }

    static func slowWarning(realtimeX x: Double) -> String {
        "Slower than real time on this Mac (\(Formatters.multiplier(x))): one hour of audio takes about "
            + "\(Formatters.duration(3600 / x)) to make."
    }

    /// Where a reference voice's transcript came from.
    static func transcriptSource(_ source: String?) -> String {
        switch source {
        case "published": return "Transcript published with the recording."
        case "whisper": return "Transcribed automatically. Check names and unusual words: cloning copies what the transcript says."
        case "user": return "Transcript corrected by you."
        default: return "The words spoken in the recording. Cloning quality depends on it."
        }
    }
}

// MARK: - Screen state kept across visits

/// Voices screen state that outlives the view: filters, the preview section per book, previews by
/// book + section + voice (so going back to the screen still shows them) and the last A/B comparison.
/// One per AppModel: `model.voiceLab`.
///
/// Previews are SampleRuns owned by the AppModel, so they keep running while the user is on another screen.
@MainActor
@Observable
final class VoiceLab {
    /// Previews are keyed by what the engine reads and how: same key, same audio.
    struct PreviewKey: Hashable, Sendable {
        var bookPath: String
        var language: String
        /// nil: the engine's first chapter.
        var section: Int?
        var voice: VoiceSelection
    }

    /// Length of a voice preview ("about 20 s").
    static let previewSeconds: Double = 20
    static let maxKeptPreviews = 40

    var filter = VoiceFilter()
    /// A/B picker choices (`VoiceChoice.id`); nil picks a default.
    var compareAId: String?
    var compareBId: String?
    private(set) var comparison: VoiceComparison?
    private(set) var previews: [PreviewKey: SampleRun] = [:]
    /// Section index read by previews, per book path (absent: first chapter).
    private var previewSections: [String: Int] = [:]

    init() {}

    /// The section previews read for `draft` (nil: the engine's first chapter).
    func previewSection(for draft: BookDraft) -> Int? {
        guard let index = previewSections[draft.url.path], draft.sections.contains(where: { $0.index == index }) else { return nil }
        return index
    }

    func setPreviewSection(_ index: Int?, for draft: BookDraft) {
        previewSections[draft.url.path] = index
    }

    func preview(for key: PreviewKey) -> SampleRun? { previews[key] }

    func store(_ run: SampleRun, for key: PreviewKey) {
        previews[key] = run
        guard previews.count > VoiceLab.maxKeptPreviews else { return }
        let removable = previews.filter { !$0.value.isRunning }.sorted { $0.value.startedAt < $1.value.startedAt }
        for (k, _) in removable.prefix(previews.count - VoiceLab.maxKeptPreviews) where k != key {
            previews[k] = nil
        }
    }

    func setComparison(_ comparison: VoiceComparison?) { self.comparison = comparison }

    /// Stops every preview that is still running (before the engine is replaced by an update).
    func cancelRunning() {
        for run in previews.values where run.isRunning { run.cancel() }
    }

    /// Stops and drops the previews made with one reference voice (its recording changed), and the comparison
    /// that shows one of them.
    func forgetPreviews(refVoiceId: String) {
        for (key, run) in previews where key.voice.refVoiceId == refVoiceId {
            if run.isRunning { run.cancel() }
            previews[key] = nil
        }
        if let c = comparison, c.a.voice.refVoiceId == refVoiceId || c.b.voice.refVoiceId == refVoiceId {
            comparison = nil
        }
    }
}

extension EngineRun {
    /// The sample's audio file (as reported by `sample_done`, else the requested output path).
    var previewAudioURL: URL? { result?.output.map { URL(fileURLWithPath: $0) } ?? outputURL }

    /// Running, or finished with its audio still on disk.
    var isReusablePreview: Bool {
        if isRunning { return true }
        guard phase == .finished, let url = previewAudioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - AppModel

// `AppModel.voiceLab` (a stored property in AppModel.swift) holds this screen's state.
extension AppModel {
    // MARK: Catalogue

    /// Every voice: presets, the reference library and the user's clips.
    var voiceOptions: [VoiceOption] { VoiceCatalog.options(engines: engines, voices: voices) }

    /// `voiceOptions` passing the browser filters.
    var filteredVoiceOptions: [VoiceOption] {
        let filter = voiceLab.filter
        let language = draft?.language
        let favorites = settings.favoriteVoices
        return voiceOptions.filter {
            filter.matches($0, engines: engines, bookLanguage: language, favorites: favorites) && isVoiceLanguageShown($0)
        }
    }

    /// How many of the voices the browser can list (language switches ignored) are starred.
    var favoriteVoiceCount: Int {
        let favorites = settings.favoriteVoices
        return voiceOptions.filter { favorites.contains($0.id) && isVoiceLanguageShown($0) }.count
    }

    /// Languages offered by the language filter: the enabled ones (registry order) plus the open book's own.
    var voiceLanguages: [String] { languageCodes(includingBook: draft) }

    /// Voices of languages that are off are hidden (the user's own clips are always shown; the open book's language
    /// counts as on). A voice of another language that speaks the browsed language with an accent stays.
    func isVoiceLanguageShown(_ option: VoiceOption) -> Bool {
        if option.kind == .userClip || voiceLanguages.contains(option.language) { return true }
        guard let browsed = voiceLab.filter.languageCode(bookLanguage: draft?.language) else { return false }
        return option.speaksWithAccent(browsed)
    }

    /// Display name of a voice id (preset of `engineId`, else a reference voice), for measurements.
    func voiceDisplayName(engineId: String, voiceId: String) -> String {
        if let preset = engineList?.engine(engineId)?.voices.first(where: { $0.id == voiceId }) { return preset.name }
        return voices.first { $0.id == voiceId }?.name ?? voiceId
    }

    // MARK: Choosing

    /// A narrator using `engineId` and the given voice, keeping the current speed (and the speech-check
    /// choice when the engine does not change).
    func narratorSelection(engineId: String, presetId: String? = nil, refVoiceId: String? = nil) -> VoiceSelection {
        let current = voiceSelection
        var v = VoiceSelection(engineId: engineId, presetId: presetId, refVoiceId: refVoiceId, speed: current?.speed ?? 1.0)
        if let current, current.engineId == engineId { v.verify = current.verify }
        return v
    }

    /// The narrator a browser row selects. Reference voices are cloned by `preferredEngine` (default: the
    /// engine filter) when it can, else the current engine when it can, else the best cloning engine.
    func voiceSelection(for option: VoiceOption, preferredEngine: String?? = nil) -> VoiceSelection? {
        switch option.kind {
        case .preset:
            guard let engineId = option.engineIds.first else { return nil }
            return narratorSelection(engineId: engineId, presetId: option.voiceId)
        case .library, .userClip:
            let preferred = preferredEngine ?? voiceLab.filter.engineId
            guard let engineId = VoiceCatalog.cloningEngine(candidates: option.engineIds, current: voiceSelection?.engineId,
                                                            preferred: preferred, engines: engines, models: models) else { return nil }
            return narratorSelection(engineId: engineId, refVoiceId: option.voiceId)
        }
    }

    /// The narrator an engine card selects: the current one if it already uses that engine; the saved default
    /// for the language if it uses that engine; the current reference voice when the engine can clone it;
    /// else a preset in the book's language, else an installed reference voice in that language.
    func voiceSelection(switchingTo engineId: String) -> VoiceSelection? {
        guard let engine = engineList?.engine(engineId) else { return nil }
        let current = voiceSelection
        if let current, current.engineId == engineId { return current }
        let language = draft?.language ?? current?.language(engines: engines, voices: voices) ?? fallbackLanguage
        if let saved = settings.defaultVoices[language], saved.engineId == engineId,
           saved.fits(language: language, engines: engines, voices: voices) {
            return saved
        }
        var v = VoiceSelection(engineId: engineId, speed: current?.speed ?? 1.0)
        let installedRef: (String) -> Bool = { id in self.voices.contains { $0.id == id && $0.isInstalled && $0.lang == language } }
        if engine.supportsCloning, let ref = current?.refVoiceId, installedRef(ref) {
            v.chooseReferenceVoice(ref)
        } else if engine.supportsPresets, let preset = engine.voices.first(where: { $0.lang == language }) {
            v.choosePreset(preset.id)
        } else if engine.supportsCloning, let ref = voices.first(where: { $0.lang == language && $0.isInstalled }) {
            v.chooseReferenceVoice(ref.id)
        } else if engine.supportsPresets, let preset = engine.voices.first {
            v.choosePreset(preset.id)
        }
        return v
    }

    /// The model of `engineId` is known to be missing (`models list` loaded and says not installed).
    func isEngineMissing(_ engineId: String) -> Bool {
        models.first { $0.engine == engineId }.map { !$0.installed } ?? false
    }

    /// The line under a ticked clean-up box: installed, or what is downloaded first. nil while the model list
    /// does not mention it (an older engine: it reports a missing model itself).
    func cleanupModelNote(_ modelId: String) -> (installed: Bool, text: String)? {
        guard let status = models.first(where: { $0.engine == modelId }) else { return nil }
        if status.installed { return (true, "Installed on this Mac.") }
        let size = status.downloadGb.map { Formatters.gigabytes($0) + " " } ?? ""
        return (false, "Not installed: \(size.isEmpty ? "it" : size)will be downloaded first.")
    }

    /// The Whisper model behind "Check every sentence with speech recognition" is not installed.
    var isSpeechCheckModelMissing: Bool { isEngineMissing("whisper") }

    /// Facts for an engine card.
    func voiceEngineSummary(for engine: EngineInfo) -> VoiceEngineSummary {
        let install: VoiceEngineSummary.Install
        if let status = models.first(where: { $0.engine == engine.id }) {
            install = status.installed ? .installed(bytes: status.installedBytes) : .notInstalled(downloadGb: status.downloadGb ?? engine.downloadGb)
        } else {
            install = .unknown
        }
        let selection = voiceSelection(switchingTo: engine.id)
        let measured = VoiceCatalog.measuredRate(engine: engine.id, voice: selection?.voiceId, in: engineList)
        let bookEstimate = draft.flatMap { d in selection.flatMap { estimate(chars: d.includedChars, voice: $0) } }
        return VoiceEngineSummary(
            engine: engine, install: install, selection: selection, rate: measured?.rate,
            rateIsExactVoice: measured?.exactVoice ?? false,
            rateVoiceName: measured.map { voiceDisplayName(engineId: engine.id, voiceId: $0.rate.voice) },
            bookEstimate: bookEstimate, isChosen: voiceSelection?.engineId == engine.id,
            shownLanguages: engine.languages.filter { code in enabledLanguageCodes.contains(code) || code == draft?.language })
    }

    // MARK: Licence gate

    /// The first non-commercial engine `action` uses whose licence the user has not acknowledged yet.
    func engineNeedingLicense(for action: VoiceAction) -> EngineInfo? {
        for id in action.engineIds {
            if let engine = engineList?.engine(id), engine.noncommercial, !settings.hasAcknowledgedLicense(engine: id) {
                return engine
            }
        }
        return nil
    }

    /// Carries out a Voices screen action (call after the licence gate). Returns the sample runs it started
    /// or reused (previews and comparisons).
    @discardableResult
    func performVoiceAction(_ action: VoiceAction) -> [SampleRun] {
        switch action {
        case .select(let v):
            voiceSelection = v
            return []
        case .preview(let v):
            return startVoicePreview(v).map { [$0] } ?? []
        case .compare(let a, let b):
            guard startVoiceComparison(a, b) != nil else { return [] }
            return [voiceComparisonRuns.a, voiceComparisonRuns.b].compactMap { $0 }
        }
    }

    // MARK: Previews

    /// Why `voice` cannot be previewed on the open book right now (nil when it can).
    func voicePreviewProblem(_ voice: VoiceSelection?) -> String? {
        guard let draft else { return "Open a book to hear voices reading it." }
        guard let voice else { return "Choose a voice first." }
        guard let engine = engineList?.engine(voice.engineId) else { return "This engine is not available." }
        if isEngineMissing(engine.id) { return "\(engine.name) is not installed. Download it first." }
        if voice.voiceId == nil && !engine.supportsPresets {
            return "\(engine.name) needs a reference voice. Choose one in the list below."
        }
        if let ref = voice.refVoiceId, let entry = voices.first(where: { $0.id == ref }), !entry.isInstalled {
            return "Install “\(entry.name)” first."
        }
        if !voice.fits(language: draft.language, engines: engines, voices: voices) {
            return "This voice does not read \(Formatters.languageName(draft.language)), the book's language."
        }
        return nil
    }

    /// The preview key for `voice` on the open book and its preview section (nil without a book).
    func voicePreviewKey(for voice: VoiceSelection) -> VoiceLab.PreviewKey? {
        guard let draft else { return nil }
        return VoiceLab.PreviewKey(bookPath: draft.url.path, language: draft.language,
                                   section: voiceLab.previewSection(for: draft), voice: voice)
    }

    /// The preview of `voice` for the open book and section, if one was made or is being made.
    func voicePreview(for voice: VoiceSelection) -> SampleRun? {
        voicePreviewKey(for: voice).flatMap { voiceLab.preview(for: $0) }
    }

    /// Makes a ~20 s sample of the preview section with `voice` (`sample --seconds 20`), or returns the
    /// one already running / made. With `autoplay`, it plays when ready unless something else is playing.
    /// nil when no book is open.
    @discardableResult
    func startVoicePreview(_ voice: VoiceSelection, autoplay: Bool = true) -> SampleRun? {
        guard let key = voicePreviewKey(for: voice) else { return nil }
        if let existing = voiceLab.preview(for: key), existing.isReusablePreview { return existing }
        guard let run = startSample(voice: voice, section: key.section, seconds: VoiceLab.previewSeconds) else { return nil }
        if autoplay {
            let previous = run.onFinish
            run.onFinish = { [weak self] run in
                previous?(run)
                guard let self, run.phase == .finished, let url = run.previewAudioURL, !self.player.isPlaying else { return }
                self.player.play(url)
            }
        }
        voiceLab.store(run, for: key)
        return run
    }

    // MARK: A/B comparison

    /// Engine + voice pairs that read the open book's language (installed engines and voices only).
    var voiceComparisonChoices: [VoiceChoice] {
        guard let language = draft?.language else { return [] }
        var out: [VoiceChoice] = []
        for engine in engines where !isEngineMissing(engine.id) && engine.languages.contains(language) {
            if engine.supportsPresets {
                for p in engine.voices where p.lang == language {
                    out.append(VoiceChoice(id: "\(engine.id)|\(p.id)", engineId: engine.id, presetId: p.id,
                                           label: "\(p.name) · \(engine.name)"))
                }
            }
            if engine.supportsCloning {
                for v in voices where v.lang == language && v.isInstalled {
                    out.append(VoiceChoice(id: "\(engine.id)|\(v.id)", engineId: engine.id, refVoiceId: v.id,
                                           label: "\(v.name) · \(engine.name) (cloned)"))
                }
            }
        }
        return out
    }

    /// The narrator for an A/B choice: the current narrator when it is the same voice, else the choice at the
    /// current speed (so both sides of a comparison run at the same speed).
    func voiceSelection(for choice: VoiceChoice) -> VoiceSelection {
        if let current = voiceSelection, current.engineId == choice.engineId,
           current.presetId == choice.presetId, current.refVoiceId == choice.refVoiceId {
            return current
        }
        return narratorSelection(engineId: choice.engineId, presetId: choice.presetId, refVoiceId: choice.refVoiceId)
    }

    /// The A and B choice ids in use: the user's picks when still valid, else the current narrator and
    /// the next different voice.
    func resolvedComparisonIds(in choices: [VoiceChoice]) -> (a: String?, b: String?) {
        let ids = choices.map(\.id)
        let current = voiceSelection.flatMap { v in v.voiceId.map { "\(v.engineId)|\($0)" } }
        let a = voiceLab.compareAId.flatMap { ids.contains($0) ? $0 : nil }
            ?? current.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        let b = voiceLab.compareBId.flatMap { ids.contains($0) && $0 != a ? $0 : nil } ?? ids.first { $0 != a }
        return (a, b)
    }

    /// Makes (or reuses) previews of the same passage with `a` and `b`, without autoplay.
    @discardableResult
    func startVoiceComparison(_ a: VoiceSelection, _ b: VoiceSelection) -> VoiceComparison? {
        guard a != b, let keyA = voicePreviewKey(for: a), let keyB = voicePreviewKey(for: b) else { return nil }
        startVoicePreview(a, autoplay: false)
        startVoicePreview(b, autoplay: false)
        let comparison = VoiceComparison(a: keyA, b: keyB)
        voiceLab.setComparison(comparison)
        return comparison
    }

    /// The last comparison when it was made on the open book (nil otherwise).
    var currentVoiceComparison: VoiceComparison? {
        guard let c = voiceLab.comparison, let draft, c.a.bookPath == draft.url.path, c.a.language == draft.language else { return nil }
        return c
    }

    /// The two runs of the current comparison.
    var voiceComparisonRuns: (a: SampleRun?, b: SampleRun?) {
        guard let c = currentVoiceComparison else { return (nil, nil) }
        return (voiceLab.preview(for: c.a), voiceLab.preview(for: c.b))
    }
}
