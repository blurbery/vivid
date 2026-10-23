import XCTest
@testable import Vivid

/// The Calendar shows every air time and day in the device's own time zone.
final class CalendarDateTests: XCTestCase {
    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    /// A 9 pm US Eastern episode is the next lunchtime in Sydney and stays the
    /// same evening in New York.
    func testTimedEpisodeUsesTheLocalDayAndTime() throws {
        let stamp = "2026-10-30T01:00:00+00:00"
        let sydney = try calendar("Australia/Sydney")
        let here = try XCTUnwrap(CalendarStore.airing(airdate: "2026-10-29", airtime: "21:00", airstamp: stamp, calendar: sydney))
        XCTAssertEqual(sydney.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(here.time)),
                       DateComponents(year: 2026, month: 10, day: 30, hour: 12))
        XCTAssertEqual(sydney.dateComponents([.year, .month, .day, .hour], from: here.day),
                       DateComponents(year: 2026, month: 10, day: 30, hour: 0))

        let newYork = try calendar("America/New_York")
        let there = try XCTUnwrap(CalendarStore.airing(airdate: "2026-10-29", airtime: "21:00", airstamp: stamp, calendar: newYork))
        XCTAssertEqual(newYork.dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(there.time)),
                       DateComponents(year: 2026, month: 10, day: 29, hour: 21))
        XCTAssertEqual(newYork.dateComponents([.day], from: there.day), DateComponents(day: 29))
    }

    /// TVmaze gives a streaming drop a placeholder time. The listed day stands,
    /// with no time, wherever the device is.
    func testStreamingDropKeepsItsListedDayWithoutATime() throws {
        for zone in ["Australia/Sydney", "America/Los_Angeles", "UTC"] {
            let calendar = try calendar(zone)
            let airing = try XCTUnwrap(CalendarStore.airing(
                airdate: "2026-10-30", airtime: "", airstamp: "2026-10-30T12:00:00+00:00", calendar: calendar
            ))
            XCTAssertNil(airing.time, zone)
            XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: airing.day),
                           DateComponents(year: 2026, month: 10, day: 30), zone)
        }
    }

    /// TMDb's date-only air dates never move to the day before in a time zone
    /// behind UTC.
    func testDateOnlyDayNeverShifts() throws {
        let losAngeles = try calendar("America/Los_Angeles")
        let day = try XCTUnwrap(CalendarStore.localDay("2026-11-01", calendar: losAngeles))
        XCTAssertEqual(losAngeles.dateComponents([.year, .month, .day, .hour], from: day),
                       DateComponents(year: 2026, month: 11, day: 1, hour: 0))
        XCTAssertNil(CalendarStore.localDay("soon"))
        XCTAssertNil(CalendarStore.localDay(nil))
    }
}
