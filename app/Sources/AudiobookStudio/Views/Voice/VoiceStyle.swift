import SwiftUI

// Visual helpers of the Voices screen, built on the shared design system (Design/).

/// Colours and small rules shared by the Voices screen views.
enum VoiceStyle {
    /// Language-chip tint (text in the tint on a soft fill): French indigo (the app accent), English teal,
    /// others pink. Teal and pink are deeper in light mode and lighter in dark mode, so the chip text keeps
    /// its contrast on the card in both. The indigo is hard to read as text in dark mode: use this tint as a
    /// foreground only through `Chip` or `ReadableForeground`, which then draw the text in the label colour.
    static func tint(forLanguage code: String?) -> Color {
        switch code?.lowercased() {
        case "fr"?: return Theme.accent
        case "en"?: return teal
        case nil: return .gray
        default: return pink
        }
    }

    /// Avatar fill behind white initials, in the language's hue: deep in light and dark mode so white
    /// text on it stays above 4.5:1.
    static func avatarFill(forLanguage code: String?) -> Color {
        switch code?.lowercased() {
        case "fr"?: return deepIndigo
        case "en"?: return deepTeal
        case nil: return Color(white: 0.42)
        default: return deepPink
        }
    }

    private static let teal = Color(nsColor: .dynamic(light: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.48, alpha: 1),
                                                      dark: NSColor(srgbRed: 0.35, green: 0.78, blue: 0.86, alpha: 1)))
    private static let pink = Color(nsColor: .dynamic(light: NSColor(srgbRed: 0.72, green: 0.06, blue: 0.32, alpha: 1),
                                                      dark: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.58, alpha: 1)))
    private static let deepIndigo = Color(.sRGB, red: 0.30, green: 0.28, blue: 0.78)
    private static let deepTeal = Color(.sRGB, red: 0.0, green: 0.42, blue: 0.48)
    private static let deepPink = Color(.sRGB, red: 0.72, green: 0.06, blue: 0.32)

    /// Up to two initials from a voice name, ignoring bracketed parts: "SIWIS — studio narrator (F)" → "SS",
    /// "LibriVox reader 12205 (F)" → "LR". nil when the name has no word starting with a letter.
    static func initials(_ name: String) -> String? {
        var cleaned = name
        while let open = cleaned.firstIndex(of: "("), let close = cleaned[open...].firstIndex(of: ")") {
            cleaned.removeSubrange(open...close)
        }
        let words = cleaned
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? nil : letters.joined()
    }
}

/// A round avatar with a voice's initials (or a person symbol), tinted by its language.
/// Decorative: the name is always shown as text next to it.
struct VoiceAvatar: View {
    let name: String?
    let language: String?
    var size: CGFloat = 40
    /// Adds an accent check badge (the voice is the narrator).
    var isSelected = false

    var body: some View {
        ZStack {
            Circle()
                .fill(VoiceStyle.avatarFill(forLanguage: language))
            // Shade only towards the bottom, so the white initials never sit on a lighter colour than the fill.
            Circle()
                .fill(LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom))
            if let initials = name.flatMap(VoiceStyle.initials) {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(size * 0.12)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                // A badge fill: the accent is the disc, the check on it is white (readable in dark mode too).
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .background(Circle().fill(Theme.surface).padding(-1.5))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Lays its children out from left to right and wraps to a new line when the width runs out
/// (chips, filter controls). Items on a line are centred vertically.
struct VoiceFlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.s
    var lineSpacing: CGFloat = Theme.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        let sizes: [CGSize] = subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
        var frames: [CGRect] = []
        var lineStart = 0
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if x > 0, x + size.width > maxWidth {
                for i in lineStart..<index { frames[i].origin.y = y + (lineHeight - frames[i].height) / 2 }
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
                lineStart = index
            }
            frames.append(CGRect(x: x, y: y, width: min(size.width, maxWidth), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        for i in lineStart..<frames.count { frames[i].origin.y = y + (lineHeight - frames[i].height) / 2 }
        return (frames, CGSize(width: usedWidth, height: frames.isEmpty ? 0 : y + lineHeight))
    }
}

extension View {
    /// The Voices screen's content buttons: bordered (or prominent) capsules.
    func voiceCapsuleButton(prominent: Bool = false) -> some View {
        modifier(VoiceCapsuleButtonModifier(prominent: prominent))
    }

    /// The Voices screen's text inputs (search, transcripts): a text-background field with a separator
    /// edge, and an accent ring while it has keyboard focus.
    func voiceTextField(focused: Bool) -> some View {
        modifier(VoiceTextFieldModifier(focused: focused))
    }
}

private struct VoiceTextFieldModifier: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: .smooth(Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(focused ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct VoiceCapsuleButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
