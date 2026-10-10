import SwiftUI

/// The book's sections with a checkbox each: kind chip, title, first words, listening time and the
/// reason the engine left a section out. Front and back matter start unticked (the engine's choice).
struct BookSectionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let draft: BookDraft
    /// Makes a 2-minute sample of one section (context menu).
    let onSample: (Int) -> Void

    var body: some View {
        SurfaceCard {
            header
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(draft.sections) { section in
                    BookSectionRow(section: section,
                                   isIncluded: draft.isIncluded(section.index),
                                   onToggle: { model.draft?.setIncluded(section.index, $0) },
                                   onSample: { onSample(section.index) })
                    if section.id != draft.sections.last?.id {
                        // A very light rule, inset to the text, between rows.
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.leading, 38)
                            .padding(.trailing, Theme.Space.s)
                            .accessibilityHidden(true)
                    }
                }
            }
            // Rows carry their own padding for the hover highlight; this lines their text up with the header.
            .padding(.horizontal, -Theme.Space.s)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Space.m) {
                titleBlock
                Spacer(minLength: Theme.Space.m)
                selectionButtons
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                titleBlock
                selectionButtons
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Same title style as the `SurfaceCard` headers of the narrator and sample cards above.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "list.bullet")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accentForeground)
                    .accessibilityHidden(true)
                Text("Sections")
                    .font(Theme.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("\(draft.selectionSummary) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: draft.included)
        }
    }

    private var selectionButtons: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Select All Chapters") { model.draft?.selectAllChapters() }
                .disabled(draft.isAllChaptersSelection)
                .help("Tick every chapter and untick front and back matter")
                .accessibilityLabel("Select all chapters")
            Button("Select None") { model.draft?.setAll(false) }
                .disabled(!draft.hasSelection)
                .accessibilityLabel("Untick every section")
            Button("Reset") { model.draft?.resetSelection() }
                .disabled(draft.isEngineSelection)
                .help("Back to the sections suggested when the book was opened")
                .accessibilityLabel("Reset to the suggested sections")
        }
        .bookCardButton()
        .controlSize(.small)
    }
}

/// One section: checkbox, title, kind chip, listening time, first words, and why it was left out.
struct BookSectionRow: View {
    let section: SectionInfo
    let isIncluded: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void
    let onSample: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Toggle("Include", isOn: Binding(get: { isIncluded }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(section.sectionKind.title.lowercased()) “\(section.title)”")

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(section.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isIncluded ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(section.title)
                    Spacer(minLength: Theme.Space.m)
                    BookKindBadge(kind: section.sectionKind)
                    Text(Formatters.duration(section.estSeconds))
                        .font(Theme.number(.body, weight: .regular))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(minWidth: 64, alignment: .trailing)
                        .help("About \(Formatters.duration(section.estSeconds)) of listening, \(Formatters.characters(section.chars))")
                }
                if let words = section.firstWords, !words.isEmpty {
                    Text(words)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let reason = reasonText {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(isIncluded ? Color.secondary : Color.primary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle(!isIncluded) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(isIncluded ? "Included" : "Left out")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggle(!isIncluded) }
        }
        .padding(.vertical, Theme.Space.s + 2)
        .padding(.horizontal, Theme.Space.s)
        .hoverHighlight()
        .contextMenu {
            Button(isIncluded ? "Leave Out This Section" : "Include This Section") { onToggle(!isIncluded) }
            Button("Make a 2-Minute Sample from This Section", action: onSample)
        }
    }

    /// "Left out by default: Project Gutenberg license text".
    private var reasonText: String? {
        guard let reasons = section.reasons?.filter({ !$0.isEmpty }), !reasons.isEmpty else { return nil }
        return "Left out by default: " + reasons.joined(separator: "; ")
    }

    private var accessibilitySummary: String {
        var parts = [section.sectionKind.title, section.title, Formatters.duration(section.estSeconds),
                     Formatters.characters(section.chars)]
        if let reason = reasonText { parts.append(reason) }
        return parts.joined(separator: ", ")
    }
}
