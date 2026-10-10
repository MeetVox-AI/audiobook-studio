import Foundation

enum EngineFailure: LocalizedError, Sendable {
    case notFound(String)
    case failed(message: String, stderrTail: String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p): return "The audiobook engine was not found at \(p). To install it, run this in Terminal: curl -fsSL https://raw.githubusercontent.com/antoine-debroye/audiobook-converter/main/scripts/install-engine.sh | bash — or set its location in Settings."
        case .failed(let m, _): return m
        case .badOutput(let m): return "Unexpected engine output: \(m)"
        }
    }

    var stderrTail: String {
        if case .failed(_, let tail) = self { return tail }
        return ""
    }
}

/// Runs the Python engine CLI. Every command prints JSON lines on stdout.
struct EngineClient: Sendable {
    var executable: URL

    static var defaultPath: String {
        if let p = Bundle.main.object(forInfoDictionaryKey: "AudiobookEnginePath") as? String, !p.isEmpty { return p }
        // Where scripts/install-engine.sh puts the engine for people who installed the app from the DMG.
        return NSHomeDirectory() + "/Library/Application Support/AudiobookStudio/source/engine/.venv/bin/audiobook-engine"
    }

    init(path: String) { executable = URL(fileURLWithPath: path) }

    /// Run a command to completion; returns decoded stdout lines.
    func lines(_ args: [String]) async throws -> [EngineEvent] {
        var out: [EngineEvent] = []
        for try await ev in stream(args) { out.append(ev) }
        return out
    }

    /// Run a command and decode its last stdout line as `T`.
    func json<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        let raw = try await rawLines(args)
        guard let last = raw.last, let data = last.data(using: .utf8) else {
            throw EngineFailure.badOutput("no output")
        }
        if let ev = try? EngineJSON.decoder.decode(EngineEvent.self, from: data), ev.event == "error" {
            throw EngineFailure.failed(message: ev.message ?? "Engine error", stderrTail: "")
        }
        do { return try EngineJSON.decoder.decode(T.self, from: data) } catch {
            throw EngineFailure.badOutput("\(error)")
        }
    }

    private func rawLines(_ args: [String]) async throws -> [String] {
        var collected: [String] = []
        for try await line in rawStream(args) { collected.append(line) }
        return collected
    }

    /// Stream decoded events while the command runs. Throws EngineFailure on non-zero exit or error event.
    /// An error event is not thrown at once: the stream keeps reading until the process exits, so the
    /// failure carries the stderr tail (shown in the error disclosure) along with the engine's message.
    func stream(_ args: [String]) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var errorEvent: EngineEvent?
                    for try await line in rawStream(args) {
                        guard let data = line.data(using: .utf8),
                              let ev = try? EngineJSON.decoder.decode(EngineEvent.self, from: data) else { continue }
                        if ev.event == "error" {
                            errorEvent = ev
                            continue
                        }
                        continuation.yield(ev)
                    }
                    // Exit code 0 despite an error event: report the event without a stderr tail.
                    if let errorEvent {
                        throw EngineFailure.failed(message: errorEvent.message ?? "Engine error", stderrTail: "")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Folders searched after PATH for tools the engine runs (ffmpeg, ffprobe). An app opened from Finder or
    /// the Dock gets launchd's minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which has no Homebrew.
    static let toolFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// The app's environment with the tool folders appended to PATH (detached jobs inherit it too).
    static func childEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in toolFolders where !parts.contains(folder) { parts.append(folder) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// Raw stdout lines; stderr is collected and attached to failures.
    func rawStream(_ args: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                continuation.finish(throwing: EngineFailure.notFound(executable.path))
                return
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = EngineClient.childEnvironment()
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            let errBuffer = StderrBuffer()
            stderr.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { errBuffer.append(d) }
            }
            // The exit is awaited (never `waitUntilExit()`, which would hold a thread until the process ends).
            let (exited, exitedContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            process.terminationHandler = { _ in
                exitedContinuation.yield()
                exitedContinuation.finish()
            }
            do { try process.run() } catch {
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: EngineFailure.failed(message: "Could not start the engine: \(error.localizedDescription)", stderrTail: ""))
                return
            }
            let reader = Task {
                var lastError: String?
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if line.contains("\"event\": \"error\"") || line.contains("\"event\":\"error\"") {
                            lastError = line
                        }
                        continuation.yield(line)
                    }
                } catch {}
                for await _ in exited {}
                stderr.fileHandleForReading.readabilityHandler = nil
                // Only when the consumer went away first (the process was asked to stop and has not exited yet):
                // there is no exit status to read and nobody left to report to.
                guard !process.isRunning else {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                let tail = errBuffer.tail()
                if process.terminationStatus != 0 {
                    var message = "The engine exited with code \(process.terminationStatus)."
                    if let le = lastError, let d = le.data(using: .utf8),
                       let ev = try? EngineJSON.decoder.decode(EngineEvent.self, from: d), let m = ev.message {
                        message = m
                    }
                    continuation.finish(throwing: EngineFailure.failed(message: message, stderrTail: tail))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
                reader.cancel()
            }
        }
    }
}

/// Thread-safe rolling buffer of the last ~8 KB of stderr.
final class StderrBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 8192 { data = data.suffix(8192) }
    }
    func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
