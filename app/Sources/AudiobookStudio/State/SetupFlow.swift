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
    static let languages: [(code: String, name: String)] = [("en", "English"), ("fr", "French")]

    /// Reference voices that the cloning engines narrate with, per language (the engine's voice library ids).
    static let referenceVoices: [String: [String]] = [
        "en": ["en_librittsr_laura_caldwell_female_us", "en_librittsr_bill_boerst_male_us"],
        "fr": ["fr_siwis_female_book", "fr_cmltts_7142_male"],
    ]
    /// Engines that narrate with a reference voice.
    static let cloningEngines: Set<String> = ["qwen3", "voxtral", "fish"]

    /// Rough size of the tools and the Python environment the engine install adds.
    static let engineGB = 1.5
}

enum SetupStep: Int, Hashable, Sendable {
    case welcome, languages, models, review, working, done
}

/// One line of the progress list.
struct SetupItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case engine, model(String), voices }
    enum State: Hashable, Sendable { case pending, active, done, failed }
    var kind: Kind
    var title: String
    /// Share of the overall bar (about the download size in GB).
    var weight: Double
    var state: State = .pending
    var id: String {
        switch kind {
        case .engine: return "engine"
        case .model(let m): return "model-\(m)"
        case .voices: return "voices"
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
    var languages: Set<String>
    var chosen: Set<String> = ["kokoro", "qwen3"]
    private(set) var prerequisites = SetupPrerequisites.current()
    private(set) var items: [SetupItem] = []
    private(set) var error: EngineError?
    private(set) var isWorking = false
    let installer = EngineInstaller()

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        languages = [Locale.current.language.languageCode?.identifier == "fr" ? "fr" : "en"]
    }

    // MARK: Choices

    func present(from step: SetupStep = .welcome) {
        prerequisites = .current()
        if !isWorking { self.step = step }
        isPresented = true
    }

    func toggleLanguage(_ code: String) {
        if languages.contains(code) { if languages.count > 1 { languages.remove(code) } } else { languages.insert(code) }
    }

    func toggleModel(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    /// The reference voices the choices need.
    var voiceIds: [String] {
        guard !chosen.isDisjoint(with: SetupCatalog.cloningEngines) else { return [] }
        return SetupCatalog.languages.filter { languages.contains($0.code) }.flatMap { SetupCatalog.referenceVoices[$0.code] ?? [] }
    }

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
        case .voices: return 0
        }
    }

    /// What is happening now, as a sentence.
    var statusText: String {
        guard let active = items.first(where: { $0.state == .active }) else { return isWorking ? "Getting ready…" : "" }
        switch active.kind {
        case .engine: return installer.stepTitle + "…"
        case .model(let id): return model?.modelDownloads[id]?.statusText ?? "Downloading \(active.title)…"
        case .voices: return "Installing the reference voices…"
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
        if !voiceIds.isEmpty { list.append(SetupItem(kind: .voices, title: "Reference voices", weight: 0.2)) }
        return list
    }

    private func set(_ kind: SetupItem.Kind, _ state: SetupItem.State) {
        if let i = items.firstIndex(where: { $0.kind == kind }) { items[i].state = state }
    }

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
                case .voices:
                    if model.voices.isEmpty { await model.refreshVoices() }
                    for id in voiceIds where !(model.voices.first { $0.id == id }?.isInstalled ?? false) {
                        try Task.checkCancellation()
                        try await model.downloadVoice(id)
                    }
                }
                set(item.kind, .done)
            }
            model.settings.setupState = .completed
            await model.refreshAll()
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
        model?.selection = .newBook
    }
}
