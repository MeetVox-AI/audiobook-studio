import SwiftUI

/// "Models" screen (sidebar `.models`): the engine's model files (`models list`) with licence, size and
/// installed state; Download (progress streamed part by part) and Remove (with confirmation); free disk
/// space on the volume that holds the models.
struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var freeBytes: Int64?
    @State private var rowErrors: [String: EngineError] = [:]
    @State private var modelToRemove: ModelStatus?

    var body: some View {
        content
            .background(AmbientBackground())
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.loading.contains(.models))
                    .accessibilityLabel("Refresh the model list")
                    .help("Ask the engine which model files are installed")
                }
            }
            .task { await refresh() }
            .task(id: model.models) { await updateFreeSpace() }
            .confirmationDialog(removeTitle, isPresented: removeDialogShown, titleVisibility: .visible,
                                presenting: modelToRemove) { status in
                Button("Remove", role: .destructive) { remove(status) }
                    .accessibilityLabel("Remove the model files")
                Button("Keep", role: .cancel) {}
                    .accessibilityLabel("Keep the model files")
            } message: { status in
                Text(removeMessage(status))
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.models.isEmpty {
            if model.loading.contains(.models) {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errors[.models] {
                VStack(spacing: Theme.Space.l) {
                    OpsErrorBox(error: error)
                    Button("Try Again") {
                        Task { await refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .accessibilityLabel("Try loading the model list again")
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 560)
                .surface()
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(systemImage: "shippingbox", title: "No models listed",
                               message: "The engine did not list any model files.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ScreenIntro("Voice models run entirely on this Mac. Downloading one is the only time the engine uses the network.") {
                        ModelsFreeSpaceFigure(freeBytes: freeBytes, text: freeSpaceText)
                    }
                    if let error = model.errors[.models] {
                        OpsErrorBox(error: error)
                    }
                    let groups = grouped
                    if !groups.narration.isEmpty {
                        section("Narration", models: groups.narration, kind: .narration)
                    }
                    if !groups.cleanup.isEmpty {
                        section("Voice clean-up", models: groups.cleanup, kind: .cleanup)
                    }
                    if !groups.other.isEmpty {
                        section("Quality check", models: groups.other, kind: .speechCheck)
                    }
                }
                .padding(.horizontal, Theme.Space.xxl)
                .padding(.vertical, Theme.Space.xl)
                .screenWidth()
            }
        }
    }

    private func section(_ title: String, models: [ModelStatus], kind: ModelsKind) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title)
            ForEach(models) { row($0, kind: kind) }
        }
    }

    private func row(_ status: ModelStatus, kind: ModelsKind) -> some View {
        ModelRow(status: status, kind: kind, freeBytes: freeBytes,
                 error: Binding(get: { rowErrors[status.engine] }, set: { rowErrors[status.engine] = $0 }),
                 onDownload: { download(status) },
                 onRemove: { modelToRemove = status })
    }

    /// Narration engines first (engine order), then voice clean-up, then the speech-check model.
    private var grouped: (narration: [ModelStatus], cleanup: [ModelStatus], other: [ModelStatus]) {
        OpsModelInfo.groups(model.models, engineIds: model.engines.map(\.id))
    }

    private var freeSpaceText: String {
        guard let freeBytes else { return "Checking free disk space…" }
        return "\(Formatters.bytes(freeBytes)) available on this Mac (including space macOS can free)"
    }

    private var removeTitle: String {
        "Remove \(modelToRemove?.name ?? "this model")?"
    }

    private func removeMessage(_ status: ModelStatus) -> String {
        let size = status.installedBytes > 0 ? "\(Formatters.bytes(status.installedBytes)) of model files" : "its model files"
        return "This deletes \(size) from this Mac. You can download it again at any time."
    }

    private var removeDialogShown: Binding<Bool> {
        Binding(get: { modelToRemove != nil }, set: { if !$0 { modelToRemove = nil } })
    }

    private func refresh() async {
        await model.refreshModels()
        await updateFreeSpace()
    }

    private func updateFreeSpace() async {
        let folder = OpsDiskSpace.modelsFolder(for: model.models)
        freeBytes = await Task.detached { OpsDiskSpace.availableBytes(at: folder) }.value
    }

    private func download(_ status: ModelStatus) {
        rowErrors[status.engine] = nil
        Task {
            do {
                try await model.downloadModel(status.engine)
            } catch {
                rowErrors[status.engine] = EngineError(error)
            }
            await updateFreeSpace()
        }
    }

    private func remove(_ status: ModelStatus) {
        rowErrors[status.engine] = nil
        Task {
            do {
                try await model.removeModel(status.engine)
            } catch {
                rowErrors[status.engine] = EngineError(error)
            }
            await updateFreeSpace()
        }
    }
}

/// What a model is for, which picks its icon: a narration (text-to-speech) engine, voice clean-up for
/// "Add My Voice", or the speech check.
private enum ModelsKind {
    case narration, cleanup, speechCheck

    var systemImage: String {
        switch self {
        case .narration: return "waveform"
        case .cleanup: return "wand.and.stars"
        case .speechCheck: return "ear.badge.checkmark"
        }
    }

    var tint: Color {
        switch self {
        case .narration: return Theme.accent
        case .cleanup: return Theme.success
        case .speechCheck: return Theme.highlight
        }
    }
}

/// Free disk space as a small figure on the right of the screen header. Same words as the one-line
/// summary ("62.1 GB available on this Mac (including space macOS can free)"), laid out as a figure.
private struct ModelsFreeSpaceFigure: View {
    let freeBytes: Int64?
    /// The full sentence, read by VoiceOver and shown as the tooltip.
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let freeBytes {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "internaldrive")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.accentForeground)
                            .font(.title3)
                        Text(Formatters.bytes(freeBytes))
                            .font(Theme.number(.title2))
                            .contentTransition(.numericText())
                    }
                    Text("available on this Mac")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("(including space macOS can free)")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                }
                .multilineTextAlignment(.trailing)
                .fixedSize()
            } else {
                Label(text, systemImage: "internaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .animation(reduceMotion ? nil : .smooth, value: freeBytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .help(text)
    }
}

/// One model: name, licence, purpose, size, state, Download / Remove, download progress and its files.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: ModelStatus
    let kind: ModelsKind
    let freeBytes: Int64?
    @Binding var error: EngineError?
    let onDownload: () -> Void
    let onRemove: () -> Void
    @State private var showFiles = false

    var body: some View {
        let info = OpsModelInfo(status: status)
        let download = model.modelDownloads[status.engine]
        let inUse = model.opsModelInUse(status.engine)
        HStack(alignment: .top, spacing: Theme.Space.l) {
            IconBadge(systemImage: kind.systemImage, tint: kind.tint, size: 40)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.name)
                            .font(Theme.sectionTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        ModelsLicenseChips(license: status.license, noncommercial: status.noncommercial ?? false)
                        if let purpose = info.purposeText {
                            Text(purpose.prefix(1).uppercased() + purpose.dropFirst())
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Theme.Space.m)
                    actions(info: info, isDownloading: download != nil, inUse: inUse)
                }

                HStack(alignment: .center, spacing: Theme.Space.s) {
                    Chip(text: info.stateText, systemImage: info.stateSystemImage, tint: stateTint(info))
                    Text(info.sizeText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)

                if let download {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Image(systemName: "arrow.down.circle")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Theme.accentForeground)
                                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                            Text(download.statusText)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if download.totalParts > 1 {
                            ProgressView(value: download.fraction)
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(Theme.accent)
                        }
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetSurface()
                    .animation(reduceMotion ? nil : .smooth, value: download.fraction)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(download.statusText)
                }
                if download == nil, let warning = info.spaceWarning(freeBytes: freeBytes) {
                    InlineBanner(systemImage: "externaldrive.badge.exclamationmark", tint: Theme.warning) {
                        Text(warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let error {
                    OpsErrorBox(error: error) { self.error = nil }
                }
                if !status.parts.isEmpty {
                    DisclosureGroup(isExpanded: $showFiles) {
                        VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
                            ForEach(status.parts, id: \.repo) { part in
                                ModelPartRow(part: part)
                            }
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .insetSurface(radius: Theme.Radius.control)
                        .padding(.top, Theme.Space.xs)
                    } label: {
                        Text("Model files (\(status.parts.count))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Model files of \(status.name)")
                }
            }
        }
        .padding(Theme.Space.l + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(radius: Theme.Radius.card)
        .surface()
        .animation(reduceMotion ? nil : .smooth, value: download != nil)
    }

    private func stateTint(_ info: OpsModelInfo) -> Color {
        if status.installed { return Theme.success }
        return info.isPartial ? Theme.warning : .secondary
    }

    @ViewBuilder
    private func actions(info: OpsModelInfo, isDownloading: Bool, inUse: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            if isDownloading {
                Text("Downloading…")
                    .foregroundStyle(.secondary)
            } else {
                if !status.installed {
                    Button {
                        onDownload()
                    } label: {
                        Label(info.isPartial ? "Finish Download" : "Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Download \(status.name)")
                    .help(info.remainingDownloadBytes.map { "Downloads about \(Formatters.bytes($0))" } ?? "Downloads the model files")
                }
                if info.canRemove {
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove…", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(inUse)
                    .accessibilityLabel("Remove \(status.name)")
                    .help(inUse ? "A conversion is using this model; remove it after the conversion ends."
                                : "Deletes the model files from this Mac")
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .fixedSize()
    }
}

/// Licence name and a "NON-COMMERCIAL" chip for personal-use-only models (same text, tooltip and
/// VoiceOver label as `OpsLicenseBadge`).
private struct ModelsLicenseChips: View {
    let license: String?
    let noncommercial: Bool

    var body: some View {
        // Side by side when they fit, stacked on narrow windows (long licence names).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: Theme.Space.xs) { chips }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var chips: some View {
        if let license, !license.isEmpty {
            Chip(text: license, systemImage: "doc.text", tint: .secondary)
                .help(license)
        }
        if noncommercial {
            Chip(text: "NON-COMMERCIAL", tint: Theme.warning)
                .help("Licensed for personal, non-commercial use only")
        }
    }

    private var accessibilityText: String {
        let name = license.map { "Licence: \($0)" } ?? "Licence unknown"
        return noncommercial ? "\(name). Non-commercial use only." : name
    }
}

private struct ModelPartRow: View {
    let part: ModelPart

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: part.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(part.installed ? AnyShapeStyle(Theme.success) : AnyShapeStyle(.secondary))
                .font(.callout)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.purpose.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? part.repo)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(part.repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            if let bytes = part.bytes, bytes > 0 {
                Text(Formatters.bytes(bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(part.purpose ?? part.repo), \(part.installed ? "installed" : "not installed")")
    }
}
