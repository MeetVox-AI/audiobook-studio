import AppKit
import SwiftUI

// Small building blocks shared by the "New audiobook" screen (Views/Book), drawn with the design system
// (Design/Theme.swift, Design/Components.swift; rules in app/DESIGN.md).

extension View {
    /// Button look inside the book screen's content cards: `.borderedProminent` for the card's one primary
    /// action, `.bordered` otherwise, both as capsules.
    @ViewBuilder
    func bookCardButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// An engine failure: the engine's message as is, a "Details" disclosure with the stderr tail, a link to
/// Settings when the engine is missing, and a prominent style for "Not enough disk space".
struct BookErrorView: View {
    let error: EngineError
    /// Shows a close button when set.
    var onDismiss: (() -> Void)?
    @State private var showDetails = false

    private var tint: Color { error.isDiskSpace ? Theme.danger : Theme.warning }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Image(systemName: error.isDiskSpace ? "externaldrive.fill.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(error.isDiskSpace ? .title2 : .body)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if error.isDiskSpace {
                        Text("Not enough disk space")
                            .font(.headline)
                    }
                    Text(error.message)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Theme.Space.s)
                if error.engineMissing {
                    SettingsLink { Text("Open Settings") }
                        .bookCardButton()
                        .controlSize(.small)
                        .accessibilityLabel("Open Settings to set the engine location")
                }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss this message")
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
                .accessibilityLabel("Engine log details")
            }
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(error.isDiskSpace ? 0.14 : 0.11), in: .smooth(Theme.Radius.tile))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(tint.opacity(error.isDiskSpace ? 0.5 : 0.18))
        }
        .accessibilityElement(children: .contain)
    }
}

/// An informational line (engine `notice` messages, hints).
struct BookNoticeView: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        InlineBanner(systemImage: systemImage, tint: Theme.accent) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// "Chapter" / "Front" / "Back" chip in the section list (front and back matter muted).
struct BookKindBadge: View {
    let kind: SectionKind

    private var tint: Color {
        switch kind {
        case .chapter: return Theme.accent
        case .front, .back: return .secondary
        }
    }

    private var spokenName: String {
        switch kind {
        case .chapter: return "Chapter"
        case .front: return "Front matter"
        case .back: return "Back matter"
        }
    }

    var body: some View {
        Chip(text: kind.title, tint: tint)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenName)
    }
}

/// "NON-COMMERCIAL" / "PERSONAL USE" chip next to a voice.
struct BookLicenseBadge: View {
    let text: String
    var help: String

    var body: some View {
        Chip(text: text, systemImage: "exclamationmark.shield.fill", tint: Theme.highlight)
            .fixedSize()
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(help)
    }
}

/// The book cover written by `inspect --cover-out`, or a placeholder. The book screen loads the image once
/// (`BookCoverView.load`) because the hero backdrop behind the header uses it too.
struct BookCoverView: View {
    let url: URL?
    let title: String
    /// The loaded cover (nil while loading, or when the book has none).
    let image: NSImage?
    var width: CGFloat = 176

    private let radius: CGFloat = 12

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.smooth(radius))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Theme.hairline)
                    }
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.28), radius: 18, y: 10)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.07)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        VStack(spacing: Theme.Space.s) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 40))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Theme.accentForeground)
                            Text(url == nil ? "No cover" : "Loading cover…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .frame(width: width)
        .frame(maxHeight: width * 1.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "No cover image" : "Cover of \(title)")
    }

    /// Reads the file off the main thread (covers can be a few megabytes).
    static func load(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        return data.flatMap { NSImage(data: $0) }
    }
}

/// Licence sheet before the first use of a non-commercial engine (Voxtral, Fish).
struct BookLicenseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let engine: EngineInfo
    /// Called when the user acknowledges the licence, just before the sheet closes.
    let onAccept: () -> Void
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                IconBadge(systemImage: "exclamationmark.shield", tint: Theme.highlight, size: 40)
                Text("\(engine.name) is for non-commercial use only")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text("Its licence (\(engine.license)) allows non-commercial use only. Audio you make with it must not be used commercially, for example sold or used in a paid product.")
                .fixedSize(horizontal: false, vertical: true)
            if let notes = engine.notes, !notes.isEmpty {
                Text(notes)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("I understand and will use \(engine.name) for non-commercial purposes only", isOn: $understood)
                .toggleStyle(.checkbox)
                .accessibilityLabel("I understand and will use \(engine.name) for non-commercial purposes only")
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface(radius: Theme.Radius.control)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel and keep the licence unacknowledged")
                Button("Continue") {
                    model.settings.acknowledgeLicense(engine: engine.id)
                    onAccept()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!understood)
                .accessibilityLabel("Acknowledge the licence and continue")
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
    }
}

/// Why a licence sheet is shown and what to do once it is acknowledged.
struct BookLicenseRequest: Identifiable {
    let engine: EngineInfo
    let action: BookPendingAction
    var id: String { engine.id }
}

/// An action waiting for the licence sheet or the slow-engine confirmation.
enum BookPendingAction: Hashable {
    case sample(section: Int?)
    case convert
}
