import SwiftUI

/// "Benchmark" screen (sidebar `.benchmark`): measure an engine + voice + language on this Mac
/// (`benchmark`), then the history of every speed measured here (`engines.measured`), which feeds the
/// estimates on the book screen.
struct BenchmarkView: View {
    @Environment(AppModel.self) private var model
    @State private var engineId: String?
    @State private var language: String?
    @State private var choiceId: String?
    @State private var sortKey: BenchmarkSortKey = .date
    @State private var sortAscending = false
    /// Benchmark waiting for the licence of a non-commercial engine to be acknowledged (first use only).
    @State private var pendingLicense: BenchmarkLicenseRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ScreenIntro("A benchmark narrates a short fixed passage to measure how fast an engine and voice run on this Mac. Estimates use the latest measurement, from a benchmark, a sample or a finished conversion.")
                runCard
                ForEach(model.benchmarks.prefix(5)) { run in
                    BenchmarkRunCard(run: run)
                }
                historyCard
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .screenWidth()
        }
        .background(AmbientBackground())
        .navigationTitle("Benchmark")
        .sheet(item: $pendingLicense) { request in
            // The sheet saves the acknowledgement itself, then the benchmark starts.
            BookLicenseSheet(engine: request.engine) {
                model.startBenchmark(voice: request.voice, language: request.language)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshEngines() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.loading.contains(.engines))
                .accessibilityLabel("Reload the measured speeds")
                .help("Reload engines and the speeds measured on this Mac")
            }
        }
    }

    // MARK: Run form

    private var selection: OpsBenchmarkSelection? {
        model.opsBenchmarkSelection(engineId: engineId, language: language, choiceId: choiceId)
    }

    @ViewBuilder
    private var runCard: some View {
        SurfaceCard("Measure a voice", systemImage: "speedometer") {
            if let selection {
                form(selection)
            } else if model.loading.contains(.engines) {
                ProgressView("Loading engines…")
            } else if let error = model.errors[.engines] {
                OpsErrorBox(error: error)
            } else {
                Text("No engines are available. Check the engine location in Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func form(_ s: OpsBenchmarkSelection) -> some View {
        let installed = model.opsModelInstalled(s.engine.id)
        let running = model.benchmarks.contains { $0.isRunning }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.m) {
            GridRow {
                Text("Engine").foregroundStyle(.secondary)
                Picker("Engine", selection: engineBinding(s)) {
                    ForEach(model.engines) { engine in
                        Text(engine.noncommercial ? "\(engine.name) — personal use only" : engine.name)
                            .tag(engine.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                .accessibilityLabel("Engine")
            }
            GridRow {
                Text("Language").foregroundStyle(.secondary)
                Picker("Language", selection: languageBinding(s)) {
                    ForEach(s.engine.languages.filter { model.isEnabled($0) || $0 == s.language }, id: \.self) { code in
                        Text(Formatters.languageName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                .accessibilityLabel("Language")
            }
            GridRow {
                Text("Voice").foregroundStyle(.secondary)
                if s.choices.isEmpty {
                    Text(noVoiceText(s))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Voice", selection: choiceBinding(s)) {
                        ForEach(s.choices) { choice in
                            Text(choice.isClone ? "\(choice.voiceName) (cloned)" : choice.voiceName).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    .accessibilityLabel("Voice")
                }
            }
        }

        if installed == false {
            InlineBanner(systemImage: "arrow.down.circle", tint: Theme.warning) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Text("The \(s.engine.name) model is not installed. Download it before measuring it.")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: Theme.Space.s)
                    Button("Open Models") { model.selection = .models }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Open the Models screen to download this model")
                }
            }
            .accessibilityElement(children: .contain)
        }
        if model.activeJobCount > 0 {
            InlineBanner(systemImage: "hourglass", tint: .secondary) {
                Text("A conversion is running: the benchmark waits for the GPU and starts when it is free.")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }

        HStack(spacing: Theme.Space.m) {
            Button {
                if let choice = s.choice { runBenchmark(choice.selection, language: s.language) }
            } label: {
                Label("Run Benchmark", systemImage: "speedometer")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(s.choice == nil || running || installed == false)
            .accessibilityLabel("Run the benchmark")
            .help(running ? "A benchmark is already running" : "Narrates a short passage and measures the speed")
            if let m = s.choice.flatMap({ c in model.engineList?.measured["\(c.selection.engineId)|\(c.selection.voiceId ?? "")"] }) {
                Text("Last measured: \(Formatters.charsPerSecond(m.charsPerS))\(m.realtimeX.map { " · " + Formatters.realtime($0) } ?? "")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Starts the benchmark, after the licence sheet the first time a non-commercial engine is used.
    private func runBenchmark(_ voice: VoiceSelection, language: String) {
        if let engine = model.bookLicenseToAcknowledge(voice: voice) {
            pendingLicense = BenchmarkLicenseRequest(engine: engine, voice: voice, language: language)
            return
        }
        model.startBenchmark(voice: voice, language: language)
    }

    private func noVoiceText(_ s: OpsBenchmarkSelection) -> String {
        if s.engine.supportsCloning && !s.engine.supportsPresets {
            return "\(s.engine.name) only clones voices. Install a \(Formatters.languageName(s.language)) voice on the Voices screen first."
        }
        if s.engine.supportsCloning {
            return "No \(Formatters.languageName(s.language)) voice for \(s.engine.name). Install one on the Voices screen."
        }
        return "\(s.engine.name) has no \(Formatters.languageName(s.language)) voice."
    }

    private func engineBinding(_ s: OpsBenchmarkSelection) -> Binding<String> {
        Binding(get: { s.engine.id }, set: { id in
            engineId = id
            choiceId = nil
        })
    }

    private func languageBinding(_ s: OpsBenchmarkSelection) -> Binding<String> {
        Binding(get: { s.language }, set: { lang in
            engineId = s.engine.id
            language = lang
            choiceId = nil
        })
    }

    private func choiceBinding(_ s: OpsBenchmarkSelection) -> Binding<String> {
        Binding(get: { s.choice?.id ?? "" }, set: { id in
            engineId = s.engine.id
            language = s.language
            choiceId = id
        })
    }

    // MARK: History

    // A list rather than a Table: six table columns need about 640 pt, more than the card has at the
    // default window size, which made the table scroll sideways. Sorting moved to a "Sort by" menu.
    @ViewBuilder
    private var historyCard: some View {
        let rows = sortKey.sorted(model.opsMeasuredRows, ascending: sortAscending)
        SurfaceCard("Measured on this Mac", systemImage: "clock.arrow.circlepath") {
            if !rows.isEmpty {
                HStack(spacing: Theme.Space.xs) {
                    Picker("Sort by", selection: $sortKey) {
                        ForEach(BenchmarkSortKey.allCases) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help(sortAscending ? "Ascending: click for descending" : "Descending: click for ascending")
                    .accessibilityLabel(sortAscending ? "Sorted ascending" : "Sorted descending")
                    .accessibilityHint("Reverses the order")
                }
            }
        } content: {
            if rows.isEmpty {
                Text("Nothing measured yet. Run a benchmark, make a sample or finish a conversion to record a speed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        BenchmarkHistoryRow(row: row)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Speeds measured on this Mac")
            }
        }
    }
}

/// What the measured-speeds list is sorted by.
private enum BenchmarkSortKey: String, CaseIterable, Identifiable {
    case date, speed, realtime, engine, voice, source
    var id: Self { self }

    var title: String {
        switch self {
        case .date: return "Date"
        case .speed: return "Speed"
        case .realtime: return "Real time"
        case .engine: return "Engine"
        case .voice: return "Voice"
        case .source: return "Measured by"
        }
    }

    func sorted(_ rows: [OpsMeasuredRow], ascending: Bool) -> [OpsMeasuredRow] {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .date: return rows.sorted(using: KeyPathComparator(\.updatedSortKey, order: order))
        case .speed: return rows.sorted(using: KeyPathComparator(\.charsPerSecond, order: order))
        case .realtime: return rows.sorted(using: KeyPathComparator(\.realtimeX, order: order))
        case .engine: return rows.sorted(using: KeyPathComparator(\.engineName, order: order))
        case .voice: return rows.sorted(using: KeyPathComparator(\.voiceName, order: order))
        case .source: return rows.sorted(using: KeyPathComparator(\.source, order: order))
        }
    }
}

/// One measured speed: voice and engine on the left, speed in the middle, how and when on the right.
private struct BenchmarkHistoryRow: View {
    let row: OpsMeasuredRow

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.voiceName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(row.engineName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.charsPerSecond(row.charsPerSecond))
                    .font(Theme.number(.body))
                Text(row.realtimeText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            VStack(alignment: .trailing, spacing: 3) {
                Chip(text: row.source)
                Text(row.updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 110, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.s + 2)
        .hoverHighlight()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.voiceName), \(row.engineName): \(Formatters.charsPerSecond(row.charsPerSecond)), \(row.realtimeText). \(row.source), \(row.updatedText)")
    }
}

/// A benchmark that waits for its engine's licence to be acknowledged.
private struct BenchmarkLicenseRequest: Identifiable {
    let engine: EngineInfo
    let voice: VoiceSelection
    let language: String
    var id: String { engine.id }
}

/// A benchmark started this session: progress while it runs, then its figures or its error.
private struct BenchmarkRunCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let run: BenchmarkRun

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Space.m + 2) {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    IconBadge(systemImage: "speedometer", tint: phaseTint, size: 36)
                        .symbolEffect(.pulse, options: .repeating, isActive: run.isRunning && !reduceMotion)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(run.voice.displayName(engines: model.engines, voices: model.voices))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Chip(text: Formatters.languageName(run.language), systemImage: "globe", tint: .secondary)
                    }
                    Spacer(minLength: Theme.Space.m)
                    Text(JobText.date(run.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch run.phase {
                case .finished:
                    if let result = run.result {
                        StatGrid(minWidth: 160) {
                            ForEach(JobResultSummary.benchmarkItems(result)) { item in
                                StatTile(label: item.label, value: item.value, systemImage: item.systemImage)
                            }
                        }
                    }
                case .failed:
                    OpsErrorBox(error: run.error ?? EngineError(message: "The benchmark failed."))
                case .cancelled:
                    Label("Stopped before it finished.", systemImage: "stop.circle")
                        .foregroundStyle(.secondary)
                default:
                    HStack(spacing: Theme.Space.m) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(run.statusText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Stop") { run.cancel() }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityLabel("Stop the benchmark")
                    }
                    .padding(Theme.Space.m)
                    .insetSurface()
                    .accessibilityElement(children: .contain)
                }
                ForEach(Array(run.notices.enumerated()), id: \.offset) { _, notice in
                    InlineBanner(systemImage: "info.circle", tint: .secondary) {
                        Text(notice)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .animation(reduceMotion ? nil : .smooth, value: run.phase)
        }
    }

    private var phaseTint: Color {
        switch run.phase {
        case .finished: return Theme.success
        case .failed: return Theme.danger
        case .cancelled: return .secondary
        default: return Theme.accent
        }
    }
}
