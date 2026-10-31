import XCTest
@testable import Vivid

/// Release and air dates: a plain date is a calendar day and reads the same
/// day in every time zone; a date-time is shown in the device's time zone.
final class DetailDateTests: XCTestCase {
    private func formatter(_ style: DateFormatter.Style, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter
    }

    func testPlainDateKeepsItsDay() {
        // 1 May 2024, 00:00 GMT.
        let day = Date(timeIntervalSince1970: 1_714_521_600)
        XCTAssertEqual(DetailDateFormatting.longDate("2024-05-01"), formatter(.long, timeZone: .gmt).string(from: day))
        XCTAssertEqual(DetailDateFormatting.abbreviatedDate(" 2024-05-01 "), formatter(.medium, timeZone: .gmt).string(from: day))
    }

    func testDateTimeIsShownInTheDeviceTimeZone() {
        // 1 May 2024, 23:30 GMT.
        let moment = Date(timeIntervalSince1970: 1_714_606_200)
        XCTAssertEqual(DetailDateFormatting.longDate("2024-05-01T23:30:00Z"),
                       formatter(.long, timeZone: .current).string(from: moment))
    }

    func testUnreadableTextIsShownTrimmed() {
        XCTAssertEqual(DetailDateFormatting.longDate("  Spring 2024 "), "Spring 2024")
        XCTAssertNil(DetailDateFormatting.longDate("   "))
    }
}
