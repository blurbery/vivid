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
}
