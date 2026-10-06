import XCTest
@testable import Vivid

final class EpisodeSpoilerPolicyTests: XCTestCase {
    private typealias Position = EpisodeSpoilerPolicy.Position

    private func episode(_ season: Int, _ number: Int, played: Bool = false, inProgress: Bool = false) throws -> EpisodeListItem {
        let json = """
        {"contentId":"s\(season)e\(number)","seasonNumber":\(season),"episodeNumber":\(number),
         "title":"Episode \(number) Title","overview":"Something happens in episode \(number), then more.",
         "userData":{"played":\(played),"isInProgress":\(inProgress)}}
        """
        return try JSONDecoder().decode(EpisodeListItem.self, from: Data(json.utf8))
    }

    private func season(_ number: Int, episodeCount: Int = 3, userData: String? = nil) throws -> Season {
        var json = #"{"contentId":"season-\#(number)","seasonNumber":\#(number),"episodeCount":\#(episodeCount)"#
        if let userData { json += #","userData":\#(userData)"# }
        json += "}"
        return try JSONDecoder().decode(Season.self, from: Data(json.utf8))
    }

    func testFreshSeriesKeepsItsFirstEpisodeAndCoversTheRest() throws {
        let seasons = [try season(0, episodeCount: 1), try season(1), try season(2)]
        let pages = [
            0: [try episode(0, 1)],
            1: [try episode(1, 1), try episode(1, 2), try episode(1, 3)],
            2: [try episode(2, 1)],
        ]
        let position = EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
        XCTAssertEqual(position, Position(season: 1, episode: 1))

        let covered = EpisodeSpoilerPolicy.cover(pages, after: position)
        XCTAssertEqual(covered[1]?.map(\.hidesSpoilers), [false, true, true])
        XCTAssertEqual(covered[2]?.map(\.hidesSpoilers), [true])
        XCTAssertEqual(covered[0]?.map(\.hidesSpoilers), [false], "specials are never covered")
    }

    func testEpisodeInProgressIsTheCurrentPosition() throws {
        let seasons = [try season(1), try season(2)]
        let pages = [
            1: [try episode(1, 1, played: true), try episode(1, 2), try episode(1, 3, played: true)],
            2: [try episode(2, 1, played: true), try episode(2, 2, inProgress: true), try episode(2, 3)],
        ]
        let position = EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
        XCTAssertEqual(position, Position(season: 2, episode: 2))

        let covered = EpisodeSpoilerPolicy.cover(pages, after: position)
        XCTAssertEqual(covered[1]?.map(\.hidesSpoilers), [false, false, false], "a skipped earlier episode is not future")
        XCTAssertEqual(covered[2]?.map(\.hidesSpoilers), [false, false, true])
    }

    func testWatchedCountsPlaceAnUnloadedSeason() throws {
        let seasons = [
            try season(1, episodeCount: 8, userData: #"{"played":false,"watchedCount":8,"unplayedCount":0}"#),
            try season(2, userData: #"{"played":false,"watchedCount":1,"unplayedCount":2}"#),
            try season(3),
        ]
        let pages = [
            2: [try episode(2, 1, played: true), try episode(2, 2), try episode(2, 3)],
            3: [try episode(3, 1)],
        ]
        let position = EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
        XCTAssertEqual(position, Position(season: 2, episode: 2))
        XCTAssertEqual(EpisodeSpoilerPolicy.cover(pages, after: position)[3]?.map(\.hidesSpoilers), [true])
    }

    func testUnloadedUnfinishedSeasonCoversEverythingAfterIt() throws {
        let seasons = [
            try season(1, userData: #"{"played":false,"watchedCount":1,"unplayedCount":2}"#),
            try season(3),
        ]
        let pages = [3: [try episode(3, 1), try episode(3, 2)]]
        let position = EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
        XCTAssertEqual(position, Position(season: 1, episode: 0))
        XCTAssertEqual(EpisodeSpoilerPolicy.cover(pages, after: position)[3]?.map(\.hidesSpoilers), [true, true])
    }

    func testSeasonWithoutUserDataIsSkippedWhileUnloaded() throws {
        // Emby sends no season counts, so a loaded later season decides from its own episodes.
        let seasons = [try season(1), try season(2), try season(3)]
        let pages = [3: [try episode(3, 1, played: true), try episode(3, 2), try episode(3, 3)]]
        let position = EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
        XCTAssertEqual(position, Position(season: 3, episode: 2))
        XCTAssertEqual(EpisodeSpoilerPolicy.cover(pages, after: position)[3]?.map(\.hidesSpoilers), [false, false, true])
    }

    func testFullyWatchedSeriesCoversNothing() throws {
        let seasons = [try season(1, userData: #"{"played":true}"#)]
        let page = [try episode(1, 1, played: true), try episode(1, 2, played: true)]
        XCTAssertNil(EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: [1: page]))
        XCTAssertEqual(EpisodeSpoilerPolicy.cover(page, after: nil).map(\.hidesSpoilers), [false, false])
    }

    func testCoveredCopyScramblesTextAndKeepsEverythingElse() throws {
        let original = try episode(1, 2)
        let covered = original.coveringSpoilers()
        XCTAssertTrue(covered.hidesSpoilers)
        XCTAssertFalse(original.hidesSpoilers)
        XCTAssertEqual(covered.contentId, original.contentId)
        XCTAssertEqual(covered.episodeNumber, original.episodeNumber)
        XCTAssertEqual(covered.userData, original.userData)
        XCTAssertEqual(covered.title, original.title, "the title stays readable")
        XCTAssertNotEqual(covered.overview, original.overview)
        XCTAssertEqual(
            covered.overview?.filter { !$0.isLetter && !$0.isNumber },
            original.overview?.filter { !$0.isLetter && !$0.isNumber },
            "spacing and punctuation keep their places"
        )
        XCTAssertEqual(original.coveringSpoilers(), covered, "the same episode scrambles the same way every time")
    }

    func testCoveredFlagIsNeverEncoded() throws {
        let covered = try episode(1, 2).coveringSpoilers()
        let decoded = try JSONDecoder().decode(EpisodeListItem.self, from: JSONEncoder().encode(covered))
        XCTAssertFalse(decoded.hidesSpoilers)
        XCTAssertEqual(decoded.overview, covered.overview)
    }

    func testScrambleKeepsShapeAndCase() {
        let text = "The One Where It Ends, 2024!"
        let scrambled = SpoilerText.scramble(text, seed: "s1e1")
        XCTAssertEqual(scrambled.count, text.count)
        XCTAssertEqual(scrambled.filter { $0 == " " }.count, 5)
        XCTAssertTrue(scrambled.hasSuffix("!"))
        XCTAssertTrue(scrambled.first?.isUppercase == true)
        XCTAssertNotEqual(scrambled, text)
        XCTAssertEqual(scrambled, SpoilerText.scramble(text, seed: "s1e1"))
        XCTAssertNotEqual(scrambled, SpoilerText.scramble(text, seed: "s1e2"))
    }
}
