import Foundation
import Testing
@testable import AudiobookStudio

// Every fixture is a real engine output. Each one is decoded here into the model the app uses for it.

enum Fixtures {
    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        try EngineJSON.decoder.decode(T.self, from: data(name))
    }

    /// Decodes every line of a .jsonl fixture (fails on any undecodable line).
    static func events(_ name: String) throws -> [EngineEvent] {
        let (lines, rest) = EventTailer.split(try data(name))
        var all = lines
        if !rest.isEmpty { all.append(rest) }
        return try all.map { try EngineJSON.decoder.decode(EngineEvent.self, from: $0) }
    }

    /// Fixture file → test that decodes it. A new fixture without an entry fails `everyFixtureIsDecoded`.
    static let decoded: Set<String> = [
        "benchmark.json", "cache_info.json", "convert_events.jsonl", "detached.json", "engines.json",
        "error.json", "inspect_en.json", "inspect_fr.json", "job_status.json", "jobs_list.json",
        "models_list.json", "sample_events.jsonl", "voices_list.json",
    ]
}

@Test func everyFixtureIsDecoded() throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: Fixtures.directory.path)
        .filter { !$0.hasPrefix(".") }
    #expect(Set(files) == Fixtures.decoded)
}

@Test func decodesBenchmark() throws {
    let ev = try Fixtures.decode("benchmark.json", as: EngineEvent.self)
    #expect(ev.event == "benchmark")
    #expect(ev.engine == "kokoro" && ev.voice == "af_heart" && ev.lang == "en")
    #expect(ev.batch == 1 && ev.chunks == 6 && ev.chars == 1197)
    #expect(ev.charsPerS == 474.4 && ev.realtimeX == 28.54 && ev.secondsPerChar == 0.0602)
    #expect(ev.peakMemoryGb == 2.77 && ev.runs == [2.52] && ev.wallS == 2.52 && ev.audioS == 72.0)
}

@Test func decodesCacheInfo() throws {
    let info = try Fixtures.decode("cache_info.json", as: CacheInfo.self)
    #expect(info.chunksBytes == 172_190_507 && info.jobsBytes == 162_863_989)
    #expect(info.totalBytes == 335_054_496)
    #expect(info.path.hasSuffix("AudiobookStudio"))
}

@Test func decodesConvertEvents() throws {
    let events = try Fixtures.events("convert_events.jsonl")
    #expect(events.count == 30)
    #expect(events.first?.event == "run_start" && events.first?.pid == 73938 && events.first?.jobId == "e8800d406374")

    let start = try #require(events.first { $0.event == "job_start" })
    #expect(start.title == "Le tour du monde en quatre-vingts jours" && start.engineName == "Qwen3-TTS 1.7B")
    #expect(start.sections?.map(\.index) == [-1, 3, 4])
    #expect(start.sections?.last?.chunks == 40)
    #expect(start.totalChars == 17815 && start.cachedChars == 0 && start.savedRateCps == 43.51 && start.estWallS == 412)
    #expect(start.warnings?.count == 1)

    let loading = try #require(events.first { $0.event == "model_loading" })
    #expect(loading.checkpoint == "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit")
    #expect(events.first { $0.event == "qa_model_loaded" }?.loadS == 0.85)

    let progress = events.filter { $0.event == "progress" }
    #expect(progress.count == 14)
    #expect(progress.first?.etaBasis == "saved" && progress.first?.rateCps == nil)
    #expect(progress.last?.percent == 100.0 && progress.last?.qa?.checked == 99)

    let encoding = events.filter { $0.event == "encoding" }
    #expect(encoding.first?.encoder == "aac_at" && encoding.last?.percent == 100)

    let done = try #require(events.last)
    #expect(done.event == "done" && done.isTerminal)
    #expect(done.durationS == 1011.2 && done.chapters == 3 && done.sizeMb == 8.4 && done.freedWorkMb == 26.4)
    #expect(done.verificationProblems == [] && done.flaggedChunks == 0)
    #expect(done.qa == QAStats(checked: 99, redone: 0, flagged: 0))
}

@Test func decodesDetached() throws {
    let d = try Fixtures.decode("detached.json", as: DetachedJob.self)
    #expect(d.event == "detached" && d.jobId == "5b212f0ec9f9" && d.pid == 76827)
    #expect(d.eventsURL.lastPathComponent == "events.jsonl")
    #expect(d.alreadyRunning == nil)
}

@Test func decodesEngines() throws {
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    #expect(list.engines.map(\.id) == ["qwen3", "voxtral", "fish", "kokoro"])
    let fish = try #require(list.engine("fish"))
    #expect(fish.noncommercial && !fish.supportsPresets && fish.supportsCloning && fish.voices.isEmpty)
    #expect(list.engine("kokoro")?.supportsSpeed == true && list.engine("kokoro")?.voices.count == 21)
    #expect(list.engine("qwen3")?.batchSize == 8 && list.engine("qwen3")?.downloadGb == 6.2)
    #expect(list.measured.count == 8)
    // Exact voice, then the median of the engine's measured voices.
    #expect(list.rate(engine: "kokoro", voice: "af_bella") == 250.47)
    #expect(list.rate(engine: "kokoro", voice: "am_adam") == 188.33)
    #expect(list.measurement(engine: "kokoro", voice: "am_adam")?.exactVoice == false)
    #expect(list.rate(engine: "nothing", voice: nil) == nil)
    #expect(list.measuredRates.first?.id == "kokoro|ff_siwis")   // most recently updated
}

@Test func decodesErrorEvent() throws {
    let ev = try Fixtures.decode("error.json", as: EngineEvent.self)
    #expect(ev.event == "error" && ev.isTerminal)
    #expect(ev.message == "File not found: /nonexistent.epub")
}

@Test func decodesEnglishInspect() throws {
    let book = try Fixtures.decode("inspect_en.json", as: BookInfo.self)
    #expect(book.title == "Pride and Prejudice" && book.author == "Jane Austen" && book.format == "epub")
    #expect(book.language == "en" && book.languageSource == "metadata")
    #expect(book.cover?.mediaType == "image/jpeg" && book.cover?.writtenTo == nil)
    #expect(book.metadata?.tocEntries == 63 && book.metadata?.identifier == "http://www.gutenberg.org/1342")
    #expect(book.sections.count == 66)
    #expect(book.sections.first?.sectionKind == .front && book.sections.first?.reasons == ["Project Gutenberg header"])
    let included = book.sections.filter(\.include)
    #expect(included.reduce(0) { $0 + $1.chars } == book.includedChars)
    #expect(Set(book.sections.map(\.sectionKind)) == [.front, .chapter, .back])
}

@Test func decodesFrenchInspect() throws {
    let book = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    #expect(book.language == "fr" && book.cover?.mediaType == "image/png")
    #expect(book.sections.count == 42 && book.includedChars == 412_027)
    #expect(book.warnings == ["Recovered 'XII', which is missing from the book's table of contents."])
    #expect(book.sections[2].reasons == ["mostly headings: looks like a printed table of contents"])
}

@Test func decodesJobStatus() throws {
    let job = try Fixtures.decode("job_status.json", as: JobStatus.self)
    #expect(job.jobId == "e8800d406374" && job.jobState == .done && !job.isActive)
    #expect(job.argv?.first == "convert" && job.argv?.contains("--ref-voice") == true)
    #expect(job.outputs?.count == 1 && job.outputURL?.pathExtension == "m4b")
    #expect(job.lastProgress?.qa?.checked == 99)
    #expect(job.result?.freedWorkMb == 26.4 && job.result?.qa?.flagged == 0)
    #expect(job.lastError == nil && job.stderrTail == nil)
    #expect(job.startedDate != nil && job.finishedDate != nil)
}

@Test func decodesJobsList() throws {
    let list = try Fixtures.decode("jobs_list.json", as: JobList.self)
    #expect(list.jobs.map(\.jobId) == ["13174015a535", "033885dc2758", "549a31e5e8ba"])
    #expect(list.jobs.allSatisfy { $0.jobState == .done })
    #expect(list.jobs[1].result?.realtimeX == 12.95 && list.jobs[1].lastProgress?.etaBasis == "measured")
}

@Test func decodesModelsList() throws {
    let list = try Fixtures.decode("models_list.json", as: ModelList.self)
    #expect(list.models.map(\.engine) == ["qwen3", "voxtral", "fish", "kokoro", "whisper"])
    let qwen = try #require(list.models.first)
    #expect(qwen.parts.count == 2 && qwen.installed && qwen.noncommercial == false)
    #expect(qwen.installedBytes == 3_080_141_538 + 3_104_158_788)
    #expect(list.models[1].noncommercial == true)
}

@Test func decodesSampleEvents() throws {
    let events = try Fixtures.events("sample_events.jsonl")
    let done = try #require(events.last)
    #expect(done.event == "sample_done" && done.section == 3 && done.title == "Chapter I.")
    #expect(done.audioS == 26.0 && done.rateCps == 118.8 && done.realtimeX == nil && done.qa == nil)
    #expect(done.bookChars == 708_164 && done.bookEstWallS == 5961)
    #expect(done.note?.hasPrefix("Projection from this sample") == true)
}

@Test func decodesVoicesList() throws {
    let list = try Fixtures.decode("voices_list.json", as: VoiceList.self)
    #expect(list.voices.count == 11)
    let siwis = try #require(list.voices.first)
    #expect(siwis.id == "fr_siwis_female_book" && siwis.lang == "fr" && siwis.isInstalled)
    #expect(siwis.commercialOk == true && siwis.transcriptSource == "published" && siwis.durationS == 11.4)
    #expect(siwis.sampleRate == 44100 && siwis.audioUrl != nil && siwis.sha256 != nil && siwis.path != nil)
    #expect(!siwis.isUserClip)
    #expect(list.voices.filter { $0.transcriptSource == "whisper" }.count == 3)
}

/// The engine sends `stderr_tail` as a list of lines; a single string must decode too.
@Test func decodesStderrTailAsLinesOrString() throws {
    let asList = #"{"job_id": "a", "state": "failed", "job_dir": "/j", "stderr_tail": ["Traceback", "ValueError: x"]}"#
    let a = try EngineJSON.decoder.decode(JobStatus.self, from: Data(asList.utf8))
    #expect(a.stderrTail?.text == "Traceback\nValueError: x" && a.jobState == .failed && a.jobState.canResume)
    let asString = #"{"job_id": "b", "state": "interrupted", "job_dir": "/j", "stderr_tail": "one\ntwo"}"#
    let b = try EngineJSON.decoder.decode(JobStatus.self, from: Data(asString.utf8))
    #expect(b.stderrTail?.lines == ["one", "two"])
}
