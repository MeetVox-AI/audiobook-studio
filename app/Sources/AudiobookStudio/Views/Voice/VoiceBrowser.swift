import SwiftUI

/// Voice browser: presets from `engines`, the reference library and the user's clips from `voices list`,
/// with filters (language, gender, engine, licence, search), install, preview, transcript editing.
struct VoiceBrowser: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void
    let addVoice: () -> Void

    var body: some View {
        let options = model.filteredVoiceOptions
        let groups = VoiceCatalog.groups(options, engines: model.engines,
                                         accentLanguage: model.voiceLab.filter.languageCode(bookLanguage: model.draft?.language))
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader("Voices", subtitle: subtitle) {
                Button(action: addVoice) {
                    Label("Add My Voice…", systemImage: "plus")
                }
                .voiceCapsuleButton()
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
                .contentTransition(.numericText())

            if options.isEmpty {
                EmptyStateView(systemImage: "line.3.horizontal.decrease.circle", title: "No voices match",
                               message: "Change the filters to see more voices.") {
                    Button("Show All Voices") { model.voiceLab.filter = VoiceFilter(language: .all) }
                        .voiceCapsuleButton()
                        .accessibilityLabel("Clear the filters and show all voices")
                }
                .frame(maxWidth: .infinity)
                .surface()
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.options) { option in
                                VoiceOptionRow(option: option, perform: perform)
                            }
                        } header: {
                            Text(group.title)
                                .font(Theme.sectionTitle)
                                .padding(.top, Theme.Space.l)
                                .padding(.bottom, Theme.Space.xs)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var lab = model.voiceLab
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search by name, accent or description", text: $lab.filter.search)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search voices")
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .voiceTextField(focused: isSearchFocused)

            VoiceFlowLayout(spacing: Theme.Space.l, lineSpacing: Theme.Space.s) {
                Picker("Language", selection: $lab.filter.language) {
                    Text(bookLanguageTitle).tag(VoiceLanguageFilter.book)
                    Text("All languages").tag(VoiceLanguageFilter.all)
                    Divider()
                    ForEach(model.voiceLanguages, id: \.self) { code in
                        Text(Formatters.languageName(code)).tag(VoiceLanguageFilter.only(code))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Filter by language")

                Picker("Gender", selection: $lab.filter.gender) {
                    Text("Any").tag(String?.none)
                    ForEach(VoiceFilter.genders, id: \.self) { g in
                        Text(VoiceText.gender(g) ?? g).tag(Optional(g))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Filter by gender")

                Picker("Engine", selection: $lab.filter.engineId) {
                    Text("All engines").tag(String?.none)
                    ForEach(model.engines) { engine in
                        Text(engine.name).tag(Optional(engine.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Filter by engine")
                .help("Only voices this engine can speak with. Reference voices you choose are cloned by this engine.")

                Picker("Licence", selection: $lab.filter.license) {
                    ForEach(VoiceLicenseFilter.allCases) { license in
                        Text(license.title).tag(license)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Filter by licence")

                if lab.filter.isNarrowed {
                    Button("Reset Filters") { lab.filter = VoiceFilter() }
                        .voiceCapsuleButton()
                        .controlSize(.small)
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

    /// Avatar width plus the gap after it: sub-content lines up with the name.
    private static let avatarSize: CGFloat = 40
    private static let indent: CGFloat = avatarSize + Theme.Space.m

    var body: some View {
        let target = model.voiceSelection(for: option)
        let chosen = option.isChosen(by: model.voiceSelection)
        let preview = target.flatMap { model.voicePreview(for: $0) }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VoiceAvatar(name: option.name, language: option.language, size: Self.avatarSize, isSelected: chosen)
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    Text(option.name)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    VoiceFlowLayout(spacing: Theme.Space.xs + 2, lineSpacing: Theme.Space.xs + 2) {
                        chips
                    }
                    if let facts {
                        Text(facts)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let summary = option.summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                actions(target: target, chosen: chosen, preview: preview)
                    .frame(minHeight: Self.avatarSize)
            }

            if let preview, preview.isRunning || preview.phase == .finished || preview.phase == .failed {
                VoiceSampleStatus(run: preview, name: "the preview of \(option.name)")
                    .padding(Theme.Space.m - 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .insetSurface(radius: Theme.Radius.control)
                    .padding(.leading, Self.indent)
            }

            if option.isReference, let entry = option.entry {
                DisclosureGroup(isExpanded: $showDetails) {
                    VoiceReferenceDetails(option: option, entry: entry, confirmingRemoval: $confirmingRemoval, error: $error)
                        .padding(.top, Theme.Space.s)
                } label: {
                    Text(option.installed ? "Transcript and credits" : "Credits")
                        .font(.callout)
                }
                .padding(.leading, Self.indent)
                .accessibilityLabel("Transcript and credits of \(option.name)")
            }

            if let error {
                VoiceErrorNote(error: error)
                    .padding(.leading, Self.indent)
            }
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chosen ? Theme.accent.opacity(0.07) : Color.clear, in: .smooth(Theme.Radius.tile))
        .hoverHighlight(radius: Theme.Radius.tile)
        .surface(radius: Theme.Radius.tile)
        .overlay {
            if chosen {
                RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(option.name)\(chosen ? ", narrator" : "")")
        .contextMenu {
            if option.isReference && option.installed {
                if option.kind == .userClip {
                    Button("Delete Voice…", role: .destructive) { confirmingRemoval = true }
                } else {
                    Button("Remove Download") { remove() }
                }
            }
        }
        .confirmationDialog("Delete “\(option.name)”?", isPresented: $confirmingRemoval) {
            Button("Delete Voice", role: .destructive) { remove() }
                .accessibilityLabel("Delete the voice \(option.name)")
        } message: {
            Text("Audiobook Studio deletes its copy of the recording and its transcript. Your original file and the audiobooks you already made are not affected.")
        }
    }

    /// The voice cannot be used commercially with any engine that can speak with it.
    private var personalUseOnly: Bool { !option.allowsCommercialUse(engines: model.engines) }

    /// Language, gender, accent, licence, "Your voice" and install state as chips.
    @ViewBuilder
    private var chips: some View {
        Chip(text: Formatters.languageName(option.language), systemImage: "globe",
             tint: VoiceStyle.tint(forLanguage: option.language))
        if let browsed = model.voiceLab.filter.languageCode(bookLanguage: model.draft?.language),
           option.speaksWithAccent(browsed) {
            Chip(text: "Speaks \(Formatters.languageName(browsed)) with an accent", systemImage: "character.bubble",
                 tint: .secondary)
        }
        if let gender = VoiceText.gender(option.gender) {
            Chip(text: gender, systemImage: "person", tint: .secondary)
        }
        if let accent = option.accent {
            Chip(text: "\(accent) accent", systemImage: "character.bubble", tint: .secondary)
        }
        if option.kind == .userClip {
            Chip(text: "Your voice", systemImage: "person.crop.circle.fill", tint: Theme.highlight)
        }
        if let license = option.license {
            VoiceLicenseBadge(license: license, noncommercial: personalUseOnly)
        }
        if option.isReference && !option.installed {
            Chip(text: "Not installed", systemImage: "arrow.down.circle", tint: .secondary)
        }
    }

    /// What the chips do not say: "Clone with Qwen3-TTS 1.7B or Fish Audio S2 Pro · 11 s recording",
    /// or the preset's engine. nil when there is nothing left.
    private var facts: String? {
        var parts: [String] = []
        let engineNames = option.engineIds.compactMap { id in model.engineList?.engine(id)?.name }
        switch option.kind {
        case .preset:
            if let name = engineNames.first { parts.append(name) }
        case .library, .userClip:
            if !engineNames.isEmpty { parts.append("Clone with " + engineNames.joined(separator: " or ")) }
            if let d = option.entry?.durationS { parts.append("\(Formatters.duration(d)) recording") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(target: VoiceSelection?, chosen: Bool, preview: SampleRun?) -> some View {
        HStack(spacing: Theme.Space.s) {
            if option.isReference && !option.installed {
                if model.busyVoiceIds.contains(option.voiceId) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Installing \(option.name)")
                } else {
                    Button {
                        install()
                    } label: {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                    .voiceCapsuleButton()
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
                        Image(systemName: playing ? "stop.fill" : "waveform")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help(playing ? "Stop the reference recording" : "Listen to the reference recording")
                    .accessibilityLabel(playing ? "Stop the reference recording of \(option.name)"
                                                : "Play the reference recording of \(option.name)")
                }
                if model.draft != nil, preview?.isReusablePreview != true {
                    let problem = model.voicePreviewProblem(target)
                    Button("Preview") {
                        if let target { perform(.preview(target)) }
                    }
                    .voiceCapsuleButton()
                    .disabled(problem != nil)
                    .help(problem ?? "Hear this voice read the book (about \(Formatters.duration(VoiceLab.previewSeconds)))")
                    .accessibilityLabel("Preview \(option.name) reading the book")
                }
                if option.kind == .userClip && option.installed {
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(model.busyVoiceIds.contains(option.voiceId))
                    .help("Delete this voice")
                    .accessibilityLabel("Delete the voice \(option.name)")
                }
                if chosen {
                    Chip(text: "Narrator", systemImage: "checkmark", tint: Theme.accent, filled: true)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(option.name) is the narrator")
                } else {
                    Button("Use") {
                        if let target { perform(.select(target)) }
                    }
                    .voiceCapsuleButton()
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if option.installed {
                VoiceTranscriptEditor(entry: entry)
            } else if let transcript = entry.transcript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Transcript")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(transcript)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let attribution = entry.attribution, !attribution.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Credits")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let source = entry.sourcePage, !source.isEmpty {
                Label {
                    Text("Source: \(source)")
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "link")
                        .foregroundStyle(Theme.faint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if option.installed {
                let busy = model.busyVoiceIds.contains(entry.id)
                HStack(spacing: Theme.Space.s) {
                    if option.kind == .userClip {
                        Button("Delete Voice…", role: .destructive) { confirmingRemoval = true }
                            .voiceCapsuleButton()
                            .controlSize(.small)
                            .disabled(busy)
                            .accessibilityLabel("Delete the voice \(entry.name)")
                    } else {
                        Button("Remove Download") { remove() }
                            .voiceCapsuleButton()
                            .controlSize(.small)
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
    @FocusState private var isEditing: Bool

    private var original: String { entry.transcript ?? "" }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isChanged: Bool { trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { model.busyVoiceIds.contains(entry.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .focused($isEditing)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(Theme.Space.s - 2)
                .frame(minHeight: 54, maxHeight: 110)
                .voiceTextField(focused: isEditing)
                .accessibilityLabel("Transcript of \(entry.name)")
                .accessibilityHint("The exact words spoken in the reference recording")
            Text(VoiceText.transcriptSource(entry.transcriptSource))
                .font(.caption)
                .foregroundStyle(entry.transcriptSource == "whisper" ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Button("Save Transcript") { save() }
                    .voiceCapsuleButton(prominent: true)
                    .controlSize(.small)
                    .disabled(!isChanged || trimmed.isEmpty || isBusy)
                    .accessibilityLabel("Save the transcript of \(entry.name)")
                Button("Revert") { text = original }
                    .voiceCapsuleButton()
                    .controlSize(.small)
                    .disabled(!isChanged || isBusy)
                    .accessibilityLabel("Undo the transcript changes")
                if isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving")
                } else if justSaved && !isChanged {
                    Label {
                        Text("Saved")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Theme.success)
                    }
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
