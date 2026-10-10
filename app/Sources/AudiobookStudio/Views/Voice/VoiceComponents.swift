import SwiftUI

// Small building blocks shared by the Voices screen views.

/// Section heading with an optional one-line explanation (the design system's section header).
struct VoiceSectionTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        SectionHeader(title, subtitle: subtitle)
    }
}

/// A caution line on a soft amber tint (problems that do not stop the user).
struct VoiceWarningLine: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String = "exclamationmark.triangle.fill") {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.warning)
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.m - 2)
        .padding(.vertical, Theme.Space.s - 2)
        .background(Theme.warning.opacity(0.11), in: .smooth(Theme.Radius.control))
        .accessibilityElement(children: .combine)
    }
}

/// An engine failure: the engine's message as is, and its stderr tail in a "Details" disclosure.
struct VoiceErrorNote: View {
    let error: EngineError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label {
                Text(error.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.danger)
            }
            .font(error.isDiskSpace ? .body.weight(.semibold) : .callout)
            .accessibilityElement(children: .combine)
            if !error.stderrTail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.stderrTail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                    }
                    .frame(maxHeight: 140)
                    .background(Theme.surface.opacity(0.6), in: .smooth(Theme.Radius.control))
                    .padding(.top, Theme.Space.xs)
                }
                .font(.callout)
                .accessibilityLabel("Engine log details")
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.09), in: .smooth(Theme.Radius.tile))
    }
}

/// Licence chip, with a NON-COMMERCIAL chip for personal-use-only licences.
struct VoiceLicenseBadge: View {
    let license: String
    let noncommercial: Bool

    var body: some View {
        // Wraps onto a second line when the card is narrow, rather than truncating a chip.
        VoiceFlowLayout(spacing: Theme.Space.xs + 2) {
            if noncommercial {
                Chip(text: "NON-COMMERCIAL", systemImage: "exclamationmark.shield.fill", tint: Theme.warning)
            }
            Chip(text: license, systemImage: "doc.text", tint: .secondary)
                .help(license)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(noncommercial ? "Licence \(license), non-commercial: personal use only" : "Licence \(license)")
    }
}

/// Play / Stop for a sample through the shared player, as a prominent capsule ("Play", "Play A").
struct VoicePlayButton: View {
    @Environment(AppModel.self) private var model
    let url: URL
    /// What plays, for VoiceOver ("the preview of Ryan").
    let name: String
    var title: String?

    var body: some View {
        let playing = model.player.isPlaying(url)
        Button {
            model.player.toggle(url)
        } label: {
            Label {
                Text(title.map { playing ? "Stop \($0)" : "Play \($0)" } ?? (playing ? "Stop" : "Play"))
            } icon: {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .voiceCapsuleButton(prominent: true)
        .accessibilityLabel(playing ? "Stop \(name)" : "Play \(name)")
    }
}

/// Progress, result and playback of a preview sample.
struct VoiceSampleStatus: View {
    @Environment(AppModel.self) private var model
    let run: SampleRun
    /// What the sample is, for VoiceOver ("the preview of Ryan").
    let name: String
    var playTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch run.phase {
            case .finished:
                HStack(spacing: Theme.Space.m) {
                    if let url = run.previewAudioURL {
                        VoicePlayButton(url: url, name: name, title: playTitle)
                    }
                    Text(resultText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .failed:
                if let error = run.error { VoiceErrorNote(error: error) }
            case .cancelled:
                Label("Stopped.", systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .starting, .waiting, .loadingModel, .working:
                HStack(spacing: Theme.Space.m) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(run.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop") { run.cancel() }
                        .voiceCapsuleButton()
                        .controlSize(.small)
                        .accessibilityLabel("Stop making \(name)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(name): \(run.statusText)")
            }
            ForEach(Array(run.notices.enumerated()), id: \.offset) { _, notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "26 s of audio from “Chapter I.” · made at 3.3× real time (44 characters/s)".
    private var resultText: String {
        guard let r = run.result else { return "Sample ready." }
        var parts: [String] = []
        var audio = r.audioS.map { "\(Formatters.duration($0)) of audio" } ?? "Sample ready"
        if let title = r.title, !title.isEmpty { audio += " from “\(title)”" }
        parts.append(audio)
        if r.charsSynthesized == 0 {
            parts.append("reused from audio made earlier")
        } else if let x = r.realtimeX {
            var speed = "made at \(Formatters.realtime(x))"
            if let cps = r.rateCps { speed += " (\(Formatters.charsPerSecond(cps)))" }
            parts.append(speed)
        } else if let cps = r.rateCps {
            parts.append("made at \(Formatters.charsPerSecond(cps))")
        }
        return parts.joined(separator: " · ")
    }
}

/// "Open a book to hear voices reading it." with an Open button.
struct VoiceNoBookPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconBadge(systemImage: "book.closed", tint: .secondary, size: 36)
            Text("Open a book to hear voices reading it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button("Open a Book…") { model.openWithPanel() }
                .voiceCapsuleButton()
                .accessibilityLabel("Open a book")
        }
    }
}
