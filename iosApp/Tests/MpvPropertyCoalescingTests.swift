import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

@MainActor
final class MpvPropertyCoalescingTests: XCTestCase {
    private final class Recorder: MpvPlayerDelegate {
        var deliveries: [String] = []
        func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
            deliveries.append("\(name)=\(value.map { "\($0)" } ?? "nil")")
        }
        func onEvent(name: String, data: [String: Any]?) {
            deliveries.append("event:\(name)")
        }
    }

    private let mpvQueue = DispatchQueue(label: "MpvPropertyCoalescingTests")

    private func drainMain() async {
        // Each dispatch posts to main from `mpvQueue`; yielding twice lets
        // every queued block and anything it enqueues run.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testBusyMainReceivesOnlyLatestTimeInMpvOrder() async {
        let core = MpvPlayerCoreBase()
        let recorder = Recorder()
        core.delegate = recorder

        // Main is busy in this test, so these all queue before delivery.
        mpvQueue.sync {
            core.dispatchDelegateProperty(name: "time-pos", value: 1.0, sourceId: nil)
            core.dispatchDelegateProperty(name: "avsync", value: 0.01, sourceId: nil)
            core.dispatchDelegateProperty(name: "time-pos", value: 2.0, sourceId: nil)
            core.dispatchDelegateProperty(name: "pause", value: true, sourceId: nil)
            core.dispatchDelegateProperty(name: "time-pos", value: 3.0, sourceId: nil)
            core.dispatchDelegateEvent(name: "seek", data: nil)
            core.dispatchDelegateProperty(name: "time-pos", value: 4.0, sourceId: nil)
            core.dispatchDelegateProperty(name: "time-pos", value: 5.0, sourceId: nil)
        }
        await drainMain()

        XCTAssertEqual(recorder.deliveries, [
            "time-pos=2.0", "avsync=0.01", "pause=true",
            "time-pos=3.0", "event:seek",
            "time-pos=5.0",
        ])
    }

    func testIdleMainStillReceivesEveryTimeUpdate() async {
        let core = MpvPlayerCoreBase()
        let recorder = Recorder()
        core.delegate = recorder

        for time in [1.0, 2.0, 3.0] {
            mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: time, sourceId: nil) }
            await drainMain()
        }

        XCTAssertEqual(recorder.deliveries, ["time-pos=1.0", "time-pos=2.0", "time-pos=3.0"])
    }

    func testTerminalCoreDropsPendingValues() async {
        let core = MpvPlayerCoreBase()
        let recorder = Recorder()
        core.delegate = recorder

        mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: 1.0, sourceId: nil) }
        core.beginDisposal()
        await drainMain()

        XCTAssertTrue(recorder.deliveries.isEmpty)
    }
}
