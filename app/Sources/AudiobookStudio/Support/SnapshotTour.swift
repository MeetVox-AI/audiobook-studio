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

        if let book = ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_BOOK"], !book.isEmpty {
            await model.openBook(URL(fileURLWithPath: book))
            report["book_title"] = model.draft?.info.title ?? NSNull()
            report["book_error"] = model.bookError?.message ?? NSNull()
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
                if capture(to: file) { shots.append(file.lastPathComponent) }
            }
        }
        if ProcessInfo.processInfo.environment["AUDIOBOOK_STUDIO_SNAPSHOT_ACTION"] == "convert" {
            NSApp.appearance = NSAppearance(named: .aqua)
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
        let voice = VoiceSelection(engineId: "kokoro", presetId: draft.language == "fr" ? "ff_siwis" : "af_heart")
        model.voiceSelection = voice
        model.selection = .newBook

        func shot(_ name: String) {
            let file = dir.appendingPathComponent("\(name).png")
            if capture(to: file) { shots.append(file.lastPathComponent) }
        }

        if let run = model.startSample(voice: voice, section: first?.index, seconds: 20) {
            let deadline = Date().addingTimeInterval(240)
            while run.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(1.5))
            shot("action-sample")
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
                    shot("action-progress")
                    midShot = true
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(2))
            shot("action-done")
            report["convert_state"] = "\(monitor.state)"
            report["convert_output"] = monitor.result?.output ?? NSNull()
            report["convert_duration_s"] = monitor.result?.durationS ?? NSNull()
            report["convert_error"] = monitor.errorMessage ?? NSNull()
            report["convert_rate_points"] = monitor.rateHistory.count
        } catch {
            report["convert_error"] = "\(error)"
        }
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
