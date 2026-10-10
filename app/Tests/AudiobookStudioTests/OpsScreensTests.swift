import Foundation
import Testing
@testable import AudiobookStudio

// Tests for the display logic of the Jobs, Job detail, Models, Benchmark and Settings screens
// (State/AppModel+Jobs.swift), against the real engine fixtures.

@MainActor
private func fixtureModel() throws -> (AppModel, UserDefaults, String) {
    let suite = "AudiobookStudioOpsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let model = AppModel(settings: AppSettings(defaults: defaults))
    model.preload(engines: try Fixtures.decode("engines.json", as: EngineList.self),
                  models: try Fixtures.decode("models_list.json", as: ModelList.self).models,
                  voices: try Fixtures.decode("voices_list.json", as: VoiceList.self).voices,
                  jobs: try Fixtures.decode("jobs_list.json", as: JobList.self).jobs,
                  cache: try Fixtures.decode("cache_info.json", as: CacheInfo.self))
    return (model, defaults, suite)
}

/// A monitor fed with the real convert fixture, up to (and including) the event that matches `stop`.
@MainActor
private func fixtureMonitor(until stop: ((EngineEvent) -> Bool)? = nil) throws -> JobMonitor {
    let monitor = JobMonitor(jobId: "e8800d406374", jobDir: URL(fileURLWithPath: "/tmp/jobs/e8800d406374"), pid: 73938,
                             initialState: .running, client: nil, options: .testing)
    for ev in try Fixtures.events("convert_events.jsonl") {
        monitor.apply(ev)
        if let stop, stop(ev) { break }
    }
    return monitor
}

// MARK: - Dates

@Test func jobDatesReadNaturally() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 20)))
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 18, minute: 28)))
    let yesterday = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 9, minute: 5)))
    let earlier = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 14, minute: 0)))
    let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 24, hour: 8)))
    #expect(JobText.date(today, now: now, calendar: calendar) == "Today at 6:28 PM")
    #expect(JobText.date(yesterday, now: now, calendar: calendar) == "Yesterday at 9:05 AM")
    #expect(JobText.date(earlier, now: now, calendar: calendar) == "Mar 2 at 2:00 PM")
    #expect(JobText.date(lastYear, now: now, calendar: calendar) == "Dec 24, 2025")
}

// MARK: - Job list lines

@MainActor
@Test func jobListLinesFromFixtures() throws {
    let jobs = try Fixtures.decode("jobs_list.json", as: JobList.self).jobs
    let first = try #require(jobs.first)
    // 377.4 s of audio, 1 chapter, 3.7 MB.
    #expect(JobText.listLine(job: first, monitor: nil, state: first.jobState) == "6 min of audio · 1 chapter · 3.7 MB")

    var failed = first
    failed.state = "failed"
    failed.error = "Not enough disk space: 1.2 GB free, about 3 GB needed."
    #expect(JobText.listLine(job: failed, monitor: nil, state: failed.jobState) == "Not enough disk space: 1.2 GB free, about 3 GB needed.")

    var cancelled = first
    cancelled.state = "cancelled"
    cancelled.lastProgress = EngineEvent(event: "progress", percent: 43.54)
    #expect(JobText.listLine(job: cancelled, monitor: nil, state: cancelled.jobState)
            == "Cancelled at 43%. Resume to continue where it stopped.")
    var interrupted = cancelled
    interrupted.state = "interrupted"
    #expect(JobText.listLine(job: interrupted, monitor: nil, state: interrupted.jobState)
            == "Stopped unexpectedly at 43%. Resume to continue where it stopped.")

    var running = cancelled
    running.state = "running"
    #expect(JobText.listLine(job: running, monitor: nil, state: .running) == "43% done")
    #expect(JobText.listLine(job: running, monitor: nil, state: .queued) == "Waiting to start")

    var problems = first
    problems.state = "done_with_problems"
    #expect(JobText.listLine(job: problems, monitor: nil, state: problems.jobState)
            == "6 min of audio · 1 chapter · 3.7 MB · the final check found problems")
}

@MainActor
@Test func progressLineFollowsTheMonitor() throws {
    // First progress: no measured speed yet, ETA from the saved rate (411 s, 329–534 s).
    let early = try fixtureMonitor { $0.event == "progress" }
    #expect(JobText.progressLine(monitor: early) == "0% done · time left: about 7 min (5–9)")
    #expect(JobText.etaBasis(early.latestProgress?.etaBasis) == "Based on speeds saved from earlier runs on this Mac; refined as the conversion runs.")

    let mid = try fixtureMonitor { $0.event == "progress" && $0.percent == 43.54 }
    #expect(JobText.progressLine(monitor: mid) == "43% done · time left: about 3 min")
    #expect(JobText.listLine(job: try Fixtures.decode("job_status.json", as: JobStatus.self), monitor: mid, state: mid.state)
            == "43% done · time left: about 3 min")

    // While assembling / encoding, the phase is shown instead.
    let encoding = try fixtureMonitor { $0.event == "encoding" && $0.percent == 44 }
    #expect(JobText.progressLine(monitor: encoding) == "Encoding the audiobook (44%)")

    let done = try fixtureMonitor()
    #expect(done.state == .done)
    let status = try Fixtures.decode("job_status.json", as: JobStatus.self)
    #expect(JobText.listLine(job: status, monitor: done, state: done.state) == "17 min of audio · 3 chapters · 8.4 MB")
}

@Test func etaBasisExplanations() {
    #expect(JobText.etaBasis("measured") == "Based on the speed measured during this conversion.")
    #expect(JobText.etaBasis("calibrating") == "Measuring this Mac's speed; the estimate appears after the first chunks.")
    #expect(JobText.etaBasis(nil) == nil && JobText.etaBasis("guess") == nil)
}

// MARK: - Job screen text

@Test func qualityTexts() {
    #expect(JobText.qa(QAStats(checked: 99, redone: 0, flagged: 0)) == "99 sentences checked · 0 re-generated · 0 flagged")
    #expect(JobText.qa(QAStats(checked: 1, redone: nil, flagged: 2)) == "1 sentence checked · 2 flagged")
    #expect(JobText.qa(QAStats()) == nil && JobText.qa(nil) == nil)

    #expect(JobText.redos([]) == nil)
    let redos = [EngineEvent(event: "qa_redo", fixed: true), EngineEvent(event: "qa_redo", fixed: false),
                 EngineEvent(event: "qa_redo", fixed: true)]
    #expect(JobText.redos(redos) == "3 chunks were narrated again after the speech check; 2 now pass.")
    #expect(JobText.redos([EngineEvent(event: "qa_redo", fixed: false)]) == "1 chunk was narrated again after the speech check; 0 now pass.")
    #expect(JobText.redos([EngineEvent(event: "qa_redo", fixed: true)]) == "1 chunk was narrated again after the speech check; 1 now passes.")
}

@MainActor
@Test func planAndFlaggedChunkTexts() throws {
    let monitor = try fixtureMonitor { $0.event == "job_start" }
    let plan = try #require(monitor.plan)
    #expect(JobText.planSummary(plan) == "17,815 characters · about 18 min of audio · 3 parts")
    #expect(JobText.reused(plan) == nil)
    var cached = plan
    cached.cachedChars = 4200
    #expect(JobText.reused(cached) == "4,200 characters reused from an earlier run")

    // Chunk numbers in events are zero-based; section titles come from job_start.
    #expect(JobText.flaggedLocation(FlaggedChunk(section: 3, chunk: 0, issues: [], text: ""), plan: plan) == "“I”, chunk 1")
    #expect(JobText.flaggedLocation(FlaggedChunk(section: -1, chunk: 0, issues: [], text: ""), plan: plan) == "“Générique”, chunk 1")
    #expect(JobText.flaggedLocation(FlaggedChunk(section: 9, chunk: 2, issues: [], text: ""), plan: plan) == "Section 9, chunk 3")
    #expect(JobText.flaggedLocation(FlaggedChunk(section: -1, chunk: 4, issues: [], text: ""), plan: nil) == "Introduction, chunk 5")

    #expect(JobText.stoppedTitle(.failed) == "The conversion failed")
    #expect(JobText.stoppedTitle(.interrupted) == "The conversion stopped unexpectedly")
    #expect(JobText.stoppedTitle(.cancelled) == "The conversion was cancelled")
}

@Test func speedTrend() {
    #expect(JobSpeedTrend.compare(now: 66, average: 58) == .faster)
    #expect(JobSpeedTrend.compare(now: 50, average: 58) == .slower)
    #expect(JobSpeedTrend.compare(now: 60, average: 58) == .steady)
    #expect(JobSpeedTrend.compare(now: nil, average: 58) == nil)
    #expect(JobSpeedTrend.compare(now: 60, average: 0) == nil)
}

@Test func liveElapsedCountsFromTheLastReport() {
    let received = Date(timeIntervalSinceReferenceDate: 1000)
    let clock = JobLiveElapsed(reported: 40, receivedAt: received)
    #expect(clock.seconds(at: received) == 40)
    #expect(clock.seconds(at: received.addingTimeInterval(5)) == 45)
    #expect(clock.seconds(at: received.addingTimeInterval(-3)) == 40)   // never runs backwards
    #expect(clock.seconds(at: received.addingTimeInterval(10_000)) == 40 + JobLiveElapsed.maxExtrapolation)
}

@MainActor
@Test func rateChartSamplesFromTheFixture() throws {
    let monitor = try fixtureMonitor()
    let points = monitor.rateHistory
    #expect(points.count == 13)   // 14 progress events, the first has no measured speed yet
    #expect(JobRateChart.usesMinutes(points))   // the run lasted about 5 minutes
    let samples = JobRateChart.samples(points)
    let now = samples.filter { $0.series == JobRateChart.nowSeries }
    let average = samples.filter { $0.series == JobRateChart.averageSeries }
    #expect(now.count == 13 && average.count == 13)
    #expect(Set(samples.map(\.id)).count == samples.count)
    let first = try #require(now.first)
    #expect(abs(first.x - 40.0 / 60) < 0.001 && first.charsPerSecond == 50.9)
    #expect(JobRateChart.accessibilitySummary(points) == "Latest 60 characters/s, ranging from 51 characters/s to 61 characters/s")
    #expect(JobRateChart.accessibilitySummary([]) == "No measurements yet")

    let short = [RatePoint(id: 0, elapsed: 30, rateCps: 40), RatePoint(id: 1, elapsed: 60, rateCps: 44)]
    #expect(!JobRateChart.usesMinutes(short) && JobRateChart.samples(short).map(\.x) == [30, 60])
}

@Test func resultSummaryFromTheDoneEvent() throws {
    let status = try Fixtures.decode("job_status.json", as: JobStatus.self)
    let done = try #require(status.result)
    let items = JobResultSummary.items(done)
    #expect(items.map(\.label) == ["Audio length", "Chapters", "File size", "Conversion time", "Speed", "Flagged chunks"])
    #expect(items.map(\.value) == ["17 min", "3", "8.4 MB", "5 min", Formatters.realtime(3.25), "0"])
    #expect(JobResultSummary.freedWork(done) == "Freed 26.4 MB of temporary chapter files.")
    var noFreed = done
    noFreed.freedWorkMb = nil
    #expect(JobResultSummary.freedWork(noFreed) == nil)
}

@Test func benchmarkSummaryFromTheFixture() throws {
    let ev = try Fixtures.decode("benchmark.json", as: EngineEvent.self)
    let items = JobResultSummary.benchmarkItems(ev)
    #expect(items.map(\.label) == ["Speed", "Real time", "Peak memory", "Model loading", "Passage", "Batch size"])
    #expect(items.map(\.value) == ["474 characters/s", "29× real time", "2.8 GB", "0 s + 5 s warm-up",
                                   "1,197 characters, 1 min of audio", "1"])
}

// MARK: - Models

@Test func modelRowTexts() throws {
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    let qwen = try #require(models.first { $0.engine == "qwen3" })
    let installed = OpsModelInfo(status: qwen)
    #expect(installed.stateText == "Installed" && installed.sizeText == "6.2 GB on disk" && installed.canRemove)
    #expect(installed.purposeText == "preset voices (CustomVoice), voice cloning (Base)")
    #expect(installed.remainingDownloadBytes == nil && !installed.lacksSpace(freeBytes: 1))

    var partial = qwen
    partial.installed = false
    partial.parts[1].installed = false
    let p = OpsModelInfo(status: partial)
    #expect(p.isPartial && p.canRemove && p.stateText == "Partly installed (1 of 2 parts)")
    #expect(p.remainingDownloadBytes == Int64(3_119_858_462))
    #expect(p.sizeText == "3.1 GB download")
    #expect(p.lacksSpace(freeBytes: 1_000_000_000) && !p.lacksSpace(freeBytes: 10_000_000_000) && !p.lacksSpace(freeBytes: nil))
    #expect(p.spaceWarning(freeBytes: 1_000_000_000)
            == "Not enough free space: the download needs 3.1 GB and 1 GB is free.")

    var missing = qwen
    missing.installed = false
    missing.parts = missing.parts.map { var part = $0; part.installed = false; return part }
    let m = OpsModelInfo(status: missing)
    #expect(OpsModelInfo(status: try #require(models.first { $0.engine == "voxtral" })).purposeText == nil)
    #expect(OpsModelInfo(status: try #require(models.first { $0.engine == "kokoro" })).purposeText == "model + 54 voices")
    #expect(!m.isPartial && !m.canRemove && m.stateText == "Not installed" && m.sizeText == "6.2 GB download")
}

@Test func diskSpaceProbe() throws {
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    #expect(OpsDiskSpace.modelsFolder(for: models).path == models[0].parts[0].path)
    #expect(OpsDiskSpace.modelsFolder(for: []).path.hasSuffix("/.cache/huggingface/hub"))
    // A folder that does not exist yet is measured on its nearest existing parent.
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ops-\(UUID().uuidString)/a/b")
    let free = try #require(OpsDiskSpace.availableBytes(at: missing))
    #expect(free > 0)
}

// MARK: - Settings

@MainActor
@Test func audioQualityTexts() {
    #expect(OpsAudioQuality.bytesPerHour(kbps: 64) == 28_800_000)
    #expect(OpsAudioQuality.caption(kbps: 64) == "About 28.8 MB per hour of audio.")
    #expect(OpsAudioQuality.caption(kbps: 128) == "About 57.6 MB per hour of audio.")
    #expect(AppSettings.bitrateChoices.map(OpsAudioQuality.title) == ["64 kbps (smallest files)", "96 kbps", "128 kbps (best quality)"])
}

@Test func engineCheckAndCacheTexts() throws {
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    #expect(OpsEngineCheck.summary(list)
            == "The engine works: 4 voice engines (Qwen3-TTS 1.7B, Voxtral TTS 4B, Fish Audio S2 Pro, Kokoro 82M (fast draft)).")
    var one = list
    one.engines = [list.engines[3]]
    #expect(OpsEngineCheck.summary(one) == "The engine works: 1 voice engine (Kokoro 82M (fast draft)).")
    one.engines = []
    #expect(OpsEngineCheck.summary(one) == "The engine answered, but it lists no voice engines.")

    let cache = try Fixtures.decode("cache_info.json", as: CacheInfo.self)
    #expect(OpsCacheText.freed(cache.totalBytes) == "Freed 335.1 MB.")
    #expect(OpsCacheText.freed(0) == "There was nothing to free.")
}

// MARK: - AppModel lookups

@MainActor
@Test func namesAndNarrationLines() throws {
    let (model, defaults, suite) = try fixtureModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(model.opsEngineName("qwen3") == "Qwen3-TTS 1.7B")
    #expect(model.opsEngineName("whisper") == "Whisper large-v3-turbo (quality checks)")
    #expect(model.opsEngineName("unknown") == "unknown" && model.opsEngineName(nil) == nil && model.opsEngineName("") == nil)
    #expect(model.opsVoiceName(engine: "qwen3", voice: "ryan") == "Ryan")
    #expect(model.opsVoiceName(engine: "qwen3", voice: "fr_siwis_female_book") == "SIWIS — studio narrator (F)")
    #expect(model.opsVoiceName(engine: "kokoro", voice: "zz") == "zz")
    #expect(model.opsNarration(engine: "kokoro", voice: "af_bella", language: "en") == "Kokoro 82M (fast draft) · Bella · English")
    #expect(model.opsNarration(engine: nil, voice: nil, language: "fr") == "French")
    #expect(model.opsLanguages == ["en"])
    #expect(model.opsModelInstalled("fish") == true && model.opsModelInstalled("nope") == nil)

    #expect(model.jobsInProgress.isEmpty && model.jobsFinished.count == 3)
    #expect(model.job(withId: "033885dc2758")?.engine == "kokoro" && model.job(withId: "nope") == nil)
}

@MainActor
@Test func narratorChoicesPerEngineAndLanguage() throws {
    let (model, defaults, suite) = try fixtureModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    let engines = model.engines
    let qwen = try #require(engines.first { $0.id == "qwen3" })
    let fish = try #require(engines.first { $0.id == "fish" })
    let kokoro = try #require(engines.first { $0.id == "kokoro" })
    let voxtral = try #require(engines.first { $0.id == "voxtral" })

    // Qwen3 has no French preset: only the 5 installed French voices, cloned.
    let qwenFr = model.opsNarratorChoices(engine: qwen, language: "fr")
    #expect(qwenFr.count == 5 && qwenFr.allSatisfy(\.isClone))
    #expect(qwenFr[0].id == "qwen3|clone:fr_siwis_female_book")
    #expect(qwenFr[0].title == "SIWIS — studio narrator (F) · Qwen3-TTS 1.7B (cloned)")
    #expect(qwenFr[0].title == qwenFr[0].selection.displayName(engines: engines, voices: model.voices))
    // English: presets first, then clones.
    let qwenEn = model.opsNarratorChoices(engine: qwen, language: "en")
    #expect(qwenEn.count == 6 + 6 && qwenEn[0].id == "qwen3|preset:ryan" && !qwenEn[0].isClone && qwenEn[6].isClone)
    // Fish clones only; Kokoro and Voxtral never clone.
    #expect(model.opsNarratorChoices(engine: fish, language: "en").count == 6)
    #expect(model.opsNarratorChoices(engine: kokoro, language: "fr").map(\.id) == ["kokoro|preset:ff_siwis"])
    let voxtralFr = model.opsNarratorChoices(engine: voxtral, language: "fr")
    #expect(voxtralFr.map(\.id) == ["voxtral|preset:fr_female", "voxtral|preset:fr_male"])
    #expect(voxtralFr[0].pickerTitle == "French female · Voxtral TTS 4B — personal use only")
    #expect(model.opsNarratorChoices(engine: kokoro, language: "de").isEmpty)
    #expect(model.opsNarratorChoices(language: "fr").count == 5 + 2 + 5 + 1)

    // Keys ignore speed and speech check.
    #expect(OpsNarratorChoice.key(VoiceSelection(engineId: "qwen3", presetId: "ryan", speed: 1.3, verify: false)) == "qwen3|preset:ryan")
    #expect(OpsNarratorChoice.key(VoiceSelection(engineId: "fish")) == "fish|default")
}

@MainActor
@Test func measuredRowsForTheHistoryTable() throws {
    let (model, defaults, suite) = try fixtureModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    let rows = model.opsMeasuredRows
    #expect(rows.count == 8)
    let newest = try #require(rows.first)
    #expect(newest.id == "kokoro|ff_siwis" && newest.engineName == "Kokoro 82M (fast draft)" && newest.voiceName == "Siwis")
    #expect(newest.source == "Sample" && newest.realtimeText == Formatters.realtime(10.81))
    #expect(newest.updated == JobStatus.parseLocalDate("2026-10-09T18:27:42"))
    let clone = try #require(rows.first { $0.id == "qwen3|fr_siwis_female_book" })
    #expect(clone.voiceName == "SIWIS — studio narrator (F)")
    let convert = try #require(rows.first { $0.id == "kokoro|af_bella" })
    #expect(convert.source == "Conversion" && convert.chars == 18349)
    #expect(rows.map(\.updatedSortKey) == rows.map(\.updatedSortKey).sorted(by: >))

    #expect(OpsMeasuredRow.sourceTitle("benchmark") == "Benchmark")
    #expect(OpsMeasuredRow.sourceTitle("manual") == "Manual" && OpsMeasuredRow.sourceTitle(nil) == "—")
}

@MainActor
@Test func benchmarkFormSelection() throws {
    let (model, defaults, suite) = try fixtureModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    // Defaults follow the current narrator (Qwen3 · Ryan for English).
    let initial = try #require(model.opsBenchmarkSelection(engineId: nil, language: nil, choiceId: nil))
    #expect(initial.engine.id == "qwen3" && initial.language == "en" && initial.choice?.id == "qwen3|preset:ryan")

    // Switching to Fish keeps the language and picks its first cloned voice.
    let fish = try #require(model.opsBenchmarkSelection(engineId: "fish", language: "en", choiceId: nil))
    #expect(fish.choice?.id == "fish|clone:en_ljspeech_lj006_0002_female_us" && fish.choices.count == 6)

    // An unsupported language or voice falls back to something valid.
    let kokoro = try #require(model.opsBenchmarkSelection(engineId: "kokoro", language: "de", choiceId: "qwen3|preset:ryan"))
    #expect(kokoro.language == "en" && kokoro.choice?.id == "kokoro|preset:af_heart")
    let french = try #require(model.opsBenchmarkSelection(engineId: "kokoro", language: "fr", choiceId: "kokoro|preset:ff_siwis"))
    #expect(french.choice?.id == "kokoro|preset:ff_siwis")

    // Before engines load there is nothing to pick.
    let empty = AppModel(settings: AppSettings(defaults: defaults))
    #expect(empty.opsBenchmarkSelection(engineId: nil, language: nil, choiceId: nil) == nil)
    #expect(empty.opsLanguages == ["en"])
}

@MainActor
@Test func modelsInUseByRunningJobs() throws {
    let (model, defaults, suite) = try fixtureModel()
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(!model.opsModelInUse("kokoro") && !model.opsModelInUse(OpsModelInfo.speechCheckModel))
    var jobs = model.jobs
    jobs[1].state = "running"   // the Kokoro job
    model.preload(jobs: jobs)
    #expect(model.jobsInProgress.map(\.jobId) == ["033885dc2758"] && model.jobsFinished.count == 2)
    #expect(model.opsModelInUse("kokoro") && model.opsModelInUse(OpsModelInfo.speechCheckModel))
    #expect(!model.opsModelInUse("qwen3"))
}
