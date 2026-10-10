import SwiftUI

/// Engine picker: one card per engine from `engines`.
struct VoiceEngineCards: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VoiceSectionTitle("Engine", subtitle: "Each engine has its own voices, speed and licence. Speeds are measured on this Mac.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Space.l, alignment: .top)],
                      alignment: .leading, spacing: Theme.Space.l) {
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VoiceLicenseBadge(license: engine.license, noncommercial: engine.noncommercial)
                if engine.noncommercial {
                    Text("Audio made with it is for personal use only.")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(summary.capabilitiesText, systemImage: "person.2.wave.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            figures

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
            .voiceCapsuleButton()
            .controlSize(.large)
            .disabled(summary.isChosen || summary.selection == nil)
            .accessibilityLabel(summary.isChosen ? "\(engine.name) is in use" : "Use \(engine.name)")
        }
        .padding(Theme.Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hoverHighlight(radius: Theme.Radius.card)
        .surface()
        .overlay {
            if summary.isChosen {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(engine.name) engine\(summary.isChosen ? ", in use" : "")")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            IconBadge(systemImage: engineSymbol, tint: engine.noncommercial ? Theme.warning : Theme.accent, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Label(summary.languagesText, systemImage: "globe")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.xs)
            if summary.isChosen {
                Label("In use", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .font(.title2)
                    .accessibilityLabel("In use")
            }
        }
    }

    /// What the engine can do, as a symbol: presets and cloning, presets only, cloning only, one voice.
    private var engineSymbol: String {
        switch (engine.supportsPresets, engine.supportsCloning) {
        case (true, true): return "person.2.wave.2.fill"
        case (true, false): return "person.wave.2.fill"
        case (false, true): return "waveform.badge.mic"
        case (false, false): return "waveform"
        }
    }

    // MARK: Figures

    /// Speed on this Mac, the open book's estimate and the size on disk, as small figures.
    private var figures: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            speedFigure
            if model.draft != nil || installedBytes != nil {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    if model.draft != nil { bookFigure }
                    if let installedBytes {
                        VoiceEngineFigure(systemImage: "checkmark.seal.fill", tint: Theme.success, label: "Installed",
                                          value: Formatters.bytes(installedBytes),
                                          accessibilityText: "Installed · \(Formatters.bytes(installedBytes))")
                    }
                }
            }
        }
        // Ideal height only (the card stretches its spacer, not the tiles); tiles of a row share one height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var speedFigure: some View {
        let measurement = summary.rate?.measurement
        let value: String?
        let unit: String
        if let m = measurement, let x = m.realtimeX {
            value = Formatters.multiplier(x)
            unit = "real time on this Mac"
        } else if let m = measurement {
            value = Formatters.charsPerSecond(m.charsPerS)
            unit = "on this Mac"
        } else {
            value = nil
            unit = "Speed not measured on this Mac yet"
        }
        return VoiceEngineFigure(systemImage: "speedometer", label: "Speed", value: value, unit: unit,
                                 detail: speedDetail, accessibilityText: "\(speedHeadline). \(speedDetail)")
    }

    private var bookFigure: some View {
        if let estimate = summary.bookEstimate {
            VoiceEngineFigure(systemImage: "clock", label: "This book", value: Formatters.estimate(estimate.seconds),
                              unit: "to convert", accessibilityText: bookEstimateText)
        } else {
            VoiceEngineFigure(systemImage: "clock", label: "This book", value: nil,
                              unit: "no estimate until the speed is measured", accessibilityText: bookEstimateText)
        }
    }

    /// Bytes on disk when the engine is installed and its size is known.
    private var installedBytes: Int64? {
        if case .installed(let bytes) = summary.install, bytes > 0 { return bytes }
        return nil
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

    // MARK: Install

    @ViewBuilder
    private var installRow: some View {
        switch summary.install {
        case .unknown:
            EmptyView()
        case .installed(let bytes):
            // The size is shown as a figure above; without a size only the state is shown.
            if bytes <= 0 {
                Label {
                    Text("Installed")
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.success)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        case .notInstalled(let gb):
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let download = model.modelDownloads[engine.id] {
                    ProgressView(value: download.fraction) {
                        Text(download.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Downloading \(engine.name)")
                    .accessibilityValue(Formatters.percent(download.fraction * 100))
                } else {
                    Button {
                        download()
                    } label: {
                        Label(gb.map { "Download \(Formatters.gigabytes($0))" } ?? "Download", systemImage: "arrow.down.circle")
                    }
                    .voiceCapsuleButton()
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

/// One small figure of an engine card: a labelled rounded number in a recessed tile, with the rest of
/// the sentence after it ("2.2×" + "real time on this Mac") and an optional detail line.
private struct VoiceEngineFigure: View {
    let systemImage: String
    var tint: Color = Theme.accent
    let label: String
    let value: String?
    var unit: String?
    var detail: String?
    /// The figure as one sentence for VoiceOver.
    let accessibilityText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    // Dark mode: a tint that is hard to read (the accent) becomes the label's secondary colour.
                    .foregroundStyle(ReadableForeground(tint, fallback: .secondary))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if let value {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs + 1) {
                        valueText(value)
                        if let unit { unitText(unit) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        valueText(value)
                        if let unit { unitText(unit).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            } else if let unit {
                Text(unit)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.m - 2)
        .padding(.vertical, Theme.Space.s + 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insetSurface(radius: Theme.Radius.control)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(Theme.number(.title3))
            .contentTransition(.numericText())
            .fixedSize(horizontal: false, vertical: true)
    }

    private func unitText(_ unit: String) -> some View {
        Text(unit)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
