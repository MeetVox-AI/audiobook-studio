import Darwin
import Foundation

/// One point of the speed chart (one `progress` event that carried a rate).
struct RatePoint: Identifiable, Hashable, Sendable {
    var id: Int
    /// Seconds since the run started (`elapsed_s`, else `t`).
    var elapsed: Double
    /// Recent speed (`rate_cps`, characters per second over a sliding window).
    var rateCps: Double
    /// Average speed of this run (`run_rate_cps`).
    var runRateCps: Double?
    /// Audio seconds produced per wall second (`realtime_x`).
    var realtimeX: Double?
    var percent: Double?
}

/// A chunk the speech check could not get right (`chunk_flagged`).
struct FlaggedChunk: Identifiable, Hashable, Sendable {
    var section: Int
    var chunk: Int
    var issues: [String]
    var text: String
    var id: String { "\(section)-\(chunk)" }
}

/// What the job process is doing right now (finer than JobState).
enum JobPhase: Equatable, Sendable {
    case starting
    case waitingForGPU(String)
    case loadingModel
    case synthesizing
    case assembling
    case encoding(percent: Double)
    case finished

    var title: String {
        switch self {
        case .starting: return "Starting…"
        case .waitingForGPU(let message): return message
        case .loadingModel: return "Loading the voice model…"
        case .synthesizing: return "Narrating"
        case .assembling: return "Assembling chapters…"
        case .encoding(let p): return "Encoding the audiobook (\(Formatters.percent(p)))"
        case .finished: return "Finished"
        }
    }
}

/// Live state of one conversion job, read from its `events.jsonl`.
///
/// Two modes, chosen from the state the job had when the monitor was created:
/// - **live** (job queued/running): tails the file with `EventTailer`, starting at the run whose
///   `run_start.pid` matches the job's process (or the latest run when the pid is unknown) so a terminal
///   event left by an earlier run of the same job is never mistaken for the end. While live it keeps the Mac
///   awake (ProcessInfo activity), checks every few seconds that the process is still alive (a killed process
///   writes no terminal event; the engine then reports "interrupted"), and on done/failure posts a
///   notification (bundled app only) and calls `onFinish`.
/// - **replay** (job already finished): reads the latest run once to fill the chart, flagged chunks and result.
///
/// All state is on the main actor; views observe it directly.
@MainActor
@Observable
final class JobMonitor: Identifiable {
    struct Options: Sendable {
        /// Begin a ProcessInfo activity (idle sleep disabled) while the job is live.
        var keepAwake = true
        /// Post a notification when a live job ends (also requires a bundled app).
        var notifications = true
        var pollInterval: Duration = .milliseconds(400)
        /// How often to check that the job process is alive; nil disables the check.
        var livenessInterval: Duration? = .seconds(5)

        /// No side effects, fast polling: for tests.
        static let testing = Options(keepAwake: false, notifications: false, pollInterval: .milliseconds(20), livenessInterval: nil)
    }

    nonisolated let id: String
    var jobId: String { id }
    let jobDir: URL
    let eventsURL: URL
    /// The job was queued/running when the monitor was created (it is followed live).
    let isLive: Bool

    /// The run's process id (from `convert --detach`, `jobs list`, or `run_start`).
    private(set) var pid: Int?
    private(set) var state: JobState
    private(set) var phase: JobPhase = .starting

    // From job_start (or the job status the monitor was created from).
    private(set) var title: String?
    private(set) var author: String?
    private(set) var engineName: String?
    private(set) var voice: String?
    private(set) var lang: String?
    /// The run's `job_start` event: planned sections, totals, saved-rate estimate, warnings.
    private(set) var plan: EngineEvent?

    /// Latest `section_start` (current chapter).
    private(set) var currentSection: EngineEvent?
    /// Latest `progress` event.
    private(set) var latestProgress: EngineEvent?
    /// Speed over time for the chart (decimated to at most `maxRatePoints`).
    private(set) var rateHistory: [RatePoint] = []
    private(set) var flaggedChunks: [FlaggedChunk] = []
    /// `qa_redo` events (chunks re-generated after a failed speech check).
    private(set) var qaRedos: [EngineEvent] = []
    /// Latest speech-check counters.
    private(set) var qa: QAStats?
    /// `notice` messages (info banners).
    private(set) var notices: [String] = []
    private(set) var encodingPercent: Double?
    /// The `done` event.
    private(set) var result: EngineEvent?
    /// Failure message (engine wording) for failed or interrupted jobs.
    private(set) var errorMessage: String?
    /// Engine stderr tail for the error disclosure (failed / interrupted jobs).
    private(set) var stderrTail: String?
    /// The `cancelled` event's message.
    private(set) var cancelMessage: String?
    /// `t` of the latest event (seconds since the run started).
    private(set) var lastEventTime: Double?
    /// "Keeping your Mac awake" indicator.
    private(set) var isKeepingAwake = false

    /// Read when a live job ends; AppModel points it at the Notifications setting.
    @ObservationIgnored var notificationsAllowed: () -> Bool = { true }
    /// Called once when a live job ends (AppModel refreshes the job list and measured speeds).
    @ObservationIgnored var onFinish: ((JobMonitor) -> Void)?

    static let maxRatePoints = 1000

    @ObservationIgnored private let initialState: JobState
    @ObservationIgnored private let client: EngineClient?
    @ObservationIgnored private let options: Options
    @ObservationIgnored private var tailTask: Task<Void, Never>?
    @ObservationIgnored private var livenessTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var nextRatePointId = 0

    init(jobId: String, jobDir: URL, eventsURL: URL? = nil, pid: Int?, initialState: JobState,
         title: String? = nil, author: String? = nil, engine: String? = nil, voice: String? = nil, lang: String? = nil,
         client: EngineClient?, options: Options = Options()) {
        self.id = jobId
        self.jobDir = jobDir
        self.eventsURL = eventsURL ?? jobDir.appendingPathComponent("events.jsonl")
        self.pid = pid
        self.initialState = initialState
        self.state = initialState
        self.isLive = initialState.isActive
        self.title = title
        self.author = author
        self.engineName = engine
        self.voice = voice
        self.lang = lang
        self.client = client
        self.options = options
    }

    /// A monitor for a job from `jobs list` / `jobs status` (live if it is queued or running).
    convenience init(status: JobStatus, client: EngineClient?, options: Options = Options()) {
        self.init(jobId: status.jobId, jobDir: URL(fileURLWithPath: status.jobDir), pid: status.pid,
                  initialState: status.jobState, title: status.title, author: status.author,
                  engine: status.engine, voice: status.voice, lang: status.lang, client: client, options: options)
        latestProgress = status.lastProgress
        result = status.result
        errorMessage = status.error ?? status.lastError?.message
        stderrTail = status.stderrTail?.text
    }

    // MARK: Display helpers

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Untitled book"
    }

    /// Percent of characters synthesized (0...100); 100 once an audiobook was produced.
    var percent: Double {
        if state.producedOutput { return 100 }
        return latestProgress?.percent ?? 0
    }

    var fraction: Double { min(1, max(0, percent / 100)) }

    /// "about 23 min (20–27)" / "calibrating…" while narrating; nil otherwise (once narration ends no new
    /// progress arrives, so the last estimate would stay on screen through assembling and encoding).
    var etaText: String? {
        guard state.isActive, case .synthesizing = phase, let p = latestProgress else { return nil }
        return Formatters.eta(p)
    }

    /// "Chapter 12 of 38 — “XII”" (the engine's `n` is zero-based).
    var chapterText: String? {
        guard let s = currentSection, let n = s.n, let of = s.of else { return nil }
        let name = s.title.map { " — “\($0)”" } ?? ""
        return "Chapter \(n + 1) of \(of)\(name)"
    }

    /// "Chunk 8 of 58".
    var chunkText: String? {
        guard let p = latestProgress, let c = p.chunk, let total = p.chunks else { return nil }
        return "Chunk \(c) of \(total)"
    }

    /// Seconds since the run started.
    var elapsedSeconds: Double? { result?.wallS ?? latestProgress?.elapsedS ?? lastEventTime }

    var flaggedCount: Int { max(flaggedChunks.count, result?.flaggedChunks ?? 0) }

    var outputURL: URL? { result?.output.map { URL(fileURLWithPath: $0) } }

    /// Status line for lists: phase while active, state otherwise.
    var statusText: String { state.isActive ? phase.title : state.title }

    // MARK: Lifecycle

    /// Starts following (live) or replaying (finished) the job. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        if isLive {
            beginKeepAwake()
            follow(from: pid.map { .run(pid: $0) } ?? .latestRun)
            startLivenessChecks()
        } else {
            let url = eventsURL
            tailTask = Task { [weak self] in
                let events = await Task.detached { EventTailer.readLatestRun(at: url) }.value
                self?.replay(events)
            }
        }
    }

    /// Stops following without changing the state (the job itself keeps running).
    func stop() {
        tailTask?.cancel()
        tailTask = nil
        livenessTask?.cancel()
        livenessTask = nil
        endKeepAwake()
    }

    /// Applies one engine event. Exposed for tests and previews; normally fed by the tailer.
    func apply(_ ev: EngineEvent) {
        if let t = ev.t { lastEventTime = t }
        switch ev.event {
        case "run_start":
            resetRun()
            if let p = ev.pid { pid = p }
            state = .queued
            phase = .starting
        case "job_start":
            plan = ev
            title = ev.title ?? title
            author = ev.author ?? author
            engineName = ev.engineName ?? ev.engine ?? engineName
            voice = ev.voice ?? voice
            lang = ev.lang ?? lang
            state = .running
            // The engine writes job_start once it holds the GPU: the wait (`queued`) is over.
            if case .waitingForGPU = phase { phase = .starting }
        case "queued":
            state = .queued
            phase = .waitingForGPU(ev.message ?? "Waiting for the GPU…")
        case "model_loading":
            state = .running
            phase = .loadingModel
        case "model_loaded":
            state = .running
            phase = .synthesizing
        case "section_start":
            currentSection = ev
            state = .running
            if phase != .loadingModel { phase = .synthesizing }
        case "progress":
            latestProgress = ev
            if let q = ev.qa { qa = q }
            state = .running
            phase = .synthesizing
            appendRatePoint(ev)
        case "chunk_flagged":
            flaggedChunks.append(FlaggedChunk(section: ev.section ?? 0, chunk: ev.chunk ?? 0,
                                              issues: ev.issues ?? [], text: ev.text ?? ""))
        case "qa_redo":
            qaRedos.append(ev)
        case "notice":
            if let m = ev.message { notices.append(m) }
        case "assembling":
            phase = .assembling
        case "encoding":
            encodingPercent = ev.percent
            phase = .encoding(percent: ev.percent ?? 0)
        case "done":
            result = ev
            if let q = ev.qa { qa = q }
            state = (ev.verificationProblems ?? []).isEmpty ? .done : .doneWithProblems
            phase = .finished
            finish()
        case "cancelled":
            cancelMessage = ev.message
            state = .cancelled
            phase = .finished
            finish()
        case "error":
            errorMessage = ev.message ?? "The conversion failed."
            state = .failed
            phase = .finished
            finish()
        default:
            break   // qa_model_loaded, section_skip, model events of newer engines...
        }
    }

    // MARK: Private

    private func follow(from start: EventTailer.StartPoint) {
        tailTask?.cancel()
        let stream = EventTailer(url: eventsURL, pollInterval: options.pollInterval).events(from: start)
        tailTask = Task { [weak self] in
            for await ev in stream {
                guard let self else { return }
                self.apply(ev)
            }
        }
    }

    private func replay(_ events: [EngineEvent]) {
        for ev in events { apply(ev) }
        if !finished {
            // No terminal event in the file (e.g. the process was killed): trust the engine's job state.
            state = initialState
            phase = .finished
            if initialState == .interrupted, errorMessage == nil {
                errorMessage = JobMonitor.interruptedMessage
            }
            finished = true
        }
    }

    /// A clean slate for a new run (only matters when a file is read from the beginning).
    private func resetRun() {
        plan = nil
        currentSection = nil
        latestProgress = nil
        rateHistory = []
        flaggedChunks = []
        qaRedos = []
        qa = nil
        notices = []
        encodingPercent = nil
        result = nil
        errorMessage = nil
        cancelMessage = nil
    }

    private func appendRatePoint(_ ev: EngineEvent) {
        guard let rate = ev.rateCps else { return }
        rateHistory.append(RatePoint(id: nextRatePointId, elapsed: ev.elapsedS ?? ev.t ?? 0, rateCps: rate,
                                     runRateCps: ev.runRateCps, realtimeX: ev.realtimeX, percent: ev.percent))
        nextRatePointId += 1
        if rateHistory.count > JobMonitor.maxRatePoints {
            // Keep the chart light on very long books: drop every other point.
            rateHistory = rateHistory.enumerated().filter { $0.offset % 2 == 0 || $0.offset == rateHistory.count - 1 }.map(\.element)
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        livenessTask?.cancel()
        livenessTask = nil
        endKeepAwake()
        if (state == .failed || state == .interrupted), stderrTail == nil { fetchStderrTail() }
        if isLive {
            postNotification()
            onFinish?(self)
        }
    }

    private func fetchStderrTail() {
        guard let client else { return }
        let id = jobId
        Task { [weak self] in
            guard let status = try? await client.json(["jobs", "status", id], as: JobStatus.self) else { return }
            self?.stderrTail = status.stderrTail?.text
        }
    }

    private func startLivenessChecks() {
        guard let interval = options.livenessInterval, client != nil else { return }
        livenessTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !self.finished else { return }
                guard let pid = self.pid else { continue }
                if JobMonitor.isProcessAlive(pid) {
                    misses = 0
                    continue
                }
                misses += 1
                // Two misses in a row: the last events had time to be written and read.
                if misses >= 2 {
                    misses = 0
                    await self.reconcileWithEngine()
                }
            }
        }
    }

    /// The process is gone without a terminal event in the file: ask the engine what happened.
    private func reconcileWithEngine() async {
        guard let client, !finished else { return }
        do {
            let status = try await client.json(["jobs", "status", jobId], as: JobStatus.self)
            guard !finished else { return }
            if status.isActive {
                // A newer run of the same job (another process) is running: follow it instead.
                if let newPid = status.pid, newPid != pid {
                    pid = newPid
                    follow(from: .run(pid: newPid))
                }
                return
            }
            stderrTail = status.stderrTail?.text ?? stderrTail
            if let done = status.result {
                apply(done)
            } else if let error = status.lastError {
                apply(error)
            } else {
                end(state: status.jobState, message: status.error)
            }
        } catch {
            guard !finished else { return }
            end(state: .interrupted, message: nil)
        }
    }

    private func end(state: JobState, message: String?) {
        self.state = state
        if state == .interrupted {
            errorMessage = message ?? JobMonitor.interruptedMessage
        } else if let message {
            errorMessage = message
        }
        phase = .finished
        finish()
    }

    static let interruptedMessage =
        "The conversion stopped unexpectedly. Convert again with the same settings to resume; finished parts are reused."

    nonisolated static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    private func beginKeepAwake() {
        guard options.keepAwake, activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Converting an audiobook")
        isKeepingAwake = true
    }

    private func endKeepAwake() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isKeepingAwake = false
    }

    private func postNotification() {
        guard options.notifications, notificationsAllowed() else { return }
        let name = displayTitle
        let identifier = "job-\(jobId)"
        switch state {
        case .done, .doneWithProblems:
            var body = "“\(name)” is ready"
            if let d = result?.durationS { body += " (\(Formatters.duration(d)))" }
            body += "."
            if state == .doneWithProblems { body += " The final check found problems; open the job for details." }
            Notifications.post(title: "Audiobook ready", body: body, identifier: identifier)
        case .failed:
            Notifications.post(title: "Conversion failed",
                               body: "“\(name)”: \(errorMessage ?? "The engine reported an error.")",
                               identifier: identifier)
        case .interrupted:
            Notifications.post(title: "Conversion stopped",
                               body: "“\(name)” stopped unexpectedly. Convert again to resume.",
                               identifier: identifier)
        default:
            break   // cancelled by the user: no notification
        }
    }
}
