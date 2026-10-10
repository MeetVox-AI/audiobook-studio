import Foundation
import Testing
@testable import AudiobookStudio

// The sidebar's "new version" button: what Sparkle's events turn into, and what its button does. Sparkle itself
// is not started (`startSparkle: false`); its delegates call these same transitions.

@Test @MainActor func aFoundUpdateIsAnnouncedUntilSparklesWindowShowsIt() {
    let updater = Updater(startSparkle: false)
    #expect(updater.notice == nil && !updater.isAvailable)
    updater.foundUpdate(version: "0.3.4")
    #expect(updater.notice == .available(version: "0.3.4"))
    updater.reminderNotNeeded()                 // the person opened Sparkle's window, or the session ended
    #expect(updater.notice == nil)
}

@Test @MainActor func aDownloadedUpdateStaysUntilItIsInstalled() {
    let updater = Updater(startSparkle: false)
    var installed = 0
    updater.readyToInstall(version: "0.3.4") { installed += 1 }
    #expect(updater.notice == .readyToInstall(version: "0.3.4"))
    updater.foundUpdate(version: "0.3.4")       // a later check does not downgrade it to "available"
    updater.reminderNotNeeded()                 // nor does the end of a session: it installs only on quit
    #expect(updater.notice == .readyToInstall(version: "0.3.4"))
    updater.performNotice()
    #expect(installed == 1)                     // "Update Now" installs and relaunches
}

@Test func theButtonSaysWhatItDoes() {
    let ready = Updater.Notice.readyToInstall(version: "0.3.4")
    let found = Updater.Notice.available(version: "0.3.4")
    #expect(AppUpdateButton.buttonTitle(ready) == "Update Now")
    #expect(AppUpdateButton.help(ready) == "Audiobook Studio 0.3.4 is downloaded. Update Now restarts the app to use it; otherwise it installs when you quit.")
    #expect(AppUpdateButton.buttonTitle(found) == "Update…")
    #expect(AppUpdateButton.help(found) == "Audiobook Studio 0.3.4 is available. Click to install it; otherwise you keep this version.")
}
