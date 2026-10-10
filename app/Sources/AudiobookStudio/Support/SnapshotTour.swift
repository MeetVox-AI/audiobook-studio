import AppKit
import Foundation

/// Self-check mode for development and CI: when AUDIOBOOK_STUDIO_SNAPSHOT_DIR is set, the app loads
/// the real engine data, optionally opens AUDIOBOOK_STUDIO_SNAPSHOT_BOOK, visits every screen in
/// light and dark appearance, saves its own window as PNG files plus a JSON report, then quits.
/// It renders its own window (no screen-recording permission needed). Never active otherwise.
@MainActor
enum SnapshotTour {
    static var directory: URL? {
        guard let p = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_DIR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func run(model: AppModel, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var report: [String: Any] = [:]
        var shots: [String] = []

        // The empty "New audiobook" screen, before any book is opened.
        model.selection = .newBook
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .seconds(2))
            let file = dir.appendingPathComponent("empty-\(appearanceName).png")
            if await snap(to: file) { shots.append(file.lastPathComponent) }
        }
        if external { await settingsTour(dir: dir, shots: &shots) }
        if ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_ONLY"] == "settings" {
            report["screens"] = shots
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("report.json"))
            }
            NSApp.terminate(nil)
            return
        }

        if let book = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_BOOK"], !book.isEmpty {
            await model.openBook(URL(fileURLWithPath: book))
            report["book_title"] = model.draft?.info.title ?? NSNull()
            report["book_error"] = model.bookError?.message ?? NSNull()
        }
        if let search = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_VOICE_SEARCH"], !search.isEmpty {
            model.voiceLab.filter = VoiceFilter(language: .all)
            model.voiceLab.filter.search = search
        }
        var stops: [(String, SidebarItem)] = [
            ("book", .newBook), ("voices", .voices), ("models", .models), ("benchmark", .benchmark), ("jobs", .jobs),
        ]
        if let job = model.jobs.first { stops.append(("job", .job(job.jobId))) }

        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (name, item) in stops {
                model.selection = item
                try? await Task.sleep(for: .seconds(2))
                let file = dir.appendingPathComponent("\(name)-\(appearanceName).png")
                if await snap(to: file) { shots.append(file.lastPathComponent) }
                if name == "book", appearanceName == "light", external {
                    report["title_edit"] = await titleEditCheck(dir: dir, shots: &shots)
                }
                if name == "voices", external {
                    await sheetCapture(buttonLabel: "Add my voice", name: "addvoice-\(appearanceName)", dir: dir, shots: &shots)
                }
                if scrollToBottom() {
                    try? await Task.sleep(for: .seconds(1.5))
                    let lower = dir.appendingPathComponent("\(name)-bottom-\(appearanceName).png")
                    if await snap(to: lower) { shots.append(lower.lastPathComponent) }
                    scrollToTop()
                }
            }
        }
        if ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_ACTION"] == "convert" {
            // AUDIOBOOK_STUDIO_SNAPSHOT_ACTION_APPEARANCE=dark runs the sample/convert part in dark mode.
            let dark = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_ACTION_APPEARANCE"] == "dark"
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await convertTour(model: model, dir: dir, report: &report, shots: &shots)
        }
        report["screens"] = shots
        report["engines"] = model.engines.map(\.id)
        report["models_installed"] = model.models.filter(\.installed).map(\.engine)
        report["voices"] = model.voices.count
        report["jobs"] = model.jobs.count
        report["errors"] = Dictionary(uniqueKeysWithValues: model.errors.map { ($0.key.rawValue, $0.value.message) })
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("report.json"))
        }
        NSApp.terminate(nil)
    }

    /// End-to-end through the app: sample, then a detached one-chapter conversion followed to the end.
    private static func convertTour(model: AppModel, dir: URL, report: inout [String: Any], shots: inout [String]) async {
        guard var draft = model.draft else { report["action_error"] = "no book open"; return }
        let first = draft.info.sections.first { $0.include && $0.kind == "chapter" }
        draft.setAll(false)
        if let f = first { draft.setIncluded(f.index, true) }
        model.draft = draft
        // AUDIOBOOK_STUDIO_SNAPSHOT_PRESET picks another Kokoro preset (e.g. one not in the sentence cache, so the
        // conversion really narrates and the progress screen can be captured).
        let preset = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_PRESET"].flatMap { $0.isEmpty ? nil : $0 }
        let voice = VoiceSelection(engineId: "kokoro", presetId: preset ?? (draft.language == "fr" ? "ff_siwis" : "af_heart"))
        model.voiceSelection = voice
        model.selection = .newBook

        func shot(_ name: String) async {
            let file = dir.appendingPathComponent("\(name).png")
            if await snap(to: file) { shots.append(file.lastPathComponent) }
        }

        // Start the sample from the book screen's own button (so the screen shows its player), scrolled into view;
        // fall back to the model when the button cannot be found.
        try? await Task.sleep(for: .seconds(2))
        scroll(toY: 560)
        try? await Task.sleep(for: .seconds(1))
        let before = Set(model.samples.map(\.id))
        var viaButton = false
        if let button = accessibilityElement(labelled: "Make a 2-minute sample"), press(button) {
            try? await Task.sleep(for: .seconds(1))
            viaButton = model.samples.contains { !before.contains($0.id) }
        }
        report["sample_via_button"] = viaButton
        let started = viaButton ? model.samples.first { !before.contains($0.id) }
                                : model.startSample(voice: voice, section: first?.index, seconds: 20)
        if let run = started {
            let deadline = Date().addingTimeInterval(240)
            while run.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1.5))
            await shot("action-sample-panel")
            scrollToTop()
            try? await Task.sleep(for: .seconds(1))
            await shot("action-sample")
            report["sample_status"] = run.statusText
            report["sample_error"] = run.error?.message ?? NSNull()
            report["sample_audio_s"] = run.result?.audioS ?? NSNull()
            report["sample_file_exists"] = run.outputURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        } else {
            report["sample_error"] = "startSample returned nil"
        }

        do {
            let monitor = try await model.startConvert(voice: voice)
            model.selection = .job(monitor.jobId)
            var midShot = false
            let deadline = Date().addingTimeInterval(900)
            while (monitor.state == .queued || monitor.state == .running) && Date() < deadline {
                if !midShot, let pct = monitor.latestProgress?.percent, pct > 25 {
                    try? await Task.sleep(for: .seconds(1))
                    await shot("action-progress")
                    midShot = true
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(2))
            await shot("action-done")
            report["convert_state"] = "\(monitor.state)"
            report["convert_output"] = monitor.result?.output ?? NSNull()
            report["convert_duration_s"] = monitor.result?.durationS ?? NSNull()
            report["convert_error"] = monitor.errorMessage ?? NSNull()
            report["convert_rate_points"] = monitor.rateHistory.count
        } catch {
            report["convert_error"] = "\(error)"
        }
    }

    /// Opens the Settings window, captures it in light and dark appearance, then closes it (external mode only).
    private static func settingsTour(dir: URL, shots: inout [String]) async {
        let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        // The app menu's "Settings…" item, as a user would choose it.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix("Settings") }) else { return }
        appMenu.performActionForItem(at: index)
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && !before.contains($0.windowNumber) }) else { return }
        // Each tab of the Settings window, selected through its toolbar item as a click would.
        // Each section, chosen through the window's segmented control as a click would.
        func segmentedControl(in view: NSView?) -> NSSegmentedControl? {
            guard let view else { return nil }
            if let control = view as? NSSegmentedControl { return control }
            for sub in view.subviews { if let hit = segmentedControl(in: sub) { return hit } }
            return nil
        }
        let control = segmentedControl(in: window.contentView?.superview ?? window.contentView)
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (index, section) in ["General", "Voices", "Storage"].enumerated() {
                if let control, index < control.segmentCount {
                    control.selectedSegment = index
                    control.sendAction(control.action, to: control.target)
                }
                try? await Task.sleep(for: .seconds(1))
                let file = dir.appendingPathComponent("settings-\(section.lowercased())-\(appearanceName).png")
                if await externalCapture(to: file, window: window) { shots.append(file.lastPathComponent) }
            }
        }
        window.close()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    /// Presses the book title through the window's accessibility tree (as VoiceOver would), checks that a
    /// text field takes keyboard focus, captures it, then ends editing and checks the title is shown again.
    private static func titleEditCheck(dir: URL, shots: inout [String]) async -> [String: Any] {
        var result: [String: Any] = [:]
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) else {
            return ["error": "no window"]
        }
        guard let titleNode = accessibilityElement(labelled: "Book title") else { return ["error": "title element not found"] }
        result["found"] = true
        result["role"] = titleNode.value(forKey: "accessibilityRole") as? String ?? ""
        result["pressed"] = press(titleNode)
        try? await Task.sleep(for: .seconds(1))
        let responder = window.firstResponder
        result["focused_text_field"] = responder is NSTextView || responder is NSTextField
        result["responder"] = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let file = dir.appendingPathComponent("book-title-edit-light.png")
        if await snap(to: file) { shots.append(file.lastPathComponent) }
        window.makeFirstResponder(nil)
        try? await Task.sleep(for: .seconds(1))
        result["ended_editing"] = !(window.firstResponder is NSTextView)
        return result
    }

    /// Presses a button that opens a sheet, captures the sheet window, then closes it with its Cancel button.
    private static func sheetCapture(buttonLabel: String, name: String, dir: URL, shots: inout [String]) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }),
              let button = accessibilityElement(labelled: buttonLabel), press(button) else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard let sheet = window.attachedSheet else { return }
        let file = dir.appendingPathComponent("\(name).png")
        if await externalCapture(to: file, window: sheet) { shots.append(file.lastPathComponent) }
        // Close it as a user would (Cancel, then Escape); end the sheet directly only as a last resort.
        if let cancel = accessibilityElement(labelled: "Cancel", in: sheet) { press(cancel) }
        try? await Task.sleep(for: .seconds(1))
        if window.attachedSheet != nil {
            sheet.cancelOperation(nil)
            try? await Task.sleep(for: .seconds(1))
        }
        if window.attachedSheet != nil { window.endSheet(sheet) }
        try? await Task.sleep(for: .seconds(0.5))
    }

    /// The first element of a window's accessibility tree (toolbar included) with this label (what VoiceOver
    /// reads). Defaults to the main window.
    static func accessibilityElement(labelled label: String, in chosen: NSWindow? = nil) -> NSObject? {
        guard let window = chosen ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) })
        else { return nil }
        let root: Any = window
        func find(_ element: Any, depth: Int) -> NSObject? {
            // Only accessibility elements answer these keys; asking any other object raises an exception.
            guard depth < 40, let node = element as? NSObject, node is NSAccessibilityElementProtocol else { return nil }
            if node.responds(to: #selector(NSAccessibilityProtocol.accessibilityLabel)),
               (node.value(forKey: "accessibilityLabel") as? String) == label { return node }
            guard node.responds(to: #selector(NSAccessibilityProtocol.accessibilityChildren)) else { return nil }
            let children = node.value(forKey: "accessibilityChildren") as? [Any] ?? []
            for child in children { if let hit = find(child, depth: depth + 1) { return hit } }
            return nil
        }
        return find(root, depth: 0)
    }

    /// Presses an accessibility element (a button), as VoiceOver's "press" does.
    @discardableResult
    static func press(_ element: NSObject) -> Bool {
        if let button = element as? NSAccessibilityButton { return button.accessibilityPerformPress() }
        return element.perform(NSSelectorFromString("accessibilityPerformPress")) != nil
    }

    static func snap(to url: URL) async -> Bool {
        external ? await externalCapture(to: url) : capture(to: url)
    }

    static func scrollToTop() {
        guard let sv = largestScrollView(), let doc = sv.documentView else { return }
        let y = doc.isFlipped ? 0 : max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    /// Scrolls the main window's largest scroll view so that `y` points from the top are at the top.
    static func scroll(toY offset: CGFloat) {
        guard let sv = largestScrollView(), let doc = sv.documentView else { return }
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        let y = doc.isFlipped ? min(offset, maxY) : max(0, maxY - offset)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }

    static func largestScrollView() -> NSScrollView? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }),
              let root = window.contentView else { return nil }
        var scrollViews: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView { scrollViews.append(sv) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return scrollViews.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    /// Scrolls the main window's largest scroll view to its end (lazy rows below the fold get built).
    static func scrollToBottom() -> Bool {
        guard let sv = largestScrollView(), let doc = sv.documentView,
              doc.frame.height > sv.contentView.bounds.height + 40 else { return false }
        let y = doc.isFlipped ? max(0, doc.frame.height - sv.contentView.bounds.height) : 0
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
        return true
    }

    /// External capture mode (AUDIOBOOK_STUDIO_SNAPSHOT_EXTERNAL=1): instead of rendering itself (which cannot
    /// draw Liquid Glass or other materials), the app writes "<name>.request" holding its window number and
    /// waits up to 15 s for "<name>.png" to appear, so a tool such as `screencapture -l` can capture the real window.
    static var external: Bool { ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_EXTERNAL"] == "1" }

    static func externalCapture(to url: URL, window chosen: NSWindow? = nil) async -> Bool {
        guard let window = chosen ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) else { return false }
        // Capture the active look (inactive windows draw accents and prominent buttons in grey).
        // Cooperative `activate()` is refused while another app is frontmost, so this self-test uses the
        // older forcing call (looked up at run time: it is deprecated and this is development-only code).
        let selector = NSSelectorFromString("activateIgnoringOtherApps:")
        if NSApp.responds(to: selector) {
            typealias Activate = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(NSApp.method(for: selector), to: Activate.self)(NSApp, selector, true)
        } else {
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let request = url.deletingPathExtension().appendingPathExtension("request")
        try? "\(window.windowNumber)".write(to: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Renders the main window (including its title bar and toolbar) into a PNG.
    static func capture(to url: URL) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }),
              let content = window.contentView else { return false }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
