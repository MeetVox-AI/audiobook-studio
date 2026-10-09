import SwiftUI

/// Engine picker: one card per engine from `engines`.
struct VoiceEngineCards: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VoiceSectionTitle("Engine", subtitle: "Each engine has its own voices, speed and licence. Speeds are measured on this Mac.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 14) {
                ForEach(model.engines) { engine in
                    VoiceEngineCard(summary: model.voiceEngineSummary(for: engine), perform: perform)
                }
            }
        }
    }
}

/// Name, licence, languages, measured speed, book estimate, install state and notes of one engine.
private struct VoiceEngineCard: View {
    @Environment(AppModel.self) private var model
    let summary: VoiceEngineSummary
    let perform: (VoiceAction) -> Void
    @State private var downloadError: EngineError?

    private var engine: EngineInfo { summary.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(engine.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if summary.isChosen {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("In use")
                }
            }

            VoiceLicenseBadge(license: engine.license, noncommercial: engine.noncommercial)
            if engine.noncommercial {
                Text("Audio made with it is for personal use only.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(summary.languagesText, systemImage: "globe")
                Label(summary.capabilitiesText, systemImage: "person.2.wave.2")
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(speedHeadline)
                        Text(speedDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "speedometer")
                }
                .accessibilityElement(children: .combine)
                if model.draft != nil {
                    Label(bookEstimateText, systemImage: "clock")
                }
            }
            .font(.callout)

            if let slow = summary.slowWarning {
                VoiceWarningLine(slow, systemImage: "tortoise.fill")
            }

            installRow

            if let notes = engine.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                guard let selection = summary.selection else { return }
                perform(.select(selection))
            } label: {
                Text(summary.isChosen ? "In Use" : "Use \(engine.name)")
                    .frame(maxWidth: .infinity)
            }
            .disabled(summary.isChosen || summary.selection == nil)
            .accessibilityLabel(summary.isChosen ? "\(engine.name) is in use" : "Use \(engine.name)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(summary.isChosen ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: summary.isChosen ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(engine.name) engine\(summary.isChosen ? ", in use" : "")")
    }

    /// "3.3× real time on this Mac", or that it was never measured.
    private var speedHeadline: String {
        guard let m = summary.rate?.measurement else { return "Speed not measured on this Mac yet" }
        if let x = m.realtimeX { return "\(Formatters.realtime(x)) on this Mac" }
        return "\(Formatters.charsPerSecond(m.charsPerS)) on this Mac"
    }

    /// "Ryan · 44 characters/s", "Measured with French female · 30 characters/s".
    private var speedDetail: String {
        guard let rate = summary.rate else { return "Make a preview or run a benchmark to measure it." }
        var parts: [String] = []
        if let name = summary.rateVoiceName {
            parts.append(summary.rateIsExactVoice ? name : "Measured with \(name)")
        }
        if rate.measurement.realtimeX != nil { parts.append(Formatters.charsPerSecond(rate.measurement.charsPerS)) }
        return parts.joined(separator: " · ")
    }

    private var bookEstimateText: String {
        guard let estimate = summary.bookEstimate else { return "This book: no estimate until the speed is measured" }
        return "This book: \(Formatters.estimate(estimate.seconds)) to convert"
    }

    @ViewBuilder
    private var installRow: some View {
        switch summary.install {
        case .unknown:
            EmptyView()
        case .installed(let bytes):
            Label(bytes > 0 ? "Installed · \(Formatters.bytes(bytes))" : "Installed", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .notInstalled(let gb):
            VStack(alignment: .leading, spacing: 6) {
                if let download = model.modelDownloads[engine.id] {
                    ProgressView(value: download.fraction) {
                        Text(download.statusText)
                            .font(.caption)
                    }
                    .accessibilityLabel("Downloading \(engine.name)")
                    .accessibilityValue(Formatters.percent(download.fraction * 100))
                } else {
                    Button {
                        download()
                    } label: {
                        Label(gb.map { "Download \(Formatters.gigabytes($0))" } ?? "Download", systemImage: "arrow.down.circle")
                    }
                    .help("Downloads the model files of \(engine.name) (the only step that uses the internet)")
                    .accessibilityLabel("Download \(engine.name)\(gb.map { ", \(Formatters.gigabytes($0))" } ?? "")")
                }
                if let downloadError { VoiceErrorNote(error: downloadError) }
            }
        }
    }

    private func download() {
        downloadError = nil
        let id = engine.id
        Task {
            do { try await model.downloadModel(id) } catch { downloadError = EngineError(error) }
        }
    }
}
