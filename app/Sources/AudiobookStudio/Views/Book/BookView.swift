import AppKit
import SwiftUI

/// "New audiobook" screen (sidebar `.newBook`).
///
/// Without a book: a drop area with an Open button (window-wide drag and drop is handled by RootView),
/// progress while `inspect` runs and its error inline. With a book (`model.draft`): cover, title/author,
/// language, warnings, narrator and output folder, "Make a 2-minute sample", the section list and a totals
/// bar with the estimates and Convert (`convert --detach`; the app then shows the job).
struct BookView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let draft = model.draft {
                BookDraftScreen(draft: draft)
            } else {
                BookDropZone()
            }
        }
        .navigationTitle("New Audiobook")
    }
}

/// The book being prepared, and the flow around sample and Convert: licence sheet for non-commercial
/// engines, confirmation for engines slower than real time, then the engine call.
private struct BookDraftScreen: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft

    @State private var convertError: EngineError?
    @State private var isStartingConvert = false
    @State private var licenseRequest: BookLicenseRequest?
    /// Action to run once the licence sheet has fully closed (so a following alert can be shown).
    @State private var actionAfterLicense: BookPendingAction?
    @State private var slowWarning: BookSlowEngineWarning?
    @State private var dismissedBookErrorID: UUID?
    /// Section for "Make a 2-minute sample" (nil: the engine picks the first chapter).
    @State private var sampleSection: Int?
    /// The cover, loaded once for the header and the blurred hero backdrop behind it.
    @State private var coverImage: NSImage?
    /// The latest 2-minute sample started here, kept per window so it survives switching screens.
    @SceneStorage("BookView.sampleRunID") private var sampleRunID = ""
    @SceneStorage("BookView.sampleBookPath") private var sampleBookPath = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if model.isInspecting {
                    inspectingPill
                }
                if let error = model.bookError, error.id != dismissedBookErrorID {
                    BookErrorView(error: error) { dismissedBookErrorID = error.id }
                }
                if let job = activeJobForBook {
                    activeJobBanner(job)
                }
                BookHeaderView(draft: draft, cover: coverImage)
                BookNarratorPanel(draft: draft)
                BookSamplePanel(draft: draft, run: currentSample, section: $sampleSection,
                                blocker: model.bookBlocker(voice: model.voiceSelection, forConversion: false),
                                onStart: { perform(.sample(section: $0)) })
                BookSectionList(draft: draft) { index in
                    sampleSection = index
                    perform(.sample(section: index))
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .screenWidth()
            .background(alignment: .top) {
                // The blurred cover behind the hero header, spanning the whole width and reaching up under
                // the toolbar so the glow has no hard top edge; it scrolls with the content.
                HeroBackdrop(image: coverImage)
                    .frame(height: 560)
                    .offset(y: -160)
            }
        }
        .background(AmbientBackground())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BookTotalsBar(draft: draft,
                          blocker: model.bookBlocker(voice: model.voiceSelection, forConversion: true),
                          convertError: convertError,
                          isStarting: isStartingConvert,
                          onDismissError: { convertError = nil },
                          onConvert: { perform(.convert) })
        }
        .task(id: draft.coverURL) { coverImage = await BookCoverView.load(draft.coverURL) }
        .navigationSubtitle(draft.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openWithPanel()
                } label: {
                    Label("Open Another Book…", systemImage: "folder")
                }
                .help("Open another EPUB or PDF")
                .accessibilityLabel("Open another book")
                Button {
                    convertError = nil
                    model.closeBook()
                } label: {
                    Label("Close Book", systemImage: "xmark.circle")
                }
                .help("Close this book")
                .accessibilityLabel("Close this book")
            }
        }
        .sheet(item: $licenseRequest, onDismiss: {
            guard let action = actionAfterLicense else { return }
            actionAfterLicense = nil
            perform(action)
        }) { request in
            BookLicenseSheet(engine: request.engine) { actionAfterLicense = request.action }
        }
        .alert(slowWarning?.title ?? "", isPresented: slowWarningShown, presenting: slowWarning) { _ in
            Button("Convert Anyway") { Task { await convert() } }
                .accessibilityLabel("Convert anyway")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Cancel the conversion")
        } message: { warning in
            Text(warning.message)
        }
        .onChange(of: draft.url) { _, _ in
            convertError = nil
            sampleSection = nil
        }
    }

    /// The latest 2-minute sample of this book, if it is still in `model.samples`.
    private var currentSample: SampleRun? {
        guard sampleBookPath == draft.url.path, !sampleRunID.isEmpty else { return nil }
        return model.samples.first { $0.id.uuidString == sampleRunID }
    }

    /// A queued or running conversion of this book.
    private var activeJobForBook: JobStatus? {
        model.jobs.first { $0.book == draft.url.path && model.liveState(of: $0).isActive }
    }

    /// "Reading the new book…" while another book is being opened over this one.
    private var inspectingPill: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text("Reading the new book…")
                .font(.callout)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reading the new book")
    }

    private func activeJobBanner(_ job: JobStatus) -> some View {
        InlineBanner(systemImage: "waveform", tint: Theme.accent) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("This book is being converted.")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Show Progress") { model.selection = .job(job.jobId) }
                    .bookCardButton()
                    .controlSize(.small)
                    .accessibilityLabel("Show the conversion progress")
            }
        }
    }

    private var slowWarningShown: Binding<Bool> {
        Binding(get: { slowWarning != nil }, set: { if !$0 { slowWarning = nil } })
    }

    // MARK: Actions

    /// Runs the licence check (and, for Convert, the slow-engine check) before the action itself.
    /// Does nothing while something blocks the action (its reason is shown above the Convert bar and in the
    /// sample button's help).
    private func perform(_ action: BookPendingAction) {
        let voice = model.voiceSelection
        guard model.bookBlocker(voice: voice, forConversion: action == .convert) == nil else { return }
        if case .sample = action, currentSample?.isRunning == true { return }
        if let engine = model.bookLicenseToAcknowledge(voice: voice) {
            licenseRequest = BookLicenseRequest(engine: engine, action: action)
            return
        }
        switch action {
        case .sample(let section):
            guard let run = model.startBookSample(section: section) else { return }
            sampleRunID = run.id.uuidString
            sampleBookPath = draft.url.path
        case .convert:
            if let voice, let warning = model.bookSlowEngineWarning(voice: voice, chars: draft.includedChars) {
                slowWarning = warning
                return
            }
            Task { await convert() }
        }
    }

    /// `convert --detach`; on success the model selects the job's screen.
    private func convert() async {
        guard !isStartingConvert else { return }
        isStartingConvert = true
        convertError = nil
        defer { isStartingConvert = false }
        do {
            try await model.startConvert()
        } catch {
            convertError = EngineError(error)
        }
    }
}
