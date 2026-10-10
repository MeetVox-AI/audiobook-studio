import SwiftUI

/// One job's screen (sidebar `.job(id)`): live progress while the job is queued or running, the
/// result once it is done, or what went wrong (with Resume) when it stopped.
///
/// The JobMonitor is created with `model.attachMonitor(jobId:)` from `.task`, never from `body`; it is
/// re-attached when the job list loads (app launch) so a job selected early still finds its monitor.
struct JobDetailView: View {
    @Environment(AppModel.self) private var model
    let jobId: String

    init(jobId: String) {
        self.jobId = jobId
    }

    var body: some View {
        let job = model.job(withId: jobId)
        Group {
            if let monitor = model.monitors[jobId] {
                // A resumed job gets a new monitor: start its screen state afresh.
                JobScreen(monitor: monitor, job: job)
                    .id(ObjectIdentifier(monitor))
            } else if job != nil || model.loading.contains(.jobs) {
                ProgressView("Reading the job’s progress…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AmbientBackground())
            } else {
                EmptyStateView(systemImage: "questionmark.folder", title: "Job not found",
                               message: "The engine no longer lists this job. Its folder may have been deleted when disk space was freed.") {
                    HStack(spacing: Theme.Space.m) {
                        Button("Show All Jobs") { model.selection = .jobs }
                            .jobsCardButton(prominent: true)
                            .accessibilityLabel("Show all jobs")
                        Button("Refresh") {
                            Task { await model.refreshJobs() }
                        }
                        .jobsCardButton()
                        .accessibilityLabel("Refresh the job list")
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AmbientBackground())
            }
        }
        .navigationTitle(model.monitors[jobId]?.displayTitle ?? job?.title ?? "Job")
        .task(id: AttachKey(jobId: jobId, isListed: job != nil)) {
            model.attachMonitor(jobId: jobId)
        }
    }
}

/// Re-runs the attach task when the job id changes or the job appears in the list.
private struct AttachKey: Hashable {
    let jobId: String
    let isListed: Bool
}

/// The scrolling job screen for one monitor.
private struct JobScreen: View {
    let monitor: JobMonitor
    let job: JobStatus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                JobHeader(monitor: monitor, job: job)
                JobNotices(monitor: monitor)
                if monitor.state.isActive {
                    JobProgressPanel(monitor: monitor)
                    JobRateChartCard(points: monitor.rateHistory, isLive: true)
                    JobQualityCard(monitor: monitor)
                    JobMachineStatusCard(monitor: monitor)
                } else if monitor.state.producedOutput {
                    JobDonePanel(monitor: monitor, job: job)
                    JobQualityCard(monitor: monitor)
                    if monitor.rateHistory.count > 1 {
                        JobRateChartCard(points: monitor.rateHistory, isLive: false)
                    }
                } else {
                    JobStoppedPanel(monitor: monitor, job: job)
                    JobQualityCard(monitor: monitor)
                    if monitor.rateHistory.count > 1 {
                        JobRateChartCard(points: monitor.rateHistory, isLive: false)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .screenWidth()
            .animation(reduceMotion ? nil : .smooth, value: monitor.state)
        }
        // A finished audiobook (without problems) gets a faint green glow; everything else keeps the indigo one.
        .background(AmbientBackground(tint: monitor.state == .done ? Theme.success : Theme.accent))
    }
}

/// Title, author, then chips for the state, the narration and the start date.
private struct JobHeader: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor
    let job: JobStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(monitor.displayTitle)
                    .font(Theme.screenTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let author = monitor.author ?? job?.author, !author.isEmpty {
                    Text("by \(author)")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            JobsFlowLayout {
                OpsStateBadge(state: monitor.state)
                let narration = model.opsNarration(engine: job?.engine ?? monitor.engineName, voice: job?.voice ?? monitor.voice,
                                                   language: job?.lang ?? monitor.lang)
                if !narration.isEmpty {
                    Chip(text: narration, systemImage: "person.wave.2", tint: .secondary)
                        .help(narration)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Narration: \(narration)")
                }
                if let started = job?.startedDate {
                    Chip(text: "Started \(JobText.date(started))", systemImage: "calendar", tint: .secondary)
                }
            }
        }
    }
}

/// Engine notices and the plan's warnings.
private struct JobNotices: View {
    let monitor: JobMonitor

    var body: some View {
        let warnings = monitor.plan?.warnings ?? []
        if !monitor.notices.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(Array(monitor.notices.enumerated()), id: \.offset) { _, notice in
                    OpsNotice(text: notice, systemImage: "info.circle.fill", tint: Theme.accent)
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    OpsNotice(text: warning, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                }
            }
        }
    }
}

/// A failed, cancelled or interrupted job: what happened, the engine log, Resume and Convert again.
private struct JobStoppedPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor
    let job: JobStatus?
    @State private var isResuming = false
    @State private var actionError: EngineError?
    @State private var resumeLicense: JobResumeLicenseRequest?

    var body: some View {
        let state = monitor.state
        let tint = OpsStyle.tint(for: state)
        SurfaceCard {
            HStack(alignment: .center, spacing: Theme.Space.m + 2) {
                IconBadge(systemImage: JobsStateSymbol.badge(for: state), tint: tint, size: 44)
                Text(JobText.stoppedTitle(state))
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            message(for: state)
            if let progress = progressText {
                HStack(spacing: Theme.Space.s + 2) {
                    ProgressRing(progress: monitor.fraction, lineWidth: 3.5, tint: tint)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    Text(progress)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if hasActions(state) {
                JobsFlowLayout(spacing: Theme.Space.s + 2, lineSpacing: Theme.Space.s + 2) {
                    if let job, state.canResume, job.argv != nil {
                        Button {
                            requestResume(job)
                        } label: {
                            Label("Resume Conversion", systemImage: "play.fill")
                        }
                        .jobsCardButton(prominent: true)
                        .disabled(isResuming)
                        .accessibilityLabel("Resume this conversion")
                        .help("Runs the same conversion again; finished chunks and chapters are reused.")
                    }
                    if let job, let book = job.bookURL, FileActions.exists(book) {
                        Button {
                            Task { await model.convertAgain(job) }
                        } label: {
                            Label("Convert Again with Other Settings", systemImage: "slider.horizontal.3")
                        }
                        .jobsCardButton()
                        .accessibilityLabel("Open the book again to choose other settings")
                    }
                    if isResuming {
                        ProgressView().controlSize(.small)
                    }
                }
                .controlSize(.large)
            }
            if let actionError {
                OpsErrorBox(error: actionError) { self.actionError = nil }
            }
        }
        .sheet(item: $resumeLicense) { request in
            // The sheet saves the acknowledgement itself, then the job resumes.
            BookLicenseSheet(engine: request.engine) { resume(request.job) }
        }
    }

    /// Resume, Convert Again or the resume spinner will show (the same conditions as the buttons in `body`).
    private func hasActions(_ state: JobState) -> Bool {
        guard let job else { return isResuming }
        let canResume = state.canResume && job.argv != nil
        let canConvertAgain = job.bookURL.map(FileActions.exists) ?? false
        return canResume || canConvertAgain || isResuming
    }

    @ViewBuilder
    private func message(for state: JobState) -> some View {
        switch state {
        case .failed:
            OpsErrorBox(error: EngineError(message: monitor.errorMessage ?? "The engine reported an error.",
                                           stderrTail: monitor.stderrTail ?? ""))
        case .interrupted:
            if let tail = monitor.stderrTail, !tail.isEmpty {
                OpsErrorBox(error: EngineError(message: monitor.errorMessage ?? JobMonitor.interruptedMessage, stderrTail: tail))
            } else {
                Text(monitor.errorMessage ?? JobMonitor.interruptedMessage)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cancelled:
            Text(monitor.cancelMessage ?? JobText.cancelledFallback)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text("The engine reports the state “\(state.engineValue)”, which this version of Audiobook Studio does not know.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Stopped at 43% · Chapter 2 of 3 — “I”".
    private var progressText: String? {
        guard monitor.percent > 0 else { return nil }
        var text = "Stopped at \(Formatters.percent(monitor.percent))"
        if let chapter = monitor.chapterText { text += " · \(chapter)" }
        return text
    }

    /// Resumes, after the licence sheet when the job's engine is non-commercial and not acknowledged yet.
    private func requestResume(_ job: JobStatus) {
        if let engine = model.licenseToAcknowledge(beforeResuming: job) {
            resumeLicense = JobResumeLicenseRequest(engine: engine, job: job)
            return
        }
        resume(job)
    }

    private func resume(_ job: JobStatus) {
        isResuming = true
        actionError = nil
        Task {
            do {
                try await model.resumeJob(job)
            } catch {
                actionError = EngineError(error)
            }
            isResuming = false
        }
    }
}
