import SwiftUI

// Small views shared by the Jobs, Job detail, Models, Benchmark and Settings screens.
// Built on the design system (Design/Theme.swift, Design/Components.swift), so they follow light and dark mode.

/// Colours for job states.
enum OpsStyle {
    static func tint(for state: JobState) -> Color {
        switch state {
        case .queued, .running: return Theme.accent
        case .done: return Theme.success
        case .doneWithProblems: return Theme.warning
        case .failed: return Theme.danger
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

    private var tint: Color { error.isDiskSpace ? Theme.danger : Theme.warning }

    var body: some View {
        OpsTintedBox(systemImage: error.isDiskSpace ? "externaldrive.badge.exclamationmark" : "exclamationmark.triangle.fill",
                     tint: tint) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
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
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                            .padding(Theme.Space.s)
                    }
                    .frame(maxHeight: 160)
                    .insetSurface(radius: Theme.Radius.control)
                    .padding(.top, Theme.Space.xs)
                }
                .font(.callout)
                .accessibilityLabel("Engine log details")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// An info or warning line (engine `notice` events, book warnings, hints).
struct OpsNotice: View {
    let text: String
    var systemImage = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        OpsTintedBox(systemImage: systemImage, tint: tint) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The soft tinted box behind OpsErrorBox and OpsNotice: InlineBanner's layout, padding and fill, without
/// its outline (InlineBanner is not meant for errors next to a control, and the design asks for almost no
/// strokes).
private struct OpsTintedBox<Content: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                // Like InlineBanner: an accent tint (engine notices) would be hard to read in dark mode.
                .foregroundStyle(ReadableForeground(tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.m + 2)
        .background(tint.opacity(0.11), in: .smooth(Theme.Radius.tile))
    }
}

/// Licence name plus a "NON-COMMERCIAL" badge for personal-use-only models. The two chips wrap onto
/// two lines when the row is narrow; a licence name too long for the line shows in full on hover.
struct OpsLicenseBadge: View {
    let license: String?
    let noncommercial: Bool

    var body: some View {
        JobsFlowLayout(spacing: 6, lineSpacing: Theme.Space.xs) {
            if let license, !license.isEmpty {
                Chip(text: license, tint: .secondary)
                    .help(license)
            }
            if noncommercial {
                Chip(text: "NON-COMMERCIAL", tint: Theme.warning)
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

/// Job state as a coloured capsule with the state's symbol.
struct OpsStateBadge: View {
    let state: JobState

    var body: some View {
        Chip(text: state.title, systemImage: state.systemImage, tint: OpsStyle.tint(for: state))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State: \(state.title)")
    }
}

/// A grid of labelled figures (job result, benchmark result) as stat tiles; tiles in a row share its height.
struct OpsFigureGrid: View {
    let items: [JobSummaryItem]
    var minWidth: CGFloat = 150

    var body: some View {
        JobsTileGrid(minColumnWidth: minWidth) {
            ForEach(items) { item in
                // Reads as "label: value" to VoiceOver.
                JobsStatTile(label: item.label, value: item.value, systemImage: item.systemImage)
            }
        }
    }
}

/// A titled card used to group parts of a screen (a solid surface card).
struct OpsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        SurfaceCard(title) {
            content
        }
    }
}
