import AppKit
import SwiftUI

/// Window helpers shared by screens that live in the Settings window but lead to the main window.
enum WindowActions {
    /// Brings the main window to the front (opening it when it was closed). Called from the Settings window,
    /// whose key window is therefore not a candidate.
    @MainActor
    static func showMainWindow(openWindow: OpenWindowAction) {
        let settings = NSApp.keyWindow
        let main = NSApp.windows.first { $0 !== settings && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        if let main {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: AppDelegate.mainWindowID)
        }
        NSApp.activate()
    }
}
