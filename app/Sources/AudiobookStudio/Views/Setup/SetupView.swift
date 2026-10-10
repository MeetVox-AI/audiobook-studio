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

/// A selectable row: a checkmark circle, a title with detail, and a trailing size.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let trailing: String
    var tag: String?
    var extra: String?
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(Theme.accentForeground) : AnyShapeStyle(Color.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.s) {
                        Text(title).font(.headline)
                        if let tag { Chip(text: tag, tint: .secondary) }
                    }
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let extra {
                        Text(extra)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Text(trailing)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.08) : Theme.inset, in: .smooth(Theme.Radius.tile))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(isOn ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: isOn ? 1.5 : 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel("\(title), \(trailing)")
        .accessibilityHint(extra.map { "\(detail) \($0)" } ?? detail)
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

private func gbText(_ gb: Double) -> String { gb < 1 ? "\(Int((gb * 1000).rounded())) MB" : String(format: "%.1f GB", gb) }

// MARK: - Steps

private struct WelcomeStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "books.vertical.fill", title: "Welcome to Audiobook Studio",
                       subtitle: "Turn any EPUB or PDF into an audiobook, narrated by AI voices that run entirely on this Mac. Nothing you read leaves it.")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Label("Pick your languages and voices", systemImage: "globe")
                Label("The voices download once, then work offline", systemImage: "arrow.down.circle")
                Label("About 5 minutes on a fast connection", systemImage: "clock")
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
            Footer(primaryTitle: "Continue", primary: { flow.step = .models }) {
                Button("Back") { flow.step = .welcome }.accessibilityLabel("Go back")
            }
        }
    }
}

private struct ModelsStep: View {
    @Environment(AppModel.self) private var model
    @State private var showMore = false

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "waveform", title: "Choose your voices",
                       subtitle: "Nothing is downloaded until you choose it. Larger voices sound better and take longer to download and to narrate.")
            VStack(spacing: Theme.Space.s) {
                ForEach(SetupCatalog.narration) { choice in
                    row(choice, tag: choice.id == "qwen3" ? "Recommended" : nil)
                }
                row(SetupCatalog.quality, tag: "Optional")
                DisclosureGroup("More voices (personal use only)", isExpanded: $showMore) {
                    VStack(spacing: Theme.Space.s) {
                        ForEach(SetupCatalog.more) { row($0, tag: "Non-commercial") }
                    }
                    .padding(.top, Theme.Space.s)
                }
                .accessibilityLabel("More voices, for personal use only")
            }
            CoverageNotice()
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(flow.chosen.isEmpty ? "Choose at least one voice to continue." : "Download size: \(gbText(flow.neededGB))")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Footer(primaryTitle: "Continue", primaryEnabled: !flow.chosen.isEmpty, primary: {
                flow.recheckPrerequisites(); flow.step = .review
            }) {
                Button("Back") { flow.step = .languages }.accessibilityLabel("Go back")
            }
        }
    }

    private func row(_ choice: SetupModelChoice, tag: String?) -> some View {
        let installed = model.models.first { $0.engine == choice.id }?.installed ?? false
        var extra: String?
        if let c = model.setup.coverage(of: choice.id), !model.setup.languages.isEmpty {
            extra = c.missing.isEmpty ? "Narrates \(c.speaks.count == 1 ? "your language" : "all your languages")."
                : c.speaks.isEmpty ? "Does not narrate \(SetupCatalog.languageList(c.missing))."
                : "Narrates \(SetupCatalog.languageList(c.speaks)); not \(SetupCatalog.languageList(c.missing))."
        }
        return ChoiceRow(title: choice.title, detail: choice.detail,
                         trailing: installed ? "Installed" : gbText(choice.gb), tag: tag, extra: extra,
                         isOn: model.setup.chosen.contains(choice.id)) { model.setup.toggleModel(choice.id) }
    }
}

private struct ReviewStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let flow = model.setup
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            StepHeader(systemImage: "checklist", title: "Ready to set up",
                       subtitle: "Audiobook Studio will install its voice engine and download your choices. Keep the app open; you can use the window meanwhile.")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !flow.engineInstalled { line("gearshape.2", "The voice engine and audio tools") }
                ForEach(SetupCatalog.all.filter { flow.chosen.contains($0.id) }) { choice in
                    let done = model.models.first { $0.engine == choice.id }?.installed ?? false
                    line(done ? "checkmark.circle" : "arrow.down.circle", "\(choice.listTitle ?? choice.title)\(done ? " (already installed)" : "")",
                         detail: done ? nil : gbText(choice.gb))
                }
                ForEach(flow.languagePlan.add, id: \.self) { code in
                    line("person.wave.2", "\(Formatters.languageName(code)) reference voices", detail: "~\(Int(SetupCatalog.voiceMBPerLanguage)) MB")
                }
                ForEach(flow.languagePlan.remove, id: \.self) { code in
                    line("minus.circle", "Turn off \(Formatters.languageName(code)) and delete its voices")
                }
            }
            CoverageNotice(showAction: false)
            if flow.needsHomebrew { HomebrewNotice() }
            if let blocker = flow.blocker {
                InlineBanner(systemImage: "externaldrive.badge.exclamationmark", tint: Theme.danger) { Text(blocker) }
            }
            Footer(primaryTitle: "Install", primaryEnabled: flow.canInstall, primary: { flow.start() }) {
                Button("Back") { flow.step = .models }.accessibilityLabel("Go back")
            }
        }
    }

    private func line(_ image: String, _ text: String, detail: String? = nil) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: image).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary).monospacedDigit() }
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
                        }
                        if let note = item.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let error = flow.error { OpsErrorBox(error: error) }
            HStack {
                if flow.error != nil {
                    Button("Skip for Now") { flow.dismiss() }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Skip the setup for now")
                    Spacer()
                    Button("Try Again") { flow.start() }
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
                       subtitle: "Drop an EPUB or PDF on the window to make your first audiobook. Add more voices or languages any time from the sidebar.")
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
                Text(error.message).lineLimit(2).font(.callout)
                Spacer()
                Button("Try Again") { flow.present(from: .working); flow.start() }
                    .accessibilityLabel("Try the setup again")
            } else {
                Image(systemName: "sparkles").symbolRenderingMode(.hierarchical).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.engineMissing ? "Finish setting up to start making audiobooks" : "Download a voice to start making audiobooks")
                        .font(.callout.weight(.semibold))
                    Text("It takes a few minutes and works offline afterwards.").font(.caption).foregroundStyle(.secondary)
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
