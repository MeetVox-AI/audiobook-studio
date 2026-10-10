import SwiftUI

/// A finished job: summary (audio length, chapters, size, conversion time, × real time, flagged chunks),
/// verification problems, and Play / Reveal in Finder / Open in Books / Convert again.
struct JobDonePanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let monitor: JobMonitor
    let job: JobStatus?
    /// Show the player's error only after Play was pressed here (the player is shared).
    @State private var triedToPlay = false
    /// Bumped once when the panel appears, to bounce the seal (not with Reduce Motion).
    @State private var celebrate = 0

    /// Label of the `done.flagged_chunks` figure in `JobResultSummary.items`.
    private static let flaggedLabel = "Flagged chunks"

    var body: some View {
        let state = monitor.state
        let result = monitor.result ?? job?.result
        let output = monitor.outputURL ?? job?.outputURL
        let problems = result?.verificationProblems ?? []
        let tint = OpsStyle.tint(for: state)
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            SurfaceCard(padding: Theme.Space.xl) {
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    Image(systemName: state == .doneWithProblems ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.system(size: 48, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        // A state tint used as a symbol colour: kept readable in dark mode (DESIGN.md).
                        .foregroundStyle(ReadableForeground(tint))
                        .symbolEffect(.bounce, value: celebrate)
                        .frame(width: 64, height: 64)
                        .background(tint.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                    Text(state == .doneWithProblems ? "Your audiobook is ready, with problems" : "Your audiobook is ready")
                        .font(.title.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                if let result {
                    // The flagged-chunks tile turns amber from the result's count, not from its icon.
                    let flagged = (result.flaggedChunks ?? 0) > 0
                    JobsTileGrid(minColumnWidth: 200) {
                        ForEach(JobResultSummary.items(result)) { item in
                            JobsStatTile(label: item.label, value: item.value, systemImage: item.systemImage,
                                         tint: flagged && item.label == Self.flaggedLabel ? Theme.warning : Theme.accent)
                        }
                    }
                }
                if let output {
                    fileSection(output)
                } else {
                    Text("The engine did not report where it saved the audiobook.")
                        .foregroundStyle(.secondary)
                }
                if let freed = result.flatMap(JobResultSummary.freedWork) {
                    Label(freed, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !problems.isEmpty {
                SurfaceCard("Problems found by the final check") {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text("The audiobook was made anyway. Listen to the parts mentioned, or convert again with other settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            if !reduceMotion { celebrate += 1 }
        }
    }

    @ViewBuilder
    private func fileSection(_ output: URL) -> some View {
        let exists = FileActions.exists(output)
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: "book.closed.fill", tint: Theme.accent, size: 36)
                Text(output.lastPathComponent)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.m)
            .insetSurface()
            .help(output.path)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audiobook file: \(output.lastPathComponent)")
            if !exists {
                OpsNotice(text: "The audiobook is no longer at \(output.path). It may have been moved, renamed or deleted.",
                          systemImage: "questionmark.folder", tint: Theme.warning)
            }
            JobsFlowLayout(spacing: Theme.Space.s + 2, lineSpacing: Theme.Space.s + 2) {
                let playing = model.player.isPlaying(output)
                Button {
                    triedToPlay = true
                    model.player.toggle(output)
                } label: {
                    Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .jobsCardButton(prominent: true)
                .disabled(!exists)
                .accessibilityLabel(playing ? "Stop playing the audiobook" : "Play the audiobook")

                Button {
                    FileActions.revealInFinder(output)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .jobsCardButton()
                .disabled(!exists)
                .accessibilityLabel("Show the audiobook file in Finder")

                Button {
                    FileActions.openInBooks(output)
                } label: {
                    Label("Open in Books", systemImage: "books.vertical")
                }
                .jobsCardButton()
                .disabled(!exists)
                .accessibilityLabel("Open the audiobook in Apple Books")
                .help("Adds the audiobook to Apple Books")

                if let job, let book = job.bookURL, FileActions.exists(book) {
                    Button {
                        Task { await model.convertAgain(job) }
                    } label: {
                        Label("Convert Again with Other Settings", systemImage: "slider.horizontal.3")
                    }
                    .jobsCardButton()
                    .accessibilityLabel("Open the book again to convert it with other settings")
                }
            }
            .controlSize(.large)
            if triedToPlay, let message = model.player.errorMessage, model.player.currentURL == nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
