import Foundation
import Testing
@testable import AudiobookStudio

@Test func splitKeepsPartialLastLine() {
    let data = Data("{\"event\":\"a\"}\n{\"event\":\"b\"}\n{\"event\":\"par".utf8)
    let (lines, rest) = EventTailer.split(data)
    #expect(lines.count == 2)
    #expect(String(decoding: rest, as: UTF8.self) == "{\"event\":\"par")
}

@Test func tailerYieldsUntilTerminalEvent() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("events-\(UUID().uuidString).jsonl")
    try Data("{\"event\":\"job_start\",\"total_chars\":10}\n{\"event\":\"progress\",\"percent\":50.0,\"eta_s\":12}\n".utf8).write(to: url)
    let tailer = EventTailer(url: url, pollInterval: .milliseconds(50))
    let writer = Task {
        try await Task.sleep(for: .milliseconds(150))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"event\":\"done\",\"output\":\"/x.m4b\",\"duration_s\":3.5}\n{\"event\":\"ignored\"}\n".utf8))
        try h.close()
    }
    var seen: [String] = []
    for await ev in tailer.events() { seen.append(ev.event ?? "?") }
    try await writer.value
    #expect(seen == ["job_start", "progress", "done"])
}

@Test func decodesSnakeCaseProgress() throws {
    let line = #"{"t": 71.9, "event": "progress", "chars_done": 14820, "total_chars": 414423, "percent": 3.58, "rate_cps": 192.2, "eta_s": 2080, "eta_low_s": 1900, "eta_high_s": 2300, "eta_basis": "measured"}"#
    let ev = try EngineJSON.decoder.decode(EngineEvent.self, from: Data(line.utf8))
    #expect(ev.charsDone == 14820 && ev.etaLowS == 1900 && ev.etaBasis == "measured")
}
