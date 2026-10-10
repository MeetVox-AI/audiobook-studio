import Charts
import SwiftUI

/// Live progress of a queued or running job: a large progress ring, the ETA range with its basis, the
/// phase and chapter, Cancel (with confirmation), then stat tiles for chunk, elapsed time, speed now
/// against the average, real-time factor, and what the job narrates.
struct JobProgressPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let monitor: JobMonitor
    @State private var confirmCancel = false
    @State private var isCancelling = false
    @State private var cancelError: EngineError?
    @State private var elapsed: JobLiveElapsed?

    var body: some View {
        SurfaceCard {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                progressRing
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    // Once narration is over (assembling, encoding) the last estimate no longer applies and
                    // the phase line below already says what is happening, so "Time left" is left out.
                    if monitor.etaText != nil || monitor.latestProgress == nil {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Label("Time left", systemImage: "hourglass")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            etaView
                        }
                        .accessibilityElement(children: .combine)
                    }
                    phaseLine
                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        Label("Cancel Conversion…", systemImage: "stop.fill")
                    }
                    .jobsCardButton()
                    .disabled(isCancelling)
                    .accessibilityLabel("Cancel this conversion")
                    .help("Stops the conversion. Finished chunks are kept so it can resume later.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .encoding(let percent) = monitor.phase {
                ProgressView(value: min(1, max(0, percent / 100))) {
                    Text("Encoding the audiobook file")
                        .font(.caption)
                }
                .tint(Theme.accent)
                .accessibilityLabel("Encoding progress")
                .accessibilityValue(Formatters.percent(percent))
            }
            if case .waitingForGPU = monitor.phase {
                OpsNotice(text: "Another conversion, sample or benchmark is using the GPU. This one starts as soon as it is free.",
                          systemImage: "hourglass")
            }

            // Wide columns: up to four tiles sit in a 2 × 2 grid, and "Now 61 characters/s" stays on one line.
            // Tiles in a row share its height, so the Chunk caption and the Speed average line do not leave
            // the tile beside them shorter.
            JobsTileGrid(minColumnWidth: 260) {
                if let p = monitor.latestProgress, let chunk = p.chunk, let chunks = p.chunks {
                    let of = "\(Formatters.count(chunk)) of \(Formatters.count(chunks))"
                    JobsStatTile(label: "Chunk", value: of, systemImage: "square.stack.3d.up",
                                 caption: "In this chapter", accessibilityText: "Chunk: \(of) in this chapter")
                }
                elapsedTile
                JobSpeedTile(progress: monitor.latestProgress)
                if let progress = monitor.latestProgress, progress.rateCps != nil || progress.runRateCps != nil,
                   let x = progress.realtimeX {
                    JobsStatTile(label: "Real time", value: Formatters.multiplier(x), systemImage: "hare",
                                 accessibilityText: Formatters.realtime(x))
                }
            }

            if let plan = monitor.plan, let summary = JobText.planSummary(plan) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Image(systemName: "book")
                        .symbolRenderingMode(.hierarchical)
                        // Drawn like a tile icon (StatTile): secondary in dark mode, where the accent is hard to read.
                        .foregroundStyle(ReadableForeground(Theme.accent, fallback: .secondary))
                        .font(.callout.weight(.semibold))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This job")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(summary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reused = JobText.reused(plan) {
                            Text(reused)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Theme.Space.m + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface()
                .accessibilityElement(children: .combine)
            }

            if let cancelError {
                OpsErrorBox(error: cancelError) { self.cancelError = nil }
            }
        }
        .onChange(of: reportedElapsed, initial: true) { _, value in
            elapsed = value.map { JobLiveElapsed(reported: $0, receivedAt: Date()) }
        }
        .confirmationDialog("Stop converting “\(monitor.displayTitle)”?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop Conversion", role: .destructive) { cancel() }
                .accessibilityLabel("Stop this conversion")
            Button("Keep Converting", role: .cancel) {}
                .accessibilityLabel("Keep converting")
        } message: {
            Text("Finished chunks are kept, so you can resume later with the same settings.")
        }
        .onChange(of: monitor.state) { _, state in
            if !state.isActive { isCancelling = false }
        }
    }

    // MARK: Hero

    private var progressRing: some View {
        ProgressRing(progress: monitor.fraction, lineWidth: 14) {
            Text(Formatters.percent(monitor.percent))
                .font(Theme.number(.largeTitle))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, Theme.Space.l + 4)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth, value: monitor.percent)
        }
        .frame(width: 150, height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conversion progress")
        .accessibilityValue("\(Formatters.percent(monitor.percent)) of the characters narrated")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The phase ("Narrating", "Loading the voice model…") with a working symbol, and the current chapter.
    private var phaseLine: some View {
        let waiting: Bool = {
            if case .waitingForGPU = monitor.phase { return true }
            return false
        }()
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: waiting ? "hourglass" : "waveform")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accentForeground)
                .font(.title3.weight(.semibold))
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && !waiting && !isCancelling)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isCancelling ? "Stopping…" : monitor.phase.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let chapter = monitor.chapterText {
                    Text(chapter)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var etaView: some View {
        if let eta = monitor.etaText, let progress = monitor.latestProgress {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(eta)
                    .font(Theme.number(.title, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .smooth, value: eta)
                if let basis = JobText.etaBasis(progress.etaBasis) {
                    Text(basis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("Appears once narration starts")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Figures

    @ViewBuilder
    private var elapsedTile: some View {
        if let elapsed {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                JobsStatTile(label: "Elapsed", value: Formatters.clock(elapsed.seconds(at: context.date)), systemImage: "timer")
            }
        } else {
            JobsStatTile(label: "Elapsed", value: "—", systemImage: "timer")
        }
    }

    /// Seconds since the run started, as last reported by the engine.
    private var reportedElapsed: Double? {
        let values = [monitor.latestProgress?.elapsedS, monitor.lastEventTime].compactMap { $0 }
        return values.max()
    }

    private func cancel() {
        isCancelling = true
        cancelError = nil
        Task {
            do {
                try await model.cancelJob(monitor.jobId)
            } catch {
                cancelError = EngineError(error)
                isCancelling = false
            }
        }
    }
}

/// Speed now (with a faster / slower arrow against the run's average) and the average below it,
/// drawn like a StatTile.
private struct JobSpeedTile: View {
    let progress: EngineEvent?

    var body: some View {
        let now = progress?.rateCps
        let average = progress?.runRateCps
        JobsTile(label: "Speed", systemImage: "speedometer") {
            if now == nil && average == nil {
                Text("Measuring…")
                    .font(Theme.number(.title2))
                    .foregroundStyle(.secondary)
            } else {
                if let now {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Now")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(Formatters.charsPerSecond(now))
                            .font(Theme.number(.title2))
                            .contentTransition(.numericText())
                            .fixedSize(horizontal: false, vertical: true)
                        if let trend = JobSpeedTrend.compare(now: now, average: average), trend != .steady {
                            Image(systemName: trend.systemImage)
                                .font(.callout.weight(.bold))
                                .foregroundStyle(.secondary)
                                .help(trend.text.prefix(1).uppercased() + trend.text.dropFirst())
                                .accessibilityLabel(trend.text)
                        }
                    }
                }
                if let average {
                    // Its own line (the main figure when speed now is not known yet), so it starts with a capital.
                    Text("Average \(Formatters.charsPerSecond(average))")
                        .font(now == nil ? Theme.number(.title2) : .caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Speed over time" chart: speed now as a line over a soft gradient area, the run's average as a
/// dashed line.
struct JobRateChartCard: View {
    let points: [RatePoint]
    let isLive: Bool

    var body: some View {
        SurfaceCard(isLive ? "Speed over time" : "Speed during the conversion", systemImage: "chart.xyaxis.line") {
            if points.count < 2 {
                Text("The chart appears after a few measurements.")
                    .foregroundStyle(.secondary)
            } else {
                let minutes = JobRateChart.usesMinutes(points)
                let samples = JobRateChart.samples(points)
                let xName = minutes ? "Minutes" : "Seconds"
                Chart {
                    ForEach(samples.filter { $0.series == JobRateChart.nowSeries }) { sample in
                        AreaMark(x: .value(xName, sample.x),
                                 y: .value("Characters per second", sample.charsPerSecond))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    ForEach(samples) { sample in
                        LineMark(x: .value(xName, sample.x),
                                 y: .value("Characters per second", sample.charsPerSecond))
                            .foregroundStyle(by: .value("Series", sample.series))
                            .interpolationMethod(.monotone)
                            .lineStyle(sample.series == JobRateChart.averageSeries ? Self.averageStroke : Self.nowStroke)
                    }
                }
                .chartForegroundStyleScale([JobRateChart.nowSeries: Theme.accent,
                                            JobRateChart.averageSeries: Color.secondary])
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: Self.gridStroke)
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: Self.gridStroke)
                            .foregroundStyle(Color.secondary.opacity(0.25))
                        AxisValueLabel()
                    }
                }
                .chartXAxisLabel(minutes ? "Minutes since the start" : "Seconds since the start")
                .chartYAxisLabel("Characters/s")
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 200)
                .accessibilityLabel("Narration speed over time")
                .accessibilityValue(JobRateChart.accessibilitySummary(points))
            }
        }
    }

    private static let nowStroke = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
    private static let averageStroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4])
    private static let gridStroke = StrokeStyle(lineWidth: 0.5, dash: [2, 3])
}

/// Speech check counters, re-generated chunks and the flagged chunks (expandable, with text and issue).
struct JobQualityCard: View {
    let monitor: JobMonitor
    @State private var showFlagged = false

    var body: some View {
        let qa = JobText.qa(monitor.qa)
        let redos = JobText.redos(monitor.qaRedos)
        let flagged = monitor.flaggedCount
        if qa != nil || redos != nil || flagged > 0 {
            SurfaceCard("Quality check", systemImage: "checkmark.shield") {
                if let qa {
                    QualityLine(systemImage: "waveform.badge.magnifyingglass", tint: Theme.accent) {
                        Text(qa)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Speech check: \(qa)")
                }
                if let redos {
                    QualityLine(systemImage: "arrow.triangle.2.circlepath", tint: Theme.accent) {
                        Text(redos)
                    }
                    .accessibilityElement(children: .combine)
                }
                if flagged == 0 {
                    QualityLine(systemImage: "checkmark", tint: Theme.success) {
                        Text("No flagged chunks")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    DisclosureGroup(isExpanded: $showFlagged) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            if monitor.flaggedChunks.isEmpty {
                                Text("The details of these chunks are not in the job’s log.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(monitor.flaggedChunks.enumerated()), id: \.offset) { _, chunk in
                                FlaggedChunkRow(chunk: chunk, location: JobText.flaggedLocation(chunk, plan: monitor.plan))
                            }
                        }
                        .padding(.top, Theme.Space.s)
                    } label: {
                        QualityLine(systemImage: "exclamationmark.bubble", tint: Theme.warning) {
                            Text(flagged == 1 ? "1 flagged chunk" : "\(Formatters.count(flagged)) flagged chunks")
                                .foregroundStyle(Theme.warning)
                                .fontWeight(.medium)
                        }
                    }
                    .accessibilityLabel(flagged == 1 ? "1 flagged chunk, show details" : "\(flagged) flagged chunks, show details")
                    Text("Flagged chunks may have missing or misread words. Listen to them in the finished audiobook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A line of the quality card: a small tinted badge and its text.
private struct QualityLine<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            IconBadge(systemImage: systemImage, tint: tint, size: 28)
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FlaggedChunkRow: View {
    let chunk: FlaggedChunk
    let location: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(location)
                .font(.callout.weight(.medium))
            if !chunk.issues.isEmpty {
                Text(chunk.issues.joined(separator: "; "))
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !chunk.text.isEmpty {
                Text(chunk.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(radius: Theme.Radius.control)
        .insetSurface(radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }
}

/// Thermal state, power source and the keep-awake indicator while a job runs.
struct JobMachineStatusCard: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor

    var body: some View {
        let system = model.system
        SurfaceCard("This Mac", systemImage: "desktopcomputer") {
            JobsFlowLayout {
                Chip(text: "Temperature: \(system.thermalState.title)", systemImage: system.thermalState.systemImage,
                     tint: system.thermalState.isThrottling ? Theme.warning : .secondary)
                Chip(text: system.powerSource.title, systemImage: system.powerSource.systemImage,
                     tint: system.isOnBattery ? Theme.warning : .secondary)
                if monitor.isKeepingAwake {
                    Chip(text: "Keeping your Mac awake", systemImage: "cup.and.saucer", tint: Theme.accent)
                        .help("Your Mac will not go to sleep on its own until the conversion ends.")
                }
            }
            if let explanation = system.thermalState.explanation {
                OpsNotice(text: explanation, systemImage: "thermometer.high", tint: Theme.warning)
            }
            if system.isOnBattery {
                OpsNotice(text: "Your Mac is running on battery: the conversion is slower and drains the battery. Plug in the power adapter to finish sooner.",
                          systemImage: "battery.25", tint: Theme.warning)
            }
            Text("The conversion keeps running if you close this window or quit Audiobook Studio; it is followed again when you reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
