import XCTest
@testable import Vivid

/// Release and air dates read as the calendar day the server wrote, in every
/// time zone, whether it sent a plain date or a date-time.
final class DetailDateTests: XCTestCase {
    private func formatter(_ style: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .gmt
        formatter.dateStyle = style
        formatter.timeStyle = .none
        return formatter
    }

    func testPlainDateKeepsItsDay() {
        // 1 May 2024, 00:00 GMT.
        let day = Date(timeIntervalSince1970: 1_714_521_600)
        XCTAssertEqual(DetailDateFormatting.longDate("2024-05-01"), formatter(.long).string(from: day))
        XCTAssertEqual(DetailDateFormatting.abbreviatedDate(" 2024-05-01 "), formatter(.medium).string(from: day))
    }

    func testDateTimeKeepsItsWrittenDay() {
        // 1 May 2024, 00:00 GMT.
        let day = Date(timeIntervalSince1970: 1_714_521_600)
        XCTAssertEqual(DetailDateFormatting.longDate("2024-05-01T23:30:00Z"), formatter(.long).string(from: day))
        XCTAssertEqual(DetailDateFormatting.longDate("2024-05-01T00:00:00.0000000Z"), formatter(.long).string(from: day))
    }

    func testUnreadableTextIsShownTrimmed() {
        XCTAssertEqual(DetailDateFormatting.longDate("  Spring 2024 "), "Spring 2024")
        XCTAssertNil(DetailDateFormatting.longDate("   "))
    }
}
