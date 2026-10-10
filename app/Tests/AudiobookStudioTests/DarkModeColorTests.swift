import SwiftUI
import Testing
@testable import AudiobookStudio

// The dark-mode rule (DESIGN.md, "Dark mode: no purple text"): a colour that is hard to read on the dark
// card surface is never used for text or symbols in dark mode; light mode is never changed.

@MainActor private func environment(_ scheme: ColorScheme) -> EnvironmentValues {
    var values = EnvironmentValues()
    values.colorScheme = scheme
    return values
}

/// The app's accent in dark mode (AccentColor in Assets/Assets.xcassets).
private let appIndigoDark = Color(.sRGB, red: 0.369, green: 0.361, blue: 0.902)

@MainActor @Test func theIndigoAccentIsHardToReadInDarkMode() {
    #expect(Theme.isHardToRead(appIndigoDark, in: environment(.dark)))
    // (The system indigo is lighter in dark mode on macOS 26, about 4:1, so it is not caught; the app's own
    // accent is the darker indigo above.)
}

@MainActor @Test func stateColoursKeepTheirColourInDarkMode() {
    let dark = environment(.dark)
    #expect(!Theme.isHardToRead(.orange, in: dark))
    #expect(!Theme.isHardToRead(.green, in: dark))
    #expect(!Theme.isHardToRead(.red, in: dark))
    #expect(!Theme.isHardToRead(.white, in: dark))
    #expect(!Theme.isHardToRead(Theme.highlight, in: dark))
}

@MainActor @Test func lightModeIsNeverChanged() {
    let light = environment(.light)
    #expect(!Theme.isHardToRead(appIndigoDark, in: light))
    #expect(!Theme.isHardToRead(.indigo, in: light))
    #expect(!Theme.isHardToRead(.black, in: light))
}

@MainActor @Test func darkGreysAndBlacksAreReplacedToo() {
    // The rule is about readability, not hue: any colour too dark for the dark surface is replaced.
    #expect(Theme.isHardToRead(.black, in: environment(.dark)))
    #expect(Theme.isHardToRead(Color(white: 0.25), in: environment(.dark)))
}
