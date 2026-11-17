import XCTest
@testable import Vivid

@MainActor
final class MediaRuntimeStatusOverlayTests: XCTestCase {
    func testEpisodesAlwaysUseRuntimeStatus() {
        XCTAssertTrue(MediaRuntimeStatusOverlay.applies(toType: "Episode", inContinueWatching: false))
        XCTAssertTrue(MediaRuntimeStatusOverlay.applies(toType: "episode", inContinueWatching: true))
    }

    func testMoviesUseRuntimeStatusOnlyInContinueWatching() {
        XCTAssertTrue(MediaRuntimeStatusOverlay.applies(toType: "Movie", inContinueWatching: true))
        XCTAssertFalse(MediaRuntimeStatusOverlay.applies(toType: "movie", inContinueWatching: false))
    }

    func testOtherTypesKeepTheirExistingBadges() {
        XCTAssertFalse(MediaRuntimeStatusOverlay.applies(toType: "series", inContinueWatching: true))
        XCTAssertFalse(MediaRuntimeStatusOverlay.applies(toType: "video", inContinueWatching: true))
    }

    // MARK: Time pill

    private typealias TimePill = MediaRuntimeStatusOverlay.TimePill

    private func timePill(
        isPlayed: Bool = false,
        progress: Double? = nil,
        duration: Double? = nil,
        runtimeMinutes: Int? = nil
    ) -> TimePill? {
        MediaRuntimeStatusOverlay.timePill(
            isPlayed: isPlayed,
            progress: progress,
            duration: duration,
            runtimeMinutes: runtimeMinutes
        )
    }

    func testAnUnstartedTitleShowsItsFullRuntime() {
        XCTAssertEqual(timePill(runtimeMinutes: 47), TimePill(showsTick: false, minutes: 47))
        XCTAssertEqual(timePill(progress: 0, duration: 2820), TimePill(showsTick: false, minutes: 47))
    }

    func testAPartWatchedTitleShowsTheMinutesLeftRoundedAsTheResumeButtonRoundsThem() {
        XCTAssertEqual(
            timePill(progress: 0.5, duration: 2820, runtimeMinutes: 47),
            TimePill(showsTick: false, minutes: 24)
        )
        XCTAssertEqual(
            timePill(progress: 0.5, duration: 2820, runtimeMinutes: 47)?.minutes,
            ResumePresentation(position: 1410, duration: 2820)?.minutesRemaining
        )
        // Without a duration the runtime stands in for it.
        XCTAssertEqual(timePill(progress: 0.5, runtimeMinutes: 40), TimePill(showsTick: false, minutes: 20))
    }

    func testAWatchedTitleShowsTheTickAlone() {
        XCTAssertEqual(timePill(isPlayed: true, runtimeMinutes: 47), TimePill(showsTick: true, minutes: nil))
        XCTAssertEqual(
            timePill(isPlayed: true, progress: 1, duration: 2820, runtimeMinutes: 47),
            TimePill(showsTick: true, minutes: nil)
        )
        XCTAssertEqual(timePill(isPlayed: true), TimePill(showsTick: true, minutes: nil))
    }

    func testARewatchShowsItsMinutesLeftInsteadOfTheTick() {
        XCTAssertEqual(
            timePill(isPlayed: true, progress: 0.5, duration: 2820, runtimeMinutes: 47),
            TimePill(showsTick: false, minutes: 24)
        )
    }

    func testMinutesLeftMatchTheResumeButtonOnWholeMinutes() {
        XCTAssertEqual(
            timePill(progress: 900.0 / 1320.0, duration: 1320)?.minutes,
            ResumePresentation(position: 900, duration: 1320)?.minutesRemaining
        )
    }

    func testNothingKnownShowsNoTimePill() {
        XCTAssertNil(timePill())
        XCTAssertNil(timePill(progress: 0.5))
    }

    // MARK: Home caption line

    private func items() throws -> [SectionItem] {
        try JSONDecoder().decode([SectionItem].self, from: Data(#"""
        [
          {"contentId":"fixture-episode","type":"episode","title":"Another chapter","seriesTitle":"A sample series","seasonNumber":1,"episodeNumber":7},
          {"contentId":"fixture-untitled","type":"Episode","title":"A sample series","seriesTitle":"A sample series","seasonNumber":10,"episodeNumber":24},
          {"contentId":"fixture-unnumbered","type":"episode","title":"A lost chapter","seriesTitle":"A sample series","seasonNumber":2},
          {"contentId":"fixture-movie","type":"movie","title":"A sample movie","year":2026}
        ]
        """#.utf8))
    }

    func testTheLineUnderAStatusRowCardIsTheUnpaddedNumbersThenTheTitle() throws {
        let items = try items()
        XCTAssertEqual(EpisodeCardCaption.statusCardLine(for: items[0]), "S1 E7 \u{00B7} Another chapter")
        // No title of its own: the numbers alone.
        XCTAssertEqual(EpisodeCardCaption.statusCardLine(for: items[1]), "S10 E24")
        // A missing number leaves the other.
        XCTAssertEqual(EpisodeCardCaption.statusCardLine(for: items[2]), "S2 \u{00B7} A lost chapter")
        XCTAssertNil(EpisodeCardCaption.statusCardLine(for: items[3]))
        // Poster captions keep the zero-padded code.
        XCTAssertEqual(EpisodeCardCaption.line(for: items[0]), "S01E07 \u{00B7} Another chapter")
    }
}
