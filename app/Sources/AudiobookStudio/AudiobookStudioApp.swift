import AppKit
import SwiftUI
import UserNotifications

/// App entry point.
/// - One main window (RootView) plus the standard Settings scene (⌘,).
/// - File > Open… (⌘O) shows the Open panel; .epub/.pdf files can also be dropped on the window
///   or opened from Finder (the bundle declares both document types).
/// - At launch the AppDelegate loads engine data and re-attaches to queued/running jobs
///   (`AppModel.launch()`), so closing the window or quitting never stops a conversion.
@main
struct AudiobookStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Audiobook Studio", id: AppDelegate.mainWindowID) {
            RootView()
                .environment(appDelegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenBookCommand(model: appDelegate.model)
            }
            // "Check for Updates…" in the app menu, as macOS apps do (release builds only).
            CommandGroup(after: .appInfo) {
                if appDelegate.updater.isAvailable {
                    Button("Check for Updates…") { appDelegate.updater.checkForUpdates() }
                        .accessibilityLabel("Check for updates")
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.updater)
        }
    }
}

/// File > Open… (⌘O). Reopens the main window first if it was closed.
private struct OpenBookCommand: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open…") {
            if !AppDelegate.hasVisibleMainWindow { openWindow(id: AppDelegate.mainWindowID) }
            model.openWithPanel()
        }
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityLabel("Open a book")
    }
}

/// Owns the AppModel (so files opened from Finder before any window exists still reach it),
/// starts the launch work and lets notifications show while the app is in front.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let mainWindowID = "main"

    /// The self-check tour (SnapshotTour) keeps its settings in a separate defaults domain, so it never reads
    /// or changes the user's own preferences.
    let updater = Updater()

    let model = AppModel(settings: SnapshotTour.directory == nil
        ? AppSettings()
        : AppSettings(defaults: UserDefaults(suiteName: "local.audiobookstudio.snapshot") ?? .standard))

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable: make it a regular app with a Dock icon and a menu bar.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        if Notifications.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
        Task {
            await model.launch()
            if let dir = SnapshotTour.directory { await SnapshotTour.run(model: model, into: dir) }
        }
    }

    /// Books opened from Finder (double-click, "Open With", dropped on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        model.handleDrop(urls)
    }

    /// Samples, previews, benchmarks and model downloads exist only for the app's screens: stop their engine
    /// processes (they would otherwise hold the GPU or keep downloading). Conversions run detached and continue.
    func applicationWillTerminate(_ notification: Notification) {
        model.stopScreenEngineWork()
    }

    /// Jobs run in their own processes: closing the last window must not quit while one is running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// True when a main (non-panel) window is on screen.
    static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
