import AppKit
import SwiftUI

/// First-run setup, shown over the window: welcome → languages → voice models → review → progress → done.
/// Every step can be skipped ("Skip for now"); the same flow reopens from Settings or the banner.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var flow: SetupFlow { model.setup }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(spacing: Theme.Space.l) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    stepContent
                        .id(flow.step)
                        .transition(.opacity)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 580, alignment: .leading)
                .surface()
                if flow.step != .welcome && flow.step != .done {
                    StepDots(current: flow.step)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: flow.step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set up Audiobook Studio")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .welcome: WelcomeStep()
        case .languages: LanguagesStep()
        case .models: ModelsStep()
        case .review: ReviewStep()
        case .working: WorkingStep()
        case .done: DoneStep()
        }
    }
}

// MARK: - Pieces

private struct StepDots: View {
    let current: SetupStep
    var body: some View {
        HStack(spacing: 6) {
            ForEach([SetupStep.languages, .models, .review, .working], id: \.self) { s in
                Capsule()
                    .fill(s == current ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: s == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StepHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            IconBadge(systemImage: systemImage, size: 44)
            Text(title)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A language choice: native name, English name, a checkmark. Compact, for a grid.
private struct LanguageCell: View {
    let code: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let entry = LanguageRegistry.builtin[code]
        let name = entry?.name ?? code
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                // Every cell is as tall as a two-line one (native name + English name). A language whose two names
                // are the same, English, has one line: it is centred in that height so the grid stays uniform.
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Xy").font(.headline)
                        Text("Xy").font(.caption)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry?.native ?? name).font(.headline)
                            .environment(\.layoutDirection, entry?.rtl == true ? .rightToLeft : .leftToRight)
                        if entry?.native != name { Text(name).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.08) : Theme.inset, in: .smooth(Theme.Radius.tile))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(isOn ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: isOn ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(entry.map { $0.native == name ? name : "\(name), \($0.native)" } ?? name)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
    }
}

/// The non-blocking note about languages no chosen voice speaks, with a one-tap suggestion.
private struct CoverageNotice: View {
    @Environment(AppModel.self) private var model
    var showAction = true

    var body: some View {
        let flow = model.setup
        if let note = flow.coverageNote {
            InlineBanner(systemImage: "text.bubble", tint: Theme.warning) {
                Text(note).fixedSize(horizontal: false, vertical: true)
                if showAction, !flow.suggestedEngines.isEmpty {
                    let names = flow.suggestedEngines.compactMap { SetupCatalog.engineNames[$0] }.joined(separator: " and ")
                    Button("Add \(names)") { flow.acceptSuggestion() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .accessibilityLabel("Add \(names) to your choices")
                }
            }
        }
    }
}

private struct Footer<Leading: View>: View {
    @Environment(AppModel.self) private var model
    var primaryTitle: String
    var primaryEnabled = true
    var showSkip = true
    var primary: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack {
            leading
            if showSkip {
                Button("Skip for Now") { model.setup.dismiss() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Look around first. You can finish the setup later from the banner or Settings.")
                    .accessibilityLabel("Skip the setup for now")
            }
            Spacer()
            Button(primaryTitle, action: primary)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!primaryEnabled)
                .accessibilityLabel(primaryTitle)
        }
        .padding(.top, Theme.Space.s)
    }
}

private extension Footer where Leading == EmptyView {
    init(primaryTitle: String, primaryEnabled: Bool = true, showSkip: Bool = true, primary: @escaping () -> Void) {
        self.init(primaryTitle: primaryTitle, primaryEnabled: primaryEnabled, showSkip: showSkip, primary: primary, leading: { EmptyView() })
    }
}


/// A voice model as a selectable card: tier, exact model, download size, speed, languages and licence.
private struct ModelCard: View {
    let choice: SetupModelChoice
    var tag: String?
    let installed: Bool
    var coverage: String?
    /// "Required for Dutch, Arabic": the card cannot be unticked while those languages are on.
    var lock: String?
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var identity: String {
        choice.title == choice.modelName ? "by \(choice.maker)" : "Model: \(choice.modelName), by \(choice.maker)"
    }

    private var sizeValue: String { SetupCatalog.sizeText(choice.gb) }

    private var licenceLine: String { "\(choice.licenseSummary). Licence: \(choice.licenseName)." }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        Text(choice.title).font(.headline)
                        if let tag { Chip(text: tag, tint: .secondary) }
                        if let lock { Chip(text: lock, systemImage: "lock.fill", tint: .secondary) }
                    }
                    Text(identity).font(.subheadline.weight(.medium))
                    Text(choice.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let speed = choice.speed {
                        Label {
                            Text([speed + ".", choice.bookTime].compactMap { $0 }.joined(separator: " "))
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "speedometer")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if let coverage {
                        Text(coverage).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Theme.Space.s) {
                        Chip(text: choice.licenseSummary, systemImage: choice.noncommercial ? "person.fill" : "checkmark.seal",
                             tint: choice.noncommercial ? Theme.warning : Theme.success)
                        Text(choice.licenseName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(installed ? "Installed" : sizeValue).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(installed ? "\(sizeValue) on disk" : "download").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.08)
                        : choice.noncommercial ? Theme.warning.opacity(0.06) : Theme.inset, in: .smooth(Theme.Radius.tile))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(isOn ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: isOn ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityHint(([choice.detail, coverage, lock.map { "\($0). It cannot be unselected while those languages are on." }].compactMap { $0 }).joined(separator: " "))
    }

    private var label: String {
        var parts = [choice.title]
        if let tag { parts.append(tag) }
        if let lock { parts.append(lock) }
        parts.append(choice.title == choice.modelName ? choice.modelName : "model \(choice.modelName)")
        parts.append(installed ? "installed, \(sizeValue) on disk" : "\(sizeValue) download")
        if let speed = choice.speed { parts.append(speed + ". " + (choice.bookTime ?? "")) }
        parts.append(licenceLine)
        return parts.joined(separator: ", ")
    }
}

/// "What the licences mean", always visible beside the cards.
private struct LicenseExplainer: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("What the licences mean").font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Label(SetupCatalog.freeLicenceMeaning, systemImage: "checkmark.seal")
            Label(SetupCatalog.personalLicenceMeaning, systemImage: "person.fill")
            Text(SetupCatalog.rightsNote).padding(.leading, 22)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurface(radius: Theme.Radius.tile)
        .accessibilityElement(children: .combine)
    }
}

/// A fixed line under "Also needed" (not a choice): an icon, a title, a note and a size.
private struct NeededLine: View {
    let systemImage: String
    let title: String
    let note: String
    let badge: String?
    let size: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: systemImage).symbolRenderingMode(.hierarchical).font(.title3)
                .foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(title).font(.headline)
                    if let badge { Chip(text: badge, tint: .secondary) }
                }
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Text(size).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetSurface(radius: Theme.Radius.tile)
        .accessibilityElement(children: .combine)
    }
}

private struct ToolsLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let installed = model.setup.engineInstalled
        NeededLine(systemImage: "gearshape.2", title: "Voice engine tools",
                   note: "The Python environment, ffmpeg and espeak-ng that run the voices. Free software.",
                   badge: installed ? "Installed" : "Required",
                   size: installed ? "Installed" : "about \(SetupCatalog.sizeText(SetupCatalog.engineGB))")
    }
}

private struct VoicesLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        let count = flow.languagePlan.add.count
        NeededLine(systemImage: "person.wave.2", title: "Reference voices",
                   note: "Small voice samples for your \(count == 1 ? "language" : "\(count) languages"), about \(Int(SetupCatalog.voiceMBPerLanguage)) MB each.",
                   badge: nil, size: "about \(SetupCatalog.sizeText(flow.voicesMB / 1000))")
    }
}

/// Stays under the cards: what is left to download, that it happens once, and the free space.
private struct DownloadSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if flow.chosen.isEmpty {
                        Text("Choose at least one voice to continue.").font(.headline)
                    } else if flow.neededGB <= 0 {
                        Text("Nothing to download").font(.headline)
                        Text("What you chose is already installed.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Total download: \(SetupCatalog.sizeText(flow.neededGB))").font(.headline).monospacedDigit()
                        Text("One time. Works offline afterwards.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text("\(flow.prerequisites.freeGB) GB free on this Mac")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            if let warning = flow.spaceWarning {
                InlineBanner(systemImage: "externaldrive.badge.exclamationmark", tint: Theme.warning) { Text(warning) }
            }
        }
        .padding(Theme.Space.m)
        .insetSurface(radius: Theme.Radius.tile)
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "books.vertical.fill", title: "Welcome to Audiobook Studio",
                       subtitle: "Turn any EPUB or PDF into an audiobook, narrated by AI voices that run entirely on this Mac. Nothing you read leaves it.")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("Pick your languages and voices", systemImage: "globe")
                Label("Voice models are large, from 0.35 to 6.7 GB; you see every size first", systemImage: "arrow.down.circle")
                Label("They download once, then work offline", systemImage: "wifi.slash")
            }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            Footer(primaryTitle: "Get Started") { model.setup.step = .languages }
        }
    }
}

private struct LanguagesStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "globe", title: "Which languages do you read?",
                       subtitle: "Choose the languages of your books. Each one adds only its small reference voices (about \(Int(SetupCatalog.voiceMBPerLanguage)) MB); the voice models are shared. You can change this any time in Settings.")
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s)], spacing: Theme.Space.s) {
                    ForEach(LanguageRegistry.codes, id: \.self) { code in
                        LanguageCell(code: code, isOn: flow.languages.contains(code)) { flow.toggleLanguage(code) }
                    }
                }
                .padding(1)
            }
            .frame(maxHeight: 320)
            .accessibilityLabel("Languages")
            Text(flow.languages.count == 1 ? "1 language selected" : "\(flow.languages.count) languages selected")
                .font(.callout).foregroundStyle(.secondary)
            Label(flow.languageNeedsSummary, systemImage: "waveform")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(flow.languageNeedsSummary)
            Footer(primaryTitle: "Continue", primary: { flow.step = .models }) {
                Button("Back") { flow.step = .welcome }.accessibilityLabel("Go back")
            }
        }
    }
}

private struct ModelsStep: View {
    @Environment(AppModel.self) private var model
    @State private var showOther = false

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "waveform", title: "Choose your voices",
                       subtitle: "Your languages decide which voices are needed; you can add others. Quick is good for drafts and High quality for the final version. Nothing is downloaded until you choose it and press Install on the last step.")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    LicenseExplainer()
                    VStack(spacing: Theme.Space.s) {
                        ForEach(SetupCatalog.tiers) { card($0, tag: $0.id == "qwen3" ? "Recommended" : nil) }
                    }
                    Text(SetupCatalog.benchmarkNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Also needed").font(.headline).padding(.top, Theme.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: Theme.Space.s) {
                        ToolsLine()
                        if !flow.languagePlan.add.isEmpty { VoicesLine() }
                        card(SetupCatalog.quality, tag: "Optional, recommended")
                    }
                    DisclosureGroup("Other options", isExpanded: $showOther) {
                        VStack(spacing: Theme.Space.s) {
                            Text("Not one of the three tiers. Use it for languages the tiers do not cover.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(SetupCatalog.other) { card($0, tag: nil) }
                        }
                        .padding(.top, Theme.Space.s)
                    }
                    .accessibilityLabel("Other options: Voxtral 4B, for personal use only")
                    CoverageNotice()
                }
                .padding(1)
            }
            .frame(maxHeight: 400)
            if let notice = flow.notice {
                InlineBanner(systemImage: "lock.fill", tint: Theme.warning) { Text(notice).fixedSize(horizontal: false, vertical: true) }
            }
            DownloadSummary()
            Footer(primaryTitle: "Continue", primaryEnabled: !flow.chosen.isEmpty, primary: {
                flow.recheckPrerequisites(); flow.step = .review
            }) {
                Button("Back") { flow.step = .languages }.accessibilityLabel("Go back")
            }
        }
        .onAppear { showOther = flow.chosen.contains("voxtral") }
        .onChange(of: flow.chosen.contains("voxtral")) { _, on in if on { showOther = true } }
    }

    private func card(_ choice: SetupModelChoice, tag: String?) -> some View {
        let flow = model.setup
        var coverage: String?
        if let c = flow.coverage(of: choice.id), !flow.languages.isEmpty {
            coverage = c.missing.isEmpty ? "Narrates \(c.speaks.count == 1 ? "your language" : "all your languages")."
                : c.speaks.isEmpty ? "Does not narrate \(SetupCatalog.languageList(c.missing))."
                : "Narrates \(SetupCatalog.languageList(c.speaks)); not \(SetupCatalog.languageList(c.missing))."
        }
        if choice.id == "kokoro", let draft = flow.quickDraftNote { coverage = [coverage, draft].compactMap { $0 }.joined(separator: " ") }
        return ModelCard(choice: choice, tag: tag, installed: flow.isInstalled(choice.id), coverage: coverage,
                         lock: flow.lockLabel(choice.id), isOn: flow.chosen.contains(choice.id)) {
            // A refused untick explains itself on screen and to VoiceOver.
            if let why = flow.toggleModel(choice.id) { AccessibilityNotification.Announcement(why).post() }
        }
    }
}

private struct ReviewStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        let models = (SetupCatalog.tiers + SetupCatalog.other).filter { flow.chosen.contains($0.id) }
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "checklist", title: "Ready to set up",
                       subtitle: "Pressing Install downloads exactly this. Keep the app open; you can use the window meanwhile.")
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if !flow.engineInstalled {
                            line("gearshape.2", "Voice engine tools", sub: "Python environment, ffmpeg, espeak-ng", size: SetupCatalog.sizeText(SetupCatalog.engineGB))
                        }
                        ForEach(models) { choice in modelLine(choice, installed: flow.isInstalled(choice.id)) }
                        if models.count > 1 || models.contains(where: { !flow.isInstalled($0.id) }) {
                            HStack {
                                Text("Voice models subtotal").foregroundStyle(.secondary)
                                Spacer()
                                Text(SetupCatalog.sizeText(flow.modelsGB)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                            .accessibilityElement(children: .combine)
                        }
                        if flow.chosen.contains("whisper") {
                            modelLine(SetupCatalog.quality, installed: flow.isInstalled("whisper"))
                        }
                        if !flow.languagePlan.add.isEmpty {
                            line("person.wave.2", "Reference voices, \(flow.languagePlan.add.count == 1 ? "1 language" : "\(flow.languagePlan.add.count) languages")",
                                 sub: SetupCatalog.languageList(flow.languagePlan.add), size: "about \(SetupCatalog.sizeText(flow.voicesMB / 1000))")
                        }
                        ForEach(flow.languagePlan.remove, id: \.self) { code in
                            line("minus.circle", "Turn off \(Formatters.languageName(code)) and delete its voices")
                        }
                    }
                    Divider()
                    totals(flow)
                    CoverageNotice(showAction: false)
                    switch flow.firstNotice {
                    case .commandLineTools: DeveloperToolsNotice(issue: .commandLineToolsMissing) { flow.recheckPrerequisites() }
                    case .license: DeveloperToolsNotice(issue: .licenseNotAccepted) { flow.recheckPrerequisites() }
                    case .homebrew: HomebrewNotice()
                    case nil: EmptyView()
                    }
                    if let blocker = flow.blocker {
                        InlineBanner(systemImage: "externaldrive.badge.exclamationmark", tint: Theme.danger) { Text(blocker) }
                    }
                    if !flow.modelsNeedingAcknowledgement.isEmpty { LicenseAcknowledgement() }
                }
                .padding(1)
            }
            .frame(maxHeight: 420)
            Footer(primaryTitle: "Install", primaryEnabled: flow.canInstall, primary: { flow.start() }) {
                Button("Back") { flow.step = .models }.accessibilityLabel("Go back")
            }
        }
    }

    private func totals(_ flow: SetupFlow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(flow.neededGB > 0 ? "Total download" : "Nothing to download").font(.headline)
                Spacer()
                if flow.neededGB > 0 { Text(SetupCatalog.sizeText(flow.neededGB)).font(.headline).monospacedDigit() }
            }
            .accessibilityElement(children: .combine)
            if flow.neededGB > 0 {
                Text("One time. Works offline afterwards.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Free space on this Mac").foregroundStyle(.secondary)
                Spacer()
                Text("\(flow.prerequisites.freeGB) GB").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
    }

    private func modelLine(_ choice: SetupModelChoice, installed: Bool) -> some View {
        let name = choice.title == choice.modelName ? choice.modelName : "\(choice.title), \(choice.modelName)"
        let licence = choice.noncommercial ? "\(SetupCatalog.personalUseOnly): \(choice.licenseName)" : "\(choice.licenseSummary): \(choice.licenseName)"
        let why = model.setup.lockLabel(choice.id).map { ", \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? ""
        return line(installed ? "checkmark.circle" : "arrow.down.circle", name, sub: licence + why,
                    size: installed ? "Installed, \(SetupCatalog.sizeText(choice.gb)) on disk" : SetupCatalog.sizeText(choice.gb))
    }

    private func line(_ image: String, _ text: String, sub: String? = nil, size: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: image).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if let size { Text(size).foregroundStyle(.secondary).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one acknowledgement the review step asks for when a non-commercial model will be downloaded.
private struct LicenseAcknowledgement: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        InlineBanner(systemImage: "person.fill", tint: Theme.warning) {
            Text("Personal use only").font(.headline)
            ForEach(flow.modelsNeedingAcknowledgement) { choice in
                let locked = flow.lockedLanguages(choice.id)
                Text("\(choice.modelName): \(choice.licenseName), a non-commercial licence.")
                    .fixedSize(horizontal: false, vertical: true)
                if !locked.isEmpty {
                    Text("\(SetupCatalog.languageList(locked)) \(locked.count == 1 ? "is" : "are") narrated by \(choice.modelName), which is for personal use only.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Audiobooks made with these voices are for personal use only. You may make them for yourself; you may not sell them or use them for business. \(SetupCatalog.rightsNote)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(SetupCatalog.acknowledgement, isOn: Binding(get: { flow.licenseAcknowledged }, set: { flow.setLicenseAcknowledged($0) }))
                .toggleStyle(.checkbox)
                .padding(.top, Theme.Space.xs)
                .accessibilityHint("Required before Install is available")
        }
    }
}

/// Homebrew installs the audio tools; its own installer asks for the Mac's password, so the person runs it.
private struct HomebrewNotice: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        InlineBanner(systemImage: "terminal", tint: Theme.warning) {
            Text("One thing first: Homebrew")
                .font(.headline)
            Text("Audiobook Studio uses Homebrew to install its audio tools. Paste this line into the Terminal app (it asks for your Mac password), wait until it finishes, then come back and check again.")
                .fixedSize(horizontal: false, vertical: true)
            Text(SetupPrerequisites.homebrewCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface(radius: Theme.Radius.control)
            HStack {
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SetupPrerequisites.homebrewCommand, forType: .string)
                    copied = true
                }
                .accessibilityLabel("Copy the Homebrew install command")
                Button("Check Again") { model.setup.recheckPrerequisites() }
                    .accessibilityLabel("Check again whether Homebrew is installed")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }
}

/// Apple's developer tools (git) are missing or their licence was never accepted. Neither needs a password inside
/// the app: the person runs one line in Terminal, or Apple's own installer, then presses Check Again.
private struct DeveloperToolsNotice: View {
    let issue: DeveloperTools
    var checkAgain: () -> Void
    @State private var copied = false

    var body: some View {
        switch issue {
        case .licenseNotAccepted: license
        case .commandLineToolsMissing: tools
        case .ready: EmptyView()
        }
    }

    private var license: some View {
        InlineBanner(systemImage: "terminal", tint: Theme.warning) {
            Text("One thing first: accept Apple’s licence")
                .font(.headline)
            Text("Apple’s developer tools need you to accept their licence once. Open the Terminal app, paste this line, press Return, type your Mac password when asked (nothing shows while you type), wait for it to finish, then come back and press Check Again.")
                .fixedSize(horizontal: false, vertical: true)
            Text(DeveloperTools.acceptLicenseCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurface(radius: Theme.Radius.control)
                .accessibilityLabel("Command to accept the licence: \(DeveloperTools.acceptLicenseCommand)")
            Text("Audiobook Studio uses Apple’s tools (git) and Homebrew to install its audio engine; macOS blocks them until the licence is accepted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DeveloperTools.acceptLicenseCommand, forType: .string)
                    copied = true
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy the command that accepts Apple’s licence")
                Button("Open Terminal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open the Terminal app")
                checkAgainButton
            }
            .buttonBorderShape(.capsule)
        }
    }

    private var tools: some View {
        InlineBanner(systemImage: "wrench.and.screwdriver", tint: Theme.warning) {
            Text("One thing first: Apple’s developer tools")
                .font(.headline)
            Text("Your Mac needs Apple’s command line developer tools (about 1 GB, from Apple). Press Install Tools; macOS shows its own installer. When it finishes, come back and press Check Again.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Install Tools") {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                    proc.arguments = ["--install"]
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try? proc.run()
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Install Apple’s command line developer tools")
                checkAgainButton
            }
            .buttonBorderShape(.capsule)
        }
    }

    private var checkAgainButton: some View {
        Button("Check Again", action: checkAgain)
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Check again whether Apple’s developer tools are ready")
    }
}

private struct WorkingStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: flow.error == nil ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill",
                       title: flow.error == nil ? "Setting things up…" : "The setup stopped",
                       subtitle: flow.error == nil ? "This is the only time the app needs the internet. Feel free to look around meanwhile."
                                                  : "Nothing is lost: what already finished is kept.")
            if flow.error == nil {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ProgressView(value: flow.fraction)
                        .accessibilityLabel("Setup progress")
                        .accessibilityValue(Formatters.percent(flow.fraction * 100))
                    Text(flow.statusText).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(flow.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Space.s) {
                            icon(item.state).frame(width: 22)
                            Text(item.title).foregroundStyle(item.state == .pending ? .secondary : .primary)
                            if let size = item.sizeLabel { Spacer(); Text(size).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        if let note = item.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let error = flow.error {
                if let issue = flow.failureIssue {
                    DeveloperToolsNotice(issue: issue) { flow.tryAgain() }
                    DisclosureGroup("Details") {
                        Text([error.message, error.stderrTail].filter { !$0.isEmpty }.joined(separator: "\n\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Theme.Space.xs)
                    }
                    .accessibilityLabel("Technical details of the error")
                } else {
                    OpsErrorBox(error: error)
                }
            }
            HStack {
                if flow.error != nil {
                    Button("Skip for Now") { flow.dismiss() }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Skip the setup for now")
                    Spacer()
                    Button("Try Again") { flow.tryAgain() }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                        .accessibilityLabel("Try the setup again")
                } else {
                    Button("Cancel Setup") { flow.cancel(); flow.step = .review }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Cancel the setup")
                    Spacer()
                    Button("Continue in Background") { flow.dismiss() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                        .accessibilityLabel("Close this window and keep setting up in the background")
                }
            }
        }
    }

    @ViewBuilder
    private func icon(_ state: SetupItem.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary).accessibilityHidden(true)
        case .active: ProgressView().controlSize(.small).accessibilityHidden(true)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).accessibilityHidden(true)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).accessibilityHidden(true)
        }
    }
}

private struct DoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "checkmark.seal.fill", title: "You’re all set",
                       subtitle: (model.setup.downloadedSummary.isEmpty ? "" : "Downloaded: \(model.setup.downloadedSummary). ")
                       + "Drop an EPUB or PDF on the window to make your first audiobook. Add more voices or languages any time from the sidebar.")
            if !model.setup.languageIssues.isEmpty {
                InlineBanner(systemImage: "exclamationmark.triangle.fill", tint: Theme.warning) {
                    Text("Some language voices need another try").font(.headline)
                    ForEach(model.setup.languageIssues) { item in
                        Text("\(item.title): \(item.note ?? "did not finish").").fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Your languages work, and your own voice clips too. The missing library voices can be downloaded again.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { model.setup.start() }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .accessibilityLabel("Try downloading the missing voices again")
                }
            }
            Footer(primaryTitle: "Make an Audiobook", showSkip: false) { model.setup.finish() }
        }
    }
}

// MARK: - Banner when the setup is closed

/// Shown above every screen while the setup is unfinished and its window is closed: progress while it works in
/// the background, a failure with Try Again, or a calm invitation to finish.
struct SetupBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        HStack(spacing: Theme.Space.m) {
            if flow.isWorking {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up Audiobook Studio… \(Formatters.percent(flow.fraction * 100))").font(.callout.weight(.semibold))
                    Text(flow.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Show") { flow.present(from: .working) }
                    .accessibilityLabel("Show the setup progress")
            } else if let error = flow.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).accessibilityHidden(true)
                Text(flow.failureIssue == nil ? error.message : "Apple’s developer tools need attention before the setup can continue.")
                    .lineLimit(2).font(.callout)
                Spacer()
                Button("Try Again") { flow.present(from: .working); flow.tryAgain() }
                    .accessibilityLabel("Try the setup again")
            } else {
                Image(systemName: "sparkles").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.engineMissing ? "Finish setting up to start making audiobooks" : "Download a voice to start making audiobooks")
                        .font(.callout.weight(.semibold))
                    Text("You see every download size first. Works offline afterwards.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set Up…") { flow.present(from: model.engineMissing ? .welcome : .models) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Open the setup")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
