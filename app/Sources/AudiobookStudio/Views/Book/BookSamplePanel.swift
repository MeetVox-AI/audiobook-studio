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
        SurfaceCard("Hear it first", systemImage: "waveform.badge.magnifyingglass") {
            Text("Make a 2-minute sample to hear the voice on this book and measure the speed on this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls
            if let run {
                status(of: run)
            }
        }
    }

    // MARK: Start

    /// True when a finished sample is shown: its Play button is then the card's primary action.
    private var hasFinishedSample: Bool { run?.phase == .finished && run?.result != nil }

    private var controls: some View {
        HStack(spacing: Theme.Space.m) {
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
                Label("Make a 2-Minute Sample", systemImage: "waveform")
            }
            .bookCardButton(prominent: !hasFinishedSample)
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
            HStack(spacing: Theme.Space.m) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.statusText)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(voiceLine(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { run.cancel() }
                    .bookCardButton()
                    .accessibilityLabel("Stop making the sample")
            }
            .padding(Theme.Space.m)
            .insetSurface()
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
        let speed = speedFigure(projection)
        let conversion = conversionFigure(projection)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                if let url {
                    playButton(url)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sampleTitle(result))
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
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
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("Show the sample file in Finder")
                    .accessibilityLabel("Show the sample file in Finder")
                }
            }
            .padding(Theme.Space.m)
            .insetSurface()

            if triedToPlay, let message = model.player.errorMessage {
                Label(message, systemImage: "speaker.slash")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            }

            StatGrid(minWidth: 220) {
                if let speed {
                    StatTile(label: "Speed on this Mac", value: speed.value, systemImage: "speedometer",
                             caption: speed.caption)
                } else {
                    BookUnreportedFigure(label: "Speed on this Mac", systemImage: "speedometer",
                                         message: "Not reported by the engine")
                }
                if let conversion {
                    StatTile(label: "Full conversion", value: conversion.value, systemImage: "clock",
                             caption: conversion.caption)
                } else {
                    BookUnreportedFigure(label: "Full conversion", systemImage: "clock",
                                         message: "No projection: the engine did not report a speed")
                }
            }

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

    /// The round, prominent Play / Stop button of the finished sample.
    private func playButton(_ url: URL) -> some View {
        let playing = model.player.isPlaying(url)
        return Button {
            triedToPlay = true
            model.player.toggle(url)
        } label: {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(.title3.weight(.semibold))
                .frame(width: 30, height: 30)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(playing ? "Stop" : "Play Sample")
        .accessibilityLabel(playing ? "Stop the sample" : "Play the sample")
    }

    /// "43.5 characters/s" with "3.3× real time" below (`projection.speedText` split for the tile);
    /// nil when the engine reported no speed.
    private func speedFigure(_ projection: BookSampleProjection) -> (value: String, caption: String?)? {
        guard let cps = projection.charsPerSecond else { return nil }
        return (Formatters.charsPerSecond(cps), projection.realtimeX.map(Formatters.realtime))
    }

    /// "≈ 4 h 30 min" with "for the 61 selected sections (705,384 characters)" below
    /// (`projection.projectionText` split for the tile); nil when there is no projection.
    private func conversionFigure(_ projection: BookSampleProjection) -> (value: String, caption: String?)? {
        let sectionCount = projection.coversCustomSelection ? draft.included.count : nil
        guard let seconds = projection.projectedSeconds,
              let text = projection.projectionText(sectionCount: sectionCount) else { return nil }
        let head = Formatters.estimate(seconds)
        // `projectionText` starts with the same estimate; keep the whole sentence below the number otherwise.
        guard text.hasPrefix(head) else { return (head, text) }
        let rest = text.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
        return (head, rest.isEmpty ? nil : rest)
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

/// A sample figure the engine did not report: the same header as a `StatTile` (icon and label) with the
/// sentence as plain text instead of the large number font.
private struct BookUnreportedFigure: View {
    let label: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.callout.weight(.semibold))
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .insetSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(message)")
    }
}
