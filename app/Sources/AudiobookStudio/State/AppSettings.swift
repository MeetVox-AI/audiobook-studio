import Foundation

/// Pause length preference. v1 stores it only: the engine does not take pacing options yet.
enum PauseLength: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case short, normal, long
    var id: String { rawValue }
    var title: String {
        switch self {
        case .short: return "Short"
        case .normal: return "Normal"
        case .long: return "Long"
        }
    }
}

/// Sentence / paragraph / chapter pauses (stored only in v1).
struct Pacing: Codable, Hashable, Sendable {
    var sentence: PauseLength = .normal
    var paragraph: PauseLength = .normal
    var chapter: PauseLength = .normal
}

/// User settings, persisted in UserDefaults on every change. Bind to them directly from SwiftUI,
/// e.g. `Toggle("Notifications", isOn: $settings.notificationsEnabled)` with `@Bindable var settings = model.settings`.
@MainActor
@Observable
final class AppSettings {
    /// AAC bitrates offered in Settings (kbps, mono).
    static let bitrateChoices = [64, 96, 128]

    /// Engine executable chosen by the user; nil uses `EngineClient.defaultPath`
    /// (Info.plist `AudiobookEnginePath`, or the development checkout under `swift run`).
    var enginePathOverride: String? { didSet { save(enginePathOverride, Key.enginePath) } }

    /// Folder for finished audiobooks; nil means "next to the book" (the engine default).
    var outputFolder: String? { didSet { save(outputFolder, Key.outputFolder) } }

    /// AAC bitrate in kbps (one of `bitrateChoices`).
    var bitrateKbps: Int { didSet { save(bitrateKbps, Key.bitrate) } }

    /// Default narrator per language code ("en", "fr").
    var defaultVoices: [String: VoiceSelection] { didSet { saveCodable(defaultVoices, Key.defaultVoices) } }

    /// Notify when a conversion finishes or fails (bundled app only).
    var notificationsEnabled: Bool { didSet { save(notificationsEnabled, Key.notifications) } }

    /// Advanced: keep chapter audio files in the job folder after success (`--keep-work`).
    var keepWork: Bool { didSet { save(keepWork, Key.keepWork) } }

    /// Version of the terms of use the user accepted (0 = none). Raise `currentTermsVersion` to ask again.
    var acceptedTermsVersion: Int { didSet { save(acceptedTermsVersion, Key.terms) } }
    static let currentTermsVersion = 2   // 2: privacy policy added
    var hasAcceptedTerms: Bool { acceptedTermsVersion >= AppSettings.currentTermsVersion }
    func acceptTerms() { acceptedTermsVersion = AppSettings.currentTermsVersion }

    /// How far the first-run setup got. `.skipped` hides the setup window; a banner offers to finish it.
    enum SetupState: String, Sendable { case notStarted, skipped, completed }
    var setupState: SetupState { didSet { save(setupState.rawValue, Key.setup) } }

    /// Stored only in v1.
    var pacing: Pacing { didSet { saveCodable(pacing, Key.pacing) } }

    /// Non-commercial engines whose licence the user acknowledged (licence sheet shown once per engine).
    var acknowledgedLicenses: Set<String> { didSet { saveCodable(acknowledgedLicenses, Key.licenses) } }

    /// The engine executable path in use. Setting it to empty or to the default clears the override.
    var enginePath: String {
        get { enginePathOverride ?? EngineClient.defaultPath }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            enginePathOverride = (trimmed.isEmpty || trimmed == EngineClient.defaultPath) ? nil : trimmed
        }
    }

    /// Output folder as a URL (nil = next to the book).
    var outputFolderURL: URL? {
        get { outputFolder.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
        set { outputFolder = newValue?.path }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let enginePath = "AudiobookStudio.enginePath"
        static let outputFolder = "AudiobookStudio.outputFolder"
        static let bitrate = "AudiobookStudio.bitrateKbps"
        static let defaultVoices = "AudiobookStudio.defaultVoices"
        static let notifications = "AudiobookStudio.notificationsEnabled"
        static let keepWork = "AudiobookStudio.keepWork"
        static let pacing = "AudiobookStudio.pacing"
        static let licenses = "AudiobookStudio.acknowledgedLicenses"
        static let terms = "AudiobookStudio.acceptedTermsVersion"
        static let setup = "AudiobookStudio.setupState"
    }

    /// `defaults` is injectable for tests (`UserDefaults(suiteName:)`).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enginePathOverride = defaults.string(forKey: Key.enginePath)
        outputFolder = defaults.string(forKey: Key.outputFolder)
        let bitrate = defaults.integer(forKey: Key.bitrate)
        bitrateKbps = AppSettings.bitrateChoices.contains(bitrate) ? bitrate : 64
        defaultVoices = AppSettings.loadCodable([String: VoiceSelection].self, Key.defaultVoices, defaults) ?? [:]
        notificationsEnabled = defaults.object(forKey: Key.notifications) as? Bool ?? true
        keepWork = defaults.bool(forKey: Key.keepWork)
        pacing = AppSettings.loadCodable(Pacing.self, Key.pacing, defaults) ?? Pacing()
        acknowledgedLicenses = AppSettings.loadCodable(Set<String>.self, Key.licenses, defaults) ?? []
        acceptedTermsVersion = defaults.integer(forKey: Key.terms)
        setupState = defaults.string(forKey: Key.setup).flatMap(SetupState.init(rawValue:)) ?? .notStarted
    }

    func resetEnginePath() { enginePathOverride = nil }

    func hasAcknowledgedLicense(engine: String) -> Bool { acknowledgedLicenses.contains(engine) }
    func acknowledgeLicense(engine: String) { acknowledgedLicenses.insert(engine) }

    // MARK: Persistence

    private func save(_ value: String?, _ key: String) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func save(_ value: Int, _ key: String) { defaults.set(value, forKey: key) }
    private func save(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
