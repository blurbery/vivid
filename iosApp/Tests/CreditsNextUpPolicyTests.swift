import XCTest
@testable import Vivid

final class CreditsNextUpPolicyTests: XCTestCase {
    private let duration: Double = 1_800

    func testCreditsRunningToTheEndOpenNextUp() {
        XCTAssertEqual(range(start: 1_500, end: 1_800)?.start, 1_500)
        // A marker that stops a few seconds short still runs to the end.
        XCTAssertEqual(range(start: 1_500, end: 1_791)?.start, 1_500)
    }

    func testCreditsWithASceneAfterThemKeepSkipCredits() {
        XCTAssertNil(range(start: 1_500, end: 1_700))
    }

    func testNeedsANextEpisodeAndAMarker() {
        XCTAssertNil(range(start: 1_500, end: 1_800, hasNextEpisode: false))
        XCTAssertNil(CreditsNextUpPolicy.range(credits: nil, duration: duration, hasNextEpisode: true))
    }

    func testAMarkerInTheFirstHalfIsIgnored() {
        XCTAssertNil(range(start: 600, end: 1_800))
    }

    func testUnknownDurationOpensNothing() {
        let credits = TimeRange(start: 1_500, end: 1_800)
        XCTAssertNil(CreditsNextUpPolicy.range(credits: credits, duration: 0, hasNextEpisode: true))
        XCTAssertNil(CreditsNextUpPolicy.range(credits: credits, duration: .nan, hasNextEpisode: true))
    }

    private func range(start: Double, end: Double, hasNextEpisode: Bool = true) -> TimeRange? {
        CreditsNextUpPolicy.range(
            credits: TimeRange(start: start, end: end),
            duration: duration,
            hasNextEpisode: hasNextEpisode
        )
    }
}
