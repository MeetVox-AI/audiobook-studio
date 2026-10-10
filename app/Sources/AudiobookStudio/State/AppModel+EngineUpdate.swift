import Foundation

// Keeping the engine in step with the app. After an app update the engine (installed separately, by
// scripts/install-engine.sh) can be older than the app needs. The app spots it from the engine's API level
// (`engines` → "api") and runs the same installer itself: it updates the engine code and its Python libraries in
// place, without voice models (NO_MODELS=1). Nobody has to open Terminal, and nothing pops up: with automatic
// updates on (the app's own setting, Sparkle) it happens silently at launch, or once no conversion is running;
// otherwise the banner at the top offers it.

extension AppModel {
    /// The engine API level this app needs (`audiobook_engine.API_VERSION`). Raise it together with the engine's
    /// whenever the app starts using a new engine command or option.
    static let requiredEngineAPI = 2

    /// The running engine's API level; engines from before levels existed report none and count as 1.
    var engineAPI: Int { engineList?.api ?? 1 }

    /// The engine works but is older than this app needs (false while the engine list is not loaded).
    var engineNeedsUpdate: Bool { engineList != nil && engineAPI < Self.requiredEngineAPI }

    /// The engine in use is the one the app installed, so the app may update it. A development checkout or an
    /// engine chosen in Settings is the user's own: the app says it is old but leaves it alone.
    var engineIsManaged: Bool { settings.enginePath == managedEnginePath }

    /// What stops an update now (nil when it can run).
    var engineUpdateBlocker: String? {
        if !engineIsManaged {
            return "This engine was not installed by Audiobook Studio (\(settings.enginePath)). Update that copy, or choose the default location in Settings."
        }
        if activeJobCount > 0 {
            return "A conversion is running. The engine can be updated when it finishes."
        }
        return nil
    }

    var isUpdatingEngine: Bool { engineUpdater.isRunning }

    /// Whether the person keeps automatic updates on (Sparkle's setting, Settings → About; on by default in
    /// release builds). Development builds have no update feed, so this is off there.
    nonisolated static func automaticUpdatesEnabled(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        if let chosen = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool { return chosen }
        return bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && (bundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool ?? false)
    }

    /// With automatic updates on, updates an engine that is ours and older than needed, silently (the banner
    /// shows progress). Runs at launch and after each conversion, so one postponed by a running job starts then.
    func autoUpdateEngineIfNeeded() {
        guard engineNeedsUpdate, engineUpdateBlocker == nil, !engineUpdater.isRunning, engineUpdateError == nil,
              automaticUpdates() else { return }
        Task { await updateEngine() }
    }

    /// Updates the engine with the installer (engine code and Python libraries only), then reloads everything.
    /// Failures are kept in `engineUpdateError`. `script` replaces the installer in tests.
    func updateEngine(script: URL? = nil) async {
        guard !engineUpdater.isRunning else { return }
        if let blocker = engineUpdateBlocker {
            engineUpdateError = EngineError(message: blocker)
            return
        }
        engineUpdateError = nil
        stopScreenEngineWork()       // samples, benchmarks, downloads: they run the engine being replaced
        voiceLab.cancelRunning()
        do {
            try await engineUpdater.install(script: script ?? engineInstallerScript)
        } catch is CancellationError {
            return
        } catch {
            engineUpdateError = EngineError(error)
            return
        }
        await refreshAll()
        if engineNeedsUpdate {
            engineUpdateError = EngineError(message: "The engine was updated but is still older than this version of Audiobook Studio needs. Try again later; if it keeps happening, reinstall it from the setup.")
        }
    }
}
