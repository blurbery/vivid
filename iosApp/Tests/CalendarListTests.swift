import XCTest
@testable import Vivid

/// Upcoming is rebuilt on every visit from the profile's series as they are
/// now and the air dates saved for them, so Watchlist changes show at once.
final class CalendarListTests: XCTestCase {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var window: DateInterval {
        DateInterval(start: today, end: day(CalendarStore.upcomingDays))
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    private func saved(
        _ contentId: String, show: String? = nil, days: [Int], refreshAfter: Date = .distantFuture
    ) -> CalendarStore.SavedSeries {
        CalendarStore.SavedSeries(
            show: show ?? "tvdb:\(contentId)", seriesContentId: contentId, title: contentId,
            posterUrl: nil, posterThumbhash: nil,
            episodes: days.enumerated().map {
                .init(season: 1, number: $0.offset + 1, name: nil, day: day($0.element), airsAt: nil)
            },
            refreshAfter: refreshAfter
        )
    }

    private func candidate(_ contentId: String, _ source: UpcomingEpisode.Source) -> CalendarStore.Candidate {
        CalendarStore.Candidate(contentId: contentId, source: source)
    }

    func testSeriesTakenOffTheWatchlistDropsOutAtOnce() {
        let series = ["a": saved("a", days: [1]), "b": saved("b", days: [2])]
        let before = CalendarStore.upcoming(
            for: [candidate("a", .watchlist), candidate("b", .watchlist)], saved: series, window: window
        )
        XCTAssertEqual(Set(before.map(\.seriesContentId)), ["a", "b"])

        let after = CalendarStore.upcoming(for: [candidate("b", .watchlist)], saved: series, window: window)
        XCTAssertEqual(after.map(\.seriesContentId), ["b"])
    }

    func testNewAndDueSeriesAreLookedUpAndOthersAreNot() {
        let now = Date()
        let series = [
            "fresh": saved("fresh", days: [1], refreshAfter: now.addingTimeInterval(60)),
            "due": saved("due", days: [1], refreshAfter: now.addingTimeInterval(-60)),
        ]
        let candidates = [candidate("fresh", .history), candidate("due", .history), candidate("new", .watchlist)]

        let due = CalendarStore.seriesToLookUp(candidates, saved: series, now: now, force: false)
        XCTAssertEqual(due.map(\.contentId), ["due", "new"])
        let forced = CalendarStore.seriesToLookUp(candidates, saved: series, now: now, force: true)
        XCTAssertEqual(forced.map(\.contentId), ["fresh", "due", "new"])
    }

    /// A series still shows from what's saved while it's looked up again.
    func testDueSeriesStillShows() {
        let series = ["a": saved("a", days: [3], refreshAfter: .distantPast)]
        let list = CalendarStore.upcoming(for: [candidate("a", .history)], saved: series, window: window)
        XCTAssertEqual(list.count, 1)
    }

    /// A series added to the Watchlist from history shows as Watchlist.
    func testSourceFollowsTheCurrentList() {
        let series = ["a": saved("a", days: [1])]
        let list = CalendarStore.upcoming(for: [candidate("a", .watchlist)], saved: series, window: window)
        XCTAssertEqual(list.first?.source, .watchlist)
    }

    /// Saved episodes that have aired drop off, and the next ones take
    /// their place up to the cap.
    func testAiredEpisodesDropAndEachSeriesShowsAtMostSix() {
        let series = ["a": saved("a", days: [-2, -1, 0, 1, 2, 3, 4, 5, 6, 7])]
        let list = CalendarStore.upcoming(for: [candidate("a", .continueWatching)], saved: series, window: window)
        XCTAssertEqual(list.count, CalendarStore.maxEpisodesPerSeries)
        XCTAssertEqual(list.first?.day, today)
        XCTAssertEqual(list.last?.day, day(5))
    }

    func testShowInTwoLibrariesIsListedOnceFromTheMostPersonalSource() {
        let series = [
            "movies-library": saved("movies-library", show: "tvdb:1", days: [1]),
            "tv-library": saved("tv-library", show: "tvdb:1", days: [1]),
        ]
        let list = CalendarStore.upcoming(
            for: [candidate("tv-library", .continueWatching), candidate("movies-library", .history)],
            saved: series, window: window
        )
        XCTAssertEqual(list.map(\.seriesContentId), ["tv-library"])
        XCTAssertEqual(list.first?.source, .continueWatching)
    }
}
