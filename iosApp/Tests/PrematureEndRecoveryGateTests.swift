import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class PrematureEndRecoveryGateTests: XCTestCase {
    private func play(_ gate: inout VividPrematureEndRecoveryGate, from start: Double, seconds: Int,
                      playing: Bool = true, uptime: inout Double) {
        for step in 0...seconds {
            gate.observe(position: start + Double(step), uptime: uptime, playing: playing, rate: 1)
            uptime += 1
        }
    }

    func testFirstEarlyEndAlwaysReopens() {
        var gate = VividPrematureEndRecoveryGate()
        XCTAssertTrue(gate.begin())
    }

    func testTruncatedSourceFallsThroughOnTheNextEnd() {
        var gate = VividPrematureEndRecoveryGate()
        var uptime = 100.0
        XCTAssertTrue(gate.begin())
        // The reopened stream ends again after a few seconds of playback.
        play(&gate, from: 1200, seconds: 5, uptime: &uptime)
        XCTAssertFalse(gate.begin())
    }

    func testLongFilmRecoversEachTokenExpiry() {
        var gate = VividPrematureEndRecoveryGate()
        var uptime = 100.0
        for hour in 0..<3 {
            XCTAssertTrue(gate.begin(), "expiry \(hour)")
            play(&gate, from: Double(hour * 3600), seconds: 45, uptime: &uptime)
        }
    }

    func testPausedOrSeekingTimeDoesNotCount() {
        var gate = VividPrematureEndRecoveryGate()
        var uptime = 100.0
        XCTAssertTrue(gate.begin())
        play(&gate, from: 500, seconds: 120, playing: false, uptime: &uptime)
        // A backward seek leaves the position behind the previous sample.
        gate.observe(position: 600, uptime: uptime, playing: true, rate: 1)
        gate.observe(position: 100, uptime: uptime + 1, playing: true, rate: 1)
        XCTAssertFalse(gate.begin())
        XCTAssertEqual(gate.playedSinceAttempt, 0)
    }
}
