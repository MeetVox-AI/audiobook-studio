import SwiftUI

/// "Benchmark" screen (sidebar `.benchmark`): measure an engine + voice + language on this Mac
/// (`benchmark`), then the history of every speed measured here (`engines.measured`), which feeds the
/// estimates on the book screen.
struct BenchmarkView: View {
    @Environment(AppModel.self) private var model
    @State private var engineId: String?
    @State private var language: String?
    @State private var choiceId: String?
    @State private var sortOrder = [KeyPathComparator(\OpsMeasuredRow.updatedSortKey, order: .reverse)]
    /// Benchmark waiting for the licence of a non-commercial engine to be acknowledged (first use only).
    @State private var pendingLicense: BenchmarkLicenseRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("A benchmark narrates a short fixed passage to measure how fast an engine and voice run on this Mac. Estimates use the latest measurement, from a benchmark, a sample or a finished conversion.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                runCard
                ForEach(model.benchmarks.prefix(5)) { run in
                    BenchmarkRunCard(run: run)
                }
                historyCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
        OpsCard("Measure a voice") {
            if let selection {
                form(selection)
            } else if model.loading.contains(.engines) {
                ProgressView("Loading engines…")
            } else if let error = model.errors[.engines] {
                OpsErrorBox(error: error)
            } else {
                Text("No engines are available. Check the engine location in Settings.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func form(_ s: OpsBenchmarkSelection) -> some View {
        let installed = model.opsModelInstalled(s.engine.id)
        let running = model.benchmarks.contains { $0.isRunning }
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
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
                    ForEach(s.engine.languages, id: \.self) { code in
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
            HStack {
                OpsNotice(text: "The \(s.engine.name) model is not installed. Download it before measuring it.",
                          systemImage: "arrow.down.circle", tint: .orange)
                Button("Open Models") { model.selection = .models }
                    .accessibilityLabel("Open the Models screen to download this model")
            }
        }
        if model.activeJobCount > 0 {
            OpsNotice(text: "A conversion is running: the benchmark waits for the GPU and starts when it is free.",
                      systemImage: "hourglass")
        }

        HStack(spacing: 10) {
            Button {
                if let choice = s.choice { runBenchmark(choice.selection, language: s.language) }
            } label: {
                Label("Run Benchmark", systemImage: "speedometer")
            }
            .buttonStyle(.borderedProminent)
            .disabled(s.choice == nil || running || installed == false)
            .accessibilityLabel("Run the benchmark")
            .help(running ? "A benchmark is already running" : "Narrates a short passage and measures the speed")
            if let m = s.choice.flatMap({ c in model.engineList?.measured["\(c.selection.engineId)|\(c.selection.voiceId ?? "")"] }) {
                Text("Last measured: \(Formatters.charsPerSecond(m.charsPerS))\(m.realtimeX.map { " · " + Formatters.realtime($0) } ?? "")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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

    @ViewBuilder
    private var historyCard: some View {
        let rows = model.opsMeasuredRows.sorted(using: sortOrder)
        OpsCard("Measured on this Mac") {
            if rows.isEmpty {
                Text("Nothing measured yet. Run a benchmark, make a sample or finish a conversion to record a speed.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Engine", value: \.engineName)
                        .width(min: 110, ideal: 150)
                    TableColumn("Voice", value: \.voiceName)
                        .width(min: 110, ideal: 170)
                    TableColumn("Speed", value: \.charsPerSecond) { row in
                        Text(Formatters.charsPerSecond(row.charsPerSecond)).monospacedDigit()
                    }
                    .width(min: 125, ideal: 135)
                    TableColumn("Real time", value: \.realtimeX) { row in
                        Text(row.realtimeText).monospacedDigit()
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Measured by", value: \.source)
                        .width(min: 80, ideal: 100)
                    TableColumn("Date", value: \.updatedSortKey) { row in
                        Text(row.updatedText)
                    }
                    .width(min: 80, ideal: 110)
                }
                .frame(height: min(420, CGFloat(rows.count) * 26 + 34))
                .accessibilityLabel("Speeds measured on this Mac")
            }
        }
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
    let run: BenchmarkRun

    var body: some View {
        OpsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(run.voice.displayName(engines: model.engines, voices: model.voices))
                        .font(.headline)
                    Text(Formatters.languageName(run.language))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(JobText.date(run.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch run.phase {
                case .finished:
                    if let result = run.result {
                        OpsFigureGrid(items: JobResultSummary.benchmarkItems(result), minWidth: 140)
                    }
                case .failed:
                    OpsErrorBox(error: run.error ?? EngineError(message: "The benchmark failed."))
                case .cancelled:
                    Text("Stopped before it finished.")
                        .foregroundStyle(.secondary)
                default:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(run.statusText)
                        Spacer()
                        Button("Stop") { run.cancel() }
                            .accessibilityLabel("Stop the benchmark")
                    }
                    .accessibilityElement(children: .contain)
                }
                ForEach(Array(run.notices.enumerated()), id: \.offset) { _, notice in
                    OpsNotice(text: notice)
                }
            }
        }
    }
}
