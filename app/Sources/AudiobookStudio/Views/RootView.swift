import SwiftUI

/// Main window: sidebar + detail. Routing is driven by `AppModel.selection`.
/// The whole window accepts dropped .epub / .pdf files (opened with `AppModel.handleDrop`).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            DetailRouter(selection: model.selection ?? .newBook)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let problem = model.errors[.engines] {
                        EngineProblemBanner(error: problem)
                    }
                }
        }
        .frame(minWidth: 820, minHeight: 560)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted { DropHighlight() }
        }
    }
}

/// Picks the screen for a sidebar item.
private struct DetailRouter: View {
    let selection: SidebarItem

    var body: some View {
        switch selection {
        case .newBook: BookView()
        case .jobs: JobsView()
        case .job(let id): JobDetailView(jobId: id)
        case .voices: VoiceView()
        case .models: ModelsView()
        case .benchmark: BenchmarkView()
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("New audiobook", systemImage: "book.closed")
                .tag(SidebarItem.newBook)
                .accessibilityLabel("New audiobook")

            Section("Conversions") {
                Label("Jobs", systemImage: "list.bullet.rectangle")
                    .badge(model.activeJobCount)
                    .tag(SidebarItem.jobs)
                    .accessibilityLabel(jobsAccessibilityLabel)
                ForEach(model.sidebarMonitors) { monitor in
                    SidebarJobRow(monitor: monitor)
                        .tag(SidebarItem.job(monitor.jobId))
                }
            }

            Section("Library") {
                Label("Voices", systemImage: "person.wave.2")
                    .tag(SidebarItem.voices)
                    .accessibilityLabel("Voices")
                Label("Models", systemImage: "shippingbox")
                    .tag(SidebarItem.models)
                    .accessibilityLabel("Models")
                Label("Benchmark", systemImage: "speedometer")
                    .tag(SidebarItem.benchmark)
                    .accessibilityLabel("Benchmark")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsLink {
                Label("Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityLabel("Open Settings")
            .help("Engine location, output folder, audio quality and notifications")
        }
    }

    private var jobsAccessibilityLabel: String {
        switch model.activeJobCount {
        case 0: return "Jobs"
        case 1: return "Jobs, 1 conversion running"
        case let n: return "Jobs, \(n) conversions running"
        }
    }
}

/// A running job under "Jobs": title, progress ring and status.
private struct SidebarJobRow: View {
    let monitor: JobMonitor

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: monitor.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.displayTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(monitor.displayTitle), \(subtitle)")
    }

    private var subtitle: String {
        guard monitor.state.isActive else { return monitor.state.title }
        if case .synthesizing = monitor.phase {
            let eta = monitor.etaText.map { ", \($0) left" } ?? ""
            return Formatters.percent(monitor.percent) + eta
        }
        return monitor.phase.title
    }
}

// MARK: - Banners and overlays

/// Shown above every screen when the engine cannot be reached (wrong path, broken install).
private struct EngineProblemBanner: View {
    @Environment(AppModel.self) private var model
    let error: EngineError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(error.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                if error.engineMissing {
                    SettingsLink { Text("Open Settings") }
                        .accessibilityLabel("Open Settings to set the engine location")
                }
                Button("Try Again") {
                    Task { await model.refreshAll() }
                }
                .disabled(!model.loading.isEmpty)
                .accessibilityLabel("Try loading the engine again")
            }
            if !error.stderrTail.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(error.stderrTail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .accessibilityLabel("Engine log details")
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Highlight while a file is dragged over the window.
private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label("Drop an EPUB or PDF to make an audiobook", systemImage: "arrow.down.doc")
                    .font(.title3)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityLabel("Drop an EPUB or PDF to make an audiobook")
    }
}
