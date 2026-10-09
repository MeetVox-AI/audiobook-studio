import Foundation
import UserNotifications

/// Local notifications (job done / failed).
///
/// UNUserNotificationCenter requires a real app bundle: under `swift run` (bare executable) or
/// `swift test` (test runner) calling it can crash, so every entry point checks `isAvailable` first.
@MainActor
enum Notifications {
    /// True only when running as a bundled .app (Bundle.main.bundleIdentifier != nil and an .app bundle).
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks once for permission to show alerts. Safe to call repeatedly.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification immediately. `identifier` replaces an earlier one with the same id.
    static func post(title: String, body: String, identifier: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
