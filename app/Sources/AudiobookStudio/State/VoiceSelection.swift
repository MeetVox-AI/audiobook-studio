import Foundation

/// The narrator choice for a sample, a conversion or a benchmark.
///
/// Exactly one voice source is passed to the engine:
/// - `presetId`   → `--voice <id>`      (a preset from `engines`, engines with `supportsPresets`)
/// - `refVoiceId` → `--ref-voice <id>`  (an installed voice from `voices list`, engines with `supportsCloning`)
/// - neither      → the engine's first preset (the engine rejects this for clone-only engines like Fish).
/// The engine validates combinations and returns a user-facing error message; show it as is.
struct VoiceSelection: Codable, Hashable, Sendable {
    var engineId: String
    var presetId: String?
    var refVoiceId: String?
    /// Narration speed, 0.75...1.5 in the UI (the engine accepts 0.5...2.0).
    var speed: Double
    /// "Check every sentence with speech recognition" (Whisper; about +15% time).
    var verify: Bool

    init(engineId: String, presetId: String? = nil, refVoiceId: String? = nil, speed: Double = 1.0, verify: Bool? = nil) {
        self.engineId = engineId
        self.presetId = presetId
        self.refVoiceId = presetId == nil ? refVoiceId : nil
        self.speed = speed
        self.verify = verify ?? VoiceSelection.defaultVerify(engineId: engineId)
    }

    /// Speed slider range shown in the UI.
    static let speedRange: ClosedRange<Double> = 0.75...1.5

    /// Engines that do not sample (deterministic output): the speech check is off by default for them.
    /// Per SPEC: on for sampling engines (qwen3, voxtral, fish), off for kokoro.
    static let nonSamplingEngines: Set<String> = ["kokoro"]

    static func defaultVerify(engineId: String) -> Bool { !nonSamplingEngines.contains(engineId) }

    /// The voice id used in `engines.measured` keys ("<engine>|<voice>").
    var voiceId: String? { presetId ?? refVoiceId }
    var isClone: Bool { refVoiceId != nil }

    mutating func choosePreset(_ id: String) {
        presetId = id
        refVoiceId = nil
    }

    mutating func chooseReferenceVoice(_ id: String) {
        refVoiceId = id
        presetId = nil
    }

    /// Switches engine, clears the voice and resets the speech check to that engine's default.
    mutating func switchEngine(to id: String) {
        guard id != engineId else { return }
        engineId = id
        presetId = nil
        refVoiceId = nil
        verify = VoiceSelection.defaultVerify(engineId: id)
    }

    // MARK: Engine arguments

    /// `--engine E` plus the voice flag. Used by convert, sample and benchmark.
    var voiceArguments: [String] {
        var a = ["--engine", engineId]
        if let presetId { a += ["--voice", presetId] } else if let refVoiceId { a += ["--ref-voice", refVoiceId] }
        return a
    }

    /// `voiceArguments` plus speed and speech check. Used by convert and sample (benchmark has neither option).
    var synthesisArguments: [String] {
        var a = voiceArguments
        if abs(speed - 1.0) > 0.001 { a += ["--speed", Formatters.trimmed(speed, digits: 2)] }
        a.append(verify ? "--verify" : "--no-verify")
        return a
    }

    // MARK: Lookups

    /// The selected voice's language, from the engine preset or the installed voice.
    func language(engines: [EngineInfo], voices: [VoiceEntry]) -> String? {
        if let presetId {
            return engines.first { $0.id == engineId }?.voices.first { $0.id == presetId }?.lang
        }
        if let refVoiceId { return voices.first { $0.id == refVoiceId }?.lang }
        return nil
    }

    /// True when the engine speaks `language` and the chosen voice (if known) is in that language.
    func fits(language: String, engines: [EngineInfo], voices: [VoiceEntry]) -> Bool {
        guard let engine = engines.first(where: { $0.id == engineId }), engine.languages.contains(language) else { return false }
        guard let voiceLang = self.language(engines: engines, voices: voices) else { return voiceId == nil }
        return voiceLang == language
    }

    /// "Ryan · Qwen3-TTS 1.7B", "SIWIS — studio narrator (F) · Qwen3-TTS 1.7B (cloned)".
    func displayName(engines: [EngineInfo], voices: [VoiceEntry]) -> String {
        let engine = engines.first { $0.id == engineId }
        let engineName = engine?.name ?? engineId
        if let presetId {
            let name = engine?.voices.first { $0.id == presetId }?.name ?? presetId
            return "\(name) · \(engineName)"
        }
        if let refVoiceId {
            let name = voices.first { $0.id == refVoiceId }?.name ?? refVoiceId
            return "\(name) · \(engineName) (cloned)"
        }
        return "\(engineName) default voice"
    }

    /// A reasonable first choice for a language when the user has no saved default:
    /// installed engines first (when the model list is known), commercial-use engines before non-commercial
    /// ones, engine order as listed by the engine; within an engine a preset in that language, else (cloning
    /// engines) the first installed reference voice in that language.
    static func suggested(for language: String, engines: [EngineInfo], voices: [VoiceEntry],
                          models: [ModelStatus] = []) -> VoiceSelection? {
        let installedEngines = Set(models.filter(\.installed).map(\.engine))
        let candidates = engines.enumerated().filter { $0.element.languages.contains(language) }.sorted { a, b in
            let ai = models.isEmpty || installedEngines.contains(a.element.id)
            let bi = models.isEmpty || installedEngines.contains(b.element.id)
            if ai != bi { return ai }
            if a.element.noncommercial != b.element.noncommercial { return !a.element.noncommercial }
            return a.offset < b.offset
        }.map(\.element)
        for engine in candidates {
            if engine.supportsPresets, let preset = engine.voices.first(where: { $0.lang == language }) {
                return VoiceSelection(engineId: engine.id, presetId: preset.id)
            }
            if engine.supportsCloning, let ref = voices.first(where: { $0.lang == language && $0.isInstalled }) {
                return VoiceSelection(engineId: engine.id, refVoiceId: ref.id)
            }
        }
        return nil
    }
}
