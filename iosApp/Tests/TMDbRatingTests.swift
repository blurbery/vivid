import XCTest
@testable import Vivid

final class TMDbRatingTests: XCTestCase {
    func testDisplayRatingRoundsToOneDecimalAndHidesUnratedTitles() {
        XCTAssertEqual(TVTMDbStore.displayRating(average: 8.26, count: 1_200), 8.3)
        XCTAssertEqual(TVTMDbStore.displayRating(average: 7.95, count: 3), 8.0)
        XCTAssertNil(TVTMDbStore.displayRating(average: 0, count: 0), "TMDb reports 0 for titles nobody has rated")
        XCTAssertNil(TVTMDbStore.displayRating(average: 8.0, count: 0))
        XCTAssertNil(TVTMDbStore.displayRating(average: nil, count: 10))
        XCTAssertNil(TVTMDbStore.displayRating(average: 8.0, count: nil))
    }

    func testBadgeLabelKeepsOneDecimal() {
        XCTAssertEqual(TMDbRatingBadge.label(for: 8.3), "8.3")
        XCTAssertEqual(TMDbRatingBadge.label(for: 10), "10.0")
    }
}
