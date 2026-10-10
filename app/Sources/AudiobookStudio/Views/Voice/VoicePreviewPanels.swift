import SwiftUI

/// "Preview on this book": a ~20 s sample of the chosen section read by the current narrator.
struct VoicePreviewPanel: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VoiceSectionTitle("Preview on this book",
                              subtitle: "About \(Formatters.duration(VoiceLab.previewSeconds)) of the book read by the narrator. It plays when ready.")
            SurfaceCard {
                if let draft = model.draft {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        VoicePreviewSectionPicker(draft: draft)
                        HStack(spacing: Theme.Space.m) {
                            Button {
                                if let v = model.voiceSelection { perform(.preview(v)) }
                            } label: {
                                Label("Preview Narrator", systemImage: "play.circle")
                            }
                            .voiceCapsuleButton(prominent: true)
                            .controlSize(.large)
                            .disabled(problem != nil || run?.isRunning == true)
                            .accessibilityLabel("Make a preview of the narrator reading this book")
                            if let problem {
                                Text(problem)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let run {
                            VoiceSampleStatus(run: run, name: "the preview of \(narratorName)")
                                .padding(Theme.Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .insetSurface()
                        }
                        if let message = model.player.errorMessage {
                            VoiceWarningLine(message)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VoiceNoBookPrompt()
                }
            }
        }
    }

    private var problem: String? { model.voicePreviewProblem(model.voiceSelection) }
    private var run: SampleRun? { model.voiceSelection.flatMap { model.voicePreview(for: $0) } }
    private var narratorName: String {
        model.voiceSelection?.displayName(engines: model.engines, voices: model.voices) ?? "the narrator"
    }
}

/// Which section previews and comparisons read (shared, so A and B read the same passage).
struct VoicePreviewSectionPicker: View {
    @Environment(AppModel.self) private var model
    let draft: BookDraft

    /// Tag for "the engine's first chapter".
    private static let automatic = -1

    var body: some View {
        let lab = model.voiceLab
        Picker("Read from", selection: Binding(
            get: { lab.previewSection(for: draft) ?? Self.automatic },
            set: { lab.setPreviewSection($0 == Self.automatic ? nil : $0, for: draft) })) {
            Text("First chapter (chosen by the engine)").tag(Self.automatic)
            Divider()
            ForEach(draft.sections) { section in
                Text(label(section)).tag(section.index)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityLabel("Section that previews read from")
        .help("Previews and comparisons read the start of this section")
    }

    private func label(_ s: SectionInfo) -> String {
        let title = s.title.count > 60 ? String(s.title.prefix(59)) + "…" : s.title
        return "\(title) (\(s.sectionKind.title))"
    }
}

/// "Compare two voices": samples of the same passage with voices A and B, played one after the other.
struct VoiceComparePanel: View {
    @Environment(AppModel.self) private var model
    let perform: (VoiceAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VoiceSectionTitle("Compare two voices",
                              subtitle: "Both voices read the same passage of the book, so you can hear the difference.")
            SurfaceCard {
                if let draft = model.draft {
                    content(draft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VoiceNoBookPrompt()
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ draft: BookDraft) -> some View {
        let choices = model.voiceComparisonChoices
        if choices.count < 2 {
            Label {
                Text("Install at least two voices that read \(Formatters.languageName(draft.language)) to compare them.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "rectangle.split.2x1")
                    .symbolRenderingMode(.hierarchical)
                    // Dark mode: no accent-coloured symbol (hard to read); the message's secondary colour.
                    .foregroundStyle(ReadableForeground(Theme.accent, fallback: .secondary))
            }
            .foregroundStyle(.secondary)
        } else {
            let ids = model.resolvedComparisonIds(in: choices)
            let lab = model.voiceLab
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    // White on indigo, near-black on amber: both letters stay readable in light and dark mode.
                    VoiceComparePickerTile(letter: "A", tint: Theme.accent, letterColor: .white,
                                           picker: picker("Voice A", choices: choices,
                                                          selection: Binding(get: { ids.a }, set: { lab.compareAId = $0 })))
                    VoiceComparePickerTile(letter: "B", tint: Theme.highlight, letterColor: Color(white: 0.1),
                                           picker: picker("Voice B", choices: choices,
                                                          selection: Binding(get: { ids.b }, set: { lab.compareBId = $0 })))
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.m) {
                    let pair = selections(ids, choices)
                    Button {
                        if let pair { perform(.compare(pair.a, pair.b)) }
                    } label: {
                        Label("Make Both Samples", systemImage: "rectangle.split.2x1")
                    }
                    .voiceCapsuleButton(prominent: true)
                    .controlSize(.large)
                    .disabled(compareProblem(pair) != nil || isComparing)
                    .accessibilityLabel("Make samples of voice A and voice B reading the same passage")
                    Text(compareProblem(pair) ?? "Reads the section chosen under Preview. The second sample starts when the first is done.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The last comparison, in its own row: it names the voices that were compared, which
                // stay the same when the pickers above change.
                if let comparison = model.currentVoiceComparison {
                    let runs = model.voiceComparisonRuns
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        VoiceCompareResult(letter: "A", voice: comparison.a.voice, run: runs.a, perform: perform)
                        VoiceCompareResult(letter: "B", voice: comparison.b.voice, run: runs.b, perform: perform)
                    }
                }
            }
        }
    }

    private var isComparing: Bool {
        let runs = model.voiceComparisonRuns
        return runs.a?.isRunning == true || runs.b?.isRunning == true
    }

    private func picker(_ title: String, choices: [VoiceChoice], selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            ForEach(choices) { choice in
                Text(choice.label).tag(Optional(choice.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(title)
    }

    private func selections(_ ids: (a: String?, b: String?), _ choices: [VoiceChoice]) -> (a: VoiceSelection, b: VoiceSelection)? {
        guard let a = choices.first(where: { $0.id == ids.a }), let b = choices.first(where: { $0.id == ids.b }) else { return nil }
        return (model.voiceSelection(for: a), model.voiceSelection(for: b))
    }

    private func compareProblem(_ pair: (a: VoiceSelection, b: VoiceSelection)?) -> String? {
        guard let pair else { return "Choose two voices." }
        if pair.a == pair.b { return "Choose two different voices." }
        return model.voicePreviewProblem(pair.a) ?? model.voicePreviewProblem(pair.b)
    }
}

/// One side of the A/B choice, as a tile: a letter badge, "Voice A" and the voice picker.
private struct VoiceComparePickerTile<PickerView: View>: View {
    let letter: String
    let tint: Color
    /// Colour of the letter on the tint (chosen for contrast with that tint).
    let letterColor: Color
    let picker: PickerView

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Text(letter)
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .foregroundStyle(letterColor)
                    .frame(width: 26, height: 26)
                    .background(tint, in: Circle())
                    .accessibilityHidden(true)
                Text("Voice \(letter)")
                    .font(.headline)
            }
            picker
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insetSurface()
    }
}

/// One side of the last A/B comparison: the compared voice, its sample and "Use Voice A".
private struct VoiceCompareResult: View {
    @Environment(AppModel.self) private var model
    let letter: String
    let voice: VoiceSelection
    let run: SampleRun?
    let perform: (VoiceAction) -> Void

    var body: some View {
        let name = voice.displayName(engines: model.engines, voices: model.voices)
        let chosen = model.voiceSelection == voice
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("\(letter) · \(name)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let run {
                VoiceSampleStatus(run: run, name: "sample \(letter), \(name)", playTitle: letter)
            }
            Button(chosen ? "Narrator" : "Use Voice \(letter)") { perform(.select(voice)) }
                .voiceCapsuleButton()
                .disabled(chosen)
                .accessibilityLabel(chosen ? "Voice \(letter) is the narrator" : "Use voice \(letter), \(name), as the narrator")
        }
        .padding(Theme.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .insetSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice \(letter): \(name)")
    }
}
