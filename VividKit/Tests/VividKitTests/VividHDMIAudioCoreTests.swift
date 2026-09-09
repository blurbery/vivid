import XCTest
@testable import VividKit

final class VividHDMIAudioCoreTests: XCTestCase {
    func testFullOverdueQueueRecoversPromptlyButNotOnOneLatePoll() {
        var core = VividHDMIAudioCore()
        XCTAssertEqual(core.observe(clock: 4.8, audioEnd: 4.64, ready: false,
            uptime: 0, eligible: true, sufficient: true), .none)
        XCTAssertEqual(core.observe(clock: 4.9, audioEnd: 4.64, ready: false,
            uptime: 0.1, eligible: true, sufficient: true), .none)
        XCTAssertEqual(core.observe(clock: 5.3, audioEnd: 4.64, ready: false,
            uptime: 0.5, eligible: true, sufficient: true), .none)
        XCTAssertEqual(core.observe(clock: 5.5, audioEnd: 4.64, ready: false,
            uptime: 0.7, eligible: true, sufficient: true), .flushAudio)
        XCTAssertEqual(core.observe(clock: 5.6, audioEnd: 6, ready: true,
            uptime: 0.8, eligible: true, sufficient: true), .recovered)
        for second in 1...6 {
            XCTAssertEqual(core.observe(clock: Double(second) + 6, audioEnd: 6,
                ready: false, uptime: Double(second), eligible: true, sufficient: true), .none)
        }
        XCTAssertEqual(core.observe(clock: 13, audioEnd: 6, ready: false,
            uptime: 7, eligible: true, sufficient: true), .failed)
    }

    func testProgressOrReadinessCancelsFastStallDetection() {
        for ready in [true, false] {
            var core = VividHDMIAudioCore()
            _ = core.observe(clock: 10, audioEnd: 6, ready: false,
                uptime: 0, eligible: true, sufficient: true)
            _ = core.observe(clock: 10.1, audioEnd: 6, ready: false,
                uptime: 0.1, eligible: true, sufficient: true)
            XCTAssertEqual(core.observe(clock: 10.5, audioEnd: ready ? 6 : 6.1, ready: ready,
                uptime: 0.5, eligible: true, sufficient: true), .none)
            XCTAssertEqual(core.observe(clock: 10.8, audioEnd: ready ? 6 : 6.1, ready: false,
                uptime: 0.8, eligible: true, sufficient: true), .none)
        }
    }

    func testCatchUpFollowsClockOnlyAfterHDMIReset() {
        XCTAssertNil(VividHDMIAudioCore.catchUpFloor(recoveryFloor: nil, clock: 12))
        XCTAssertEqual(VividHDMIAudioCore.catchUpFloor(recoveryFloor: 10, clock: 10.3), 10.3)
        XCTAssertEqual(VividHDMIAudioCore.catchUpFloor(recoveryFloor: 10, clock: 9), 10)
        XCTAssertNil(VividHDMIAudioCore.catchUpFloor(recoveryFloor: 10, clock: .nan))
        XCTAssertNil(VividHDMIAudioCore.catchUpFloor(recoveryFloor: .infinity, clock: 10))
    }

    func testRouteExcludesHomePodsAndMixedRoutes() {
        XCTAssertTrue(VividHDMIAudioCore.accepts(routeTypes: ["HDMIOutput"]))
        for routes in [[], ["AirPlay"], ["HDMIOutput", "AirPlay"], ["BuiltInSpeaker"]] {
            XCTAssertFalse(VividHDMIAudioCore.accepts(routeTypes: routes))
        }
    }

    func testHealthyPlaybackAndStationaryClockNeverFlush() {
        var core = VividHDMIAudioCore()
        for second in 0..<60 {
            XCTAssertEqual(core.observe(clock: Double(second), audioEnd: Double(second) + 1,
                ready: false, uptime: Double(second), eligible: true, sufficient: true), .none)
        }
        for second in 60..<90 {
            XCTAssertEqual(core.observe(clock: 60, audioEnd: 6,
                ready: false, uptime: Double(second), eligible: true, sufficient: true), .none)
        }
    }

    func testStalledAudioFlushesOnceAndClockAloneCannotConfirmRecovery() {
        var core = VividHDMIAudioCore()
        for second in 0..<7 {
            XCTAssertEqual(core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true), .none)
        }
        XCTAssertEqual(core.observe(clock: 17, audioEnd: 6.6, ready: false, uptime: 7, eligible: true), .flushAudio)
        XCTAssertEqual(core.observe(clock: 22, audioEnd: 6.6, ready: false, uptime: 12, eligible: true), .none)
        XCTAssertEqual(core.observe(clock: 23, audioEnd: 6.6, ready: false, uptime: 13, eligible: true), .failed)
        for second in 14..<40 {
            XCTAssertEqual(core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true), .none)
        }
    }

    func testRecoveryRequiresAudioToCatchUpAndSuspensionCancelsPendingWork() {
        var core = VividHDMIAudioCore()
        for second in 0...7 {
            _ = core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true)
        }
        XCTAssertEqual(core.observe(clock: 18, audioEnd: 7, ready: true, uptime: 8, eligible: true), .none)
        XCTAssertEqual(core.observe(clock: 19, audioEnd: 19.5, ready: true, uptime: 9, eligible: true), .recovered)
        core.suspend()
        var failures = 0
        for second in 10..<40 {
            let action = core.observe(clock: Double(second) + 10, audioEnd: 19.5,
                ready: false, uptime: Double(second), eligible: true)
            XCTAssertTrue(action == .none || action == .failed)
            if action == .failed { failures += 1 }
        }
        XCTAssertEqual(failures, 1)
        core = VividHDMIAudioCore()
        for second in 0...7 {
            _ = core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true)
        }
        XCTAssertEqual(core.observe(clock: 18, audioEnd: 6.6, ready: false, uptime: 8, eligible: false), .none)
        XCTAssertEqual(core.observe(clock: 30, audioEnd: 6.6, ready: false, uptime: 20, eligible: true), .none)
    }

    func testTemporaryBufferingPreservesRecoveryConfirmation() {
        var core = VividHDMIAudioCore()
        for second in 0...7 {
            _ = core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true)
        }
        XCTAssertTrue(core.isRecovering)
        XCTAssertEqual(core.observe(clock: 17, audioEnd: 6.6, ready: true,
            uptime: 7.05, eligible: true, buffering: true), .none)
        XCTAssertTrue(core.isRecovering)
        XCTAssertEqual(core.observe(clock: 17, audioEnd: 17.5, ready: true,
            uptime: 7.5, eligible: true, buffering: true), .recovered)
        XCTAssertFalse(core.isRecovering)
    }

    func testBufferingCannotExtendRecoveryDeadlineOrStartRecovery() {
        var core = VividHDMIAudioCore()
        for second in 0..<20 {
            XCTAssertEqual(core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true, buffering: true), .none)
        }
        for second in 20...27 {
            _ = core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true)
        }
        XCTAssertTrue(core.isRecovering)
        XCTAssertEqual(core.observe(clock: 37, audioEnd: 6.6, ready: true,
            uptime: 33, eligible: true, buffering: true), .failed)
        XCTAssertFalse(core.isRecovering)
    }

    func testSecondStallFailsWithoutAnotherFlush() {
        var core = VividHDMIAudioCore()
        for second in 0...7 {
            _ = core.observe(clock: Double(second) + 10, audioEnd: 6.6,
                ready: false, uptime: Double(second), eligible: true)
        }
        XCTAssertEqual(core.observe(clock: 18, audioEnd: 18.5, ready: true,
            uptime: 8, eligible: true), .recovered)
        for second in 9...14 {
            XCTAssertEqual(core.observe(clock: Double(second) + 10, audioEnd: 18.5,
                ready: false, uptime: Double(second), eligible: true), .none)
        }
        XCTAssertEqual(core.observe(clock: 25, audioEnd: 18.5, ready: false,
            uptime: 15, eligible: true), .failed)
        XCTAssertEqual(core.observe(clock: 40, audioEnd: 18.5, ready: false,
            uptime: 30, eligible: true), .none)
    }
}
