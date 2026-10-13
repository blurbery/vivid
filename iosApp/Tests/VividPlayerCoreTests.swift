// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import AVFoundation
import UIKit
import XCTest
#if os(tvOS)
import AVKit
@testable import VividTV
#else
@testable import Vivid
#endif

/// Records deliveries in the order main receives them.
private final class CoreRecorder: VividPlayerCoreDelegate {
    var log: [String] = []
    var properties: [(name: String, value: Any?, sourceId: Int64?)] = []
    var events: [(name: String, data: [String: Any]?)] = []

    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        properties.append((name, value, sourceId))
        log.append("\(name)=\(value.map { "\($0)" } ?? "nil")")
    }

    func onEvent(name: String, data: [String: Any]?) {
        events.append((name, data))
        log.append("event:\(name)")
    }
}

/// A core whose mpv context is replaced, so the surface, lifecycle and
/// request paths run without libmpv. It records the bridge's own writes.
private final class StubCore: VividPlayerCore {
    var startsContext = true
    var startedWids: [Int64] = []
    var layerWasMountedAtStart = false
    var createdLayer: VividSampleBufferLayer?
    weak var expectedHost: UIView?
    var actions: [String] = []

    override func startContext(wid: Int64) -> Bool {
        startedWids.append(wid)
        createdLayer = sampleBufferDisplayLayer
        if let layer = sampleBufferDisplayLayer, let host = expectedHost {
            layerWasMountedAtStart = layer.superlayer?.superlayer === host.layer
                && host.subviews.first?.layer === layer.superlayer
        }
        return startsContext
    }

    override func setProperty(_ name: String, value: String) {
        actions.append("set \(name)=\(value)")
        super.setProperty(name, value: value)
    }

    override func command(_ args: [String]) {
        actions.append("command " + args.joined(separator: " "))
        super.command(args)
    }
}

/// Sections 4, 6.10 to 6.13, 6.17, 6.18, 7, 9 and 10.2 of the player bridge
/// specification, exercised on the new types without an mpv context.
@MainActor
final class VividPlayerCoreTests: XCTestCase {
    private let mpvQueue = DispatchQueue(label: "VividPlayerCoreTests")

    /// One main hop: every block queued before this call runs first.
    private func drainMainOnce() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func drainMain() async {
        for _ in 0..<2 { await drainMainOnce() }
    }

    private func makeHost(attachToScene: Bool = false, sibling: Bool = false) -> (window: UIWindow, host: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        if attachToScene {
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        }
        let host = UIView(frame: window.bounds)
        host.backgroundColor = .black
        if sibling { host.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))) }
        window.addSubview(host)
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        return (window, host)
    }

    private func address(of layer: CALayer) -> Int64 {
        Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
    }

    private func notAvailableText() -> String? { VividPlayerCoreError.notAvailable.errorDescription }

    private func disposedText() -> String? { VividPlayerCoreError.disposed.errorDescription }

    // MARK: Construction

    func testBareBaseIsCheapOnABackgroundThread() {
        let finished = expectation(description: "background base")
        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                let base = VividPlayerCoreBase()
                XCTAssertEqual(base.eventQueue.label, "mpv")
                XCTAssertEqual(base.eventQueue.qos, .userInitiated)
                XCTAssertNil(base.delegate)
                XCTAssertFalse(base.isTerminal)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testEachCoreHasItsOwnEventQueue() {
        let first = VividPlayerCoreBase()
        let second = VividPlayerCoreBase()
        XCTAssertFalse(first.eventQueue === second.eventQueue)
        XCTAssertEqual(second.eventQueue.label, "mpv")
    }

    func testCoreDefaults() {
        let core = VividPlayerCore()
        XCTAssertNil(core.delegate)
        XCTAssertFalse(core.isPipActive)
        XCTAssertTrue(core.matchContentEnabled)
        XCTAssertTrue(core.hdrEnabled)
        XCTAssertNil(core.onEnterBackground)
        XCTAssertNil(core.sampleBufferDisplayLayer)
        XCTAssertFalse(core.selectsAudioWhilePreloading)
        XCTAssertNil(core.preloadedAudioTrackID(tracks: [["type": "audio", "id": Int64(1)]]))
        XCTAssertTrue(core.pauseTracker.showsPaused)
        core.dispose()
    }

    // MARK: Ordered delivery and coalescing (section 6.10)

    func testCoalescingScenarioBusyMain() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
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
        XCTAssertEqual(recorder.log, [
            "time-pos=2.0", "avsync=0.01", "pause=true", "time-pos=3.0", "event:seek", "time-pos=5.0",
        ])
    }

    func testCoalescingScenarioIdleMain() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        for time in [1.0, 2.0, 3.0] {
            mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: time, sourceId: nil) }
            await drainMain()
        }
        XCTAssertEqual(recorder.log, ["time-pos=1.0", "time-pos=2.0", "time-pos=3.0"])
    }

    func testCoalescingScenarioDisposal() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: 1.0, sourceId: nil) }
        core.beginDisposal()
        await drainMain()
        XCTAssertTrue(recorder.log.isEmpty)
    }

    func testReplacedCoalescedValueKeepsItsQueuePosition() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        mpvQueue.sync {
            core.dispatchDelegateProperty(name: "avsync", value: 0.1, sourceId: nil)
            core.dispatchDelegateProperty(name: "demuxer-cache-duration", value: 2.0, sourceId: nil)
            core.dispatchDelegateProperty(name: "demuxer-cache-state", value: nil, sourceId: nil)
            core.dispatchDelegateProperty(name: "avsync", value: 0.3, sourceId: nil)
            core.dispatchDelegateProperty(name: "demuxer-cache-duration", value: 4.0, sourceId: nil)
        }
        await drainMain()
        XCTAssertEqual(recorder.log, ["avsync=0.3", "demuxer-cache-duration=4.0", "demuxer-cache-state=nil"])
    }

    func testOrderedItemCarriesPendingValuesAheadOfItselfInOneHop() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        mpvQueue.sync {
            core.dispatchDelegateProperty(name: "demuxer-cache-duration", value: 1.0, sourceId: nil)
            core.dispatchDelegateProperty(name: "time-pos", value: 7.0, sourceId: 2)
            core.dispatchDelegateProperty(name: "aid", value: "1", sourceId: 2)
        }
        await drainMainOnce()
        XCTAssertEqual(recorder.log, ["demuxer-cache-duration=1.0", "time-pos=7.0", "aid=1"])
        XCTAssertEqual(recorder.properties[1].sourceId, 2)
        XCTAssertEqual(recorder.properties[2].sourceId, 2)
        XCTAssertNil(recorder.properties[0].sourceId)

        // The flush queued for the first value finds its token retired.
        await drainMain()
        XCTAssertEqual(recorder.log.count, 3)

        // A later coalesced value schedules a fresh flush.
        mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: 8.0, sourceId: 2) }
        await drainMainOnce()
        XCTAssertEqual(recorder.log.last, "time-pos=8.0")
    }

    func testEventPayloadGainsInt64SourceIdOnlyWhenGiven() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        mpvQueue.sync {
            core.dispatchDelegateEvent(name: "file-loaded", data: nil, sourceId: 7)
            core.dispatchDelegateEvent(name: "end-file", data: ["reason": 0], sourceId: 9)
            core.dispatchDelegateEvent(name: "seek", data: nil)
            core.dispatchDelegateEvent(name: "log-message", data: ["text": "x"])
        }
        await drainMain()
        XCTAssertEqual(recorder.events.map(\.name), ["file-loaded", "end-file", "seek", "log-message"])

        let loaded = recorder.events[0].data
        XCTAssertEqual(loaded?.count, 1)
        XCTAssertTrue(loaded?["sourceId"] is Int64)
        XCTAssertEqual(loaded?["sourceId"] as? Int64, 7)

        let ended = recorder.events[1].data
        XCTAssertEqual(ended?.count, 2)
        XCTAssertEqual(ended?["reason"] as? Int, 0)
        XCTAssertEqual(ended?["sourceId"] as? Int64, 9)

        XCTAssertNil(recorder.events[2].data)
        XCTAssertEqual(recorder.events[3].data?.count, 1)
        XCTAssertEqual(recorder.events[3].data?["text"] as? String, "x")
    }

    func testDelegateIsReadAtDeliveryTime() async {
        let core = VividPlayerCoreBase()
        let first = CoreRecorder()
        let second = CoreRecorder()
        core.delegate = first
        mpvQueue.sync { core.dispatchDelegateProperty(name: "pause", value: false, sourceId: nil) }
        core.delegate = second
        await drainMain()
        XCTAssertTrue(first.log.isEmpty)
        XCTAssertEqual(second.log, ["pause=false"])

        mpvQueue.sync { core.dispatchDelegateEvent(name: "seek", data: nil) }
        core.delegate = nil
        await drainMain()
        XCTAssertEqual(second.log, ["pause=false"])
    }

    func testBeginDisposalDropsQueuedOrderedItems() async {
        let core = VividPlayerCoreBase()
        let recorder = CoreRecorder()
        core.delegate = recorder
        mpvQueue.sync {
            core.dispatchDelegateProperty(name: "avsync", value: 0.2, sourceId: nil)
            core.dispatchDelegateProperty(name: "pause", value: true, sourceId: nil)
            core.dispatchDelegateEvent(name: "end-file", data: nil)
        }
        XCTAssertTrue(core.beginDisposal())
        XCTAssertFalse(core.beginDisposal())
        XCTAssertTrue(core.isTerminal)
        await drainMain()
        mpvQueue.sync { core.dispatchDelegateProperty(name: "time-pos", value: 1.0, sourceId: nil) }
        await drainMain()
        XCTAssertTrue(recorder.log.isEmpty)
    }

    // MARK: Requests without a context (sections 6.13.3 and 10.1)

    func testTerminalCoreFailsSetAndGetInlineOnMain() {
        let core = VividPlayerCoreBase()
        core.beginDisposal()
        var setResults: [Result<Void, Error>] = []
        var getResults: [Result<String?, Error>] = []
        core.setPropertyAsync("volume", value: "50") { setResults.append($0) }
        core.getPropertyAsync("volume") { getResults.append($0) }
        XCTAssertEqual(setResults.count, 1)
        XCTAssertEqual(getResults.count, 1)
        if case .failure(let error) = setResults.first {
            XCTAssertEqual(error.localizedDescription, notAvailableText())
        } else { XCTFail("set should fail") }
        if case .failure(let error) = getResults.first {
            XCTAssertEqual(error.localizedDescription, notAvailableText())
        } else { XCTFail("get should fail") }
    }

    func testRequestsWithoutAContextFailInlineOnMain() async {
        let core = VividPlayerCore()
        var calls: [String] = []
        core.setPropertyAsync("volume", value: "50") { result in
            if case .failure(let error) = result, error.localizedDescription == self.notAvailableText() {
                calls.append("set")
            }
        }
        core.getPropertyAsync("volume") { result in
            if case .failure(let error) = result, error.localizedDescription == self.notAvailableText() {
                calls.append("get")
            }
        }
        core.commandAsync(["seek", "0"]) { result in
            if case .failure(let error) = result, error.localizedDescription == self.notAvailableText() {
                calls.append("command")
            }
        }
        XCTAssertEqual(calls, ["set", "get", "command"])
        core.setProperty("volume", value: "10")
        core.command(["stop"])
        await drainMain()
        XCTAssertEqual(calls, ["set", "get", "command"])
        core.dispose()
    }

    func testEmptyCommandSucceedsInlineWithNilEvenWhenTerminal() {
        let core = VividPlayerCoreBase()
        var results: [Int64?] = []
        core.commandAsync([]) { if case .success(let id) = $0 { results.append(id) } }
        core.beginDisposal()
        core.commandAsync([]) { if case .success(let id) = $0 { results.append(id) } }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results, [nil, nil])
    }

    func testCompletionsCalledOffMainArriveLaterOnMain() {
        let core = VividPlayerCoreBase()
        core.beginDisposal()
        let arrived = expectation(description: "completions")
        arrived.expectedFulfillmentCount = 3
        let submitted = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var returned = false
        var order: [String] = []
        var inline: [Bool] = []
        var onMain: [Bool] = []
        func finish(_ name: String) {
            lock.lock()
            order.append(name)
            inline.append(!returned)
            onMain.append(Thread.isMainThread)
            lock.unlock()
            arrived.fulfill()
        }
        // `sync` from main would run on the main thread, so submit asynchronously
        // and hold main until every call has returned. A completion queued on
        // main cannot run before then; one run inside its call on the calling
        // thread is recorded at once.
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            core.getPropertyAsync("volume") { _ in finish("get") }
            core.setPropertyAsync("volume", value: "1") { _ in finish("set") }
            core.commandAsync([]) { _ in finish("command") }
            lock.lock()
            returned = true
            lock.unlock()
            submitted.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 5), .success, "the calls returned while main was held")
        lock.lock()
        let completedDuringCalls = order.count
        lock.unlock()
        XCTAssertEqual(completedDuringCalls, 0, "no completion ran inside its call")
        wait(for: [arrived], timeout: 5)
        XCTAssertEqual(order, ["get", "set", "command"])
        XCTAssertEqual(inline, [false, false, false])
        XCTAssertEqual(onMain, [true, true, true])
    }

    // MARK: Pause cache (section 6.12)

    func testPausedValuesAreCaseInsensitive() {
        for value in ["1", "true", "yes", "on", "ON", "On", "TRUE", "Yes"] {
            XCTAssertTrue(VividPlayerPauseTracker.isPausedValue(value), value)
        }
        for value in ["0", "no", "false", "off", "", "2", " yes", "paused", "auto"] {
            XCTAssertFalse(VividPlayerPauseTracker.isPausedValue(value), value)
        }
    }

    func testPauseTableRequestPlaySucceeds() {
        let tracker = VividPlayerPauseTracker()
        XCTAssertTrue(tracker.showsPaused)
        let play = tracker.begin(paused: false)
        XCTAssertFalse(tracker.showsPaused)
        tracker.resolve(play, succeeded: true)
        XCTAssertFalse(tracker.showsPaused)
    }

    func testPauseTableObservationBeforeReply() {
        let tracker = VividPlayerPauseTracker()
        let play = tracker.begin(paused: false)
        tracker.observe(paused: false)
        tracker.resolve(play, succeeded: true)
        XCTAssertFalse(tracker.showsPaused)
    }

    func testPauseTableFailureReverts() {
        let tracker = VividPlayerPauseTracker()
        let play = tracker.begin(paused: false)
        XCTAssertFalse(tracker.showsPaused)
        tracker.resolve(play, succeeded: false)
        XCTAssertTrue(tracker.showsPaused)
    }

    func testPauseTableNewestOutstandingRequestWins() {
        let tracker = VividPlayerPauseTracker()
        let play = tracker.begin(paused: false)
        let pause = tracker.begin(paused: true)
        tracker.resolve(play, succeeded: true)
        XCTAssertTrue(tracker.showsPaused, "request 2 is still outstanding")
        tracker.resolve(pause, succeeded: true)
        XCTAssertTrue(tracker.showsPaused)
    }

    func testPauseTableLateReplyChangesNothing() {
        let tracker = VividPlayerPauseTracker()
        let pause = tracker.begin(paused: true)
        let play = tracker.begin(paused: false)
        tracker.resolve(play, succeeded: true)
        XCTAssertFalse(tracker.showsPaused)
        tracker.resolve(pause, succeeded: true)
        XCTAssertFalse(tracker.showsPaused)
    }

    func testPauseTableResolvedRequestRetiresOlderOnes() {
        let tracker = VividPlayerPauseTracker()
        let pause = tracker.begin(paused: true)
        let play = tracker.begin(paused: false)
        tracker.resolve(play, succeeded: true)
        XCTAssertFalse(tracker.showsPaused)
        // Request 1 retired with request 2, so it does not block the observation.
        tracker.observe(paused: true)
        XCTAssertTrue(tracker.showsPaused)
        tracker.resolve(pause, succeeded: true)
        XCTAssertTrue(tracker.showsPaused)
    }

    func testPauseTableObservationWinsOverAnOlderRequest() {
        let tracker = VividPlayerPauseTracker()
        let play = tracker.begin(paused: false)
        tracker.observe(paused: true)
        XCTAssertFalse(tracker.showsPaused, "the request is still outstanding")
        tracker.resolve(play, succeeded: true)
        XCTAssertTrue(tracker.showsPaused)
    }

    func testPauseTableObservationWithNothingOutstanding() {
        let tracker = VividPlayerPauseTracker()
        tracker.observe(paused: false)
        XCTAssertFalse(tracker.showsPaused)
        tracker.observe(paused: true)
        XCTAssertTrue(tracker.showsPaused)
    }

    func testFailedResolutionAlsoRetiresOlderRequests() {
        let tracker = VividPlayerPauseTracker()
        tracker.observe(paused: false)
        let first = tracker.begin(paused: true)
        let second = tracker.begin(paused: true)
        let third = tracker.begin(paused: true)
        tracker.resolve(second, succeeded: false)
        XCTAssertTrue(tracker.showsPaused, "request 3 is still outstanding")
        tracker.resolve(third, succeeded: false)
        XCTAssertFalse(tracker.showsPaused, "back to the confirmed state")
        tracker.resolve(first, succeeded: true)
        XCTAssertFalse(tracker.showsPaused, "request 1 was retired with request 2")
    }

    func testPauseRequestResolvesBeforeTheCallersCompletion() {
        let core = VividPlayerCore()
        core.pauseTracker.observe(paused: false)
        var seenInsideCompletion: Bool?
        // No context, so the request fails inline and the displayed state reverts.
        core.setPropertyAsync("pause", value: "ON") { _ in
            seenInsideCompletion = core.pauseTracker.showsPaused
        }
        XCTAssertEqual(seenInsideCompletion, false)
        XCTAssertFalse(core.pauseTracker.showsPaused)
        core.dispose()
    }

    func testPauseRequestOnATerminalCoreChangesNothing() {
        let core = VividPlayerCoreBase()
        core.pauseTracker.observe(paused: false)
        core.beginDisposal()
        var failed = false
        core.setPropertyAsync("pause", value: "yes") { if case .failure = $0 { failed = true } }
        XCTAssertTrue(failed)
        XCTAssertFalse(core.pauseTracker.showsPaused)
    }

    // MARK: Disposal (section 6.17)

    func testDisposeWithoutAContextCallsItsCompletionOnceOnTheEventQueue() async {
        let core = VividPlayerCore()
        let key = DispatchSpecificKey<String>()
        core.eventQueue.setSpecific(key: key, value: "event-queue")
        let finished = expectation(description: "dispose completion")
        let calls = Counter()
        core.dispose(preserveDisplayCriteria: false) {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), "event-queue")
            calls.increment()
            finished.fulfill()
        }
        XCTAssertTrue(core.isTerminal)
        await fulfillment(of: [finished], timeout: 5)

        let second = expectation(description: "second dispose completion")
        second.isInverted = true
        core.dispose { second.fulfill() }
        core.dispose(preserveDisplayCriteria: true) { second.fulfill() }
        await fulfillment(of: [second], timeout: 0.5)
        XCTAssertEqual(calls.value, 1)
    }

    func testDisposeAfterBeginDisposalDoesNothing() async {
        let core = VividPlayerCore()
        core.beginDisposal()
        let never = expectation(description: "completion")
        never.isInverted = true
        core.dispose { never.fulfill() }
        await fulfillment(of: [never], timeout: 0.5)
    }

    func testDisposeTakesTheSurfaceDownButKeepsTheHostView() async {
        let (window, host) = makeHost(sibling: true)
        let core = StubCore()
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        core.setVisible(true)
        let layer = try? XCTUnwrap(core.sampleBufferDisplayLayer)
        let container = host.subviews.first
        let finished = expectation(description: "dispose completion")
        core.dispose(preserveDisplayCriteria: true) { finished.fulfill() }

        XCTAssertNil(core.sampleBufferDisplayLayer)
        XCTAssertNil(layer?.superlayer)
        XCTAssertNil(container?.superview)
        XCTAssertEqual(host.subviews.count, 1, "only the caller's own subview remains")
        XCTAssertTrue(host.window === window)
        await fulfillment(of: [finished], timeout: 5)

        // Safe no-ops once disposed.
        core.updateFrame()
        core.setVisible(true)
        core.externalDisplayDidChange()
        XCTAssertEqual(host.subviews.count, 1)
    }

    func testReleasingAnInitialisedCoreWithoutDisposeDoesNotCrash() async throws {
        let (window, host) = makeHost()
        var core: StubCore? = StubCore()
        weak var weakCore = core
        XCTAssertEqual(core?.initialize(in: window, hostView: host), true)
        core?.setVisible(true)
        XCTAssertEqual(host.subviews.count, 1)
        core = nil
        XCTAssertNil(weakCore)
        // Its deinit disposed it: the container is gone and the queued destroy step runs safely.
        XCTAssertEqual(host.subviews.count, 0)
        try await Task.sleep(for: .milliseconds(300))
        await drainMain()
    }

    func testReleasingAnUninitialisedCoreWithoutDisposeDoesNotCrash() async throws {
        autoreleasepool {
            let core = VividPlayerCore()
            core.setProperty("volume", value: "1")
            _ = core
        }
        try await Task.sleep(for: .milliseconds(200))
        await drainMain()
    }

    // MARK: Initialisation and surface (sections 6.2, 7 and 9.3)

    func testInitializeMountsTheLayerBeforeCreatingTheContext() throws {
        let (window, host) = makeHost(sibling: true)
        let core = StubCore()
        core.expectedHost = host
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        defer { core.dispose() }

        let layer = try XCTUnwrap(core.sampleBufferDisplayLayer)
        XCTAssertEqual(core.startedWids, [address(of: layer)])
        XCTAssertTrue(core.layerWasMountedAtStart)

        let container = try XCTUnwrap(host.subviews.first)
        XCTAssertEqual(host.subviews.count, 2)
        XCTAssertTrue(layer.superlayer === container.layer)
        XCTAssertTrue(layer.superlayer?.superlayer === host.layer)
        XCTAssertEqual(container.backgroundColor, .black)
        XCTAssertFalse(container.isUserInteractionEnabled)
        XCTAssertEqual(container.frame, window.bounds)
        XCTAssertTrue(layer.isOpaque)
        XCTAssertEqual(layer.backgroundColor, UIColor.black.cgColor)
        XCTAssertEqual(layer.videoGravity, .resizeAspect)
        XCTAssertEqual(layer.contentsScale, window.screen.nativeScale)
        #if os(iOS)
        XCTAssertTrue(container.isHidden, "iOS keeps the container hidden until setVisible(true)")
        #else
        XCTAssertFalse(container.isHidden)
        #endif
    }

    func testFailedInitializeLeavesNothingInTheHostView() async throws {
        let (window, host) = makeHost(sibling: true)
        let core = StubCore()
        core.startsContext = false
        var backgroundHookCalls = 0
        core.onEnterBackground = { backgroundHookCalls += 1 }
        XCTAssertFalse(core.initialize(in: window, hostView: host))

        XCTAssertNil(core.sampleBufferDisplayLayer)
        XCTAssertNil(core.createdLayer?.superlayer)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertFalse(core.isTerminal)

        // No lifecycle observer was registered.
        postBackground()
        XCTAssertEqual(backgroundHookCalls, 0)
        XCTAssertTrue(core.actions.isEmpty)

        // Surface calls stay safe, and a later dispose still completes.
        core.updateFrame()
        core.setVisible(true)
        XCTAssertEqual(host.subviews.count, 1)
        let finished = expectation(description: "dispose completion")
        core.dispose(preserveDisplayCriteria: false) { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
    }

    func testSurfaceCallsAreSafeBeforeInitialize() {
        let core = VividPlayerCore()
        core.updateFrame()
        core.updateFrame(CGRect(x: 0, y: 0, width: 10, height: 10))
        core.setVisible(true)
        core.externalDisplayDidChange()
        XCTAssertNil(core.sampleBufferDisplayLayer)
        core.dispose()
    }

    func testVisibilityAndGeometryFollowTheHostView() throws {
        let (window, host) = makeHost()
        let core = StubCore()
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        defer { core.dispose() }
        core.setVisible(true)
        let layer = try XCTUnwrap(core.sampleBufferDisplayLayer)
        let container = try XCTUnwrap(host.subviews.first)
        XCTAssertFalse(container.isHidden)
        XCTAssertTrue(container.autoresizingMask.contains(.flexibleWidth))
        XCTAssertTrue(container.autoresizingMask.contains(.flexibleHeight))
        XCTAssertEqual(container.frame, host.bounds)

        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        container.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        core.updateFrame()
        XCTAssertEqual(container.frame, host.bounds)
        XCTAssertEqual(layer.bounds, CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(layer.position, CGPoint(x: 150, y: 100))
        XCTAssertTrue(layer.superlayer === container.layer)

        // A placement refresh returns the container to the bottom of the host view.
        host.insertSubview(UIView(), at: 0)
        XCTAssertFalse(host.subviews.first === container)
        core.externalDisplayDidChange()
        XCTAssertTrue(host.subviews.first === container)
        XCTAssertTrue(core.sampleBufferDisplayLayer === layer, "the same layer moves with its container")
    }

    // MARK: Picture in Picture compositing (section 9.5)

    func testPictureInPictureCompositingSendsEveryCall() {
        let core = StubCore()
        core.setPipSubtitleCompositing(true)
        core.setPipSubtitleCompositing(true)
        core.setPipSubtitleCompositing(false)
        #if os(iOS)
        XCTAssertEqual(core.actions, [
            "set avfoundation-pip-composite-osd=yes",
            "set avfoundation-pip-composite-osd=yes",
            "set avfoundation-pip-composite-osd=no",
        ])
        #else
        XCTAssertTrue(core.actions.isEmpty, "Apple TV has no Picture in Picture")
        #endif
        core.dispose()
    }

    // MARK: App lifecycle (section 6.18)

    private func postBackground() {
        #if os(iOS)
        NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification, object: nil)
        #else
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
    }

    private func postForeground() {
        #if os(iOS)
        NotificationCenter.default.post(name: UIScene.willEnterForegroundNotification, object: nil)
        #else
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    /// A window without a scene makes the core follow every scene's
    /// notifications, so the test can post them without touching the app's scene.
    private func lifecycleCore() -> StubCore {
        let (window, host) = makeHost(attachToScene: false)
        let core = StubCore()
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        core.setVisible(true)
        core.actions = []
        addTeardownBlock { @MainActor in core.dispose() }
        return core
    }

    func testBackgroundCallsTheHookFirstThenDeselectsVideo() {
        let core = lifecycleCore()
        var seenInHook: (backgrounded: Bool, actions: [String])?
        core.onEnterBackground = { seenInHook = (core.isBackgrounded, core.actions) }
        postBackground()
        XCTAssertEqual(seenInHook?.backgrounded, false)
        XCTAssertEqual(seenInHook?.actions, [])
        XCTAssertTrue(core.isBackgrounded)
        XCTAssertEqual(core.actions, ["set vid=no"])

        postForeground()
        XCTAssertFalse(core.isBackgrounded)
        XCTAssertEqual(core.actions, ["set vid=no", "set vid=auto"])
    }

    func testPictureInPictureKeepsVideoAcrossBackgroundAndForeground() {
        let core = lifecycleCore()
        var hookCalls = 0
        core.onEnterBackground = { hookCalls += 1 }
        core.isPipActive = true
        postBackground()
        XCTAssertEqual(hookCalls, 1)
        XCTAssertTrue(core.isBackgrounded)
        postForeground()
        XCTAssertFalse(core.isBackgrounded)
        XCTAssertTrue(core.actions.isEmpty)
    }

    func testObserversAreRemovedAtDispose() {
        let core = lifecycleCore()
        var hookCalls = 0
        core.onEnterBackground = { hookCalls += 1 }
        core.dispose()
        postBackground()
        postForeground()
        XCTAssertEqual(hookCalls, 0)
        XCTAssertTrue(core.actions.isEmpty)
    }

    #if os(iOS)
    private func postActivation() {
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: nil)
    }

    func testActivationRestoresVideoAndRedrawsOnlyWhenPaused() {
        let core = lifecycleCore()
        core.isBackgrounded = true
        XCTAssertTrue(core.pauseTracker.showsPaused)
        postActivation()
        XCTAssertFalse(core.isBackgrounded)
        XCTAssertEqual(core.actions, ["set vid=auto", "command seek 0 relative+exact"])

        core.actions = []
        core.pauseTracker.observe(paused: false)
        postActivation()
        XCTAssertEqual(core.actions, ["set vid=auto"])
    }

    func testActivationDoesNothingMoreDuringPictureInPicture() {
        let core = lifecycleCore()
        core.isBackgrounded = true
        core.isPipActive = true
        postActivation()
        XCTAssertFalse(core.isBackgrounded)
        XCTAssertTrue(core.actions.isEmpty)
    }

    func testCoreFollowsOnlyItsOwnSceneWhenItHasOne() throws {
        let (window, host) = makeHost(attachToScene: true)
        try XCTSkipIf(window.windowScene == nil, "The test host has no window scene to attach to.")
        let core = StubCore()
        var hookCalls = 0
        core.onEnterBackground = { hookCalls += 1 }
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        defer { core.dispose() }
        core.actions = []
        // Posted without a scene, so a core bound to its own scene ignores them.
        postBackground()
        postForeground()
        postActivation()
        XCTAssertEqual(hookCalls, 0)
        XCTAssertTrue(core.actions.isEmpty)
    }

    // MARK: External displays (section 9.1)

    func testExternalDisplayRoleTest() {
        let role = { UISceneSession.Role(rawValue: $0) }
        XCTAssertTrue(VividExternalDisplay.isExternalDisplayRole(role("UIWindowSceneSessionRoleExternalDisplay")))
        XCTAssertTrue(VividExternalDisplay.isExternalDisplayRole(
            role("UIWindowSceneSessionRoleExternalDisplayNonInteractive")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(.windowApplication))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("UIWindowSceneSessionRoleApplication")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("CPTemplateApplicationSceneSessionRoleApplication")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("uiwindowscenesessionroleexternaldisplay")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("UIWindowSceneSessionRoleExternalDisplay ")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("UIWindowSceneSessionRoleExternalDisplayFuture")))
        XCTAssertFalse(VividExternalDisplay.isExternalDisplayRole(role("")))
    }

    func testExternalDisplayRoleTestWorksOffMain() {
        let finished = expectation(description: "off-main role test")
        DispatchQueue.global().async {
            XCTAssertTrue(VividExternalDisplay.isExternalDisplayRole(
                UISceneSession.Role(rawValue: "UIWindowSceneSessionRoleExternalDisplay")))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
    #else
    func testTVHasNoActivationHandler() {
        let core = lifecycleCore()
        core.isBackgrounded = true
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: nil)
        XCTAssertTrue(core.isBackgrounded)
        XCTAssertTrue(core.actions.isEmpty)
    }
    #endif

    // MARK: Console output (section 10.2)

    private func captureStandardOutput(_ body: () -> Void) -> String {
        fflush(stdout)
        let pipe = Pipe()
        let saved = dup(STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        body()
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    func testCheckErrorPrintsTheDocumentedLine() {
        let core = VividPlayerCoreBase()
        let output = captureStandardOutput {
            core.checkError(-5, option: "ao-avfoundation-manage-audio-session",
                            file: "Vivid/VividMPVPlayer.swift", line: 120)
            core.checkError(-5, file: "VividTV/VividMPVPlayer.swift", line: 7)
        }
        let lines = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[VividPlayerCore]") }
        XCTAssertEqual(lines, [
            "[VividPlayerCore] MPV error: option not found option=ao-avfoundation-manage-audio-session at Vivid/VividMPVPlayer.swift:120",
            "[VividPlayerCore] MPV error: option not found at VividTV/VividMPVPlayer.swift:7",
        ])
    }

    func testCheckErrorCapturesTheCallersLocation() {
        let core = VividPlayerCoreBase()
        var line: UInt = 0
        let output = captureStandardOutput {
            line = #line + 1
            core.checkError(-5, option: "aid")
        }
        XCTAssertTrue(output.contains("[VividPlayerCore] MPV error: option not found option=aid at \(#fileID):\(line)\n"),
                      output)
    }

    func testCheckErrorIsSilentForSuccess() {
        let core = VividPlayerCoreBase()
        let output = captureStandardOutput {
            core.checkError(0)
            core.checkError(1, option: "vo")
        }
        XCTAssertFalse(output.contains("[VividPlayerCore]"), output)
    }
}

/// A thread-safe call counter for completions that run off main.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
