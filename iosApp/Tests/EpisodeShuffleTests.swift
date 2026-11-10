import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class EpisodeShuffleTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let file = EpisodeFile(fileId: 1, resolution: "1080p", codecVideo: "h264", hdr: false,
                                   audioChannels: nil, container: nil, fileSize: nil)

    private func episode(_ id: String, season: Int, number: Int, airDate: String? = nil,
                         files: [EpisodeFile]?) -> EpisodeListItem {
        EpisodeListItem(contentId: id, seasonNumber: season, episodeNumber: number, title: nil, overview: nil,
                        airDate: airDate, runtime: nil, imdbId: nil, tmdbId: nil, tvdbId: nil, stillUrl: nil,
                        stillThumbhash: nil, userData: nil, files: files)
    }

    private func queue(_ episodes: [EpisodeListItem], seed: UInt64 = 7) -> EpisodeShuffleQueue? {
        var generator = SeededGenerator(state: seed)
        return EpisodeShuffleQueue.make(seriesId: "s", seriesTitle: "Show", episodes: episodes, now: now,
                                        using: &generator)
    }

    func testKeepsEveryPlayableRegularEpisodeOnceAndLeavesSpecialsOut() throws {
        let episodes = (1...6).map { episode("e\($0)", season: ($0 + 1) / 2, number: $0, files: [file]) }
            + [episode("special", season: 0, number: 1, files: [file]), episode("e1", season: 1, number: 1, files: [file])]
        let shuffled = try XCTUnwrap(queue(episodes))
        XCTAssertEqual(Set(shuffled.episodes.map(\.contentId)), Set((1...6).map { "e\($0)" }))
        XCTAssertEqual(shuffled.episodes.count, 6, "A repeated episode plays once")
    }

    func testLeavesOutMissingAndUnairedEpisodes() throws {
        let episodes = [
            episode("has-file", season: 1, number: 1, files: [file]),
            episode("missing", season: 1, number: 2, files: []),
            episode("aired", season: 1, number: 3, airDate: "2020-01-01", files: nil),
            episode("unaired", season: 1, number: 4, airDate: "2099-01-01", files: nil),
            episode("unknown", season: 1, number: 5, files: nil),
            episode("early-file", season: 1, number: 6, airDate: "2099-01-01", files: [file]),
        ]
        let shuffled = try XCTUnwrap(queue(episodes))
        XCTAssertEqual(Set(shuffled.episodes.map(\.contentId)), ["has-file", "aired"])
    }

    func testNothingPlayableMakesNoQueue() {
        XCTAssertNil(queue([episode("special", season: 0, number: 1, files: [file])]))
    }

    func testFollowsTheOrderAndEndsAfterTheLastEpisode() throws {
        let shuffled = try XCTUnwrap(queue((1...5).map { episode("e\($0)", season: 1, number: $0, files: [file]) }))
        let order = shuffled.episodes.map(\.contentId)
        for index in 0..<(order.count - 1) {
            XCTAssertEqual(shuffled.episode(after: order[index])?.contentId, order[index + 1])
        }
        XCTAssertNil(shuffled.episode(after: order[order.count - 1]))
        XCTAssertNil(shuffled.episode(after: "not-in-it"))
    }

    @MainActor
    func testTheHandoffIsTakenOnceOnlyByItsFirstEpisode() throws {
        let shuffled = try XCTUnwrap(queue((1...3).map { episode("e\($0)", season: 1, number: $0, files: [file]) }))
        let first = try XCTUnwrap(shuffled.episodes.first?.contentId)
        let handoff = EpisodeShuffleHandoff()
        handoff.stage(shuffled)
        XCTAssertNil(handoff.take(for: "another"), "Another start clears it")
        XCTAssertNil(handoff.take(for: first))
        handoff.stage(shuffled)
        XCTAssertNotNil(handoff.take(for: first))
        XCTAssertNil(handoff.take(for: first), "One use only")
        handoff.stage(shuffled)
        XCTAssertNil(handoff.take(for: first, now: Date().addingTimeInterval(120)), "Expires after a minute")
    }

    // MARK: Subtitles

    private func prefs(language: String?, mode: SubtitleMode, forcedOnly: Bool = false,
                       fallback: [String] = []) -> PlayerViewModel.PrefsSnapshot {
        PlayerViewModel.PrefsSnapshot(
            preferredLanguage: language, additionalPreferredLanguages: [], mode: mode, showForced: forcedOnly,
            forcedOnly: forcedOnly, preferAccessibilityTracks: false, disableWhenNoLanguageMatch: language != nil,
            trackSignature: nil, fallbackLanguages: fallback
        )
    }

    func testAMissingSubtitleLanguageFallsBackToSettingsThenEnglish() {
        let viewing = prefs(language: "fr", mode: .always)
        let settings = prefs(language: "de", mode: .auto, fallback: ["es"])
        let result = PlayerViewModel.shuffleSubtitlePrefs(viewing, settings: settings)
        XCTAssertEqual(result.preferredLanguage, "fr")
        XCTAssertEqual(result.fallbackLanguages, ["de", "es", "en"])
    }

    func testAFreshShuffleAddsEnglishToSettings() {
        let settings = prefs(language: "de", mode: .auto)
        let result = PlayerViewModel.shuffleSubtitlePrefs(settings, settings: settings)
        XCTAssertEqual(result.preferredLanguage, "de")
        XCTAssertEqual(result.fallbackLanguages, ["en"])
    }

    func testOffAndForcedOnlyPicksAreKept() {
        let settings = prefs(language: "de", mode: .always)
        let off = prefs(language: nil, mode: .off)
        XCTAssertEqual(PlayerViewModel.shuffleSubtitlePrefs(off, settings: settings).fallbackLanguages, [])
        let forced = prefs(language: "fr", mode: .always, forcedOnly: true)
        XCTAssertEqual(PlayerViewModel.shuffleSubtitlePrefs(forced, settings: settings).fallbackLanguages, [])
    }
}
