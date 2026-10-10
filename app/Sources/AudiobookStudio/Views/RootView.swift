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
                    if showsSetupBanner {
                        SetupBanner()
                    } else if let problem = model.errors[.engines] {
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
        // First run: the setup covers the window until the person finishes or skips it.
        .overlay {
            if model.setup.isPresented && model.settings.hasAcceptedTerms {
                SetupView().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.setup.isPresented)
        // First launch: the terms of use must be accepted. (The self-test tour has its own settings and skips it.)
        .sheet(isPresented: Binding(
            get: { !model.settings.hasAcceptedTerms && (SnapshotTour.directory == nil || SnapshotTour.showTerms) },
            set: { _ in }
        )) {
            TermsSheet { model.settings.acceptTerms() }
        }
    }
}

extension RootView {
    /// The friendly setup banner replaces the engine error while the setup is unfinished (engine not installed,
    /// no voice yet, or the setup working / failed in the background).
    fileprivate var showsSetupBanner: Bool {
        guard !model.setup.isPresented else { return false }
        if model.setup.isWorking || model.setup.error != nil { return true }
        return model.settings.setupState != .completed && model.needsSetup
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("New audiobook", systemImage: "book.closed")
                .tag(SidebarItem.newBook)
                .accessibilityLabel("New audiobook")
                .listItemTint(rowTint)

            Section("Conversions") {
                Label("Jobs", systemImage: "list.bullet.rectangle")
                    .badge(model.activeJobCount)
                    .tag(SidebarItem.jobs)
                    .accessibilityLabel(jobsAccessibilityLabel)
                    .listItemTint(rowTint)
                ForEach(model.sidebarMonitors) { monitor in
                    SidebarJobRow(monitor: monitor)
                        .tag(SidebarItem.job(monitor.jobId))
                }
            }

            Section("Library") {
                Label("Voices", systemImage: "person.wave.2")
                    .tag(SidebarItem.voices)
                    .accessibilityLabel("Voices")
                    .listItemTint(rowTint)
                Label("Models", systemImage: "shippingbox")
                    .tag(SidebarItem.models)
                    .accessibilityLabel("Models")
                    .listItemTint(rowTint)
                Label("Benchmark", systemImage: "speedometer")
                    .tag(SidebarItem.benchmark)
                    .accessibilityLabel("Benchmark")
                    .listItemTint(rowTint)
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

    /// Dark mode: grey sidebar icons instead of the accent (indigo is hard to read on dark).
    private var rowTint: ListItemTint? { colorScheme == .dark ? .monochrome : nil }

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
            Group {
                if monitor.state.isActive {
                    ProgressRing(progress: monitor.fraction, lineWidth: 2.5, tint: OpsStyle.tint(for: monitor.state))
                } else {
                    Image(systemName: finishedSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(OpsStyle.tint(for: monitor.state))
                }
            }
            .frame(width: 18, height: 18)
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

    private var finishedSymbol: String {
        switch monitor.state {
        case .done: return "checkmark.circle.fill"
        case .doneWithProblems: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "stop.circle.fill"
        }
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
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
            .background(Theme.accent.opacity(0.07), in: .smooth(Theme.Radius.card))
            .overlay {
                Label("Drop an EPUB or PDF to make an audiobook", systemImage: "arrow.down.doc.fill")
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(10)
            .allowsHitTesting(false)
            .accessibilityLabel("Drop an EPUB or PDF to make an audiobook")
    }
}
