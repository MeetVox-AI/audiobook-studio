import Foundation
import Sparkle

/// In-app updates (Sparkle). Release builds ship with an appcast URL and a public signing key in Info.plist
/// (see scripts/bundle.sh); the app then checks once a day, downloads a new version in the background and
/// installs it when the app quits. Updates are accepted only when they are signed with the project's key.
/// Development builds have no feed, so the updater is never started there.
///
/// No update ever opens a window by itself. With automatic updates (the default) a new version is downloaded and
/// installed silently when the app quits; a small button next to Settings (`notice`) offers "Update Now"
/// meanwhile. With automatic updates off, the same button offers "Update…" and nothing else happens: whoever
/// ignores it keeps the current version. Only a check the person starts shows Sparkle's window.
@MainActor
@Observable
final class Updater: NSObject {
    /// What the sidebar says about a new version.
    enum Notice: Equatable {
        /// Found, not downloaded (automatic updates are off): "Update…" opens Sparkle's window to install it.
        case available(version: String)
        /// Downloaded and waiting to be installed when the app quits: "Update Now" installs it now.
        case readyToInstall(version: String)

        var version: String {
            switch self {
            case .available(let v), .readyToInstall(let v): return v
            }
        }
    }

    private(set) var notice: Notice?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?

    /// True when this build can update itself (a release build with a feed).
    var isAvailable: Bool { controller != nil }

    /// `startSparkle: false` builds the notice logic alone (tests).
    init(startSparkle: Bool = true) {
        super.init()
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
        // The self-test tour must never reach out to the network or show update windows.
        guard startSparkle, hasFeed, SnapshotTour.directory == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Privacy: the update check never sends a system profile (the same is set in Info.plist, SUSendProfileInfo).
        controller?.updater.sendsSystemProfile = false
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// The sidebar button: install the downloaded version and relaunch, or show Sparkle's window for it.
    func performNotice() {
        switch notice {
        case .readyToInstall:
            installNow?()
        case .available:
            checkForUpdates()
        case nil:
            break
        }
    }

    // MARK: - Notice transitions (called from the Sparkle delegates below; tests call them directly)

    /// A scheduled check found a version the person has not seen yet (automatic updates off).
    func foundUpdate(version: String) {
        if case .readyToInstall = notice { return }   // a downloaded update says more
        notice = .available(version: version)
    }

    /// A version was downloaded and will be installed on quit; `install` installs it now and relaunches.
    func readyToInstall(version: String, install: @escaping () -> Void) {
        installNow = install
        notice = .readyToInstall(version: version)
    }

    /// Sparkle's own window is showing the update, or the update session ended: the reminder is no longer needed.
    /// A downloaded update stays announced: it is still installed only when the app quits.
    func reminderNotNeeded() {
        if case .available = notice { notice = nil }
    }
}

// Sparkle calls its delegates on the main thread (SPUUpdaterDelegate is main-actor already; the user driver
// delegate is not annotated, so @preconcurrency checks it at run time).
extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyToInstall(version: item.displayVersionString, install: immediateInstallHandler)
        return true   // the sidebar offers "Update Now"; Sparkle still installs on quit
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        reminderNotNeeded()
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks: the sidebar shows the update instead of a window popping up.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { foundUpdate(version: update.displayVersionString) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        reminderNotNeeded()
    }

    func standardUserDriverWillFinishUpdateSession() {
        reminderNotNeeded()
    }
}
