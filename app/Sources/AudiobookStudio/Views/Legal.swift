import SwiftUI

/// The terms shown on first launch (and whenever `AppSettings.currentTermsVersion` is raised) and under
/// Settings > About. Plain language; not a substitute for legal advice.
enum LegalText {
    static let title = "Before you start"
    static let intro = "Audiobook Studio turns books into audiobooks on your Mac. Please read these short terms once."

    static let points: [(symbol: String, heading: String, body: String)] = [
        ("checkmark.seal", "Lawful use only",
         "Use Audiobook Studio only in a lawful way. Convert only books you own or have the right to use, and clone a voice only with its owner’s permission. Never use it to deceive, impersonate, defraud or harm anyone, or to infringe copyright or any other law."),
        ("person.crop.circle.badge.checkmark", "You are responsible",
         "You alone are responsible for what you make and how you use it, including following the licences of the voice models and voices you use (some are non-commercial only)."),
        ("exclamationmark.shield", "No warranty, no liability",
         "The app is provided “as is”, without warranty of any kind. To the fullest extent the law allows, the developer is not liable for any use of the app, for anything made with it, or for any loss or damage."),
        ("doc.text", "Licences",
         "Audiobook Studio is released under the MIT licence. The models, voices and libraries it uses keep their own licences, listed in full under Settings → About. Voxtral and Fish Audio S2 Pro are for non-commercial use only."),
    ]

    /// Licence of each component, shown under Settings > About (from the project README).
    static let licences: [(name: String, licence: String)] = [
        ("Audiobook Studio", "MIT"),
        ("Kokoro 82M (voice model)", "Apache-2.0"),
        ("Qwen3-TTS 1.7B (voice model)", "Apache-2.0"),
        ("Voxtral 4B (voice model)", "CC BY-NC 4.0, non-commercial"),
        ("Fish Audio S2 Pro (voice model)", "Fish Audio Research Licence, non-commercial"),
        ("Whisper large-v3-turbo (speech check)", "MIT"),
        ("mlx-audio (inference library)", "MIT"),
        ("PyMuPDF (PDF reading)", "AGPL-3.0"),
        ("Reference voices", "CC BY 4.0, CC0 or public domain; credits are shown in Voices"),
    ]

    static let acceptance = "By continuing you accept these terms."
}

/// The first-launch sheet. It cannot be dismissed without choosing: accept, or quit.
struct TermsSheet: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: "checkmark.shield", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LegalText.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(LegalText.intro)
                        .foregroundStyle(.secondary)
                }
            }
            LegalPoints()
            Text(LegalText.acceptance)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Quit Audiobook Studio without accepting")
                Spacer()
                Button("I Understand and Accept", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Accept the terms and continue")
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }
}

/// The four points, as rows (used by the sheet and by Settings > About).
struct LegalPoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(Array(LegalText.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    IconBadge(systemImage: point.symbol, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.heading).font(.headline)
                        Text(point.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
