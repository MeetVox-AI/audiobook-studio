import SwiftUI

/// Floating glass bar at the bottom of the book screen (placed with `.safeAreaInset(edge: .bottom)`):
/// selected sections and characters, estimated audio length, estimated conversion time on this Mac (or the
/// advice to measure it) with where that speed comes from, and the Convert button.
/// A failed Convert and the problem that blocks Convert are shown on solid banners just above the bar
/// (long text never sits on glass); the bar itself keeps only the figures and the button.
struct BookTotalsBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: BookDraft
    /// Problem that stops the conversion (shown on a banner just above the bar, with a way to fix it).
    let blocker: BookBlocker?
    /// Why the last Convert failed (the engine's message; disk space shown prominently).
    let convertError: EngineError?
    let isStarting: Bool
    let onDismissError: () -> Void
    let onConvert: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let convertError {
                floatingBanner(BookErrorView(error: convertError, onDismiss: onDismissError))
            }
            if let blocker {
                floatingBanner(blockerBanner(blocker))
                    .transition(.opacity)
            }
            GlassBar(spacing: Theme.Space.l) {
                totals
                Spacer(minLength: Theme.Space.m)
                convertButton
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: blocker)
    }

    /// A banner floating just above the glass bar, on a solid surface so its text never sits on glass.
    private func floatingBanner(_ banner: some View) -> some View {
        banner
            .background(Theme.surface, in: .smooth(Theme.Radius.tile))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: 14, y: 4)
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.s)
    }

    // MARK: Totals

    private var totals: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.l + 4) { figures }
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) { figures }
            }
            if let estimate = model.estimate {
                Text(estimate.bookBasisText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(estimate.bookBasisText)
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: draft.included)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var figures: some View {
        BookTotalsFigure(systemImage: "checklist", value: draft.selectionSummary,
                         caption: Formatters.characters(draft.includedChars))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(draft.selectionSummary) · \(Formatters.characters(draft.includedChars))")
        BookTotalsFigure(systemImage: "headphones", value: Formatters.estimate(draft.includedEstSeconds),
                         caption: "of audio")
            .help("Estimated listening time of the selected sections")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Estimated audio length \(Formatters.duration(draft.includedEstSeconds))")
        if let estimate = model.estimate {
            BookTotalsFigure(systemImage: "clock", value: Formatters.estimate(estimate.seconds),
                             caption: "on this Mac")
                .help(estimate.bookBasisText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(estimateAccessibilityLabel)
        } else {
            BookTotalsFigure(systemImage: "speedometer", value: nil, caption: model.estimateSummary,
                             tint: .secondary)
                .help("No speed has been measured on this Mac for this engine yet")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(estimateAccessibilityLabel)
        }
    }

    private var estimateAccessibilityLabel: String {
        guard let estimate = model.estimate else { return ConversionEstimate.unavailableMessage }
        return "Estimated conversion time on this Mac: \(Formatters.duration(estimate.seconds))"
    }

    // MARK: Convert

    /// Why Convert is disabled, with the button that leads to the fix (the baseline's hint next to Convert).
    private func blockerBanner(_ blocker: BookBlocker) -> some View {
        InlineBanner(systemImage: "exclamationmark.circle.fill", tint: Theme.warning) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text(blocker.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = blocker.fixTitle, let destination = blocker.fixDestination {
                    Button(title) { model.selection = destination }
                        .bookCardButton()
                        .controlSize(.small)
                        .accessibilityLabel(title.replacingOccurrences(of: "…", with: ""))
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .contain)
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
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(blocker != nil || isStarting)
        .help(blocker?.message ?? "Make the audiobook in the background (⌘↩). You can close the window while it runs.")
        .accessibilityLabel(isStarting ? "Starting the conversion" : "Convert to an audiobook")
        .accessibilityHint("Starts the conversion in the background and shows its progress")
    }
}

/// One compact figure of the totals bar: a tinted symbol, a rounded number and a small caption below it
/// (or only a sentence when there is no number).
/// Dark mode: a tint that is hard to read (the indigo accent) draws the symbol in the primary label colour, so the
/// accent figures still stand apart from the deliberately grey (`.secondary`) speedometer figure, as in light mode.
private struct BookTotalsFigure: View {
    let systemImage: String
    let value: String?
    let caption: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(ReadableForeground(tint))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if let value {
                    Text(value)
                        .font(Theme.number(.headline))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
