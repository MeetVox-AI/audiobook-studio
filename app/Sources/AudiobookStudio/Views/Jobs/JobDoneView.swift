import SwiftUI

/// A finished job: summary (audio length, chapters, size, conversion time, × real time, flagged chunks),
/// verification problems, and Play / Reveal in Finder / Open in Books / Convert again.
struct JobDonePanel: View {
    @Environment(AppModel.self) private var model
    let monitor: JobMonitor
    let job: JobStatus?
    /// Show the player's error only after Play was pressed here (the player is shared).
    @State private var triedToPlay = false

    var body: some View {
        let state = monitor.state
        let result = monitor.result ?? job?.result
        let output = monitor.outputURL ?? job?.outputURL
        let problems = result?.verificationProblems ?? []
        VStack(alignment: .leading, spacing: 16) {
            OpsCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(state == .doneWithProblems ? "Your audiobook is ready, with problems" : "Your audiobook is ready",
                          systemImage: state.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(OpsStyle.tint(for: state))
                        .accessibilityAddTraits(.isHeader)
                    if let result {
                        OpsFigureGrid(items: JobResultSummary.items(result))
                    }
                    if let output {
                        fileSection(output)
                    } else {
                        Text("The engine did not report where it saved the audiobook.")
                            .foregroundStyle(.secondary)
                    }
                    if let freed = result.flatMap(JobResultSummary.freedWork) {
                        Text(freed)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !problems.isEmpty {
                OpsCard("Problems found by the final check") {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text("The audiobook was made anyway. Listen to the parts mentioned, or convert again with other settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ output: URL) -> some View {
        let exists = FileActions.exists(output)
        VStack(alignment: .leading, spacing: 10) {
            Label(output.lastPathComponent, systemImage: "book.closed")
                .font(.callout)
                .textSelection(.enabled)
                .help(output.path)
                .accessibilityLabel("Audiobook file: \(output.lastPathComponent)")
            if !exists {
                OpsNotice(text: "The audiobook is no longer at \(output.path). It may have been moved, renamed or deleted.",
                          systemImage: "questionmark.folder", tint: .orange)
            }
            HStack(spacing: 10) {
                let playing = model.player.isPlaying(output)
                Button {
                    triedToPlay = true
                    model.player.toggle(output)
                } label: {
                    Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!exists)
                .accessibilityLabel(playing ? "Stop playing the audiobook" : "Play the audiobook")

                Button {
                    FileActions.revealInFinder(output)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!exists)
                .accessibilityLabel("Show the audiobook file in Finder")

                Button {
                    FileActions.openInBooks(output)
                } label: {
                    Label("Open in Books", systemImage: "books.vertical")
                }
                .disabled(!exists)
                .accessibilityLabel("Open the audiobook in Apple Books")
                .help("Adds the audiobook to Apple Books")

                if let job, let book = job.bookURL, FileActions.exists(book) {
                    Button {
                        Task { await model.convertAgain(job) }
                    } label: {
                        Label("Convert Again with Other Settings", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Open the book again to convert it with other settings")
                }
            }
            if triedToPlay, let message = model.player.errorMessage, model.player.currentURL == nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
