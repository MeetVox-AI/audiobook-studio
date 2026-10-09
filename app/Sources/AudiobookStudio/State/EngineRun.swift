import Foundation

/// A sample made with `AppModel.startSample(...)`.
typealias SampleRun = EngineRun
/// A benchmark started with `AppModel.startBenchmark(...)`.
typealias BenchmarkRun = EngineRun

/// One streaming engine command the app waits for (a sample or a benchmark), observable from SwiftUI.
///
/// Lifecycle: `.starting` → (`.waiting` while another job holds the GPU) → `.loadingModel` → `.working`
/// → `.finished` (with `result`) | `.failed` (with `error`) | `.cancelled`.
@MainActor
@Observable
final class EngineRun: Identifiable {
    enum Kind: Sendable { case sample, benchmark }

    enum Phase: Equatable, Sendable {
        case starting
        case waiting(String)        // engine `queued{message}`, e.g. "A conversion is using the GPU; waiting."
        case loadingModel
        case working
        case finished
        case failed
        case cancelled
    }

    nonisolated let id: UUID
    let kind: Kind
    let voice: VoiceSelection
    let language: String
    /// Sample section index (nil: the engine's first chapter). Always nil for benchmarks.
    let section: Int?
    /// Where the sample audio is written (nil for benchmarks). Exists once `phase == .finished`.
    let outputURL: URL?
    /// The book a sample narrates (nil for benchmarks).
    let bookPath: String?
    let startedAt: Date

    private(set) var phase: Phase = .starting
    /// `model_loaded.load_s` + warm-up, when reported.
    private(set) var modelLoadSeconds: Double?
    /// `sample_done` or `benchmark` event.
    private(set) var result: EngineEvent?
    private(set) var error: EngineError?
    /// `notice` messages (info banners), e.g. "Speech check skipped: ...".
    private(set) var notices: [String] = []

    /// Called once when the run ends (finished, failed or cancelled).
    @ObservationIgnored var onFinish: ((EngineRun) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .starting, .waiting, .loadingModel, .working: return true
        case .finished, .failed, .cancelled: return false
        }
    }

    /// Short status line: "Waiting for the GPU…", "Loading the voice model…", "Narrating…".
    var statusText: String {
        switch phase {
        case .starting: return "Starting…"
        case .waiting(let message): return message
        case .loadingModel: return "Loading the voice model…"
        case .working: return kind == .sample ? "Narrating the sample…" : "Measuring speed…"
        case .finished: return kind == .sample ? "Sample ready" : "Benchmark finished"
        case .failed: return error?.message ?? "Failed"
        case .cancelled: return "Stopped"
        }
    }

    init(kind: Kind, voice: VoiceSelection, language: String, section: Int? = nil, outputURL: URL? = nil,
         bookPath: String? = nil) {
        self.id = UUID()
        self.kind = kind
        self.voice = voice
        self.language = language
        self.section = section
        self.outputURL = outputURL
        self.bookPath = bookPath
        self.startedAt = Date()
    }

    /// Runs `arguments` with `client` and follows its events. Called by AppModel.
    func start(client: EngineClient, arguments: [String]) {
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                for try await event in client.stream(arguments) {
                    self?.apply(event)
                }
                self?.endWithoutResultIfNeeded()
            } catch {
                self?.fail(error)
            }
        }
    }

    /// Stops the engine process (the stream's termination terminates it).
    func cancel() {
        guard isRunning else { return }
        task?.cancel()
        phase = .cancelled
        finish()
    }

    /// Applies one event. Internal so tests can drive a run without the engine.
    func apply(_ event: EngineEvent) {
        guard isRunning else { return }
        switch event.event {
        case "queued":
            phase = .waiting(event.message ?? "Waiting for the GPU…")
        case "model_loading":
            phase = .loadingModel
        case "model_loaded":
            modelLoadSeconds = (event.loadS ?? 0) + (event.warmupS ?? 0)
            phase = .working
        case "notice":
            if let m = event.message { notices.append(m) }
        case "sample_done", "benchmark":
            result = event
            phase = .finished
            finish()
        default:
            if phase == .starting { phase = .working }
        }
    }

    private func endWithoutResultIfNeeded() {
        guard isRunning else { return }
        error = EngineError(message: "The engine stopped without a result.")
        phase = .failed
        finish()
    }

    private func fail(_ error: Error) {
        guard isRunning else { return }
        if error is CancellationError {
            phase = .cancelled
        } else {
            self.error = EngineError(error)
            phase = .failed
        }
        finish()
    }

    private func finish() {
        let callback = onFinish
        onFinish = nil
        callback?(self)
    }
}
