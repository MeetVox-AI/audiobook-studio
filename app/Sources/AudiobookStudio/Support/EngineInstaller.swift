import Foundation

/// The result of a small read-only command run during the preflight.
struct CommandResult: Equatable, Sendable {
    var status: Int32
    /// Standard output and standard error together.
    var output: String
}

/// Runs a short command (executable path, arguments, timeout in seconds). Injected so tests never run real commands.
typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult

enum SystemCommands {
    /// Runs the command for real, waiting at most `timeout` seconds. A command that cannot start or times out
    /// reports status -1.
    static let run: CommandRunner = { executable, arguments, timeout in
        // Inside the test bundle nothing real is ever run: a clean Mac answers.
        if isUnderTest { return CommandResult(status: 0, output: "") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return CommandResult(status: -1, output: error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return CommandResult(status: -1, output: "Timed out after \(Int(timeout)) seconds.")
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return CommandResult(status: proc.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static let isUnderTest = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// Apple's developer tools (git comes from them): installed, and their licence accepted.
enum DeveloperTools: Equatable, Sendable {
    case ready
    /// Xcode or its command line tools are installed but the licence was never accepted: git and Homebrew refuse to run.
    case licenseNotAccepted
    /// The command line tools are not installed.
    case commandLineToolsMissing

    /// The command people paste into Terminal to accept the licence.
    static let acceptLicenseCommand = "sudo xcodebuild -license accept"

    /// Recognises the licence and missing-tools problems in an install failure (its message and the log tail);
    /// nil for any other failure. Case-insensitive; the licence wins when both are mentioned.
    static func issue(message: String, logTail: String = "") -> DeveloperTools? {
        let text = (message + "\n" + logTail).lowercased()
        if text.contains("license"), text.contains("xcodebuild") { return .licenseNotAccepted }
        if text.contains("xcode-select") || text.contains("command line tools") || text.contains("no developer tools") {
            return .commandLineToolsMissing
        }
        return nil
    }
}

/// What the Mac needs before the engine can be installed from inside the app.
struct SetupPrerequisites: Equatable, Sendable {
    var appleSilicon: Bool
    var homebrew: Bool
    var freeGB: Int
    var developerTools: DeveloperTools = .ready
    /// The raw message of a developer-tools check that failed for an unknown reason (diagnostics only; never blocks).
    var developerToolsNote: String?

    /// What people paste into Terminal when Homebrew is missing (the installer asks for their password, so the
    /// app cannot run it for them).
    static let homebrewCommand = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    /// Checks the developer tools without ever showing a system dialog: `xcode-select -p` first (git is not run when
    /// the tools are missing, because Apple's git shim would offer to install them), then `git --version`.
    static func developerToolsState(run: CommandRunner) -> (state: DeveloperTools, note: String?) {
        guard run("/usr/bin/xcode-select", ["-p"], 5).status == 0 else { return (.commandLineToolsMissing, nil) }
        let git = run("/usr/bin/git", ["--version"], 5)
        if git.status == 0 { return (.ready, nil) }
        let raw = git.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("license") || lower.contains("xcodebuild -license") { return (.licenseNotAccepted, raw) }
        return (.ready, raw)
    }

    /// Cheap: two file checks, a disk query and (unless `checkTools` is false) two tiny commands.
    static func current(run: CommandRunner = SystemCommands.run, checkTools: Bool = true) -> SetupPrerequisites {
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        let fm = FileManager.default
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].contains { fm.isExecutableFile(atPath: $0) }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        var result = SetupPrerequisites(appleSilicon: arm, homebrew: brew, freeGB: Int(free / 1_000_000_000))
        if checkTools {
            let tools = developerToolsState(run: run)
            result.developerTools = tools.state
            result.developerToolsNote = tools.note
        }
        return result
    }

    /// The first thing in the way, in words for a person; nil when the install can start.
    func blocker(neededGB: Double) -> String? {
        if !appleSilicon { return "Audiobook Studio needs a Mac with Apple silicon (M1 or later)." }
        if Double(freeGB) < neededGB { return "This Mac has \(freeGB) GB free; the choices above need about \(Int(neededGB.rounded(.up))) GB." }
        return nil
    }
}

/// Installs the engine by running `install-engine.sh` (bundled with the app) without the models:
/// the app downloads those itself, with progress. Reports which of the script's steps it is on.
@MainActor
@Observable
final class EngineInstaller {
    /// Titles of the script's steps, in order (it prints one "==>" line per step).
    static let stepTitles = ["Installing audio tools", "Downloading the engine", "Preparing the voice engine"]

    /// How many "==>" lines the script has printed (the step in progress is the last one).
    private(set) var markers = 0
    private(set) var isRunning = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var cancelled = false

    var stepTitle: String { Self.stepTitles[min(max(markers - 1, 0), Self.stepTitles.count - 1)] }
    /// 0...1 across the script's steps.
    var fraction: Double { isRunning ? Double(max(markers - 1, 0)) / Double(Self.stepTitles.count) : 0 }

    /// Where the script comes from: the app bundle, the source checkout (development builds), else GitHub.
    static func scriptURL() async throws -> URL {
        if let bundled = Bundle.main.url(forResource: "install-engine", withExtension: "sh") { return bundled }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/install-engine.sh")
        if FileManager.default.fileExists(atPath: checkout.path) { return checkout }
        let remote = URL(string: "https://raw.githubusercontent.com/MeetVox-AI/audiobook-studio/main/scripts/install-engine.sh")!
        let (data, response) = try await URLSession.shared.data(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EngineError(message: "The setup files could not be downloaded. Check the internet connection and try again.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("install-engine-\(UUID().uuidString).sh")
        try data.write(to: file)
        return file
    }

    /// Runs the script to completion. Throws EngineError (the script's own "Error:" line, log tail in the details).
    func install(script scriptOverride: URL? = nil) async throws {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        markers = 0
        defer { isRunning = false; process = nil }

        let script: URL
        do {
            if let scriptOverride { script = scriptOverride } else { script = try await Self.scriptURL() }
        } catch { throw EngineError(error) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = EngineClient.childEnvironment()
        env["NO_MODELS"] = "1"
        env["AUDIOBOOK_PREFIX"] = EngineClient.installPrefix
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let log = StderrBuffer()
        let steps = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        for pipe in [out, err] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                log.append(d)
                let text = String(decoding: d, as: UTF8.self)
                for line in text.split(separator: "\n") where line.hasPrefix("==> ") && !line.hasPrefix("==> Done") {
                    steps.continuation.yield()
                }
            }
        }
        let exited = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        proc.terminationHandler = { p in
            exited.continuation.yield(p.terminationStatus)
            exited.continuation.finish()
            steps.continuation.finish()
        }
        do { try proc.run() } catch {
            throw EngineError(message: "The setup could not start: \(error.localizedDescription)")
        }
        process = proc
        let ticker = Task { [weak self] in
            for await _ in steps.stream { self?.markers += 1 }
        }
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        ticker.cancel()
        if cancelled { throw CancellationError() }
        guard status == 0 else {
            let tail = log.tail()
            let line = tail.split(separator: "\n").last { $0.hasPrefix("Error:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            throw EngineError(message: line ?? "The setup stopped before it finished. Try again; if it keeps failing, the details below say why.",
                              stderrTail: tail)
        }
        markers = Self.stepTitles.count + 1
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }
}
