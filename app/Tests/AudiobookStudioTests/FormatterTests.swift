import Foundation
import Testing
@testable import AudiobookStudio

@Test func durations() {
    #expect(Formatters.duration(0) == "0 s")
    #expect(Formatters.duration(45) == "45 s")
    #expect(Formatters.duration(59.4) == "59 s")
    #expect(Formatters.duration(60) == "1 min")
    #expect(Formatters.duration(23 * 60 + 10) == "23 min")
    #expect(Formatters.duration(4980) == "1 h 23 min")
    #expect(Formatters.duration(7200) == "2 h")
    #expect(Formatters.duration(3599) == "1 h")           // rounds to 60 min
    #expect(Formatters.duration(45850) == "12 h 44 min")  // Pride and Prejudice listening time
    #expect(Formatters.duration(-5) == "0 s")
    #expect(Formatters.duration(.nan) == "0 s")
}

@Test func clockFormatting() {
    #expect(Formatters.clock(0) == "0:00")
    #expect(Formatters.clock(245) == "4:05")
    #expect(Formatters.clock(3723) == "1:02:03")
}

@Test func etaRanges() {
    #expect(Formatters.eta(seconds: 23 * 60, low: 20 * 60, high: 27 * 60, basis: "measured") == "about 23 min (20–27)")
    #expect(Formatters.eta(seconds: 2080, low: 1900, high: 2300, basis: "measured") == "about 35 min (32–38)")
    // Range collapses after rounding (fixture: eta 323, low 294, high 323).
    #expect(Formatters.eta(seconds: 323, low: 294, high: 323, basis: "measured") == "about 5 min")
    #expect(Formatters.eta(seconds: 45, low: 40, high: 52, basis: "measured") == "about 45 s (40–52)")
    #expect(Formatters.eta(seconds: 3900, low: 3500, high: 4400, basis: "saved") == "about 1 h 5 min (58 min–1 h 13 min)")
    #expect(Formatters.eta(seconds: 600, low: nil, high: nil, basis: "saved") == "about 10 min")
    // Honest numbers: no estimate while calibrating or when the engine sends none.
    #expect(Formatters.eta(seconds: 600, low: 500, high: 700, basis: "calibrating") == "calibrating…")
    #expect(Formatters.eta(seconds: nil, low: nil, high: nil, basis: nil) == "calibrating…")
}

@Test func etaFromProgressFixture() throws {
    let progress = try Fixtures.events("convert_events.jsonl").filter { $0.event == "progress" }
    #expect(Formatters.eta(progress[0]) == "about 7 min (5–9)")   // 411 s (329–534), basis "saved"
    #expect(Formatters.eta(progress[1]) == "about 5 min")         // 323 s (294–323)
}

@Test func speeds() {
    #expect(Formatters.realtime(14.2) == "14× real time")
    #expect(Formatters.realtime(3.27) == "3.3× real time")
    #expect(Formatters.realtime(3.0) == "3× real time")
    #expect(Formatters.realtime(0.56) == "0.56× real time")
    #expect(Formatters.multiplier(28.54) == "29×")
    #expect(Formatters.charsPerSecond(60.3) == "60 characters/s")
    #expect(Formatters.charsPerSecond(9.52) == "9.5 characters/s")
    #expect(Formatters.estimate(2460) == "≈ 41 min")
}

@Test func sizesAndCounts() {
    #expect(Formatters.bytes(0) == "0 bytes")
    #expect(Formatters.bytes(1) == "1 byte")
    #expect(Formatters.bytes(512) == "512 bytes")
    #expect(Formatters.bytes(64_000) == "64 KB")
    #expect(Formatters.bytes(172_190_507) == "172.2 MB")
    #expect(Formatters.bytes(Int64(999_960_000)) == "1 GB")
    #expect(Formatters.bytes(Int64(6_731_423_034)) == "6.7 GB")
    #expect(Formatters.gigabytes(6.2) == "6.2 GB")
    #expect(Formatters.gigabytes(0.35) == "350 MB")
    #expect(Formatters.megabytes(8.4) == "8.4 MB")
    #expect(Formatters.count(705_384) == "705,384")
    #expect(Formatters.characters(1) == "1 character")
    #expect(Formatters.characters(17_815) == "17,815 characters")
    #expect(Formatters.percent(43.54) == "43%")
    #expect(Formatters.percent(100) == "100%")
    #expect(Formatters.percent(120) == "100%")
}

@Test func words() {
    #expect(Formatters.languageName("en") == "English")
    #expect(Formatters.languageName("fr") == "French")
    #expect(Formatters.languageSource("metadata") == "from metadata")
    #expect(Formatters.languageSource("detected") == "detected")
    #expect(Formatters.trimmed(1.25, digits: 2) == "1.25")
    #expect(Formatters.trimmed(1.0, digits: 2) == "1")
}
