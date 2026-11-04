import Foundation
import OSLog

/// Recovery of the current item after the engine or its source fails.
///
/// There are three ways back, tried in this order by the callers in
/// `+EngineEvents` and `+PlaybackEnd`:
///
/// - **Same-route reload.** Reopen the committed Silo plan at the current
///   position with fresh request headers. Used for an expired bearer, a
///   transient connection error and a stream that ended early.
/// - **Replan.** Ask Silo for another route (`attemptProtocolV3Replan`). Track,
///   quality, output route and seek-reanchor changes use the same path.
/// - **Stale-session renewal.** Start a new session at the current position
///   (`attemptStaleSessionRenewal`, in `+SessionLoad`), when the server says
///   the session is gone.
///
/// Anything that can't recover ends at the Retry screen through
/// `finalizeTerminalPlaybackError`.
extension PlayerViewModel {
    // MARK: Entry point

    func handlePlaybackError(_ message: String, failure: PlaybackErrorInfo? = nil) {
        let logMessage = MediaLogRedactor.sanitize(message)
        Self.logger.error("Player error: \(logMessage, privacy: .public)")
        guard !hasReachedEndOfFile else {
            Self.logger.info("Ignoring playback error after EOF: \(logMessage, privacy: .public)")
            return
        }
        suppressNextUpForPlaybackFailure()
        if activePreparedProtocolV3 != nil, committedProtocolV3LoadEpoch != nil {
            attemptProtocolV3Recovery(after: message)
            return
        }
        if isPlaybackSessionMissingMessage(message) || isExpiredPlaybackSessionSource(failure),
           attemptStaleSessionRenewal(reason: "player_error", observedPosition: currentTime) {
            return
        }
        progressTask?.cancel()
        finalizeTerminalPlaybackError(message)
    }

    private func attemptProtocolV3Recovery(after message: String) {
        guard protocolV3ReplanTask == nil else { return }
        if !attemptProtocolV3Replan(
            position: currentTime,
            classification: Self.protocolV3FailureClassification(message),
            message: message
        ) {
            finalizeTerminalPlaybackError(message)
        }
    }

    // MARK: Credentials

    /// Rebuilds the committed plan with the account bearer `VividAPI` holds
    /// now. Protocol V3 media URLs don't change when the access token is
    /// refreshed, but the engine fixes its request headers when it opens the
    /// source. The reload goes ahead only when the refresh produced a
    /// different Authorization value.
    @discardableResult
    func attemptProtocolV3AuthenticationReload(after failure: PlaybackErrorInfo) -> Bool {
        guard VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure) else { return false }
        return beginProtocolV3SameRouteReload(
            fallbackClassification: failure.kind.rawValue,
            fallbackMessage: failure.message
        )
    }

    /// The periodic progress report owns token refresh. After a successful
    /// report, hand changed headers to the engine only when it can keep its
    /// current reader. When it can't, nothing changes here: a real media
    /// authentication failure later takes the same-route reload instead.
    ///
    /// `scripts/tests/playback-auth-refresh-tests.py` compiles this method's
    /// body against a stand-in player, so it sticks to the members that
    /// harness provides.
    func updateProtocolV3AuthenticationAfterProgress(
        _ result: PlaybackProgressReportResult
    ) async {
        guard result == .success,
              protocolV3ReplanTask == nil,
              let protocolV3 = activePreparedProtocolV3,
              (protocolV3.plan.nativeApiMajor == 2 || protocolV3.serverFeatures.contains(
                  PlaybackProtocolV3.headerAuthenticatedMediaFeature
              )),
              let sessionId = activePlaybackSessionId,
              let loadEpoch = vividPlaybackController.activeLoadEpoch,
              let failedSpec = vividPlaybackController.activeSpec,
              failedSpec.planID == protocolV3.plan.planId,
              failedSpec.sessionID == sessionId,
              committedProtocolV3LoadEpoch != nil,
              let session = await sessionBridge.committedProtocolV3Session(
                  planId: protocolV3.plan.planId,
                  sessionId: sessionId
              ),
              let streamRequest = await makeStreamRequest(
                  session: session,
                  additionalHeaders: protocolV3.plan.stream.headers,
                  requiresHeaderAuthenticatedMedia: true,
                  allowsAuthorizedMediaOrigins: protocolV3.negotiatedAuthorizedMediaOrigins,
                  nativeApiMajor: protocolV3.plan.nativeApiMajor
              ),
              // Everything below is read again after the awaits, so a reply
              // that lands after a replan or a new load changes nothing.
              activePlaybackSessionId == sessionId,
              activePreparedProtocolV3?.plan.planId == protocolV3.plan.planId,
              vividPlaybackController.activeLoadEpoch == loadEpoch,
              vividPlaybackController.activeSpec?.planID == failedSpec.planID,
              vividPlaybackController.activeSpec?.sessionID == sessionId,
              vividPlaybackController.activeSpec?.options.httpHeaders == failedSpec.options.httpHeaders,
              VividAuthenticationRecoveryPolicy.shouldUpdateHeadersAfterProgress(
                  result,
                  activeHeaders: failedSpec.options.httpHeaders,
                  currentHeaders: streamRequest.headers
              ) else {
            return
        }

        if vividPlaybackController.updateSourceHeaders(
            streamRequest.headers,
            for: loadEpoch,
            expectedHeaders: failedSpec.options.httpHeaders,
            sourceURL: streamRequest.url
        ) {
            Self.logger.info("Stream recovery reason=authorization_rotated outcome=headers_updated")
        }
    }

    /// The engine asks for this when its source answers 401. Refresh the
    /// session's credentials and hand back headers it can use on the same
    /// reader, or nil to let the failure take its usual path.
    func refreshDirectSourceHeaders(
        epoch: VividPlaybackController.LoadEpoch,
        generation: UInt64
    ) async -> [String: String]? {
        guard !Task.isCancelled, !isDisposed, streamLoadGeneration == generation,
              protocolV3ReplanTask == nil,
              vividPlaybackController.activeLoadEpoch == epoch,
              committedProtocolV3LoadEpoch == epoch,
              let spec = vividPlaybackController.activeSpec, !spec.options.nativeRemoteHLS,
              let protocolV3 = activePreparedProtocolV3,
              protocolV3.refreshesMediaHeaders,
              protocolV3.plan.planId == spec.planID,
              let sessionId = activePlaybackSessionId, sessionId == spec.sessionID else { return nil }
        do {
            try await sessionBridge.refreshPlaybackAuthentication(
                sessionId: sessionId,
                position: progressIsEligible && currentTime.isFinite ? max(0, currentTime) : 0,
                isPaused: !vividPlaybackController.shouldPlayWhenReady
            )
            try requireCurrentStreamLoad(generation)
            guard vividPlaybackController.activeLoadEpoch == epoch,
                  let session = await sessionBridge.committedProtocolV3Session(
                      planId: spec.planID, sessionId: sessionId
                  ),
                  let request = await makeHeaderAuthenticatedStreamRequest(session: session, protocolV3: protocolV3)
            else { return nil }
            try requireCurrentStreamLoad(generation)
            guard vividPlaybackController.activeLoadEpoch == epoch,
                  activePlaybackSessionId == sessionId,
                  activePreparedProtocolV3?.plan.planId == spec.planID,
                  request.url == spec.sourceURL,
                  let current = vividPlaybackController.activeSpec else { return nil }
            // Another refresh already installed newer headers.
            if current.options.httpHeaders != spec.options.httpHeaders {
                return current.options.httpHeaders
            }
            guard VividAuthenticationRecoveryPolicy.shouldReload(
                      failedHeaders: spec.options.httpHeaders, refreshedHeaders: request.headers
                  ),
                  vividPlaybackController.updateSourceHeaders(
                      request.headers, for: epoch,
                      expectedHeaders: spec.options.httpHeaders, sourceURL: request.url
                  ) else { return nil }
            Self.logger.info("Stream recovery reason=http_401 outcome=headers_updated")
            return request.headers
        } catch {
            Self.logger.info("Stream recovery reason=http_401 outcome=refresh_unavailable")
            return nil
        }
    }

    // MARK: Same-route reload

    /// Reopens the committed Silo plan at the current position with current
    /// credentials. Returns false when this load can't (another replan is
    /// running, the plan can't take refreshed headers, or the reason's budget
    /// is spent), so the caller tries the next recovery. Returns true once
    /// the reload owns the outcome, including when the authentication budget
    /// is spent and it went straight to Retry.
    ///
    /// - `prematureSourceEnd`: the stream ended early. Bounded by
    ///   `prematureEndRecoveryGate`; reopens even with an unchanged bearer.
    /// - `transientFailureCode`: a recognised connection error. Bounded by
    ///   `transientRecoveryBudget`; no credential refresh first.
    /// - Neither: an expired bearer. Bounded by `authenticationRecoveryBudget`
    ///   and only reloads when the refresh changed the Authorization header.
    @discardableResult
    func beginProtocolV3SameRouteReload(
        fallbackClassification: String,
        fallbackMessage: String,
        transientFailureCode: Int? = nil,
        prematureSourceEnd: Bool = false
    ) -> Bool {
        guard protocolV3ReplanTask == nil,
              let protocolV3 = activePreparedProtocolV3,
              protocolV3.refreshesMediaHeaders,
              let sessionId = activePlaybackSessionId,
              let watchDetail = currentWatchDetail,
              let selectedVersion = currentSelectedVersion,
              let failedSpec = vividPlaybackController.activeSpec,
              failedSpec.planID == protocolV3.plan.planId,
              failedSpec.sessionID == sessionId,
              committedProtocolV3LoadEpoch != nil else {
            return false
        }

        let planId = protocolV3.plan.planId
        let resumePosition = currentTime.isFinite ? max(0, currentTime) : 0
        let failedHeaders = failedSpec.options.httpHeaders
        let recoveryEpisode = freshLoadGeneration
        let isCredentialReload = !prematureSourceEnd && transientFailureCode == nil
        if prematureSourceEnd {
            guard prematureEndRecoveryGate.begin() else { return false }
        } else if transientFailureCode != nil {
            guard transientRecoveryBudget.beginReload() else { return false }
        }
        if isCredentialReload, !authenticationRecoveryBudget.begin(generation: recoveryEpisode) {
            progressTask?.cancel()
            finalizeTerminalPlaybackError(fallbackMessage)
            return true
        }

        progressTask?.cancel()
        progressTask = nil
        isLoading = true
        isBuffering = false
        isLoadingSubtitles = false
        bufferingProgress = nil
        streamLoadGeneration &+= 1
        let recoveryGeneration = streamLoadGeneration
        authenticationReloadGeneration = recoveryGeneration

        if prematureSourceEnd {
            Self.logger.warning("Stream recovery reason=premature_source_end position=\(resumePosition, privacy: .public) outcome=same_route_reload")
        } else if let code = transientFailureCode {
            Self.logger.warning("Stream recovery domain=NSURLErrorDomain code=\(code, privacy: .public) outcome=same_route_reload")
        } else {
            Self.logger.warning(
                "Protocol V3 media credential expired; refreshing and reloading plan \(planId, privacy: .public) at source position \(resumePosition, privacy: .public)"
            )
        }
        Self.logger.info("Stream recovery outcome=session_reconstruction")

        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            var shouldFallBackToReplan = true
            var finalClassification = fallbackClassification
            var finalMessage = fallbackMessage
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                if self.authenticationReloadGeneration == recoveryGeneration {
                    self.authenticationReloadGeneration = nil
                }
                // A newer load or replan owns the handle and the queues once
                // the generation has moved on.
                if !self.isDisposed, recoveryGeneration == self.streamLoadGeneration {
                    self.protocolV3ReplanTask = nil
                    if shouldFallBackToReplan {
                        self.fallBackFromSameRouteReload(
                            classification: finalClassification,
                            message: finalMessage,
                            resumePosition: resumePosition
                        )
                    } else {
                        self.drainQueuedProtocolV3Work(seekSource: "queuedAuthReloadReanchor")
                    }
                }
            }

            do {
                if prematureSourceEnd {
                    // Refresh an expired bearer before reopening. A failure here
                    // still reopens with whatever credential is current.
                    try? await self.sessionBridge.refreshPlaybackAuthentication(
                        sessionId: sessionId,
                        position: self.progressIsEligible ? resumePosition : 0,
                        isPaused: !self.vividPlaybackController.shouldPlayWhenReady
                    )
                } else if isCredentialReload {
                    // This request goes through the normal API transport, whose
                    // 401 handling refreshes TokenStore before retrying. Its
                    // answer is otherwise best effort; the header comparison
                    // below decides.
                    try await self.sessionBridge.refreshPlaybackAuthentication(
                        sessionId: sessionId,
                        position: self.progressIsEligible ? resumePosition : 0,
                        isPaused: !self.vividPlaybackController.shouldPlayWhenReady
                    )
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)
                guard self.activePlaybackSessionId == sessionId,
                      self.activePreparedProtocolV3?.plan.planId == planId,
                      let session = await self.sessionBridge.committedProtocolV3Session(
                          planId: planId,
                          sessionId: sessionId
                      ) else {
                    throw CancellationError()
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)

                let prepared = PreparedPlayback(
                    watchDetail: watchDetail,
                    selectedVersion: selectedVersion,
                    session: session,
                    activeQualityId: self.activeQualityId,
                    bandwidthCap: self.activeBandwidthCap,
                    protocolV3: protocolV3
                )
                guard let streamRequest = await self.makeHeaderAuthenticatedStreamRequest(
                    session: session, protocolV3: protocolV3
                ) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)
                // An early end or a dropped connection reopens even with the
                // same bearer: the connection was lost, not the credential.
                guard !isCredentialReload || VividAuthenticationRecoveryPolicy.shouldReload(
                    failedHeaders: failedHeaders,
                    refreshedHeaders: streamRequest.headers
                ) else {
                    finalClassification = "authentication"
                    Self.logger.warning(
                        "Protocol V3 media credential did not change; using bounded route recovery"
                    )
                    return
                }

                // A local seek inside the window can finish while the refresh
                // was suspended. Read the position again at the last
                // synchronous point before `beginLoad` replaces the epoch, so
                // the reload never jumps back over that seek.
                let reloadPosition = self.currentTime.isFinite ? max(0, self.currentTime) : resumePosition
                let shouldPlayWhenReady = self.vividPlaybackController.shouldPlayWhenReady
                self.pendingAudioFfIndex = self.resolvedAudioTrackIndexForResume()
                self.pendingSubtitleFfIndex = self.resolvedSubtitleTrackIndexForResume()
                if let subtitle = self.selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(subtitle) {
                    self.armSidecarRestore(Self.protocolV3SidecarRestoreIntent(
                        snapshot: subtitle,
                        selectedSubtitleIndex: protocolV3.plan.selectedTracks.subtitle?.index,
                        subtitleMode: protocolV3.plan.subtitle.mode,
                        isEmbedded: protocolV3.plan.subtitle.embedded != nil
                    ))
                }
                self.resolvedServerUrl = streamRequest.serverUrl
                try await self.loadVivid(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: recoveryGeneration,
                    resumeSourcePosition: reloadPosition,
                    shouldPlayWhenReady: shouldPlayWhenReady
                )
                try self.requireCurrentStreamLoad(recoveryGeneration)
                guard self.activePlaybackSessionId == sessionId,
                      self.activePreparedProtocolV3?.plan.planId == planId else {
                    throw CancellationError()
                }
                self.applySecondarySubtitleTrackSelection(self.selectedSecondarySubtitleId)
                self.markProtocolV3VividLoadCommitted()
                try await self.confirmAuthenticationRecovery(
                    generation: recoveryGeneration,
                    transientRecovery: transientFailureCode != nil
                )
                if transientFailureCode == nil {
                    self.authenticationRecoveryBudget.recovered(generation: recoveryEpisode)
                }
                shouldFallBackToReplan = false
                Self.logger.info("Stream recovery outcome=recovered")
            } catch is CancellationError {
                shouldFallBackToReplan = false
                Self.logger.info("Stream recovery outcome=cancelled")
            } catch {
                let failure = VividAuthenticationRecoveryPolicy.finalFailure(error)
                finalClassification = VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure)
                    ? "authentication" : failure.kind.rawValue
                finalMessage = failure.message
                Self.logger.error(
                    "Stream recovery outcome=failed classification=\(finalClassification, privacy: .public) code=\(failure.underlyingCode ?? 0, privacy: .public)"
                )
            }
        }
        return true
    }

    /// A same-route reload that didn't recover. An authentication failure
    /// would fail on every route, and a refused audio session too, so those
    /// stop at Retry; anything else asks Silo for the next route.
    private func fallBackFromSameRouteReload(classification: String, message: String, resumePosition: Double) {
        if classification == "authentication"
            || classification == PlaybackErrorKind.audioSessionUnavailable.rawValue {
            finalizeTerminalPlaybackError(message)
        } else if !attemptProtocolV3Replan(
            position: currentTime.isFinite ? max(0, currentTime) : resumePosition,
            classification: classification,
            message: message
        ) {
            finalizeTerminalPlaybackError(message)
        }
    }

    /// Waits up to 12 seconds for the reopened source to show it plays: ready,
    /// and advancing (or settled while paused). Throws the engine's failure
    /// if one arrives first.
    private func confirmAuthenticationRecovery(generation: UInt64, transientRecovery: Bool = false) async throws {
        let engine = vividPlaybackController.engine
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var readiness = VividAuthenticationRecoveryReadiness()
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireCurrentStreamLoad(generation)
            if let failure = engine.errorInfo { throw failure }
            let ready = engine.currentAVPlayer.map { $0.currentItem?.status == .readyToPlay }
                ?? (engine.hasFirstFrameReadyForDisplay || engine.videoRoute == .audio)
            if readiness.observe(
                time: engine.clock.currentTime,
                ready: ready,
                wantsPlayback: vividPlaybackController.shouldPlayWhenReady,
                playing: engine.state == .playing,
                paused: engine.state == .paused,
                seeking: engine.isSeeking || seekTargetTime != nil
            ) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PlaybackErrorInfo(
            kind: .vodSourceFailed,
            message: transientRecovery
                ? "Playback did not resume after reconnecting the media source."
                : "Playback did not resume after renewing authentication.",
            underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorTimedOut
        )
    }

    private func makeHeaderAuthenticatedStreamRequest(
        session: PlaybackSessionResponse,
        protocolV3: PreparedPlaybackV3
    ) async -> StreamRequest? {
        await makeStreamRequest(
            session: session,
            additionalHeaders: protocolV3.plan.stream.headers,
            requiresHeaderAuthenticatedMedia: true,
            allowsAuthorizedMediaOrigins: protocolV3.negotiatedAuthorizedMediaOrigins,
            nativeApiMajor: protocolV3.plan.nativeApiMajor
        )
    }

    // MARK: Queued track changes

    /// The track a queued change asks for. `.subtitle(nil)` turns subtitles
    /// off, which is why this is an enum and not two optional IDs.
    ///
    /// Each case carries the Vivid `trackId` the viewer tapped and the server
    /// identity the deferred replan is resolved from: the audio selection
    /// ordinal (`srcId ?? ffIndex`) and the subtitle combined index. The
    /// replan in flight can repackage streams, so a Vivid ID recorded before
    /// it can vanish or name another stream by the time the queue drains; the
    /// server identity survives that.
    enum QueuedProtocolV3TrackTarget {
        case audio(trackId: Int64, selectionIndex: Int?)
        case subtitle(trackId: Int64?, combinedIndex: Int?)
    }

    func queuedTrackTarget(forAudio track: PlayerTrack) -> QueuedProtocolV3TrackTarget {
        .audio(trackId: track.trackId, selectionIndex: audioSelectionIndex(for: track))
    }

    /// A track change waiting for the replan in flight to settle.
    ///
    /// The position isn't stored: playback keeps moving while it waits, so
    /// it's read when the queue drains. The target is stored: the replan in
    /// flight publishes its own plan's tracks on the way through, and
    /// `adoptVividInventory` republishes the selection from the engine, so
    /// reading the selection at drain time would ask for the track the viewer
    /// was already on and drop the tap.
    struct QueuedProtocolV3TrackChange {
        let classification: String
        let message: String
        let target: QueuedProtocolV3TrackTarget?
    }

    private func serverCombinedSubtitleIndex(for track: PlayerTrack) -> Int? {
        guard let version = currentSelectedVersion else { return nil }
        return ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
            for: track,
            in: version,
            inventory: activePreparedProtocolV3?.plan.subtitle.inventory ?? []
        )
    }

    /// Puts a queued pick back in the selection just before the deferred
    /// replan reads it, undoing any republish from the interim plan.
    ///
    /// The recorded Vivid ID is tried first, then the server identity
    /// captured at queue time, so a renumbered stream still finds the tap. A
    /// target that matches neither is dropped: the interim plan may not carry
    /// that track, and a selection pointing at nothing resolves to no index,
    /// which is worse than the track that's playing.
    private func restoreQueuedProtocolV3TrackSelection(_ target: QueuedProtocolV3TrackTarget) {
        switch target {
        case .audio(let trackId, let selectionIndex):
            let resolved = audioTracks.first { $0.trackId == trackId }
                ?? selectionIndex.flatMap { wanted in
                    audioTracks.first { audioSelectionIndex(for: $0) == wanted }
                }
            guard let resolved, selectedAudioId != resolved.trackId else { return }
            pendingAudioFfIndex = nil
            selectedAudioId = resolved.trackId
            reapplyAutomaticSubtitlePolicy()
        case .subtitle(let trackId, let combinedIndex):
            guard let trackId else {
                guard selectedSubtitleId != nil else { return }
                pendingSubtitleFfIndex = nil
                hasExplicitSubtitleChoice = true
                selectedSubtitleId = nil
                return
            }
            let resolved = subtitleTracks.first { $0.trackId == trackId }
                ?? combinedIndex.flatMap { wanted in
                    subtitleTracks.first { serverCombinedSubtitleIndex(for: $0) == wanted }
                }
            guard let resolved, selectedSubtitleId != resolved.trackId else { return }
            pendingSubtitleFfIndex = nil
            hasExplicitSubtitleChoice = true
            selectedSubtitleId = resolved.trackId
        }
    }

    /// Runs the queued track change, or else the queued seek, once the replan
    /// or reload that held them has settled. The track change goes first: its
    /// replan drains a still-pending seek in turn, so both survive and the
    /// seek lands last.
    /// `canIssue` false still empties the queue but sends nothing.
    private func drainQueuedProtocolV3Work(seekSource: String, canIssue: Bool = true) {
        if let queued = pendingProtocolV3TrackChange {
            pendingProtocolV3TrackChange = nil
            guard canIssue else { return }
            attemptProtocolV3Replan(
                position: currentTime,
                classification: queued.classification,
                message: queued.message,
                requeueWhenBusy: true,
                trackTarget: queued.target
            )
        } else if let target = pendingProtocolV3SeekReanchorPosition {
            pendingProtocolV3SeekReanchorPosition = nil
            guard canIssue else { return }
            commitSeek(to: target, source: seekSource)
        }
    }

    // MARK: Replan

    /// Asks Silo for a new plan and reloads onto it. Used for recovery and
    /// for track, quality, output route and seek-reanchor changes.
    ///
    /// Returns false when nothing was started: a track target with no server
    /// identity, no current item, or a replan already running (a seek
    /// reanchor and a `requeueWhenBusy` track change queue instead and
    /// return true). Returns true once the replan owns the outcome.
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
        // A track change needs a stable server ordinal before it's queued or
        // sent. Falling back to the engine's current selection would turn a
        // tap that can't be mapped into a replan for the track already
        // playing. The dimension the viewer didn't touch stays nil and is
        // read back from the player below, after any queued pick is restored.
        let explicitAudioTrackIndex: Int?
        let explicitSubtitleTrackIndex: Int?
        let targetsSubtitle: Bool
        switch trackTarget {
        case .audio(_, nil), .subtitle(.some, nil):
            return false
        case .audio(_, let selectionIndex):
            explicitAudioTrackIndex = selectionIndex
            explicitSubtitleTrackIndex = nil
            targetsSubtitle = false
        case .subtitle(let trackId, let combinedIndex):
            explicitAudioTrackIndex = nil
            // No track ID is an explicit Off.
            explicitSubtitleTrackIndex = trackId == nil ? nil : combinedIndex
            targetsSubtitle = true
        case nil:
            explicitAudioTrackIndex = nil
            explicitSubtitleTrackIndex = nil
            targetsSubtitle = false
        }
        if protocolV3ReplanTask != nil {
            if operation == PlaybackProtocolV3.ReplanOperation.seekReanchor {
                // Rapid seeks in the window are latest-wins, issued once the
                // route change in flight settles.
                pendingProtocolV3SeekReanchorPosition = position
                return true
            }
            if requeueWhenBusy {
                // A track change the UI already shows. Dropping it would leave
                // the player disagreeing with itself, so it's queued,
                // latest-wins, and sent at whatever position playback reaches.
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
        guard let watchDetail = currentWatchDetail else {
            if completesQualitySwitch { isQualitySwitching = false }
            return false
        }
        // On the deferred path the selection may have been republished from
        // the interim plan while the pick waited, so put the pick back before
        // reading it. On the direct path this changes nothing.
        if let trackTarget {
            restoreQueuedProtocolV3TrackSelection(trackTarget)
        }
        let selectedSubtitleSnapshot = selectedSubtitleId
        // The selection can be republished by the engine while the task waits
        // to start, so the request's indices are fixed here rather than read
        // inside the task.
        let requestedAudioTrackIndex = explicitAudioTrackIndex ?? resolvedAudioTrackIndexForResume()
        let requestedSubtitleTrackIndex = targetsSubtitle
            ? explicitSubtitleTrackIndex
            : resolvedProtocolV3SubtitleIndexForResume()
        if targetsSubtitle {
            cmpLog(
                "[CMP-SUB] phase=replan_request requested_index="
                    + (requestedSubtitleTrackIndex.map(String.init) ?? "off")
            )
        }
        progressTask?.cancel()
        isLoading = true
        isBuffering = false
        isLoadingSubtitles = false
        bufferingProgress = nil
        streamLoadGeneration &+= 1
        let replanGeneration = streamLoadGeneration
        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let rollback = ProtocolV3ReplanRollback(capturing: self)
            var uncommittedPrepared: PreparedPlayback?
            var chainedLoadFailureRecovery: (position: Double, classification: String, message: String)?
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                // Once a new load or teardown has moved the generation on, the
                // handle, the quality switch flag and the queues belong to it.
                if replanGeneration == self.streamLoadGeneration {
                    self.protocolV3ReplanTask = nil
                    if completesQualitySwitch { self.isQualitySwitching = false }
                    if let recovery = chainedLoadFailureRecovery {
                        self.attemptProtocolV3Replan(
                            position: recovery.position,
                            classification: recovery.classification,
                            message: recovery.message
                        )
                    } else {
                        self.drainQueuedProtocolV3Work(
                            seekSource: "queuedReanchor",
                            canIssue: !self.isDisposed && self.activePreparedProtocolV3 != nil
                        )
                    }
                }
            }
            do {
                #if DEBUG
                self.testRecorder?.record(.serverReplan(classification: classification))
                #endif
                let answer = try await self.sessionBridge.replanProtocolV3(
                    watchDetail: watchDetail,
                    position: position,
                    classification: classification,
                    message: message,
                    operation: operation,
                    qualityPreference: qualityPreference,
                    audioTrackIndex: requestedAudioTrackIndex,
                    subtitleTrackIndex: requestedSubtitleTrackIndex,
                    outputRouteSnapshot: outputRouteSnapshot
                )
                guard let prepared = answer else {
                    // A refusal ends this item, but only if it's still current.
                    try self.requireCurrentStreamLoad(replanGeneration)
                    self.finalizeTerminalPlaybackError(message)
                    return
                }
                if targetsSubtitle {
                    cmpLog(
                        "[CMP-SUB] phase=replan_response selected_index="
                            + (prepared.protocolV3?.plan.selectedTracks.subtitle?.index.map(String.init) ?? "off")
                            + " mode="
                            + (prepared.protocolV3?.plan.subtitle.mode ?? "unknown")
                    )
                }
                uncommittedPrepared = prepared
                try self.requireCurrentStreamLoad(replanGeneration)

                // The replacement starts with subtitles off and Silo is asked
                // for none, because Vivid draws them. Read the playing subtitle
                // back now, after the wait (a pick or Off made meanwhile
                // counts) and while the old plan still describes it.
                let subtitleIndexForReload = targetsSubtitle ? nil : self.resolvedSubtitleTrackIndexForResume()
                let previousSessionId = self.activePlaybackSessionId
                self.activePlaybackSessionId = prepared.session.sessionId
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.adoptProtocolV3RenewalIntent(from: prepared)
                if !targetsSubtitle {
                    if self.hasExplicitSubtitleChoice {
                        // A track (or Off) picked for this item comes back.
                        self.pendingSubtitleFfIndex = subtitleIndexForReload
                    } else {
                        // Auto runs again on the new tracks, with the audio
                        // this replan may have switched.
                        self.prefsForCurrentItem = self.prefsForCurrentItem
                            ?? self.automaticSubtitlePrefsSnapshot()
                        self.prefsResolvedForCurrentItem = false
                    }
                }
                self.armSidecarRestore(Self.protocolV3SidecarRestoreIntent(
                    snapshot: selectedSubtitleSnapshot,
                    selectedSubtitleIndex: prepared.protocolV3?.plan.selectedTracks.subtitle?.index,
                    subtitleMode: prepared.protocolV3?.plan.subtitle.mode,
                    isEmbedded: prepared.protocolV3?.plan.subtitle.embedded != nil
                ))
                self.duration = prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? self.duration
                self.currentTime = self.movieTime(for: prepared.session)
                self.activeQualityId = prepared.activeQualityId
                self.activeBandwidthCap = prepared.bandwidthCap
                self.qualityOptions = Self.playbackQualityOptions(for: prepared)

                try self.requireCurrentStreamLoad(replanGeneration)
                guard let streamRequest = await self.makeStreamRequest(for: prepared) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(prepared.session.streamUrl)
                }
                try self.requireCurrentStreamLoad(replanGeneration)
                self.resolvedServerUrl = streamRequest.serverUrl
                try await self.loadVivid(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: replanGeneration,
                    shouldPlayWhenReady: self.vividPlaybackController.shouldPlayWhenReady
                )
                guard await self.sessionBridge.commitPendingProtocolV3Transition(prepared) else {
                    throw CancellationError()
                }
                self.markProtocolV3VividLoadCommitted()
                uncommittedPrepared = nil
                if completesQualitySwitch {
                    self.lastLoadRequest?.preferredQualityOverride = prepared.activeQualityId
                    self.lastLoadRequest?.carriedBandwidthCap = prepared.bandwidthCap
                }
                if previousSessionId != prepared.session.sessionId {
                    await self.realtimeClient.unbind()
                    await self.realtimeClient.bind(sessionId: prepared.session.sessionId)
                }
                await self.sessionBridge.reportProtocolV3PlanExecutionStarted(prepared)
            } catch is CancellationError {
                // Same rule as a fresh load: an abandoned replacement mustn't
                // leave the engine reading a retired session. The engine only
                // holds the candidate once `loadVivid` moved the epoch; before
                // that the previous source is still playing.
                if replanGeneration == self.streamLoadGeneration,
                   self.activeVividLoadEpoch != rollback.vividLoadEpoch {
                    _ = self.disposeVividPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if replanGeneration == self.streamLoadGeneration {
                    rollback.restore(into: self)
                }
                return
            } catch {
                let loadFailure = Self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    // The engine refused the replacement before it committed.
                    // Report that exact failed plan and step down the bounded
                    // route ladder. No realtime, first-frame or success event
                    // goes out for it.
                    if loadFailure.shouldAdvanceRoute,
                       await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(uncommittedPrepared) {
                        chainedLoadFailureRecovery = (position, loadFailure.classification, loadFailure.message)
                        return
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if replanGeneration == self.streamLoadGeneration {
                    rollback.restore(into: self)
                }
                guard !Task.isCancelled, !self.isDisposed else { return }
                Self.logger.error(
                    "Protocol V3 replan failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
                if PlaybackSessionBridge.isPlaybackSessionMissing(error),
                   self.attemptStaleSessionRenewal(
                       reason: "protocol_v3_replan_missing_session",
                       observedPosition: position
                   ) {
                    return
                }
                self.finalizeTerminalPlaybackError(error.localizedDescription)
            }
        }
        return true
    }

    /// Arms the restore of a Silo subtitle file picked before a reload: drawn
    /// by Vivid, or burned in by the server and kept selected in the picker.
    private func armSidecarRestore(_ intent: ProtocolV3SidecarRestoreIntent?) {
        switch intent {
        case .renderLocally(let trackId):
            pendingSidecarSubtitleTrackId = trackId
            pendingServerRenderedSubtitleTrackId = nil
        case .serverRendered(let trackId):
            pendingSidecarSubtitleTrackId = nil
            pendingServerRenderedSubtitleTrackId = trackId
        case nil:
            break
        }
    }

    /// What a replan changes before its replacement commits, captured when it
    /// starts so a failed or cancelled replan puts the item back as it was.
    private struct ProtocolV3ReplanRollback {
        let vividLoadEpoch: VividPlaybackController.LoadEpoch?
        let playbackSessionId: String?
        let watchDetail: WatchDetail?
        let selectedVersion: FileVersion?
        let preparedProtocolV3: PreparedPlaybackV3?
        let lastLoadRequest: LoadRequest?
        let pendingAudioFfIndex: Int?
        let pendingSubtitleFfIndex: Int?
        let pendingSidecarSubtitleTrackId: Int64?
        let pendingServerRenderedSubtitleTrackId: Int64?
        let duration: Double
        let currentTime: Double
        let activeQualityId: String
        let activeBandwidthCap: CarriedBandwidthCap
        let qualityOptions: [ApplePlaybackQualityOption]
        let resolvedServerUrl: String
        let prefsForCurrentItem: PrefsSnapshot?
        let prefsResolvedForCurrentItem: Bool

        @MainActor
        init(capturing model: PlayerViewModel) {
            vividLoadEpoch = model.activeVividLoadEpoch
            playbackSessionId = model.activePlaybackSessionId
            watchDetail = model.currentWatchDetail
            selectedVersion = model.currentSelectedVersion
            preparedProtocolV3 = model.activePreparedProtocolV3
            lastLoadRequest = model.lastLoadRequest
            pendingAudioFfIndex = model.pendingAudioFfIndex
            pendingSubtitleFfIndex = model.pendingSubtitleFfIndex
            pendingSidecarSubtitleTrackId = model.pendingSidecarSubtitleTrackId
            pendingServerRenderedSubtitleTrackId = model.pendingServerRenderedSubtitleTrackId
            duration = model.duration
            currentTime = model.currentTime
            activeQualityId = model.activeQualityId
            activeBandwidthCap = model.activeBandwidthCap
            qualityOptions = model.qualityOptions
            resolvedServerUrl = model.resolvedServerUrl
            prefsForCurrentItem = model.prefsForCurrentItem
            prefsResolvedForCurrentItem = model.prefsResolvedForCurrentItem
        }

        @MainActor
        func restore(into model: PlayerViewModel) {
            model.activePlaybackSessionId = playbackSessionId
            model.currentWatchDetail = watchDetail
            model.currentSelectedVersion = selectedVersion
            model.activePreparedProtocolV3 = preparedProtocolV3
            model.lastLoadRequest = lastLoadRequest
            model.pendingAudioFfIndex = pendingAudioFfIndex
            model.pendingSubtitleFfIndex = pendingSubtitleFfIndex
            model.pendingSidecarSubtitleTrackId = pendingSidecarSubtitleTrackId
            model.pendingServerRenderedSubtitleTrackId = pendingServerRenderedSubtitleTrackId
            model.duration = duration
            model.currentTime = currentTime
            model.activeQualityId = activeQualityId
            model.activeBandwidthCap = activeBandwidthCap
            model.qualityOptions = qualityOptions
            model.resolvedServerUrl = resolvedServerUrl
            model.prefsForCurrentItem = prefsForCurrentItem
            model.prefsResolvedForCurrentItem = prefsResolvedForCurrentItem
        }
    }

    // MARK: Failure classification

    /// The classification sent with a replan for an untyped error message.
    private static func protocolV3FailureClassification(_ message: String) -> String {
        let value = message.lowercased()
        if value.contains("decoder") || value.contains("videotoolbox") || value.contains("-129") {
            return "decoder_error"
        }
        if value.contains("unsupported") || value.contains("cannot decode") {
            return "unsupported_stream"
        }
        if value.contains("network") || value.contains("timed out") || value.contains("connection") {
            return "network_degraded"
        }
        if value.contains("http 404") || value.contains("not found") || value.contains("source ended") {
            return "source_unavailable"
        }
        return "playback_error"
    }

    /// Typed failures that say nothing about whether another route would play.
    /// Rate limiting is a retry-later condition at the same origin, and a
    /// refused audio session fails the same way on every route.
    static let routeIndependentFailureKinds: Set<PlaybackErrorKind> = [
        .sourceRateLimited,
        .audioSessionUnavailable,
    ]

    /// Whether a load that failed before its plan committed should step down
    /// to Silo's next route, and the classification and message to send.
    static func protocolV3LoadFailureRecovery(
        _ error: Error
    ) -> (shouldAdvanceRoute: Bool, classification: String, message: String) {
        if let error = error as? ApplePlaybackV3PlanError, case .invalidEmbeddedSubtitle = error {
            return (true, "subtitle_embedded_failed", error.localizedDescription)
        }
        if let failure = error as? VividPlaybackController.EmbeddedSubtitleSelectionError {
            return (true, "subtitle_embedded_failed", failure.localizedDescription)
        }
        if let loadFailure = error as? VividPlaybackController.LoadFailure {
            // Every other typed open failure is useful evidence for the route
            // ladder, which the bridge's attempt limit keeps bounded.
            let failure = loadFailure.failure
            return (!routeIndependentFailureKinds.contains(failure.kind), failure.kind.rawValue, failure.message)
        }
        let message = error.localizedDescription
        return (true, protocolV3FailureClassification(message), message)
    }
}

fileprivate extension PreparedPlaybackV3 {
    /// Whether a load of this plan can be reopened with refreshed request
    /// headers: Silo's v2 API, or a server that advertises header
    /// authenticated media.
    var refreshesMediaHeaders: Bool {
        plan.nativeApiMajor == 2 || serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }
}
