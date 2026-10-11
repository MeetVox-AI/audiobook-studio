import Foundation
import Testing
@testable import AudiobookStudio

// Favourite voices: stored in AppSettings (UserDefaults, a throw-away suite per test), the browser's
// "Favourites" filter, starred-first ordering, and survival across a relaunch. The real defaults domain is never used.

@MainActor
private func makeSuite() throws -> (UserDefaults, String) {
    let suite = "AudiobookStudioFavoriteTests-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

@MainActor
private func makeModel(settings: AppSettings) throws -> AppModel {
    settings.enginePath = "/nonexistent/audiobook-engine-\(UUID().uuidString)"
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FavoriteTests-\(UUID().uuidString)")
    let model = AppModel(settings: settings, scratchDirectory: scratch)
    let info = try Fixtures.decode("inspect_fr.json", as: BookInfo.self)
    model.draft = BookDraft(url: URL(fileURLWithPath: "/books/fr.epub"), info: info, coverURL: nil)
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let models = try Fixtures.decode("models_list.json", as: ModelList.self).models
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices
    model.preload(engines: list, models: models, voices: voices)
    return model
}

@Test @MainActor func favouritesToggleAndPersistAcrossRelaunch() throws {
    let (defaults, suite) = try makeSuite()
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.favoriteVoices.isEmpty)

    settings.toggleFavoriteVoice("ref:fr_siwis_female_book")
    settings.toggleFavoriteVoice("preset:kokoro:af_heart")
    #expect(settings.isFavoriteVoice("ref:fr_siwis_female_book"))
    settings.toggleFavoriteVoice("preset:kokoro:af_heart")
    #expect(!settings.isFavoriteVoice("preset:kokoro:af_heart"))

    // A new AppSettings on the same suite is what a relaunch sees.
    let relaunched = AppSettings(defaults: defaults)
    #expect(relaunched.favoriteVoices == ["ref:fr_siwis_female_book"])
    relaunched.setFavoriteVoice("ref:fr_siwis_female_book", false)
    #expect(AppSettings(defaults: defaults).favoriteVoices.isEmpty)
}

@Test @MainActor func favouritesDoNotLeakIntoAnotherSuite() throws {
    let (a, suiteA) = try makeSuite()
    let (b, suiteB) = try makeSuite()
    defer { a.removePersistentDomain(forName: suiteA); b.removePersistentDomain(forName: suiteB) }
    AppSettings(defaults: a).toggleFavoriteVoice("ref:x")
    #expect(AppSettings(defaults: b).favoriteVoices.isEmpty)
}

@Test @MainActor func favouritesFilterShowsOnlyStarredVoicesAndResets() throws {
    let (defaults, suite) = try makeSuite()
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = try makeModel(settings: settings)
    model.voiceLab.filter = VoiceFilter(language: .all)
    let all = model.filteredVoiceOptions
    #expect(all.count > 3)

    // Favourites on with nothing starred: nothing to show, and the empty state may say so.
    model.voiceLab.filter.favoritesOnly = true
    #expect(model.filteredVoiceOptions.isEmpty)
    #expect(model.favoriteVoiceCount == 0)

    // One preset, one reference voice (installed or not: any library voice) are starred.
    let preset = try #require(all.first { $0.kind == .preset })
    let reference = try #require(all.first { $0.kind == .library })
    settings.toggleFavoriteVoice(preset.id)
    settings.toggleFavoriteVoice(reference.id)
    #expect(Set(model.filteredVoiceOptions.map(\.id)) == [preset.id, reference.id])
    #expect(model.favoriteVoiceCount == 2)

    // Other filters still apply on top (gender that matches neither).
    model.voiceLab.filter.gender = preset.gender == "male" ? "female" : "male"
    #expect(!model.filteredVoiceOptions.contains { $0.id == preset.id })

    #expect(model.voiceLab.filter.isNarrowed)
    model.voiceLab.filter = VoiceFilter()   // Reset Filters
    #expect(!model.voiceLab.filter.favoritesOnly)
    #expect(!model.voiceLab.filter.isNarrowed)
    var onlyFavourites = VoiceFilter()
    onlyFavourites.favoritesOnly = true
    #expect(onlyFavourites.isNarrowed)
}

@Test func starredVoicesSortFirstInsideEachGroup() throws {
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices
    let options = VoiceCatalog.options(engines: list.engines, voices: voices)
    let plain = VoiceCatalog.groups(options, engines: list.engines)
    let library = try #require(plain.first { $0.id == "library" })
    let last = try #require(library.options.last)
    let starred = VoiceCatalog.groups(options, engines: list.engines, favorites: [last.id])
    #expect(starred.map(\.id) == plain.map(\.id))   // same groups, same order
    let starredLibrary = try #require(starred.first { $0.id == "library" })
    #expect(starredLibrary.options.first?.id == last.id)
    #expect(Set(starredLibrary.options.map(\.id)) == Set(library.options.map(\.id)))
    // The other groups keep their order.
    #expect(starred.dropFirst().map { $0.options.map(\.id) } == plain.dropFirst().map { $0.options.map(\.id) })
}

@Test @MainActor func presetsOfDifferentEnginesAreStarredSeparatelyButReferenceVoicesOnce() throws {
    let list = try Fixtures.decode("engines.json", as: EngineList.self)
    let voices = try Fixtures.decode("voices_list.json", as: VoiceList.self).voices
    let options = VoiceCatalog.options(engines: list.engines, voices: voices)
    // A reference voice is one row whichever engines clone it, so its key carries no engine.
    let reference = try #require(options.first { $0.kind == .library })
    #expect(reference.id == "ref:\(reference.voiceId)" && reference.engineIds.count > 1)
    // Presets are keyed with their engine.
    #expect(options.filter { $0.kind == .preset }.allSatisfy { $0.id == "preset:\($0.engineIds[0]):\($0.voiceId)" })
}

@Test @MainActor func deletingAUserClipDropsItsStarButUninstallingALibraryVoiceKeepsIt() throws {
    let (defaults, suite) = try makeSuite()
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let model = try makeModel(settings: settings)
    settings.favoriteVoices = ["ref:user-ma-voix", "ref:fr_siwis_female_book", "preset:kokoro:af_heart"]
    model.forgetVoice("user-ma-voix", file: nil)
    #expect(settings.favoriteVoices == ["ref:fr_siwis_female_book", "preset:kokoro:af_heart"])
    model.forgetVoice("fr_siwis_female_book", file: nil)
    #expect(settings.isFavoriteVoice("ref:fr_siwis_female_book"))
}
