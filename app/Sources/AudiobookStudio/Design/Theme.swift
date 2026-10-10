import AppKit
import SwiftUI

// Design tokens shared by every screen. The rules behind them are in app/DESIGN.md.

enum Theme {
    /// Spacing on an 8-point grid.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii (always drawn with the continuous corner style).
    enum Radius {
        static let card: CGFloat = 18
        static let tile: CGFloat = 14
        static let control: CGFloat = 10
        static let bar: CGFloat = 24
    }

    /// Widest a screen's content grows before it is centred (keeps lines readable on big windows).
    static let contentWidth: CGFloat = 900

    // MARK: Colours

    /// The accent for primary actions, selection and progress. It is the system accent, so it follows the
    /// user's choice in System Settings; with "Multicolor" (the default) macOS uses the app's own accent,
    /// indigo like the icon (AccentColor in Assets/Assets.xcassets, compiled into the app by bundle.sh).
    static let accent = Color.accentColor
    /// Warm amber (from the icon's waveform): highlights and things that need a look.
    static let highlight = Color(nsColor: .dynamic(light: NSColor(srgbRed: 0.85, green: 0.52, blue: 0.0, alpha: 1),
                                                   dark: NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1)))
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    /// Page background behind the cards.
    static let canvas = Color(nsColor: .dynamic(light: NSColor(srgbRed: 0.957, green: 0.957, blue: 0.97, alpha: 1),
                                                dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.122, alpha: 1)))
    /// Solid surface of content cards.
    static let surface = Color(nsColor: .dynamic(light: .white,
                                                 dark: NSColor(srgbRed: 0.165, green: 0.165, blue: 0.18, alpha: 1)))
    /// A recessed area inside a card (tiles, wells, inline lists).
    static let inset = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.035),
                                               dark: NSColor(white: 1, alpha: 0.05)))
    /// Hairline used only where a surface needs an edge (dark mode cards, wells).
    static let hairline = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.06),
                                                  dark: NSColor(white: 1, alpha: 0.07)))

    // MARK: Type

    /// Rounded, tabular numbers for figures (durations, speeds, percentages).
    static func number(_ style: Font.TextStyle = .title2, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded).weight(weight).monospacedDigit()
    }

    /// Screen title shown at the top of a scrolling screen.
    static let screenTitle = Font.system(.largeTitle, design: .default).weight(.bold)
    /// Card and section titles.
    static let sectionTitle = Font.title3.weight(.semibold)
}

// MARK: - Dark mode: readable foregrounds

extension Theme {
    /// The accent as a text or symbol colour: the accent in light mode; in dark mode, where the indigo accent
    /// is hard to read on dark surfaces, the primary label colour (white). Use this, never `accent`, for text
    /// and symbols; `accent` stays for fills, strokes, selection and progress.
    static var accentForeground: ReadableForeground { ReadableForeground(Theme.accent) }

    /// Relative luminance (WCAG) of a colour as it resolves in `environment`.
    static func luminance(_ color: Color, in environment: EnvironmentValues) -> Double {
        let c = color.resolve(in: environment)
        return 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
    }

    /// True in dark mode when `color` used as text or a symbol would read poorly on the dark card surface:
    /// contrast below 3.5:1. That catches the indigo accent (about 2.8:1) and other dark purples and blues,
    /// while the orange, green and red state colours (4.3:1 to 7:1) keep their colour.
    static func isHardToRead(_ color: Color, in environment: EnvironmentValues) -> Bool {
        guard environment.colorScheme == .dark else { return false }
        let surface = 0.0232 // relative luminance of Theme.surface in dark mode (sRGB grey 0.165)
        return (luminance(color, in: environment) + 0.05) / (surface + 0.05) < 3.5
    }
}

extension Theme {
    /// The faintest text and hint symbols: the tertiary label colour in light mode; in dark mode the secondary
    /// one, because tertiary grey is only about 2.2:1 on the dark cards.
    static var faint: FaintForeground { FaintForeground() }
}

/// See `Theme.faint`.
struct FaintForeground: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        environment.colorScheme == .dark ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
    }
}

/// A text or symbol colour that stays readable: `color` as is, except in dark mode when it would be hard to
/// read on dark surfaces (`Theme.isHardToRead`), where the `fallback` label colour is used instead.
/// Light mode is never changed.
struct ReadableForeground: ShapeStyle {
    let color: Color
    var fallback: HierarchicalShapeStyle = .primary

    init(_ color: Color, fallback: HierarchicalShapeStyle = .primary) {
        self.color = color
        self.fallback = fallback
    }

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        Theme.isHardToRead(color, in: environment) ? AnyShapeStyle(fallback) : AnyShapeStyle(color)
    }
}

extension NSColor {
    /// A colour that follows the window's light or dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Shape where Self == RoundedRectangle {
    /// A rounded rectangle with continuous corners.
    static func smooth(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
