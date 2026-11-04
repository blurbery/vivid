import Foundation
import OSLog

/// Getting the current item playing again after its engine or source fails.
///
/// `+EngineEvents` and `+PlaybackEnd` try three ways back, in this order:
///
/// 1. **Reopen the same route.** Load the committed Silo plan again at the
///    current position with fresh request headers. This covers an expired
///    bearer, a dropped connection and a stream that stopped early.
/// 2. **Replan.** Ask Silo for a different route
///    (`attemptProtocolV3Replan`). Track, quality, output route and seek
///    re-anchor changes travel the same way.
/// 3. **Renew a stale session.** Start a new session where playback was
///    (`attemptStaleSessionRenewal`, in `+SessionLoad`) when the server has
///    lost the old one.
///
/// A failure nothing can recover ends on the Retry screen through
/// `finalizeTerminalPlaybackError`; a recovery load that fails shows a notice
/// instead.
extension PlayerViewModel {
    // MARK: Entry point

    func handlePlaybackError(_ message: String, failure: PlaybackErrorInfo? = nil) {
        let redacted = MediaLogRedactor.sanitize(message)
        Self.logger.error("Player error: \(redacted, privacy: .public)")
        if hasReachedEndOfFile {
            Self.logger.info("Ignoring playback error after EOF: \(redacted, privacy: .public)")
            return
        }
        suppressNextUpForPlaybackFailure()

        if activePreparedProtocolV3 != nil, committedProtocolV3LoadEpoch != nil {
            // A Silo plan is playing: ask for another route, unless one is
            // already on its way.
            guard protocolV3ReplanTask == nil else { return }
            let classification = Self.protocolV3FailureClassification(message)
            if !attemptProtocolV3Replan(position: currentTime, classification: classification, message: message) {
                finalizeTerminalPlaybackError(message)
            }
            return
        }

        let sessionIsGone = isPlaybackSessionMissingMessage(message) || isExpiredPlaybackSessionSource(failure)
        if sessionIsGone, attemptStaleSessionRenewal(reason: "player_error", observedPosition: currentTime) {
            return
        }
        progressTask?.cancel()
        finalizeTerminalPlaybackError(message)
    }

    // MARK: Credentials

    /// Reopens the committed plan with whatever account bearer `VividAPI`
    /// now holds. A token refresh leaves Protocol V3 media URLs as they
    /// were, but the engine settles its request headers when it opens the
    /// source, so only a reload picks up a new Authorization value, and the
    /// reload only happens when the value really changed.
    @discardableResult
    func attemptProtocolV3AuthenticationReload(after failure: PlaybackErrorInfo) -> Bool {
        guard VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure) else { return false }
        return beginProtocolV3SameRouteReload(
            fallbackClassification: failure.kind.rawValue,
            fallbackMessage: failure.message
        )
    }

    /// Token refresh belongs to the periodic progress report. When a report
    /// succeeds and the request headers have changed, pass them to the
    /// engine, but only if it can keep its open reader. If it can't, leave
    /// things alone: a genuine media authentication failure later goes
    /// through the same-route reload.
    ///
    /// `scripts/tests/playback-auth-refresh-tests.py` builds this body
    /// against a stand-in player, so it only uses what that stand-in offers.
    func updateProtocolV3AuthenticationAfterProgress(
        _ result: PlaybackProgressReportResult
    ) async {
        guard result == .success, protocolV3ReplanTask == nil, let prepared = activePreparedProtocolV3 else { return }
        let mediaUsesHeaders = prepared.plan.nativeApiMajor == 2
            || prepared.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
        guard mediaUsesHeaders,
              let sessionId = activePlaybackSessionId,
              let epoch = vividPlaybackController.activeLoadEpoch,
              let loaded = vividPlaybackController.activeSpec,
              loaded.planID == prepared.plan.planId,
              loaded.sessionID == sessionId,
              committedProtocolV3LoadEpoch != nil else { return }

        guard let session = await sessionBridge.committedProtocolV3Session(planId: prepared.plan.planId, sessionId: sessionId),
              let fresh = await makeStreamRequest(
                  session: session,
                  additionalHeaders: prepared.plan.stream.headers,
                  requiresHeaderAuthenticatedMedia: true,
                  allowsAuthorizedMediaOrigins: prepared.negotiatedAuthorizedMediaOrigins,
                  nativeApiMajor: prepared.plan.nativeApiMajor
              ) else { return }

        // Both waits above can outlast a replan or a new load, so everything
        // is checked again before the engine is touched.
        let current = vividPlaybackController.activeSpec
        guard activePlaybackSessionId == sessionId,
              activePreparedProtocolV3?.plan.planId == prepared.plan.planId,
              vividPlaybackController.activeLoadEpoch == epoch,
              current?.planID == loaded.planID,
              current?.sessionID == sessionId,
              current?.options.httpHeaders == loaded.options.httpHeaders,
              VividAuthenticationRecoveryPolicy.shouldUpdateHeadersAfterProgress(
                  result,
                  activeHeaders: loaded.options.httpHeaders,
                  currentHeaders: fresh.headers
              ) else { return }

        let installed = vividPlaybackController.updateSourceHeaders(
            fresh.headers,
            for: epoch,
            expectedHeaders: loaded.options.httpHeaders,
            sourceURL: fresh.url
        )
        if installed {
            Self.logger.info("Stream recovery reason=authorization_rotated outcome=headers_updated")
        }
    }

    /// Called by the engine when its source answers 401. Renews the
    /// session's credentials and returns headers the open reader can use, or
    /// nil so the failure takes its normal course.
    func refreshDirectSourceHeaders(
        epoch: VividPlaybackController.LoadEpoch,
        generation: UInt64
    ) async -> [String: String]? {
        let controller = vividPlaybackController
        guard !Task.isCancelled, !isDisposed, generation == streamLoadGeneration,
              protocolV3ReplanTask == nil,
              controller.activeLoadEpoch == epoch, committedProtocolV3LoadEpoch == epoch,
              let opened = controller.activeSpec, !opened.options.nativeRemoteHLS,
              let prepared = activePreparedProtocolV3, prepared.reopensWithFreshHeaders,
              prepared.plan.planId == opened.planID,
              let sessionId = activePlaybackSessionId, sessionId == opened.sessionID else {
            return nil
        }
        let openedHeaders = opened.options.httpHeaders
        do {
            let position = progressIsEligible && currentTime.isFinite ? max(0, currentTime) : 0
            try await sessionBridge.refreshPlaybackAuthentication(
                sessionId: sessionId,
                position: position,
                isPaused: !controller.shouldPlayWhenReady
            )
            try requireCurrentStreamLoad(generation)
            guard controller.activeLoadEpoch == epoch,
                  let session = await sessionBridge.committedProtocolV3Session(planId: opened.planID, sessionId: sessionId),
                  let fresh = await refreshedStreamRequest(for: session, plan: prepared) else {
                return nil
            }
            try requireCurrentStreamLoad(generation)
            guard controller.activeLoadEpoch == epoch,
                  activePlaybackSessionId == sessionId,
                  activePreparedProtocolV3?.plan.planId == opened.planID,
                  fresh.url == opened.sourceURL,
                  let now = controller.activeSpec else {
                return nil
            }
            // A refresh that ran alongside this one got there first.
            guard now.options.httpHeaders == openedHeaders else { return now.options.httpHeaders }
            guard VividAuthenticationRecoveryPolicy.shouldReload(failedHeaders: openedHeaders, refreshedHeaders: fresh.headers),
                  controller.updateSourceHeaders(fresh.headers, for: epoch, expectedHeaders: openedHeaders, sourceURL: fresh.url) else {
                return nil
            }
            Self.logger.info("Stream recovery reason=http_401 outcome=headers_updated")
            return fresh.headers
        } catch {
            Self.logger.info("Stream recovery reason=http_401 outcome=refresh_unavailable")
            return nil
        }
    }

    // MARK: Same-route reload

    /// Loads the committed Silo plan again where playback is, with current
    /// credentials.
    ///
    /// False means this load can't (a replan is running, the plan can't take
    /// refreshed headers, or this reason's allowance is used up) and the
    /// caller should try its next option. True means the reload has taken
    /// charge of the outcome, including going straight to Retry when the
    /// authentication allowance is spent.
    ///
    /// - `prematureSourceEnd`: the stream ended too soon. Limited by
    ///   `prematureEndRecoveryGate`, and reopens even if the bearer is the
    ///   same.
    /// - `transientFailureCode`: a known connection error. Limited by
    ///   `transientRecoveryBudget`, with no credential refresh first.
    /// - Otherwise: an expired bearer. Limited by
    ///   `authenticationRecoveryBudget`, and only reloads when the refresh
    ///   changed the Authorization header.
    @discardableResult
    func beginProtocolV3SameRouteReload(
        fallbackClassification: String,
        fallbackMessage: String,
        transientFailureCode: Int? = nil,
        prematureSourceEnd: Bool = false
    ) -> Bool {
        guard protocolV3ReplanTask == nil,
              let prepared = activePreparedProtocolV3, prepared.reopensWithFreshHeaders,
              let sessionId = activePlaybackSessionId,
              let detail = currentWatchDetail,
              let version = currentSelectedVersion,
              let opened = vividPlaybackController.activeSpec,
              opened.planID == prepared.plan.planId,
              opened.sessionID == sessionId,
              committedProtocolV3LoadEpoch != nil else {
            return false
        }

        let attempt = SameRouteReload(
            sessionId: sessionId,
            prepared: prepared,
            detail: detail,
            version: version,
            openedHeaders: opened.options.httpHeaders,
            startPosition: currentTime.isFinite ? max(0, currentTime) : 0,
            episode: freshLoadGeneration,
            prematureEnd: prematureSourceEnd,
            connectionErrorCode: transientFailureCode
        )
        if attempt.prematureEnd {
            guard prematureEndRecoveryGate.begin() else { return false }
        } else if attempt.connectionErrorCode != nil {
            guard transientRecoveryBudget.beginReload() else { return false }
        }
        if attempt.renewsCredential, !authenticationRecoveryBudget.begin(generation: attempt.episode) {
            progressTask?.cancel()
            finalizeTerminalPlaybackError(fallbackMessage)
            return true
        }

        progressTask?.cancel()
        progressTask = nil
        showRecoveryLoading()
        let generation = streamLoadGeneration
        authenticationReloadGeneration = generation
        logSameRouteReloadStart(attempt)

        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            // Where the attempt goes if it doesn't recover: nil means it did
            // recover, or was cancelled.
            var fallback: (classification: String, message: String)? = (fallbackClassification, fallbackMessage)
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                if self.authenticationReloadGeneration == generation {
                    self.authenticationReloadGeneration = nil
                }
                // Once the generation has moved on, a newer load or replan
                // owns the task handle and the queues.
                if !self.isDisposed, generation == self.streamLoadGeneration {
                    self.protocolV3ReplanTask = nil
                    if let fallback {
                        self.fallBackFromSameRouteReload(
                            classification: fallback.classification,
                            message: fallback.message,
                            resumePosition: attempt.startPosition
                        )
                    } else {
                        self.drainQueuedProtocolV3Work(seekSource: "queuedAuthReloadReanchor")
                    }
                }
            }

            do {
                switch try await self.reopenCommittedPlan(attempt, generation: generation) {
                case .credentialUnchanged:
                    fallback = ("authentication", fallbackMessage)
                case .reopened:
                    if attempt.connectionErrorCode == nil {
                        self.authenticationRecoveryBudget.recovered(generation: attempt.episode)
                    }
                    fallback = nil
                    Self.logger.info("Stream recovery outcome=recovered")
                }
            } catch is CancellationError {
                fallback = nil
                Self.logger.info("Stream recovery outcome=cancelled")
            } catch {
                let failure = VividAuthenticationRecoveryPolicy.finalFailure(error)
                let classification = VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure)
                    ? "authentication"
                    : failure.kind.rawValue
                fallback = (classification, failure.message)
                Self.logger.error(
                    "Stream recovery outcome=failed classification=\(classification, privacy: .public) code=\(failure.underlyingCode ?? 0, privacy: .public)"
                )
            }
        }
        return true
    }

    /// Everything a same-route reload needs, fixed when it starts.
    private struct SameRouteReload {
        let sessionId: String
        let prepared: PreparedPlaybackV3
        let detail: WatchDetail
        let version: FileVersion
        let openedHeaders: [String: String]
        let startPosition: Double
        /// The fresh load the authentication allowance is counted against.
        let episode: UInt64
        let prematureEnd: Bool
        let connectionErrorCode: Int?

        var planId: String { prepared.plan.planId }

        /// An expired bearer: neither an early end nor a dropped connection.
        var renewsCredential: Bool { !prematureEnd && connectionErrorCode == nil }
    }

    private enum SameRouteReloadResult {
        case reopened
        /// The refresh produced the same Authorization header, so reopening
        /// would only fail again.
        case credentialUnchanged
    }

    /// Puts the player into its loading state for a recovery load and moves
    /// to a new stream generation.
    private func showRecoveryLoading() {
        isLoading = true
        isBuffering = false
        isLoadingSubtitles = false
        bufferingProgress = nil
        streamLoadGeneration &+= 1
    }

    private func logSameRouteReloadStart(_ attempt: SameRouteReload) {
        let position = attempt.startPosition
        if attempt.prematureEnd {
            Self.logger.warning("Stream recovery reason=premature_source_end position=\(position, privacy: .public) outcome=same_route_reload")
        } else if let code = attempt.connectionErrorCode {
            Self.logger.warning("Stream recovery domain=NSURLErrorDomain code=\(code, privacy: .public) outcome=same_route_reload")
        } else {
            let planId = attempt.planId
            Self.logger.warning(
                "Protocol V3 media credential expired; refreshing and reloading plan \(planId, privacy: .public) at source position \(position, privacy: .public)"
            )
        }
        Self.logger.info("Stream recovery outcome=session_reconstruction")
    }

    /// The body of a same-route reload, run inside its task. Throws
    /// `CancellationError` once a newer load or the session's replacement
    /// has made it pointless.
    private func reopenCommittedPlan(_ attempt: SameRouteReload, generation: UInt64) async throws -> SameRouteReloadResult {
        let controller = vividPlaybackController
        let reportedPosition = progressIsEligible ? attempt.startPosition : 0
        if attempt.prematureEnd {
            // Renew an expired bearer first. If that fails, reopen with
            // whatever credential is current anyway.
            try? await sessionBridge.refreshPlaybackAuthentication(
                sessionId: attempt.sessionId,
                position: reportedPosition,
                isPaused: !controller.shouldPlayWhenReady
            )
        } else if attempt.renewsCredential {
            // This goes through the normal API transport, which refreshes
            // TokenStore on a 401 and tries again. Its own answer doesn't
            // matter much: comparing the headers below decides.
            try await sessionBridge.refreshPlaybackAuthentication(
                sessionId: attempt.sessionId,
                position: reportedPosition,
                isPaused: !controller.shouldPlayWhenReady
            )
        }
        try requireCurrentStreamLoad(generation)
        guard activePlaybackSessionId == attempt.sessionId,
              activePreparedProtocolV3?.plan.planId == attempt.planId,
              let session = await sessionBridge.committedProtocolV3Session(planId: attempt.planId, sessionId: attempt.sessionId) else {
            throw CancellationError()
        }
        try requireCurrentStreamLoad(generation)

        let replay = PreparedPlayback(
            watchDetail: attempt.detail,
            selectedVersion: attempt.version,
            session: session,
            activeQualityId: activeQualityId,
            bandwidthCap: activeBandwidthCap,
            protocolV3: attempt.prepared
        )
        guard let fresh = await refreshedStreamRequest(for: session, plan: attempt.prepared) else {
            throw VividLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
        }
        try requireCurrentStreamLoad(generation)
        // An early end or a dropped connection lost the connection, not the
        // credential, so those reopen even with the same bearer.
        if attempt.renewsCredential,
           !VividAuthenticationRecoveryPolicy.shouldReload(failedHeaders: attempt.openedHeaders, refreshedHeaders: fresh.headers) {
            Self.logger.warning("Protocol V3 media credential did not change; using bounded route recovery")
            return .credentialUnchanged
        }

        // A local seek can finish while the refresh was waiting, so the
        // position is read again here, the last moment before `beginLoad`
        // replaces the epoch, and the reload never jumps back past it.
        let reloadAt = currentTime.isFinite ? max(0, currentTime) : attempt.startPosition
        let resumePlaying = controller.shouldPlayWhenReady
        pendingAudioFfIndex = resolvedAudioTrackIndexForResume()
        pendingSubtitleFfIndex = resolvedSubtitleTrackIndexForResume()
        if let subtitle = selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(subtitle) {
            let plan = attempt.prepared.plan
            armSidecarRestore(Self.protocolV3SidecarRestoreIntent(
                snapshot: subtitle,
                selectedSubtitleIndex: plan.selectedTracks.subtitle?.index,
                subtitleMode: plan.subtitle.mode,
                isEmbedded: plan.subtitle.embedded != nil
            ))
        }
        resolvedServerUrl = fresh.serverUrl
        try await loadVivid(
            prepared: replay,
            streamRequest: fresh,
            expectedStreamLoadGeneration: generation,
            resumeSourcePosition: reloadAt,
            shouldPlayWhenReady: resumePlaying
        )
        try requireCurrentStreamLoad(generation)
        guard activePlaybackSessionId == attempt.sessionId, activePreparedProtocolV3?.plan.planId == attempt.planId else {
            throw CancellationError()
        }
        applySecondarySubtitleTrackSelection(selectedSecondarySubtitleId)
        markProtocolV3VividLoadCommitted()
        try await waitForRecoveredPlayback(generation: generation, afterConnectionDrop: attempt.connectionErrorCode != nil)
        return .reopened
    }

    /// Where a same-route reload that didn't recover goes next. An
    /// authentication failure would fail on any route, and so would a
    /// refused audio session, so both end at Retry. Anything else asks Silo
    /// for the next route.
    private func fallBackFromSameRouteReload(classification: String, message: String, resumePosition: Double) {
        let routeCannotHelp = classification == "authentication"
            || classification == PlaybackErrorKind.audioSessionUnavailable.rawValue
        if routeCannotHelp {
            finalizeTerminalPlaybackError(message)
            return
        }
        let position = currentTime.isFinite ? max(0, currentTime) : resumePosition
        if !attemptProtocolV3Replan(position: position, classification: classification, message: message) {
            finalizeTerminalPlaybackError(message)
        }
    }

    /// Gives the reopened source up to 12 seconds to show it plays: ready,
    /// and moving (or settled, if paused). An engine failure that arrives
    /// first is thrown instead.
    private func waitForRecoveredPlayback(generation: UInt64, afterConnectionDrop: Bool) async throws {
        let engine = vividPlaybackController.engine
        let giveUpAt = ProcessInfo.processInfo.systemUptime + 12
        var readiness = VividAuthenticationRecoveryReadiness()
        while ProcessInfo.processInfo.systemUptime < giveUpAt {
            try requireCurrentStreamLoad(generation)
            if let failure = engine.errorInfo { throw failure }
            let ready: Bool
            if let player = engine.currentAVPlayer {
                ready = player.currentItem?.status == .readyToPlay
            } else {
                ready = engine.hasFirstFrameReadyForDisplay || engine.videoRoute == .audio
            }
            let settled = readiness.observe(
                time: engine.clock.currentTime,
                ready: ready,
                wantsPlayback: vividPlaybackController.shouldPlayWhenReady,
                playing: engine.state == .playing,
                paused: engine.state == .paused,
                seeking: engine.isSeeking || seekTargetTime != nil
            )
            if settled { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let message = afterConnectionDrop
            ? "Playback did not resume after reconnecting the media source."
            : "Playback did not resume after renewing authentication."
        throw PlaybackErrorInfo(
            kind: .vodSourceFailed,
            message: message,
            underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorTimedOut
        )
    }

    /// The plan's stream with the request headers the account holds now.
    private func refreshedStreamRequest(for session: PlaybackSessionResponse, plan prepared: PreparedPlaybackV3) async -> StreamRequest? {
        await makeStreamRequest(
            session: session,
            additionalHeaders: prepared.plan.stream.headers,
            requiresHeaderAuthenticatedMedia: true,
            allowsAuthorizedMediaOrigins: prepared.negotiatedAuthorizedMediaOrigins,
            nativeApiMajor: prepared.plan.nativeApiMajor
        )
    }

    // MARK: Queued track changes

    /// The audio track a queued change asks for.
    ///
    /// It keeps both the Vivid `trackId` the viewer tapped and the server's
    /// selection ordinal for it (`srcId ?? ffIndex`). The replan in flight
    /// can repackage the streams, so by the time the queue runs the Vivid id
    /// may be gone or point at another stream, while the server ordinal
    /// still names the right one.
    struct QueuedProtocolV3TrackTarget {
        let audioTrackId: Int64
        let selectionIndex: Int?
    }

    func queuedTrackTarget(forAudio track: PlayerTrack) -> QueuedProtocolV3TrackTarget {
        QueuedProtocolV3TrackTarget(audioTrackId: track.trackId, selectionIndex: audioSelectionIndex(for: track))
    }

    /// A track change waiting for the replan in flight to finish.
    ///
    /// No position is kept, because playback carries on meanwhile and the
    /// position is read when the queue runs. The target is kept: the replan
    /// in flight publishes its own plan's tracks as it goes, and
    /// `adoptVividInventory` republishes the engine's selection, so reading
    /// the selection later would ask for the track already playing and lose
    /// the tap.
    struct QueuedProtocolV3TrackChange {
        let classification: String
        let message: String
        let target: QueuedProtocolV3TrackTarget?
    }

    /// Restores a queued pick to the selection just before the deferred
    /// replan reads it, undoing whatever the interim plan republished.
    ///
    /// The Vivid id is tried first and then the server ordinal, so a stream
    /// that was renumbered is still found. A target that matches neither is
    /// dropped: the interim plan may not have that track, and a selection
    /// that names nothing resolves to no index at all, which is worse than
    /// keeping the track that's playing.
    private func restoreQueuedAudioSelection(_ target: QueuedProtocolV3TrackTarget) {
        let match = audioTracks.first { $0.trackId == target.audioTrackId }
            ?? target.selectionIndex.flatMap { ordinal in
                audioTracks.first { audioSelectionIndex(for: $0) == ordinal }
            }
        guard let match, match.trackId != selectedAudioId else { return }
        pendingAudioFfIndex = nil
        selectedAudioId = match.trackId
        reapplyAutomaticSubtitlePolicy()
    }

    /// Once the replan or reload that held them back has finished, sends the
    /// queued track change, or failing that the queued seek. The track
    /// change goes first because its own replan then drains any seek still
    /// waiting, so neither is lost and the seek lands last. With `canIssue`
    /// false the queue is still emptied but nothing is sent.
    private func drainQueuedProtocolV3Work(seekSource: String, canIssue: Bool = true) {
        if let change = pendingProtocolV3TrackChange {
            pendingProtocolV3TrackChange = nil
            if canIssue {
                attemptProtocolV3Replan(
                    position: currentTime,
                    classification: change.classification,
                    message: change.message,
                    requeueWhenBusy: true,
                    trackTarget: change.target
                )
            }
            return
        }
        guard let seekTarget = pendingProtocolV3SeekReanchorPosition else { return }
        pendingProtocolV3SeekReanchorPosition = nil
        if canIssue {
            commitSeek(to: seekTarget, source: seekSource)
        }
    }

    // MARK: Replan

    /// Asks Silo for a new plan and loads it, for recovery and for track,
    /// quality, output route and seek re-anchor changes.
    ///
    /// Returns false when nothing started: a track target without a server
    /// ordinal, no current item, or a replan already running (a seek
    /// re-anchor and a `requeueWhenBusy` track change are queued instead and
    /// return true). Returns true once the replan has taken charge of the
    /// outcome.
    @discardableResult
    func attemptProtocolV3Replan(
        position: Double,
        classification: String,
        message: String,
        operation: String? = nil,
        qualityPreference: String? = nil,
        completesQualitySwitch: Bool = false,
        requeueWhenBusy: Bool = false,
        trackTarget: QueuedProtocolV3TrackTarget? = nil,
        outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot? = nil
    ) -> Bool {
        // A track change has to have a stable server ordinal before it's
        // queued or sent. Using the engine's current selection instead would
        // turn a tap that can't be mapped into a replan for the track that's
        // already playing.
        if let trackTarget, trackTarget.selectionIndex == nil { return false }

        if protocolV3ReplanTask != nil {
            if operation == PlaybackProtocolV3.ReplanOperation.seekReanchor {
                // Quick seeks inside the window: the latest one wins, sent
                // once the route change in flight is done.
                pendingProtocolV3SeekReanchorPosition = position
                return true
            }
            if requeueWhenBusy {
                // The screen already shows this track change, and dropping it
                // would leave the player contradicting itself. The latest one
                // is queued and sent from wherever playback has got to.
                pendingProtocolV3TrackChange = QueuedProtocolV3TrackChange(
                    classification: classification,
                    message: message,
                    target: trackTarget
                )
                return true
            }
            if completesQualitySwitch { isQualitySwitching = false }
            return false
        }
        guard let detail = currentWatchDetail else {
            if completesQualitySwitch { isQualitySwitching = false }
            return false
        }
        // On the deferred path the interim plan may have republished the
        // selection while the pick waited, so the pick goes back in before
        // anything reads it. On the direct path this changes nothing.
        if let trackTarget {
            restoreQueuedAudioSelection(trackTarget)
        }
        let subtitleBeforeReplan = selectedSubtitleId
        // The engine can republish the selection before the task starts, so
        // the request's track indices are settled now rather than inside it.
        let audioIndex = trackTarget?.selectionIndex ?? resolvedAudioTrackIndexForResume()
        let subtitleIndex = resolvedProtocolV3SubtitleIndexForResume()
        progressTask?.cancel()
        showRecoveryLoading()
        let generation = streamLoadGeneration

        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let undo = ReplanUndo(of: self)
            var candidate: PreparedPlayback?
            var nextRoute: (position: Double, classification: String, message: String)?
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                // A new load or a teardown that has moved the generation on
                // owns the handle, the quality-switch flag and the queues.
                if generation == self.streamLoadGeneration {
                    self.protocolV3ReplanTask = nil
                    if completesQualitySwitch { self.isQualitySwitching = false }
                    if let nextRoute {
                        self.attemptProtocolV3Replan(
                            position: nextRoute.position,
                            classification: nextRoute.classification,
                            message: nextRoute.message
                        )
                    } else {
                        let canIssue = !self.isDisposed && self.activePreparedProtocolV3 != nil
                        self.drainQueuedProtocolV3Work(seekSource: "queuedReanchor", canIssue: canIssue)
                    }
                }
            }

            do {
                #if DEBUG
                self.testRecorder?.record(.serverReplan(classification: classification))
                #endif
                let answer = try await self.sessionBridge.replanProtocolV3(
                    watchDetail: detail,
                    position: position,
                    classification: classification,
                    message: message,
                    operation: operation,
                    qualityPreference: qualityPreference,
                    audioTrackIndex: audioIndex,
                    subtitleTrackIndex: subtitleIndex,
                    outputRouteSnapshot: outputRouteSnapshot
                )
                guard let replacement = answer else {
                    // Silo refused: that ends the item, if it's still the
                    // current one.
                    try self.requireCurrentStreamLoad(generation)
                    self.finalizeTerminalPlaybackError(message)
                    return
                }
                candidate = replacement
                try self.requireCurrentStreamLoad(generation)
                try await self.loadReplanReplacement(
                    replacement,
                    subtitleBeforeReplan: subtitleBeforeReplan,
                    generation: generation,
                    completesQualitySwitch: completesQualitySwitch,
                    onCommit: { candidate = nil }
                )
            } catch is CancellationError {
                // As with a fresh load, an abandoned replacement mustn't leave
                // the engine reading a retired session. The engine only holds
                // the candidate once `loadVivid` has moved the epoch; before
                // that the old source is still the one playing.
                if generation == self.streamLoadGeneration, self.activeVividLoadEpoch != undo.loadEpoch {
                    _ = self.disposeVividPlayback()
                }
                if let candidate {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(candidate)
                }
                if generation == self.streamLoadGeneration {
                    undo.apply(to: self)
                }
            } catch {
                let recovery = Self.protocolV3LoadFailureRecovery(error)
                if let candidate {
                    // The engine turned the replacement down before it
                    // committed. Report that exact plan and step down the
                    // limited route ladder, without any realtime, first-frame
                    // or success event for it.
                    if recovery.shouldAdvanceRoute,
                       await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(candidate) {
                        nextRoute = (position, recovery.classification, recovery.message)
                        return
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(candidate)
                }
                if generation == self.streamLoadGeneration {
                    undo.apply(to: self)
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error("Protocol V3 replan failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
                if PlaybackSessionBridge.isPlaybackSessionMissing(error),
                   self.attemptStaleSessionRenewal(reason: "protocol_v3_replan_missing_session", observedPosition: position) {
                    return
                }
                self.finalizeTerminalPlaybackError(error.localizedDescription)
            }
        }
        return true
    }

    /// Adopts the plan a replan answered with and loads it. `onCommit` runs
    /// as soon as the bridge has committed the plan, after which a failure
    /// no longer rolls it back.
    private func loadReplanReplacement(
        _ replacement: PreparedPlayback,
        subtitleBeforeReplan: Int64?,
        generation: UInt64,
        completesQualitySwitch: Bool,
        onCommit: () -> Void
    ) async throws {
        // The replacement starts with subtitles off and Silo is asked for
        // none, because Vivid draws them. The subtitle playing is read back
        // now, after the wait (so a pick or Off made meanwhile counts) and
        // while the old plan still describes it.
        let subtitleToRestore = resolvedSubtitleTrackIndexForResume()
        let sessionBeforeReplan = activePlaybackSessionId
        let replacementPlan = replacement.protocolV3?.plan
        activePlaybackSessionId = replacement.session.sessionId
        currentWatchDetail = replacement.watchDetail
        currentSelectedVersion = replacement.selectedVersion
        activePreparedProtocolV3 = replacement.protocolV3
        adoptProtocolV3RenewalIntent(from: replacement)
        if hasExplicitSubtitleChoice {
            // A track or Off chosen for this item comes back.
            pendingSubtitleFfIndex = subtitleToRestore
        } else {
            // Auto runs again on the new tracks, with whatever audio this
            // replan may have switched to.
            prefsForCurrentItem = prefsForCurrentItem ?? automaticSubtitlePrefsSnapshot()
            prefsResolvedForCurrentItem = false
        }
        armSidecarRestore(Self.protocolV3SidecarRestoreIntent(
            snapshot: subtitleBeforeReplan,
            selectedSubtitleIndex: replacementPlan?.selectedTracks.subtitle?.index,
            subtitleMode: replacementPlan?.subtitle.mode,
            isEmbedded: replacementPlan?.subtitle.embedded != nil
        ))
        duration = replacement.session.durationSeconds ?? replacement.selectedVersion.duration ?? duration
        currentTime = movieTime(for: replacement.session)
        activeQualityId = replacement.activeQualityId
        activeBandwidthCap = replacement.bandwidthCap
        qualityOptions = Self.playbackQualityOptions(for: replacement)

        try requireCurrentStreamLoad(generation)
        guard let stream = await makeStreamRequest(for: replacement) else {
            throw VividLoadSpec.ValidationError.invalidStreamURL(replacement.session.streamUrl)
        }
        try requireCurrentStreamLoad(generation)
        resolvedServerUrl = stream.serverUrl
        try await loadVivid(
            prepared: replacement,
            streamRequest: stream,
            expectedStreamLoadGeneration: generation,
            shouldPlayWhenReady: vividPlaybackController.shouldPlayWhenReady
        )
        guard await sessionBridge.commitPendingProtocolV3Transition(replacement) else {
            throw CancellationError()
        }
        markProtocolV3VividLoadCommitted()
        onCommit()
        if completesQualitySwitch {
            lastLoadRequest?.preferredQualityOverride = replacement.activeQualityId
            lastLoadRequest?.carriedBandwidthCap = replacement.bandwidthCap
        }
        if sessionBeforeReplan != replacement.session.sessionId {
            await realtimeClient.unbind()
            await realtimeClient.bind(sessionId: replacement.session.sessionId)
        }
        await sessionBridge.reportProtocolV3PlanExecutionStarted(replacement)
    }

    /// Arms the restore of a Silo subtitle file chosen before a reload,
    /// whether Vivid draws it or the server burns it in and the picker keeps
    /// it selected.
    private func armSidecarRestore(_ intent: ProtocolV3SidecarRestoreIntent?) {
        guard let intent else { return }
        switch intent {
        case .renderLocally(let trackId):
            pendingSidecarSubtitleTrackId = trackId
            pendingServerRenderedSubtitleTrackId = nil
        case .serverRendered(let trackId):
            pendingSidecarSubtitleTrackId = nil
            pendingServerRenderedSubtitleTrackId = trackId
        }
    }

    /// The parts of the player a replan changes before its replacement
    /// commits, taken when the replan's task starts so a failed or cancelled
    /// replan can put the item back exactly as it was.
    private struct ReplanUndo {
        let loadEpoch: VividPlaybackController.LoadEpoch?
        private let sessionID: String?
        private let detail: WatchDetail?
        private let version: FileVersion?
        private let plan: PreparedPlaybackV3?
        private let request: LoadRequest?
        private let audioIndex: Int?
        private let subtitleIndex: Int?
        private let sidecarTrack: Int64?
        private let burnedInTrack: Int64?
        private let length: Double
        private let position: Double
        private let qualityID: String
        private let bandwidth: CarriedBandwidthCap
        private let qualities: [ApplePlaybackQualityOption]
        private let serverURL: String
        private let prefs: PrefsSnapshot?
        private let prefsResolved: Bool

        @MainActor
        init(of player: PlayerViewModel) {
            loadEpoch = player.activeVividLoadEpoch
            sessionID = player.activePlaybackSessionId
            detail = player.currentWatchDetail
            version = player.currentSelectedVersion
            plan = player.activePreparedProtocolV3
            request = player.lastLoadRequest
            audioIndex = player.pendingAudioFfIndex
            subtitleIndex = player.pendingSubtitleFfIndex
            sidecarTrack = player.pendingSidecarSubtitleTrackId
            burnedInTrack = player.pendingServerRenderedSubtitleTrackId
            length = player.duration
            position = player.currentTime
            qualityID = player.activeQualityId
            bandwidth = player.activeBandwidthCap
            qualities = player.qualityOptions
            serverURL = player.resolvedServerUrl
            prefs = player.prefsForCurrentItem
            prefsResolved = player.prefsResolvedForCurrentItem
        }

        @MainActor
        func apply(to player: PlayerViewModel) {
            player.activePlaybackSessionId = sessionID
            player.currentWatchDetail = detail
            player.currentSelectedVersion = version
            player.activePreparedProtocolV3 = plan
            player.lastLoadRequest = request
            player.pendingAudioFfIndex = audioIndex
            player.pendingSubtitleFfIndex = subtitleIndex
            player.pendingSidecarSubtitleTrackId = sidecarTrack
            player.pendingServerRenderedSubtitleTrackId = burnedInTrack
            player.duration = length
            player.currentTime = position
            player.activeQualityId = qualityID
            player.activeBandwidthCap = bandwidth
            player.qualityOptions = qualities
            player.resolvedServerUrl = serverURL
            player.prefsForCurrentItem = prefs
            player.prefsResolvedForCurrentItem = prefsResolved
        }
    }

    // MARK: Failure classification

    /// Words in an untyped error message, checked in this order, and the
    /// replan classification each points to.
    private static let failureMessageClues: [(classification: String, clues: [String])] = [
        ("decoder_error", ["decoder", "videotoolbox", "-129"]),
        ("unsupported_stream", ["unsupported", "cannot decode"]),
        ("network_degraded", ["network", "timed out", "connection"]),
        ("source_unavailable", ["http 404", "not found", "source ended"]),
    ]

    /// The classification a replan sends for an error that only has a
    /// message.
    private static func protocolV3FailureClassification(_ message: String) -> String {
        let text = message.lowercased()
        let hit = failureMessageClues.first { entry in entry.clues.contains { text.contains($0) } }
        return hit?.classification ?? "playback_error"
    }

    /// Typed failures that say nothing about whether another route would
    /// play: rate limiting means try the same origin later, and a refused
    /// audio session fails the same way whatever the route.
    static let routeIndependentFailureKinds: Set<PlaybackErrorKind> = [
        .sourceRateLimited,
        .audioSessionUnavailable,
    ]

    /// For a load that failed before its plan committed: whether to step
    /// down to Silo's next route, and the classification and message to send
    /// with it.
    static func protocolV3LoadFailureRecovery(
        _ error: Error
    ) -> (shouldAdvanceRoute: Bool, classification: String, message: String) {
        switch error {
        case let planError as ApplePlaybackV3PlanError:
            if case .invalidEmbeddedSubtitle = planError {
                return (true, "subtitle_embedded_failed", planError.localizedDescription)
            }
        case let missing as VividPlaybackController.EmbeddedSubtitleSelectionError:
            return (true, "subtitle_embedded_failed", missing.localizedDescription)
        case let engineFailure as VividPlaybackController.LoadFailure:
            // Any other typed open failure tells the route ladder something
            // useful, and the bridge's attempt limit keeps the ladder short.
            let kind = engineFailure.failure.kind
            return (!routeIndependentFailureKinds.contains(kind), kind.rawValue, engineFailure.failure.message)
        default:
            break
        }
        let description = error.localizedDescription
        return (true, protocolV3FailureClassification(description), description)
    }
}

fileprivate extension PreparedPlaybackV3 {
    /// Whether a load of this plan can be reopened with refreshed request
    /// headers: Silo's v2 API does, and so does a server that advertises
    /// header-authenticated media.
    var reopensWithFreshHeaders: Bool {
        if plan.nativeApiMajor == 2 { return true }
        return serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }
}
