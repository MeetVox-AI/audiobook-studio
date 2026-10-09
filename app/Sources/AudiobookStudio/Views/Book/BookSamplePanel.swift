import SwiftUI

/// "Make a 2-minute sample": narrates part of the book with the chosen voice, then plays it and shows
/// the speed measured on this Mac and the projected conversion time.
struct BookSamplePanel: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft
    /// The latest 2-minute sample of this book (nil before the first one).
    let run: SampleRun?
    /// Section to sample (nil: the engine picks the first chapter).
    @Binding var section: Int?
    /// Problem that stops a sample (no voice, model not downloaded...).
    let blocker: BookBlocker?
    /// Starts a sample of `section` (after the licence check).
    let onStart: (Int?) -> Void

    @State private var triedToPlay = false

    var body: some View {
        BookCard(title: "Hear it first", systemImage: "waveform.badge.magnifyingglass") {
            Text("Make a 2-minute sample to hear the voice on this book and measure the speed on this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls
            if let run {
                Divider()
                status(of: run)
            }
        }
    }

    // MARK: Start

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Sample from", selection: $section) {
                Text("First chapter (automatic)").tag(Int?.none)
                Divider()
                ForEach(draft.sections.filter { $0.chars > 0 }) { s in
                    Text(BookSamplePanel.menuTitle(s)).tag(Int?.some(s.index))
                }
            }
            .frame(maxWidth: 360)
            .accessibilityLabel("Section to sample")
            Button {
                onStart(section)
            } label: {
                Label("Make a 2-Minute Sample", systemImage: "play.circle")
            }
            .disabled(blocker != nil || run?.isRunning == true)
            .help(blocker?.message ?? "Narrates about two minutes of the chosen section with the chosen voice")
            .accessibilityLabel("Make a 2-minute sample")
            .accessibilityHint(blocker?.message ?? "Narrates about two minutes of the chosen section")
        }
    }

    /// Menu label of a section: "Chapter I." / "Chapter XII" (bare numbers get "Chapter") /
    /// "Project Gutenberg license (back)"; long titles are shortened to 60 characters.
    static func menuTitle(_ section: SectionInfo) -> String {
        var title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = "Section \(section.index)" }
        if section.sectionKind == .chapter, isBareNumber(title) { title = "Chapter \(title)" }
        let short = title.count > 60 ? String(title.prefix(59)) + "…" : title
        return section.sectionKind == .chapter ? short : "\(short) (\(section.sectionKind.title.lowercased()))"
    }

    /// "XII", "12", "IV." — a chapter title that is only a number.
    private static func isBareNumber(_ title: String) -> Bool {
        let core = title.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !core.isEmpty, core.count <= 8 else { return false }
        return core.allSatisfy { "IVXLCDM0123456789".contains($0) }
    }

    // MARK: Progress and result

    @ViewBuilder
    private func status(of run: SampleRun) -> some View {
        switch run.phase {
        case .starting, .waiting, .loadingModel, .working:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.statusText)
                    Text(voiceLine(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { run.cancel() }
                    .accessibilityLabel("Stop making the sample")
            }
            .accessibilityElement(children: .combine)
            notices(run)
        case .finished:
            if let result = run.result {
                finished(run, result: result)
            }
            notices(run)
        case .failed:
            if let error = run.error {
                BookErrorView(error: error)
            } else {
                Text("The sample failed.")
            }
            notices(run)
        case .cancelled:
            Label("Sample stopped.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func notices(_ run: SampleRun) -> some View {
        ForEach(Array(run.notices.enumerated()), id: \.offset) { _, notice in
            BookNoticeView(text: notice)
        }
    }

    private func finished(_ run: SampleRun, result: EngineEvent) -> some View {
        let projection = BookSampleProjection(result: result, draft: draft)
        let url = result.output.map { URL(fileURLWithPath: $0) } ?? run.outputURL
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let url {
                    let playing = model.player.isPlaying(url)
                    Button {
                        triedToPlay = true
                        model.player.toggle(url)
                    } label: {
                        Label(playing ? "Stop" : "Play Sample", systemImage: playing ? "stop.fill" : "play.fill")
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(playing ? "Stop the sample" : "Play the sample")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sampleTitle(result))
                        .font(.body.weight(.medium))
                    Text(voiceLine(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if let url, FileActions.exists(url) {
                    Button {
                        FileActions.revealInFinder(url)
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show the sample file in Finder")
                    .accessibilityLabel("Show the sample file in Finder")
                }
            }
            if triedToPlay, let message = model.player.errorMessage {
                Label(message, systemImage: "speaker.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Speed on this Mac")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(projection.speedText ?? "Not reported by the engine")
                }
                GridRow {
                    Text("Full conversion")
                        .foregroundStyle(.secondary)
                    Text(projection.projectionText(sectionCount: projection.coversCustomSelection ? draft.included.count : nil)
                        ?? "No projection: the engine did not report a speed")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if projection.reusedCachedAudio {
                Text("This sample was made before, so nothing was narrated this time: the speed is the one saved earlier on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(projection.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Chapter I. · 2:04".
    private func sampleTitle(_ result: EngineEvent) -> String {
        var parts: [String] = []
        if let title = result.title, !title.isEmpty { parts.append(title) }
        if let audio = result.audioS { parts.append(Formatters.clock(audio)) }
        return parts.isEmpty ? "Sample" : parts.joined(separator: " · ")
    }

    /// "Ryan · Qwen3-TTS 1.7B", plus "(not the current voice)" when the voice changed since.
    private func voiceLine(_ run: SampleRun) -> String {
        let name = run.voice.displayName(engines: model.engines, voices: model.voices)
        return run.voice == model.voiceSelection ? name : "\(name) (not the voice chosen now)"
    }
}
