import AppKit
import Foundation

/// Finder / Books actions for finished audiobooks and samples.
@MainActor
enum FileActions {
    /// Selects the file in a Finder window.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the file with its default app.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens an .m4b in Apple Books (equivalent of `open -a Books <file>`), falling back to the default app.
    static func openInBooks(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard let books = workspace.urlForApplication(withBundleIdentifier: "com.apple.iBooksX") else {
            workspace.open(url)
            return
        }
        workspace.open([url], withApplicationAt: books, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// True when a file exists at `url` (finished outputs may have been moved or deleted).
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
