import SwiftUI

/// "Jobs" screen (sidebar `.jobs`): every conversion the engine knows, in progress first.
/// Active rows show live progress and the ETA range from their JobMonitor; finished rows show the
/// outcome. Selecting a row opens the job screen (`model.selection = .job(id)`).
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var actionError: EngineError?
    @State private var jobToCancel: JobStatus?
    @State private var resumeLicense: JobResumeLicenseRequest?

    var body: some View {
        content
            .navigationTitle("Jobs")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await model.refreshJobs() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loading.contains(.jobs))
                    .accessibilityLabel("Refresh the job list")
                    .help("Ask the engine for the latest list of jobs")
                }
            }
            .task {
                await model.refreshJobs()
                model.reattachRunningJobs()
            }
            .confirmationDialog(cancelTitle, isPresented: cancelDialogShown, titleVisibility: .visible, presenting: jobToCancel) { job in
                Button("Stop Conversion", role: .destructive) { cancel(job) }
                    .accessibilityLabel("Stop this conversion")
                Button("Keep Converting", role: .cancel) {}
                    .accessibilityLabel("Keep converting")
            } message: { _ in
                Text("Finished chunks are kept, so you can resume later with the same settings.")
            }
            .sheet(item: $resumeLicense) { request in
                // The sheet saves the acknowledgement itself, then the job resumes.
                BookLicenseSheet(engine: request.engine) { resume(request.job) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.jobs.isEmpty {
            emptyState
        } else {
            List {
                if let error = model.errors[.jobs] {
                    OpsErrorBox(error: error)
                }
                if let actionError {
                    OpsErrorBox(error: actionError) { self.actionError = nil }
                }
                let active = model.jobsInProgress
                if !active.isEmpty {
                    Section("In progress") {
                        ForEach(active) { row($0) }
                    }
                }
                let finished = model.jobsFinished
                if !finished.isEmpty {
                    Section("Past conversions") {
                        ForEach(finished) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loading.contains(.jobs) {
            ProgressView("Loading jobs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errors[.jobs] {
            VStack(spacing: 12) {
                OpsErrorBox(error: error)
                Button("Try Again") {
                    Task { await model.refreshJobs() }
                }
                .accessibilityLabel("Try loading the job list again")
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No conversions yet", systemImage: "waveform")
            } description: {
                Text("Open a book and choose a voice to make your first audiobook. Conversions appear here while they run and after they finish.")
            } actions: {
                Button("New Audiobook") { model.selection = .newBook }
                    .accessibilityLabel("Start a new audiobook")
            }
        }
    }

    private func row(_ job: JobStatus) -> some View {
        Button {
            model.selection = .job(job.jobId)
        } label: {
            JobRow(job: job)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this conversion")
        .contextMenu { menu(for: job) }
    }

    @ViewBuilder
    private func menu(for job: JobStatus) -> some View {
        let state = model.liveState(of: job)
        let output = model.monitors[job.jobId]?.outputURL ?? job.outputURL
        Button("Show Details") { model.selection = .job(job.jobId) }
            .accessibilityLabel("Show this conversion")
        if state.producedOutput, let output, FileActions.exists(output) {
            Divider()
            Button(model.player.isPlaying(output) ? "Stop Playing" : "Play") { model.player.toggle(output) }
                .accessibilityLabel(model.player.isPlaying(output) ? "Stop playing the audiobook" : "Play the audiobook")
            Button("Reveal in Finder") { FileActions.revealInFinder(output) }
                .accessibilityLabel("Show the audiobook file in Finder")
            Button("Open in Books") { FileActions.openInBooks(output) }
                .accessibilityLabel("Open the audiobook in Apple Books")
        }
        if state.isActive {
            Divider()
            Button("Cancel Conversion…", role: .destructive) { jobToCancel = job }
                .accessibilityLabel("Cancel this conversion")
        } else if state.canResume, job.argv != nil {
            Divider()
            Button("Resume Conversion") { requestResume(job) }
                .accessibilityLabel("Resume this conversion")
        }
    }

    private var cancelTitle: String {
        "Stop converting “\(jobToCancel?.title ?? "this book")”?"
    }

    private var cancelDialogShown: Binding<Bool> {
        Binding(get: { jobToCancel != nil }, set: { if !$0 { jobToCancel = nil } })
    }

    private func cancel(_ job: JobStatus) {
        Task {
            do {
                try await model.cancelJob(job.jobId)
            } catch {
                actionError = EngineError(error)
            }
        }
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
        Task {
            do {
                try await model.resumeJob(job)
            } catch {
                actionError = EngineError(error)
            }
        }
    }
}

/// A Resume waiting for the licence sheet of the job's non-commercial engine.
struct JobResumeLicenseRequest: Identifiable {
    let engine: EngineInfo
    let job: JobStatus
    var id: String { job.jobId }
}

/// One job in the list: state icon, title, narration, live progress or outcome, start date.
private struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: JobStatus

    var body: some View {
        let state = model.liveState(of: job)
        let monitor = model.monitors[job.jobId]
        let line = JobText.listLine(job: job, monitor: monitor, state: state)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.systemImage)
                .font(.title2)
                .foregroundStyle(OpsStyle.tint(for: state))
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title(monitor))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let started = job.startedDate {
                        Text(JobText.date(started))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if state.isActive {
                    ProgressView(value: fraction(monitor))
                        .accessibilityHidden(true)
                }
                Text(line)
                    .font(.caption)
                    .foregroundStyle(state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title(monitor)), \(state.title). \(subtitle). \(line)")
    }

    private func title(_ monitor: JobMonitor?) -> String {
        if let t = job.title, !t.isEmpty { return t }
        return monitor?.displayTitle ?? "Untitled book"
    }

    private var subtitle: String {
        let narration = model.opsNarration(engine: job.engine, voice: job.voice, language: job.lang)
        guard let author = job.author, !author.isEmpty else { return narration }
        return narration.isEmpty ? author : "\(author) · \(narration)"
    }

    private func fraction(_ monitor: JobMonitor?) -> Double {
        if let monitor { return monitor.fraction }
        return min(1, max(0, (job.lastProgress?.percent ?? 0) / 100))
    }
}
