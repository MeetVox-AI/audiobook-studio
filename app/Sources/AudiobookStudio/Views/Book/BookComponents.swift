import AppKit
import SwiftUI

// Small building blocks shared by the "New audiobook" screen (Views/Book).

/// A titled, rounded panel.
struct BookCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
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

    private var tint: Color { error.isDiskSpace ? .red : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: error.isDiskSpace ? "externaldrive.fill.badge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(error.isDiskSpace ? .title2 : .body)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if error.isDiskSpace {
                        Text("Not enough disk space")
                            .font(.headline)
                    }
                    Text(error.message)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if error.engineMissing {
                    SettingsLink { Text("Open Settings") }
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
                    }
                    .frame(maxHeight: 160)
                }
                .accessibilityLabel("Engine log details")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(error.isDiskSpace ? 0.6 : 0.3))
        }
        .accessibilityElement(children: .contain)
    }
}

/// An informational line (engine `notice` messages, hints).
struct BookNoticeView: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "Chapter" / "Front" / "Back" badge in the section list.
struct BookKindBadge: View {
    let kind: SectionKind

    private var tint: Color {
        switch kind {
        case .chapter: return .accentColor
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
        Text(kind.title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minWidth: 58)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel(spokenName)
    }
}

/// "NON-COMMERCIAL" / "PERSONAL USE" badge next to a voice.
struct BookLicenseBadge: View {
    let text: String
    var help: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().strokeBorder(Color.orange.opacity(0.7)) }
            .help(help)
            .accessibilityLabel(help)
    }
}

/// The book cover written by `inspect --cover-out`, loaded off the main thread, or a placeholder.
struct BookCoverView: View {
    let url: URL?
    let title: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.3), radius: 4, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 34))
                            Text(url == nil ? "No cover" : "Loading cover…")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .aspectRatio(2 / 3, contentMode: .fit)
            }
        }
        .frame(width: 140)
        .frame(maxHeight: 220)
        .task(id: url) { image = await BookCoverView.load(url) }
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
        VStack(alignment: .leading, spacing: 16) {
            Label("\(engine.name) is for non-commercial use only", systemImage: "exclamationmark.shield")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
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
        }
        .padding(24)
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
