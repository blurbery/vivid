// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// How the player view model ends an item. An end of stream that the
/// timeline cannot confirm is recovered, never completed; a confirmed end
/// completes the item exactly once; and Next Up advances only from settled
/// playback.
///
/// "Silo" is a server-planned load (prepared, and committed unless a case
/// says otherwise). "Other" has no server plan, as with Emby, Jellyfin and
/// direct play. The player's own session bridge holds no server session in
/// these tests, so it refuses every replan and a same-route reopen settles
/// without reaching the network.
@MainActor
final class PlaybackEndRecoveryTests: XCTestCase {
    private enum Provider: CustomStringConvertible {
        case silo, other
        var description: String { self == .silo ? "Silo" : "other" }
    }

    /// How a Silo same-route reopen answers an early end.
    private enum Reopen {
        /// The reopen starts.
        case accepted
        /// The reopen is refused: an earlier reopen had no playback since.
        case refused
        /// The plan cannot reopen with refreshed headers at all.
        case unavailable
    }

    private struct Fixture {
        let model: PlayerViewModel
        let recorder: PlayerTestRecorder
        let epoch: VividPlaybackController.LoadEpoch
    }

    private let itemDuration: Double = 3_600
    private let contentId = "fixture-episode-1"
    private let nextContentId = "fixture-episode-2"
    private let sessionId = "session-v3"
    private let earlyEndMessage = PlayerViewModel.prematureSourceEndMessage

    // MARK: 1. Confirmed-end window

    func testConfirmedEndAcceptsOnlyEightSecondsEitherSideOfTheDuration() {
        for position in [3_592.0, 3_599, 3_600, 3_601, 3_608] {
            XCTAssertTrue(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: position, duration: 3_600),
                          "\(position) of 3600")
        }
        for position in [3_591.0, 3_609, 3_546, 1_200, 0] {
            XCTAssertFalse(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: position, duration: 3_600),
                           "\(position) of 3600")
        }
        XCTAssertFalse(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: 7_190, duration: 7_200))
        for duration in [0.0, .nan, .infinity] {
            XCTAssertFalse(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: 100, duration: duration),
                           "duration \(duration)")
            XCTAssertFalse(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: duration, duration: duration),
                           "position and duration \(duration)")
        }
        for position in [Double.nan, .infinity] {
            XCTAssertFalse(PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: position, duration: 3_600),
                           "position \(position)")
        }
    }

    // MARK: 2. An unexpected end does not complete the item

    func testUnexpectedEndNeverCompletesTheItem() async throws {
        let timelines: [(position: Double, duration: Double)] = [
            (1_200, 3_600), (3_546, 3_600), (7_190, 7_200), (0, 3_600),
            (100, 0), (100, .nan), (100, .infinity), (.nan, 3_600), (.infinity, 3_600),
        ]
        let variants: [(Provider, Reopen)] = [(.silo, .refused), (.silo, .unavailable), (.other, .refused)]
        for timeline in timelines {
            for (provider, reopen) in variants {
                let label = "\(provider) reopen \(reopen) at \(timeline.position) of \(timeline.duration)"
                let fixture = try makeFixture(provider, reopen: reopen,
                                              position: timeline.position, duration: timeline.duration)
                let model = fixture.model
                showPreEndNextUp(model)

                deliverEnd(fixture)

                XCTAssertFalse(model.hasReachedEndOfFile, label)
                assertNextUpHidden(model, label)
                assertSamePosition(model.currentTime, timeline.position, label)
                if provider == .silo {
                    // Recovery has not torn anything down yet, so a pause
                    // here could only have come from end handling.
                    XCTAssertTrue(model.vividPlaybackController.shouldPlayWhenReady, label)
                    XCTAssertFalse(sameRouteReopenStarted(model), label)
                }

                await settleRecovery(model)

                let entries = fixture.recorder.entries
                XCTAssertFalse(model.hasReachedEndOfFile, label)
                XCTAssertEqual(postrolls(entries), 0, label)
                XCTAssertNil(model.completedPlaybackContentId, label)
                XCTAssertEqual(watchedMutations(entries), 0, label)
                XCTAssertEqual(progressWrites(entries), 0, label)
                assertSamePosition(model.currentTime, timeline.position, label)
                assertNextUpHidden(model, label)
                switch provider {
                case .silo:
                    XCTAssertEqual(entries.filter { $0 == .sameRouteReopenRequest }.count, 1, label)
                    XCTAssertEqual(serverReplans(entries), 1, label)
                case .other:
                    XCTAssertEqual(serverReplans(entries), 0, label)
                    XCTAssertEqual(terminalErrors(entries), [earlyEndMessage], label)
                    XCTAssertEqual(model.error, earlyEndMessage, label)
                }
            }
        }
    }

    // MARK: 3. A natural end completes exactly once

    func testNaturalEndCompletesOnceAndStartsTheEndedCountdown() throws {
        for provider in [Provider.silo, .other] {
            for position in [3_592.0, 3_599, 3_600, 3_601] {
                let label = "\(provider) at \(position)"
                let fixture = try makeFixture(provider, position: position)
                let model = fixture.model
                XCTAssertFalse(model.showNextUpScreen, label)

                deliverEnd(fixture)
                deliverEnd(fixture)

                let entries = fixture.recorder.entries
                XCTAssertEqual(entries.filter { $0 == .postroll(videoEnded: true) }.count, 1, label)
                XCTAssertEqual(postrolls(entries), 1, label)
                XCTAssertTrue(model.showNextUpScreen, label)
                XCTAssertTrue(model.nextUpScreenVideoEnded, label)
                XCTAssertTrue(model.hasReachedEndOfFile, label)
                XCTAssertEqual(model.completedPlaybackContentId, contentId, label)
                XCTAssertEqual(entries.filter { $0 == .watchedMutation(contentId: contentId) }.count, 1, label)
                XCTAssertEqual(watchedMutations(entries), 1, label)
                XCTAssertEqual(progressReports(entries).map(\.position), [3_600], label)
                XCTAssertEqual(progressReports(entries).map(\.completedContentId), [contentId], label)
                XCTAssertEqual(model.currentTime, 3_600, label)
                XCTAssertEqual(model.nextUpCountdownSeconds, 10, label)
                XCTAssertEqual(model.nextUpCountdownTotalSeconds, 10, label)
                XCTAssertNotNil(model.nextUpCountdownTask, label)
                XCTAssertEqual(terminalErrors(entries), [], label)
                XCTAssertEqual(serverReplans(entries), 0, label)
            }
        }
    }

    // MARK: 4. An error is never a completion

    func testPlaybackErrorNeverCompletesEvenAtTheEnd() async throws {
        for position in [1_200.0, 3_546, 3_599, 3_600] {
            let label = "error at \(position)"
            let fixture = try makeFixture(.silo, position: position)
            let model = fixture.model
            showPreEndNextUp(model)
            let countdown = startDummyCountdown(model)

            model.handlePlaybackError("The video decoder stopped producing frames.")

            assertNextUpHidden(model, label)
            XCTAssertTrue(countdown.isCancelled, label)
            await settleRecovery(model)

            let entries = fixture.recorder.entries
            XCTAssertEqual(serverReplans(entries), 1, label)
            XCTAssertFalse(model.hasReachedEndOfFile, label)
            XCTAssertEqual(postrolls(entries), 0, label)
            XCTAssertNil(model.completedPlaybackContentId, label)
            XCTAssertEqual(watchedMutations(entries), 0, label)
            assertNextUpHidden(model, label)
        }
    }

    // MARK: 5. A refused audio session stops at Retry

    func testRefusedAudioSessionDuringPlaybackStopsAtRetry() async throws {
        let failure = PlaybackErrorInfo(
            kind: .audioSessionUnavailable,
            message: "Audio output isn't available right now. Try again in a moment.",
            underlyingDomain: NSOSStatusErrorDomain,
            underlyingCode: 561_017_449
        )
        for provider in [Provider.silo, .other] {
            let label = "\(provider)"
            let fixture = try makeFixture(provider, reopen: .accepted)
            let model = fixture.model
            XCTAssertTrue(model.isVividLoadEstablished, label)
            XCTAssertFalse(model.freshLoadOwnsFailureHandling, label)

            model.handleVividFailure(failure)
            await settleRecovery(model)

            let entries = fixture.recorder.entries
            XCTAssertEqual(serverReplans(entries), 0, label)
            XCTAssertFalse(entries.contains(.sameRouteReopenRequest), label)
            XCTAssertEqual(terminalErrors(entries), [failure.message], label)
            XCTAssertEqual(model.error, failure.message, label)
        }
    }

    // MARK: 6. Automatic Next Up waits for settled playback

    func testAutomaticNextUpWaitsForSettledPlayback() throws {
        let unsettled: [(String, @MainActor (PlayerViewModel) -> Void)] = [
            ("buffering", { $0.isBuffering = true }),
            ("loading", { $0.isLoading = true }),
        ]
        for (label, unsettle) in unsettled {
            let fixture = try makeFixture(.other, position: 3_590)
            let model = fixture.model
            unsettle(model)

            model.updateNextUpPresentation(for: 3_590)

            XCTAssertEqual(postrolls(fixture.recorder.entries), 0, label)
            XCTAssertFalse(model.showNextUpScreen, label)
            XCTAssertNil(model.nextUpCountdownSeconds, label)
        }

        let fixture = try makeFixture(.other, position: 3_590)
        let model = fixture.model
        model.updateNextUpPresentation(for: 3_590)

        XCTAssertEqual(fixture.recorder.entries, [.postroll(videoEnded: false)])
        XCTAssertTrue(model.showNextUpScreen)
        XCTAssertFalse(model.nextUpScreenVideoEnded)
        XCTAssertEqual(model.nextUpPresentationSource, .automatic)
        XCTAssertEqual(model.nextUpCountdownSeconds, 10)
    }

    // MARK: 7. A visible countdown does not move in unsettled states

    func testVisibleNextUpCountdownHoldsInUnsettledStates() throws {
        for (label, unsettle) in unsettledStates() + [("load epoch not started", { $0.startedVividLoadEpoch = nil })] {
            let fixture = try makeFixture(.other, position: 3_599.9)
            let model = fixture.model
            showPreEndNextUp(model, countdown: 1)
            unsettle(model)
            let loads = model.freshLoadGeneration

            model.updateNextUpPresentation(for: 3_599.9)

            XCTAssertEqual(model.nextUpCountdownSeconds, 1, label)
            XCTAssertEqual(postrolls(fixture.recorder.entries), 0, label)
            XCTAssertEqual(model.freshLoadGeneration, loads, label)
            XCTAssertEqual(model.lastLoadRequest?.contentId, contentId, label)
        }

        let fixture = try makeFixture(.other, position: 3_599.9)
        let model = fixture.model
        showPreEndNextUp(model, countdown: 1)
        let loads = model.freshLoadGeneration

        model.updateNextUpPresentation(for: 3_599.9)
        model.updateNextUpPresentation(for: 3_599.9)

        XCTAssertEqual(model.freshLoadGeneration, loads + 1)
        XCTAssertEqual(model.lastLoadRequest?.contentId, nextContentId)
    }

    // MARK: 8. The HUD cannot bypass those guards

    func testHUDNextUpActionCannotPlayFromUnsettledStates() throws {
        for (label, unsettle) in unsettledStates() {
            let fixture = try makeFixture(.other, position: 3_599.9)
            let model = fixture.model
            unsettle(model)
            let loads = model.freshLoadGeneration

            model.showNextUpNow()

            XCTAssertEqual(model.freshLoadGeneration, loads, label)
            XCTAssertEqual(model.lastLoadRequest?.contentId, contentId, label)
        }

        let fixture = try makeFixture(.other, position: 3_599.9)
        let model = fixture.model
        let loads = model.freshLoadGeneration

        model.showNextUpNow()

        XCTAssertEqual(model.freshLoadGeneration, loads + 1)
        XCTAssertEqual(model.lastLoadRequest?.contentId, nextContentId)
    }

    // MARK: 9. An end deferred while a load owns failure handling

    func testEndDeferredWhileALoadOwnsFailureHandlingRecoversOnce() async throws {
        for owner in ["fresh load", "uncommitted plan"] {
            let fixture = try makeFixture(.silo, reopen: .refused, committed: owner == "fresh load")
            let model = fixture.model
            if owner == "fresh load" { model.freshLoadOwnsFailureHandling = true }

            deliverEnd(fixture)

            XCTAssertEqual(fixture.recorder.entries, [], owner)
            XCTAssertNil(model.error, owner)
            XCTAssertNil(model.protocolV3ReplanTask, owner)
            XCTAssertEqual(model.pendingUnexpectedEndEpoch, fixture.epoch, owner)

            if owner == "fresh load" {
                model.freshLoadOwnsFailureHandling = false
            } else {
                model.markProtocolV3VividLoadCommitted()
            }
            model.recoverPendingUnexpectedEnd()
            model.recoverPendingUnexpectedEnd()

            XCTAssertNil(model.pendingUnexpectedEndEpoch, owner)
            XCTAssertFalse(sameRouteReopenStarted(model), owner)
            await settleRecovery(model)
            let entries = fixture.recorder.entries
            XCTAssertEqual(entries.filter { $0 == .sameRouteReopenRequest }.count, 1, owner)
            XCTAssertEqual(serverReplans(entries), 1, owner)
            XCTAssertEqual(postrolls(entries), 0, owner)
            XCTAssertNil(model.pendingUnexpectedEndEpoch, owner)
        }
    }

    func testEndDeferredForAReplacedLoadIsDropped() async throws {
        for owner in ["fresh load", "uncommitted plan"] {
            let fixture = try makeFixture(.silo, reopen: .refused, committed: owner == "fresh load")
            let model = fixture.model
            if owner == "fresh load" { model.freshLoadOwnsFailureHandling = true }
            deliverEnd(fixture)
            XCTAssertEqual(model.pendingUnexpectedEndEpoch, fixture.epoch, owner)

            let replacement = try siloSpec()
            model.activeVividLoadEpoch = model.vividPlaybackController.beginLoad(replacement)
            if owner == "fresh load" {
                model.freshLoadOwnsFailureHandling = false
            } else {
                model.markProtocolV3VividLoadCommitted()
            }
            model.recoverPendingUnexpectedEnd()

            XCTAssertNil(model.pendingUnexpectedEndEpoch, owner)
            await settleRecovery(model)
            XCTAssertEqual(fixture.recorder.entries, [], owner)
            XCTAssertNil(model.error, owner)
        }
    }

    // MARK: 10. The same-route reopen comes before server recovery

    func testSameRouteReopenComesBeforeServerRecovery() async throws {
        for ownedByFreshLoad in [false, true] {
            for reopen in [Reopen.accepted, .refused] {
                let label = "reopen \(reopen), fresh load owned \(ownedByFreshLoad)"
                let fixture = try makeFixture(.silo, reopen: reopen)
                let model = fixture.model
                if ownedByFreshLoad { model.freshLoadOwnsFailureHandling = true }

                deliverEnd(fixture)
                if ownedByFreshLoad {
                    XCTAssertEqual(fixture.recorder.entries, [], label)
                    model.freshLoadOwnsFailureHandling = false
                    model.recoverPendingUnexpectedEnd()
                }
                XCTAssertEqual(fixture.recorder.entries.first, .sameRouteReopenRequest, label)
                XCTAssertEqual(sameRouteReopenStarted(model), reopen == .accepted, label)
                await settleRecovery(model)

                let entries = fixture.recorder.entries
                XCTAssertEqual(postrolls(entries), 0, label)
                XCTAssertNil(model.completedPlaybackContentId, label)
                XCTAssertEqual(watchedMutations(entries), 0, label)
                XCTAssertFalse(model.hasReachedEndOfFile, label)
                switch reopen {
                case .accepted:
                    XCTAssertEqual(entries, [.sameRouteReopenRequest], label)
                    XCTAssertNil(model.error, label)
                case .refused, .unavailable:
                    XCTAssertEqual(entries.filter { $0 == .sameRouteReopenRequest }.count, 1, label)
                    XCTAssertEqual(serverReplans(entries), 1, label)
                }
            }
        }
    }

    // MARK: 11. Replan refused, or a replan already running

    func testRefusedOrRunningReplanStopsOnceAndHidesNextUp() async throws {
        let typed = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Lucid playback failed (-13).")
        let deliveries: [(String, @MainActor (PlayerViewModel) -> Void)] = [
            ("typed failure", { $0.handleVividFailure(typed) }),
            ("playback error", { $0.handlePlaybackError(typed.message) }),
            ("typed failure then playback error", {
                $0.handleVividFailure(typed)
                $0.handlePlaybackError(typed.message)
            }),
        ]
        for (label, deliver) in deliveries {
            let refused = try makeFixture(.silo)
            showPreEndNextUp(refused.model)
            deliver(refused.model)
            await settleRecovery(refused.model)
            XCTAssertEqual(serverReplans(refused.recorder.entries), 1, "refused, \(label)")
            XCTAssertEqual(terminalErrors(refused.recorder.entries), [typed.message], "refused, \(label)")
            XCTAssertEqual(refused.model.error, typed.message, "refused, \(label)")
            assertNextUpHidden(refused.model, "refused, \(label)")

            let running = try makeFixture(.silo)
            showPreEndNextUp(running.model)
            let inFlight = longRunningTask()
            running.model.protocolV3ReplanTask = inFlight
            deliver(running.model)
            XCTAssertEqual(running.recorder.entries, [], "running, \(label)")
            XCTAssertNil(running.model.error, "running, \(label)")
            XCTAssertEqual(running.model.protocolV3ReplanTask, inFlight, "running, \(label)")
            assertNextUpHidden(running.model, "running, \(label)")
            inFlight.cancel()
        }
    }

    // MARK: 12. A late clock tick after a terminal failure

    func testClockTickAfterTerminalFailureShowsNoNextUp() throws {
        let fixture = try makeFixture(.other, position: 3_599)
        let model = fixture.model

        model.handlePlaybackError("The media source stopped responding.")
        XCTAssertEqual(terminalErrors(fixture.recorder.entries), ["The media source stopped responding."])
        model.updateNextUpPresentation(for: 3_599)

        XCTAssertEqual(postrolls(fixture.recorder.entries), 0)
        XCTAssertFalse(model.showNextUpScreen)
        XCTAssertNil(model.nextUpCountdownSeconds)
    }

    // MARK: 13. A truncated offline stream

    func testTruncatedOfflineStreamStopsAtRetry() throws {
        for playing in [true, false] {
            let label = playing ? "playing" : "paused"
            let fixture = try makeFixture(.other, offline: true)
            let model = fixture.model
            if !playing {
                model.vividPlaybackController.pause()
                model.isPlaying = false
            }

            deliverEnd(fixture)

            let entries = fixture.recorder.entries
            XCTAssertEqual(terminalErrors(entries), [earlyEndMessage], label)
            XCTAssertEqual(model.error, earlyEndMessage, label)
            XCTAssertEqual(serverReplans(entries), 0, label)
            XCTAssertEqual(watchedMutations(entries), 0, label)
            XCTAssertFalse(offlineWrites(entries).contains { $0.completed }, label)
            XCTAssertNil(model.completedPlaybackContentId, label)
            XCTAssertEqual(postrolls(entries), 0, label)
            XCTAssertFalse(model.hasReachedEndOfFile, label)
        }
    }

    // MARK: 14. Recovery keeps the user's autoplay choice

    func testRecoveryKeepsTheUsersAutoplayChoice() async throws {
        for cancelledByUser in [false, true] {
            let label = cancelledByUser ? "autoplay cancelled" : "autoplay on"
            let fixture = try makeFixture(.silo, reopen: .accepted)
            let model = fixture.model
            showPreEndNextUp(model)
            if cancelledByUser { model.cancelNextUpAutoPlay() }

            deliverEnd(fixture)
            XCTAssertTrue(sameRouteReopenStarted(model), label)
            await settleRecovery(model)
            XCTAssertEqual(fixture.recorder.entries, [.sameRouteReopenRequest], label)
            assertNextUpHidden(model, label)

            // The reopened stream then plays to its real end.
            model.currentTime = itemDuration
            deliverEnd(fixture)

            let entries = fixture.recorder.entries
            XCTAssertEqual(postrolls(entries), 1, label)
            XCTAssertEqual(entries.filter { $0 == .postroll(videoEnded: true) }.count, 1, label)
            XCTAssertTrue(model.showNextUpScreen, label)
            XCTAssertEqual(model.nextUpAutoplayCancelled, cancelledByUser, label)
            if cancelledByUser {
                XCTAssertNil(model.nextUpCountdownSeconds, label)
                XCTAssertNil(model.nextUpCountdownTask, label)
            } else {
                XCTAssertEqual(model.nextUpCountdownSeconds, 10, label)
                XCTAssertNotNil(model.nextUpCountdownTask, label)
            }
        }
    }

    // MARK: 15. The final position is written once

    func testNaturalEndWritesTheFinalPositionOnce() async throws {
        for offline in [false, true] {
            for completedEarlier in [false, true] {
                let label = "\(offline ? "offline" : "online"), completed earlier \(completedEarlier)"
                let fixture = try makeFixture(.other, position: itemDuration, offline: offline)
                let model = fixture.model
                if completedEarlier { model.completedPlaybackContentId = contentId }

                deliverEnd(fixture)
                deliverEnd(fixture)
                await model.naturalEndProgressTask?.value

                let entries = fixture.recorder.entries
                if offline {
                    XCTAssertEqual(offlineWrites(entries).map(\.position), [3_600], label)
                    XCTAssertEqual(progressReports(entries).count, 0, label)
                } else {
                    XCTAssertEqual(progressReports(entries).map(\.position), [3_600], label)
                    XCTAssertEqual(offlineWrites(entries).count, 0, label)
                }
                XCTAssertEqual(watchedMutations(entries), completedEarlier ? 0 : 1, label)
                XCTAssertEqual(model.completedPlaybackContentId, contentId, label)
            }
        }
    }

    // MARK: 16. Credits skip

    func testCreditsSkipToTheDurationIsANaturalEnd() throws {
        let fixture = try makeFixture(.other, position: 1_200)
        let model = fixture.model

        model.performCreditsSkip(to: itemDuration)

        let entries = fixture.recorder.entries
        XCTAssertEqual(entries.filter { $0 == .postroll(videoEnded: true) }.count, 1)
        XCTAssertEqual(postrolls(entries), 1)
        XCTAssertTrue(model.hasReachedEndOfFile)
        XCTAssertEqual(model.completedPlaybackContentId, contentId)
        XCTAssertEqual(watchedMutations(entries), 1)
        XCTAssertEqual(progressReports(entries).map(\.position), [3_600])
        XCTAssertNil(model.seekTargetTime)
    }

    func testCreditsSkipBeforeTheDurationSeeks() throws {
        let fixture = try makeFixture(.other, position: 1_200)
        let model = fixture.model

        model.performCreditsSkip(to: 3_500)

        XCTAssertEqual(model.seekTargetTime, 3_500)
        XCTAssertEqual(model.currentTime, 3_500)
        XCTAssertNotNil(model.seekReplanTask)
        XCTAssertEqual(postrolls(fixture.recorder.entries), 0)
        XCTAssertFalse(model.hasReachedEndOfFile)
        XCTAssertNil(model.completedPlaybackContentId)
        XCTAssertEqual(watchedMutations(fixture.recorder.entries), 0)
    }

    // MARK: - Fixture

    private func makeFixture(
        _ provider: Provider,
        reopen: Reopen = .refused,
        committed: Bool = true,
        position: Double = 1_200,
        duration: Double = 3_600,
        offline: Bool = false
    ) throws -> Fixture {
        let settings = PlayerSettings.shared
        let savedAutoPlay = settings.autoPlayNextEpisode
        let savedPromptSeconds = settings.nextUpPromptSeconds
        settings.setAutoPlayNextEpisode(true)
        settings.setNextUpPromptSeconds(30)

        let model = PlayerViewModel()
        let recorder = PlayerTestRecorder()
        model.testRecorder = recorder
        let retained = TeardownBox(model)
        addTeardownBlock { @MainActor in
            if let model = retained.object {
                model.cleanup()
                await model.waitForCleanupCompletion()
            }
            // The model's deinit needs the main actor, so its last release
            // happens here rather than wherever XCTest finishes this block.
            retained.object = nil
            settings.setAutoPlayNextEpisode(savedAutoPlay)
            settings.setNextUpPromptSeconds(savedPromptSeconds)
        }

        let spec: VividLoadSpec
        switch provider {
        case .silo:
            let plan = PlaybackEndFixtures.plan(sessionId: sessionId, durationSeconds: itemDuration)
            var features = [PlaybackProtocolV3.planFeature]
            if reopen != .unavailable { features.append(PlaybackProtocolV3.headerAuthenticatedMediaFeature) }
            model.activePreparedProtocolV3 = PreparedPlaybackV3(
                playbackAttemptId: "apple:fixture-attempt",
                planAttemptId: "apple-plan:fixture-attempt",
                planAttemptKey: plan.planAttemptKey,
                // The current route, so a route notification during a test is
                // not mistaken for an output change.
                outputContextId: ApplePlaybackV3Capabilities.snapshot().outputContextId,
                serverFeatures: features,
                plan: plan
            )
            spec = try siloSpec()
        case .other where offline:
            spec = try VividLoadSpec(
                offlineURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fixture-episode.mp4"),
                startPosition: 0, audioOnly: false, panelIsInHDRMode: false
            )
        case .other:
            spec = try VividLoadSpec(
                directURL: try XCTUnwrap(URL(string: "https://media.example.invalid/fixture-episode.mp4")),
                headers: [:], startPosition: 0, audioOnly: false, panelIsInHDRMode: false
            )
        }
        let epoch = model.vividPlaybackController.beginLoad(spec, shouldPlayWhenReady: true)
        model.activeVividLoadEpoch = epoch
        model.establishedVividLoadEpoch = epoch
        model.startedVividLoadEpoch = epoch
        if provider == .silo, committed { model.committedProtocolV3LoadEpoch = epoch }
        if reopen == .refused {
            // A reopen earlier in this load with no playback since.
            XCTAssertTrue(model.prematureEndRecoveryGate.begin())
        }
        if offline {
            model.offlinePlaybackContext = .init(downloadId: "fixture-download", mediaItemId: contentId)
        } else {
            model.activePlaybackSessionId = sessionId
        }

        let detail = try makeWatchDetail()
        model.currentWatchDetail = detail
        model.currentSelectedVersion = makeVersion()
        model.lastLoadRequest = PlayerViewModel.LoadRequest(
            contentId: contentId, preferredFileId: 42, preferredAudioTrackIndex: nil,
            preferredSubtitleTrackIndex: nil, preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false
        )
        let next = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"fixture-episode-2","seasonNumber":1,"episodeNumber":2,"title":"The next one"}"#.utf8
        ))
        model.nextUpEpisode = PlayerNextUpEpisode(episode: next, seriesId: "fixture-series",
                                                  seriesTitle: "Fixture series")
        model.duration = duration
        model.currentTime = position
        model.isLoading = false
        model.isBuffering = false
        model.isPlaying = true
        XCTAssertTrue(recorder.entries.isEmpty)
        return Fixture(model: model, recorder: recorder, epoch: epoch)
    }

    private func siloSpec() throws -> VividLoadSpec {
        try VividLoadSpec(
            validating: PlaybackEndFixtures.plan(sessionId: sessionId, durationSeconds: itemDuration),
            sessionID: sessionId,
            matchContentEnabled: false,
            sourceURLOverride: URL(string: "https://media.example.invalid/stream/\(sessionId)"),
            panelIsInHDRMode: false
        )
    }

    private func makeWatchDetail() throws -> WatchDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WatchDetail.self, from: Data("""
            {"content_id":"\(contentId)","type":"episode","title":"Pilot","series_id":"fixture-series",
             "series_title":"Fixture series","season_number":1,"episode_number":1}
            """.utf8))
    }

    private func makeVersion() -> FileVersion {
        FileVersion(fileId: 42, fileName: "fixture.mp4", resolution: "1920x1080", codecVideo: "h264",
                    codecAudio: "aac", hdr: false, container: "mp4", fileSize: 1_000,
                    duration: itemDuration, bitrate: 8_000_000, videoTracks: nil, audioTracks: nil,
                    subtitleTracks: nil, chapters: nil)
    }

    // MARK: - Helpers

    /// The states in which Next Up must not advance, applied to an otherwise
    /// healthy, playing load.
    private func unsettledStates() -> [(String, @MainActor (PlayerViewModel) -> Void)] {
        [
            ("paused", { $0.isPlaying = false }),
            ("scrubbing", { $0.isScrubbing = true }),
            ("pending seek target", { $0.seekTargetTime = 3_599.9 }),
            ("engine seeking", { model in
                model.vividEngine.debugReceiveProperty("seeking", value: true)
                XCTAssertTrue(model.vividEngine.isSeeking)
            }),
            ("quality switch", { $0.isQualitySwitching = true }),
            ("error displayed", { $0.error = "Playback failed." }),
            ("server replan running", { model in
                model.protocolV3ReplanTask = self.longRunningTask()
            }),
        ]
    }

    /// The pre-end Next Up prompt, already counting down.
    private func showPreEndNextUp(_ model: PlayerViewModel, countdown: Int = 10) {
        model.showNextUpScreen = true
        model.nextUpScreenVideoEnded = false
        model.nextUpPresentationSource = .automatic
        model.nextUpCountdownSeconds = countdown
    }

    /// Stands in for a running ended-video countdown.
    private func startDummyCountdown(_ model: PlayerViewModel) -> Task<Void, Never> {
        let task = longRunningTask()
        model.nextUpCountdownTask = task
        return task
    }

    /// Stands in for work still in flight. Teardown cancels it.
    private func longRunningTask() -> Task<Void, Never> {
        Task { @MainActor in
            _ = try? await Task.sleep(for: .seconds(60))
        }
    }

    /// A started same-route reopen owns the stream generation it opened.
    private func sameRouteReopenStarted(_ model: PlayerViewModel) -> Bool {
        model.protocolV3ReplanTask != nil
            && model.authenticationReloadGeneration == model.streamLoadGeneration
    }

    /// Delivers the controller's end-of-stream event for the fixture's load.
    private func deliverEnd(_ fixture: Fixture) {
        fixture.model.handleVividEvent(.init(epoch: fixture.epoch, event: .ended))
    }

    /// Waits for in-flight reopen and replan work, including any chained step.
    private func settleRecovery(_ model: PlayerViewModel) async {
        for _ in 0..<8 {
            guard let task = model.protocolV3ReplanTask else { return }
            await task.value
            await Task.yield()
        }
    }

    private func assertNextUpHidden(_ model: PlayerViewModel, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(model.showNextUpScreen, label, file: file, line: line)
        XCTAssertNil(model.nextUpCountdownSeconds, label, file: file, line: line)
        XCTAssertNil(model.nextUpCountdownTask, label, file: file, line: line)
    }

    private func assertSamePosition(_ actual: Double, _ expected: Double, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        if expected.isNaN {
            XCTAssertTrue(actual.isNaN, label, file: file, line: line)
        } else {
            XCTAssertEqual(actual, expected, label, file: file, line: line)
        }
    }

    private func postrolls(_ entries: [PlayerTestRecorder.Entry]) -> Int {
        entries.filter { entry in
            guard case .postroll = entry else { return false }
            return true
        }.count
    }

    private func serverReplans(_ entries: [PlayerTestRecorder.Entry]) -> Int {
        entries.filter { entry in
            guard case .serverReplan = entry else { return false }
            return true
        }.count
    }

    private func watchedMutations(_ entries: [PlayerTestRecorder.Entry]) -> Int {
        entries.filter { entry in
            guard case .watchedMutation = entry else { return false }
            return true
        }.count
    }

    private func terminalErrors(_ entries: [PlayerTestRecorder.Entry]) -> [String] {
        entries.compactMap { entry -> String? in
            guard case .terminalError(let message) = entry else { return nil }
            return message
        }
    }

    private func progressReports(_ entries: [PlayerTestRecorder.Entry])
        -> [(position: Double, completedContentId: String?)] {
        entries.compactMap { entry -> (position: Double, completedContentId: String?)? in
            guard case .progressReport(let position, let completed) = entry else { return nil }
            return (position, completed)
        }
    }

    private func offlineWrites(_ entries: [PlayerTestRecorder.Entry]) -> [(position: Double, completed: Bool)] {
        entries.compactMap { entry -> (position: Double, completed: Bool)? in
            guard case .offlineProgress(let position, let completed) = entry else { return nil }
            return (position, completed)
        }
    }

    private func progressWrites(_ entries: [PlayerTestRecorder.Entry]) -> Int {
        progressReports(entries).count + offlineWrites(entries).count
    }
}

/// Holds an object for a teardown block, so the block can release it on the
/// main actor. XCTest finishes async teardown blocks off the main thread,
/// and the player view model and UIKit objects must not be freed there.
/// Only touched on the main actor.
final class TeardownBox<Object: AnyObject>: @unchecked Sendable {
    var object: Object?

    init(_ object: Object) {
        self.object = object
    }
}

/// Plans shared by the playback-end tests.
enum PlaybackEndFixtures {
    /// A validated original-file plan. Whether a load of it can reopen on
    /// the same route is set by the prepared plan's server features.
    static func plan(sessionId: String, durationSeconds: Double,
                     canSeekAnywhere: Bool = true) -> PlaybackV3Plan {
        PlaybackV3Plan(
            nativeApiMajor: nil,
            protocolVersion: 3,
            planId: "plan:fixture",
            sessionId: sessionId,
            expiresAt: "2030-01-01T00:00:00Z",
            delivery: PlaybackProtocolV3.PlanDelivery.originalHTTP,
            planAttemptKey: "v3:fixture",
            stream: PlaybackV3Stream(
                url: "/stream/\(sessionId)", protocol: "http_progressive", container: "mp4",
                mimeType: "video/mp4", headers: [:], headerRefresh: "session", headerRefreshUrl: nil
            ),
            timeline: PlaybackV3Timeline(
                sourceStartSeconds: 0, streamOriginSeconds: 0, playerStartSeconds: 0,
                timelineOffsetSeconds: 0, seekWindowStartSeconds: nil, seekWindowEndSeconds: nil,
                canSeekAnywhere: canSeekAnywhere, seekRestoration: "player_position"
            ),
            selectedTracks: PlaybackV3SelectedTracks(
                audio: PlaybackV3TrackIdentity(id: "file:42:audio:0", index: 0), subtitle: nil
            ),
            effectiveRecipe: PlaybackV3EffectiveRecipe(
                videoCodec: "h264", audioCodec: "aac", width: 1_920, height: 1_080, frameRate: 23.976,
                bitrateKbps: 8_000, dynamicRange: "sdr", audioChannels: 2, audioLayout: "stereo"
            ),
            claims: PlaybackV3ValidationClaims(
                video: PlaybackV3VideoClaims(hdr10: false, hdr10Plus: false, hlg: false,
                                             dolbyVision: false, dolbyVisionReason: nil),
                audio: PlaybackV3AudioClaims(codec: "aac", passthrough: false, atmosPreserved: false,
                                             dtsVariant: nil, reason: "client_decode_supported"),
                subtitles: PlaybackV3SubtitleClaims(assStylingPreserved: false, bitmapOverlay: false,
                                                    bitmapSidecar: false, reason: nil)
            ),
            subtitle: PlaybackV3SubtitleDecision(mode: "off", trackId: nil, artifact: nil,
                                                 embedded: nil, inventory: []),
            transformations: [],
            appliedQuirks: [],
            runtimeCorrections: [],
            degradationWarnings: [],
            decisionReason: "validated_original_playback",
            requestedMediaFileId: 42,
            effectiveMediaFileId: 42,
            source: PlaybackV3SourceDescriptor(
                mediaFileId: 42, durationSeconds: durationSeconds, container: "mp4", videoCodec: "h264",
                videoProfile: "high", videoLevel: 41, bitDepth: 8, colorRange: "tv", width: 1_920,
                height: 1_080, frameRate: 23.976, bitrateKbps: 8_000, dynamicRange: "sdr",
                hdr10Plus: false, dolbyVisionProfile: nil, dvBlCompatId: nil, dvEnhancementLayer: "none",
                audioCodec: "aac", audioChannels: 2, audioLayout: "stereo", videoCopyUnsafe: false
            ),
            subtitleFidelityPolicy: "allow_simplified_rendering",
            availableQualities: [
                PlaybackV3AvailableQuality(label: "original", displayName: nil, height: 1_080,
                                           bitrateKbps: 8_000, preservesSource: true),
            ]
        )
    }
}
