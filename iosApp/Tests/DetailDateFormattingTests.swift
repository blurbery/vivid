import XCTest
@testable import Vivid

final class DetailDateFormattingTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!

    private func day(_ raw: String, in timeZone: TimeZone) -> String? {
        guard let components = DetailDateFormatting.calendarDay(raw, timeZone: timeZone),
              let year = components.year, let month = components.month, let day = components.day
        else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func testMidnightDatesKeepTheirDayInEveryTimeZone() {
        // Jellyfin and Emby movies and series, Remux, Silo, and an explicit offset.
        for raw in ["2010-05-20T00:00:00.0000000Z", "2010-05-20T00:00:00Z", "2010-05-20", "2010-05-20T00:00:00+10:00"] {
            XCTAssertEqual(day(raw, in: newYork), "2010-05-20", raw)
            XCTAssertEqual(day(raw, in: sydney), "2010-05-20", raw)
        }
    }

    func testJellyfinEpisodeFromLocalServerTakesTheViewersDay() {
        // Jellyfin's TMDB episode provider sends the server's local midnight in UTC.
        XCTAssertEqual(day("2024-03-04T13:00:00.0000000Z", in: sydney), "2024-03-05")
        XCTAssertEqual(day("2024-03-05T05:00:00.0000000Z", in: newYork), "2024-03-05")
    }

    func testOtherValuesKeepTheirLeadingDayOrFallBack() {
        XCTAssertEqual(day("2024-03-05T10:20:30.123", in: newYork), "2024-03-05")
        XCTAssertNil(day("2024-02-31", in: newYork))
        XCTAssertNil(day("soon", in: newYork))
        XCTAssertEqual(DetailDateFormatting.longDate("soon"), "soon")
    }

    func testLongDateShowsTheDayTheServerNamed() {
        let expected = DateFormatter()
        expected.dateStyle = .long
        expected.timeStyle = .none
        expected.timeZone = TimeZone(secondsFromGMT: 0)
        let date = Date(timeIntervalSince1970: 1_274_313_600) // 2010-05-20T00:00:00Z
        XCTAssertEqual(DetailDateFormatting.longDate("2010-05-20T00:00:00.0000000Z"), expected.string(from: date))
    }

    func testAirDateArrivesOnTheViewersDay() {
        // 9am on 5 March in Sydney is still 4 March in New York.
        let now = Date(timeIntervalSince1970: 1_709_589_600) // 2024-03-04T22:00:00Z
        XCTAssertEqual(DetailDateFormatting.dayHasArrived("2024-03-05T00:00:00.0000000Z", now: now, timeZone: sydney), true)
        XCTAssertEqual(DetailDateFormatting.dayHasArrived("2024-03-05T00:00:00.0000000Z", now: now, timeZone: newYork), false)
        XCTAssertNil(DetailDateFormatting.dayHasArrived("TBA", now: now, timeZone: newYork))
    }
}
