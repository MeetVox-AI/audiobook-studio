import Foundation

/// The book being prepared on the "New audiobook" screen: the engine's `inspect` result plus the
/// user's choices (sections to include, language). Owned by `AppModel.draft`; edit it in place,
/// e.g. `model.draft?.setIncluded(3, false)`.
struct BookDraft: Hashable, Sendable {
    /// The .epub / .pdf file.
    var url: URL
    /// `inspect` output (never modified; the engine's defaults live here).
    var info: BookInfo
    /// Indexes of the sections to convert. Starts as the engine's selection (front/back matter unticked).
    var included: Set<Int>
    /// Book language passed to the engine ("en" / "fr"). Defaults to the detected language.
    var language: String
    /// Cover image written by `inspect --cover-out` into a temporary folder (nil when the book has none).
    var coverURL: URL?
    /// Editable title and author. v1 displays them only: the engine takes them from the book.
    var title: String
    var author: String

    init(url: URL, info: BookInfo, coverURL: URL?) {
        self.url = url
        self.info = info
        self.included = Set(info.sections.filter(\.include).map(\.index))
        self.language = info.language
        self.coverURL = coverURL
        self.title = info.title
        self.author = info.author
    }

    var sections: [SectionInfo] { info.sections }
    var warnings: [String] { info.warnings ?? [] }

    func isIncluded(_ index: Int) -> Bool { included.contains(index) }

    mutating func setIncluded(_ index: Int, _ on: Bool) {
        if on { included.insert(index) } else { included.remove(index) }
    }

    mutating func toggle(_ index: Int) { setIncluded(index, !included.contains(index)) }

    /// Ticks or unticks every section (or every section of one kind).
    mutating func setAll(_ on: Bool, kind: SectionKind? = nil) {
        for s in sections where kind == nil || s.sectionKind == kind {
            setIncluded(s.index, on)
        }
    }

    /// Back to the engine's suggested selection.
    mutating func resetSelection() {
        included = Set(sections.filter(\.include).map(\.index))
    }

    // MARK: Totals (for the totals bar)

    var includedSections: [SectionInfo] { sections.filter { included.contains($0.index) } }
    var includedChars: Int { includedSections.reduce(0) { $0 + $1.chars } }
    /// Estimated listening time of the selection (engine estimate per section).
    var includedEstSeconds: Double { includedSections.reduce(0) { $0 + $1.estSeconds } }
    var hasSelection: Bool { !included.isEmpty }

    /// `--sections` value, e.g. "2-14,20".
    var sectionsArgument: String { BookDraft.sectionsSpec(included) }

    /// "from metadata" / "detected" for the detected language; nil once the user picked another one.
    var languageSourceLabel: String? {
        language == info.language ? Formatters.languageSource(info.languageSource) : nil
    }

    /// Compresses section indexes into the engine's range syntax: [2,3,4,7] → "2-4,7".
    static func sectionsSpec<S: Sequence>(_ indexes: S) -> String where S.Element == Int {
        let sorted = Array(Set(indexes)).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i])" : "\(sorted[i])-\(sorted[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }
}

/// Estimated conversion time on this Mac, from a measured engine speed (`engines.measured`).
struct ConversionEstimate: Hashable, Sendable {
    /// Synthesis time at the measured speed (characters ÷ characters per second).
    var seconds: Double
    var charsPerSecond: Double
    /// True when this exact voice was measured; false when it is the median of the engine's other voices.
    var exactVoice: Bool
    var measurement: SpeedMeasurement

    /// "On this Mac: ≈ 41 min".
    var summary: String { "On this Mac: \(Formatters.estimate(seconds))" }

    /// Shown when no measurement exists for the engine.
    static let unavailableMessage = "Run a benchmark or make a sample to get an estimate"
}
