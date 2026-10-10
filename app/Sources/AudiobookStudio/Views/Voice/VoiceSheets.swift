import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add my voice

/// "Add my voice": a recording, a name, its language, an optional transcript and the consent checkbox.
/// `voices add ... --i-have-rights` is only run once the checkbox is ticked.
struct AddVoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with the new voice after the engine added it.
    let onAdded: (VoiceEntry) -> Void

    @State private var form = AddVoiceForm()
    @State private var isChoosingFile = false
    @State private var isAdding = false
    @State private var error: EngineError?
    @State private var didSetLanguage = false
    /// What the bottom bar says while adding ("Downloading Spanish…"); nil before the voice itself is added.
    @State private var step: String?
    @FocusState private var isEditingTranscript: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VoiceSheetHeader(systemImage: "waveform.badge.plus", tint: Theme.accent, title: "Add My Voice") {
                    Text("\(cloningEngines) can narrate in a voice they hear in a short recording. Use 10 to 20 seconds of one person speaking clearly, with no music or background noise. Longer recordings are trimmed to 20 seconds; at least 3 seconds of speech are needed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VoiceSheetGroup {
                    // Columns: the labels line up on the right, the fields on the left.
                    Form {
                        LabeledContent("Recording") {
                            HStack(spacing: Theme.Space.s + 2) {
                                Label {
                                    Text(form.file?.lastPathComponent ?? "No file chosen")
                                        .foregroundStyle(form.file == nil ? .secondary : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } icon: {
                                    Image(systemName: form.file == nil ? "waveform" : "waveform.circle.fill")
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundStyle(form.file == nil ? AnyShapeStyle(Theme.faint) : AnyShapeStyle(Theme.accentForeground))
                                }
                                Button(form.file == nil ? "Choose…" : "Change…") { isChoosingFile = true }
                                    .voiceCapsuleButton()
                                    .accessibilityLabel("Choose the recording")
                            }
                        }

                        LabeledContent("Name") {
                            TextField("Name", text: $form.name, prompt: Text("For example: My voice"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .accessibilityLabel("Voice name")
                        }

                        LabeledContent("Language") {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                languagePicker
                                languageNote
                            }
                        }
                    }
                    .formStyle(.columns)
                }

                VoiceCleanupOptions(isolate: $form.isolate, enhance: $form.enhance)

                VoiceSheetGroup {
                    Text("Transcript (optional)")
                        .font(.headline)
                    TextEditor(text: $form.transcript)
                        .focused($isEditingTranscript)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(Theme.Space.s - 2)
                        .frame(minHeight: 70, maxHeight: 110)
                        .voiceTextField(focused: isEditingTranscript)
                        .accessibilityLabel("Transcript of the recording, optional")
                    Text("The exact words spoken in the recording. Leave it empty to transcribe it automatically; you can correct it afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VoiceSheetGroup {
                    Toggle(isOn: $form.hasRights) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I have the right to use this voice")
                                .fontWeight(.medium)
                            Text("It is my own voice, or the speaker has allowed me to clone it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("I have the right to use this voice")
                    .accessibilityHint("Required. It is your own voice, or the speaker has allowed you to clone it.")
                }

                if let error { VoiceErrorNote(error: error) }
            }
            .padding(Theme.Space.xl)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(step ?? addingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let missing = form.missingStep {
                    Text(missing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                Button("Cancel") { dismiss() }
                    .voiceCapsuleButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                    .accessibilityLabel("Cancel adding a voice")
                Button("Add Voice") { add() }
                    .voiceCapsuleButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSubmit || isAdding)
                    .accessibilityLabel("Add the voice")
            }
            .controlSize(.large)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
        }
        .frame(width: 520, height: 600)
        .background(Theme.canvas)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { form.chooseFile(url) }
        }
        .onAppear {
            guard !didSetLanguage else { return }
            didSetLanguage = true
            form = AddVoiceForm(language: model.draft?.language, languages: model.cloningLanguageCodes)
        }
    }

    /// Segmented for two or three languages, a menu for more (only languages a cloning engine speaks are offered).
    @ViewBuilder
    private var languagePicker: some View {
        let picker = Picker("Language", selection: $form.language) {
            ForEach(form.languages, id: \.self) { code in
                Text(model.needsDownload(code) && form.languages.count > 3
                     ? "\(Formatters.languageName(code)) (not installed)" : Formatters.languageName(code)).tag(code)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Language spoken in the recording")
        if form.languages.count <= 3 {
            picker.pickerStyle(.segmented)
        } else {
            picker.pickerStyle(.menu)
        }
    }

    /// "Spanish is installed." or what will be downloaded first.
    @ViewBuilder
    private var languageNote: some View {
        let text = model.addVoiceLanguageNote(form.language)
        if !text.isEmpty {
            Label(text, systemImage: model.needsDownload(form.language) ? "arrow.down.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cloningEngines: String {
        let names = model.engines.filter(\.supportsCloning).map(\.name)
        return names.isEmpty ? "Cloning engines" : VoiceText.list(names)
    }

    /// "Cleaning, adding and transcribing the voice…"
    private var addingText: String {
        let cleaning = form.isolate || form.enhance ? "Cleaning and adding the voice" : "Adding the voice"
        return cleaning + (form.transcriptArgument == nil ? " and transcribing it…" : "…")
    }

    private func add() {
        guard let file = form.file, form.canSubmit else { return }
        error = nil
        isAdding = true
        let name = form.trimmedName, language = form.language
        let transcript = form.transcriptArgument, hasRights = form.hasRights
        let isolate = form.isolate, enhance = form.enhance
        Task {
            defer { isAdding = false; step = nil }
            do {
                if model.needsDownload(language) {
                    step = "Downloading \(Formatters.languageName(language))…"
                    try await model.addLanguage(language)
                }
                for id in model.missingCleanupModels(isolate: isolate, enhance: enhance) {
                    step = "Downloading \(VoiceCleanupOptions.title(id).lowercased())…"
                    try await model.downloadModel(id)
                }
                step = nil
                let entry = try await model.addVoice(file: file, name: name, language: language,
                                                     transcript: transcript, hasRights: hasRights,
                                                     isolate: isolate, enhance: enhance)
                dismiss()
                onAdded(entry)
            } catch {
                self.error = EngineError(error)
            }
        }
    }
}

// MARK: - Clean-up boxes

/// "Voice isolation" and "Voice enhancer", shared by "Add My Voice" and "Change Recording". Under a ticked box:
/// whether its model is installed or will be downloaded first.
struct VoiceCleanupOptions: View {
    @Environment(AppModel.self) private var model
    @Binding var isolate: Bool
    @Binding var enhance: Bool

    static func title(_ modelId: String) -> String {
        modelId == OpsModelInfo.voiceIsolationModel ? "Voice isolation" : "Voice enhancer"
    }

    var body: some View {
        VoiceSheetGroup {
            Text("Clean up the recording")
                .font(.headline)
            box($isolate, model: OpsModelInfo.voiceIsolationModel,
                detail: "Removes background noise and music, keeps the voice. DeepFilterNet3 · MIT.")
            box($enhance, model: OpsModelInfo.voiceEnhancerModel,
                detail: "Restores clear, studio-like speech. MossFormer2-SE · Apache-2.0. Slower.")
        }
    }

    private func box(_ isOn: Binding<Bool>, model modelId: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(modelId))
                        .fontWeight(.medium)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(Self.title(modelId))
            .accessibilityHint(detail)
            if isOn.wrappedValue, let note = model.cleanupModelNote(modelId) {
                Label(note.text, systemImage: note.installed ? "checkmark.circle" : "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)   // under the box's title, past the checkbox
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Change a voice's recording

/// "Change Recording" for one of the user's voices: choose a new file, or process the kept original again with
/// other clean-up boxes. The voice keeps its id, name, language and the places it is used.
struct ChangeRecordingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: VoiceEntry

    @State private var form: ChangeRecordingForm
    @State private var isChoosingFile = false
    @State private var isWorking = false
    @State private var step: String?
    @State private var error: EngineError?
    @FocusState private var isEditingTranscript: Bool

    init(entry: VoiceEntry) {
        self.entry = entry
        _form = State(initialValue: ChangeRecordingForm(entry: entry))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VoiceSheetHeader(systemImage: "arrow.triangle.2.circlepath", tint: Theme.accent,
                                 title: "Change Recording") {
                    Text("“\(entry.name)” keeps its name, language and the places it is used. Choose a new recording, or clean up the current one again.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VoiceSheetGroup {
                    Form {
                        LabeledContent("Current") {
                            Text(currentText)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LabeledContent("New recording") {
                            HStack(spacing: Theme.Space.s + 2) {
                                Text(form.file?.lastPathComponent ?? "None: reuse the current one")
                                    .foregroundStyle(form.file == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button(form.file == nil ? "Choose…" : "Change…") { isChoosingFile = true }
                                    .voiceCapsuleButton()
                                    .accessibilityLabel("Choose a new recording")
                                if form.file != nil {
                                    Button("Clear") { form.file = nil; form.hasRights = false }
                                        .voiceCapsuleButton()
                                        .accessibilityLabel("Keep the current recording")
                                }
                            }
                        }
                    }
                    .formStyle(.columns)
                }

                VoiceCleanupOptions(isolate: $form.isolate, enhance: $form.enhance)

                if form.isNewFile {
                    VoiceSheetGroup {
                        Text("Transcript (optional)")
                            .font(.headline)
                        TextEditor(text: $form.transcript)
                            .focused($isEditingTranscript)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .padding(Theme.Space.s - 2)
                            .frame(minHeight: 60, maxHeight: 100)
                            .voiceTextField(focused: isEditingTranscript)
                            .accessibilityLabel("Transcript of the new recording, optional")
                        Text("The exact words spoken in the new recording. Leave it empty to transcribe it automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VoiceSheetGroup {
                        Toggle(isOn: $form.hasRights) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("I have the right to use this voice")
                                    .fontWeight(.medium)
                                Text("It is my own voice, or the speaker has allowed me to clone it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("I have the right to use this voice")
                    }
                } else if form.hasOriginal {
                    Text("The transcript is kept when the cleaned clip is as long as before; otherwise it is transcribed again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error { VoiceErrorNote(error: error) }
            }
            .padding(Theme.Space.xl)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text(step ?? (form.isNewFile ? "Replacing the recording…" : "Processing the recording again…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let missing = form.missingStep {
                    Text(missing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                Button("Cancel") { dismiss() }
                    .voiceCapsuleButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(form.actionTitle) { submit() }
                    .voiceCapsuleButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canSubmit || isWorking)
            }
            .controlSize(.large)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
        }
        .frame(width: 520, height: 600)
        .background(Theme.canvas)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { form.chooseFile(url) }
        }
    }

    private var currentText: String {
        guard form.hasOriginal else { return "Original not saved (added before originals were kept)" }
        var boxes: [String] = []
        if form.currentIsolate { boxes.append("isolation") }
        if form.currentEnhance { boxes.append("enhancer") }
        let name = entry.originalName ?? "Your recording"
        return boxes.isEmpty ? name : "\(name) · \(boxes.joined(separator: " + "))"
    }

    private func submit() {
        guard form.canSubmit else { return }
        error = nil
        isWorking = true
        let f = form
        Task {
            defer { isWorking = false; step = nil }
            do {
                for id in model.missingCleanupModels(isolate: f.isolate, enhance: f.enhance) {
                    step = "Downloading \(VoiceCleanupOptions.title(id).lowercased())…"
                    try await model.downloadModel(id)
                }
                step = nil
                try await model.replaceVoice(id: f.voiceId, file: f.file, isolate: f.isolate, enhance: f.enhance,
                                             transcript: f.transcriptArgument, hasRights: f.hasRights)
                dismiss()
            } catch {
                self.error = EngineError(error)
            }
        }
    }
}

// MARK: - Licence acknowledgement

/// Shown before the first use of a non-commercial engine (Voxtral, Fish). The acknowledgement is
/// remembered per engine (`AppSettings.acknowledgeLicense(engine:)`).
struct VoiceLicenseSheet: View {
    let engine: EngineInfo
    /// Names of engines whose licence allows commercial use, offered as alternatives.
    let commercialEngines: [String]
    /// true: acknowledged; false: cancelled.
    let onDecision: (Bool) -> Void

    @State private var agreed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VoiceSheetHeader(systemImage: "exclamationmark.shield.fill", tint: Theme.warning,
                             title: "Non-commercial licence") {
                Chip(text: engine.license, systemImage: "doc.text", tint: Theme.warning)
                    .help(engine.license)
            }

            VoiceSheetGroup {
                Text("\(engine.name) has a non-commercial licence: \(engine.license).")
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Samples and audiobooks made with it are for personal use only. You may not sell them, publish them for money or use them in commercial work.")
                    .fixedSize(horizontal: false, vertical: true)
                if let notes = engine.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !commercialEngines.isEmpty {
                InlineBanner(systemImage: "lightbulb.fill", tint: Theme.accent) {
                    Text("For commercial use, choose \(VoiceText.list(commercialEngines, conjunction: "or")) instead.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VoiceSheetGroup {
                Toggle(isOn: $agreed) {
                    Text("I will use audio made with \(engine.name) for personal, non-commercial purposes only")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("I will use audio made with \(engine.name) for personal, non-commercial purposes only")
            }

            HStack(spacing: Theme.Space.m) {
                Spacer()
                Button("Cancel") { onDecision(false) }
                    .voiceCapsuleButton()
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel and keep the current engine")
                Button("Continue") { onDecision(true) }
                    .voiceCapsuleButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!agreed)
                    .accessibilityLabel("Acknowledge the licence and continue")
            }
            .controlSize(.large)
            .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .background(Theme.canvas)
    }
}

// MARK: - Sheet layout

/// A sheet's header: a tinted icon badge, the title and what follows it (explanation, licence chip).
private struct VoiceSheetHeader<Detail: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m + 2) {
            IconBadge(systemImage: systemImage, tint: tint, size: 46)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A group of related fields on a solid surface (the sheet's grouped content).
private struct VoiceSheetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            content
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Theme.Radius.tile)
    }
}
