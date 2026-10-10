import AppKit
import SwiftUI

/// Top of the book screen (hero): cover, editable title and author, book facts as chips, language picker
/// (with "from metadata" / "detected"), the file, and the engine's warnings about the book.
/// The blurred cover behind it (`HeroBackdrop`) is drawn by the book screen.
struct BookHeaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: BookDraft
    /// The cover loaded by the book screen (nil while loading or when the book has none).
    let cover: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                BookCoverView(url: draft.coverURL, title: draft.title, image: cover)
                details
            }
            if !draft.warnings.isEmpty {
                warnings
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            facts
            BookHeaderField(label: "Title", text: titleBinding, prompt: draft.info.title,
                            font: Theme.screenTitle, accessibilityLabel: "Book title")
            BookHeaderField(label: "Author", text: authorBinding, prompt: draft.info.author,
                            font: .title2, accessibilityLabel: "Author")
            languageRow
            fileRow
            if isEdited {
                editNote
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .smooth, value: isEdited)
    }

    private var isEdited: Bool { draft.title != draft.info.title || draft.author != draft.info.author }

    private var titleBinding: Binding<String> {
        Binding(get: { model.draft?.title ?? "" }, set: { model.draft?.title = $0 })
    }

    private var authorBinding: Binding<String> {
        Binding(get: { model.draft?.author ?? "" }, set: { model.draft?.author = $0 })
    }

    /// Format, number of sections, year and publisher (the parts of `draft.detailsLine`) as chips that wrap
    /// onto a second line when the column is narrow (like the baseline's wrapping details line).
    private var facts: some View {
        BookChipFlow(spacing: Theme.Space.s, lineSpacing: Theme.Space.xs + 2) {
            Chip(text: draft.formatName, systemImage: draft.formatName == "PDF" ? "doc.richtext" : "book.closed",
                 tint: Theme.accent)
            Chip(text: sectionCountText, systemImage: "list.bullet")
            if let year = draft.publicationYear {
                Chip(text: year, systemImage: "calendar")
            }
            if let publisher {
                Chip(text: publisher, systemImage: "building.columns")
                    .help(publisher)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(draft.detailsLine)
    }

    /// "42 sections" (the same wording as `draft.detailsLine`).
    private var sectionCountText: String {
        draft.sections.count == 1 ? "1 section" : "\(Formatters.count(draft.sections.count)) sections"
    }

    private var publisher: String? {
        guard let name = draft.info.metadata?.publisher?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            BookHeaderLabel(text: "Language")
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Picker("Language", selection: Binding(get: { draft.language }, set: { model.setLanguage($0) })) {
                    ForEach(model.bookLanguageChoices, id: \.self) { code in
                        Text(Formatters.languageName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Book language")
                .accessibilityValue(Formatters.languageName(draft.language))
                .help("The language the narrator reads in. Changing it also picks that language's default voice.")
                Text(languageSourceText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languageSourceText: String {
        if let label = draft.languageSourceLabel { return label }
        return "you changed it from \(Formatters.languageName(draft.info.language)) (\(Formatters.languageSource(draft.info.languageSource)))"
    }

    private var fileRow: some View {
        HStack(spacing: 6) {
            Image(systemName: draft.formatName == "PDF" ? "doc.richtext" : "doc.text")
                .foregroundStyle(Theme.faint)
                .accessibilityHidden(true)
            Text(draft.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(draft.url.path)
            Button {
                FileActions.revealInFinder(draft.url)
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Show the book in Finder")
            .accessibilityLabel("Show the book in Finder")
        }
        .font(.callout)
    }

    private var editNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Edits are shown in the app only for now: the audiobook uses the title and author stored in the book file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Revert") {
                model.draft?.title = draft.info.title
                model.draft?.author = draft.info.author
            }
            .bookCardButton()
            .controlSize(.small)
            .accessibilityLabel("Revert the title and author to the ones in the book")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.surface.opacity(0.7), in: .smooth(Theme.Radius.control))
    }

    // MARK: Warnings

    private var warnings: some View {
        InlineBanner(systemImage: "exclamationmark.triangle.fill", tint: Theme.highlight) {
            Text("Notes from reading the book")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Lays its views out left to right and starts a new line when the next one does not fit, so the book
/// facts chips wrap instead of being cut off. A single view wider than the whole line is narrowed to the
/// line's width (a chip then truncates; its tooltip and the row's accessibility label keep the full text).
private struct BookChipFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Line {
        var y: CGFloat = 0
        var height: CGFloat = 0
        /// Subview index, x position and size.
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for line in arrange(width: bounds.width, subviews: subviews).lines {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + line.y + (line.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    /// Splits the subviews into lines no wider than `width` (nil: everything on one line).
    private func arrange(width: CGFloat?, subviews: Subviews) -> (lines: [Line], size: CGSize) {
        let maxWidth = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        var lineEnd: CGFloat = 0
        var widest: CGFloat = 0
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if !line.items.isEmpty, lineEnd + spacing + size.width > maxWidth {
                widest = max(widest, lineEnd)
                let nextY = line.y + line.height + lineSpacing
                lines.append(line)
                line = Line(y: nextY)
                lineEnd = 0
            }
            let x = line.items.isEmpty ? 0 : lineEnd + spacing
            line.items.append((index, x, size))
            line.height = max(line.height, size.height)
            lineEnd = x + size.width
        }
        guard !line.items.isEmpty else { return ([], .zero) }   // no subviews
        widest = max(widest, lineEnd)
        lines.append(line)
        return (lines, CGSize(width: widest, height: line.y + line.height))
    }
}

/// Small label above a header field ("Title", "Author", "Language").
private struct BookHeaderLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}

/// An editable header text (title, author). At rest it shows the text large and wrapped (a long title is
/// never cut off), with a pencil as the editing affordance and a stronger fill on hover. Clicking it (or
/// pressing it with VoiceOver) swaps in a text field with an accent ring; Return, Escape or clicking
/// elsewhere ends editing.
/// (A vertical-axis TextField was tried first: on macOS 26 it only drew the first line of a wrapped title.)
private struct BookHeaderField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let font: Font
    let accessibilityLabel: String

    @FocusState private var isFocused: Bool
    @State private var isEditing = false
    @State private var isHovering = false

    private var fillOpacity: Double { isEditing ? 1 : (isHovering ? 0.9 : 0.6) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            BookHeaderLabel(text: label)
            Group {
                if isEditing {
                    editor
                } else {
                    display
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.surface.opacity(fillOpacity), in: .smooth(Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(isEditing ? Theme.accent.opacity(0.8) : Theme.hairline,
                                  lineWidth: isEditing ? 1.5 : 1)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isEditing)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }

    private var display: some View {
        Button {
            isEditing = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(text.isEmpty ? prompt : text)
                    .font(font)
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(Theme.faint) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pencil")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.faint)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to edit")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(text.isEmpty ? prompt : text)
        .accessibilityHint("Edits the \(label.lowercased())")
    }

    private var editor: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            TextField(label, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(font)
                .focused($isFocused)
                .onSubmit { isEditing = false }
                .onExitCommand { isEditing = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused { isEditing = false }
                }
                .task {
                    // The field only exists after the click; focus it once it is in the window.
                    await Task.yield()
                    isFocused = true
                }
                .accessibilityLabel(accessibilityLabel)
            Image(systemName: "pencil")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.accentForeground)
                .accessibilityHidden(true)
        }
    }
}
