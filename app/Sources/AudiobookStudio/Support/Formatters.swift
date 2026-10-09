import Foundation

/// User-facing number and time formatting. All output is English and locale-independent
/// (decimal point, "," grouping), so the UI reads the same everywhere and the strings are testable.
///
/// Honest numbers: these functions only format values the engine reported. They never invent an ETA;
/// `eta(...)` says "calibrating…" when the engine has no basis for one yet.
enum Formatters {

    // MARK: Durations

    /// "45 s", "23 min", "1 h 23 min", "2 h". Minutes are rounded to the nearest minute.
    static func duration(_ seconds: Double) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        if s < 59.5 { return "\(Int(s.rounded())) s" }
        let totalMinutes = Int((s / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let h = totalMinutes / 60, m = totalMinutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// Elapsed time as a clock: "4:05", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Remaining time as a range: "about 23 min (20–27)", "about 1 h 5 min (58 min–1 h 12 min)",
    /// "about 3 min" (when the range collapses), or "calibrating…" when the engine has no estimate yet.
    static func eta(seconds: Double?, low: Double?, high: Double?, basis: String?) -> String {
        guard basis != "calibrating", let seconds else { return "calibrating…" }
        let main = duration(seconds)
        guard let low, let high else { return "about \(main)" }
        let lowText = duration(low), highText = duration(high)
        if lowText == highText { return "about \(main)" }
        let all = [seconds, low, high]
        // Same unit everywhere: print the unit once, like "about 23 min (20–27)".
        if all.allSatisfy({ $0 >= 59.5 && Int(($0 / 60).rounded()) < 60 }) {
            return "about \(main) (\(Int((low / 60).rounded()))–\(Int((high / 60).rounded())))"
        }
        if all.allSatisfy({ $0 < 59.5 }) {
            return "about \(main) (\(Int(low.rounded()))–\(Int(high.rounded())))"
        }
        return "about \(main) (\(lowText)–\(highText))"
    }

    /// ETA of a `progress` event.
    static func eta(_ progress: EngineEvent) -> String {
        eta(seconds: progress.etaS, low: progress.etaLowS, high: progress.etaHighS, basis: progress.etaBasis)
    }

    /// A pre-conversion estimate: "≈ 41 min".
    static func estimate(_ seconds: Double) -> String { "≈ \(duration(seconds))" }

    // MARK: Speed

    /// "14× real time", "3.3× real time", "0.56× real time".
    static func realtime(_ x: Double) -> String { "\(multiplier(x)) real time" }

    /// "14×", "3.3×", "0.56×".
    static func multiplier(_ x: Double) -> String {
        let digits = x < 1 ? 2 : (x < 10 ? 1 : 0)
        return trimmed(x, digits: digits) + "×"
    }

    /// "61 characters/s", "9.5 characters/s".
    static func charsPerSecond(_ cps: Double) -> String {
        trimmed(cps, digits: cps < 10 ? 1 : 0) + " characters/s"
    }

    // MARK: Sizes and counts

    /// Decimal units like Finder: "0 bytes", "512 bytes", "64 KB", "172.2 MB", "6.2 GB".
    static func bytes(_ count: Int64) -> String {
        let n = Double(max(0, count))
        if n < 1000 { return count == 1 ? "1 byte" : "\(Int(n)) bytes" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = n / 1000
        var unit = 0
        while value >= 999.95 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return trimmed(value, digits: unit == 0 ? 0 : 1) + " " + units[unit]
    }

    static func bytes(_ count: Int) -> String { bytes(Int64(count)) }

    /// "6.2 GB" from the engine's `download_gb`.
    static func gigabytes(_ gb: Double) -> String { bytes(Int64((gb * 1e9).rounded())) }

    /// "8.4 MB" from the engine's `size_mb`.
    static func megabytes(_ mb: Double) -> String { bytes(Int64((mb * 1e6).rounded())) }

    /// "705,384".
    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    /// "705,384 characters", "1 character".
    static func characters(_ n: Int) -> String { n == 1 ? "1 character" : "\(count(n)) characters" }

    /// "43%" (0...100 input).
    static func percent(_ p: Double) -> String { "\(Int(max(0, min(100, p)).rounded(.down)))%" }

    // MARK: Words

    /// "English", "French", or the code itself.
    static func languageName(_ code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "fr": return "French"
        default: return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
        }
    }

    /// How the engine found the book's language: "from metadata", "detected", "default".
    static func languageSource(_ source: String?) -> String {
        switch source {
        case "metadata": return "from metadata"
        case "detected": return "detected"
        case "default": return "not detected (default)"
        case let other?: return other
        case nil: return "detected"
        }
    }

    /// Fixed-point with trailing zeros removed: 3.30 → "3.3", 14.0 → "14".
    static func trimmed(_ value: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
