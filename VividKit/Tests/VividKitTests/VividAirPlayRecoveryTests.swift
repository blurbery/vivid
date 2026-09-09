import XCTest
@testable import VividKit

final class VividAirPlayRecoveryTests: XCTestCase {
    func testFlushDuringRecoveryIsRetainedAndConsumedOnce() {
        var recovery = VividAirPlayRecovery()
        XCTAssertFalse(recovery.takeFlush())
        recovery.recordFlush()
        recovery.recordFlush()
        XCTAssertTrue(recovery.pendingFlush)
        XCTAssertTrue(recovery.takeFlush())
        XCTAssertFalse(recovery.takeFlush())
        recovery.recordFlush()
        XCTAssertTrue(recovery.takeFlush())
    }

    func testMovingClockCannotHideStalledAudio() {
        for clock in [0.63, 3.7, 10, 39.8] {
            XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 3.264, end: 3.264,
                clock: clock, finished: false))
        }
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 3.264, end: 4,
            clock: 10, finished: false))
        XCTAssertTrue(VividAirPlayRecovery.audioAdvanced(from: 3.264, end: 4,
            clock: 3.7, finished: false))
    }

    func testInvalidProgressAndFinishedAudio() {
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 0, end: nil, clock: 1, finished: false))
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 0, end: .nan, clock: 1, finished: false))
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 0, end: 3, clock: .nan, finished: false))
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: nil, end: 3, clock: 1, finished: false))
        XCTAssertTrue(VividAirPlayRecovery.audioAdvanced(from: 3, end: 3, clock: 2, finished: true))
        XCTAssertFalse(VividAirPlayRecovery.audioAdvanced(from: 3, end: 3, clock: 4, finished: true))
    }

    func testRepeatedFlushesRemainBoundedAndNewStateHasNoPendingWork() {
        var recovery = VividAirPlayRecovery()
        var budget = VividAudioRecoveryBudget()
        XCTAssertTrue(budget.consume(at: 0))
        for second in 1...2 {
            recovery.recordFlush()
            XCTAssertTrue(recovery.takeFlush())
            XCTAssertTrue(budget.consume(at: Double(second)))
        }
        recovery.recordFlush()
        XCTAssertTrue(recovery.takeFlush())
        XCTAssertFalse(budget.consume(at: 3))
        recovery.recordFlush()
        recovery = VividAirPlayRecovery()
        XCTAssertFalse(recovery.takeFlush())
    }
}
