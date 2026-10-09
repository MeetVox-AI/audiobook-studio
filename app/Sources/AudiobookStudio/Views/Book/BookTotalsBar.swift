import SwiftUI

/// Bottom bar of the book screen: selected sections, characters, estimated audio length, estimated
/// conversion time on this Mac (or the advice to measure it), and the Convert button.
struct BookTotalsBar: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft
    /// Problem that stops the conversion (shown next to the button, with a way to fix it).
    let blocker: BookBlocker?
    /// Why the last Convert failed (the engine's message; disk space shown prominently).
    let convertError: EngineError?
    let isStarting: Bool
    let onDismissError: () -> Void
    let onConvert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let convertError {
                BookErrorView(error: convertError, onDismiss: onDismissError)
            }
            HStack(alignment: .center, spacing: 16) {
                totals
                Spacer(minLength: 12)
                if let blocker {
                    blockerHint(blocker)
                }
                convertButton
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Totals

    private var totals: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(draft.selectionSummary) · \(Formatters.characters(draft.includedChars))")
                .font(.headline)
                .monospacedDigit()
            HStack(spacing: 14) {
                Label("\(Formatters.estimate(draft.includedEstSeconds)) of audio", systemImage: "headphones")
                    .help("Estimated listening time of the selected sections")
                    .accessibilityLabel("Estimated audio length \(Formatters.duration(draft.includedEstSeconds))")
                Label(model.estimateSummary, systemImage: model.estimate == nil ? "speedometer" : "clock")
                    .foregroundStyle(model.estimate == nil ? Color.secondary : Color.primary)
                    .help(model.estimate?.bookBasisText ?? "No speed has been measured on this Mac for this engine yet")
                    .accessibilityLabel(estimateAccessibilityLabel)
            }
            .font(.callout)
            if let estimate = model.estimate {
                Text(estimate.bookBasisText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var estimateAccessibilityLabel: String {
        guard let estimate = model.estimate else { return ConversionEstimate.unavailableMessage }
        return "Estimated conversion time on this Mac: \(Formatters.duration(estimate.seconds))"
    }

    // MARK: Convert

    private func blockerHint(_ blocker: BookBlocker) -> some View {
        HStack(spacing: 8) {
            Label(blocker.message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .trailing)
                .multilineTextAlignment(.trailing)
            if let title = blocker.fixTitle, let destination = blocker.fixDestination {
                Button(title) { model.selection = destination }
                    .accessibilityLabel(title.replacingOccurrences(of: "…", with: ""))
            }
        }
    }

    private var convertButton: some View {
        Button(action: onConvert) {
            HStack(spacing: 6) {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Starting…")
                } else {
                    Image(systemName: "waveform")
                        .accessibilityHidden(true)
                    Text("Convert")
                }
            }
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(blocker != nil || isStarting)
        .help(blocker?.message ?? "Make the audiobook in the background (⌘↩). You can close the window while it runs.")
        .accessibilityLabel(isStarting ? "Starting the conversion" : "Convert to an audiobook")
        .accessibilityHint("Starts the conversion in the background and shows its progress")
    }
}
