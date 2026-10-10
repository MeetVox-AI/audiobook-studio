import Foundation

/// A voice model offered in the first-run setup. The sizes mirror the engine's catalog (`models list`), which
/// cannot be asked yet: the engine is what the setup installs.
struct SetupModelChoice: Identifiable, Hashable, Sendable {
    var id: String
    /// What the person picks: a tier ("Quick", "High quality", "Very high quality") or, for the other options, the model.
    var title: String
    /// The exact model ("Kokoro 82M").
    var modelName: String
    /// Who makes it.
    var maker: String
    var detail: String
    var gb: Double
    /// The licence's name ("Apache-2.0").
    var licenseName: String
    var noncommercial = false
    /// "About 14-18x faster than listening", measured on an Apple M4 Pro; nil for the quality check.
    var speed: String?
    /// "A 10-hour book takes about 40 minutes."
    var bookTime: String?
    /// Name in the progress list (defaults to the title).
    var listTitle: String?

    /// "Free for any use" or "Personal use only".
    var licenseSummary: String { noncommercial ? SetupCatalog.personalUseOnly : SetupCatalog.freeForAnyUse }
}

enum SetupCatalog {
    static let freeForAnyUse = "Free for any use"
    static let personalUseOnly = "Personal use only"

    /// The three tiers, from the smallest to the largest download.
    static let tiers: [SetupModelChoice] = [
        SetupModelChoice(id: "kokoro", title: "Quick", modelName: "Kokoro 82M", maker: "hexgrad",
                         detail: "Good for drafts and short tests. English is very good; the other languages are draft quality.",
                         gb: 0.35, licenseName: "Apache-2.0",
                         speed: "About 14-18x faster than listening", bookTime: "A 10-hour book takes about 40 minutes.",
                         listTitle: "Quick (Kokoro 82M)"),
        SetupModelChoice(id: "qwen3", title: "High quality", modelName: "Qwen3-TTS 1.7B", maker: "Qwen (Alibaba)",
                         detail: "Expressive narration in ten languages. It can clone a voice from a short clip.",
                         gb: 6.2, licenseName: "Apache-2.0",
                         speed: "About 3-5x faster than listening with its preset voices, about 2.4x when cloning a voice",
                         bookTime: "A 10-hour book takes about 2-4 hours.",
                         listTitle: "High quality (Qwen3-TTS 1.7B)"),
        SetupModelChoice(id: "fish", title: "Very high quality", modelName: "Fish Audio S2 Pro", maker: "Fish Audio",
                         detail: "The most realistic cloned voice. It speaks English and French only.",
                         gb: 6.7, licenseName: "Fish Audio Research Licence", noncommercial: true,
                         speed: "Slower than listening (about 0.56x)", bookTime: "A 10-hour book takes about 18 hours.",
                         listTitle: "Very high quality (Fish Audio S2 Pro)"),
    ]
    static let quality = SetupModelChoice(id: "whisper", title: "Quality check", modelName: "Whisper large-v3-turbo", maker: "OpenAI",
                                          detail: "Listens back to every chapter to catch skipped or garbled words. It adds about 15% to the time, and it also transcribes your own voice clips.",
                                          gb: 1.6, licenseName: "MIT", listTitle: "Quality check (Whisper large-v3-turbo)")
    /// Not one of the three tiers: a non-commercial model that also narrates Dutch and Arabic.
    static let other: [SetupModelChoice] = [
        SetupModelChoice(id: "voxtral", title: "Voxtral 4B", modelName: "Voxtral 4B", maker: "Mistral AI",
                         detail: "Native voices in nine languages. This is the way to narrate Dutch and Arabic.",
                         gb: 2.5, licenseName: "CC BY-NC 4.0", noncommercial: true,
                         speed: "About 1.7-1.9x faster than listening", bookTime: nil,
                         listTitle: "Voxtral 4B"),
    ]
    static let all = tiers + [quality] + other
    static let benchmarkNote = "Times are for a 10-hour book, measured on an Apple M4 Pro. Yours will differ; the app measures your Mac."
    static let rightsNote = "Audiobooks made from books you do not hold the rights to are for personal use only."
    static let freeLicenceMeaning = "Free for any use (Apache-2.0, MIT): make audiobooks for any purpose, including selling them."
    static let personalLicenceMeaning = "Personal use only (non-commercial licences): make audiobooks for yourself. Do not sell them or use them for business."
    static let acknowledgement = "I understand these voices are for personal use only"
    /// Which narration engines speak which languages. A mirror of the engine's specs (the engine does not exist yet
    /// at this step, so `languages list` cannot be asked); `SetupTests` compares it with the engine fixtures so a
    /// drift is noticed. Whisper is not a narrator and is not listed.
    static let engineLanguages: [String: [String]] = [
        "kokoro": ["en", "fr", "es", "it", "pt", "hi"],
        "qwen3": ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko"],
        "voxtral": ["en", "fr", "es", "de", "it", "pt", "nl", "hi", "ar"],
        "fish": ["en", "fr"],
    ]
    /// Names used in sentences ("Russian needs High quality (Qwen3-TTS 1.7B)").
    static let engineNames: [String: String] = [
        "kokoro": "Quick (Kokoro 82M)", "qwen3": "High quality (Qwen3-TTS 1.7B)", "voxtral": "Voxtral 4B",
        "fish": "Very high quality (Fish Audio S2 Pro)",
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

    /// Which engine is picked first when several could narrate a language (a default, never a lock).
    static let preference = ["qwen3", "kokoro", "voxtral", "fish"]

    /// The narration engines that speak `code`, in preference order.
    static func candidates(for code: String) -> [String] {
        preference.filter { engineLanguages[$0]?.contains(code) == true }
    }

    /// Every narration engine speaks it: no engine is needed for it in particular (English, French).
    static func isOpen(_ code: String) -> Bool { candidates(for: code).count == preference.count }

    /// The engines to add to `have` so that every language in `languages` has a narrator. A language only one
    /// engine speaks forces that engine (Dutch, Arabic: Voxtral; Russian, Chinese, Japanese, Korean: Qwen3-TTS);
    /// any other gets its first candidate in `preference` order, unless an engine already added or in `have` speaks it.
    static func required(languages: Set<String>, have: Set<String>) -> [String] {
        var engines = have
        var added: [String] = []
        let ordered = LanguageRegistry.codes.filter(languages.contains)
        func covered(_ code: String) -> Bool { engines.contains { engineLanguages[$0]?.contains(code) == true } }
        for pass in 0..<2 {
            for code in ordered where !covered(code) {
                let options = candidates(for: code)
                guard let pick = options.first, pass == 1 || options.count == 1 else { continue }
                engines.insert(pick)
                added.append(pick)
            }
        }
        return added
    }

    /// The live line on the languages step: what the selection implies, whatever is ticked later. Nothing is
    /// alarming for languages any voice speaks.
    static func needsSummary(languages: Set<String>, installed: Set<String>) -> String {
        let specific = languages.filter { !isOpen($0) }
        let needed = required(languages: specific, have: installed)
        if needed.isEmpty {
            let names = languageList(Array(languages))
            return specific.isEmpty ? "Any voice quality works for \(names)."
                                    : "Voices already on this Mac cover \(names). You can review this before anything downloads."
        }
        let neededSet = Set(needed)
        var assigned: [String: [String]] = [:]
        for code in LanguageRegistry.codes.filter(languages.contains) where !isOpen(code) {
            if let engine = candidates(for: code).first(where: neededSet.contains) { assigned[engine, default: []].append(code) }
        }
        let parts = preference.filter(neededSet.contains).compactMap { id -> String? in
            guard let choice = choice(id), let codes = assigned[id] else { return nil }
            var facts = [sizeText(choice.gb)]
            if choice.noncommercial { facts.append("personal use only") }
            if id == "kokoro", codes.contains(where: { $0 != "en" }) { facts.append("draft quality") }
            return "\(choice.modelName) (\(facts.joined(separator: ", "))) for \(languageList(codes))"
        }
        return "Your languages need: " + parts.joined(separator: "; ") + ". You can review this before anything downloads."
    }

    /// "Russian needs High quality (Qwen3-TTS 1.7B); add it here or later in Models."
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

    /// "3 MB", "0.35 GB", "6.2 GB": decimal units, as Finder shows them.
    static func sizeText(_ gb: Double) -> String {
        if gb < 0.1 { return "\(max(1, Int((gb * 1000).rounded()))) MB" }
        return gb < 1 ? String(format: "%.2f GB", gb) : String(format: "%.1f GB", gb)
    }

    /// What is left to download, in GB: the engine tools when the engine is not installed, each chosen model that
    /// is not on disk yet, and the reference voices of `languageCount` languages.
    static func downloadGB(chosen: Set<String>, installed: Set<String>, engineInstalled: Bool, languageCount: Int) -> Double {
        let models = all.filter { chosen.contains($0.id) && !installed.contains($0.id) }.reduce(0) { $0 + $1.gb }
        return models + (engineInstalled ? 0 : engineGB) + Double(languageCount) * voiceMBPerLanguage / 1000
    }

    /// Download of the chosen narration models only (not the quality check, tools or voices).
    static func narrationGB(chosen: Set<String>, installed: Set<String>) -> Double {
        (tiers + other).filter { chosen.contains($0.id) && !installed.contains($0.id) }.reduce(0) { $0 + $1.gb }
    }

    /// "Not enough free space: the download needs 8.1 GB and 5 GB is free." nil when it fits.
    static func spaceWarning(neededGB: Double, freeGB: Int) -> String? {
        guard Double(freeGB) < neededGB else { return nil }
        return "Not enough free space: the download needs \(sizeText(neededGB)) and \(freeGB) GB is free."
    }
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
    /// "6.2 GB" for the big downloads (shown in the progress list).
    var sizeLabel: String?
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
    /// What the person ticked (today's defaults count as ticked): never removed behind their back.
    var userChosen: Set<String> = ["kokoro", "qwen3"]
    /// Why the last untick was refused, in words for a person; cleared by the next change.
    private(set) var notice: String?
    /// Everything that will be downloaded or used: the person's ticks plus the engines the languages require.
    var chosen: Set<String> {
        get { userChosen.union(autoEngines) }
        set { userChosen = newValue }
    }
    /// The non-commercial models the person has said they understand are for personal use only.
    private(set) var acknowledgedModels: Set<String> = []
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
        notice = nil
        if languages.contains(code) { if languages.count > 1 { languages.remove(code) } } else { languages.insert(code) }
    }

    /// Ticks or unticks a model. An engine that is the only narrator of a selected language cannot be unticked:
    /// the reason is returned (and kept in `notice`) instead of failing silently.
    @discardableResult
    func toggleModel(_ id: String) -> String? {
        notice = nil
        if chosen.contains(id) {
            if let why = lockMessage(for: id) { notice = why; return why }
            userChosen.remove(id)
        } else {
            userChosen.insert(id)
        }
        return nil
    }

    // MARK: Engines that follow from the languages

    /// Narration engines on disk.
    var installedEngines: Set<String> { installedModelIds.filter { SetupCatalog.engineLanguages[$0] != nil } }

    /// Engines added because a selected language has no narrator among the ticked and installed ones.
    var autoEngines: Set<String> {
        let ticked = userChosen.filter { SetupCatalog.engineLanguages[$0] != nil }
        return Set(SetupCatalog.required(languages: languages, have: ticked.union(installedEngines)))
    }

    /// Selected languages that `engine` alone narrates among the chosen and installed engines (empty when it is not chosen).
    func lockedLanguages(_ engine: String) -> [String] {
        guard chosen.contains(engine), let spoken = SetupCatalog.engineLanguages[engine] else { return [] }
        let others = chosen.union(installedEngines).subtracting([engine])
        return LanguageRegistry.codes.filter { code in
            languages.contains(code) && spoken.contains(code)
                && !others.contains { SetupCatalog.engineLanguages[$0]?.contains(code) == true }
        }
    }

    /// The locked languages no other engine in the catalogue speaks at all ("Required for Dutch, Arabic").
    func requiredLanguages(_ engine: String) -> [String] {
        lockedLanguages(engine).filter { SetupCatalog.candidates(for: $0) == [engine] }
    }

    /// "Required for Dutch and Arabic" or "Needed for German"; nil when the engine is not holding a language up.
    func lockLabel(_ engine: String) -> String? {
        let required = requiredLanguages(engine)
        if !required.isEmpty { return "Required for \(SetupCatalog.languageList(required))" }
        let locked = lockedLanguages(engine)
        return locked.isEmpty ? nil : "Needed for \(SetupCatalog.languageList(locked))"
    }

    func lockMessage(for engine: String) -> String? {
        let locked = lockedLanguages(engine)
        guard !locked.isEmpty else { return nil }
        let name = SetupCatalog.engineNames[engine] ?? engine
        let required = requiredLanguages(engine)
        if !required.isEmpty {
            return "\(SetupCatalog.languageList(required)) can only be narrated by \(name), so it stays selected while \(required.count == 1 ? "that language is" : "those languages are") on. You can change your languages in the previous step."
        }
        return "\(SetupCatalog.languageList(locked)) would have no voice without \(name). Select another voice that speaks \(locked.count == 1 ? "it" : "them") first, or change your languages in the previous step."
    }

    /// Draft-quality note for Quick when it is the only narrator of a language other than English.
    var quickDraftNote: String? {
        let drafts = lockedLanguages("kokoro").filter { $0 != "en" }
        guard !drafts.isEmpty else { return nil }
        var better: [String] = []
        if drafts.allSatisfy({ SetupCatalog.engineLanguages["qwen3"]?.contains($0) == true }) { better.append("High quality") }
        if drafts.allSatisfy({ SetupCatalog.engineLanguages["voxtral"]?.contains($0) == true }) { better.append("Voxtral 4B (under Other options)") }
        let tail = better.isEmpty ? "" : " \(better.joined(separator: " or ")) gives better voices."
        return "Draft quality for \(SetupCatalog.languageList(drafts)).\(tail)"
    }

    /// The live summary on the languages step.
    var languageNeedsSummary: String { SetupCatalog.needsSummary(languages: languages, installed: installedEngines) }

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

    /// Names of the models this setup downloaded, for the last step.
    var downloadedSummary: String {
        let names = items.compactMap { item -> String? in
            guard case .model = item.kind, item.state == .done else { return nil }
            return item.title
        }
        return names.joined(separator: ", ")
    }

    /// Accepts the suggestion with one tap.
    func acceptSuggestion() { userChosen.formUnion(suggestedEngines) }

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

    /// Ids of the models already on disk.
    var installedModelIds: Set<String> { Set((model?.models ?? []).filter(\.installed).map(\.engine)) }

    func isInstalled(_ id: String) -> Bool { installedModelIds.contains(id) }

    /// Download size of everything left to fetch, in GB: engine tools, chosen models, quality check and voices.
    var neededGB: Double {
        SetupCatalog.downloadGB(chosen: chosen, installed: installedModelIds, engineInstalled: engineInstalled,
                                languageCount: languagePlan.add.count)
    }

    /// Download size of the chosen voice models only (tiers and other options), in GB.
    var modelsGB: Double { SetupCatalog.narrationGB(chosen: chosen, installed: installedModelIds) }

    /// "Not enough free space..." when what is left to download does not fit on this Mac.
    var spaceWarning: String? { SetupCatalog.spaceWarning(neededGB: neededGB, freeGB: prerequisites.freeGB) }

    // MARK: Licences

    /// Chosen non-commercial models that will be downloaded now: the ones the person must acknowledge.
    var modelsNeedingAcknowledgement: [SetupModelChoice] { modelsToDownload.filter(\.noncommercial) }

    /// The one checkbox of the review step covers exactly the models listed beside it.
    var licenseAcknowledged: Bool {
        let needed = Set(modelsNeedingAcknowledgement.map(\.id))
        return !needed.isEmpty && needed.isSubset(of: acknowledgedModels)
    }

    func setLicenseAcknowledged(_ on: Bool) {
        let ids = Set(modelsNeedingAcknowledgement.map(\.id))
        if on { acknowledgedModels.formUnion(ids) } else { acknowledgedModels.subtract(ids) }
    }

    /// True when Install must wait for the acknowledgement.
    var acknowledgementPending: Bool { !modelsNeedingAcknowledgement.isEmpty && !licenseAcknowledged }

    /// Why the install cannot start yet, in words for a person; nil when it can.
    var blocker: String? { prerequisites.blocker(neededGB: neededGB) }

    /// Homebrew is missing and the engine needs it.
    var needsHomebrew: Bool { !engineInstalled && !prerequisites.homebrew }

    var canInstall: Bool { !chosen.isEmpty && blocker == nil && !needsHomebrew && !acknowledgementPending }

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
        // The acknowledgement is recorded when the downloads are started, so the licence sheet is not shown again.
        if licenseAcknowledged {
            for choice in modelsNeedingAcknowledgement { model.settings.acknowledgeLicense(engine: choice.id) }
        }
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
        if !engineInstalled { list.append(SetupItem(kind: .engine, title: "Voice engine tools", weight: SetupCatalog.engineGB, sizeLabel: SetupCatalog.sizeText(SetupCatalog.engineGB))) }
        for choice in SetupCatalog.all where chosen.contains(choice.id) {
            list.append(SetupItem(kind: .model(choice.id), title: choice.listTitle ?? choice.title, weight: choice.gb, sizeLabel: SetupCatalog.sizeText(choice.gb)))
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
