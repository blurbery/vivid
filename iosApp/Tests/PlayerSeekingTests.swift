import XCTest
@testable import Vivid

/// Scrubbing on iPhone and iPad.
@MainActor
final class PlayerSeekingTests: XCTestCase {
    private func finish(_ model: PlayerViewModel) async {
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    /// The item ending while a finger is still on the timeline used to leave
    /// the scrub running until the next load, with its preview reader open.
    func testTheItemEndingMidScrubStillEndsTheScrub() async {
        let model = PlayerViewModel()
        model.duration = 600
        model.currentTime = 595
        model.beginScrub(fraction: 0.5)
        XCTAssertTrue(model.isScrubbing)

        model.hasReachedEndOfFile = true
        model.endScrub()
        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(model.scrubPreviewTime, 595)
        await finish(model)
    }

    /// A scrub that ends normally seeks to where it was let go.
    func testEndingAScrubSeeksToThePreview() async {
        let model = PlayerViewModel()
        model.duration = 600
        model.beginScrub(fraction: 0.25)
        model.endScrub()
        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(model.currentTime, 150)
        XCTAssertEqual(model.seekTargetTime, 150)
        await finish(model)
    }
}
