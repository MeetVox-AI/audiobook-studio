import Foundation
import Sparkle

/// In-app updates (Sparkle). Release builds ship with an appcast URL and a public signing key in Info.plist
/// (see scripts/bundle.sh); the app then checks once a day, downloads a new version in the background and
/// installs it when the app quits. Updates are accepted only when they are signed with the project's key.
/// Development builds have no feed, so the updater is never started there.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController?

    /// True when this build can update itself (a release build with a feed).
    var isAvailable: Bool { controller != nil }

    init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
        // The self-test tour must never reach out to the network or show update windows.
        if hasFeed && SnapshotTour.directory == nil {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}
