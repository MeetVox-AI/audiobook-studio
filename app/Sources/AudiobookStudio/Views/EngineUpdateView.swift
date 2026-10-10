import SwiftUI

/// Top-of-window notice while the engine is older than the app needs. Never a window: with automatic updates on,
/// the engine updates by itself and this shows the progress; otherwise it offers "Update". Voices, models and
/// audiobooks stay.
struct EngineUpdateBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.m) {
                content
            }
            if let error = model.engineUpdateError, !model.isUpdatingEngine, !error.stderrTail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.stderrTail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
                .accessibilityLabel("Engine update details")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isUpdatingEngine {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Updating the voice engine…").font(.callout.weight(.semibold))
                ProgressView(value: model.engineUpdater.fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(maxWidth: 320)
                Text(model.engineUpdater.stepTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Updating the voice engine: \(model.engineUpdater.stepTitle)")
            Spacer()
        } else if let error = model.engineUpdateError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The voice engine could not be updated").font(.callout.weight(.semibold))
                Text(error.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if model.engineIsManaged {
                Button("Try Again") { Task { await model.updateEngine() } }
                    .disabled(model.engineUpdateBlocker != nil)
                    .accessibilityLabel("Try updating the voice engine again")
            }
        } else {
            Image(systemName: "arrow.down.circle").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The voice engine needs an update").font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if model.engineIsManaged {
                Button("Update") { Task { await model.updateEngine() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.engineUpdateBlocker != nil)
                    .help("Downloads the new engine and its libraries (a minute or two). Voices, models and audiobooks stay.")
                    .accessibilityLabel("Update the voice engine")
            }
        }
    }

    private var detail: String {
        if !model.engineIsManaged {
            return "This engine was not installed by Audiobook Studio: update that copy, or choose the default location in Settings."
        }
        if model.activeJobCount > 0 {
            return model.automaticUpdates()
                ? "It updates by itself when the conversion in progress finishes. Needed for voice clean-up and Change Recording."
                : "You can update it when the conversion in progress finishes. Needed for voice clean-up and Change Recording."
        }
        return "Needed for voice clean-up and Change Recording. Takes a minute or two; voices, models and audiobooks stay."
    }
}
