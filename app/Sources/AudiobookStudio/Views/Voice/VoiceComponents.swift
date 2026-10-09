import SwiftUI

// Small building blocks shared by the Voices screen views.

/// Section heading with an optional one-line explanation.
struct VoiceSectionTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An orange caution line (problems that do not stop the user).
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
                .foregroundStyle(.orange)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// An engine failure: the engine's message as is, and its stderr tail in a "Details" disclosure.
struct VoiceErrorNote: View {
    let error: EngineError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(error.message)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
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
                    }
                    .frame(maxHeight: 140)
                }
                .font(.callout)
                .accessibilityLabel("Engine log details")
            }
        }
    }
}

/// Licence capsule, with a NON-COMMERCIAL badge for personal-use-only licences.
struct VoiceLicenseBadge: View {
    let license: String
    let noncommercial: Bool

    var body: some View {
        HStack(spacing: 6) {
            if noncommercial {
                Label("NON-COMMERCIAL", systemImage: "exclamationmark.shield.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.orange.opacity(0.6), lineWidth: 1))
            }
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(license)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(noncommercial ? "Licence \(license), non-commercial: personal use only" : "Licence \(license)")
    }
}

/// Play / Stop for a sample through the shared player.
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
            Label(title.map { playing ? "Stop \($0)" : "Play \($0)" } ?? (playing ? "Stop" : "Play"),
                  systemImage: playing ? "stop.fill" : "play.fill")
        }
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
        VStack(alignment: .leading, spacing: 6) {
            switch run.phase {
            case .finished:
                HStack(spacing: 12) {
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
                Text("Stopped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .starting, .waiting, .loadingModel, .working:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(run.statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Stop") { run.cancel() }
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
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Open a book to hear voices reading it.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Open a Book…") { model.openWithPanel() }
                .accessibilityLabel("Open a book")
        }
        .padding(8)
    }
}
