import SwiftUI

/// The narrator chosen for this book (changed on the Voices screen), the speech check option and
/// where the audiobook will be saved.
struct BookNarratorPanel: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft

    var body: some View {
        BookCard(title: "Narrator and output", systemImage: "person.wave.2") {
            voiceRow
            if model.voiceSelection != nil {
                speechCheck
            }
            if let warning = model.bookVoiceWarning(voice: model.voiceSelection, language: draft.language) {
                Label {
                    Text(warning.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
            Divider()
            outputRow
        }
    }

    // MARK: Voice

    private var voiceRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(voiceName)
                        .font(.body.weight(.medium))
                    if let engine = model.bookSelectedEngine, engine.noncommercial {
                        BookLicenseBadge(text: "NON-COMMERCIAL",
                                         help: "\(engine.name) is licensed for non-commercial use only (\(engine.license))")
                    } else if model.bookVoiceIsPersonalUseOnly(model.voiceSelection) {
                        BookLicenseBadge(text: "PERSONAL USE",
                                         help: "This voice's licence does not allow commercial use")
                    }
                }
                if let detail = voiceDetail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(model.voiceSelection == nil ? "Choose Voice…" : "Change Voice…") {
                model.selection = .voices
            }
            .accessibilityLabel(model.voiceSelection == nil ? "Choose a voice" : "Change the voice")
            .accessibilityHint("Opens the Voices screen")
        }
    }

    private var voiceName: String {
        guard let voice = model.voiceSelection else {
            return model.loading.contains(.engines) ? "Loading voices…" : "No voice chosen"
        }
        return voice.displayName(engines: model.engines, voices: model.voices)
    }

    /// "Speed 1.25× · Measured on this Mac: 3.3× real time".
    private var voiceDetail: String? {
        guard let voice = model.voiceSelection else {
            return "Pick a narrator on the Voices screen."
        }
        var parts: [String] = []
        if abs(voice.speed - 1) > 0.001 { parts.append("Speed \(Formatters.multiplier(voice.speed))") }
        if let measured = model.engineList?.measurement(engine: voice.engineId, voice: voice.voiceId),
           let x = measured.measurement.realtimeX {
            let whose = measured.exactVoice ? "" : " (another voice of this engine)"
            parts.append("Measured on this Mac: \(Formatters.realtime(x))\(whose)")
        } else if model.engineList != nil {
            parts.append("Not measured on this Mac yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var speechCheck: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Check every sentence with speech recognition", isOn: verifyBinding)
                .toggleStyle(.checkbox)
                .accessibilityLabel("Check every sentence with speech recognition")
                .accessibilityHint("About 15 percent more time. Sentences that do not match the text are narrated again.")
            Text("About +15% time. Sentences that do not match the text are narrated again, or flagged for you to check.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    private var verifyBinding: Binding<Bool> {
        Binding(get: { model.voiceSelection?.verify ?? false }, set: { model.voiceSelection?.verify = $0 })
    }

    // MARK: Output

    @ViewBuilder
    private var outputRow: some View {
        if let location = model.bookOutputLocation {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Save to: \(location.title)")
                    Text(location.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(location.folderURL.path)
                    if location.isCustom && !FileActions.exists(location.folderURL) {
                        Label("This folder does not exist. Choose another one.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("AAC \(model.settings.bitrateKbps) kbps .m4b with chapters (quality is set in Settings)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Button("Choose…") { model.chooseBookOutputFolder() }
                    .accessibilityLabel("Choose the folder for the audiobook")
                if location.isCustom {
                    Button("Next to the Book") { model.settings.outputFolder = nil }
                        .accessibilityLabel("Save the audiobook next to the book")
                }
            }
        }
    }
}
