import Foundation

// Which languages are on (Settings > Languages) and what the rest of the app derives from it: pickers list only
// enabled languages (plus the open book's own), a book in a language that is off or not ready is blocked, and
// Settings rows describe what each language costs. The engine owns the list (`languages list`); the add / remove
// actions are in AppModel.swift next to the other downloads.

/// What Settings shows for one language.
struct LanguageRowState: Hashable, Sendable, Identifiable {
    var info: LanguageInfo
    var id: String { info.code }

    var code: String { info.code }
    var isOn: Bool { info.enabled }

    /// "2 voices, 6.4 MB on disk" (On) or "Voices: ~3.1 MB download" (Off): the one-line cost.
    var detail: String {
        let v = info.voices
        if info.enabled {
            if v.installed == 0 { return "No extra voices on disk" }
            let count = v.installed == 1 ? "1 voice" : "\(Formatters.count(v.installed)) voices"
            return "\(count), \(Formatters.bytes(v.bytes)) on disk"
        }
        if v.downloadMb <= 0 && v.available == 0 { return "No voices to download" }
        return "Voices: ~\(Formatters.megabytes(v.downloadMb)) download"
    }

    /// "Needs Voxtral TTS 4B (2.5 GB, non-commercial)"; nil when an installed engine can speak the language.
    var need: String? { info.needText }

    /// The confirmation text before turning the language off.
    var removalMessage: String {
        let name = info.name
        let v = info.voices.installed
        let shared = "The voice models are shared with other languages and stay."
        switch v {
        case 0: return "No voices were downloaded for \(name). \(shared)"
        case 1: return "Deletes the 1 voice downloaded for \(name). \(shared)"
        default: return "Deletes the \(Formatters.count(v)) voices downloaded for \(name). \(shared)"
        }
    }
}

extension AppModel {
    /// True once `languages list` has been read (an older engine without the command never sets it).
    var languagesKnown: Bool { !languageList.isEmpty }

    /// Codes of the languages that are on, in registry order. English and French until the list is loaded.
    var enabledLanguageCodes: [String] {
        languagesKnown ? languageList.filter(\.enabled).map(\.code) : LanguageRegistry.defaultEnabled
    }

    func isEnabled(_ code: String) -> Bool { enabledLanguageCodes.contains(code.lowercased()) }

    func languageInfo(_ code: String) -> LanguageInfo? { languageList.first { $0.code == code.lowercased() } }

    /// The language used when no book says otherwise: the first one that is on.
    var fallbackLanguage: String { enabledLanguageCodes.first ?? "en" }

    /// One row per registry language, for Settings.
    var languageRows: [LanguageRowState] { languageList.map(LanguageRowState.init) }

    /// Codes a picker may offer for the open book: the enabled languages plus the book's own (detected and chosen).
    func languageCodes(includingBook draft: BookDraft?) -> [String] {
        var codes = enabledLanguageCodes
        if let draft { codes += [draft.info.language, draft.language] }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// The open book's language is a registry language that is off: the banner offers to add it.
    var bookLanguageToAdd: LanguageInfo? {
        guard let draft, let info = languageInfo(draft.language), !info.enabled else { return nil }
        return info
    }

    /// What stops a book in `language` before any voice is looked at (nil for a language that is on and ready,
    /// and for codes outside the registry, which keep their old behaviour).
    func bookLanguageBlocker(for language: String) -> BookBlocker? {
        guard let info = languageInfo(language) else { return nil }
        if !info.enabled { return .languageOff(language: info.name) }
        if !info.ready {
            return .languageNotReady(language: info.name,
                                     engine: info.engineToInstall?.needText ?? "a voice engine that speaks it")
        }
        return nil
    }

    /// "Add Spanish" size line: "Voices: ~3.1 MB download. Nothing else is downloaded."
    func languageAddHint(_ info: LanguageInfo) -> String {
        LanguageRowState(info: info).detail + ". Nothing else is downloaded."
    }
}

extension LanguageChangeResult {
    /// The line shown after a language was added or removed: "Spanish is on. 3 voices are on disk."
    func summary(languageName: String) -> String {
        if enabled {
            let voices = voicesInstalled == 0 ? "" : voicesInstalled == 1 ? " 1 voice is on disk." : " \(Formatters.count(voicesInstalled)) voices are on disk."
            return "\(languageName) is on.\(voices)"
        }
        let n = removedVoices.count
        let removed = n == 0 ? "" : n == 1 ? " Deleted 1 voice." : " Deleted \(Formatters.count(n)) voices."
        return "\(languageName) is off.\(removed)"
    }

    /// Things to report that are not errors: voices that could not be downloaded, voices kept because they are in use.
    var notes: [String] {
        var out: [String] = []
        for e in voiceErrors {
            out.append("Could not download \(e.id ?? "a voice")\(e.error.map { ": \($0)" } ?? "").")
        }
        for k in keptVoices {
            out.append("Kept \(k.id ?? "a voice")\(k.reason.map { ": \($0)" } ?? "").")
        }
        return out
    }
}
