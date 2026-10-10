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

    // MARK: Privacy (the full text is PRIVACY.md in the project; keep the two in step)

    static let privacyTitle = "Your privacy"
    static let privacyIntro = "The short version. The full Privacy Policy is under Settings → About."

    static let privacyPoints: [(symbol: String, heading: String, body: String)] = [
        ("lock.shield", "We collect nothing",
         "Audiobook Studio collects, receives and shares no data about you: no accounts, no analytics, no telemetry, no tracking, no crash reports. Your books, voices and audiobooks stay on your Mac and are never sent to the developer or to anyone else."),
        ("wifi.slash", "Works offline",
         "Narration, voice cloning and the speech check run on your Mac with no network connection. The internet is used only to download or update software."),
        ("arrow.down.circle", "Downloads come from other companies",
         "When you install, add a language or a voice, or check for updates, your Mac connects directly to GitHub, Hugging Face, the Internet Archive, Homebrew and the Python Package Index. They can see your IP address and what you asked for, under their own privacy policies. The developer receives nothing and is not responsible for what they collect."),
    ]

    /// Who the app talks to, and why (the table in PRIVACY.md, section 4).
    static let connections: [(service: String, why: String)] = [
        ("GitHub", "Daily check for a new version and the update download; the app, the engine installer and the engine's source code"),
        ("Hugging Face", "Voice models and some reference voices"),
        ("Internet Archive", "Some reference voices"),
        ("Homebrew", "The tools the engine needs (uv, ffmpeg, espeak-ng)"),
        ("Python Package Index", "The engine's Python libraries"),
    ]

    static let privacyAcceptance = "By choosing “I Agree” you accept the Terms of Use and the Privacy Policy."
    static let policyURL = URL(string: "https://github.com/antoine-debroye/audiobook-converter/blob/main/PRIVACY.md")!
}

/// The first-launch sheet, in two short pages: Terms of use, then Privacy. One agreement at the end covers both.
/// It cannot be dismissed without choosing: agree, or quit.
struct TermsSheet: View {
    let onAccept: () -> Void
    @State private var page: Page = .terms

    private enum Page { case terms, privacy }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: page == .terms ? "checkmark.shield" : "lock.shield", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page == .terms ? LegalText.title : LegalText.privacyTitle)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(page == .terms ? LegalText.intro : LegalText.privacyIntro)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(page == .terms ? "1 of 2" : "2 of 2")
                    .font(.callout)
                    .foregroundStyle(Theme.faint)
                    .accessibilityLabel(page == .terms ? "Page 1 of 2" : "Page 2 of 2")
            }
            LegalPoints(points: page == .terms ? LegalText.points : LegalText.privacyPoints)
            Text(page == .terms ? LegalText.acceptance : LegalText.privacyAcceptance)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Quit Audiobook Studio without accepting")
                Spacer()
                if page == .terms {
                    Button("Next") { page = .privacy }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Next: the privacy policy")
                } else {
                    Button("Back") { page = .terms }
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Back to the terms of use")
                    Button("I Agree", action: onAccept)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("I agree to the terms of use and the privacy policy")
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled()
    }
}

/// Points as rows (used by the sheet and by Settings > About).
struct LegalPoints: View {
    var points: [(symbol: String, heading: String, body: String)] = LegalText.points

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
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
