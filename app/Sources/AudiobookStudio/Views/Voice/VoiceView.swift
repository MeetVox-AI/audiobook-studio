import SwiftUI

/// "Voices" screen (sidebar `.voices`): choose the narrator for the open book.
///
/// Engine cards (licence, languages, speed measured on this Mac, install state), narration options
/// (speed, speech check), a ~20 s preview on the book, an A/B comparison of two voices on the same
/// passage, the voice browser (presets, the reference library, the user's clips, with filters,
/// install, transcript editing) and "Add my voice". Every choice lands in `model.voiceSelection`,
/// which the Book screen, samples and conversions use. Non-commercial engines ask for a licence
/// acknowledgement once (remembered per engine in Settings).
struct VoiceView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingLicense: PendingVoiceLicense?
    @State private var isAddingVoice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VoiceNarratorHeader(perform: perform, reviewLicense: reviewLicense)
                if model.engines.isEmpty {
                    VoiceEnginesUnavailable()
                } else {
                    VoiceEngineCards(perform: perform)
                    VoiceNarrationOptions()
                    VoicePreviewPanel(perform: perform)
                    VoiceComparePanel(perform: perform)
                    VoiceBrowser(perform: perform, addVoice: { isAddingVoice = true })
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Voices")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task {
                        async let e: Void = model.refreshEngines()
                        async let v: Void = model.refreshVoices()
                        async let m: Void = model.refreshModels()
                        _ = await (e, v, m)
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(isReloading)
                .help("Reload engines, models and voices")
                .accessibilityLabel("Reload engines, models and voices")

                Button {
                    isAddingVoice = true
                } label: {
                    Label("Add My Voice…", systemImage: "plus")
                }
                .help("Add a recording of a voice you have the right to use, to narrate with it")
                .accessibilityLabel("Add my voice")
            }
        }
        .sheet(item: $pendingLicense) { pending in
            VoiceLicenseSheet(engine: pending.engine, commercialEngines: commercialEngineNames) { accepted in
                pendingLicense = nil
                guard accepted else { return }
                model.settings.acknowledgeLicense(engine: pending.engine.id)
                // Another engine of the same action may still need its licence: check again.
                if let action = pending.action { perform(action) }
            }
        }
        .sheet(isPresented: $isAddingVoice) {
            AddVoiceSheet { entry in voiceAdded(entry) }
        }
    }

    private var isReloading: Bool {
        model.loading.contains(.engines) || model.loading.contains(.voices) || model.loading.contains(.models)
    }

    private var commercialEngineNames: [String] {
        model.engines.filter { !$0.noncommercial }.map(\.name)
    }

    /// Runs an action, showing the licence sheet first when it uses a non-commercial engine for the first time.
    private func perform(_ action: VoiceAction) {
        if let engine = model.engineNeedingLicense(for: action) {
            pendingLicense = PendingVoiceLicense(engine: engine, action: action)
            return
        }
        model.performVoiceAction(action)
    }

    /// Shows the licence of the engine already in use (e.g. a saved default) so the user can acknowledge it.
    private func reviewLicense(_ engine: EngineInfo) {
        pendingLicense = PendingVoiceLicense(engine: engine, action: nil)
    }

    /// A clip was added: make it the narrator when it reads the book's language.
    private func voiceAdded(_ entry: VoiceEntry) {
        let language = model.draft?.language ?? model.voiceSelection?.language(engines: model.engines, voices: model.voices)
        guard language == nil || language == entry.lang,
              let option = model.voiceOptions.first(where: { $0.voiceId == entry.id && $0.isReference }),
              let selection = model.voiceSelection(for: option) else { return }
        perform(.select(selection))
    }
}

/// The licence sheet to show and what to do once it is acknowledged (nil: only acknowledge).
struct PendingVoiceLicense: Identifiable {
    let id = UUID()
    let engine: EngineInfo
    let action: VoiceAction?
}

// MARK: - Narrator header

/// The current narrator, its problems (language, install, licence, speed) and "Use as default".
private struct VoiceNarratorHeader: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void
    let reviewLicense: (EngineInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(bookContext)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.wave.2.fill")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Narrator")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let details {
                            Text(details)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        warnings
                    }
                    Spacer(minLength: 12)
                    defaultControl
                }
                .padding(8)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Narrator: \(title)")
        }
    }

    private var selection: VoiceSelection? { model.voiceSelection }
    private var engine: EngineInfo? { selection.flatMap { model.engineList?.engine($0.engineId) } }

    private var bookContext: String {
        if let draft = model.draft {
            return "Choose who reads “\(draft.title)” (\(Formatters.languageName(draft.language))). Your choice is used for samples and the conversion."
        }
        return "No book is open. The voice you choose here is used for the next book you open in its language."
    }

    private var title: String {
        guard let selection else { return model.engines.isEmpty ? "No engines available" : "No voice chosen" }
        return selection.displayName(engines: model.engines, voices: model.voices)
    }

    private var details: String? {
        guard let selection else { return nil }
        var parts: [String] = []
        if let lang = selection.language(engines: model.engines, voices: model.voices) {
            parts.append(Formatters.languageName(lang))
        }
        parts.append("Speed \(VoiceText.speed(selection.speed))")
        parts.append(selection.verify ? "Speech check on" : "Speech check off")
        return parts.joined(separator: " · ")
    }

    /// Language the default applies to: the book's, else the narrator's own.
    private var defaultLanguage: String? {
        model.draft?.language ?? selection?.language(engines: model.engines, voices: model.voices)
    }

    @ViewBuilder
    private var defaultControl: some View {
        if let selection, let language = defaultLanguage,
           selection.fits(language: language, engines: model.engines, voices: model.voices) {
            let name = Formatters.languageName(language)
            if model.settings.defaultVoices[language] == selection {
                Label("Default for \(name) books", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("This narrator is the default for \(name) books")
            } else {
                Button("Use as Default for \(name)") {
                    model.saveVoiceAsDefault(for: language)
                }
                .help("New \(name) books start with this narrator, speed and speech check")
                .accessibilityLabel("Use this narrator as the default for \(name) books")
            }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if let selection, let engine {
            VStack(alignment: .leading, spacing: 6) {
                if let draft = model.draft,
                   !selection.fits(language: draft.language, engines: model.engines, voices: model.voices) {
                    VoiceWarningLine("This voice does not read \(Formatters.languageName(draft.language)), the book's language. Choose a \(Formatters.languageName(draft.language)) voice below.",
                                     systemImage: "character.bubble")
                }
                if model.isEngineMissing(engine.id) {
                    VoiceWarningLine("\(engine.name) is not installed yet. Download it from its card below.",
                                     systemImage: "arrow.down.circle")
                }
                if selection.voiceId == nil && !engine.supportsPresets {
                    VoiceWarningLine("\(engine.name) needs a reference voice. Choose one in the list below.",
                                     systemImage: "person.crop.circle.badge.questionmark")
                }
                if let slow = model.voiceEngineSummary(for: engine).slowWarning {
                    VoiceWarningLine(slow, systemImage: "tortoise")
                }
                if engine.noncommercial {
                    if model.settings.hasAcknowledgedLicense(engine: engine.id) {
                        VoiceLicenseBadge(license: engine.license, noncommercial: true)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            VoiceWarningLine("\(engine.name) has a non-commercial licence: personal use only.",
                                             systemImage: "exclamationmark.shield")
                            Button("Review Licence…") { reviewLicense(engine) }
                                .accessibilityLabel("Review the \(engine.name) licence")
                        }
                    }
                }
            }
        } else if selection == nil, !model.engines.isEmpty {
            Text("Pick an engine card or a voice below.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown instead of the screen when `engines` has not loaded.
private struct VoiceEnginesUnavailable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.loading.contains(.engines) {
            ProgressView("Loading engines and voices…")
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityLabel("Loading engines and voices")
        } else {
            ContentUnavailableView {
                Label("No engines available", systemImage: "waveform.slash")
            } description: {
                Text(model.errors[.engines]?.message ?? "The engine did not list any voices.")
            } actions: {
                Button("Try Again") {
                    Task { await model.refreshAll() }
                }
                .accessibilityLabel("Try loading the engines again")
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}

// MARK: - Narration options

/// Speed slider and the speech-check toggle of the current narrator.
private struct VoiceNarrationOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VoiceSectionTitle("Narration")
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    speedRow
                    Divider()
                    speechCheck
                }
                .padding(8)
            }
            .disabled(model.voiceSelection == nil)
        }
    }

    private var engine: EngineInfo? { model.voiceSelection.flatMap { model.engineList?.engine($0.engineId) } }
    private var speed: Double { model.voiceSelection?.speed ?? 1.0 }

    private var speedBinding: Binding<Double> {
        Binding(get: { model.voiceSelection?.speed ?? 1.0 },
                set: { model.voiceSelection?.speed = ($0 * 100).rounded() / 100 })
    }

    private var verifyBinding: Binding<Bool> {
        Binding(get: { model.voiceSelection?.verify ?? false },
                set: { model.voiceSelection?.verify = $0 })
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Speed")
                    .frame(width: 60, alignment: .leading)
                Slider(value: speedBinding, in: VoiceSelection.speedRange, step: 0.05) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text(VoiceText.speed(VoiceSelection.speedRange.lowerBound)).font(.caption)
                } maximumValueLabel: {
                    Text(VoiceText.speed(VoiceSelection.speedRange.upperBound)).font(.caption)
                }
                .labelsHidden()
                .accessibilityLabel("Narration speed")
                .accessibilityValue(VoiceText.speed(speed))
                Text(VoiceText.speed(speed))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Normal") { speedBinding.wrappedValue = 1.0 }
                    .disabled(abs(speed - 1.0) < 0.001)
                    .accessibilityLabel("Reset the speed to normal")
            }
            Text(speedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var speedNote: String {
        guard let engine else { return "Choose a voice to set its speed." }
        if engine.supportsSpeed == true { return "\(engine.name) speaks at this speed itself." }
        return "\(engine.name) speaks at its natural pace; the finished audio is sped up or slowed down to this speed."
    }

    private var speechCheck: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: verifyBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check every sentence with speech recognition")
                    Text("About +15% time. Sentences that come out wrong are made again; any still wrong are listed when the audiobook is done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityLabel("Check every sentence with speech recognition")
            .accessibilityHint("About 15 percent more time")
            if let engine, !VoiceSelection.defaultVerify(engineId: engine.id) {
                Text("Off by default for \(engine.name): it reads the same text the same way every time, so a second attempt rarely helps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.voiceSelection?.verify == true, model.isSpeechCheckModelMissing {
                HStack(spacing: 10) {
                    VoiceWarningLine("The speech-recognition model is not installed.", systemImage: "arrow.down.circle")
                    Button("Open Models") { model.selection = .models }
                        .accessibilityLabel("Open Models to install the speech-recognition model")
                }
            }
        }
    }
}
