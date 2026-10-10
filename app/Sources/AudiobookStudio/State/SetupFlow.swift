import Foundation

/// A voice model offered in the first-run setup. The sizes mirror the engine's catalog (`models list`), which
/// cannot be asked yet: the engine is what the setup installs.
struct SetupModelChoice: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
    var gb: Double
    var noncommercial = false
    /// Name in the progress list (defaults to the title).
    var listTitle: String?
}

enum SetupCatalog {
    static let narration: [SetupModelChoice] = [
        SetupModelChoice(id: "kokoro", title: "Fast", detail: "Natural and very quick, a good start for any book. Small download.", gb: 0.35, listTitle: "Fast voice (Kokoro)"),
        SetupModelChoice(id: "qwen3", title: "Best quality", detail: "The most expressive narration, and it can clone a voice. French is spoken through voice cloning.", gb: 6.2, listTitle: "Best-quality voice (Qwen3-TTS)"),
    ]
    static let quality = SetupModelChoice(id: "whisper", title: "Quality check",
                                          detail: "Listens to each chapter afterwards to catch skipped or garbled words. Also transcribes your own voice clips.", gb: 1.6)
    /// Personal-use only licences: shown under "More voices".
    static let more: [SetupModelChoice] = [
        SetupModelChoice(id: "voxtral", title: "Voxtral", detail: "Lively, expressive narration.", gb: 2.5, noncommercial: true),
        SetupModelChoice(id: "fish", title: "Fish Audio S2 Pro", detail: "Highly realistic, the largest model.", gb: 6.7, noncommercial: true),
    ]
    static let all = narration + [quality] + more
    /// Which narration engines speak which languages. A mirror of the engine's specs (the engine does not exist yet
    /// at this step, so `languages list` cannot be asked); `SetupTests` compares it with the engine fixtures so a
    /// drift is noticed. Whisper is not a narrator and is not listed.
    static let engineLanguages: [String: [String]] = [
        "kokoro": ["en", "fr", "es", "it", "pt", "hi"],
        "qwen3": ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko"],
        "voxtral": ["en", "fr", "es", "de", "it", "pt", "nl", "hi", "ar"],
        "fish": ["en", "fr"],
    ]
    /// Names used in sentences ("Russian needs Best quality (Qwen3-TTS)").
    static let engineNames: [String: String] = [
        "kokoro": "Fast (Kokoro)", "qwen3": "Best quality (Qwen3-TTS)", "voxtral": "Voxtral", "fish": "Fish Audio S2 Pro",
    ]
    /// Rough download of one language's reference voices, in MB (only an estimate: the engine reports the real size).
    static let voiceMBPerLanguage = 3.0

    static func choice(_ id: String) -> SetupModelChoice? { all.first { $0.id == id } }

    /// "Russian", "Russian and Japanese", "Russian, Korean and Japanese" (registry order).
    static func languageList(_ codes: [String]) -> String {
        let names = LanguageRegistry.codes.filter(codes.contains).map { LanguageRegistry.builtin[$0]?.name ?? $0 }
            + codes.filter { !LanguageRegistry.codes.contains($0) }
        if names.count < 2 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    /// English is the only language on by default, so it is the only one pre-selected on a fresh install.
    static let defaultLanguages: Set<String> = ["en"]

    /// The selected languages (registry order) that none of `engines` can narrate.
    static func uncovered(_ languages: Set<String>, engines: Set<String>) -> [String] {
        LanguageRegistry.codes.filter { code in
            languages.contains(code) && !engines.contains { engineLanguages[$0]?.contains(code) == true }
        }
    }

    /// The cheapest set of narration engines (by download size, then fewest) that speaks every language in `needed`.
    /// Only a suggestion: nothing is chosen until the person accepts it.
    static func suggestion(for needed: [String]) -> [String] {
        guard !needed.isEmpty else { return [] }
        let ids = ["kokoro", "qwen3", "voxtral", "fish"]
        var best: (ids: [String], gb: Double)?
        for mask in 1..<(1 << ids.count) {
            let subset = ids.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            guard uncovered(Set(needed), engines: Set(subset)).isEmpty else { continue }
            let gb = subset.reduce(0) { $0 + (choice($1)?.gb ?? 0) }
            if best == nil || gb < best!.gb - 0.0001 || (abs(gb - best!.gb) < 0.0001 && subset.count < best!.ids.count) { best = (subset, gb) }
        }
        return best?.ids ?? []
    }

    /// "Russian needs Best quality (Qwen3-TTS); add it here or later in Models."
    static func coverageMessage(uncovered: [String], suggestion: [String]) -> String? {
        guard !uncovered.isEmpty else { return nil }
        let who = languageList(uncovered)
        let verb = uncovered.count == 1 ? "needs" : "need"
        let names = suggestion.compactMap { engineNames[$0] }
        guard !names.isEmpty else { return "\(who) \(verb) a voice that is not offered here yet; add one later in Models." }
        let engines = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(who) \(verb) \(engines); add it here or later in Models."
    }

    /// What to do to the engine's languages so that exactly `selected` are on: add every selected language first
    /// (this downloads its voices; also makes sure a language that is already on has them), then turn off the ones
    /// that are on and not selected. Add first because the engine refuses to turn off the last language.
    struct LanguagePlan: Equatable, Sendable {
        var add: [String]
        var remove: [String]
    }

    static func languagePlan(selected: Set<String>, enabled: [String]) -> LanguagePlan {
        LanguagePlan(add: LanguageRegistry.codes.filter(selected.contains),
                     remove: LanguageRegistry.codes.filter { enabled.contains($0) && !selected.contains($0) })
    }

    /// Rough size of the tools and the Python environment the engine install adds.
    static let engineGB = 1.5
}

enum SetupStep: Int, Hashable, Sendable {
    case welcome, languages, models, review, working, done
}

/// One line of the progress list.
struct SetupItem: Identifiable, Hashable, Sendable {
    /// `language` turns a language on (and downloads its voices); `languageOff` turns one off.
    enum Kind: Hashable, Sendable { case engine, model(String), language(String), languageOff(String) }
    enum State: Hashable, Sendable { case pending, active, done, failed }
    var kind: Kind
    var title: String
    /// Share of the overall bar (about the download size in GB).
    var weight: Double
    var state: State = .pending
    /// Why a language step did not fully work (shown under it, with a retry).
    var note: String?
    var isLanguageStep: Bool {
        switch kind {
        case .language, .languageOff: return true
        default: return false
        }
    }
    var id: String {
        switch kind {
        case .engine: return "engine"
        case .model(let m): return "model-\(m)"
        case .language(let c): return "language-\(c)"
        case .languageOff(let c): return "language-off-\(c)"
        }
    }
}

/// The first-run setup: what the person chose, and the work of installing the engine, downloading the chosen
/// models and installing the reference voices. It lives in the AppModel, so the work goes on when the setup
/// window is closed ("Continue in background") and a banner shows where it is.
@MainActor
@Observable
final class SetupFlow {
    var step: SetupStep = .welcome
    /// The setup window is open.
    var isPresented = false
    /// The languages the person wants on (at least one).
    var languages: Set<String>
    /// The person changed the languages in this session: reopening the setup keeps their choice.
    private(set) var languagesEdited = false
    var chosen: Set<String> = ["kokoro", "qwen3"]
    private(set) var prerequisites = SetupPrerequisites.current()
    private(set) var items: [SetupItem] = []
    private(set) var error: EngineError?
    private(set) var isWorking = false
    let installer = EngineInstaller()

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        languages = SetupCatalog.defaultLanguages
    }

    // MARK: Choices

    func present(from step: SetupStep = .welcome) {
        prerequisites = .current()
        if !isWorking {
            self.step = step
            if !languagesEdited { languages = initialLanguages() }
        }
        isPresented = true
    }

    /// The languages that are on now when the engine can tell (reopening the setup), else English.
    func initialLanguages() -> Set<String> {
        if let model, model.languagesKnown {
            let on = Set(model.enabledLanguageCodes)
            if !on.isEmpty { return on }
        }
        return SetupCatalog.defaultLanguages
    }

    func toggleLanguage(_ code: String) {
        guard LanguageRegistry.codes.contains(code) else { return }
        languagesEdited = true
        if languages.contains(code) { if languages.count > 1 { languages.remove(code) } } else { languages.insert(code) }
    }

    func toggleModel(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    // MARK: Languages and engines

    /// Narration engines that will be available: the chosen ones and the ones already on disk.
    var availableEngines: Set<String> {
        var ids = chosen.filter { SetupCatalog.engineLanguages[$0] != nil }
        for m in model?.models ?? [] where m.installed && SetupCatalog.engineLanguages[m.engine] != nil { ids.insert(m.engine) }
        return ids
    }

    /// Selected languages that no available engine speaks.
    var uncoveredLanguages: [String] { SetupCatalog.uncovered(languages, engines: availableEngines) }

    /// The cheapest engines that would cover them (a suggestion; nothing is chosen for the person).
    var suggestedEngines: [String] { SetupCatalog.suggestion(for: uncoveredLanguages) }

    /// The non-blocking note for the models and review steps; nil when every language is covered.
    var coverageNote: String? { SetupCatalog.coverageMessage(uncovered: uncoveredLanguages, suggestion: suggestedEngines) }

    /// Accepts the suggestion with one tap.
    func acceptSuggestion() { chosen.formUnion(suggestedEngines) }

    /// Which of the selected languages an engine speaks, and which it does not.
    func coverage(of engineId: String) -> (speaks: [String], missing: [String])? {
        guard let spoken = SetupCatalog.engineLanguages[engineId] else { return nil }
        let selected = LanguageRegistry.codes.filter(languages.contains)
        return (selected.filter(spoken.contains), selected.filter { !spoken.contains($0) })
    }

    /// Languages on now: the engine's list, else only English (a fresh engine).
    private var currentlyEnabled: [String] {
        if let model, model.languagesKnown { return model.enabledLanguageCodes }
        return Array(SetupCatalog.defaultLanguages)
    }

    /// What will be done to the engine's languages.
    var languagePlan: SetupCatalog.LanguagePlan {
        SetupCatalog.languagePlan(selected: languages, enabled: currentlyEnabled)
    }

    /// Estimated download of the reference voices for the languages to add, in MB.
    var voicesMB: Double { Double(languagePlan.add.count) * SetupCatalog.voiceMBPerLanguage }

    var engineInstalled: Bool {
        guard let model else { return false }
        return FileManager.default.isExecutableFile(atPath: model.settings.enginePath)
    }

    /// Models still to download (the ones already on disk are skipped).
    var modelsToDownload: [SetupModelChoice] {
        SetupCatalog.all.filter { choice in
            chosen.contains(choice.id) && !(model?.models.first { $0.engine == choice.id }?.installed ?? false)
        }
    }

    /// Download size of what is left to fetch, in GB.
    var neededGB: Double {
        modelsToDownload.reduce(0) { $0 + $1.gb } + (engineInstalled ? 0 : SetupCatalog.engineGB)
    }

    /// Why the install cannot start yet, in words for a person; nil when it can.
    var blocker: String? { prerequisites.blocker(neededGB: neededGB) }

    /// Homebrew is missing and the engine needs it.
    var needsHomebrew: Bool { !engineInstalled && !prerequisites.homebrew }

    var canInstall: Bool { !chosen.isEmpty && blocker == nil && !needsHomebrew }

    func recheckPrerequisites() { prerequisites = .current() }

    // MARK: Work

    /// Overall progress, 0...1.
    var fraction: Double {
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        var done = 0.0
        for item in items {
            switch item.state {
            case .done: done += item.weight
            case .active: done += item.weight * activeFraction(item)
            default: break
            }
        }
        return min(1, done / total)
    }

    private func activeFraction(_ item: SetupItem) -> Double {
        switch item.kind {
        case .engine: return installer.fraction
        case .model(let id): return model?.modelDownloads[id]?.fraction ?? 0
        case .language, .languageOff: return 0
        }
    }

    /// What is happening now, as a sentence.
    var statusText: String {
        guard let active = items.first(where: { $0.state == .active }) else { return isWorking ? "Getting ready…" : "" }
        switch active.kind {
        case .engine: return installer.stepTitle + "…"
        case .model(let id): return model?.modelDownloads[id]?.statusText ?? "Downloading \(active.title)…"
        case .language(let code):
            guard let d = model?.languageDownloads[code] else { return "Adding \(Formatters.languageName(code))…" }
            return d.statusText
        case .languageOff(let code): return "Turning off \(Formatters.languageName(code))…"
        }
    }

    func start() {
        guard !isWorking, let model else { return }
        isWorking = true   // at once, so a second tap (or the banner) cannot start a second run
        task = Task { await run(model) }
    }

    func cancel() {
        installer.cancel()
        task?.cancel()
        if let model { model.stopScreenEngineWork() }
    }

    private func plan() -> [SetupItem] {
        var list: [SetupItem] = []
        if !engineInstalled { list.append(SetupItem(kind: .engine, title: "Install the voice engine", weight: SetupCatalog.engineGB)) }
        for choice in SetupCatalog.all where chosen.contains(choice.id) {
            list.append(SetupItem(kind: .model(choice.id), title: choice.listTitle ?? choice.title, weight: choice.gb))
        }
        let languagePlan = self.languagePlan
        for code in languagePlan.add {
            list.append(SetupItem(kind: .language(code), title: "\(Formatters.languageName(code)) voices", weight: 0.1))
        }
        for code in languagePlan.remove {
            list.append(SetupItem(kind: .languageOff(code), title: "Turn off \(Formatters.languageName(code))", weight: 0.02))
        }
        return list
    }

    private func set(_ kind: SetupItem.Kind, _ state: SetupItem.State, note: String? = nil) {
        if let i = items.firstIndex(where: { $0.kind == kind }) { items[i].state = state; items[i].note = note }
    }

    /// Language steps that did not fully work (the setup still finishes; they can be retried).
    var languageIssues: [SetupItem] {
        items.filter { $0.state == .failed && $0.isLanguageStep }
    }

    /// Waits for the work in progress (tests).
    func waitForWork() async { await task?.value }

    private func run(_ model: AppModel) async {
        isWorking = true
        error = nil
        step = .working
        defer { isWorking = false }
        if items.isEmpty || items.allSatisfy({ $0.state == .done }) { items = plan() }
        var current: SetupItem.Kind?
        do {
            for item in items where item.state != .done {
                try Task.checkCancellation()
                current = item.kind
                set(item.kind, .active)
                switch item.kind {
                case .engine:
                    try await installer.install()
                    model.settings.resetEnginePath()
                    await model.refreshAll()
                case .model(let id):
                    if model.models.isEmpty { await model.refreshModels() }
                    if !(model.models.first { $0.engine == id }?.installed ?? false) { try await model.downloadModel(id) }
                case .language(let code):
                    var issue: String?
                    do {
                        let result = try await model.addLanguage(code)
                        if let result {
                            if !result.enabled { issue = "\(Formatters.languageName(code)) could not be turned on." }
                            else if !result.voiceErrors.isEmpty { issue = result.notes.joined(separator: " ") }
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Not fatal: the books can still be made with the person's own clips, and Try Again retries.
                        issue = EngineError(error).message
                    }
                    if let issue { set(item.kind, .failed, note: issue); continue }
                case .languageOff(let code):
                    // The engine refuses to turn off the last language: only when a chosen one is really on.
                    guard languages.contains(where: { model.isEnabled($0) }) else {
                        set(item.kind, .failed, note: "Kept \(Formatters.languageName(code)) on because no chosen language is on yet.")
                        continue
                    }
                    do { try await model.removeLanguage(code) } catch is CancellationError { throw CancellationError() } catch {
                        set(item.kind, .failed, note: EngineError(error).message)
                        continue
                    }
                }
                set(item.kind, .done)
            }
            model.settings.setupState = .completed
            await model.refreshAll()
            languagesEdited = false
            step = .done
        } catch is CancellationError {
            if let current { set(current, .pending) }
        } catch {
            if Task.isCancelled { if let current { set(current, .pending) }; return }
            if let current { set(current, .failed) }
            self.error = EngineError(error)
        }
    }

    /// "Skip for now" before anything started, or "Continue in background" while it works.
    func dismiss() {
        isPresented = false
        if !isWorking, model?.settings.setupState == .notStarted { model?.settings.setupState = .skipped }
    }

    /// Closes the finished setup and shows the empty book screen.
    func finish() {
        isPresented = false
        step = .welcome
        items = []
        languagesEdited = false
        model?.selection = .newBook
    }
}
