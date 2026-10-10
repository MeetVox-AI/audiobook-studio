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
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
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
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xl)
            .screenWidth()
        }
        .background(AmbientBackground())
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
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // The window title already says "Voices" (and so does the voice list's header below), so the
            // book context stands alone here instead of under a third "Voices" title.
            Text(bookContext)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SurfaceCard("Narrator", systemImage: "person.wave.2.fill") {
                defaultControl
            } content: {
                HStack(alignment: .top, spacing: Theme.Space.l + 4) {
                    VoiceAvatar(name: voiceName, language: language, size: 76)
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(voiceName ?? title)
                                .font(.title.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                            if selection != nil {
                                VoiceFlowLayout(spacing: Theme.Space.xs + 2, lineSpacing: Theme.Space.xs + 2) {
                                    chips
                                }
                            }
                        }
                        if let selection {
                            HStack(spacing: Theme.Space.s) {
                                VoiceHeroFact(systemImage: "speedometer", label: "Speed",
                                              value: VoiceText.speed(selection.speed),
                                              accessibilityText: "Speed \(VoiceText.speed(selection.speed))")
                                VoiceHeroFact(systemImage: "checkmark.bubble", label: "Speech check",
                                              value: selection.verify ? "On" : "Off",
                                              accessibilityText: selection.verify ? "Speech check on" : "Speech check off")
                            }
                        }
                        warnings
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Narrator: \(title)")
        }
    }

    private var selection: VoiceSelection? { model.voiceSelection }
    private var engine: EngineInfo? { selection.flatMap { model.engineList?.engine($0.engineId) } }
    private var language: String? { selection?.language(engines: model.engines, voices: model.voices) }

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

    /// The voice's own name (preset or reference voice), without the engine; nil for an engine's default voice.
    private var voiceName: String? {
        guard let selection else { return nil }
        if let presetId = selection.presetId {
            return model.engines.first { $0.id == selection.engineId }?.voices.first { $0.id == presetId }?.name ?? presetId
        }
        if let refVoiceId = selection.refVoiceId {
            return model.voices.first { $0.id == refVoiceId }?.name ?? refVoiceId
        }
        return nil
    }

    @ViewBuilder
    private var chips: some View {
        if let selection {
            Chip(text: engine?.name ?? selection.engineId, systemImage: "waveform", tint: Theme.accent)
            if selection.isClone {
                Chip(text: "Cloned", systemImage: "person.wave.2", tint: .secondary)
            }
            if let language {
                Chip(text: Formatters.languageName(language), systemImage: "globe",
                     tint: VoiceStyle.tint(forLanguage: language))
            }
        }
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
                Label {
                    Text("Default for \(name) books")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.success)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("This narrator is the default for \(name) books")
            } else {
                Button("Use as Default for \(name)") {
                    model.saveVoiceAsDefault(for: language)
                }
                .voiceCapsuleButton()
                .help("New \(name) books start with this narrator, speed and speech check")
                .accessibilityLabel("Use this narrator as the default for \(name) books")
            }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if let selection, let engine {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
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
                        HStack(alignment: .center, spacing: Theme.Space.s) {
                            VoiceWarningLine("\(engine.name) has a non-commercial licence: personal use only.",
                                             systemImage: "exclamationmark.shield")
                            Button("Review Licence…") { reviewLicense(engine) }
                                .voiceCapsuleButton()
                                .controlSize(.small)
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

/// One fact of the narrator (speed, speech check): a small rounded figure over its label.
private struct VoiceHeroFact: View {
    let systemImage: String
    let label: String
    let value: String
    let accessibilityText: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.number(.title3))
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
            Label {
                Text(label)
            } icon: {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    // Dark mode: no accent-coloured symbol (hard to read); the label's secondary colour.
                    .foregroundStyle(ReadableForeground(Theme.accent, fallback: .secondary))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .insetSurface(radius: Theme.Radius.control)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
            EmptyStateView(systemImage: "waveform.slash", title: "No engines available",
                           message: model.errors[.engines]?.message ?? "The engine did not list any voices.") {
                Button("Try Again") {
                    Task { await model.refreshAll() }
                }
                .voiceCapsuleButton(prominent: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VoiceSectionTitle("Narration")
            SurfaceCard {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    speedRow
                    speechCheck
                }
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
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.m) {
                IconBadge(systemImage: "speedometer", size: 28)
                Text("Speed")
                    .font(.headline)
                Slider(value: speedBinding, in: VoiceSelection.speedRange, step: 0.05) {
                    Text("Speed")
                } minimumValueLabel: {
                    Text(VoiceText.speed(VoiceSelection.speedRange.lowerBound)).font(.caption)
                        .modifier(SliderValueLabelStyle())
                } maximumValueLabel: {
                    Text(VoiceText.speed(VoiceSelection.speedRange.upperBound)).font(.caption)
                        .modifier(SliderValueLabelStyle())
                }
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityLabel("Narration speed")
                .accessibilityValue(VoiceText.speed(speed))
                Text(VoiceText.speed(speed))
                    .font(Theme.number(.title3))
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: speed)
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityHidden(true)
                Button("Normal") { speedBinding.wrappedValue = 1.0 }
                    .voiceCapsuleButton()
                    .disabled(abs(speed - 1.0) < 0.001)
                    .accessibilityLabel("Reset the speed to normal")
            }
            Text(speedNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28 + Theme.Space.m)
        }
    }

    private var speedNote: String {
        guard let engine else { return "Choose a voice to set its speed." }
        if engine.supportsSpeed == true { return "\(engine.name) speaks at this speed itself." }
        return "\(engine.name) speaks at its natural pace; the finished audio is sped up or slowed down to this speed."
    }

    private var speechCheck: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                IconBadge(systemImage: "checkmark.bubble", size: 28)
                Toggle(isOn: verifyBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check every sentence with speech recognition")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("About +15% time. Sentences that come out wrong are made again; any still wrong are listed when the audiobook is done.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .accessibilityLabel("Check every sentence with speech recognition")
                .accessibilityHint("About 15 percent more time")
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let engine, !VoiceSelection.defaultVerify(engineId: engine.id) {
                    Text("Off by default for \(engine.name): it reads the same text the same way every time, so a second attempt rarely helps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.voiceSelection?.verify == true, model.isSpeechCheckModelMissing {
                    HStack(spacing: Theme.Space.s) {
                        VoiceWarningLine("The speech-recognition model is not installed.", systemImage: "arrow.down.circle")
                        Button("Open Models") { model.selection = .models }
                            .voiceCapsuleButton()
                            .controlSize(.small)
                            .accessibilityLabel("Open Models to install the speech-recognition model")
                    }
                }
            }
            .padding(.leading, 28 + Theme.Space.m)
        }
    }
}

/// The speed slider's value labels ("0.5×", "2×"). A tinted Slider draws them in its tint (the accent), and
/// inside it the hierarchical `.primary` / `.secondary` styles, so `ReadableForeground` too, resolve to that
/// tint. So in dark mode, when the accent is hard to read, they take the concrete secondary label colour (the
/// grey of an untinted slider's labels); otherwise they are left untouched and keep the accent as before.
private struct SliderValueLabelStyle: ViewModifier {
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        if Theme.isHardToRead(Theme.accent, in: environment) {
            content.foregroundStyle(Color.secondary)
        } else {
            content
        }
    }
}
