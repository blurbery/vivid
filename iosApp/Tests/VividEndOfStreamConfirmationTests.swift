// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Combine
import Foundation
import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// The adapter reports an end of stream only after a short confirmation
/// window in which a queued error, a stop, a new load or a seek still wins,
/// and the controller publishes one end per pass through the media.
@MainActor
final class VividEndOfStreamConfirmationTests: XCTestCase {
    private struct WaitTimedOut: Error {}

    /// Counts the adapter's transitions into the ended state.
    private final class EndLog {
        var ended = 0
    }

    /// Comfortably past the adapter's 250 ms confirmation window.
    private let pastWindow: Duration = .milliseconds(800)
    /// Well inside the confirmation window.
    private let insideWindow: Duration = .milliseconds(60)
    private let naturalEnd: [String: Any] = ["reason": 0]
    private let stoppedEnd: [String: Any] = ["reason": 2]
    private let failedEnd: [String: Any] = ["reason": 4, "error": -13]

    // MARK: Confirmation window

    func testEndFlagThenNaturalEndFileEndsExactlyOnce() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveProperty("eof-reached", value: true)
        player.debugReceiveEvent("end-file", data: naturalEnd)
        try await waitUntil("the confirmed end") { player.state == .ended }
        player.debugReceiveProperty("eof-reached", value: true)
        player.debugReceiveEvent("end-file", data: naturalEnd)
        try await Task.sleep(for: pastWindow)

        XCTAssertEqual(log.ended, 1)
        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(player.playbackPhase, .ended)
        XCTAssertNil(player.errorInfo)
    }

    func testEndFlagThenFailedEndFileRecordsTheError() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveProperty("eof-reached", value: true)
        player.debugReceiveEvent("end-file", data: failedEnd)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertEqual(player.errorInfo?.kind, .softwarePipelineFailed)
    }

    func testFailedEndFileThenEndFlagRecordsTheError() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveEvent("end-file", data: failedEnd)
        player.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertEqual(player.errorInfo?.kind, .softwarePipelineFailed)
    }

    func testFailedEndFileInsideTheWindowWins() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: insideWindow)
        player.debugReceiveEvent("end-file", data: failedEnd)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertEqual(player.errorInfo?.kind, .softwarePipelineFailed)
    }

    func testEndFlagClearedInsideTheWindowIsNotAnEnd() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: insideWindow)
        player.debugReceiveProperty("eof-reached", value: false)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertNil(player.errorInfo)
    }

    func testEndFlagBeforeFileLoadedIsALoadFailure() async throws {
        let (player, log) = makePlayer(fileLoaded: false, firstFrame: false)

        player.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertEqual(player.errorInfo?.kind, .softwarePipelineFailed)
        XCTAssertEqual(player.errorInfo?.message, "The media stream ended before playback started.")
    }

    func testEndFlagBeforeTheFirstFrameIsAStartUpFailure() async throws {
        let (player, log) = makePlayer(fileLoaded: true, firstFrame: false)
        XCTAssertTrue(player.isSessionReady)

        player.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertEqual(player.errorInfo?.kind, .softwarePipelineFailed)
        XCTAssertEqual(player.errorInfo?.message, "The media stream ended before playback started.")
    }

    func testEndFlagThenStoppedEndFileIsNotAnEnd() async throws {
        let (player, log) = makePlayer()

        player.debugReceiveProperty("eof-reached", value: true)
        player.debugReceiveEvent("end-file", data: stoppedEnd)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(player, log)
        XCTAssertNil(player.errorInfo)
    }

    /// These two need a real source: a new load and a seek both act on the
    /// media core, which a player without a source does not have.
    func testNewLoadInsideTheWindowIsNotAnEnd() async throws {
        let (controller, url) = try makeSyntheticController()
        try await loadPaused(controller, url)
        let log = observeEnds(controller.engine)

        controller.engine.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: insideWindow)
        let replacement = try VividLoadSpec(directURL: url, headers: [:], startPosition: 0, audioOnly: false)
        let epoch = controller.beginLoad(replacement, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(controller.engine, log)
        XCTAssertNil(controller.engine.errorInfo)
    }

    func testSeekInsideTheWindowIsNotAnEnd() async throws {
        let (controller, url) = try makeSyntheticController()
        try await loadPaused(controller, url)
        let log = observeEnds(controller.engine)

        controller.engine.debugReceiveProperty("eof-reached", value: true)
        try await Task.sleep(for: insideWindow)
        await controller.engine.seek(to: 0.5)
        try await Task.sleep(for: pastWindow)

        assertNeverEnded(controller.engine, log)
        XCTAssertNil(controller.engine.errorInfo)
    }

    // MARK: Rewinding re-arms the end

    func testLocalRewindAfterTheEndPublishesTheNextEnd() async throws {
        let (controller, url) = try makeSyntheticController()
        var ends = 0
        controller.onEvent = { event in
            if case .ended = event.event { ends += 1 }
        }
        let spec = try VividLoadSpec(directURL: url, headers: [:], startPosition: 0, audioOnly: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.play()
        try await waitUntil("the first end") { ends == 1 }

        let result = await controller.seek(toSourceTime: 0.5)
        guard case .completed(let landed) = result else {
            return XCTFail("A local rewind did not complete: \(result)")
        }
        XCTAssertEqual(landed, 0.5, accuracy: 0.1)
        XCTAssertEqual(controller.engine.clock.currentTime, 0.5, accuracy: 0.1)
        XCTAssertNotEqual(controller.engine.state, .ended)
        controller.play()
        try await waitUntil("the second end") { ends == 2 }

        XCTAssertEqual(controller.activeLoadEpoch, epoch)
        XCTAssertNil(controller.engine.errorInfo)
    }

    func testSeekNeedingAReplanLeavesThePublishedEndAlone() async throws {
        let (controller, url) = try makeSyntheticController()
        var ends = 0
        controller.onEvent = { event in
            if case .ended = event.event { ends += 1 }
        }
        // No local seeking: every seek needs a server replan.
        let sessionId = "session-synthetic"
        let spec = try VividLoadSpec(
            validating: PlaybackEndFixtures.plan(sessionId: sessionId, durationSeconds: 2, canSeekAnywhere: false),
            sessionID: sessionId, matchContentEnabled: false, sourceURLOverride: url, panelIsInHDRMode: false
        )
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        controller.play()
        try await waitUntil("the first end") { ends == 1 }

        let result = await controller.seek(toSourceTime: 0.5)
        XCTAssertEqual(result, .requiresReplan(sourceSeconds: 0.5))

        // Rewind the engine itself and play out again. Only a controller the
        // replan seek had re-armed would publish this second end.
        await controller.engine.seek(to: 0.5)
        XCTAssertNotEqual(controller.engine.state, .ended)
        controller.play()
        try await waitUntil("the engine's second end") { controller.engine.state == .ended }
        try await Task.sleep(for: pastWindow)

        XCTAssertEqual(ends, 1)
        XCTAssertEqual(controller.activeLoadEpoch, epoch)
    }

    // MARK: - Helpers

    /// A player with no source, driven only through its core's delegate
    /// events. By default the file has loaded and shown its first frame.
    private func makePlayer(fileLoaded: Bool = true, firstFrame: Bool = true) -> (VividMPVPlayer, EndLog) {
        let player = VividMPVPlayer()
        let log = observeEnds(player)
        addTeardownBlock { @MainActor in player.stop() }
        if fileLoaded { player.debugReceiveEvent("file-loaded") }
        if firstFrame { player.debugReceiveEvent("playback-restart") }
        return (player, log)
    }

    private func observeEnds(_ player: VividMPVPlayer) -> EndLog {
        let log = EndLog()
        let subscription = player.$state.sink { state in
            if state == .ended { log.ended += 1 }
        }
        addTeardownBlock { @MainActor in subscription.cancel() }
        return log
    }

    /// A muted controller whose surface is in a window, with the synthetic
    /// two-second fixture.
    private func makeSyntheticController() throws -> (VividPlaybackController, URL) {
        let controller = try VividPlaybackController()
        controller.setMuted(true)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        }
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(controller.engine.surface)
        controller.engine.surface.frame = host.view.bounds
        controller.engine.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            controller.onEvent = nil
            controller.stop()
            window.isHidden = true
            window.rootViewController = nil
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "v3_h264_aac", withExtension: "mp4"))
        return (controller, url)
    }

    /// Opens the fixture paused on its first frame.
    private func loadPaused(_ controller: VividPlaybackController, _ url: URL) async throws {
        let spec = try VividLoadSpec(directURL: url, headers: [:], startPosition: 0, audioOnly: false)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        let engine = controller.engine
        do {
            try await waitUntil("the first frame", timeout: 3, failing: false) { engine.hasFirstFrameReadyForDisplay }
        } catch {
            // Some cores show the first frame only once playback starts.
            controller.play()
            try await waitUntil("the first frame") { engine.hasFirstFrameReadyForDisplay }
            controller.pause()
        }
        XCTAssertTrue(engine.isSessionReady)
        XCTAssertNotEqual(engine.state, .ended)
    }

    private func assertNeverEnded(_ player: VividMPVPlayer, _ log: EndLog,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(log.ended, 0, file: file, line: line)
        XCTAssertNotEqual(player.state, .ended, file: file, line: line)
    }

    private func waitUntil(_ description: String, timeout: Double = 15, failing: Bool = true,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                if failing { XCTFail("Timed out waiting for \(description)") }
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
