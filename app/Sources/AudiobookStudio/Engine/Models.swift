import Foundation

// Codable mirrors of the engine's JSON output (snake_case keys are converted automatically).
// Every field the engine may omit is optional, so newer engines with extra fields still decode.
// Source of truth: the real engine outputs in Tests/AudiobookStudioTests/Fixtures (each one is decoded by a test).

// MARK: - Shared helpers

/// A JSON value that may be either a string or an array of strings.
/// The engine sends `stderr_tail` (job status) as a list of lines; older builds sent one string.
struct TextLines: Codable, Hashable, Sendable {
    var lines: [String]
    var text: String { lines.joined(separator: "\n") }

    init(_ lines: [String]) { self.lines = lines }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        } else {
            lines = try c.decode([String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(lines)
    }
}

/// Speech-check (Whisper) counters, on `progress.qa`, `done.qa` and `sample_done.qa`.
struct QAStats: Codable, Hashable, Sendable {
    var checked: Int?
    var redone: Int?
    var flagged: Int?
}

// MARK: - inspect

struct CoverInfo: Codable, Hashable, Sendable {
    var mediaType: String?
    var bytes: Int?
    var source: String?
    var writtenTo: String?
}

/// The kind of a book section, as classified by the engine.
enum SectionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case chapter, front, back

    /// Badge text shown in the section list.
    var title: String {
        switch self {
        case .chapter: return "Chapter"
        case .front: return "Front"
        case .back: return "Back"
        }
    }
}

struct SectionInfo: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var title: String
    var kind: String            // chapter | front | back
    var include: Bool           // the engine's default selection
    var chars: Int
    var estSeconds: Double
    var paragraphs: Int?
    var firstWords: String?
    var reasons: [String]?      // why the engine unticked it, e.g. "Project Gutenberg license text"
    var text: [String]?         // full paragraphs, only with `inspect --paragraphs`
    var id: Int { index }

    /// Typed kind; unknown kinds are treated as chapters.
    var sectionKind: SectionKind { SectionKind(rawValue: kind) ?? .chapter }
}

struct BookMetadata: Codable, Hashable, Sendable {
    var publisher: String?
    var date: String?
    var description: String?
    var identifier: String?
    var tocEntries: Int?
}

struct BookInfo: Codable, Hashable, Sendable {
    var sourcePath: String
    var format: String
    var title: String
    var author: String
    var language: String
    var languageSource: String?     // metadata | detected | default
    var cover: CoverInfo?
    var sections: [SectionInfo]
    var includedChars: Int?
    var includedEstSeconds: Double?
    var warnings: [String]?
    var metadata: BookMetadata?
}

// MARK: - engines

struct PresetVoice: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var lang: String
    var gender: String?
    var accent: String?
    var note: String?
}

struct EngineInfo: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var checkpoint: String?
    var languages: [String]
    var license: String
    var noncommercial: Bool
    var batchSize: Int?
    var supportsPresets: Bool
    var supportsCloning: Bool
    var supportsSpeed: Bool?
    var downloadGb: Double?
    var notes: String?
    var voices: [PresetVoice]
}

struct SpeedMeasurement: Codable, Hashable, Sendable {
    var charsPerS: Double
    var realtimeX: Double?
    var secondsPerChar: Double?
    var chars: Int?
    var source: String?         // sample | convert | benchmark
    var updated: String?
}

/// One row of the "measured on this Mac" table (`engines.measured`).
struct MeasuredRate: Hashable, Identifiable, Sendable {
    var engine: String
    var voice: String
    var measurement: SpeedMeasurement
    var id: String { "\(engine)|\(voice)" }
}

struct EngineList: Codable, Sendable {
    var engines: [EngineInfo]
    var measured: [String: SpeedMeasurement]   // key: "<engine>|<voice>"

    /// Best known characters/second for an engine, preferring the exact voice; otherwise the median of the
    /// engine's measured voices (the mean of the two middle ones for an even count), the same number as the
    /// engine's own `saved_rate` (Python `statistics.median`) behind `saved_rate_cps` / `est_wall_s`.
    func rate(engine: String, voice: String?) -> Double? {
        if let v = voice, let m = measured["\(engine)|\(v)"] { return m.charsPerS }
        let rates = measured.filter { $0.key.hasPrefix(engine + "|") }.map(\.value.charsPerS).sorted()
        guard !rates.isEmpty else { return nil }
        let mid = rates.count / 2
        return rates.count % 2 == 1 ? rates[mid] : (rates[mid - 1] + rates[mid]) / 2
    }

    /// The measurement behind `rate(engine:voice:)`: the exact voice when measured (exactVoice = true),
    /// otherwise the middle measurement of that engine's other voices (a real row, for its source, date and
    /// real-time factor; with an even count its speed is one of the two speeds `rate` averages).
    func measurement(engine: String, voice: String?) -> (measurement: SpeedMeasurement, exactVoice: Bool)? {
        if let v = voice, let m = measured["\(engine)|\(v)"] { return (m, true) }
        let all = measured.filter { $0.key.hasPrefix(engine + "|") }.map(\.value).sorted { $0.charsPerS < $1.charsPerS }
        guard !all.isEmpty else { return nil }
        return (all[all.count / 2], false)
    }

    /// Every measurement, most recently updated first.
    var measuredRates: [MeasuredRate] {
        measured.map { key, m in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return MeasuredRate(engine: parts.first ?? key, voice: parts.count > 1 ? parts[1] : "", measurement: m)
        }
        .sorted { ($0.measurement.updated ?? "", $0.id) > ($1.measurement.updated ?? "", $1.id) }
    }

    func engine(_ id: String) -> EngineInfo? { engines.first { $0.id == id } }
}

// MARK: - models

struct ModelPart: Codable, Hashable, Sendable {
    var repo: String
    var purpose: String?
    var installed: Bool
    var bytes: Int?
    var path: String?
}

struct ModelStatus: Codable, Hashable, Identifiable, Sendable {
    var engine: String
    var name: String
    var installed: Bool
    var downloadGb: Double?
    var license: String?
    var noncommercial: Bool?
    var parts: [ModelPart]
    var id: String { engine }

    /// Bytes on disk of the installed parts.
    var installedBytes: Int64 { parts.filter(\.installed).reduce(0) { $0 + Int64($1.bytes ?? 0) } }
}

struct ModelList: Codable, Sendable { var models: [ModelStatus] }

// MARK: - voices

struct VoiceEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var lang: String
    var gender: String?
    var description: String?
    var license: String?
    var commercialOk: Bool?
    var attribution: String?
    var sourcePage: String?
    var audioUrl: String?
    var installed: Bool?
    var transcript: String?
    var transcriptSource: String?   // published | whisper | user
    var durationS: Double?
    var sampleRate: Int?
    var sha256: String?
    var path: String?

    /// Clips the user added with `voices add` (ids start with "user-").
    var isUserClip: Bool { id.hasPrefix("user-") }
    var isInstalled: Bool { installed ?? false }
}

struct VoiceList: Codable, Sendable { var voices: [VoiceEntry] }

// MARK: - events

/// A planned section in `job_start.sections` (index -1 is the spoken "Title. By Author." intro).
struct PlannedSection: Codable, Hashable, Identifiable, Sendable {
    var index: Int
    var title: String
    var chars: Int?
    var chunks: Int?
    var id: Int { index }
}

/// One engine event (job progress, sample results, errors...). Flat on purpose: the engine adds fields over time.
struct EngineEvent: Codable, Hashable, Sendable {
    var event: String?
    var t: Double?
    var message: String?
    // identity
    var jobId: String?
    var jobDir: String?
    var pid: Int?
    var events: String?
    // job_start
    var title: String?
    var author: String?
    var lang: String?
    var engine: String?
    var engineName: String?
    var voice: String?
    var license: String?
    var noncommercial: Bool?
    var sections: [PlannedSection]?
    var totalChars: Int?
    var charsToSynthesize: Int?
    var cachedChars: Int?
    var estAudioS: Double?
    var savedRateCps: Double?
    var estWallS: Double?
    var warnings: [String]?
    // model
    var checkpoint: String?
    var loadS: Double?
    var warmupS: Double?
    var sampleRate: Int?
    // sections / progress
    var section: Int?
    var n: Int?
    var of: Int?
    var chunk: Int?
    var chunks: Int?
    var chars: Int?
    var charsDone: Int?
    var percent: Double?
    var rateCps: Double?
    var runRateCps: Double?
    var realtimeX: Double?
    var etaS: Double?
    var etaLowS: Double?
    var etaHighS: Double?
    var etaBasis: String?       // measured | saved | calibrating
    var elapsedS: Double?
    var reason: String?
    var qa: QAStats?
    // flagged chunk / speech-check redo
    var issues: [String]?
    var text: String?
    var beforeCer: Double?
    var afterCer: Double?
    var fixed: Bool?
    // encoding / done
    var output: String?
    var encoder: String?
    var durationS: Double?
    var chapters: Int?
    var wallS: Double?
    var synthChars: Int?
    var synthWallS: Double?
    var flaggedChunks: Int?
    var verificationProblems: [String]?
    var sizeMb: Double?
    var freedWorkMb: Double?
    // sample
    var audioS: Double?
    var charsSynthesized: Int?
    var bookChars: Int?
    var bookEstAudioS: Double?
    var bookEstWallS: Double?
    var note: String?
    // benchmark
    var batch: Int?
    var charsPerS: Double?
    var secondsPerChar: Double?
    var peakMemoryGb: Double?
    var runs: [Double]?
    // downloads
    var repo: String?
    var purpose: String?
    var installed: Bool?
    // cache clear
    var freedBytes: Int64?

    /// done, error and cancelled end a run.
    var isTerminal: Bool { event.map(EventTailer.terminal.contains) ?? false }
}

// MARK: - jobs

/// Job states written by the engine in job.json (plus "unknown" for anything newer).
enum JobState: Hashable, Sendable {
    case queued, running, done, doneWithProblems, failed, cancelled, interrupted
    case unknown(String)

    init(engineValue: String) {
        switch engineValue {
        case "queued": self = .queued
        case "running": self = .running
        case "done": self = .done
        case "done_with_problems": self = .doneWithProblems
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        default: self = .unknown(engineValue)
        }
    }

    var engineValue: String {
        switch self {
        case .queued: return "queued"
        case .running: return "running"
        case .done: return "done"
        case .doneWithProblems: return "done_with_problems"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .interrupted: return "interrupted"
        case .unknown(let s): return s
        }
    }

    /// Short user-facing state name.
    var title: String {
        switch self {
        case .queued: return "Waiting"
        case .running: return "Converting"
        case .done: return "Done"
        case .doneWithProblems: return "Done with problems"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .unknown: return "Unknown"
        }
    }

    /// SF Symbol for lists and badges.
    var systemImage: String {
        switch self {
        case .queued: return "hourglass"
        case .running: return "waveform"
        case .done: return "checkmark.circle"
        case .doneWithProblems: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "stop.circle"
        case .interrupted: return "pause.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// A process is (or should be) working on the job.
    var isActive: Bool { self == .queued || self == .running }
    /// An audiobook file was produced.
    var producedOutput: Bool { self == .done || self == .doneWithProblems }
    /// Running the same convert again continues where it stopped (finished chunks are cached).
    var canResume: Bool { self == .cancelled || self == .interrupted || self == .failed }
}

struct JobStatus: Codable, Hashable, Identifiable, Sendable {
    var jobId: String
    var book: String?
    var title: String?
    var author: String?
    var lang: String?
    var engine: String?
    var voice: String?
    var speed: Double?
    var state: String
    var pid: Int?
    var started: String?        // local time, "2026-10-09T18:28:42"
    var finished: String?
    var argv: [String]?         // engine arguments of the latest run, starting with "convert"
    var output: String?
    var outputs: [String]?
    var error: String?
    var jobDir: String
    var lastProgress: EngineEvent?
    var lastError: EngineEvent?
    var result: EngineEvent?
    var stderrTail: TextLines?  // failed / interrupted jobs only
    var id: String { jobId }

    var jobState: JobState { JobState(engineValue: state) }
    var isActive: Bool { jobState.isActive }
    var eventsURL: URL { URL(fileURLWithPath: jobDir).appendingPathComponent("events.jsonl") }
    var outputURL: URL? { output.map { URL(fileURLWithPath: $0) } }
    /// The book file; nil when the engine recorded a relative path (a job started from the terminal as
    /// `convert book.epub`): the app runs the engine from another folder, so it cannot tell which file it was.
    var bookURL: URL? { hasRelativeBookPath ? nil : book.map { URL(fileURLWithPath: $0) } }
    /// The engine records the book path as it was typed (`job.json` book and argv).
    var hasRelativeBookPath: Bool { book.map { !$0.hasPrefix("/") } ?? false }
    var startedDate: Date? { JobStatus.parseLocalDate(started) }
    var finishedDate: Date? { JobStatus.parseLocalDate(finished) }

    /// The engine writes local wall-clock times without a time zone.
    static func parseLocalDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)
    }
}

struct JobList: Codable, Sendable { var jobs: [JobStatus] }

/// `convert --detach` output. `alreadyRunning` is set when the same job was already running.
struct DetachedJob: Codable, Hashable, Sendable {
    var event: String?
    var jobId: String
    var jobDir: String
    var pid: Int?
    var events: String
    var alreadyRunning: Bool?

    var eventsURL: URL { URL(fileURLWithPath: events) }
}

/// `jobs cancel <id>` output.
struct JobCancelResult: Codable, Hashable, Sendable {
    var cancelled: Bool
    var pid: Int?
    var stopped: Bool?
    var reason: String?
}

/// `cache info` output.
struct CacheInfo: Codable, Hashable, Sendable {
    var chunksBytes: Int64
    var jobsBytes: Int64
    var path: String

    var totalBytes: Int64 { chunksBytes + jobsBytes }
}

enum EngineJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
