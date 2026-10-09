import Foundation

/// Follows a job's append-only events.jsonl. Only complete lines are decoded; a partially written
/// last line is kept until its newline arrives. Stops after a terminal event (done/error/cancelled).
///
/// events.jsonl is appended to across runs of the same job (a cancelled or interrupted job is resumed
/// by running the same convert again). Every run starts with `run_start{pid}`; logs written by older
/// engines start each run with `job_start` instead. To show the right run, pick a `StartPoint`:
/// - `.run(pid:)` for a run the app just started or re-attached to (pid from `convert --detach` or `jobs list`);
/// - `.latestRun` to replay the most recent run of a job (job detail of a finished job);
/// - `.beginning` / `.end` for the raw file.
/// Starting at `.beginning` on a multi-run file would stop at the first terminal event of an OLD run.
struct EventTailer: Sendable {
    let url: URL
    var pollInterval: Duration = .milliseconds(400)

    static let terminal: Set<String> = ["done", "error", "cancelled"]
    /// First event of every run (carries the run's process id).
    static let runBoundary = "run_start"
    /// First event of a run in logs written before `run_start` existed.
    static let legacyRunBoundary = "job_start"

    enum StartPoint: Sendable, Equatable {
        /// Every event from the top of the file.
        case beginning
        /// Only events appended after tailing starts.
        case end
        /// The most recent run present when tailing starts (or, if the file is empty, the first run to appear).
        case latestRun
        /// The run whose `run_start` carries this process id. Earlier runs are skipped; if that run has not
        /// started writing yet, the tailer waits for it.
        case run(pid: Int)
    }

    func events(fromStart: Bool = true) -> AsyncStream<EngineEvent> {
        events(from: fromStart ? .beginning : .end)
    }

    func events(from start: StartPoint) -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in
            let task = Task {
                var offset: UInt64 = 0
                var pending = Data()
                var following = false   // true once the start of the wanted run has been found
                var firstRead = true
                switch start {
                case .beginning:
                    following = true
                case .end:
                    following = true
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? UInt64 { offset = size }
                case .latestRun, .run:
                    break
                }
                while !Task.isCancelled {
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        defer { try? handle.close() }
                        try? handle.seek(toOffset: offset)
                        let chunk = (try? handle.readToEnd()) ?? Data()
                        offset += UInt64(chunk.count)
                        pending.append(chunk)
                        let (lines, rest) = EventTailer.split(pending)
                        pending = rest
                        var batch = lines.compactMap { try? EngineJSON.decoder.decode(EngineEvent.self, from: $0) }
                        if !following {
                            let begin: Int?
                            switch start {
                            case .latestRun:
                                // Decide once, on what exists now; anything appended later is newer.
                                begin = firstRead ? (EventTailer.runStartIndex(in: batch) ?? 0) : 0
                            case .run(let pid):
                                begin = EventTailer.runStartIndex(in: batch, pid: pid)
                            case .beginning, .end:
                                begin = 0
                            }
                            if let begin {
                                batch = Array(batch[begin...])
                                following = true
                            } else {
                                batch = []
                            }
                        }
                        firstRead = false
                        for ev in batch {
                            continuation.yield(ev)
                            if ev.isTerminal {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Index of the first event of the latest run in `events`.
    /// With a pid: the last `run_start` carrying that pid (nil if absent).
    /// Without: the last `run_start`, else the last `job_start` (legacy logs), else nil.
    /// Same rule as the engine's `jobs.last_events`.
    static func runStartIndex(in events: [EngineEvent], pid: Int? = nil) -> Int? {
        if let pid {
            return events.lastIndex { $0.event == runBoundary && $0.pid == pid }
        }
        return events.lastIndex { $0.event == runBoundary } ?? events.lastIndex { $0.event == legacyRunBoundary }
    }

    /// The events of the most recent run (all events when no run boundary is present).
    static func latestRun(of events: [EngineEvent]) -> [EngineEvent] {
        Array(events[(runStartIndex(in: events) ?? 0)...])
    }

    /// Reads a whole events file once and returns its latest run. A trailing partial line is ignored.
    /// Synchronous file I/O: call it off the main actor.
    static func readLatestRun(at url: URL) -> [EngineEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let (lines, _) = split(data)
        return latestRun(of: lines.compactMap { try? EngineJSON.decoder.decode(EngineEvent.self, from: $0) })
    }

    /// Splits complete lines from a trailing partial line.
    static func split(_ data: Data) -> ([Data], Data) {
        var lines: [Data] = []
        var start = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            let line = data[start..<i]
            if !line.isEmpty { lines.append(Data(line)) }
            start = data.index(after: i)
        }
        return (lines, Data(data[start...]))
    }
}
