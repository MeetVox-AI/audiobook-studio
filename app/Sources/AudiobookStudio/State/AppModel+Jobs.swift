import Foundation

// Lookups and display text for the Jobs, Job detail (progress / done), Models, Benchmark and Settings
// screens. Pure functions over AppModel data and engine events: no engine calls here (those stay in
// AppModel), and every number is something the engine reported, formatted with `Formatters`.

// MARK: - AppModel lookups

extension AppModel {
    /// The listed job with this id (nil when `jobs list` does not know it).
    func job(withId id: String) -> JobStatus? { jobs.first { $0.jobId == id } }

    /// Queued or running jobs (live state), newest first.
    var jobsInProgress: [JobStatus] { jobs.filter { liveState(of: $0).isActive } }

    /// Finished, failed, cancelled and interrupted jobs, newest first.
    var jobsFinished: [JobStatus] { jobs.filter { !liveState(of: $0).isActive } }

    /// "Qwen3-TTS 1.7B" for "qwen3" (engines, then models); the id itself when unknown.
    func opsEngineName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return engineList?.engine(id)?.name ?? models.first { $0.engine == id }?.name ?? id
    }

    /// "Ryan" for a preset, "SIWIS — studio narrator (F)" for an installed voice; the id when unknown.
    func opsVoiceName(engine: String?, voice: String?) -> String? {
        guard let voice, !voice.isEmpty else { return nil }
        if let engine, let preset = engineList?.engine(engine)?.voices.first(where: { $0.id == voice }) {
            return preset.name
        }
        if let entry = voices.first(where: { $0.id == voice }) { return entry.name }
        return voice
    }

    /// "Qwen3-TTS 1.7B · Ryan · English" (missing parts are left out).
    func opsNarration(engine: String?, voice: String?, language: String?) -> String {
        [opsEngineName(engine), opsVoiceName(engine: engine, voice: voice), language.map(Formatters.languageName)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Voices `engine` can narrate `language` with: its presets in that language, then (cloning engines)
    /// the installed voices in that language.
    func opsNarratorChoices(engine: EngineInfo, language: String) -> [OpsNarratorChoice] {
        guard engine.languages.contains(language) else { return [] }
        var choices: [OpsNarratorChoice] = []
        if engine.supportsPresets {
            for preset in engine.voices where preset.lang == language {
                choices.append(OpsNarratorChoice(selection: VoiceSelection(engineId: engine.id, presetId: preset.id),
                                                 voiceName: preset.name, engineName: engine.name,
                                                 noncommercial: engine.noncommercial))
            }
        }
        if engine.supportsCloning {
            for voice in voices where voice.lang == language && voice.isInstalled {
                choices.append(OpsNarratorChoice(selection: VoiceSelection(engineId: engine.id, refVoiceId: voice.id),
                                                 voiceName: voice.name, engineName: engine.name,
                                                 noncommercial: engine.noncommercial))
            }
        }
        return choices
    }

    /// Every engine's voices for `language`, in engine order.
    func opsNarratorChoices(language: String) -> [OpsNarratorChoice] {
        engines.flatMap { opsNarratorChoices(engine: $0, language: language) }
    }

    /// Languages that are on and that an engine speaks, in registry order (the enabled ones before engines are loaded).
    var opsLanguages: [String] {
        let all = Set(engines.flatMap(\.languages))
        guard !all.isEmpty else { return enabledLanguageCodes }
        return enabledLanguageCodes.filter(all.contains)
    }

    /// The engine's model is installed; nil when `models list` has no entry for it (not loaded yet).
    func opsModelInstalled(_ engineId: String) -> Bool? { models.first { $0.engine == engineId }?.installed }

    /// A queued or running job uses this model: the speech-check model ("whisper") counts as used by every job.
    func opsModelInUse(_ engineId: String) -> Bool {
        jobs.contains { job in
            liveState(of: job).isActive && (job.engine == engineId || engineId == OpsModelInfo.speechCheckModel)
        }
    }

    /// Speeds measured on this Mac (`engines.measured`) with display names, newest first.
    var opsMeasuredRows: [OpsMeasuredRow] {
        (engineList?.measuredRates ?? []).map { rate in
            OpsMeasuredRow(rate: rate,
                           engineName: opsEngineName(rate.engine) ?? rate.engine,
                           voiceName: opsVoiceName(engine: rate.engine, voice: rate.voice) ?? rate.voice)
        }
    }

    /// A valid engine / language / voice for the Benchmark form, keeping what is still valid in the
    /// current choice. Defaults: the current narrator's engine, else the first installed engine.
    /// nil before engines are loaded.
    func opsBenchmarkSelection(engineId: String?, language: String?, choiceId: String?) -> OpsBenchmarkSelection? {
        guard !engines.isEmpty else { return nil }
        let installed = { (e: EngineInfo) in self.opsModelInstalled(e.id) ?? true }
        let engine = engines.first { $0.id == engineId }
            ?? engines.first { $0.id == voiceSelection?.engineId }
            ?? engines.first(where: installed)
            ?? engines[0]
        let lang = language.flatMap { engine.languages.contains($0) ? $0 : nil }
            ?? (draft.map(\.language).flatMap { engine.languages.contains($0) ? $0 : nil })
            ?? engine.languages.first(where: isEnabled)
            ?? engine.languages.first
            ?? fallbackLanguage
        let choices = opsNarratorChoices(engine: engine, language: lang)
        let preferredId = choiceId ?? voiceSelection.map(OpsNarratorChoice.key)
        let choice = choices.first { $0.id == preferredId } ?? choices.first
        return OpsBenchmarkSelection(engine: engine, language: lang, choices: choices, choice: choice)
    }
}

// MARK: - Voices in pickers

/// One narrator a picker offers (Settings default voices, Benchmark).
struct OpsNarratorChoice: Identifiable, Hashable, Sendable {
    var selection: VoiceSelection
    var voiceName: String
    var engineName: String
    var noncommercial: Bool

    var id: String { OpsNarratorChoice.key(selection) }
    var isClone: Bool { selection.isClone }

    /// "Ryan · Qwen3-TTS 1.7B", "SIWIS — studio narrator (F) · Qwen3-TTS 1.7B (cloned)"
    /// (the same wording as `VoiceSelection.displayName`).
    var title: String { "\(voiceName) · \(engineName)" + (isClone ? " (cloned)" : "") }

    /// `title`, plus "— personal use only" for non-commercial engines.
    var pickerTitle: String { noncommercial ? "\(title) — personal use only" : title }

    /// Stable identity of a voice choice, ignoring speed and speech check: "qwen3|preset:ryan".
    static func key(_ selection: VoiceSelection) -> String {
        if let p = selection.presetId { return "\(selection.engineId)|preset:\(p)" }
        if let r = selection.refVoiceId { return "\(selection.engineId)|clone:\(r)" }
        return "\(selection.engineId)|default"
    }
}

/// The Benchmark form's current engine, language and voice.
struct OpsBenchmarkSelection: Hashable, Sendable {
    var engine: EngineInfo
    var language: String
    var choices: [OpsNarratorChoice]
    var choice: OpsNarratorChoice?
}

/// A row of the "Measured on this Mac" table.
struct OpsMeasuredRow: Identifiable, Hashable, Sendable {
    var id: String
    var engineId: String
    var engineName: String
    var voiceName: String
    var charsPerSecond: Double
    /// 0 when the engine did not report it (keeps the column sortable).
    var realtimeX: Double
    var chars: Int?
    /// "Benchmark", "Sample", "Conversion".
    var source: String
    var updated: Date?

    init(rate: MeasuredRate, engineName: String, voiceName: String) {
        id = rate.id
        engineId = rate.engine
        self.engineName = engineName
        self.voiceName = voiceName
        charsPerSecond = rate.measurement.charsPerS
        realtimeX = rate.measurement.realtimeX ?? 0
        chars = rate.measurement.chars
        source = OpsMeasuredRow.sourceTitle(rate.measurement.source)
        updated = JobStatus.parseLocalDate(rate.measurement.updated)
    }

    /// For sorting: unknown dates last.
    var updatedSortKey: Date { updated ?? .distantPast }

    var realtimeText: String { realtimeX > 0 ? Formatters.realtime(realtimeX) : "—" }
    var updatedText: String { updated.map { JobText.date($0) } ?? "—" }

    static func sourceTitle(_ source: String?) -> String {
        switch source {
        case "benchmark": return "Benchmark"
        case "sample": return "Sample"
        case "convert": return "Conversion"
        case let other?: return other.capitalized
        case nil: return "—"
        }
    }
}

// MARK: - Job text

/// Display text for job rows and the job screen.
enum JobText {
    /// "Today at 6:28 PM", "Yesterday at 9:05 AM", "Oct 9 at 6:28 PM", "Oct 9, 2025".
    static func date(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: "en_US")
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        let text: String
        if calendar.isDate(date, inSameDayAs: now) {
            text = "Today at \(date.formatted(time))"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            text = "Yesterday at \(date.formatted(time))"
        } else {
            var day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                text = "\(date.formatted(day)) at \(date.formatted(time))"
            } else {
                day = day.year()
                text = date.formatted(day)
            }
        }
        // ICU puts narrow no-break spaces before AM/PM; plain spaces read (and test) the same.
        return text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// One line under a job in the list: progress while active, the outcome otherwise.
    @MainActor
    static func listLine(job: JobStatus, monitor: JobMonitor?, state: JobState) -> String {
        if state.isActive {
            guard let monitor else {
                if state == .queued { return "Waiting to start" }
                if let p = job.lastProgress?.percent { return "\(Formatters.percent(p)) done" }
                return state.title
            }
            return progressLine(monitor: monitor)
        }
        return outcome(job: job, state: state, monitor: monitor)
    }

    /// "43% done · time left: about 23 min (20–27)" while narrating; the phase otherwise.
    @MainActor
    static func progressLine(monitor: JobMonitor) -> String {
        guard case .synthesizing = monitor.phase else { return monitor.phase.title }
        var line = "\(Formatters.percent(monitor.percent)) done"
        if let eta = monitor.etaText { line += " · time left: \(eta)" }
        return line
    }

    /// How a finished job ended: "17 min of audio · 8.4 MB", the failure message, "Cancelled at 43%".
    @MainActor
    static func outcome(job: JobStatus, state: JobState, monitor: JobMonitor?) -> String {
        let percent = monitor?.latestProgress?.percent ?? job.lastProgress?.percent
        let stoppedAt = percent.map { " at \(Formatters.percent($0))" } ?? ""
        switch state {
        case .done, .doneWithProblems:
            let result = monitor?.result ?? job.result
            var parts: [String] = []
            if let d = result?.durationS { parts.append("\(Formatters.duration(d)) of audio") }
            if let c = result?.chapters { parts.append(c == 1 ? "1 chapter" : "\(Formatters.count(c)) chapters") }
            if let mb = result?.sizeMb { parts.append(Formatters.megabytes(mb)) }
            if state == .doneWithProblems { parts.append("the final check found problems") }
            return parts.isEmpty ? state.title : parts.joined(separator: " · ")
        case .failed:
            return monitor?.errorMessage ?? job.error ?? job.lastError?.message ?? "The conversion failed."
        case .cancelled:
            return "Cancelled\(stoppedAt). Resume to continue where it stopped."
        case .interrupted:
            return "Stopped unexpectedly\(stoppedAt). Resume to continue where it stopped."
        case .queued:
            return "Waiting to start"
        case .running:
            return percent.map { "\(Formatters.percent($0)) done" } ?? state.title
        case .unknown(let value):
            return "State reported by the engine: \(value)"
        }
    }

    /// Where the ETA comes from (`progress.eta_basis`).
    static func etaBasis(_ basis: String?) -> String? {
        switch basis {
        case "measured": return "Based on the speed measured during this conversion."
        case "saved": return "Based on speeds saved from earlier runs on this Mac; refined as the conversion runs."
        case "calibrating": return "Measuring this Mac's speed; the estimate appears after the first chunks."
        default: return nil
        }
    }

    /// "99 sentences checked · 1 re-generated · 0 flagged" (speech check counters).
    static func qa(_ qa: QAStats?) -> String? {
        guard let qa else { return nil }
        var parts: [String] = []
        if let c = qa.checked { parts.append(c == 1 ? "1 sentence checked" : "\(Formatters.count(c)) sentences checked") }
        if let r = qa.redone { parts.append("\(Formatters.count(r)) re-generated") }
        if let f = qa.flagged { parts.append("\(Formatters.count(f)) flagged") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3 chunks were narrated again after the speech check; 2 now pass."
    static func redos(_ events: [EngineEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        let fixed = events.filter { $0.fixed == true }.count
        let lead = events.count == 1 ? "1 chunk was narrated again" : "\(Formatters.count(events.count)) chunks were narrated again"
        return "\(lead) after the speech check; " + (fixed == 1 ? "1 now passes." : "\(Formatters.count(fixed)) now pass.")
    }

    /// Where a flagged chunk is: "“I”, chunk 3" (chunk numbers in events are zero-based).
    static func flaggedLocation(_ chunk: FlaggedChunk, plan: EngineEvent?) -> String {
        let number = chunk.chunk + 1
        if let title = plan?.sections?.first(where: { $0.index == chunk.section })?.title, !title.isEmpty {
            return "“\(title)”, chunk \(number)"
        }
        return chunk.section < 0 ? "Introduction, chunk \(number)" : "Section \(chunk.section), chunk \(number)"
    }

    /// What the job will narrate (`job_start`): "17,815 characters · about 18 min of audio · 3 parts".
    static func planSummary(_ plan: EngineEvent) -> String? {
        var parts: [String] = []
        if let c = plan.totalChars { parts.append(Formatters.characters(c)) }
        if let a = plan.estAudioS { parts.append("about \(Formatters.duration(a)) of audio") }
        if let s = plan.sections?.count { parts.append(s == 1 ? "1 part" : "\(Formatters.count(s)) parts") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4,200 characters reused from an earlier run" when the cache already had some audio.
    static func reused(_ plan: EngineEvent) -> String? {
        guard let cached = plan.cachedChars, cached > 0 else { return nil }
        return "\(Formatters.characters(cached)) reused from an earlier run"
    }

    /// Heading of a job that stopped without an audiobook.
    static func stoppedTitle(_ state: JobState) -> String {
        switch state {
        case .failed: return "The conversion failed"
        case .cancelled: return "The conversion was cancelled"
        case .interrupted: return "The conversion stopped unexpectedly"
        default: return state.title
        }
    }

    /// Body text for cancelled jobs without an engine message.
    static let cancelledFallback = "You stopped this conversion. Finished chunks are kept, so you can resume it later."
}

/// Speed now compared with the run's average.
enum JobSpeedTrend: Hashable, Sendable {
    case faster, slower, steady

    /// More than 10% away from the average counts as faster / slower. nil without both numbers.
    static func compare(now: Double?, average: Double?) -> JobSpeedTrend? {
        guard let now, let average, average > 0 else { return nil }
        let ratio = now / average
        if ratio > 1.1 { return .faster }
        if ratio < 0.9 { return .slower }
        return .steady
    }

    var text: String {
        switch self {
        case .faster: return "faster than average"
        case .slower: return "slower than average"
        case .steady: return "steady"
        }
    }

    var systemImage: String {
        switch self {
        case .faster: return "arrow.up.right"
        case .slower: return "arrow.down.right"
        case .steady: return "arrow.right"
        }
    }
}

/// The elapsed clock between engine events: the engine reports elapsed time with each event; the
/// screen keeps counting real time from the moment that report arrived (capped, so a stalled job does
/// not count forever).
struct JobLiveElapsed: Hashable, Sendable {
    var reported: Double
    var receivedAt: Date
    /// Longest stretch counted past the last report.
    static let maxExtrapolation: Double = 300

    func seconds(at now: Date) -> Double {
        reported + min(JobLiveElapsed.maxExtrapolation, max(0, now.timeIntervalSince(receivedAt)))
    }
}

/// One line of the speed chart.
struct JobRateSample: Identifiable, Hashable, Sendable {
    var id: String
    /// Elapsed time in the chart's unit (minutes or seconds).
    var x: Double
    var charsPerSecond: Double
    var series: String
}

/// Points for the "speed over time" chart.
enum JobRateChart {
    static let nowSeries = "Speed now"
    static let averageSeries = "Average"

    /// Minutes once the run is at least 3 minutes long, seconds before.
    static func usesMinutes(_ points: [RatePoint]) -> Bool { (points.last?.elapsed ?? 0) >= 180 }

    /// The two series (speed now, average) as chart samples.
    static func samples(_ points: [RatePoint]) -> [JobRateSample] {
        let minutes = usesMinutes(points)
        let x = { (p: RatePoint) in minutes ? p.elapsed / 60 : p.elapsed }
        let now = points.map { JobRateSample(id: "n\($0.id)", x: x($0), charsPerSecond: $0.rateCps, series: nowSeries) }
        let average = points.compactMap { p in
            p.runRateCps.map { JobRateSample(id: "a\(p.id)", x: x(p), charsPerSecond: $0, series: averageSeries) }
        }
        return now + average
    }

    /// Spoken summary of the chart for VoiceOver.
    static func accessibilitySummary(_ points: [RatePoint]) -> String {
        guard let last = points.last else { return "No measurements yet" }
        let rates = points.map(\.rateCps)
        var text = "Latest \(Formatters.charsPerSecond(last.rateCps))"
        if let lo = rates.min(), let hi = rates.max() {
            text += ", ranging from \(Formatters.charsPerSecond(lo)) to \(Formatters.charsPerSecond(hi))"
        }
        return text
    }
}

/// One figure of a result summary (finished job, benchmark).
struct JobSummaryItem: Identifiable, Hashable, Sendable {
    var label: String
    var value: String
    var systemImage: String
    var id: String { label }
}

enum JobResultSummary {
    /// The `done` event as figures: audio length, chapters, size, conversion time, speed, flagged chunks.
    static func items(_ done: EngineEvent) -> [JobSummaryItem] {
        var items: [JobSummaryItem] = []
        if let d = done.durationS { items.append(.init(label: "Audio length", value: Formatters.duration(d), systemImage: "headphones")) }
        if let c = done.chapters { items.append(.init(label: "Chapters", value: Formatters.count(c), systemImage: "list.number")) }
        if let mb = done.sizeMb { items.append(.init(label: "File size", value: Formatters.megabytes(mb), systemImage: "doc")) }
        if let w = done.wallS { items.append(.init(label: "Conversion time", value: Formatters.duration(w), systemImage: "timer")) }
        if let x = done.realtimeX { items.append(.init(label: "Speed", value: Formatters.realtime(x), systemImage: "speedometer")) }
        if let f = done.flaggedChunks {
            items.append(.init(label: "Flagged chunks", value: Formatters.count(f),
                               systemImage: f > 0 ? "exclamationmark.bubble" : "checkmark.bubble"))
        }
        return items
    }

    /// "Freed 26.4 MB of temporary chapter files." (`done.freed_work_mb`).
    static func freedWork(_ done: EngineEvent) -> String? {
        guard let mb = done.freedWorkMb, mb > 0 else { return nil }
        return "Freed \(Formatters.megabytes(mb)) of temporary chapter files."
    }

    /// The `benchmark` event as figures.
    static func benchmarkItems(_ ev: EngineEvent) -> [JobSummaryItem] {
        var items: [JobSummaryItem] = []
        if let c = ev.charsPerS { items.append(.init(label: "Speed", value: Formatters.charsPerSecond(c), systemImage: "speedometer")) }
        if let x = ev.realtimeX { items.append(.init(label: "Real time", value: Formatters.realtime(x), systemImage: "hare")) }
        if let m = ev.peakMemoryGb { items.append(.init(label: "Peak memory", value: Formatters.gigabytes(m), systemImage: "memorychip")) }
        if let l = ev.loadS {
            let warm = ev.warmupS.map { " + \(Formatters.duration($0)) warm-up" } ?? ""
            items.append(.init(label: "Model loading", value: Formatters.duration(l) + warm, systemImage: "shippingbox"))
        }
        if let chars = ev.chars, let audio = ev.audioS {
            items.append(.init(label: "Passage", value: "\(Formatters.characters(chars)), \(Formatters.duration(audio)) of audio",
                               systemImage: "text.alignleft"))
        }
        if let b = ev.batch { items.append(.init(label: "Batch size", value: Formatters.count(b), systemImage: "square.stack")) }
        return items
    }
}

// MARK: - Models

/// Display text for one row of the Models screen.
struct OpsModelInfo: Hashable, Sendable {
    /// The speech-check model (not a narration engine).
    static let speechCheckModel = "whisper"
    /// Clean-up models for "Add My Voice" (DeepFilterNet3, MossFormer2-SE).
    static let voiceIsolationModel = "voice-isolation"
    static let voiceEnhancerModel = "voice-enhancer"
    static let cleanupModels = [voiceIsolationModel, voiceEnhancerModel]

    /// The Models screen's groups: narration engines (engine order), voice clean-up, then the speech check and
    /// anything else. Before the engine list is known, every model that is neither clean-up nor the speech check
    /// counts as narration.
    static func groups(_ models: [ModelStatus], engineIds: [String])
        -> (narration: [ModelStatus], cleanup: [ModelStatus], other: [ModelStatus]) {
        let cleanup = cleanupModels.compactMap { id in models.first { $0.engine == id } }
        let rest = models.filter { !cleanupModels.contains($0.engine) }
        guard !engineIds.isEmpty else {
            return (rest.filter { $0.engine != speechCheckModel }, cleanup, rest.filter { $0.engine == speechCheckModel })
        }
        let narration = rest.filter { engineIds.contains($0.engine) }
            .sorted { (engineIds.firstIndex(of: $0.engine) ?? 0) < (engineIds.firstIndex(of: $1.engine) ?? 0) }
        return (narration, cleanup, rest.filter { !engineIds.contains($0.engine) })
    }

    var status: ModelStatus

    var installedPartCount: Int { status.parts.filter(\.installed).count }
    /// Some files are there, but not all of them.
    var isPartial: Bool { !status.installed && installedPartCount > 0 }
    /// Something on disk that "Remove" would delete.
    var canRemove: Bool { status.installed || installedPartCount > 0 }

    /// "Installed", "Not installed", "Partly installed (1 of 2 parts)".
    var stateText: String {
        if status.installed { return "Installed" }
        if isPartial { return "Partly installed (\(installedPartCount) of \(status.parts.count) parts)" }
        return "Not installed"
    }

    var stateSystemImage: String {
        status.installed ? "checkmark.circle.fill" : (isPartial ? "circle.lefthalf.filled" : "arrow.down.circle")
    }

    /// Bytes still to download (the engine's `download_gb` minus what is installed).
    var remainingDownloadBytes: Int64? {
        guard !status.installed, let gb = status.downloadGb else { return nil }
        return max(0, Int64((gb * 1e9).rounded()) - status.installedBytes)
    }

    /// "6.2 GB on disk" when installed, "6.7 GB download" otherwise.
    var sizeText: String {
        if status.installed {
            let bytes = status.installedBytes
            if bytes > 0 { return "\(Formatters.bytes(bytes)) on disk" }
            return status.downloadGb.map { "\(Formatters.gigabytes($0)) on disk" } ?? "Installed"
        }
        if let remaining = remainingDownloadBytes { return "\(Formatters.bytes(remaining)) download" }
        return "Size unknown"
    }

    /// What the files are for: "preset voices (CustomVoice), voice cloning (Base)".
    var purposeText: String? {
        // A lone "model" says nothing more than the row itself.
        let purposes = status.parts.compactMap(\.purpose).filter { !$0.isEmpty && $0.lowercased() != "model" }
        return purposes.isEmpty ? nil : purposes.joined(separator: ", ")
    }

    /// The download does not fit in `freeBytes`.
    func lacksSpace(freeBytes: Int64?) -> Bool {
        guard let freeBytes, let needed = remainingDownloadBytes else { return false }
        return needed > freeBytes
    }

    /// "Needs 6.7 GB; 3.1 GB free on this Mac."
    func spaceWarning(freeBytes: Int64?) -> String? {
        guard lacksSpace(freeBytes: freeBytes), let freeBytes, let needed = remainingDownloadBytes else { return nil }
        return "Not enough free space: the download needs \(Formatters.bytes(needed)) and \(Formatters.bytes(freeBytes)) is free."
    }
}

/// Free space on the disk that holds the model files.
enum OpsDiskSpace {
    /// The folder model files live in (from the installed parts), else the Hugging Face cache in the home folder.
    static func modelsFolder(for models: [ModelStatus]) -> URL {
        if let path = models.lazy.flatMap(\.parts).compactMap(\.path).first(where: { !$0.isEmpty }) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Bytes available for important data on the volume of `url` (the nearest existing folder is used).
    static func availableBytes(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? probe.resourceValues(forKeys: keys) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}

// MARK: - Settings

/// Audio quality choices (AAC bitrate, `AppSettings.bitrateChoices`).
@MainActor
enum OpsAudioQuality {
    /// Bytes per hour of mono AAC at `kbps`.
    static func bytesPerHour(kbps: Int) -> Int64 { Int64(kbps) * 1000 / 8 * 3600 }

    /// "64 kbps (smallest files)", "96 kbps", "128 kbps (best quality)".
    static func title(kbps: Int) -> String {
        if kbps == AppSettings.bitrateChoices.first { return "\(kbps) kbps (smallest files)" }
        if kbps == AppSettings.bitrateChoices.last { return "\(kbps) kbps (best quality)" }
        return "\(kbps) kbps"
    }

    /// "About 28.8 MB per hour of audio."
    static func caption(kbps: Int) -> String { "About \(Formatters.bytes(bytesPerHour(kbps: kbps))) per hour of audio." }
}

enum OpsEngineCheck {
    /// "The engine works: 4 engines (Qwen3-TTS 1.7B, Voxtral TTS 4B, …)."
    static func summary(_ list: EngineList) -> String {
        let names = list.engines.map(\.name)
        switch names.count {
        case 0: return "The engine answered, but it lists no voice engines."
        case 1: return "The engine works: 1 voice engine (\(names[0]))."
        default: return "The engine works: \(names.count) voice engines (\(names.joined(separator: ", ")))."
        }
    }
}

enum OpsCacheText {
    /// "Freed 335.1 MB." / "There was nothing to free."
    static func freed(_ bytes: Int64) -> String { bytes > 0 ? "Freed \(Formatters.bytes(bytes))." : "There was nothing to free." }
}
