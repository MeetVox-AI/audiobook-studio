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
    /// Other languages this voice can speak, with an accent (absent on older engines).
    var also: [String]?

    /// Languages the voice speaks natively or with an accent.
    func speaks(_ language: String) -> Bool { lang == language || (also ?? []).contains(language) }
    /// True when `language` is one of the voice's secondary languages.
    func speaksWithAccent(_ language: String) -> Bool { lang != language && (also ?? []).contains(language) }
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
    /// Clean-up applied to a user clip (`voices add --isolate --enhance`).
    var isolate: Bool?
    var enhance: Bool?
    /// The kept start of the user's recording (file name in voices/originals), and the name of the file it came
    /// from. Voices added before this existed have neither: changing their recording needs a new file.
    var original: String?
    var originalName: String?

    /// Clips the user added with `voices add` (ids start with "user-").
    var isUserClip: Bool { id.hasPrefix("user-") }
    var isInstalled: Bool { installed ?? false }
    /// The engine kept the start of the recording, so it can be processed again without choosing a file.
    var hasOriginal: Bool { !(original ?? "").isEmpty }
}

struct VoiceList: Codable, Sendable { var voices: [VoiceEntry] }

// MARK: - languages

/// One engine row of `languages list` for a language.
struct LanguageEngine: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var installed: Bool
    var downloadGb: Double?
    var noncommercial: Bool?
    var nativePresets: Bool?
    var cloning: Bool?

    init(id: String, name: String, installed: Bool, downloadGb: Double? = nil, noncommercial: Bool? = nil,
         nativePresets: Bool? = nil, cloning: Bool? = nil) {
        self.id = id
        self.name = name
        self.installed = installed
        self.downloadGb = downloadGb
        self.noncommercial = noncommercial
        self.nativePresets = nativePresets
        self.cloning = cloning
    }

    /// "Voxtral TTS 4B (2.5 GB, non-commercial)".
    var needText: String {
        var details: [String] = []
        if let gb = downloadGb { details.append(Formatters.gigabytes(gb)) }
        if noncommercial == true { details.append("non-commercial") }
        return details.isEmpty ? name : "\(name) (\(details.joined(separator: ", ")))"
    }
}

/// The reference voices of a language (`languages list` → `voices`).
struct LanguageVoices: Codable, Hashable, Sendable {
    var available: Int
    var installed: Int
    var bytes: Int64
    var downloadMb: Double

    static let none = LanguageVoices(available: 0, installed: 0, bytes: 0, downloadMb: 0)

    init(available: Int = 0, installed: Int = 0, bytes: Int64 = 0, downloadMb: Double = 0) {
        self.available = available
        self.installed = installed
        self.bytes = bytes
        self.downloadMb = downloadMb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decodeIfPresent(Int.self, forKey: .available) ?? 0
        installed = try c.decodeIfPresent(Int.self, forKey: .installed) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        downloadMb = try c.decodeIfPresent(Double.self, forKey: .downloadMb) ?? 0
    }
}

/// One language of the engine's registry (`languages list`).
struct LanguageInfo: Codable, Hashable, Identifiable, Sendable {
    var code: String
    /// English name ("Spanish").
    var name: String
    /// Name in the language itself ("Español").
    var native: String
    var rtl: Bool
    var enabled: Bool
    /// An installed engine can speak the language.
    var ready: Bool
    /// Engine id to install when the language is not ready.
    var recommended: String?
    var engines: [LanguageEngine]
    var voices: LanguageVoices
    var id: String { code }

    init(code: String, name: String? = nil, native: String? = nil, rtl: Bool? = nil, enabled: Bool = false,
         ready: Bool = true, recommended: String? = nil, engines: [LanguageEngine] = [], voices: LanguageVoices = .none) {
        let builtin = LanguageRegistry.builtin[code]
        self.code = code
        self.name = name ?? builtin?.name ?? code
        self.native = native ?? builtin?.native ?? name ?? code
        self.rtl = rtl ?? builtin?.rtl ?? false
        self.enabled = enabled
        self.ready = ready
        self.recommended = recommended
        self.engines = engines
        self.voices = voices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        self.init(code: code,
                  name: try c.decodeIfPresent(String.self, forKey: .name),
                  native: try c.decodeIfPresent(String.self, forKey: .native),
                  rtl: try c.decodeIfPresent(Bool.self, forKey: .rtl),
                  enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  ready: try c.decodeIfPresent(Bool.self, forKey: .ready) ?? true,
                  recommended: try c.decodeIfPresent(String.self, forKey: .recommended),
                  engines: try c.decodeIfPresent([LanguageEngine].self, forKey: .engines) ?? [],
                  voices: try c.decodeIfPresent(LanguageVoices.self, forKey: .voices) ?? .none)
    }

    /// The engine to install for a language that is not ready: the recommended one, else the smallest download.
    var engineToInstall: LanguageEngine? {
        if let recommended, let e = engines.first(where: { $0.id == recommended }) { return e }
        return engines.min { ($0.downloadGb ?? .infinity) < ($1.downloadGb ?? .infinity) }
    }

    /// "Needs Voxtral TTS 4B (2.5 GB, non-commercial)"; nil when the language is ready.
    var needText: String? {
        guard !ready else { return nil }
        guard let engine = engineToInstall else { return "Needs a voice engine that speaks \(name)" }
        return "Needs \(engine.needText)"
    }
}

struct LanguageList: Codable, Sendable { var languages: [LanguageInfo] }

/// A reference voice the engine could not download while adding a language.
struct LanguageVoiceError: Codable, Hashable, Sendable {
    var id: String?
    var error: String?
}

/// A voice `languages remove` kept, and why (it narrates a running job, ...).
struct LanguageKeptVoice: Codable, Hashable, Sendable {
    var id: String?
    var reason: String?
}

/// The `language_done` event of `languages add` / `languages remove`.
struct LanguageChangeResult: Hashable, Sendable {
    var code: String
    var enabled: Bool
    var ready: Bool
    /// Engine id to install before the language can be narrated.
    var needs: String?
    var voiceErrors: [LanguageVoiceError] = []
    var voicesInstalled: Int = 0
    var removedVoices: [String] = []
    var keptVoices: [LanguageKeptVoice] = []

    init(code: String, event: EngineEvent?, enabledDefault: Bool) {
        self.code = code
        enabled = event?.enabled ?? enabledDefault
        ready = event?.ready ?? true
        needs = event?.needs
        voiceErrors = event?.voiceErrors ?? []
        voicesInstalled = event?.voicesInstalled ?? 0
        removedVoices = event?.removedVoices ?? []
        keptVoices = event?.keptVoices ?? []
    }
}

/// The 13 languages the app knows, for names before (or without) the engine's own list.
enum LanguageRegistry {
    struct Entry: Hashable, Sendable { var name: String; var native: String; var rtl: Bool }

    /// Registry order. Only English is on by default; every other language is added on demand.
    static let codes = ["en", "fr", "es", "de", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar", "nl"]
    static let defaultEnabled = ["en"]

    static let builtin: [String: Entry] = [
        "en": Entry(name: "English", native: "English", rtl: false),
        "fr": Entry(name: "French", native: "Français", rtl: false),
        "es": Entry(name: "Spanish", native: "Español", rtl: false),
        "de": Entry(name: "German", native: "Deutsch", rtl: false),
        "it": Entry(name: "Italian", native: "Italiano", rtl: false),
        "pt": Entry(name: "Portuguese", native: "Português", rtl: false),
        "ru": Entry(name: "Russian", native: "Русский", rtl: false),
        "zh": Entry(name: "Chinese", native: "中文", rtl: false),
        "ja": Entry(name: "Japanese", native: "日本語", rtl: false),
        "ko": Entry(name: "Korean", native: "한국어", rtl: false),
        "hi": Entry(name: "Hindi", native: "हिन्दी", rtl: false),
        "ar": Entry(name: "Arabic", native: "العربية", rtl: true),
        "nl": Entry(name: "Dutch", native: "Nederlands", rtl: false),
    ]

    /// Names the engine reported (English name by code); consulted by `Formatters.languageName`.
    private static let reported = NameStore()

    static func setReported(_ names: [String: String]) { reported.set(names) }
    static func reportedName(_ code: String) -> String? { reported.get(code) }

    private final class NameStore: @unchecked Sendable {
        private var names: [String: String] = [:]
        private let lock = NSLock()
        func set(_ new: [String: String]) { lock.lock(); names = new; lock.unlock() }
        func get(_ code: String) -> String? { lock.lock(); defer { lock.unlock() }; return names[code] }
    }
}

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
    // languages add / remove (`language_voice`, `language_done`)
    var code: String?
    var id: String?
    var name: String?
    var enabled: Bool?
    var ready: Bool?
    var needs: String?
    var voicesInstalled: Int?
    var voiceErrors: [LanguageVoiceError]?
    var removedVoices: [String]?
    var keptVoices: [LanguageKeptVoice]?

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
