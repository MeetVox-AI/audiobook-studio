import SwiftUI

// Small layout and styling helpers shared by the Jobs, Job, Benchmark and Models screens (see app/DESIGN.md).

/// Lays its children out left to right and wraps them onto a new line when the width runs out, so
/// chip rows and button rows stay readable in narrow windows and with large text.
struct JobsFlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.s
    var lineSpacing: CGFloat = Theme.Space.s

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                let origin = CGPoint(x: x, y: y + (line.height - item.size.height) / 2)
                subviews[item.index].place(at: origin, anchor: .topLeading,
                                           proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    /// Greedy line breaking; a child wider than the whole line gets the full width (and truncates or wraps).
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.items.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
    }
}

/// The equal-height tile grid now lives in the design system (`TileGrid`).
typealias JobsTileGrid = TileGrid

/// A tile drawn like `StatTile` (icon and label, then its content, in an inset well) that fills the
/// height it is offered, so the tiles of one `JobsTileGrid` row line up.
struct JobsTile<Content: View>: View {
    let label: String
    var systemImage: String?
    var tint: Color = Theme.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        // Like StatTile: the tint in light mode; the secondary label colour in dark mode when the
                        // tint (the indigo accent by default) is hard to read.
                        .foregroundStyle(ReadableForeground(tint, fallback: .secondary))
                        .font(.callout.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            content
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insetSurface()
    }
}

/// `StatTile` (icon, label, big rounded value, optional caption) as a `JobsTile`, for a `JobsTileGrid`.
struct JobsStatTile: View {
    let label: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.accent
    var caption: String?
    /// What VoiceOver reads; by default "label: value" (". caption" added), like StatTile.
    var accessibilityText: String?

    var body: some View {
        JobsTile(label: label, systemImage: systemImage, tint: tint) {
            Text(value)
                .font(Theme.number(.title2))
                .contentTransition(.numericText())
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? caption.map { "\(label): \(value). \($0)" } ?? "\(label): \(value)")
    }
}

/// Symbols for a job's state inside a tinted badge (glyphs without their own circle or octagon).
enum JobsStateSymbol {
    static func badge(for state: JobState) -> String {
        switch state {
        case .queued: return "hourglass"
        case .running: return "waveform"
        case .done: return "checkmark"
        case .doneWithProblems: return "exclamationmark"
        case .failed: return "xmark"
        case .cancelled: return "stop.fill"
        case .interrupted: return "pause.fill"
        case .unknown: return "questionmark"
        }
    }
}

extension View {
    /// The capsule button look used inside content cards: `.borderedProminent` for the card's one
    /// primary action, `.bordered` for the others.
    @ViewBuilder
    func jobsCardButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
