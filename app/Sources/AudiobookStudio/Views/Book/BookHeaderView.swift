import SwiftUI

/// Top of the book screen: cover, editable title and author, book details, language picker
/// (with "from metadata" / "detected") and the engine's warnings about the book.
struct BookHeaderView: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 24) {
                BookCoverView(url: draft.coverURL, title: draft.title)
                details
            }
            if !draft.warnings.isEmpty {
                warnings
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Title")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("Title", text: titleBinding, prompt: Text(draft.info.title))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .accessibilityLabel("Book title")
                }
                GridRow {
                    Text("Author")
                        .foregroundStyle(.secondary)
                    TextField("Author", text: authorBinding, prompt: Text(draft.info.author))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Author")
                }
                GridRow {
                    Text("Language")
                        .foregroundStyle(.secondary)
                    languageRow
                }
                GridRow {
                    Text("Book")
                        .foregroundStyle(.secondary)
                    fileRow
                }
            }
            if isEdited {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Edits are shown in the app only for now: the audiobook uses the title and author stored in the book file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Revert") {
                        model.draft?.title = draft.info.title
                        model.draft?.author = draft.info.author
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Revert the title and author to the ones in the book")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isEdited: Bool { draft.title != draft.info.title || draft.author != draft.info.author }

    private var titleBinding: Binding<String> {
        Binding(get: { model.draft?.title ?? "" }, set: { model.draft?.title = $0 })
    }

    private var authorBinding: Binding<String> {
        Binding(get: { model.draft?.author ?? "" }, set: { model.draft?.author = $0 })
    }

    private var languageRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
        }
    }

    private var languageSourceText: String {
        if let label = draft.languageSourceLabel { return label }
        return "you changed it from \(Formatters.languageName(draft.info.language)) (\(Formatters.languageSource(draft.info.languageSource)))"
    }

    private var fileRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.detailsLine)
            HStack(spacing: 6) {
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
    }

    // MARK: Warnings

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Notes from reading the book", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .accessibilityHidden(true)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
