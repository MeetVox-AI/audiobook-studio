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
                VStack(spacing: 12) {
                    OpsErrorBox(error: error)
                    Button("Try Again") {
                        Task { await refresh() }
                    }
                    .accessibilityLabel("Try loading the model list again")
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No models listed", systemImage: "shippingbox",
                                       description: Text("The engine did not list any model files."))
            }
        } else {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voice models run entirely on this Mac. Downloading one is the only time the engine uses the network.")
                            .fixedSize(horizontal: false, vertical: true)
                        Label(freeSpaceText, systemImage: "internaldrive")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if let error = model.errors[.models] {
                        OpsErrorBox(error: error)
                    }
                }
                let groups = grouped
                if !groups.narration.isEmpty {
                    Section("Narration") {
                        ForEach(groups.narration) { row($0) }
                    }
                }
                if !groups.other.isEmpty {
                    Section("Quality check") {
                        ForEach(groups.other) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ status: ModelStatus) -> some View {
        ModelRow(status: status, freeBytes: freeBytes,
                 error: Binding(get: { rowErrors[status.engine] }, set: { rowErrors[status.engine] = $0 }),
                 onDownload: { download(status) },
                 onRemove: { modelToRemove = status })
    }

    /// Narration engines first (engine order), then other models such as the speech-check model.
    private var grouped: (narration: [ModelStatus], other: [ModelStatus]) {
        let engineIds = model.engines.map(\.id)
        guard !engineIds.isEmpty else {
            return (model.models.filter { $0.engine != OpsModelInfo.speechCheckModel },
                    model.models.filter { $0.engine == OpsModelInfo.speechCheckModel })
        }
        let narration = model.models.filter { engineIds.contains($0.engine) }
            .sorted { (engineIds.firstIndex(of: $0.engine) ?? 0) < (engineIds.firstIndex(of: $1.engine) ?? 0) }
        let other = model.models.filter { !engineIds.contains($0.engine) }
        return (narration, other)
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

/// One model: name, licence, purpose, size, state, Download / Remove, download progress and its files.
private struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let status: ModelStatus
    let freeBytes: Int64?
    @Binding var error: EngineError?
    let onDownload: () -> Void
    let onRemove: () -> Void
    @State private var showFiles = false

    var body: some View {
        let info = OpsModelInfo(status: status)
        let download = model.modelDownloads[status.engine]
        let inUse = model.opsModelInUse(status.engine)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.name)
                        .font(.headline)
                    OpsLicenseBadge(license: status.license, noncommercial: status.noncommercial ?? false)
                    if let purpose = info.purposeText {
                        Text(purpose.prefix(1).uppercased() + purpose.dropFirst())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Label(info.stateText, systemImage: info.stateSystemImage)
                        .foregroundStyle(status.installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        .font(.callout)
                    Text(info.sizeText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                actions(info: info, isDownloading: download != nil, inUse: inUse)
            }

            if let download {
                VStack(alignment: .leading, spacing: 4) {
                    if download.totalParts > 1 {
                        ProgressView(value: download.fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(download.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Download progress")
                .accessibilityValue(download.statusText)
            }
            if download == nil, let warning = info.spaceWarning(freeBytes: freeBytes) {
                OpsNotice(text: warning, systemImage: "externaldrive.badge.exclamationmark", tint: .orange)
            }
            if let error {
                OpsErrorBox(error: error) { self.error = nil }
            }
            if !status.parts.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.parts, id: \.repo) { part in
                            ModelPartRow(part: part)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Model files (\(status.parts.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Model files of \(status.name)")
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actions(info: OpsModelInfo, isDownloading: Bool, inUse: Bool) -> some View {
        HStack(spacing: 8) {
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
                    .disabled(inUse)
                    .accessibilityLabel("Remove \(status.name)")
                    .help(inUse ? "A conversion is using this model; remove it after the conversion ends."
                                : "Deletes the model files from this Mac")
                }
            }
        }
        .controlSize(.regular)
    }
}

private struct ModelPartRow: View {
    let part: ModelPart

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: part.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(part.installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(part.purpose.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? part.repo)
                    .font(.callout)
                Text(part.repo)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
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
