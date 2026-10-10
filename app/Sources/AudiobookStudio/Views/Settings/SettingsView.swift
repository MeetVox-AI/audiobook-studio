import AppKit
import SwiftUI

/// Settings scene (⌘,): engine location (with Test), where audiobooks go, audio quality, notifications,
/// default narrator per language, pacing (stored only in v1), cache size with "Free Space", and the
/// keep-work option. Every change is saved at once (AppSettings writes UserDefaults on every change).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var section: SettingsSection = .general

    // The sections are switched with a segmented control rather than toolbar tabs: macOS draws the selected
    // toolbar tab's label in the accent colour, unreadable indigo in dark mode, and SwiftUI's tint does not
    // reach it. (TabView's .grouped style avoids that but drew its tab bar squashed on macOS 26.)
    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings section", selection: $section) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityLabel("Settings section")
            switch section {
            case .general: GeneralSettingsTab()
            case .voices: VoiceSettingsTab()
            case .languages: LanguageSettingsTab()
            case .storage: StorageSettingsTab()
            case .about: AboutSettingsTab()
            }
        }
        .frame(width: 680, height: 620)
        .navigationTitle(section.title)
    }
}

/// The sections of the Settings window.
private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, voices, languages, storage, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .voices: return "Voices"
        case .languages: return "Languages"
        case .storage: return "Storage"
        case .about: return "About"
        }
    }
}

/// The look shared by every settings tab: a grouped form (the macOS settings look), capsule buttons and
/// switches.
private struct SettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .buttonBorderShape(.capsule)
            .toggleStyle(.switch)
    }
}

/// A green confirmation line under a control ("The engine works: …", "Freed 335.1 MB.").
private struct SettingsSuccessLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(Theme.success)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            EngineLocationSection()

            Section {
                // Label on its own line with the folder underneath, both left-aligned (a LabeledContent value
                // this long wrapped onto a second line and sat indented).
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Save audiobooks")
                    HStack(spacing: 6) {
                        Image(systemName: settings.outputFolderURL == nil ? "book.closed" : "folder")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(settings.outputFolderURL.map { $0.path(percentEncoded: false) } ?? "Next to the book")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(settings.outputFolder ?? "In the same folder as the EPUB or PDF")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                HStack(spacing: Theme.Space.s) {
                    Button("Choose Folder…") { chooseOutputFolder() }
                        .accessibilityLabel("Choose the folder for finished audiobooks")
                    Button("Next to the Book") { settings.outputFolder = nil }
                        .disabled(settings.outputFolderURL == nil)
                        .accessibilityLabel("Save audiobooks next to their book")
                    Spacer()
                }
                Picker("Audio quality", selection: $settings.bitrateKbps) {
                    ForEach(AppSettings.bitrateChoices, id: \.self) { kbps in
                        Text(OpsAudioQuality.title(kbps: kbps)).tag(kbps)
                    }
                }
                .accessibilityLabel("Audio quality")
            } header: {
                Text("Audiobooks")
            } footer: {
                Text("\(OpsAudioQuality.caption(kbps: settings.bitrateKbps)) 64 kbps is plenty for a single narrator.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Notify me when a conversion finishes or fails", isOn: $settings.notificationsEnabled)
                    .accessibilityLabel("Notify me when a conversion finishes or fails")
                    .onChange(of: settings.notificationsEnabled) { _, on in
                        if on { Notifications.requestAuthorization() }
                    }
            } header: {
                Text("Notifications")
            } footer: {
                if !Notifications.isAvailable {
                    Text("Notifications appear only when Audiobook Studio runs as an installed app, not from a development build.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .modifier(SettingsFormStyle())
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where finished audiobooks are saved."
        panel.prompt = "Choose"
        if let current = model.settings.outputFolderURL { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.outputFolderURL = url
    }
}

/// Engine location: edit, Choose…, Test (runs `engines`), Use Default. A path that passes the test is
/// saved and everything is reloaded; a failing one can still be kept with "Use Anyway".
private struct EngineLocationSection: View {
    @Environment(AppModel.self) private var model
    @State private var pathDraft = ""
    @State private var isTesting = false
    @State private var testedPath: String?
    @State private var success: String?
    @State private var failure: EngineError?
    @FocusState private var isPathFocused: Bool

    var body: some View {
        Section {
            HStack {
                Text(model.needsSetup ? "The voice engine or its voices are not installed yet." : "Reinstall the engine or download more voices.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.needsSetup ? "Set Up…" : "Set Up Again…") { model.setup.present() }
                    .accessibilityLabel("Open the setup")
            }
            TextField("Location", text: $pathDraft, prompt: Text(EngineClient.defaultPath))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .labelsHidden()
                .focused($isPathFocused)
                .task {
                    // The window gives its first text field keyboard focus (whole path selected) when Settings
                    // opens; drop that, so the field is only edited when clicked.
                    await Task.yield()
                    isPathFocused = false
                }
                .onSubmit { test() }
                .accessibilityLabel("Engine location")
                .help("The audiobook-engine program")
            HStack(spacing: Theme.Space.s) {
                Button("Choose…") { chooseEngine() }
                    .accessibilityLabel("Choose the engine program")
                Button("Test") { test() }
                    .disabled(isTesting || trimmedDraft.isEmpty)
                    .accessibilityLabel("Test the engine at this location")
                    .help("Runs the engine once to list its voice engines")
                Button("Use Default") {
                    pathDraft = EngineClient.defaultPath
                    test()
                }
                .disabled(isTesting || (model.settings.enginePathOverride == nil && trimmedDraft == EngineClient.defaultPath))
                .accessibilityLabel("Use the default engine location")
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing the engine")
                }
                Spacer()
            }
            if let success {
                SettingsSuccessLabel(text: success)
            }
            if let failure {
                OpsErrorBox(error: failure) { self.failure = nil }
                if let testedPath, testedPath != model.settings.enginePath {
                    Button("Use This Location Anyway") {
                        model.settings.enginePath = testedPath
                        self.failure = nil
                        Task { await model.refreshAll() }
                    }
                    .accessibilityLabel("Save this engine location even though the test failed")
                }
            }
        } header: {
            Text("Engine")
        } footer: {
            Text(footer)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { pathDraft = model.settings.enginePath }
    }

    private var trimmedDraft: String { pathDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var footer: String {
        if model.settings.enginePathOverride == nil {
            return "Using the default location. A location that passes the test is saved and used right away."
        }
        return "Using a custom location. Default: \(EngineClient.defaultPath)"
    }

    private func test() {
        let path = trimmedDraft
        guard !path.isEmpty, !isTesting else { return }
        isTesting = true
        testedPath = path
        success = nil
        failure = nil
        Task {
            do {
                let list = try await model.testEngine(path: path)
                success = OpsEngineCheck.summary(list)
                isTesting = false
                if path != model.settings.enginePath || model.errors[.engines] != nil {
                    model.settings.enginePath = path
                    await model.refreshAll()
                }
            } catch {
                failure = EngineError(error)
                isTesting = false
            }
        }
    }

    private func chooseEngine() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // virtual environments live in hidden ".venv" folders
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the audiobook-engine program (for example inside the engine’s .venv/bin folder)."
        panel.prompt = "Choose"
        let current = URL(fileURLWithPath: trimmedDraft.isEmpty ? model.settings.enginePath : trimmedDraft)
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathDraft = url.path
        test()
    }
}

// MARK: - Voices

private struct VoiceSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ForEach(model.opsLanguages, id: \.self) { language in
                    DefaultVoicePicker(language: language)
                }
                if model.engines.isEmpty {
                    Label {
                        Text("Voices appear once the engine is reachable.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Default narrator")
            } footer: {
                Text("Used when you open a book in that language. “Automatic” picks an installed engine that allows commercial use first.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Between sentences", selection: $settings.pacing.sentence) { pauseOptions }
                    .accessibilityLabel("Pause between sentences")
                Picker("Between paragraphs", selection: $settings.pacing.paragraph) { pauseOptions }
                    .accessibilityLabel("Pause between paragraphs")
                Picker("Between chapters", selection: $settings.pacing.chapter) { pauseOptions }
                    .accessibilityLabel("Pause between chapters")
            } header: {
                Text("Pacing")
            } footer: {
                Text("Saved for a future version: the engine does not use these pauses yet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(SettingsFormStyle())
    }

    private var pauseOptions: some View {
        ForEach(PauseLength.allCases) { length in
            Text(length.title).tag(length)
        }
    }
}

/// "Automatic" or one engine voice for a language; keeps the saved speed and speech check when the same
/// voice is chosen again.
private struct DefaultVoicePicker: View {
    @Environment(AppModel.self) private var model
    let language: String

    var body: some View {
        let choices = model.opsNarratorChoices(language: language)
        let saved = model.settings.defaultVoices[language]
        let savedKey = saved.map(OpsNarratorChoice.key)
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Picker(Formatters.languageName(language), selection: binding(choices: choices)) {
                Text(automaticTitle).tag("")
                if !choices.isEmpty { Divider() }
                ForEach(choices) { choice in
                    Text(choice.pickerTitle).tag(choice.id)
                }
                if let saved, let savedKey, !choices.contains(where: { $0.id == savedKey }) {
                    Text("\(saved.displayName(engines: model.engines, voices: model.voices)) (not available)")
                        .tag(savedKey)
                }
            }
            .accessibilityLabel("Default narrator for \(Formatters.languageName(language)) books")
            if let saved {
                Text(details(saved))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var automaticTitle: String {
        guard let suggestion = VoiceSelection.suggested(for: language, engines: model.engines, voices: model.voices,
                                                       models: model.models) else { return "Automatic" }
        return "Automatic (\(suggestion.displayName(engines: model.engines, voices: model.voices)))"
    }

    private func details(_ v: VoiceSelection) -> String {
        let speed = abs(v.speed - 1) < 0.001 ? "normal speed" : "speed \(Formatters.multiplier(v.speed))"
        return "\(speed) · speech check \(v.verify ? "on" : "off")"
    }

    private func binding(choices: [OpsNarratorChoice]) -> Binding<String> {
        Binding(
            get: { model.settings.defaultVoices[language].map(OpsNarratorChoice.key) ?? "" },
            set: { id in
                guard !id.isEmpty, let choice = choices.first(where: { $0.id == id }) else {
                    if id.isEmpty { model.settings.defaultVoices[language] = nil }
                    return
                }
                if let current = model.settings.defaultVoices[language], OpsNarratorChoice.key(current) == id { return }
                model.settings.defaultVoices[language] = choice.selection
            })
    }
}

// MARK: - Languages

/// The 13 languages with what each costs: On (voices on disk) or Off (voices to download), Add / Remove, and for
/// a language no installed engine can speak, which engine to install (never downloaded without a click).
private struct LanguageSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                if model.languageRows.isEmpty {
                    if let error = model.errors[.languages] {
                        OpsErrorBox(error: error)
                    }
                    Label {
                        Text(model.loading.contains(.languages) ? "Loading the languages…"
                                                                : "Languages appear once the engine is reachable.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(model.languageRows) { row in
                    LanguageRow(row: row) {
                        model.selection = .models
                        WindowActions.showMainWindow(openWindow: openWindow)
                    }
                }
            } header: {
                Text("Languages")
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("English and French are on by default. Any other language is added only when you choose it, here or from a book in that language.")
                    Text("The voice models are shared by every language, so a language costs only its small reference voices. Nothing is downloaded unless you choose it: models are downloaded from Models.")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(SettingsFormStyle())
        .task { await model.refreshLanguages() }
    }
}

/// One language: names, state, cost, and the Add / Remove button.
private struct LanguageRow: View {
    @Environment(AppModel.self) private var model
    let row: LanguageRowState
    let openModels: () -> Void
    @State private var confirmRemoval = false

    private var info: LanguageInfo { row.info }
    private var download: LanguageDownload? { model.languageDownloads[row.code] }
    private var isRemoving: Bool { model.languageRemovals.contains(row.code) }
    private var isLastOn: Bool { row.isOn && model.enabledLanguageCodes.count <= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    VoiceFlowLayout(spacing: Theme.Space.s, lineSpacing: Theme.Space.xs) {
                        Text(info.native)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        if info.native != info.name {
                            Text(info.name)
                                .foregroundStyle(.secondary)
                        }
                        if row.isOn {
                            Chip(text: "On", systemImage: "checkmark.circle.fill", tint: Theme.success)
                        } else {
                            Chip(text: "Off", systemImage: "circle.dashed", tint: .secondary)
                        }
                    }
                    Text(statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
                action
            }
            if let need = row.need {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label {
                        Text(need)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(ReadableForeground(Theme.warning))
                    }
                    .font(.callout)
                    Text("Nothing is downloaded until you choose to.")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Models", action: openModels)
                        .controlSize(.small)
                        .accessibilityLabel("Open Models to install the engine \(info.name) needs")
                }
            }
            if let error = model.languageErrors[row.code] {
                OpsErrorBox(error: error) { model.clearLanguageMessages(row.code) }
            }
            if let result = model.languageResults[row.code] {
                SettingsSuccessLabel(text: result.summary(languageName: info.name))
                ForEach(result.notes, id: \.self) { note in
                    Label {
                        Text(note)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "info.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .confirmationDialog("Remove \(info.name)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove \(info.name)", role: .destructive) {
                Task { try? await model.removeLanguage(row.code) }
            }
            .accessibilityLabel("Remove \(info.name) and delete its voices")
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Keep \(info.name)")
        } message: {
            Text(row.removalMessage)
        }
    }

    private var statusLine: String {
        if let download { return download.statusText }
        if isRemoving { return "Removing the voices of \(info.name)…" }
        return row.detail
    }

    private var accessibilitySummary: String {
        "\(info.name), \(info.native), \(row.isOn ? "on" : "off"). \(statusLine)"
    }

    @ViewBuilder
    private var action: some View {
        if download != nil || isRemoving {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(download != nil ? "Adding \(info.name)" : "Removing \(info.name)")
        } else if row.isOn {
            Button("Remove") { confirmRemoval = true }
                .disabled(model.isChangingLanguage || isLastOn)
                .help(isLastOn ? "At least one language must stay on." : "Turns \(info.name) off and deletes its voices")
                .accessibilityLabel("Remove \(info.name)")
        } else {
            Button("Add") { Task { try? await model.addLanguage(row.code) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingLanguage)
                .help("Turns \(info.name) on and downloads its reference voices")
                .accessibilityLabel("Add \(info.name)")
        }
    }
}

// MARK: - Storage

private struct StorageSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmFree = false
    @State private var freedMessage: String?
    @State private var error: EngineError?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                cacheFigures
                HStack(spacing: Theme.Space.s) {
                    Button("Free Space…") {
                        freedMessage = nil
                        error = nil
                        confirmFree = true
                    }
                    .disabled(model.isClearingCache || model.activeJobCount > 0 || model.cacheInfo == nil)
                    .accessibilityLabel("Free disk space used by cached audio")
                    .help(model.activeJobCount > 0 ? "A conversion is running; free space after it finishes."
                                                   : "Deletes cached audio; finished audiobooks are kept")
                    Button("Refresh") {
                        Task { await model.refreshCache() }
                    }
                    .disabled(model.loading.contains(.cache))
                    .accessibilityLabel("Measure the cache size again")
                    if model.isClearingCache || model.loading.contains(.cache) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Working")
                    }
                    Spacer()
                }
                if model.activeJobCount > 0 {
                    Label {
                        Text("A conversion is running; free space after it finishes.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "hourglass")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .foregroundStyle(.secondary)
                }
                if let freedMessage {
                    SettingsSuccessLabel(text: freedMessage)
                }
                if let error {
                    OpsErrorBox(error: error) { self.error = nil }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("Cached audio lets a stopped conversion resume without narrating again. Finished audiobooks are never deleted.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Keep chapter audio files after a conversion", isOn: $settings.keepWork)
                    .accessibilityLabel("Keep chapter audio files after a conversion")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Off by default: chapter files are deleted once the audiobook is made, to save disk space. Turn on only for troubleshooting.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(SettingsFormStyle())
        .task { await model.refreshCache() }
        .confirmationDialog("Free disk space?", isPresented: $confirmFree, titleVisibility: .visible) {
            if let info = model.cacheInfo {
                Button("Delete Cached Audio (\(Formatters.bytes(info.chunksBytes)))", role: .destructive) { free(includeJobs: false) }
                    .accessibilityLabel("Delete cached audio only")
                Button("Also Delete Finished Job Folders (\(Formatters.bytes(info.totalBytes)))", role: .destructive) {
                    free(includeJobs: true)
                }
                .accessibilityLabel("Delete cached audio and finished job folders")
            }
            Button("Cancel", role: .cancel) {}
                .accessibilityLabel("Keep everything")
        } message: {
            Text("Finished audiobooks are kept. Deleting job folders also removes those jobs, with their progress history, from the Jobs list.")
        }
    }

    @ViewBuilder
    private var cacheFigures: some View {
        if let info = model.cacheInfo {
            StatGrid(minWidth: 150) {
                StatTile(label: "Cached audio", value: Formatters.bytes(info.chunksBytes),
                         systemImage: "waveform", tint: Theme.accent)
                StatTile(label: "Job folders", value: Formatters.bytes(info.jobsBytes),
                         systemImage: "folder", tint: Theme.highlight)
                StatTile(label: "Total", value: Formatters.bytes(info.totalBytes),
                         systemImage: "internaldrive", tint: Theme.accent)
            }
            .padding(.vertical, Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Location")
                HStack(spacing: 6) {
                    Text(info.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(info.path)
                    Button {
                        FileActions.revealInFinder(URL(fileURLWithPath: info.path))
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show the engine’s data folder in Finder")
                    .help("Show in Finder")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.errors[.cache] {
            OpsErrorBox(error: error)
        } else if model.loading.contains(.cache) {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            Text("The cache size is not known yet.").foregroundStyle(.secondary)
        }
    }

    private func free(includeJobs: Bool) {
        error = nil
        freedMessage = nil
        Task {
            do {
                let bytes = try await model.clearCache(includeFinishedJobs: includeJobs)
                freedMessage = OpsCacheText.freed(bytes)
            } catch {
                self.error = EngineError(error)
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @Environment(Updater.self) private var updater
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return short
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: version)
                if updater.isAvailable {
                    Toggle("Download and install updates automatically", isOn: Binding(
                        get: { updater.automaticallyUpdates },
                        set: { updater.automaticallyUpdates = $0 }))
                        .accessibilityLabel("Download and install updates automatically")
                    HStack {
                        Button("Check for Updates Now") { updater.checkForUpdates() }
                            .accessibilityLabel("Check for updates now")
                        Spacer()
                    }
                }
            } header: {
                Text("Audiobook Studio")
            } footer: {
                Text(updater.isAvailable
                     ? "Audiobook Studio checks once a day. A new version is downloaded in the background and installed the next time you quit the app. A conversion in progress is never interrupted."
                     : "This is a development build: automatic updates are off.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LegalPoints()
                    .padding(.vertical, Theme.Space.xs)
            } header: {
                Text("Terms of use")
            } footer: {
                Text("You accepted these terms when you first opened the app. They apply to every use of it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(LegalText.licences.enumerated()), id: \.offset) { _, item in
                    LabeledContent(item.name) {
                        Text(item.licence)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Licences")
            } footer: {
                Text("Each component keeps its own licence. Audiobooks made from books you do not hold the rights to are for personal use only.")
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(SettingsFormStyle())
    }
}
