import XCTest
@testable import Vivid

final class AirPlayHandOffPolicyTests: XCTestCase {
    private let appleTV = "airplay-apple-tv"
    private let homePod = "airplay-homepod"

    /// Probes `route`, gets a video verdict, and has a stream arrive at
    /// `position` (request 1). Lucid is paused and the commit is out.
    private func committing(route: String = "airplay-apple-tv", at position: Double = 120) -> AirPlayHandOffPolicy {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: route))
        _ = policy.handle(.probeExternalActive)
        _ = policy.handle(.streamReady(request: 1, position: position))
        return policy
    }

    /// As `committing`, with the commit done and the stream on the player.
    private func handedOff(route: String = "airplay-apple-tv", at position: Double = 120) -> AirPlayHandOffPolicy {
        var policy = committing(route: route, at: position)
        _ = policy.handle(.commitFinished(request: 1, result: .committed))
        return policy
    }

    /// As `handedOff`, with the receiver's clock moving.
    private func playing(at position: Double = 120) -> AirPlayHandOffPolicy {
        var policy = handedOff(at: position)
        _ = policy.handle(.playbackStarted)
        return policy
    }

    // MARK: - Probe

    func testHomePodProbeTimesOutWithoutTouchingLucid() {
        var policy = AirPlayHandOffPolicy()
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: homePod)), [.startProbe])
        XCTAssertTrue(policy.ownsOutputRoute)
        let effects = policy.handle(.probeTimedOut)
        XCTAssertEqual(effects, [.stopProbe, .recheckOutputRoute])
        XCTAssertFalse(effects.contains(.pauseAndMuteLucid))
        XCTAssertEqual(policy.state, .ending(route: homePod))
        XCTAssertFalse(policy.ownsOutputRoute)
        // The same speaker again, or a new item on it, doesn't probe again.
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: homePod)), [])
        XCTAssertEqual(policy.handle(.loadReplaced), [])
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: homePod)), [])
    }

    func testProbeFailureLeavesTheRouteOpenForAnotherTry() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        XCTAssertEqual(policy.handle(.probeFailed), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
    }

    func testRouteGoingLocalWhileProbingStopsTheProbe() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        XCTAssertEqual(policy.handle(.routeBecameLocal), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .idle)
    }

    func testDifferentRouteMidProbeRestartsTheProbe() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: homePod))
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.stopProbe, .startProbe])
        XCTAssertEqual(policy.state, .probing(route: appleTV))
    }

    func testDifferentRouteWhilePreparingRestartsAndReleasesTheOldStream() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: homePod))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.stopProbe, .startProbe])
        XCTAssertEqual(policy.state, .probing(route: appleTV))
        XCTAssertEqual(policy.handle(.streamReady(request: 1, position: 5)), [.releaseStream(request: 1)])
    }

    func testPickingTheSameReceiverAgainAfterAnAnswerProbesAgain() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeTimedOut)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
        XCTAssertEqual(policy.handle(.routePickerClosed), [])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
    }

    func testPickerClosingMidHandOffChangesNothing() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.routePickerClosed), [])
        XCTAssertTrue(policy.isActive)
    }

    // MARK: - Prepare and commit

    func testAppleTVPausesLucidBeforeCommittingThenStarts() {
        var policy = AirPlayHandOffPolicy()
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
        XCTAssertEqual(policy.handle(.probeExternalActive), [.requestStream(request: 1)])
        XCTAssertEqual(policy.state, .preparing(route: appleTV, request: 1))
        XCTAssertEqual(
            policy.handle(.streamReady(request: 1, position: 95)),
            [.pauseAndMuteLucid, .commitStream(request: 1, at: 95)]
        )
        XCTAssertTrue(policy.isActive)
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .committed)),
            [.startStream(request: 1, at: 95)]
        )
        XCTAssertEqual(policy.handle(.playbackStarted), [])
    }

    func testStreamFailureFallsBackWithoutTouchingLucid() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.streamFailed(request: 1)), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .ending(route: appleTV))
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
    }

    func testBlockedHandOffLetsTheSameRouteTryAgain() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.handOffBlocked(request: 1)), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
        // A block for a request that isn't being prepared changes nothing.
        XCTAssertEqual(policy.handle(.handOffBlocked(request: 1)), [])
    }

    func testTemporaryFailureRetriesTwiceThenGivesUp() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(
            policy.handle(.streamUnavailable(request: 1)),
            [.stopProbe, .recheckOutputRoute, .retryRouteCheck(afterSeconds: 3)]
        )
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(
            policy.handle(.streamUnavailable(request: 2)),
            [.stopProbe, .recheckOutputRoute, .retryRouteCheck(afterSeconds: 8)]
        )
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.streamUnavailable(request: 3)), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .ending(route: appleTV))
    }

    func testRetriesStartAgainForANewRouteOrAPickerChoice() {
        var policy = AirPlayHandOffPolicy()
        for request in 1...2 {
            _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
            _ = policy.handle(.probeExternalActive)
            _ = policy.handle(.streamUnavailable(request: request))
        }
        _ = policy.handle(.routePickerClosed)
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(
            policy.handle(.streamUnavailable(request: 3)),
            [.stopProbe, .recheckOutputRoute, .retryRouteCheck(afterSeconds: 3)]
        )
        _ = policy.handle(.airPlayRouteAppeared(route: homePod))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(
            policy.handle(.streamUnavailable(request: 4)),
            [.stopProbe, .recheckOutputRoute, .retryRouteCheck(afterSeconds: 3)]
        )
    }

    func testCommittedHandOffClearsTheRetries() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        _ = policy.handle(.streamUnavailable(request: 1))
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        _ = policy.handle(.streamReady(request: 2, position: 5))
        _ = policy.handle(.commitFinished(request: 2, result: .committed))
        _ = policy.handle(.loadReplaced)
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(
            policy.handle(.streamUnavailable(request: 3)),
            [.stopProbe, .recheckOutputRoute, .retryRouteCheck(afterSeconds: 3)]
        )
    }

    func testPrepareTimeoutFallsBackWithoutTouchingLucid() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.prepareTimedOut), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .ending(route: appleTV))
        XCTAssertEqual(policy.handle(.streamReady(request: 1, position: 5)), [.releaseStream(request: 1)])
    }

    func testPrepareTimeoutWhileCommittingReloadsLucid() {
        var policy = committing(at: 40)
        XCTAssertEqual(policy.handle(.prepareTimedOut), [.endHandOff(.prepareTimedOut), .resumeLucid(at: 40)])
        // The commit answering late changes nothing more.
        XCTAssertEqual(policy.handle(.commitFinished(request: 1, result: .committed)), [])
    }

    func testRefusedFirstCommitResumesLucidInPlace() {
        var policy = committing(at: 40)
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .refused)),
            [.endHandOff(.commitFailed), .resumeLucidInPlace]
        )
        XCTAssertEqual(policy.state, .ending(route: appleTV))
    }

    func testFailedCommitReloadsLucid() {
        var policy = committing(at: 40)
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .failed)),
            [.endHandOff(.commitFailed), .resumeLucid(at: 40)]
        )
    }

    // MARK: - Starting

    func testStartTimeoutResumesLucidWhereItPaused() {
        var policy = handedOff(at: 300)
        XCTAssertEqual(policy.handle(.startTimedOut), [.endHandOff(.startTimedOut), .resumeLucid(at: 300)])
        XCTAssertEqual(policy.state, .ending(route: appleTV))
    }

    func testStartTimeoutAfterStartIsIgnored() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.startTimedOut), [])
        XCTAssertTrue(policy.isActive)
    }

    func testLocalRouteBeforeStartEndsAtOnce() {
        var policy = handedOff(at: 300)
        XCTAssertEqual(policy.handle(.routeBecameLocal), [.endHandOff(.routeLocal), .resumeLucid(at: 300)])
        XCTAssertEqual(policy.state, .idle)
    }

    func testConfirmedLossBeforeStartEndsAtOnce() {
        var policy = handedOff(at: 300)
        XCTAssertEqual(
            policy.handle(.externalLostDebounced(position: 0)),
            [.endHandOff(.receiverLost), .resumeLucid(at: 300)]
        )
    }

    func testLocalRouteWhileCommittingReloadsLucid() {
        var policy = committing(at: 70)
        XCTAssertEqual(policy.handle(.routeBecameLocal), [.endHandOff(.routeLocal), .resumeLucid(at: 70)])
    }

    // MARK: - Running

    func testTransientExternalFlipDoesNotEnd() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.externalLost), [])
        XCTAssertEqual(policy.handle(.externalRestored), [])
        // A debounce that fired just after the restore is stale.
        XCTAssertEqual(policy.handle(.externalLostDebounced(position: 400)), [])
        XCTAssertTrue(policy.isActive)
    }

    func testDisconnectResumesLucidAtReceiverPosition() {
        var policy = playing(at: 120)
        _ = policy.handle(.externalLost)
        XCTAssertEqual(
            policy.handle(.externalLostDebounced(position: 512.5)),
            [.endHandOff(.receiverLost), .resumeLucid(at: 512.5)]
        )
        XCTAssertEqual(policy.state, .ending(route: appleTV))
        // The reload that brings Lucid back keeps the answer for this route.
        XCTAssertEqual(policy.handle(.loadReplaced), [])
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
        XCTAssertEqual(policy.handle(.routeBecameLocal), [])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
    }

    func testLocalRouteAloneDoesNotEndARunningHandOff() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.routeBecameLocal), [])
        XCTAssertTrue(policy.isActive)
    }

    func testReceiverFailureResumesLucid() {
        var policy = playing(at: 50)
        XCTAssertEqual(policy.handle(.receiverFailed(position: 80)), [.endHandOff(.receiverFailed), .resumeLucid(at: 80)])

        var early = handedOff(at: 50)
        XCTAssertEqual(early.handle(.receiverFailed(position: 0)), [.endHandOff(.receiverFailed), .resumeLucid(at: 50)])
    }

    func testReceiverEndKeepsTheHandOffForTheEndScreen() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.playbackEnded), [])
        XCTAssertTrue(policy.isActive)
        // The next item replaces the load, and hands off again from idle.
        XCTAssertEqual(policy.handle(.loadReplaced), [.endHandOff(.loadReplaced)])
        XCTAssertEqual(policy.state, .idle)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
    }

    func testNewLoadWhileProbingEndsCleanly() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        XCTAssertEqual(policy.handle(.loadReplaced), [.stopProbe])
        XCTAssertEqual(policy.state, .idle)
    }

    func testNewLoadWhileActiveEndsWithoutResuming() {
        var policy = playing()
        XCTAssertEqual(policy.handle(.loadReplaced), [.endHandOff(.loadReplaced)])
        XCTAssertEqual(policy.state, .idle)
    }

    func testUserStopEndsWithoutResuming() {
        var policy = handedOff()
        XCTAssertEqual(policy.handle(.userStopped), [.endHandOff(.userStopped)])
        XCTAssertEqual(policy.state, .idle)
    }

    func testRepeatedRouteNotificationsAreIdempotent() {
        var policy = AirPlayHandOffPolicy()
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [.startProbe])
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
        _ = policy.handle(.streamReady(request: 1, position: 10))
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: appleTV)), [])
        XCTAssertEqual(policy.handle(.airPlayRouteAppeared(route: homePod)), [])
        XCTAssertTrue(policy.isActive)
    }

    // MARK: - Restarts

    func testTrackChangeSwapsTheStreamBeforeCommitting() {
        var policy = playing(at: 100)
        XCTAssertEqual(
            policy.handle(.restartRequested(position: nil)),
            [.requestStream(request: 2), .armRestartDeadline(request: 2)]
        )
        XCTAssertEqual(
            policy.handle(.streamReady(request: 2, position: 130)),
            [.startStream(request: 2, at: 130), .commitStream(request: 2, at: 130)]
        )
        XCTAssertEqual(policy.handle(.commitFinished(request: 2, result: .committed)), [])
        // The new stream has to start on its own.
        XCTAssertEqual(policy.handle(.startTimedOut), [.endHandOff(.startTimedOut), .resumeLucid(at: 130)])
    }

    func testSeekRestartStartsAtTheSeekTarget() {
        var policy = playing(at: 100)
        _ = policy.handle(.restartRequested(position: 20))
        XCTAssertEqual(
            policy.handle(.streamReady(request: 2, position: 101)),
            [.startStream(request: 2, at: 20), .commitStream(request: 2, at: 20)]
        )
    }

    func testFailedRestartKeepsTheCurrentStream() {
        for event in [AirPlayHandOffPolicy.Event.streamFailed(request: 2), .streamUnavailable(request: 2),
                      .restartTimedOut(request: 2)] {
            var policy = playing()
            _ = policy.handle(.restartRequested(position: nil))
            XCTAssertEqual(policy.handle(event), [.restartFailed(request: 2)])
            XCTAssertTrue(policy.isActive)
            XCTAssertEqual(policy.handle(.startTimedOut), [])
            // Its stream turning up afterwards is let go.
            XCTAssertEqual(policy.handle(.streamReady(request: 2, position: 5)), [.releaseStream(request: 2)])
            // Later changes aren't held back.
            XCTAssertEqual(
                policy.handle(.restartRequested(position: nil)),
                [.requestStream(request: 3), .armRestartDeadline(request: 3)]
            )
        }
    }

    func testHungRestartCommitStopsHoldingChangesBack() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.streamReady(request: 2, position: 60))
        XCTAssertEqual(policy.handle(.restartRequested(position: nil)), [])
        XCTAssertEqual(
            policy.handle(.restartTimedOut(request: 2)),
            [.requestStream(request: 3), .armRestartDeadline(request: 3)]
        )
        // The hung commit answering late changes nothing.
        XCTAssertEqual(policy.handle(.commitFinished(request: 2, result: .committed)), [])
        XCTAssertTrue(policy.isActive)
    }

    func testHungRestartCommitWithNothingWaitingJustLetsGo() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.streamReady(request: 2, position: 60))
        XCTAssertEqual(policy.handle(.restartTimedOut(request: 2)), [])
        XCTAssertEqual(
            policy.handle(.restartRequested(position: nil)),
            [.requestStream(request: 3), .armRestartDeadline(request: 3)]
        )
    }

    func testStaleRestartDeadlineIsIgnored() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.streamReady(request: 2, position: 60))
        _ = policy.handle(.commitFinished(request: 2, result: .committed))
        XCTAssertEqual(policy.handle(.restartTimedOut(request: 2)), [])
    }

    func testRefusedOrFailedRestartCommitReloadsLucid() {
        for result in [AirPlayReceiverCommit.refused, .failed] {
            var policy = playing()
            _ = policy.handle(.restartRequested(position: nil))
            _ = policy.handle(.streamReady(request: 2, position: 60))
            XCTAssertEqual(
                policy.handle(.commitFinished(request: 2, result: result)),
                [.endHandOff(.commitFailed), .resumeLucid(at: 60)]
            )
        }
    }

    func testNewerRestartReleasesTheOlderStream() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        XCTAssertEqual(
            policy.handle(.restartRequested(position: nil)),
            [.requestStream(request: 3), .armRestartDeadline(request: 3)]
        )
        XCTAssertEqual(policy.handle(.streamReady(request: 2, position: 5)), [.releaseStream(request: 2)])
        XCTAssertEqual(
            policy.handle(.streamReady(request: 3, position: 6)),
            [.startStream(request: 3, at: 6), .commitStream(request: 3, at: 6)]
        )
    }

    func testSeekWhileARestartIsPreparedMovesItsStart() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        XCTAssertEqual(policy.handle(.seekRequested(position: 44)), [])
        XCTAssertEqual(
            policy.handle(.streamReady(request: 2, position: 6)),
            [.startStream(request: 2, at: 44), .commitStream(request: 2, at: 44)]
        )
    }

    func testRestartDuringTheFirstCommitWaitsForIt() {
        var policy = committing(at: 10)
        XCTAssertEqual(policy.handle(.restartRequested(position: nil)), [])
        XCTAssertTrue(policy.isActive)
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .committed)),
            [.startStream(request: 1, at: 10), .requestStream(request: 2), .armRestartDeadline(request: 2)]
        )
    }

    func testFailedRestartTakesTheNewerWaitingChangeInstead() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.streamReady(request: 2, position: 60))
        // While request 2 commits, another change waits; then a newer restart
        // for it fails, but nothing is waiting behind that one.
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.commitFinished(request: 2, result: .committed))
        XCTAssertEqual(policy.handle(.streamFailed(request: 3)), [.restartFailed(request: 3)])
    }

    func testRestartDuringARestartCommitWaitsForIt() {
        var policy = playing()
        _ = policy.handle(.restartRequested(position: nil))
        _ = policy.handle(.streamReady(request: 2, position: 60))
        XCTAssertEqual(policy.handle(.restartRequested(position: 15)), [])
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 2, result: .committed)),
            [.requestStream(request: 3), .armRestartDeadline(request: 3)]
        )
        XCTAssertEqual(
            policy.handle(.streamReady(request: 3, position: 70)),
            [.startStream(request: 3, at: 15), .commitStream(request: 3, at: 15)]
        )
    }

    func testSeekBeforeTheFirstStreamBecomesItsStart() {
        var policy = committing(at: 10)
        XCTAssertEqual(policy.handle(.seekRequested(position: 250)), [])
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .committed)),
            [.startStream(request: 1, at: 250)]
        )
        // The receiver never starting goes back to where the viewer seeked.
        XCTAssertEqual(policy.handle(.startTimedOut), [.endHandOff(.startTimedOut), .resumeLucid(at: 250)])
    }

    func testDeferredRestartIsDroppedWhenTheFirstCommitIsRefused() {
        var policy = committing(at: 10)
        _ = policy.handle(.restartRequested(position: nil))
        XCTAssertEqual(
            policy.handle(.commitFinished(request: 1, result: .refused)),
            [.endHandOff(.commitFailed), .resumeLucidInPlace]
        )
    }

    // MARK: - Late streams

    func testLateStreamAfterRouteWentLocalIsReleasedAndLucidKeepsItsSession() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.routeBecameLocal), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.handle(.streamReady(request: 1, position: 61)), [.releaseStream(request: 1)])
    }

    func testLateStreamAfterNewLoadIsReleased() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.loadReplaced), [.stopProbe])
        XCTAssertEqual(policy.handle(.streamReady(request: 1, position: 5)), [.releaseStream(request: 1)])
    }

    func testLateStreamDuringANewerHandOffIsReleased() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        _ = policy.handle(.routeBecameLocal)
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        XCTAssertEqual(policy.handle(.probeExternalActive), [.requestStream(request: 2)])
        XCTAssertEqual(policy.handle(.streamReady(request: 1, position: 5)), [.releaseStream(request: 1)])
        XCTAssertEqual(
            policy.handle(.streamReady(request: 2, position: 7)),
            [.pauseAndMuteLucid, .commitStream(request: 2, at: 7)]
        )
    }

    func testLateFailureIsForgotten() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        _ = policy.handle(.routeBecameLocal)
        XCTAssertEqual(policy.handle(.streamFailed(request: 1)), [])
    }

    func testProbeExternalLossWhilePreparingGivesUp() {
        var policy = AirPlayHandOffPolicy()
        _ = policy.handle(.airPlayRouteAppeared(route: appleTV))
        _ = policy.handle(.probeExternalActive)
        XCTAssertEqual(policy.handle(.externalLostDebounced(position: 0)), [.stopProbe, .recheckOutputRoute])
        XCTAssertEqual(policy.state, .ending(route: appleTV))
    }
}

#if os(iOS)
final class AirPlayReceiverPlanStorageTests: XCTestCase {
    /// The bridge keeps a Silo receiver plan without its signed stream
    /// references, and otherwise unchanged.
    func testStoredReceiverPlanKeepsNoStreamReference() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(named: "decision_response", bundleClass: Self.self)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var stream = try XCTUnwrap(planObject["stream"] as? [String: Any])
        let original = try XCTUnwrap(stream["url"] as? String)
        stream["url"] = original + "?st=signed-reference&seek=12"
        planObject["stream"] = stream
        object["playback_plan"] = planObject
        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let plan = try XCTUnwrap(response.playbackPlan)

        let stored = try PlaybackSessionBridge.planWithoutStreamReferences(plan)

        XCTAssertEqual(stored.stream.url, original + "?seek=12")
        XCTAssertFalse(stored.stream.url.contains("st="))
        XCTAssertEqual(stored.planId, plan.planId)
        XCTAssertEqual(stored.timeline, plan.timeline)
        XCTAssertEqual(stored.subtitle, plan.subtitle)
        XCTAssertEqual(stored.nativeApiMajor, plan.nativeApiMajor)
        XCTAssertEqual(stored.availableQualities, plan.availableQualities)
    }

    @MainActor
    func testLastingReceiverFailuresAreNotRetried() {
        XCTAssertTrue(PlayerViewModel.isTemporaryAirPlayFailure(CancellationError()))
        XCTAssertTrue(PlayerViewModel.isTemporaryAirPlayFailure(URLError(.timedOut)))
        for lasting: PlaybackSessionBridge.AirPlayReceiverUnavailable in [.noLiveProvider, .noReceiverSession, .noReceiverStream] {
            XCTAssertFalse(PlayerViewModel.isTemporaryAirPlayFailure(lasting))
        }
    }
}
#endif
