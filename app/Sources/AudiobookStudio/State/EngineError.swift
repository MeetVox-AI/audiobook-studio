import Foundation

/// A user-presentable failure: the engine's own message (shown as is) plus the stderr tail for the
/// "Details" disclosure. Every error the AppModel stores or throws is one of these.
struct EngineError: Error, LocalizedError, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// User-facing message (the engine's wording when it came from the engine).
    var message: String
    /// Last lines of the engine's stderr; empty when there is nothing to show.
    var stderrTail: String
    /// The engine executable was not found: point the user to Settings.
    var engineMissing: Bool

    init(message: String, stderrTail: String = "", engineMissing: Bool = false) {
        self.message = message
        self.stderrTail = stderrTail
        self.engineMissing = engineMissing
    }

    /// Wraps any error. EngineFailure keeps its message and stderr tail; an EngineError is returned unchanged.
    init(_ error: any Error) {
        if let e = error as? EngineError {
            self = e
        } else if let f = error as? EngineFailure {
            var missing = false
            if case .notFound = f { missing = true }
            self.init(message: f.errorDescription ?? "The engine failed.", stderrTail: f.stderrTail, engineMissing: missing)
        } else {
            self.init(message: error.localizedDescription)
        }
    }

    var errorDescription: String? { message }

    /// The engine refused to start because the disk is too full: show it prominently.
    var isDiskSpace: Bool { message.localizedCaseInsensitiveContains("not enough disk space") }
}
