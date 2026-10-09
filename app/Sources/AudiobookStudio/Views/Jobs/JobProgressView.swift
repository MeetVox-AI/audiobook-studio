import Charts
import SwiftUI

/// Live progress of a queued or running job: big percent bar, chapter and chunk, ETA range with its
/// basis, elapsed time, speed now against the average, and Cancel (with confirmation).
struct JobProgressPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor
    @State private var confirmCancel = false
    @State private var isCancelling = false
    @State private var cancelError: EngineError?
    @State private var elapsed: JobLiveElapsed?

    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Formatters.percent(monitor.percent))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isCancelling ? "Stopping…" : monitor.phase.title)
                            .font(.title3)
                        if let chapter = monitor.chapterText {
                            Text(chapter)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 12)
                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        Label("Cancel Conversion…", systemImage: "stop.fill")
                    }
                    .disabled(isCancelling)
                    .accessibilityLabel("Cancel this conversion")
                    .help("Stops the conversion. Finished chunks are kept so it can resume later.")
                }

                ProgressView(value: monitor.fraction)
                    .controlSize(.large)
                    .accessibilityLabel("Conversion progress")
                    .accessibilityValue("\(Formatters.percent(monitor.percent)) of the characters narrated")

                if case .encoding(let percent) = monitor.phase {
                    ProgressView(value: min(1, max(0, percent / 100))) {
                        Text("Encoding the audiobook file")
                            .font(.caption)
                    }
                    .accessibilityLabel("Encoding progress")
                    .accessibilityValue(Formatters.percent(percent))
                }
                if case .waitingForGPU = monitor.phase {
                    OpsNotice(text: "Another conversion, sample or benchmark is using the GPU. This one starts as soon as it is free.",
                              systemImage: "hourglass")
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    if let p = monitor.latestProgress, let chunk = p.chunk, let chunks = p.chunks {
                        figureRow("Chunk", systemImage: "square.stack.3d.up") {
                            Text("\(Formatters.count(chunk)) of \(Formatters.count(chunks)) in this chapter")
                                .monospacedDigit()
                        }
                    }
                    figureRow("Time left", systemImage: "hourglass") { etaView }
                    figureRow("Elapsed", systemImage: "timer") { elapsedView }
                    figureRow("Speed", systemImage: "speedometer") { speedView }
                    if let plan = monitor.plan, let summary = JobText.planSummary(plan) {
                        figureRow("This job", systemImage: "book") {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary)
                                if let reused = JobText.reused(plan) {
                                    Text(reused).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let cancelError {
                    OpsErrorBox(error: cancelError) { self.cancelError = nil }
                }
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

    // MARK: Figures

    private func figureRow<V: View>(_ label: String, systemImage: String, @ViewBuilder value: () -> V) -> some View {
        GridRow {
            Label(label, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var etaView: some View {
        if let eta = monitor.etaText, let progress = monitor.latestProgress {
            VStack(alignment: .leading, spacing: 2) {
                Text(eta)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                if let basis = JobText.etaBasis(progress.etaBasis) {
                    Text(basis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if monitor.latestProgress != nil {
            // Narration is over (assembling, encoding): the last narration estimate no longer applies.
            Text(monitor.phase.title)
                .foregroundStyle(.secondary)
        } else {
            Text("Appears once narration starts")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var elapsedView: some View {
        if let elapsed {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Formatters.clock(elapsed.seconds(at: context.date)))
                    .monospacedDigit()
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var speedView: some View {
        let progress = monitor.latestProgress
        let now = progress?.rateCps
        let average = progress?.runRateCps
        if now == nil && average == nil {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let now {
                        Text("Now \(Formatters.charsPerSecond(now))")
                    }
                    if let average {
                        Text("· average \(Formatters.charsPerSecond(average))")
                            .foregroundStyle(.secondary)
                    }
                    if let trend = JobSpeedTrend.compare(now: now, average: average), trend != .steady {
                        Label(trend.text, systemImage: trend.systemImage)
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .help(trend.text.prefix(1).uppercased() + trend.text.dropFirst())
                            .accessibilityLabel(trend.text)
                    }
                }
                .monospacedDigit()
                if let x = progress?.realtimeX {
                    Text(Formatters.realtime(x))
                        .foregroundStyle(.secondary)
                }
            }
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

/// "Speed over time" line chart (characters per second now and on average).
struct JobRateChartCard: View {
    let points: [RatePoint]
    let isLive: Bool

    var body: some View {
        OpsCard(isLive ? "Speed over time" : "Speed during the conversion") {
            if points.count < 2 {
                Text("The chart appears after a few measurements.")
                    .foregroundStyle(.secondary)
            } else {
                let minutes = JobRateChart.usesMinutes(points)
                Chart(JobRateChart.samples(points)) { sample in
                    LineMark(x: .value(minutes ? "Minutes" : "Seconds", sample.x),
                             y: .value("Characters per second", sample.charsPerSecond))
                        .foregroundStyle(by: .value("Series", sample.series))
                        .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale([JobRateChart.nowSeries: Color.accentColor,
                                            JobRateChart.averageSeries: Color.secondary])
                .chartXAxisLabel(minutes ? "Minutes since the start" : "Seconds since the start")
                .chartYAxisLabel("Characters/s")
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 180)
                .accessibilityLabel("Narration speed over time")
                .accessibilityValue(JobRateChart.accessibilitySummary(points))
            }
        }
    }
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
            OpsCard("Quality check") {
                if let qa {
                    Label(qa, systemImage: "waveform.badge.magnifyingglass")
                        .accessibilityLabel("Speech check: \(qa)")
                }
                if let redos {
                    Label(redos, systemImage: "arrow.triangle.2.circlepath")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if flagged == 0 {
                    Label("No flagged chunks", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup(isExpanded: $showFlagged) {
                        VStack(alignment: .leading, spacing: 10) {
                            if monitor.flaggedChunks.isEmpty {
                                Text("The details of these chunks are not in the job’s log.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(monitor.flaggedChunks.enumerated()), id: \.offset) { _, chunk in
                                FlaggedChunkRow(chunk: chunk, location: JobText.flaggedLocation(chunk, plan: monitor.plan))
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label(flagged == 1 ? "1 flagged chunk" : "\(Formatters.count(flagged)) flagged chunks",
                              systemImage: "exclamationmark.bubble")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityLabel(flagged == 1 ? "1 flagged chunk, show details" : "\(flagged) flagged chunks, show details")
                    Text("Flagged chunks may have missing or misread words. Listen to them in the finished audiobook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
                    .foregroundStyle(.orange)
            }
            if !chunk.text.isEmpty {
                Text(chunk.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Thermal state, power source and the keep-awake indicator while a job runs.
struct JobMachineStatusCard: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor

    var body: some View {
        let system = model.system
        OpsCard("This Mac") {
            HStack(spacing: 20) {
                Label("Temperature: \(system.thermalState.title)", systemImage: system.thermalState.systemImage)
                    .foregroundStyle(system.thermalState.isThrottling ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                Label(system.powerSource.title, systemImage: system.powerSource.systemImage)
                    .foregroundStyle(system.isOnBattery ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                if monitor.isKeepingAwake {
                    Label("Keeping your Mac awake", systemImage: "cup.and.saucer")
                        .help("Your Mac will not go to sleep on its own until the conversion ends.")
                }
            }
            .font(.callout)
            if let explanation = system.thermalState.explanation {
                OpsNotice(text: explanation, systemImage: "thermometer.high", tint: .orange)
            }
            if system.isOnBattery {
                OpsNotice(text: "Your Mac is running on battery: the conversion is slower and drains the battery. Plug in the power adapter to finish sooner.",
                          systemImage: "battery.25", tint: .orange)
            }
            Text("The conversion keeps running if you close this window or quit Audiobook Studio; it is followed again when you reopen the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
