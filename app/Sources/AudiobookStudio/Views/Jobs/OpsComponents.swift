import SwiftUI

// Small views shared by the Jobs, Job detail, Models, Benchmark and Settings screens.
// System colours and materials only, so they follow light and dark mode.

/// Colours for job states.
enum OpsStyle {
    static func tint(for state: JobState) -> Color {
        switch state {
        case .queued, .running: return .accentColor
        case .done: return .green
        case .doneWithProblems: return .orange
        case .failed: return .red
        case .cancelled, .interrupted, .unknown: return .secondary
        }
    }
}

/// An engine failure next to the control that caused it: the engine's message as is, plus a "Details"
/// disclosure with the stderr tail. "Not enough disk space" failures get a heading of their own.
struct OpsErrorBox: View {
    let error: EngineError
    var onDismiss: (() -> Void)?
    @State private var showDetails = false

    init(error: EngineError, onDismiss: (() -> Void)? = nil) {
        self.error = error
        self.onDismiss = onDismiss
    }

    private var tint: Color { error.isDiskSpace ? .red : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: error.isDiskSpace ? "externaldrive.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if error.isDiskSpace {
                        Text("Not enough disk space").font(.headline)
                    }
                    Text(error.message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss this message")
                    .help("Dismiss")
                }
            }
            if !error.stderrTail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.stderrTail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .accessibilityLabel("Engine log details")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// An info or warning line (engine `notice` events, book warnings, hints).
struct OpsNotice: View {
    let text: String
    var systemImage = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Licence name plus a "NON-COMMERCIAL" badge for personal-use-only models.
struct OpsLicenseBadge: View {
    let license: String?
    let noncommercial: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let license, !license.isEmpty {
                Text(license)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if noncommercial {
                Text("NON-COMMERCIAL")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .help("Licensed for personal, non-commercial use only")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = license.map { "Licence: \($0)" } ?? "Licence unknown"
        return noncommercial ? "\(name). Non-commercial use only." : name
    }
}

/// Job state as a coloured label.
struct OpsStateBadge: View {
    let state: JobState

    var body: some View {
        Label(state.title, systemImage: state.systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(OpsStyle.tint(for: state))
            .accessibilityLabel("State: \(state.title)")
    }
}

/// A grid of labelled figures (job result, benchmark result).
struct OpsFigureGrid: View {
    let items: [JobSummaryItem]
    var minWidth: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), alignment: .topLeading)], alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.label, systemImage: item.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.label): \(item.value)")
            }
        }
    }
}

/// A titled card used to group parts of a screen.
struct OpsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
