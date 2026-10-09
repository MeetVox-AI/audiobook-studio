import SwiftUI

/// Voice browser: presets from `engines`, the reference library and the user's clips from `voices list`,
/// with filters (language, gender, engine, licence, search), install, preview, transcript editing.
struct VoiceBrowser: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void
    let addVoice: () -> Void

    var body: some View {
        let options = model.filteredVoiceOptions
        let groups = VoiceCatalog.groups(options, engines: model.engines)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VoiceSectionTitle("Voices", subtitle: subtitle)
                Spacer(minLength: 12)
                Button("Add My Voice…", action: addVoice)
                    .accessibilityLabel("Add my voice")
            }

            VoiceFilterBar()

            if let error = model.errors[.voices] {
                VoiceErrorNote(error: error)
            }

            if model.loading.contains(.voices) && model.voices.isEmpty {
                ProgressView("Loading voices…")
                    .accessibilityLabel("Loading voices")
            }

            Text(countText(options.count))
                .font(.callout)
                .foregroundStyle(.secondary)

            if options.isEmpty {
                ContentUnavailableView {
                    Label("No voices match", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Change the filters to see more voices.")
                } actions: {
                    Button("Show All Voices") { model.voiceLab.filter = VoiceFilter(language: .all) }
                        .accessibilityLabel("Clear the filters and show all voices")
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.options) { option in
                                VoiceOptionRow(option: option, perform: perform)
                                Divider()
                            }
                        } header: {
                            Text(group.title)
                                .font(.headline)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let cloners = model.engines.filter(\.supportsCloning).map(\.name)
        guard !cloners.isEmpty else { return "Preset voices are built into an engine." }
        return "Preset voices are built into an engine. Reference voices are short recordings that \(VoiceText.list(cloners)) imitate."
    }

    private func countText(_ n: Int) -> String { n == 1 ? "1 voice" : "\(Formatters.count(n)) voices" }
}

// MARK: - Filters

private struct VoiceFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var lab = model.voiceLab
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search by name, accent or description", text: $lab.filter.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .accessibilityLabel("Search voices")
            HStack(spacing: 14) {
                Picker("Language", selection: $lab.filter.language) {
                    Text(bookLanguageTitle).tag(VoiceLanguageFilter.book)
                    Text("All languages").tag(VoiceLanguageFilter.all)
                    Divider()
                    ForEach(model.voiceLanguages, id: \.self) { code in
                        Text(Formatters.languageName(code)).tag(VoiceLanguageFilter.only(code))
                    }
                }
                .fixedSize()
                .accessibilityLabel("Filter by language")

                Picker("Gender", selection: $lab.filter.gender) {
                    Text("Any").tag(String?.none)
                    ForEach(VoiceFilter.genders, id: \.self) { g in
                        Text(VoiceText.gender(g) ?? g).tag(Optional(g))
                    }
                }
                .fixedSize()
                .accessibilityLabel("Filter by gender")
            }
            HStack(spacing: 14) {
                Picker("Engine", selection: $lab.filter.engineId) {
                    Text("All engines").tag(String?.none)
                    ForEach(model.engines) { engine in
                        Text(engine.name).tag(Optional(engine.id))
                    }
                }
                .fixedSize()
                .accessibilityLabel("Filter by engine")
                .help("Only voices this engine can speak with. Reference voices you choose are cloned by this engine.")

                Picker("Licence", selection: $lab.filter.license) {
                    ForEach(VoiceLicenseFilter.allCases) { license in
                        Text(license.title).tag(license)
                    }
                }
                .fixedSize()
                .accessibilityLabel("Filter by licence")

                if lab.filter.isNarrowed {
                    Button("Reset Filters") { lab.filter = VoiceFilter() }
                        .accessibilityLabel("Reset the voice filters")
                }
            }
        }
    }

    private var bookLanguageTitle: String {
        guard let language = model.draft?.language else { return "Book language (no book open)" }
        return "Book language (\(Formatters.languageName(language)))"
    }
}

// MARK: - Row

/// One voice: facts, licence, actions (Use, Preview, Install, Play clip) and, for reference voices,
/// the transcript (editable once installed) and credits.
private struct VoiceOptionRow: View {
    @Environment(AppModel.self) private var model
    let option: VoiceOption
    let perform: (VoiceAction) -> Void
    @State private var showDetails = false
    @State private var error: EngineError?
    @State private var confirmingRemoval = false

    var body: some View {
        let target = model.voiceSelection(for: option)
        let chosen = option.isChosen(by: model.voiceSelection)
        let preview = target.flatMap { model.voicePreview(for: $0) }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(option.name)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        if let license = option.license {
                            VoiceLicenseBadge(license: license, noncommercial: personalUseOnly)
                        }
                    }
                    Text(facts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary = option.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                actions(target: target, chosen: chosen, preview: preview)
            }

            if let preview, preview.isRunning || preview.phase == .finished || preview.phase == .failed {
                VoiceSampleStatus(run: preview, name: "the preview of \(option.name)")
                    .padding(.leading, 30)
            }

            if option.isReference, let entry = option.entry {
                DisclosureGroup(isExpanded: $showDetails) {
                    VoiceReferenceDetails(option: option, entry: entry, confirmingRemoval: $confirmingRemoval, error: $error)
                        .padding(.top, 6)
                } label: {
                    Text(option.installed ? "Transcript and credits" : "Credits")
                        .font(.callout)
                }
                .padding(.leading, 30)
                .accessibilityLabel("Transcript and credits of \(option.name)")
            }

            if let error {
                VoiceErrorNote(error: error)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(option.name)\(chosen ? ", narrator" : "")")
        .confirmationDialog("Delete “\(option.name)”?", isPresented: $confirmingRemoval) {
            Button("Delete Voice", role: .destructive) { remove() }
                .accessibilityLabel("Delete the voice \(option.name)")
        } message: {
            Text("The copy of the recording kept by Audiobook Studio is deleted. Your original file is not touched.")
        }
    }

    /// The voice cannot be used commercially with any engine that can speak with it.
    private var personalUseOnly: Bool { !option.allowsCommercialUse(engines: model.engines) }

    /// "French · Female · Clone with Qwen3-TTS 1.7B or Fish Audio S2 Pro · 11 s recording".
    private var facts: String {
        var parts = [Formatters.languageName(option.language)]
        if let g = VoiceText.gender(option.gender) { parts.append(g) }
        if let accent = option.accent { parts.append("\(accent) accent") }
        let engineNames = option.engineIds.compactMap { id in model.engineList?.engine(id)?.name }
        switch option.kind {
        case .preset:
            if let name = engineNames.first { parts.append(name) }
        case .library, .userClip:
            if !engineNames.isEmpty { parts.append("Clone with " + engineNames.joined(separator: " or ")) }
            if let d = option.entry?.durationS { parts.append("\(Formatters.duration(d)) recording") }
            if !option.installed { parts.append("Not installed") }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(target: VoiceSelection?, chosen: Bool, preview: SampleRun?) -> some View {
        HStack(spacing: 8) {
            if option.isReference && !option.installed {
                if model.busyVoiceIds.contains(option.voiceId) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Installing \(option.name)")
                } else {
                    Button("Install") { install() }
                        .help("Downloads this reference recording (the internet is used for this step)")
                        .accessibilityLabel("Install the voice \(option.name)")
                }
            } else {
                if let path = option.entry?.path, option.isReference {
                    let url = URL(fileURLWithPath: path)
                    let playing = model.player.isPlaying(url)
                    Button {
                        model.player.toggle(url)
                    } label: {
                        Image(systemName: playing ? "stop.circle" : "waveform.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .help(playing ? "Stop the reference recording" : "Listen to the reference recording")
                    .accessibilityLabel(playing ? "Stop the reference recording of \(option.name)"
                                                : "Play the reference recording of \(option.name)")
                }
                if model.draft != nil, preview?.isReusablePreview != true {
                    let problem = model.voicePreviewProblem(target)
                    Button("Preview") {
                        if let target { perform(.preview(target)) }
                    }
                    .disabled(problem != nil)
                    .help(problem ?? "Hear this voice read the book (about \(Formatters.duration(VoiceLab.previewSeconds)))")
                    .accessibilityLabel("Preview \(option.name) reading the book")
                }
                if chosen {
                    Text("Narrator")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(option.name) is the narrator")
                } else {
                    Button("Use") {
                        if let target { perform(.select(target)) }
                    }
                    .disabled(target == nil)
                    .help(useHelp(target))
                    .accessibilityLabel("Use \(option.name) as the narrator")
                }
            }
        }
    }

    private func useHelp(_ target: VoiceSelection?) -> String {
        guard let target else { return "No installed engine can speak with this voice." }
        return "Narrate with \(target.displayName(engines: model.engines, voices: model.voices))"
    }

    private func install() {
        error = nil
        let id = option.voiceId
        Task {
            do { try await model.downloadVoice(id) } catch { self.error = EngineError(error) }
        }
    }

    private func remove() {
        error = nil
        let id = option.voiceId
        Task {
            do { try await model.removeVoice(id) } catch { self.error = EngineError(error) }
        }
    }
}

// MARK: - Reference voice details

/// Transcript (editable when installed), credits, source and remove for one reference voice.
private struct VoiceReferenceDetails: View {
    @Environment(AppModel.self) private var model
    let option: VoiceOption
    let entry: VoiceEntry
    @Binding var confirmingRemoval: Bool
    @Binding var error: EngineError?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if option.installed {
                VoiceTranscriptEditor(entry: entry)
            } else if let transcript = entry.transcript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript").font(.caption.weight(.semibold))
                    Text(transcript)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let attribution = entry.attribution, !attribution.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Credits").font(.caption.weight(.semibold))
                    Text(attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let source = entry.sourcePage, !source.isEmpty {
                Text("Source: \(source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if option.installed {
                let busy = model.busyVoiceIds.contains(entry.id)
                HStack(spacing: 8) {
                    if option.kind == .userClip {
                        Button("Delete Voice…", role: .destructive) { confirmingRemoval = true }
                            .disabled(busy)
                            .accessibilityLabel("Delete the voice \(entry.name)")
                    } else {
                        Button("Remove Download") { remove() }
                            .disabled(busy)
                            .help("Deletes the downloaded recording; you can install it again later")
                            .accessibilityLabel("Remove the downloaded voice \(entry.name)")
                    }
                    if busy {
                        ProgressView().controlSize(.small).accessibilityLabel("Working")
                    }
                }
            }
        }
    }

    private func remove() {
        error = nil
        let id = entry.id
        Task {
            do { try await model.removeVoice(id) } catch { self.error = EngineError(error) }
        }
    }
}

/// Editable transcript of an installed reference voice (`voices transcript`).
private struct VoiceTranscriptEditor: View {
    @Environment(AppModel.self) private var model
    let entry: VoiceEntry
    @State private var text = ""
    @State private var error: EngineError?
    @State private var justSaved = false

    private var original: String { entry.transcript ?? "" }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isChanged: Bool { trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { model.busyVoiceIds.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript").font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 54, maxHeight: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel("Transcript of \(entry.name)")
                .accessibilityHint("The exact words spoken in the reference recording")
            Text(VoiceText.transcriptSource(entry.transcriptSource))
                .font(.caption)
                .foregroundStyle(entry.transcriptSource == "whisper" ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Save Transcript") { save() }
                    .disabled(!isChanged || trimmed.isEmpty || isBusy)
                    .accessibilityLabel("Save the transcript of \(entry.name)")
                Button("Revert") { text = original }
                    .disabled(!isChanged || isBusy)
                    .accessibilityLabel("Undo the transcript changes")
                if isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving")
                } else if justSaved && !isChanged {
                    Label("Saved", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error { VoiceErrorNote(error: error) }
        }
        .onAppear { text = original }
        .onChange(of: entry.transcript) { _, new in
            text = new ?? ""
        }
    }

    private func save() {
        error = nil
        justSaved = false
        let id = entry.id, value = trimmed
        Task {
            do {
                let updated = try await model.updateTranscript(voiceId: id, text: value)
                text = updated.transcript ?? value
                justSaved = true
            } catch {
                self.error = EngineError(error)
            }
        }
    }
}
