import AppKit
import Foundation
import UniformTypeIdentifiers

/// Sidebar destinations. `.job(id)` shows one job's progress / result screen.
enum SidebarItem: Hashable, Sendable {
    case newBook
    case jobs
    case job(String)
    case voices
    case models
    case benchmark
}

/// Engine data the app loads with one-shot commands (each has its own loading flag and error).
enum EngineResource: String, Hashable, Sendable, CaseIterable {
    case engines, models, voices, jobs, cache, languages
}

/// Progress of a `models download <engine>` (the engine reports parts, not bytes).
struct ModelDownload: Hashable, Sendable {
    var engine: String
    var totalParts: Int
    var finishedParts = 0
    var currentRepo: String?
    var currentPurpose: String?

    /// 0...1 by finished parts (0 while the first part downloads).
    var fraction: Double { totalParts > 0 ? min(1, Double(finishedParts) / Double(totalParts)) : 0 }

    /// "Downloading voice cloning (Base), part 2 of 2…".
    var statusText: String {
        let what = currentPurpose ?? currentRepo ?? "model files"
        if totalParts > 1 { return "Downloading \(what), part \(min(finishedParts + 1, totalParts)) of \(totalParts)…" }
        return "Downloading \(what)…"
    }
}

/// Progress of a `languages add <code>` (the engine reports the voice it is fetching).
struct LanguageDownload: Hashable, Sendable {
    var code: String
    var voicesStarted = 0
    var currentVoiceName: String?

    /// "Downloading the voice Lucía…" or "Preparing Spanish…".
    var statusText: String {
        if let name = currentVoiceName { return "Downloading the voice \(name)…" }
        return "Preparing \(Formatters.languageName(code))…"
    }
}

/// The app store: settings, engine data, the book being prepared, the voice choice, samples,
/// benchmarks and live job monitors. One instance per app (owned by AppDelegate), injected into views
/// with `.environment(model)`; read it with `@Environment(AppModel.self) private var model`.
///
/// Conventions for screens:
/// - Data (`engineList`, `models`, `voices`, `jobs`, `cacheInfo`) is read-only; reload it with the
///   `refresh…()` methods. Failures land in `errors[resource]` (show `message`, and `stderrTail` in a
///   disclosure); `loading` holds what is loading now.
/// - Actions (`startConvert`, `cancelJob`, `downloadModel`, `addVoice`, ...) are `async throws` and throw
///   `EngineError` (the engine's message as is): show it next to the control that started the action.
/// - Long streaming work returns an observable object: `SampleRun` / `BenchmarkRun` (`EngineRun`)
///   and `JobMonitor` (in `monitors[jobId]`).
/// - Nothing here blocks the main thread: every engine call is an async subprocess.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let system: SystemStatus
    /// Shared player: only one sample / audiobook plays at a time.
    let player: AudioPlayback
    /// First-run setup: engine install, model and voice downloads.
    let setup = SetupFlow()

    // MARK: Navigation

    var selection: SidebarItem? = .newBook

    // MARK: Engine data

    /// `engines` output: engine cards, preset voices and speeds measured on this Mac.
    private(set) var engineList: EngineList?
    private(set) var models: [ModelStatus] = []
    /// Library voices and the user's clips (`voices list`).
    private(set) var voices: [VoiceEntry] = []
    /// `jobs list`, newest first, plus jobs the app just started that the engine does not list yet.
    private(set) var jobs: [JobStatus] = []
    private(set) var cacheInfo: CacheInfo?
    /// `languages list`: the 13 registry languages, which are on, and what each needs. Empty until loaded
    /// (then English counts as the enabled one).
    private(set) var languageList: [LanguageInfo] = []
    /// `languages add` in progress, by language code (at most one at a time).
    private(set) var languageDownloads: [String: LanguageDownload] = [:]
    /// Language codes with a `languages remove` in progress.
    private(set) var languageRemovals: Set<String> = []
    /// The last failure of adding / removing a language, by code (cleared by the next attempt).
    private(set) var languageErrors: [String: EngineError] = [:]
    /// The outcome of the last add / remove of each language (voices that failed or were kept).
    private(set) var languageResults: [String: LanguageChangeResult] = [:]
    private(set) var loading: Set<EngineResource> = []
    private(set) var errors: [EngineResource: EngineError] = [:]

    var engines: [EngineInfo] { engineList?.engines ?? [] }

    // MARK: Book draft

    /// The book being prepared (nil until a book is opened). Edit in place: `model.draft?.toggle(3)`.
    /// Change the language with `setLanguage(_:)` so the voice follows.
    var draft: BookDraft?
    private(set) var isInspecting = false
    /// `inspect` failure (e.g. a scanned PDF that needs OCR), shown inline on the New audiobook screen.
    private(set) var bookError: EngineError?

    // MARK: Voice

    /// Narrator used by `startSample` / `startConvert` unless one is passed explicitly.
    var voiceSelection: VoiceSelection?

    // MARK: Runs and jobs

    /// Samples made this session, newest first (at most `maxKeptRuns` finished ones are kept).
    private(set) var samples: [SampleRun] = []
    /// Benchmarks run this session, newest first.
    private(set) var benchmarks: [BenchmarkRun] = []
    /// Live or replayed job monitors by job id. Create one with `attachMonitor(jobId:)`.
    private(set) var monitors: [String: JobMonitor] = [:]
    /// Model downloads in progress, by engine id.
    private(set) var modelDownloads: [String: ModelDownload] = [:]
    /// Voice ids with a download / remove / transcript update in progress
    /// (and "add:<file path>" while `addVoice` runs).
    private(set) var busyVoiceIds: Set<String> = []
    private(set) var isClearingCache = false

    /// Voices screen state that outlives the view (filters, previews, A/B comparison).
    let voiceLab = VoiceLab()

    /// Runs the engine installer to update an engine that is older than this app needs (AppModel+EngineUpdate).
    let engineUpdater = EngineInstaller()
    /// Why the last engine update failed (cleared by the next attempt).
    var engineUpdateError: EngineError?
    /// The engine location the app installs to and may update (tests point it elsewhere).
    @ObservationIgnored var managedEnginePath = EngineClient.managedPath
    /// Automatic updates on: the engine is then updated silently too (tests replace it).
    @ObservationIgnored var automaticUpdates: () -> Bool = { AppModel.automaticUpdatesEnabled() }
    /// The installer an engine update runs; nil uses `EngineInstaller.scriptURL()` (tests use a stub).
    @ObservationIgnored var engineInstallerScript: URL?

    /// Options for new job monitors (tests use `.testing`).
    @ObservationIgnored var monitorOptions = JobMonitor.Options()
    /// Per-launch temporary folder for covers and samples.
    @ObservationIgnored let scratchDirectory: URL

    static let maxKeptRuns = 20
    static let openableTypes: [UTType] = [.epub, .pdf]

    @ObservationIgnored private var monitorOrder: [String] = []
    /// The task reading each `models download` (cancelling it stops the engine process).
    @ObservationIgnored private var modelDownloadTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var languageTasks: [String: Task<EngineEvent?, Error>] = [:]
    @ObservationIgnored private var inspectToken = UUID()
    @ObservationIgnored private var didLaunch = false

    init(settings: AppSettings = AppSettings(), system: SystemStatus = SystemStatus(),
         player: AudioPlayback = AudioPlayback(), scratchDirectory: URL? = nil) {
        self.settings = settings
        self.system = system
        self.player = player
        self.scratchDirectory = scratchDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("AudiobookStudio", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        setup.model = self
    }

    /// A client for the engine path currently in Settings.
    var client: EngineClient { EngineClient(path: settings.enginePath) }

    // MARK: - Launch and refresh

    /// Called once at app launch: starts the machine status poller, asks for notification permission,
    /// loads everything and re-attaches to jobs that are still queued or running.
    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        system.start()
        if settings.notificationsEnabled { Notifications.requestAuthorization() }
        await refreshAll()
        reattachRunningJobs()
        openSetupIfNeeded()
        autoUpdateEngineIfNeeded()
    }

    /// True when the engine cannot be reached because it is not installed.
    var engineMissing: Bool { errors[.engines]?.engineMissing ?? false }

    /// The engine works but no voice model is on disk yet.
    var hasNoModels: Bool { engineList != nil && !models.contains { $0.installed } }

    /// Something is left to set up: the engine, or the first voice model.
    var needsSetup: Bool { engineMissing || hasNoModels }

    /// First launch: opens the setup when the engine or the models are missing. Someone whose engine already
    /// works (an update, a development build) never sees it.
    private func openSetupIfNeeded() {
        guard settings.setupState == .notStarted else { return }
        if needsSetup { setup.present() } else if errors[.engines] == nil { settings.setupState = .completed }
    }

    /// Reloads engines, models, voices, jobs and cache info concurrently (call after changing the engine path).
    func refreshAll() async {
        async let e: Void = refreshEngines()
        async let m: Void = refreshModels()
        async let v: Void = refreshVoices()
        async let j: Void = refreshJobs()
        async let c: Void = refreshCache()
        async let l: Void = refreshLanguages()
        _ = await (e, m, v, j, c, l)
    }

    func refreshEngines() async {
        guard let list = await load(.engines, ["engines"], as: EngineList.self) else { return }
        engineList = list
        ensureVoiceSelection()
    }

    func refreshLanguages() async {
        guard let list = await load(.languages, ["languages", "list"], as: LanguageList.self) else { return }
        languageList = list.languages
        LanguageRegistry.setReported(Dictionary(list.languages.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a }))
        ensureVoiceSelection()
    }

    func refreshModels() async {
        guard let list = await load(.models, ["models", "list"], as: ModelList.self) else { return }
        models = list.models
    }

    func refreshVoices() async {
        guard let list = await load(.voices, ["voices", "list"], as: VoiceList.self) else { return }
        voices = list.voices
        ensureVoiceSelection()
    }

    /// Reloads `jobs list` and follows every queued/running job that has no monitor yet (so jobs are
    /// re-attached after launch, after the engine location is fixed in Settings, or when started elsewhere).
    func refreshJobs() async {
        guard let list = await load(.jobs, ["jobs", "list"], as: JobList.self) else { return }
        let listed = Set(list.jobs.map(\.jobId))
        // A just-started job writes job.json a moment after `convert --detach` returns: keep it meanwhile.
        let pending = jobs.filter { !listed.contains($0.jobId) && (monitors[$0.jobId]?.state.isActive ?? false) }
        jobs = pending + list.jobs
        reattachRunningJobs()
    }

    func refreshCache() async {
        guard let info = await load(.cache, ["cache", "info"], as: CacheInfo.self) else { return }
        cacheInfo = info
    }

    /// Runs `engines` with another executable (Settings "Test" button). Throws EngineError.
    func testEngine(path: String) async throws -> EngineList {
        do { return try await EngineClient(path: path).json(["engines"], as: EngineList.self) } catch { throw EngineError(error) }
    }

    /// Fills engine data without running the engine: for SwiftUI previews and tests
    /// (e.g. decode the JSON fixtures and pass them here). nil leaves a value unchanged.
    func preload(engines: EngineList? = nil, models: [ModelStatus]? = nil, voices: [VoiceEntry]? = nil,
                 jobs: [JobStatus]? = nil, cache: CacheInfo? = nil, languages: [LanguageInfo]? = nil) {
        if let engines { engineList = engines }
        if let models { self.models = models }
        if let voices { self.voices = voices }
        if let jobs { self.jobs = jobs }
        if let cache { cacheInfo = cache }
        if let languages {
            languageList = languages
            LanguageRegistry.setReported(Dictionary(languages.map { ($0.code, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        ensureVoiceSelection()
    }

    private func load<T: Decodable & Sendable>(_ resource: EngineResource, _ args: [String], as type: T.Type) async -> T? {
        loading.insert(resource)
        defer { loading.remove(resource) }
        do {
            let value = try await client.json(args, as: T.self)
            errors[resource] = nil
            return value
        } catch {
            // The caller went away (e.g. a screen's `.task` ended): the engine was stopped, not broken.
            guard !Task.isCancelled else { return nil }
            errors[resource] = EngineError(error)
            return nil
        }
    }

    // MARK: - Opening a book

    static func canOpen(_ url: URL) -> Bool { ["epub", "pdf"].contains(url.pathExtension.lowercased()) }

    /// Runs `inspect` (cover written to a temporary folder) and makes the result the current draft.
    /// Errors go to `bookError`. Opening another book while one is inspected keeps only the latest.
    func openBook(_ url: URL) async {
        selection = .newBook
        guard AppModel.canOpen(url) else {
            bookError = EngineError(message: "Audiobook Studio opens EPUB and PDF books. “\(url.lastPathComponent)” is not one.")
            return
        }
        let token = UUID()
        inspectToken = token
        isInspecting = true
        bookError = nil
        let coverFolder = scratchFolder("covers").appendingPathComponent(token.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: coverFolder, withIntermediateDirectories: true)
        let coverOut = coverFolder.appendingPathComponent("cover.png")
        do {
            let info = try await client.json(["inspect", url.path, "--cover-out", coverOut.path], as: BookInfo.self)
            guard inspectToken == token else { return }
            let cover = AppModel.finalizeCover(info.cover, writtenTo: coverOut)
            draft = BookDraft(url: url, info: info, coverURL: cover)
            ensureVoiceSelection()
        } catch {
            guard inspectToken == token else { return }
            bookError = EngineError(error)
        }
        isInspecting = false
    }

    /// Shows the standard Open panel (⌘O) and opens the chosen book.
    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.openableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an EPUB or PDF book to turn into an audiobook."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openBook(url) }
    }

    /// Drag and drop onto the window: opens the first EPUB/PDF. Returns false when nothing could be opened.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: AppModel.canOpen) else {
            if let first = urls.first {
                selection = .newBook
                bookError = EngineError(message: "Audiobook Studio opens EPUB and PDF books. “\(first.lastPathComponent)” is not one.")
            }
            return false
        }
        Task { await openBook(url) }
        return true
    }

    /// Clears the current book and stops its samples and voice previews that are still running (no screen
    /// shows them without the book, and they would keep the GPU busy).
    func closeBook() {
        if let closed = draft?.url.path {
            for run in samples where run.isRunning && run.bookPath == closed { run.cancel() }
        }
        inspectToken = UUID()
        draft = nil
        bookError = nil
        isInspecting = false
    }

    /// Changes the book language and switches to that language's default voice.
    func setLanguage(_ language: String) {
        guard var d = draft, d.language != language else { return }
        d.language = language
        draft = d
        voiceSelection = defaultVoice(for: language) ?? voiceSelection
    }

    /// The engine writes the cover bytes as they are; give the file the extension of its real type.
    private static func finalizeCover(_ cover: CoverInfo?, writtenTo url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let mime = cover?.mediaType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension,
              ext != url.pathExtension else { return url }
        let renamed = url.deletingPathExtension().appendingPathExtension(ext)
        do {
            try FileManager.default.moveItem(at: url, to: renamed)
            return renamed
        } catch {
            return url
        }
    }

    // MARK: - Voice and estimate

    /// Saved default for `language` (Settings), else a suggestion from the installed engines and voices.
    func defaultVoice(for language: String) -> VoiceSelection? {
        if let saved = settings.defaultVoices[language],
           engineList == nil || saved.fits(language: language, engines: engines, voices: voices) {
            return saved
        }
        return VoiceSelection.suggested(for: language, engines: engines, voices: voices, models: models)
    }

    /// Saves the current voice as the default for the book's language (or `language`).
    func saveVoiceAsDefault(for language: String? = nil) {
        guard let v = voiceSelection, let lang = language ?? draft?.language else { return }
        settings.defaultVoices[lang] = v
    }

    /// Estimated conversion time of the selected sections with the selected voice, from the measured
    /// speed (`EngineList.rate`). nil when the engine was never measured on this Mac.
    var estimate: ConversionEstimate? {
        guard let draft, let voice = voiceSelection else { return nil }
        return estimate(chars: draft.includedChars, voice: voice)
    }

    /// "On this Mac: ≈ 41 min", or the hint to run a benchmark / sample.
    var estimateSummary: String { estimate?.summary ?? ConversionEstimate.unavailableMessage }

    /// Estimate for any character count and voice (engine cards, A/B comparisons).
    func estimate(chars: Int, voice: VoiceSelection) -> ConversionEstimate? {
        guard let list = engineList, let rate = list.rate(engine: voice.engineId, voice: voice.voiceId), rate > 0,
              let m = list.measurement(engine: voice.engineId, voice: voice.voiceId) else { return nil }
        return ConversionEstimate(seconds: Double(chars) / rate, charsPerSecond: rate, exactVoice: m.exactVoice,
                                  measurement: m.measurement)
    }

    /// Keeps `voiceSelection` valid for the book language once engines / voices are known.
    private func ensureVoiceSelection() {
        let language = draft?.language ?? fallbackLanguage
        if let v = voiceSelection, engineList == nil || v.fits(language: language, engines: engines, voices: voices) { return }
        if let suggestion = defaultVoice(for: language) { voiceSelection = suggestion }
    }

    // MARK: - Samples and benchmarks

    /// Narrates a short sample of the current book (`sample`), e.g. seconds 20 for a voice preview,
    /// 120 for "Make a 2-minute sample". Two calls with different voices give an A/B comparison
    /// (the engine queues the second while the first uses the GPU). Returns nil when no book is open
    /// or no voice is chosen. When it finishes, measured speeds are reloaded (the engine saves them).
    @discardableResult
    func startSample(voice: VoiceSelection? = nil, section: Int? = nil, seconds: Double = 120) -> SampleRun? {
        guard let draft, let voice = voice ?? voiceSelection else { return nil }
        let out = scratchFolder("samples").appendingPathComponent("sample-\(UUID().uuidString).m4a")
        let request = SampleRequest(bookPath: draft.url.path, voice: voice, language: draft.language,
                                    section: section, seconds: seconds, outputPath: out.path)
        let run = SampleRun(kind: .sample, voice: voice, language: draft.language, section: section, outputURL: out,
                            bookPath: draft.url.path)
        run.onFinish = { [weak self] run in
            guard run.result != nil else { return }
            Task { await self?.refreshEngines() }
        }
        samples.insert(run, at: 0)
        samples = AppModel.trimmed(samples)
        run.start(client: client, arguments: request.arguments)
        return run
    }

    /// Measures an engine + voice on this Mac (`benchmark`). Results feed every estimate:
    /// `engineList.measured` is reloaded when it finishes.
    @discardableResult
    func startBenchmark(voice: VoiceSelection, language: String) -> BenchmarkRun {
        let run = BenchmarkRun(kind: .benchmark, voice: voice, language: language)
        run.onFinish = { [weak self] run in
            guard run.result != nil else { return }
            Task { await self?.refreshEngines() }
        }
        benchmarks.insert(run, at: 0)
        benchmarks = AppModel.trimmed(benchmarks)
        run.start(client: client, arguments: BenchmarkRequest(voice: voice, language: language).arguments)
        return run
    }

    /// Stops the engine processes that exist only for this app's screens: running samples, voice previews,
    /// benchmarks and model downloads. Called when the app quits; conversions run detached and keep going.
    func stopScreenEngineWork() {
        for run in samples + benchmarks where run.isRunning { run.cancel() }
        for task in modelDownloadTasks.values { task.cancel() }
        for task in languageTasks.values { task.cancel() }
    }

    /// Keeps running runs and the newest finished ones.
    private static func trimmed(_ runs: [EngineRun]) -> [EngineRun] {
        var kept = 0
        return runs.filter { run in
            if run.isRunning { return true }
            kept += 1
            return kept <= maxKeptRuns
        }
    }

    // MARK: - Conversion jobs

    /// Starts converting the current draft in the background (`convert ... --detach`), registers a live
    /// JobMonitor, adds the job to `jobs` and selects its screen. Uses `voice` or `voiceSelection` and the
    /// output folder, bitrate and keep-work settings. Throws EngineError (e.g. "Not enough disk space ...":
    /// check `isDiskSpace` to show it prominently).
    @discardableResult
    func startConvert(voice: VoiceSelection? = nil) async throws -> JobMonitor {
        guard let draft else { throw EngineError(message: "Open a book first.") }
        guard let voice = voice ?? voiceSelection else { throw EngineError(message: "Choose a voice first.") }
        guard draft.hasSelection else { throw EngineError(message: "Select at least one section to convert.") }
        let request = ConvertRequest(bookPath: draft.url.path, voice: voice, language: draft.language,
                                     sections: Array(draft.included), outputFolder: settings.outputFolder,
                                     bitrateKbps: settings.bitrateKbps, keepWork: settings.keepWork)
        let placeholder = JobStatus(jobId: "", book: draft.url.path, title: draft.title, author: draft.author,
                                    lang: draft.language, engine: voice.engineId, voice: voice.voiceId,
                                    speed: voice.speed, state: JobState.queued.engineValue, jobDir: "")
        return try await launchDetached(request.arguments, placeholder: placeholder)
    }

    /// Runs a stopped job again with its recorded arguments (same options → same job: finished chunks and
    /// chapters are reused). For cancelled, interrupted or failed jobs.
    /// Views check `licenseToAcknowledge(beforeResuming:)` first and show the licence sheet; this refuses
    /// (without running the engine) when that was skipped.
    @discardableResult
    func resumeJob(_ job: JobStatus) async throws -> JobMonitor {
        guard let argv = job.argv, argv.first == "convert" else {
            throw EngineError(message: "This job's settings were not recorded. Open the book and convert it again.")
        }
        if job.hasRelativeBookPath, let book = job.book {
            throw EngineError(message: "This job was started from the terminal with the book path “\(book)”, relative to "
                + "the folder it was started in. Resume it from the terminal in that folder, or open the book here and convert it again.")
        }
        if let engineId = job.engine {
            if let engine = licenseToAcknowledge(beforeResuming: job) {
                throw EngineError(message: "\(engine.name) is for non-commercial use only. Acknowledge its licence before resuming.")
            }
            if licenseWaitsForEngineList(engineId) { throw EngineError(message: BookBlocker.licenseNotShownYet.message) }
        }
        var placeholder = job
        placeholder.state = JobState.queued.engineValue
        return try await launchDetached(argv.filter { $0 != "--detach" } + ["--detach"], placeholder: placeholder)
    }

    /// Asks the engine to stop a job (`jobs cancel`). The monitor then receives the `cancelled` event.
    /// Throws EngineError when the engine refuses (e.g. the job already finished).
    func cancelJob(_ id: String) async throws {
        let result: JobCancelResult
        do {
            result = try await client.json(["jobs", "cancel", id], as: JobCancelResult.self)
        } catch {
            throw EngineError(error)
        }
        await refreshJobs()
        if !result.cancelled {
            throw EngineError(message: "The job could not be stopped (\(result.reason ?? "no reason given")).")
        }
    }

    /// Opens a job's book again and preselects its voice ("Convert again with other settings").
    func convertAgain(_ job: JobStatus) async {
        guard let url = job.bookURL else { return }
        await openBook(url)
        guard let engineId = job.engine else { return }
        var v = VoiceSelection(engineId: engineId, speed: job.speed ?? 1.0)
        if let id = job.voice {
            let isPreset = engineList?.engine(engineId)?.voices.contains { $0.id == id } ?? false
            if isPreset { v.choosePreset(id) } else if voices.contains(where: { $0.id == id }) { v.chooseReferenceVoice(id) }
        }
        voiceSelection = v
        if let lang = job.lang, draft != nil { draft?.language = lang }
    }

    /// The monitor for a job, creating (and starting) it if needed. Call from `.task` / `.onAppear`,
    /// never from `body` (it mutates state). Returns nil for an unknown job id.
    ///
    /// An existing monitor is kept, except one that saw its run end while the engine now lists the job as
    /// queued/running in another process (e.g. resumed from the terminal): that newer run gets a live monitor.
    @discardableResult
    func attachMonitor(jobId: String) -> JobMonitor? {
        let job = jobs.first { $0.jobId == jobId }
        if let existing = monitors[jobId] {
            guard let job, AppModel.isNewerRun(job, than: existing) else { return existing }
            return register(JobMonitor(status: job, client: client, options: monitorOptions))
        }
        guard let job else { return nil }
        return register(JobMonitor(status: job, client: client, options: monitorOptions))
    }

    /// True when `job` (from `jobs list`) is a queued/running run that `monitor` does not follow: the monitor's
    /// run has ended and the engine reports another process. The same pid is the run the monitor already saw
    /// end (a list read just before it ended), so it is not followed again.
    static func isNewerRun(_ job: JobStatus, than monitor: JobMonitor) -> Bool {
        guard job.isActive, !monitor.state.isActive, let pid = job.pid else { return false }
        return pid != monitor.pid
    }

    /// Follows every queued/running job from `jobs list` (app launch, every `refreshJobs`). Idempotent:
    /// a job that already has a monitor keeps it, unless that monitor's run ended and the job runs again.
    func reattachRunningJobs() {
        for job in jobs where job.isActive { attachMonitor(jobId: job.jobId) }
    }

    /// Live state of a listed job: the monitor's when there is one, else the engine's.
    func liveState(of job: JobStatus) -> JobState { monitors[job.jobId]?.state ?? job.jobState }

    /// Jobs queued or running (sidebar badge).
    var activeJobCount: Int {
        let monitored = monitors.values.filter { $0.state.isActive }.count
        let unmonitored = jobs.filter { monitors[$0.jobId] == nil && $0.isActive }.count
        return monitored + unmonitored
    }

    /// Monitors shown under "Jobs" in the sidebar: active ones, plus the selected job.
    var sidebarMonitors: [JobMonitor] {
        monitorOrder.compactMap { monitors[$0] }.filter { $0.state.isActive || selection == .job($0.jobId) }
    }

    private func launchDetached(_ args: [String], placeholder: JobStatus) async throws -> JobMonitor {
        let detached: DetachedJob
        do {
            detached = try await client.json(args, as: DetachedJob.self)
        } catch {
            throw EngineError(error)
        }
        if detached.alreadyRunning == true, let existing = monitors[detached.jobId], existing.state.isActive {
            selection = .job(detached.jobId)
            return existing
        }
        let monitor = JobMonitor(jobId: detached.jobId, jobDir: URL(fileURLWithPath: detached.jobDir),
                                 eventsURL: detached.eventsURL, pid: detached.pid, initialState: .queued,
                                 title: placeholder.title, author: placeholder.author, engine: placeholder.engine,
                                 voice: placeholder.voice, lang: placeholder.lang, client: client, options: monitorOptions)
        register(monitor)
        var status = placeholder
        status.jobId = detached.jobId
        status.jobDir = detached.jobDir
        status.pid = detached.pid
        status.state = JobState.queued.engineValue
        status.result = nil
        status.lastError = nil
        status.error = nil
        jobs.removeAll { $0.jobId == detached.jobId }
        jobs.insert(status, at: 0)
        selection = .job(detached.jobId)
        Task { await refreshJobs() }
        return monitor
    }

    @discardableResult
    private func register(_ monitor: JobMonitor) -> JobMonitor {
        monitors[monitor.jobId]?.stop()
        monitor.notificationsAllowed = { [weak self] in self?.settings.notificationsEnabled ?? false }
        monitor.onFinish = { [weak self] _ in
            Task { await self?.jobDidFinish() }
        }
        monitors[monitor.jobId] = monitor
        monitorOrder.removeAll { $0 == monitor.jobId }
        monitorOrder.append(monitor.jobId)
        monitor.start()
        return monitor
    }

    private func jobDidFinish() async {
        await refreshJobs()
        await refreshEngines()  // a finished conversion updates the measured speeds
        await refreshCache()
        autoUpdateEngineIfNeeded()   // an engine update waiting for this conversion can run now
    }

    // MARK: - Models

    /// Downloads an engine's model files (`models download`), with progress in `modelDownloads[engineId]`.
    /// The only engine command that uses the network. Throws EngineError.
    func downloadModel(_ engineId: String) async throws {
        guard modelDownloads[engineId] == nil else { return }
        let parts = models.first { $0.engine == engineId }?.parts.count ?? 0
        modelDownloads[engineId] = ModelDownload(engine: engineId, totalParts: parts)
        defer { modelDownloads[engineId] = nil }
        let client = self.client
        // Read in a task of its own so that quitting the app can stop it (`stopScreenEngineWork`);
        // cancelling the caller still cancels it too.
        let download = Task { [weak self] in
            for try await ev in client.stream(["models", "download", engineId]) {
                switch ev.event {
                case "download_start":
                    self?.modelDownloads[engineId]?.currentRepo = ev.repo
                    self?.modelDownloads[engineId]?.currentPurpose = ev.purpose
                case "download_done":
                    self?.modelDownloads[engineId]?.finishedParts += 1
                default:
                    break
                }
            }
        }
        modelDownloadTasks[engineId] = download
        defer { modelDownloadTasks[engineId] = nil }
        do {
            try await withTaskCancellationHandler {
                try await download.value
            } onCancel: {
                download.cancel()
            }
        } catch {
            await refreshModels()
            throw EngineError(error)
        }
        await refreshModels()
        await refreshEngines()
        await refreshLanguages()
    }

    /// Deletes an engine's model files (`models remove`). Throws EngineError.
    func removeModel(_ engineId: String) async throws {
        do {
            _ = try await client.json(["models", "remove", engineId], as: EngineEvent.self)
        } catch {
            throw EngineError(error)
        }
        await refreshModels()
        await refreshLanguages()
    }

    // MARK: - Languages

    /// True while a language is being added or removed (the engine changes its settings one at a time).
    var isChangingLanguage: Bool { !languageDownloads.isEmpty || !languageRemovals.isEmpty }

    /// Forgets the last failure and outcome shown for a language (the dismiss button of a message).
    func clearLanguageMessages(_ code: String) {
        languageErrors[code] = nil
        languageResults[code] = nil
    }

    /// Turns a language on and downloads its small reference voices (`languages add`), with progress in
    /// `languageDownloads[code]`. Model files are never downloaded here: a language that no installed engine
    /// can speak yet reports `needs` (the engine to install in Models). Returns nil when this language is
    /// already being changed. Throws EngineError (also kept in `languageErrors[code]`), e.g. when another
    /// language is being changed.
    @discardableResult
    func addLanguage(_ code: String) async throws -> LanguageChangeResult? {
        if languageDownloads[code] != nil || languageRemovals.contains(code) { return nil }
        guard !isChangingLanguage else {
            throw EngineError(message: "Another language is being changed. Wait for it to finish.")
        }
        languageErrors[code] = nil
        languageResults[code] = nil
        languageDownloads[code] = LanguageDownload(code: code)
        defer { languageDownloads[code] = nil }
        let client = self.client
        // Read in a task of its own so that quitting the app can stop it (`stopScreenEngineWork`).
        let task = Task<EngineEvent?, Error> { [weak self] in
            var done: EngineEvent?
            for try await ev in client.stream(["languages", "add", code]) {
                switch ev.event {
                case "language_voice":
                    self?.languageDownloads[code]?.currentVoiceName = ev.name ?? ev.id
                    self?.languageDownloads[code]?.voicesStarted += 1
                case "language_done":
                    done = ev
                default:
                    break
                }
            }
            return done
        }
        languageTasks[code] = task
        defer { languageTasks[code] = nil }
        let done: EngineEvent?
        do {
            done = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            await refreshLanguages()
            await refreshVoices()
            let failure = EngineError(error)
            languageErrors[code] = failure
            throw failure
        }
        let result = LanguageChangeResult(code: code, event: done, enabledDefault: true)
        languageResults[code] = result
        await refreshLanguages()
        await refreshVoices()
        return result
    }

    /// Turns a language off and deletes the reference voices downloaded for it (`languages remove`). Voices
    /// that still narrate a running job are kept and reported in the result, not as an error. The shared
    /// model files stay. Throws EngineError, e.g. "At least one language must stay on." (also kept in
    /// `languageErrors[code]`). Returns nil when this language is already being changed.
    @discardableResult
    func removeLanguage(_ code: String) async throws -> LanguageChangeResult? {
        if languageDownloads[code] != nil || languageRemovals.contains(code) { return nil }
        guard !isChangingLanguage else {
            throw EngineError(message: "Another language is being changed. Wait for it to finish.")
        }
        languageErrors[code] = nil
        languageResults[code] = nil
        languageRemovals.insert(code)
        defer { languageRemovals.remove(code) }
        let files = Dictionary(uniqueKeysWithValues: voices.compactMap { v in v.path.map { (v.id, URL(fileURLWithPath: $0)) } })
        let done: EngineEvent
        do {
            done = try await client.json(["languages", "remove", code], as: EngineEvent.self)
        } catch {
            let failure = EngineError(error)
            languageErrors[code] = failure
            throw failure
        }
        let result = LanguageChangeResult(code: code, event: done, enabledDefault: false)
        languageResults[code] = result
        await refreshLanguages()
        await refreshVoices()
        for id in result.removedVoices { forgetVoice(id, file: files[id]) }
        if case .only(code) = voiceLab.filter.language { voiceLab.filter.language = .book }
        ensureVoiceSelection()
        return result
    }

    // MARK: - Voices

    /// Installs a library voice (`voices download`). Throws EngineError.
    @discardableResult
    func downloadVoice(_ id: String) async throws -> VoiceEntry {
        try await voiceOperation(id, ["voices", "download", id])
    }

    /// Adds the user's own clip (`voices add`). `hasRights` must come from the consent checkbox
    /// ("I have the right to use this voice"); `--i-have-rights` is passed only when it is true.
    /// Without a transcript the engine transcribes the clip with Whisper. Throws EngineError.
    @discardableResult
    func addVoice(file: URL, name: String, language: String, transcript: String?, hasRights: Bool,
                  isolate: Bool = false, enhance: Bool = false) async throws -> VoiceEntry {
        guard hasRights else {
            throw EngineError(message: "Confirm that you have the right to use this voice before adding it.")
        }
        var args = ["voices", "add", file.path, "--name=\(name)", "--lang=\(language)"]
        if let t = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { args.append("--transcript=\(t)") }
        if isolate { args.append("--isolate") }
        if enhance { args.append("--enhance") }
        args.append("--i-have-rights")
        return try await voiceOperation("add:\(file.path)", args)
    }

    /// Changes the recording of one of the user's voices (`voices replace`), keeping its id, name and settings.
    /// With `file`: a new recording (needs `hasRights`, the consent checkbox). Without: the engine processes the
    /// kept original again with the given clean-up boxes. Previews and samples of the old recording are
    /// dropped. Throws EngineError.
    @discardableResult
    func replaceVoice(id: String, file: URL?, isolate: Bool, enhance: Bool, transcript: String?,
                      hasRights: Bool) async throws -> VoiceEntry {
        var args = ["voices", "replace", id, isolate ? "--isolate" : "--no-isolate", enhance ? "--enhance" : "--no-enhance"]
        if let file {
            guard hasRights else {
                throw EngineError(message: "Confirm that you have the right to use this voice before changing the recording.")
            }
            args.append("--file=\(file.path)")
            if let t = transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { args.append("--transcript=\(t)") }
            args.append("--i-have-rights")
        }
        let oldClip = voices.first(where: { $0.id == id })?.path.map { URL(fileURLWithPath: $0) }
        let entry = try await voiceOperation(id, args)
        forgetVoiceAudio(id, file: oldClip)
        return entry
    }

    /// The clean-up models among the ticked boxes that are known to be missing (download them first).
    func missingCleanupModels(isolate: Bool, enhance: Bool) -> [String] {
        var wanted: [String] = []
        if isolate { wanted.append(OpsModelInfo.voiceIsolationModel) }
        if enhance { wanted.append(OpsModelInfo.voiceEnhancerModel) }
        return wanted.filter(isEngineMissing)
    }

    /// After a voice's recording changed: stop playing the old clip and drop previews and samples made with it,
    /// so the old audio is not replayed under the same voice.
    func forgetVoiceAudio(_ id: String, file: URL?) {
        if let file, player.isPlaying(file) { player.stop() }
        voiceLab.forgetPreviews(refVoiceId: id)
        for run in samples where run.voice.refVoiceId == id && run.isRunning { run.cancel() }
        samples.removeAll { $0.voice.refVoiceId == id }
    }

    /// Removes an installed voice (`voices remove`). Throws EngineError.
    func removeVoice(_ id: String) async throws {
        let removedFile = voices.first(where: { $0.id == id })?.path.map { URL(fileURLWithPath: $0) }
        busyVoiceIds.insert(id)
        defer { busyVoiceIds.remove(id) }
        do {
            _ = try await client.json(["voices", "remove", id], as: EngineEvent.self)
        } catch {
            throw EngineError(error)
        }
        await refreshVoices()
        forgetVoice(id, file: removedFile)
        await refreshLanguages()
    }

    /// Clears every reference to a deleted voice: playback of its clip, saved per-language defaults,
    /// and the narrator (which falls back to the default voice for the book's language).
    func forgetVoice(_ id: String, file: URL?) {
        if let file, player.isPlaying(file) { player.stop() }
        for (language, saved) in settings.defaultVoices where saved.refVoiceId == id {
            settings.defaultVoices[language] = nil
        }
        if voiceSelection?.refVoiceId == id {
            voiceSelection = draft.flatMap { defaultVoice(for: $0.language) }
        }
    }

    /// Replaces a voice's transcript (`voices transcript`): Whisper can mishear names, and cloning
    /// quality depends on it. Throws EngineError.
    @discardableResult
    func updateTranscript(voiceId: String, text: String) async throws -> VoiceEntry {
        // "--" ends option parsing, so a transcript starting with "-" is not read as an option.
        try await voiceOperation(voiceId, ["voices", "transcript", voiceId, "--", text])
    }

    private func voiceOperation(_ busyKey: String, _ args: [String]) async throws -> VoiceEntry {
        busyVoiceIds.insert(busyKey)
        defer { busyVoiceIds.remove(busyKey) }
        let entry: VoiceEntry
        do {
            entry = try await client.json(args, as: VoiceEntry.self)
        } catch {
            throw EngineError(error)
        }
        await refreshVoices()
        await refreshLanguages()
        return entry
    }

    // MARK: - Cache

    /// Frees cached audio (`cache clear [--jobs]`); refused by the engine while a job runs.
    /// Returns the number of bytes freed. Throws EngineError.
    @discardableResult
    func clearCache(includeFinishedJobs: Bool) async throws -> Int64 {
        isClearingCache = true
        defer { isClearingCache = false }
        let ev: EngineEvent
        do {
            ev = try await client.json(["cache", "clear"] + (includeFinishedJobs ? ["--jobs"] : []), as: EngineEvent.self)
        } catch {
            throw EngineError(error)
        }
        await refreshCache()
        if includeFinishedJobs { await refreshJobs() }
        return ev.freedBytes ?? 0
    }

    // MARK: - Files

    private func scratchFolder(_ name: String) -> URL {
        let url = scratchDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
