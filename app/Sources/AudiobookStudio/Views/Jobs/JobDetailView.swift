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
            } else {
                ContentUnavailableView {
                    Label("Job not found", systemImage: "questionmark.folder")
                } description: {
                    Text("The engine no longer lists this job. Its folder may have been deleted when disk space was freed.")
                } actions: {
                    Button("Show All Jobs") { model.selection = .jobs }
                        .accessibilityLabel("Show all jobs")
                    Button("Refresh") {
                        Task { await model.refreshJobs() }
                    }
                    .accessibilityLabel("Refresh the job list")
                }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Title, author, narrator, state and start date.
private struct JobHeader: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor
    let job: JobStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(monitor.displayTitle)
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let author = monitor.author ?? job?.author, !author.isEmpty {
                Text("by \(author)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                OpsStateBadge(state: monitor.state)
                let narration = model.opsNarration(engine: job?.engine ?? monitor.engineName, voice: job?.voice ?? monitor.voice,
                                                   language: job?.lang ?? monitor.lang)
                if !narration.isEmpty {
                    Label(narration, systemImage: "person.wave.2")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel("Narration: \(narration)")
                }
                if let started = job?.startedDate {
                    Label("Started \(JobText.date(started))", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .font(.callout)
        }
    }
}

/// Engine notices and the plan's warnings.
private struct JobNotices: View {
    let monitor: JobMonitor

    var body: some View {
        let warnings = monitor.plan?.warnings ?? []
        if !monitor.notices.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(monitor.notices.enumerated()), id: \.offset) { _, notice in
                    OpsNotice(text: notice, systemImage: "info.circle.fill", tint: .accentColor)
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    OpsNotice(text: warning, systemImage: "exclamationmark.triangle", tint: .orange)
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
        OpsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(JobText.stoppedTitle(state), systemImage: state.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(OpsStyle.tint(for: state))
                    .accessibilityAddTraits(.isHeader)
                message(for: state)
                if let progress = progressText {
                    Text(progress)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let job, state.canResume, job.argv != nil {
                        Button {
                            requestResume(job)
                        } label: {
                            Label("Resume Conversion", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
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
                        .accessibilityLabel("Open the book again to choose other settings")
                    }
                    if isResuming {
                        ProgressView().controlSize(.small)
                    }
                }
                if let actionError {
                    OpsErrorBox(error: actionError) { self.actionError = nil }
                }
            }
        }
        .sheet(item: $resumeLicense) { request in
            // The sheet saves the acknowledgement itself, then the job resumes.
            BookLicenseSheet(engine: request.engine) { resume(request.job) }
        }
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
