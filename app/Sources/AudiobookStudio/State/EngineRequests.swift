import Foundation

// Engine command lines, built in one place so they can be unit tested without running the engine.

/// `convert <book> ... --detach`: starts a background job and prints one `detached` line.
/// Running the same request again resumes the job (same options → same job id; finished chunks are reused).
struct ConvertRequest: Hashable, Sendable {
    var bookPath: String
    var voice: VoiceSelection
    var language: String
    var sections: [Int]
    /// nil or empty: the engine writes next to the book.
    var outputFolder: String?
    var bitrateKbps: Int
    var keepWork: Bool

    var arguments: [String] {
        var a = ["convert", bookPath] + voice.synthesisArguments
        a += ["--lang", language, "--sections", BookDraft.sectionsSpec(sections), "--bitrate", String(bitrateKbps)]
        if keepWork { a.append("--keep-work") }
        if let outputFolder, !outputFolder.isEmpty { a += ["--out-dir", outputFolder] }
        a.append("--detach")
        return a
    }
}

/// `sample <book> ... --seconds S --out <file.m4a>`: streams model events, then `sample_done`.
struct SampleRequest: Hashable, Sendable {
    var bookPath: String
    var voice: VoiceSelection
    var language: String
    /// Section index; nil lets the engine pick the first chapter.
    var section: Int?
    /// Approximate sample length in seconds (about 20 for a voice preview, 120 for "Make a 2-minute sample").
    var seconds: Double
    var outputPath: String

    var arguments: [String] {
        var a = ["sample", bookPath] + voice.synthesisArguments + ["--lang", language]
        if let section { a += ["--section", String(section)] }
        a += ["--seconds", Formatters.trimmed(seconds, digits: 1), "--out", outputPath]
        return a
    }
}

/// `benchmark --engine E (--voice V | --ref-voice ID) --lang L`: prints one `benchmark` event.
struct BenchmarkRequest: Hashable, Sendable {
    var voice: VoiceSelection
    var language: String

    var arguments: [String] { ["benchmark"] + voice.voiceArguments + ["--lang", language] }
}
