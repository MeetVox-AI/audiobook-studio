import SwiftUI

/// The book's sections with a checkbox each: kind badge, title, first words, listening time and the
/// reason the engine left a section out. Front and back matter start unticked (the engine's choice).
struct BookSectionList: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft
    /// Makes a 2-minute sample of one section (context menu).
    let onSample: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)
            Divider()
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(draft.sections) { section in
                    BookSectionRow(section: section,
                                   isIncluded: draft.isIncluded(section.index),
                                   onToggle: { model.draft?.setIncluded(section.index, $0) },
                                   onSample: { onSample(section.index) })
                    Divider()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Sections")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("\(draft.selectionSummary) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 12)
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
        .controlSize(.small)
    }
}

/// One section: checkbox, kind badge, title, first words, listening time, and why it was left out.
struct BookSectionRow: View {
    let section: SectionInfo
    let isIncluded: Bool
    let onToggle: @MainActor @Sendable (Bool) -> Void
    let onSample: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Include", isOn: Binding(get: { isIncluded }, set: onToggle))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(section.sectionKind.title.lowercased()) “\(section.title)”")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BookKindBadge(kind: section.sectionKind)
                    Text(section.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(section.title)
                    Spacer(minLength: 12)
                    Text(Formatters.duration(section.estSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
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
