import SwiftUI

/// "New audiobook" before a book is open: a drop area with an Open button, progress while the engine
/// reads the book (`inspect`), and the reason when it cannot (e.g. a scanned PDF that needs OCR).
/// Dropping works anywhere in the window (RootView handles it); the drop area itself also accepts the
/// drop (the same `model.handleDrop`) so it can light up while a file is dragged over it.
struct BookDropZone: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment
    @State private var isTargeted = false
    /// Visible height of the scroll view, to centre the drop area vertically.
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                dropArea
                if let error = model.bookError {
                    BookErrorView(error: error)
                        .frame(maxWidth: 600)
                }
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: .infinity, minHeight: max(480, viewportHeight))
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        } action: { _, height in
            viewportHeight = height
        }
        .background(AmbientBackground())
    }

    private var dropArea: some View {
        VStack(spacing: Theme.Space.l) {
            symbol

            if model.isInspecting {
                Text("Reading the book…")
                    .font(.title2.weight(.semibold))
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading the book")
                Text("Finding chapters, the cover and the language.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Theme.Space.s) {
                    Text("Drop a book here")
                        .font(.title.weight(.bold))
                    Text("An EPUB or a PDF with selectable text. You choose the chapters and a voice; the audiobook is made on this Mac.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420)
                }
                Button {
                    model.openWithPanel()
                } label: {
                    Label("Open Book…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, Theme.Space.xs)
                .help("Choose an EPUB or PDF (⌘O)")
                .accessibilityLabel("Open a book")
                .accessibilityHint("Shows a file picker for EPUB and PDF books")
            }
        }
        .padding(.horizontal, Theme.Space.xxl + 16)
        .padding(.vertical, Theme.Space.xxl + 24)
        .frame(maxWidth: 600)
        .background { dropShape }
        .scaleEffect(isTargeted && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop area for EPUB and PDF books")
    }

    /// The big book symbol on a soft accent halo; it pulses while the book is read and bounces when a file
    /// is dragged over (no motion with Reduce Motion).
    /// Light mode: an accent gradient. Dark mode, where the indigo accent is hard to read
    /// (`Theme.isHardToRead`): the primary label colour, like `EmptyStateView`; the halo stays accent.
    private var symbol: some View {
        Image(systemName: model.isInspecting ? "book.pages" : "books.vertical")
            .font(.system(size: 54, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.isHardToRead(Theme.accent, in: environment)
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                               startPoint: .top, endPoint: .bottom)))
            .symbolEffect(.pulse, isActive: model.isInspecting && !reduceMotion)
            .symbolEffect(.bounce, value: reduceMotion ? false : isTargeted)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 112, height: 112)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Theme.accent.opacity(isTargeted ? 0.24 : 0.14), Theme.accent.opacity(0.02)],
                                         center: .center, startRadius: 0, endRadius: 64))
            }
            .accessibilityHidden(true)
    }

    /// Solid rounded surface with a dashed accent border that brightens and thickens while a file is over it.
    private var dropShape: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return shape
            .fill(Theme.surface)
            .overlay {
                shape.fill(Theme.accent.opacity(isTargeted ? 0.07 : 0))
            }
            .overlay {
                shape.strokeBorder(Theme.accent.opacity(isTargeted ? 0.95 : 0.35),
                                   style: StrokeStyle(lineWidth: isTargeted ? 2.5 : 1.5, dash: [9, 7]))
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : (isTargeted ? 0.10 : 0.05)),
                    radius: isTargeted ? 18 : 10, y: isTargeted ? 6 : 3)
    }
}
