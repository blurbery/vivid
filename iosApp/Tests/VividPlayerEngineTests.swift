// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import Libmpv
import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

private final class EngineRecorder: VividPlayerCoreDelegate {
    var properties: [(name: String, value: Any?, sourceId: Int64?)] = []
    var events: [(name: String, data: [String: Any]?)] = []
    var offMainCallbacks = 0

    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        if !Thread.isMainThread { offMainCallbacks += 1 }
        properties.append((name, value, sourceId))
    }

    func onEvent(name: String, data: [String: Any]?) {
        if !Thread.isMainThread { offMainCallbacks += 1 }
        events.append((name, data))
    }

    func events(named name: String) -> [[String: Any]?] {
        events.filter { $0.name == name }.map(\.data)
    }

    func values(named name: String) -> [(value: Any?, sourceId: Int64?)] {
        properties.filter { $0.name == name }.map { ($0.value, $0.sourceId) }
    }

    var propertyNames: Set<String> { Set(properties.map(\.name)) }
}

/// Records the preload hook's calls, which arrive on the event queue.
private final class PreloadCore: VividPlayerCore {
    private let lock = NSLock()
    private let queueKey = DispatchSpecificKey<Bool>()
    var selects = true
    var choice: Int64? = 1
    private var recorded: [(tracks: [[String: Any]], onEventQueue: Bool)] = []

    override init() {
        super.init()
        eventQueue.setSpecific(key: queueKey, value: true)
    }

    var calls: [(tracks: [[String: Any]], onEventQueue: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override var selectsAudioWhilePreloading: Bool { selects }

    override func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64? {
        lock.lock()
        recorded.append((tracks, DispatchQueue.getSpecific(key: queueKey) == true))
        lock.unlock()
        return choice
    }
}

private struct WaitTimedOut: Error {}

/// The bridge driven through a real mpv context in the simulator: event
/// payloads, property types, request replies, background filtering, the
/// preload hook and teardown (sections 4.6, 4.7, 6.6 to 6.15 and 6.17).
@MainActor
final class VividPlayerEngineTests: XCTestCase {
    private func fixturePath() throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4")).path
    }

    private func missingPath() -> String {
        NSTemporaryDirectory() + "vivid-bridge-missing-\(UUID().uuidString).mp4"
    }

    private func makeHost() -> (window: UIWindow, host: UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        window.rootViewController = controller
        let host = UIView(frame: controller.view.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.backgroundColor = .black
        controller.view.addSubview(host)
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        return (window, host)
    }

    /// Initialises `core` and disposes it after the test unless the test did.
    @discardableResult
    private func start(_ core: VividPlayerCore, _ recorder: EngineRecorder,
                       disposeAfterwards: Bool = true) throws -> UIView {
        let (window, host) = makeHost()
        core.delegate = recorder
        XCTAssertTrue(core.initialize(in: window, hostView: host))
        core.setVisible(true)
        if disposeAfterwards {
            addTeardownBlock { @MainActor in
                guard !core.isTerminal else { return }
                await withCheckedContinuation { continuation in
                    core.dispose { continuation.resume() }
                }
            }
        }
        return host
    }

    private func waitUntil(_ description: String, timeout: Double = 15,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description)")
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Wraps a completion in a checked continuation, which traps if it runs
    /// twice, and reports whether it ran before the call returned.
    private func complete<T>(_ submit: (@escaping (Result<T, Error>) -> Void) -> Void) async
        -> (result: Result<T, Error>, inline: Bool, onMain: Bool) {
        var returned = false
        var inline = false
        var onMain = false
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            submit { result in
                inline = !returned
                onMain = Thread.isMainThread
                continuation.resume(returning: result)
            }
            returned = true
        }
        return (result, inline, onMain)
    }

    private func command(_ core: VividPlayerCore, _ args: [String]) async -> Result<Int64?, Error> {
        await complete { core.commandAsync(args, completion: $0) }.result
    }

    private func set(_ core: VividPlayerCore, _ name: String, _ value: String) async -> Result<Void, Error> {
        await complete { core.setPropertyAsync(name, value: value, completion: $0) }.result
    }

    private func loadedId(_ result: Result<Int64?, Error>, file: StaticString = #filePath,
                          line: UInt = #line) throws -> Int64 {
        guard case .success(let id?) = result else {
            XCTFail("loadfile did not complete with an id: \(result)", file: file, line: line)
            throw WaitTimedOut()
        }
        return id
    }

    private func mpvError(_ result: Result<some Any, Error>, file: StaticString = #filePath,
                          line: UInt = #line) -> NSError? {
        guard case .failure(let error) = result else {
            XCTFail("expected an mpv error", file: file, line: line)
            return nil
        }
        return error as NSError
    }

    private func errorText(_ code: Int) -> String {
        String(cString: mpv_error_string(Int32(code)))
    }

    // MARK: Loading, events and property types

    func testLoadfileIdMatchesEventsAndPropertiesKeepTheirTypes() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        for (name, format) in [
            ("time-pos", "double"), ("duration", "double"), ("pause", "flag"), ("eof-reached", "flag"),
            ("track-list", "node"), ("aid", "string"), ("video-params", "node"), ("container-fps", "double"),
            ("volume", "int64"),
        ] {
            core.observeProperty(name, format: format)
        }

        let id = try loadedId(await command(core, ["loadfile", try fixturePath()]))
        try await waitUntil("playback restart") { !recorder.events(named: "playback-restart").isEmpty }
        try await waitUntil("video parameters and tracks") {
            recorder.values(named: "video-params").contains { $0.value != nil }
                && recorder.values(named: "track-list").contains { ($0.value as? [Any])?.isEmpty == false }
                && recorder.values(named: "duration").contains { $0.value != nil }
                && recorder.values(named: "container-fps").contains { $0.value != nil }
        }

        // start-file and file-loaded carry the loadfile id as Int64.
        let started = try XCTUnwrap(recorder.events(named: "start-file").first ?? nil)
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started["sourceId"] is Int64)
        XCTAssertEqual(started["sourceId"] as? Int64, id)
        let loaded = try XCTUnwrap(recorder.events(named: "file-loaded").first ?? nil)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded["sourceId"] as? Int64, id)

        let restart = try XCTUnwrap(recorder.events(named: "playback-restart").first ?? nil)
        XCTAssertTrue(restart["positionSeconds"] is Double)
        XCTAssertTrue(restart["sourceId"] is Int64)
        XCTAssertEqual(restart["sourceId"] as? Int64, id)
        XCTAssertEqual(Set(restart.keys), ["positionSeconds", "sourceId"])

        // Property values are typed by the change event's format.
        let tracks = try XCTUnwrap(recorder.values(named: "track-list").last { ($0.value as? [Any])?.isEmpty == false })
        XCTAssertEqual(tracks.sourceId, id)
        let list = try XCTUnwrap(tracks.value as? [[String: Any]])
        let video = try XCTUnwrap(list.first { $0["type"] as? String == "video" })
        XCTAssertTrue(video["id"] is Int64)
        XCTAssertTrue(video["ff-index"] is Int64)
        XCTAssertTrue(video["selected"] is Bool)
        XCTAssertTrue(video["default"] is Bool)
        XCTAssertTrue(video["external"] is Bool)
        XCTAssertEqual(video["codec"] as? String, "h264")
        let audio = try XCTUnwrap(list.first { $0["type"] as? String == "audio" })
        XCTAssertTrue(audio["demux-channel-count"] is Int64)

        let params = try XCTUnwrap(recorder.values(named: "video-params").last { $0.value != nil }?.value as? [String: Any])
        XCTAssertEqual(params["w"] as? Int64, 320)
        XCTAssertEqual(params["h"] as? Int64, 180)
        XCTAssertTrue(params["par"] is Double)
        XCTAssertTrue(params["gamma"] is String)

        let duration = try XCTUnwrap(recorder.values(named: "duration").last { $0.value != nil }?.value as? Double)
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        XCTAssertTrue(recorder.values(named: "pause").allSatisfy { $0.value is Bool })
        XCTAssertTrue(recorder.values(named: "eof-reached").allSatisfy { $0.value == nil || $0.value is Bool })
        XCTAssertTrue(recorder.values(named: "time-pos").allSatisfy { $0.value == nil || $0.value is Double })
        XCTAssertEqual(recorder.values(named: "aid").last?.value as? String, "1")

        // Internal observations never reach the delegate; container-fps does, once per change.
        let internalNames: Set<String> = [
            "width", "height", "deinterlace-active", "video-params/gamma", "video-params/primaries",
            "video-params/colormatrix", "video-params/sig-peak", "current-tracks/video/dolby-vision-profile",
            "current-tracks/video/dolby-vision-level",
        ]
        XCTAssertTrue(recorder.propertyNames.isDisjoint(with: internalNames), "\(recorder.propertyNames)")
        let rates = recorder.values(named: "container-fps").compactMap { $0.value as? Double }
        XCTAssertEqual(rates.count, 1, "\(rates)")
        XCTAssertEqual(rates.first ?? 0, 24, accuracy: 0.01)
        XCTAssertFalse(recorder.propertyNames.contains("volume"), "an int64 observation is ignored")

        // Debug-only lock timing, where built, precedes the start-file it belongs to.
        if let lock = recorder.events.firstIndex(where: {
            $0.name == "display-commit-lock" && $0.data?["transition"] as? String == "start_file"
        }) {
            XCTAssertLessThan(lock, try XCTUnwrap(recorder.events.firstIndex { $0.name == "start-file" }))
        }

        // Any other command completes with nil; stop ends the file with reason 2.
        let stopped = await command(core, ["stop"])
        guard case .success(let stopId) = stopped else { return XCTFail("stop failed") }
        XCTAssertNil(stopId)
        try await waitUntil("end of file") { !recorder.events(named: "end-file").isEmpty }
        let ended = try XCTUnwrap(recorder.events(named: "end-file").first ?? nil)
        XCTAssertEqual(Set(ended.keys), ["reason", "sourceId"])
        XCTAssertTrue(ended["reason"] is Int)
        XCTAssertEqual(ended["reason"] as? Int, Int(MPV_END_FILE_REASON_STOP.rawValue))
        XCTAssertEqual(ended["sourceId"] as? Int64, id)
        XCTAssertEqual(recorder.offMainCallbacks, 0)
    }

    func testNaturalEndOfFileReportsReasonZero() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        guard case .success = await set(core, "keep-open", "no"),
              case .success = await set(core, "start", "-0.4") else { return XCTFail("could not set up the load") }
        let id = try loadedId(await command(core, ["loadfile", try fixturePath()]))
        try await waitUntil("end of file", timeout: 20) { !recorder.events(named: "end-file").isEmpty }
        let ended = try XCTUnwrap(recorder.events(named: "end-file").first ?? nil)
        XCTAssertEqual(Set(ended.keys), ["reason", "sourceId"])
        XCTAssertTrue(ended["reason"] is Int)
        XCTAssertFalse(ended["reason"] is Int64)
        XCTAssertEqual(ended["reason"] as? Int, 0)
        XCTAssertTrue(ended["sourceId"] is Int64)
        XCTAssertEqual(ended["sourceId"] as? Int64, id)
    }

    func testLoadFailureReportsTheErrorAndMessage() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        core.setLogLevel("v")
        let id = try loadedId(await command(core, ["loadfile", missingPath()]))
        try await waitUntil("end of file") { !recorder.events(named: "end-file").isEmpty }
        let ended = try XCTUnwrap(recorder.events(named: "end-file").first ?? nil)
        XCTAssertEqual(Set(ended.keys), ["reason", "error", "message", "sourceId"])
        XCTAssertEqual(ended["reason"] as? Int, 4)
        XCTAssertEqual(ended["reason"] as? Int, Int(MPV_END_FILE_REASON_ERROR.rawValue))
        let error = try XCTUnwrap(ended["error"] as? Int)
        XCTAssertLessThan(error, 0)
        XCTAssertEqual(ended["message"] as? String, errorText(error))
        XCTAssertEqual(ended["sourceId"] as? Int64, id)
        XCTAssertNil(recorder.events(named: "file-loaded").first)

        // Log messages carry exactly three strings and no source id.
        try await waitUntil("log messages") { !recorder.events(named: "log-message").isEmpty }
        for message in recorder.events(named: "log-message") {
            let data = try XCTUnwrap(message)
            XCTAssertEqual(Set(data.keys), ["prefix", "level", "text"])
            XCTAssertTrue(data["prefix"] is String)
            XCTAssertTrue(data["level"] is String)
            XCTAssertTrue(data["text"] is String)
        }
        XCTAssertTrue(recorder.events(named: "log-message").contains { ($0?["text"] as? String)?.hasSuffix("\n") == true },
                      "text arrives as mpv sends it")
    }

    // MARK: Requests (section 6.13)

    func testRepliesCompleteOnceAsynchronouslyOnMain() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)

        let volume = await complete { core.getPropertyAsync("volume", completion: $0) }
        XCTAssertFalse(volume.inline)
        XCTAssertTrue(volume.onMain)
        guard case .success(let text?) = volume.result else { return XCTFail("volume: \(volume.result)") }
        XCTAssertNotNil(Double(text), text)

        let unavailable = await complete { core.getPropertyAsync("video-params", completion: $0) }
        XCTAssertFalse(unavailable.inline)
        XCTAssertTrue(unavailable.onMain)
        let unavailableError = mpvError(unavailable.result)
        XCTAssertEqual(unavailableError?.code, Int(MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue))
        XCTAssertEqual(unavailableError?.localizedDescription, errorText(-10))

        let rejectedSet = await complete { core.setPropertyAsync("vivid-no-such-property", value: "1", completion: $0) }
        XCTAssertFalse(rejectedSet.inline)
        XCTAssertTrue(rejectedSet.onMain)
        let setError = mpvError(rejectedSet.result)
        XCTAssertLessThan(setError?.code ?? 0, 0)
        XCTAssertEqual(setError?.localizedDescription, errorText(setError?.code ?? 0))

        let rejectedCommand = await complete { core.commandAsync(["vivid-no-such-command"], completion: $0) }
        XCTAssertFalse(rejectedCommand.inline)
        XCTAssertTrue(rejectedCommand.onMain)
        let commandError = mpvError(rejectedCommand.result)
        XCTAssertLessThan(commandError?.code ?? 0, 0)
        XCTAssertEqual(commandError?.localizedDescription, errorText(commandError?.code ?? 0))

        let setCommand = await complete { core.commandAsync(["set", "volume", "50"], completion: $0) }
        XCTAssertFalse(setCommand.inline)
        guard case .success(let none) = setCommand.result else { return XCTFail("set command failed") }
        XCTAssertNil(none)

        guard case .success = await set(core, "volume", "40") else { return XCTFail("volume set failed") }
        let readBack = await complete { core.getPropertyAsync("volume", completion: $0) }
        guard case .success(let forty?) = readBack.result else { return XCTFail("volume read failed") }
        XCTAssertEqual(Double(forty), 40)
    }

    func testPauseRequestsMoveTheDisplayedStateAtOnce() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        XCTAssertTrue(core.pauseTracker.showsPaused)

        var outcome: Result<Void, Error>?
        core.setPropertyAsync("pause", value: "no") { outcome = $0 }
        XCTAssertNil(outcome)
        XCTAssertFalse(core.pauseTracker.showsPaused, "displayed follows the request before mpv replies")
        try await waitUntil("pause reply") { outcome != nil }
        XCTAssertFalse(core.pauseTracker.showsPaused)

        outcome = nil
        core.setPropertyAsync("pause", value: "yes") { outcome = $0 }
        XCTAssertTrue(core.pauseTracker.showsPaused)
        try await waitUntil("pause reply") { outcome != nil }
        guard case .success = outcome else { return XCTFail("pause failed") }
        XCTAssertTrue(core.pauseTracker.showsPaused)

        // `ON` counts as paused at once and reaches mpv unchanged; if mpv
        // rejects it, the displayed state falls back to the confirmed one.
        guard case .success = await set(core, "pause", "no") else { return XCTFail("resume failed") }
        outcome = nil
        core.setPropertyAsync("pause", value: "ON") { outcome = $0 }
        XCTAssertTrue(core.pauseTracker.showsPaused)
        try await waitUntil("pause reply") { outcome != nil }
        let reported = await complete { core.getPropertyAsync("pause", completion: $0) }
        guard case .success(let value?) = reported.result else { return XCTFail("pause read failed") }
        switch outcome {
        case .success?:
            XCTAssertTrue(core.pauseTracker.showsPaused)
            XCTAssertEqual(value, "yes")
        default:
            XCTAssertFalse(core.pauseTracker.showsPaused, "a rejected request reverts the displayed state")
            XCTAssertEqual(value, "no")
        }
    }

    func testRequestsPendingAtDisposeFailOnceWithTheDisposedError() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder, disposeAfterwards: false)

        // Hold the event queue so no reply can be drained before disposal.
        let gate = DispatchSemaphore(value: 0)
        await withCheckedContinuation { continuation in
            core.eventQueue.async {
                continuation.resume()
                gate.wait()
            }
        }
        var outcomes: [String: [Error?]] = [:]
        func record(_ name: String, _ error: Error?) { outcomes[name, default: []].append(error) }
        core.getPropertyAsync("volume") { if case .failure(let e) = $0 { record("get", e) } else { record("get", nil) } }
        core.setPropertyAsync("volume", value: "30") { if case .failure(let e) = $0 { record("set", e) } else { record("set", nil) } }
        core.commandAsync(["set", "volume", "20"]) { if case .failure(let e) = $0 { record("command", e) } else { record("command", nil) } }
        core.setPropertyAsync("pause", value: "no") { if case .failure(let e) = $0 { record("pause", e) } else { record("pause", nil) } }
        XCTAssertFalse(core.pauseTracker.showsPaused)

        let disposed = expectation(description: "dispose completion")
        core.dispose { disposed.fulfill() }
        XCTAssertTrue(outcomes.isEmpty, "cancellations are delivered asynchronously")
        gate.signal()

        try await waitUntil("cancellations") { outcomes.count == 4 }
        await fulfillment(of: [disposed], timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        let disposedText = VividPlayerCoreError.disposed.errorDescription
        for name in ["get", "set", "command", "pause"] {
            XCTAssertEqual(outcomes[name]?.count, 1, name)
            XCTAssertEqual(outcomes[name]?.first??.localizedDescription, disposedText, name)
        }
        XCTAssertTrue(core.pauseTracker.showsPaused, "a cancelled pause request reverts the displayed state")

        // Submitted after disposal: the not-available error, inline on main.
        let late = await complete { core.getPropertyAsync("volume", completion: $0) }
        XCTAssertTrue(late.inline)
        guard case .failure(let lateError) = late.result else { return XCTFail("late request succeeded") }
        XCTAssertEqual(lateError.localizedDescription, VividPlayerCoreError.notAvailable.errorDescription)
    }

    // MARK: Synchronous reads (section 6.14)

    func testSynchronousReadsRunOnTheEventQueue() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder, disposeAfterwards: false)
        let idle: (Double?, Bool?, [String: Any]?, [[String: Any]]?, Double?) = await withCheckedContinuation { continuation in
            core.eventQueue.async {
                continuation.resume(returning: (core.fetchNumber("volume"), core.fetchFlag("pause"),
                                                core.fetchMap("video-params"),
                                                core.fetchMaps("track-list"),
                                                core.fetchNumber("time-pos")))
            }
        }
        XCTAssertEqual(idle.0, 100)
        XCTAssertNotNil(idle.1)
        XCTAssertNil(idle.2, "unavailable while idle")
        XCTAssertEqual(idle.3?.count, 0)
        XCTAssertNil(idle.4)

        let disposed = expectation(description: "dispose completion")
        core.dispose { disposed.fulfill() }
        await fulfillment(of: [disposed], timeout: 10)
        let afterDispose: (Double?, Bool?) = await withCheckedContinuation { continuation in
            core.eventQueue.async {
                continuation.resume(returning: (core.fetchNumber("volume"), core.fetchFlag("pause")))
            }
        }
        XCTAssertNil(afterDispose.0)
        XCTAssertNil(afterDispose.1)
    }

    // MARK: Background filtering (section 6.11)

    func testBackgroundDeliversOnlyCriticalPropertiesAndNoLogMessages() async throws {
        let core = VividPlayerCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        core.isBackgrounded = true
        core.setLogLevel("v")
        for (name, format) in [("pause", "flag"), ("time-pos", "double"), ("duration", "double"),
                               ("eof-reached", "flag"), ("track-list", "node"), ("volume", "double"),
                               ("chapter-list", "node")] {
            core.observeProperty(name, format: format)
        }
        try await waitUntil("critical properties") {
            recorder.propertyNames.isSuperset(of: ["pause", "time-pos", "duration", "eof-reached"])
        }
        _ = try loadedId(await command(core, ["loadfile", missingPath()]))
        try await waitUntil("end of file") { !recorder.events(named: "end-file").isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(recorder.events(named: "start-file").isEmpty, "events still arrive")
        XCTAssertFalse(recorder.propertyNames.contains("track-list"))
        XCTAssertFalse(recorder.propertyNames.contains("volume"))
        XCTAssertFalse(recorder.propertyNames.contains("chapter-list"))
        XCTAssertTrue(recorder.events(named: "log-message").isEmpty)

        // Returning delivers them again; nothing dropped is replayed.
        core.isBackgrounded = false
        core.observeProperty("track-list", format: "node")
        _ = try loadedId(await command(core, ["loadfile", missingPath()]))
        try await waitUntil("deliveries after returning") {
            recorder.propertyNames.contains("track-list") && !recorder.events(named: "log-message").isEmpty
        }
        XCTAssertFalse(recorder.propertyNames.contains("volume"))
    }

    // MARK: Preload audio choice (section 6.15)

    func testPreloadHookChoosesAudioOnTheEventQueueWithoutStalling() async throws {
        let core = PreloadCore()
        let recorder = EngineRecorder()
        try start(core, recorder)
        core.observeProperty("aid", format: "string")
        _ = try loadedId(await command(core, ["loadfile", try fixturePath()]))
        try await waitUntil("file loaded") { !recorder.events(named: "file-loaded").isEmpty }
        let calls = core.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.onEventQueue, true)
        let audio = calls.first?.tracks.first { $0["type"] as? String == "audio" }
        XCTAssertEqual(audio?["id"] as? Int64, 1)
        try await waitUntil("aid") { recorder.values(named: "aid").contains { $0.value as? String == "1" } }
    }

    func testPreloadHookWithNoChoiceStillLoads() async throws {
        let core = PreloadCore()
        core.choice = nil
        let recorder = EngineRecorder()
        try start(core, recorder)
        _ = try loadedId(await command(core, ["loadfile", try fixturePath()]))
        try await waitUntil("file loaded") { !recorder.events(named: "file-loaded").isEmpty }
        XCTAssertEqual(core.calls.count, 1)
    }

    func testPreloadHookIsNotRegisteredWhenSwitchedOff() async throws {
        let core = PreloadCore()
        core.selects = false
        let recorder = EngineRecorder()
        try start(core, recorder)
        _ = try loadedId(await command(core, ["loadfile", try fixturePath()]))
        try await waitUntil("file loaded") { !recorder.events(named: "file-loaded").isEmpty }
        XCTAssertTrue(core.calls.isEmpty)
    }

    // MARK: Teardown (section 6.17)

    func testReleasingALiveCoreWithoutDisposeDoesNotCrash() async throws {
        let recorder = EngineRecorder()
        var core: VividPlayerCore? = VividPlayerCore()
        let host = try start(try XCTUnwrap(core), recorder, disposeAfterwards: false)
        _ = try loadedId(await command(try XCTUnwrap(core), ["loadfile", try fixturePath()]))
        try await waitUntil("playback restart") { !recorder.events(named: "playback-restart").isEmpty }
        weak var released = core
        core = nil
        try await waitUntil("release") { released == nil }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(host.subviews.isEmpty, "deinit disposed and removed the container")

        // The process is still healthy enough for another context.
        let next = VividPlayerCore()
        let nextRecorder = EngineRecorder()
        try start(next, nextRecorder)
        guard case .success = await complete({ next.getPropertyAsync("volume", completion: $0) }).result else {
            return XCTFail("a new core could not answer")
        }
    }

    func testTwoCoresRunSideBySide() async throws {
        let first = VividPlayerCore()
        let firstRecorder = EngineRecorder()
        try start(first, firstRecorder, disposeAfterwards: false)
        let second = VividPlayerCore()
        let secondRecorder = EngineRecorder()
        try start(second, secondRecorder)
        XCTAssertFalse(first.eventQueue === second.eventQueue)

        _ = try loadedId(await command(first, ["loadfile", try fixturePath()]))
        _ = try loadedId(await command(second, ["loadfile", try fixturePath()]))
        try await waitUntil("both restarts") {
            !firstRecorder.events(named: "playback-restart").isEmpty
                && !secondRecorder.events(named: "playback-restart").isEmpty
        }
        XCTAssertNotNil(first.sampleBufferDisplayLayer)
        XCTAssertFalse(first.sampleBufferDisplayLayer === second.sampleBufferDisplayLayer)

        first.delegate = nil
        let disposed = expectation(description: "first dispose")
        first.dispose(preserveDisplayCriteria: true) { disposed.fulfill() }
        await fulfillment(of: [disposed], timeout: 10)

        let answer = await complete { second.getPropertyAsync("volume", completion: $0) }
        guard case .success = answer.result else { return XCTFail("the second core stopped answering") }
        let before = secondRecorder.events.count
        guard case .success = await command(second, ["seek", "0", "absolute"]) else { return XCTFail("seek failed") }
        try await waitUntil("second restart") { secondRecorder.events(named: "playback-restart").count >= 2 }
        XCTAssertGreaterThan(secondRecorder.events.count, before)
        XCTAssertNotNil(second.sampleBufferDisplayLayer)
    }
}
