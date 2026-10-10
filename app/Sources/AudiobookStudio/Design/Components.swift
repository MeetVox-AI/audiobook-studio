import AppKit
import SwiftUI

// Reusable building blocks of the design system (see app/DESIGN.md).
// Content sits on solid surfaces; Liquid Glass is only used for controls that float above content.

// MARK: - Surfaces

/// A solid, rounded content card with an optional header (icon, title, accessory on the right).
struct SurfaceCard<Accessory: View, Content: View>: View {
    var title: String?
    var systemImage: String?
    var padding: CGFloat = Theme.Space.l + 4
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String? = nil, systemImage: String? = nil, padding: CGFloat = Theme.Space.l + 4,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.padding = padding
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m + 2) {
            if title != nil || systemImage != nil {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.accentForeground)
                            .accessibilityHidden(true)
                    }
                    if let title {
                        Text(title)
                            .font(Theme.sectionTitle)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: Theme.Space.s)
                    accessory
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

extension SurfaceCard where Accessory == EmptyView {
    init(_ title: String? = nil, systemImage: String? = nil, padding: CGFloat = Theme.Space.l + 4,
         @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, padding: padding, accessory: { EmptyView() }, content: content)
    }
}

private struct SurfaceModifier: ViewModifier {
    var radius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: .smooth(radius))
            .overlay {
                if colorScheme == .dark {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline)
                }
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.06), radius: 10, y: 3)
    }
}

private struct InsetModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.background(Theme.inset, in: .smooth(radius))
    }
}

extension View {
    /// Puts the view on a solid card surface (white in light mode, raised grey in dark mode).
    func surface(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(SurfaceModifier(radius: radius))
    }

    /// A recessed well inside a card (tiles, inline lists).
    func insetSurface(radius: CGFloat = Theme.Radius.tile) -> some View {
        modifier(InsetModifier(radius: radius))
    }

    /// Centres a screen's content and limits its width.
    func screenWidth(_ width: CGFloat = Theme.contentWidth) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Page background

/// The page background: a neutral canvas with a very soft accent glow at the top, so the glass
/// bars above it have something to refract.
struct AmbientBackground: View {
    var tint: Color = Theme.accent

    var body: some View {
        ZStack {
            Theme.canvas
            LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.03), .clear],
                           startPoint: .top, endPoint: .center)
            RadialGradient(colors: [Theme.highlight.opacity(0.07), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A blurred copy of the cover that fades into the page (book header).
struct HeroBackdrop: View {
    let image: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 60, opaque: true)
                    // Dark mode: softer and less saturated, so a strongly coloured cover (a magenta one gave the
                    // whole header a purple wash) does not tint the labels on top of it.
                    .saturation(colorScheme == .dark ? 0.5 : 0.9)
                    .opacity(colorScheme == .dark ? 0.28 : 0.45)
                    .clipped()
                    .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Floating glass bar

/// A floating Liquid Glass bar for controls above content (bottom action bars, filter bars).
/// Place it with `.safeAreaInset(edge:)` so scrolling content passes underneath.
struct GlassBar<Content: View>: View {
    var spacing: CGFloat = Theme.Space.m
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                content
            }
            .padding(.horizontal, Theme.Space.l + 2)
            .padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity)
            // Dark mode: a slightly darker glass, so the small grey captions on it stay readable over the
            // content scrolling underneath.
            .glassEffect(colorScheme == .dark ? .regular.tint(.black.opacity(0.35)) : .regular,
                         in: .rect(cornerRadius: Theme.Radius.bar, style: .continuous))
        }
        // Same side margins and maximum width as the screen content, so the bar's edges line up with the cards.
        .padding(.horizontal, Theme.Space.xxl)
        .screenWidth()
        .padding(.bottom, Theme.Space.m)
        .padding(.top, Theme.Space.s)
    }
}

// MARK: - Headers

/// A section heading with an optional one-line explanation and an accessory on the right.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.m)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// The large title at the top of a scrolling screen, with an optional subtitle line.
struct ScreenHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.screenTitle)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.l)
            accessory
        }
    }
}

extension ScreenHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// The opening line of a screen whose name is already shown as the window title (Models, Benchmark):
/// an explanation in secondary text with an optional accessory on the right. Avoids repeating the title.
struct ScreenIntro<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    init(_ text: String, @ViewBuilder accessory: () -> Accessory) {
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

extension ScreenIntro where Accessory == EmptyView {
    init(_ text: String) {
        self.init(text) { EmptyView() }
    }
}

// MARK: - Figures

/// One key figure: an icon, a big rounded number and a small label.
struct StatTile: View {
    let label: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.accent
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(ReadableForeground(tint, fallback: .secondary))
                        .font(.callout.weight(.semibold))
                }
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insetSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(label): \(value). \($0)" } ?? "\(label): \(value)")
    }
}

/// An adaptive grid of stat tiles; the tiles of a row share its height.
struct StatGrid<Content: View>: View {
    var minWidth: CGFloat = 150
    @ViewBuilder var content: Content

    var body: some View {
        TileGrid(minColumnWidth: minWidth) {
            content
        }
    }
}

/// An adaptive grid of tiles (as many columns at least `minColumnWidth` wide as fit, sharing the width) where
/// every tile in a row is offered the row's height, so tiles that fill it (`StatTile`) line up even when one
/// has an extra line or a value wraps. (First written for the Jobs screens as JobsTileGrid.)
struct TileGrid: Layout {
    var minColumnWidth: CGFloat = 150
    var spacing: CGFloat = Theme.Space.m

    private struct Metrics {
        var columns: Int
        var columnWidth: CGFloat
        var rowHeights: [CGFloat]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let metrics = metrics(width: proposal.width, subviews: subviews)
        let width = CGFloat(metrics.columns) * metrics.columnWidth + spacing * CGFloat(metrics.columns - 1)
        let height = metrics.rowHeights.reduce(0, +) + spacing * CGFloat(max(0, metrics.rowHeights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let metrics = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, rowHeight) in metrics.rowHeights.enumerated() {
            for column in 0..<metrics.columns {
                let index = row * metrics.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (metrics.columnWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: metrics.columnWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }

    private func metrics(width: CGFloat?, subviews: Subviews) -> Metrics {
        let columns: Int
        let columnWidth: CGFloat
        if let width, width.isFinite {
            // Same column count as `GridItem(.adaptive(minimum:))`.
            columns = max(1, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down)))
            columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        } else {
            // No usable width offered (ideal size): every tile on one row, at the widest tile's ideal width.
            columns = subviews.count
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            columnWidth = max(minColumnWidth, widest.isFinite ? widest : minColumnWidth)
        }
        var rowHeights: [CGFloat] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + columns, subviews.count)
            let tallest = subviews[start..<end]
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max() ?? 0
            rowHeights.append(tallest)
            start = end
        }
        return Metrics(columns: columns, columnWidth: columnWidth, rowHeights: rowHeights)
    }
}


// MARK: - Chips

/// A small capsule tag (licence, kind, state).
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    /// Filled chips use the tint as background with white text (for strong states).
    var filled = false
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    // White text on the accent capsule in dark mode: the symbol solid white too.
                    .symbolRenderingMode(Theme.isHardToRead(tint, in: environment) && !filled ? .monochrome : nil)
                    .accessibilityHidden(true)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // Dark mode: a tint that is hard to read as text (the indigo accent) colours only the capsule, a little
        // stronger, and the text is white.
        .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(ReadableForeground(tint)))
        .background(filled ? AnyShapeStyle(tint)
                           : AnyShapeStyle(tint.opacity(Theme.isHardToRead(tint, in: environment) ? 0.32 : 0.14)),
                    in: Capsule())
    }
}

// MARK: - Progress

/// A circular progress ring with a gradient stroke. `progress` is 0...1; the centre shows `label` when given.
struct ProgressRing<Label: View>: View {
    let progress: Double
    var lineWidth: CGFloat = 10
    var tint: Color = Theme.accent
    @ViewBuilder var label: Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double, lineWidth: CGFloat = 10, tint: Color = Theme.accent, @ViewBuilder label: () -> Label) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = tint
        self.label = label()
    }

    private var clamped: Double { min(max(progress.isFinite ? progress : 0, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(AngularGradient(colors: [tint.opacity(0.75), tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(clamped, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: clamped)
            label
        }
        .padding(lineWidth / 2)
    }
}

extension ProgressRing where Label == EmptyView {
    init(progress: Double, lineWidth: CGFloat = 10, tint: Color = Theme.accent) {
        self.init(progress: progress, lineWidth: lineWidth, tint: tint) { EmptyView() }
    }
}

// MARK: - Rows

private struct HoverHighlight: ViewModifier {
    var radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.inset : .clear, in: .smooth(radius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// A soft rounded highlight while the pointer is over a list row. Purely decorative.
    func hoverHighlight(radius: CGFloat = Theme.Radius.control) -> some View {
        modifier(HoverHighlight(radius: radius))
    }
}

/// An icon in a soft tinted rounded square (row leading icons, empty states).
struct IconBadge: View {
    let systemImage: String
    var tint: Color = Theme.accent
    var size: CGFloat = 32
    @Environment(\.self) private var environment

    var body: some View {
        Image(systemName: systemImage)
            // On a stronger accent tile in dark mode every layer is white (a hierarchical secondary layer would
            // come out lavender).
            .symbolRenderingMode(Theme.isHardToRead(tint, in: environment) ? .monochrome : .hierarchical)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(ReadableForeground(tint))
            .frame(width: size, height: size)
            .background(tint.opacity(Theme.isHardToRead(tint, in: environment) ? 0.34 : 0.14), in: .smooth(size * 0.3))
            .accessibilityHidden(true)
    }
}

/// A coloured banner inside the content (warnings, notes). Not for errors next to a control.
struct InlineBanner<Content: View>: View {
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = Theme.warning
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(ReadableForeground(tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.m + 2)
        .background(tint.opacity(0.11), in: .smooth(Theme.Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous).strokeBorder(tint.opacity(0.18)))
    }
}

/// A centred empty state: a large tinted symbol, a title, a sentence and optional actions.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions
    @Environment(\.colorScheme) private var colorScheme

    init(systemImage: String, title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                // Light mode: an accent gradient. Dark mode: no accent-coloured symbol (hard to read), primary.
                .foregroundStyle(colorScheme == .dark
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                                   startPoint: .top, endPoint: .bottom)))
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420)
            actions
        }
        .padding(Theme.Space.xxl)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
