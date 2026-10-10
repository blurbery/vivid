import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

extension PlayerViewModel {
    func handlePlaybackError(_ message: String, failure: PlaybackErrorInfo? = nil) {
        let logMessage = MediaLogRedactor.sanitize(message)
        Self.logger.error("Player error: \(logMessage, privacy: .public)")
        guard !hasReachedEndOfFile else {
            Self.logger.info("Ignoring playback error after EOF: \(logMessage, privacy: .public)")
            return
        }
        suppressNextUpForPlaybackFailure()
        if activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch != nil {
            attemptProtocolV3Recovery(after: message)
            return
        }
        if isPlaybackSessionMissingMessage(message) || isExpiredPlaybackSessionSource(failure) {
            if attemptStaleSessionRenewal(reason: "player_error", observedPosition: currentTime) {
                return
            }
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

    /// Rebuilds the committed plan with the account bearer currently held by
    /// `VividAPI`. Protocol V3 media URLs are stable across access-token
    /// refreshes, but Vivid/AVPlayer freezes request headers at asset load.
    /// A normal authenticated progress request first gives the shared HTTP
    /// client a chance to refresh an expired token; the reload proceeds only
    /// when that produced a different Authorization value.
    @discardableResult
    func attemptProtocolV3AuthenticationReload(
        after failure: PlaybackErrorInfo
    ) -> Bool {
        guard VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure) else {
            return false
        }
        return beginProtocolV3SameRouteReload(
            fallbackClassification: failure.kind.rawValue,
            fallbackMessage: failure.message
        )
    }

    /// Progress owns token refresh. Adopt new headers only when the engine can
    /// preserve the active reader. Unsupported updates wait for actual media
    /// authentication failure, which retains same-route reload recovery.
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
                  allowsAuthorizedMediaOrigins:
                      protocolV3.negotiatedAuthorizedMediaOrigins,
                  nativeApiMajor: protocolV3.plan.nativeApiMajor
              ),
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

        if vividPlaybackController.updateSourceHeaders(streamRequest.headers, for: loadEpoch,
            expectedHeaders: failedSpec.options.httpHeaders, sourceURL: streamRequest.url) {
            Self.logger.info("Stream recovery reason=authorization_rotated outcome=headers_updated")
        }
    }

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
              (protocolV3.plan.nativeApiMajor == 2 || protocolV3.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)),
              protocolV3.plan.planId == spec.planID,
              let sessionId = activePlaybackSessionId, sessionId == spec.sessionID else { return nil }
        do {
            try await sessionBridge.refreshPlaybackAuthentication(sessionId: sessionId,
                position: progressIsEligible && currentTime.isFinite ? max(0, currentTime) : 0,
                isPaused: !vividPlaybackController.shouldPlayWhenReady)
            try requireCurrentStreamLoad(generation)
            guard vividPlaybackController.activeLoadEpoch == epoch,
                  let session = await sessionBridge.committedProtocolV3Session(
                    planId: spec.planID, sessionId: sessionId),
                  let request = await makeStreamRequest(session: session,
                    additionalHeaders: protocolV3.plan.stream.headers,
                    requiresHeaderAuthenticatedMedia: true,
                    allowsAuthorizedMediaOrigins: protocolV3.negotiatedAuthorizedMediaOrigins,
                    nativeApiMajor: protocolV3.plan.nativeApiMajor) else { return nil }
            try requireCurrentStreamLoad(generation)
            guard vividPlaybackController.activeLoadEpoch == epoch,
                  activePlaybackSessionId == sessionId,
                  activePreparedProtocolV3?.plan.planId == spec.planID,
                  request.url == spec.sourceURL,
                  let current = vividPlaybackController.activeSpec else { return nil }
            if current.options.httpHeaders != spec.options.httpHeaders {
                return current.options.httpHeaders
            }
            guard VividAuthenticationRecoveryPolicy.shouldReload(
                failedHeaders: spec.options.httpHeaders, refreshedHeaders: request.headers),
                  vividPlaybackController.updateSourceHeaders(request.headers, for: epoch,
                    expectedHeaders: spec.options.httpHeaders, sourceURL: request.url) else { return nil }
            Self.logger.info("Stream recovery reason=http_401 outcome=headers_updated")
            return request.headers
        } catch {
            Self.logger.info("Stream recovery reason=http_401 outcome=refresh_unavailable")
            return nil
        }
    }

    @discardableResult
    func beginProtocolV3SameRouteReload(
        fallbackClassification: String,
        fallbackMessage: String,
        transientFailureCode: Int? = nil,
        prematureSourceEnd: Bool = false
    ) -> Bool {
        guard protocolV3ReplanTask == nil,
              let protocolV3 = activePreparedProtocolV3,
              (protocolV3.plan.nativeApiMajor == 2 || protocolV3.serverFeatures.contains(
                  PlaybackProtocolV3.headerAuthenticatedMediaFeature
              )),
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
        if prematureSourceEnd {
            guard prematureEndRecoveryGate.begin() else { return false }
        } else if transientFailureCode != nil {
            guard transientRecoveryBudget.beginReload() else { return false }
        }
        guard prematureSourceEnd || transientFailureCode != nil
                || authenticationRecoveryBudget.begin(generation: recoveryEpisode) else {
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
            var shouldFallbackToReplan = true
            var finalClassification = fallbackClassification
            var finalMessage = fallbackMessage
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                if self.authenticationReloadGeneration == recoveryGeneration {
                    self.authenticationReloadGeneration = nil
                }
                if !self.isDisposed,
                   recoveryGeneration == self.streamLoadGeneration {
                    self.protocolV3ReplanTask = nil
                    if shouldFallbackToReplan {
                        // A refused audio session would refuse every route too,
                        // so it stops at Retry instead of stepping down a rung.
                        if finalClassification == "authentication"
                            || finalClassification == PlaybackErrorKind.audioSessionUnavailable.rawValue {
                            self.finalizeTerminalPlaybackError(finalMessage)
                        } else if !self.attemptProtocolV3Replan(
                            position: self.currentTime.isFinite ? max(0, self.currentTime) : resumePosition,
                            classification: finalClassification,
                            message: finalMessage
                        ) {
                            self.finalizeTerminalPlaybackError(finalMessage)
                        }
                    } else if let queuedTrackChange = self.pendingProtocolV3TrackChange {
                        self.pendingProtocolV3TrackChange = nil
                        self.attemptProtocolV3Replan(
                            position: self.currentTime,
                            classification: queuedTrackChange.classification,
                            message: queuedTrackChange.message,
                            requeueWhenBusy: true,
                            trackTarget: queuedTrackChange.target
                        )
                    } else if let queuedTarget = self.pendingProtocolV3SeekReanchorPosition {
                        self.pendingProtocolV3SeekReanchorPosition = nil
                        self.commitSeek(to: queuedTarget, source: "queuedAuthReloadReanchor")
                    } else {
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
                } else if transientFailureCode == nil {
                    // This request uses the normal API transport, whose 401 path
                    // refreshes TokenStore before retrying. Its result is otherwise
                    // best-effort; the header comparison below is authoritative.
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
                guard let streamRequest = await self.makeStreamRequest(
                    session: session,
                    additionalHeaders: protocolV3.plan.stream.headers,
                    requiresHeaderAuthenticatedMedia: true,
                    allowsAuthorizedMediaOrigins:
                        protocolV3.negotiatedAuthorizedMediaOrigins,
                    nativeApiMajor: protocolV3.plan.nativeApiMajor
                ) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(session.streamUrl)
                }
                try self.requireCurrentStreamLoad(recoveryGeneration)
                // An early end reopens even with an unchanged bearer: the
                // connection was lost, not necessarily the credential.
                guard prematureSourceEnd || transientFailureCode != nil || VividAuthenticationRecoveryPolicy.shouldReload(
                    failedHeaders: failedHeaders,
                    refreshedHeaders: streamRequest.headers
                ) else {
                    finalClassification = "authentication"
                    Self.logger.warning(
                        "Protocol V3 media credential did not change; using bounded route recovery"
                    )
                    return
                }

                // A local in-window seek can finish while the refresh request
                // is suspended. Sample the source-axis position again at the
                // last synchronous point before beginLoad replaces the epoch,
                // so credential recovery never jumps back over that seek.
                let reloadPosition = self.currentTime.isFinite
                    ? max(0, self.currentTime)
                    : resumePosition
                let shouldPlayWhenReady = self.vividPlaybackController.shouldPlayWhenReady
                self.pendingAudioFfIndex = self.resolvedAudioTrackIndexForResume()
                self.pendingSubtitleFfIndex = self.resolvedSubtitleTrackIndexForResume()
                if let subtitle = self.selectedSubtitleId, SubtitleTrackIdSpace.isSidecar(subtitle) {
                    switch Self.protocolV3SidecarRestoreIntent(
                        snapshot: subtitle,
                        selectedSubtitleIndex: protocolV3.plan.selectedTracks.subtitle?.index,
                        subtitleMode: protocolV3.plan.subtitle.mode,
                        isEmbedded: protocolV3.plan.subtitle.embedded != nil
                    ) {
                    case .renderLocally(let trackId):
                        self.pendingSidecarSubtitleTrackId = trackId
                        self.pendingServerRenderedSubtitleTrackId = nil
                    case .serverRendered(let trackId):
                        self.pendingSidecarSubtitleTrackId = nil
                        self.pendingServerRenderedSubtitleTrackId = trackId
                    case nil: break
                    }
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
                try await self.confirmAuthenticationRecovery(generation: recoveryGeneration,
                    transientRecovery: transientFailureCode != nil)
                if transientFailureCode == nil {
                    self.authenticationRecoveryBudget.recovered(generation: recoveryEpisode)
                }
                shouldFallbackToReplan = false
                Self.logger.info(
                    "Stream recovery outcome=recovered"
                )
            } catch is CancellationError {
                shouldFallbackToReplan = false
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

    private func confirmAuthenticationRecovery(generation: UInt64, transientRecovery: Bool = false) async throws {
        let engine = vividPlaybackController.engine
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var readiness = VividAuthenticationRecoveryReadiness()
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireCurrentStreamLoad(generation)
            if let failure = engine.errorInfo { throw failure }
            let time = engine.clock.currentTime
            let wantsPlayback = vividPlaybackController.shouldPlayWhenReady
            let ready = engine.currentAVPlayer.map { $0.currentItem?.status == .readyToPlay }
                ?? (engine.hasFirstFrameReadyForDisplay || engine.videoRoute == .audio)
            if readiness.observe(time: time, ready: ready,
                wantsPlayback: wantsPlayback,
                playing: engine.state == .playing, paused: engine.state == .paused,
                seeking: engine.isSeeking || seekTargetTime != nil) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw PlaybackErrorInfo(kind: .vodSourceFailed,
            message: transientRecovery ? "Playback did not resume after reconnecting the media source." : "Playback did not resume after renewing authentication.",
            underlyingDomain: NSURLErrorDomain, underlyingCode: NSURLErrorTimedOut)
    }

    /// The track a queued change is actually asking for. `.subtitle(nil)` is
    /// "turn subtitles off", which is why this is an enum and not two optional
    /// ids.
    ///
    /// Each case carries both the Vivid `trackId` the user tapped and the
    /// server-side identity the deferred replan will actually be resolved from
    /// — the audio selection ordinal (`srcId ?? ffIndex`) and the subtitle
    /// combined index. The interim replan can repackage streams, so an Vivid
    /// id recorded before it can vanish or land on a different stream by drain
    /// time; the server identity is what `resolvedAudioTrackIndexForResume` /
    /// `resolvedProtocolV3SubtitleIndexForResume` send, and it survives that.
    enum QueuedProtocolV3TrackTarget {
        case audio(trackId: Int64, selectionIndex: Int?)
        case subtitle(trackId: Int64?, combinedIndex: Int?)
    }

    /// Server-side ordinal a queued audio pick must resolve back to.
    func queuedTrackTarget(forAudio track: PlayerTrack) -> QueuedProtocolV3TrackTarget {
        .audio(trackId: track.trackId, selectionIndex: audioSelectionIndex(for: track))
    }

    private func serverCombinedSubtitleIndex(for track: PlayerTrack) -> Int? {
        guard let version = currentSelectedVersion else { return nil }
        return ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
            for: track,
            in: version,
            inventory: activePreparedProtocolV3?.plan.subtitle.inventory ?? []
        )
    }

    /// A track change deferred until the in-flight replan settles. Position
    /// is deliberately absent: it is re-read when the queue drains, because
    /// playback keeps moving while the earlier replan completes.
    ///
    /// The target, unlike the position, is *not* re-read. The in-flight replan
    /// publishes its own plan's inventory on the way through, and
    /// `adoptVividInventory` republishes `selectedAudioId`/`selectedSubtitleId`
    /// from the engine as it does — so by drain time the optimistic selection
    /// the user's tap wrote has been overwritten by the interim plan's. A
    /// deferred replan that re-read the selection would therefore ask the
    /// server for the track the user was already on and silently drop the tap.
    struct QueuedProtocolV3TrackChange {
        let classification: String
        let message: String
        let target: QueuedProtocolV3TrackTarget?
    }

    /// Re-publishes a queued track pick just before the deferred replan reads
    /// the selection back, undoing any interim `adoptVividInventory`.
    ///
    /// The recorded Vivid id is tried first; if the interim plan repackaged
    /// the streams and that id is gone, the pick is re-found by the server
    /// identity captured at queue time — the same ordinal the replan would
    /// have sent — so a renumbered stream still restores the user's tap.
    ///
    /// A target that resolves to neither is dropped rather than forced: the
    /// interim plan may not carry that track at all, and a selection pointing
    /// at nothing resolves to no index, which is a worse answer than the one
    /// the engine is actually rendering.
    private func restoreQueuedProtocolV3TrackSelection(
        _ target: QueuedProtocolV3TrackTarget
    ) {
        switch target {
        case .audio(let trackId, let selectionIndex):
            let resolved = audioTracks.first { $0.trackId == trackId }
                ?? selectionIndex.flatMap { wanted in
                    audioTracks.first { audioSelectionIndex(for: $0) == wanted }
                }
            guard let resolved, selectedAudioId != resolved.trackId else { return }
            pendingAudioFfIndex = nil
            selectedAudioId = resolved.trackId
            reapplySystemSubtitlePolicy()
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
        // One classification of the user's target. A track change must have a
        // stable server ordinal before it is queued or issued: falling back to
        // the currently published engine selection would turn an unmappable tap
        // into a successful replan for the track that was already playing.
        //
        // The dimension the user did not touch stays `nil` here and is read
        // back from the player below, after any queued pick is re-published.
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
            // Nil subtitle with a nil track id is explicit Off.
            explicitSubtitleTrackIndex = trackId == nil ? nil : combinedIndex
            targetsSubtitle = true
        case nil:
            explicitAudioTrackIndex = nil
            explicitSubtitleTrackIndex = nil
            targetsSubtitle = false
        }
        if protocolV3ReplanTask != nil {
            if operation == PlaybackProtocolV3.ReplanOperation.seekReanchor {
                // Rapid windowed seeks are latest-wins. Re-issue the newest
                // target after the in-flight route transition settles.
                pendingProtocolV3SeekReanchorPosition = position
                return true
            }
            if requeueWhenBusy {
                // A user track change. The UI already shows the new
                // selection, so dropping the switch here would leave the
                // player permanently disagreeing with itself. Latest-wins,
                // same as a seek: re-issued when the in-flight replan
                // settles, at whatever position playback has reached by then.
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
        // This replan is about to read the current selection back. On the
        // deferred path that selection may have been republished from the
        // interim plan's inventory while the user's pick waited, so reassert
        // the pick first. On the direct path the pick is already published and
        // this is a no-op.
        if let trackTarget {
            restoreQueuedProtocolV3TrackSelection(trackTarget)
        }
        let selectedSubtitleSnapshot = selectedSubtitleId
        // The user-facing selection can be republished from Vivid while the
        // async replan task is waiting to start (inventory/store discovery is
        // still active after a replacement load). A user track change already
        // carries the stable server identity captured at tap time; freeze the
        // request indices here instead of re-reading mutable player state from
        // inside the task.
        let requestedAudioTrackIndex = explicitAudioTrackIndex
            ?? resolvedAudioTrackIndexForResume()
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
        let currentStreamLoadGeneration = streamLoadGeneration
        protocolV3ReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let priorActivePlaybackSessionId = self.activePlaybackSessionId
            let priorVividLoadEpoch = self.activeVividLoadEpoch
            let priorWatchDetail = self.currentWatchDetail
            let priorSelectedVersion = self.currentSelectedVersion
            let priorPreparedProtocolV3 = self.activePreparedProtocolV3
            let priorLastLoadRequest = self.lastLoadRequest
            let priorPendingAudioFfIndex = self.pendingAudioFfIndex
            let priorPendingSubtitleFfIndex = self.pendingSubtitleFfIndex
            let priorPendingSidecarSubtitleTrackId = self.pendingSidecarSubtitleTrackId
            let priorPendingServerRenderedSubtitleTrackId = self.pendingServerRenderedSubtitleTrackId
            let priorDuration = self.duration
            let priorCurrentTime = self.currentTime
            let priorActiveQualityId = self.activeQualityId
            let priorActiveBandwidthCap = self.activeBandwidthCap
            let priorQualityOptions = self.qualityOptions
            let priorResolvedServerUrl = self.resolvedServerUrl
            let priorPrefsForCurrentItem = self.prefsForCurrentItem
            let priorPrefsResolvedForCurrentItem = self.prefsResolvedForCurrentItem
            var uncommittedPrepared: PreparedPlayback?
            var chainedLoadFailureRecovery: (position: Double, classification: String, message: String)?
            defer {
                defer { self.recoverPendingUnexpectedEnd() }
                self.protocolV3ReplanTask = nil
                if completesQualitySwitch { self.isQualitySwitching = false }
                if let recovery = chainedLoadFailureRecovery {
                    self.attemptProtocolV3Replan(
                        position: recovery.position,
                        classification: recovery.classification,
                        message: recovery.message
                    )
                } else if let queuedTrackChange = self.pendingProtocolV3TrackChange {
                    // Drained before the queued seek: this replan will pick
                    // up any still-pending reanchor in its own defer, so both
                    // user intents survive and the seek lands last.
                    self.pendingProtocolV3TrackChange = nil
                    if !self.isDisposed, self.activePreparedProtocolV3 != nil {
                        self.attemptProtocolV3Replan(
                            position: self.currentTime,
                            classification: queuedTrackChange.classification,
                            message: queuedTrackChange.message,
                            requeueWhenBusy: true,
                            trackTarget: queuedTrackChange.target
                        )
                    }
                } else if let queuedTarget = self.pendingProtocolV3SeekReanchorPosition {
                    self.pendingProtocolV3SeekReanchorPosition = nil
                    if !self.isDisposed, self.activePreparedProtocolV3 != nil {
                        self.commitSeek(to: queuedTarget, source: "queuedReanchor")
                    }
                } else if currentStreamLoadGeneration == self.streamLoadGeneration {
                    // Runs only once this task handle is cleared, so a policy
                    // replan it issues is accepted rather than rejected as busy.
                }
            }
            do {
                guard let prepared = try await self.sessionBridge.replanProtocolV3(
                    watchDetail: watchDetail,
                    position: position,
                    classification: classification,
                    message: message,
                    operation: operation,
                    qualityPreference: qualityPreference,
                    audioTrackIndex: requestedAudioTrackIndex,
                    subtitleTrackIndex: requestedSubtitleTrackIndex,
                    outputRouteSnapshot: outputRouteSnapshot
                ) else {
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
                guard !Task.isCancelled,
                      !self.isDisposed,
                      currentStreamLoadGeneration == self.streamLoadGeneration else {
                    throw CancellationError()
                }

                let previousSessionId = self.activePlaybackSessionId
                self.activePlaybackSessionId = prepared.session.sessionId
                self.currentWatchDetail = prepared.watchDetail
                self.currentSelectedVersion = prepared.selectedVersion
                self.activePreparedProtocolV3 = prepared.protocolV3
                self.adoptProtocolV3RenewalIntent(from: prepared)
                switch Self.protocolV3SidecarRestoreIntent(
                    snapshot: selectedSubtitleSnapshot,
                    selectedSubtitleIndex: prepared.protocolV3?.plan.selectedTracks.subtitle?.index,
                    subtitleMode: prepared.protocolV3?.plan.subtitle.mode,
                    isEmbedded: prepared.protocolV3?.plan.subtitle.embedded != nil
                ) {
                case .renderLocally(let trackId):
                    self.pendingSidecarSubtitleTrackId = trackId
                    self.pendingServerRenderedSubtitleTrackId = nil
                case .serverRendered(let trackId):
                    self.pendingSidecarSubtitleTrackId = nil
                    self.pendingServerRenderedSubtitleTrackId = trackId
                case nil:
                    break
                }
                self.duration = prepared.session.durationSeconds ?? prepared.selectedVersion.duration ?? self.duration
                self.currentTime = self.movieTime(for: prepared.session)
                self.activeQualityId = prepared.activeQualityId
                self.activeBandwidthCap = prepared.bandwidthCap
                self.qualityOptions = prepared.nativeQualityOptions ?? ApplePlaybackQuality.playbackOptions(
                    serverQualities: prepared.protocolV3?.plan.availableQualities ?? [],
                    fallbackVersion: prepared.selectedVersion
                )

                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                guard let streamRequest = await self.makeStreamRequest(
                    session: prepared.session,
                    additionalHeaders: prepared.protocolV3?.plan.stream.headers ?? [:],
                    requiresHeaderAuthenticatedMedia: prepared.protocolV3?.serverFeatures.contains(
                        PlaybackProtocolV3.headerAuthenticatedMediaFeature
                    ) == true,
                    allowsAuthorizedMediaOrigins:
                        prepared.protocolV3?.negotiatedAuthorizedMediaOrigins == true,
                    nativeApiMajor: prepared.protocolV3?.plan.nativeApiMajor
                ) else {
                    throw VividLoadSpec.ValidationError.invalidStreamURL(prepared.session.streamUrl)
                }
                try self.requireCurrentStreamLoad(currentStreamLoadGeneration)
                self.resolvedServerUrl = streamRequest.serverUrl
                let shouldPlayWhenReady = self.vividPlaybackController.shouldPlayWhenReady
                try await self.loadVivid(
                    prepared: prepared,
                    streamRequest: streamRequest,
                    expectedStreamLoadGeneration: currentStreamLoadGeneration,
                    shouldPlayWhenReady: shouldPlayWhenReady
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
                // Same rule as the fresh-load arm: an abandoned replan load
                // must not leave the engine reading a retired session. Only
                // once `loadVivid` moved the epoch does the engine hold the
                // candidate source; before that the prior source still plays.
                if currentStreamLoadGeneration == self.streamLoadGeneration,
                   self.activeVividLoadEpoch != priorVividLoadEpoch {
                    _ = self.disposeVividPlayback()
                }
                if let uncommittedPrepared {
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if currentStreamLoadGeneration == self.streamLoadGeneration {
                    self.activePlaybackSessionId = priorActivePlaybackSessionId
                    self.currentWatchDetail = priorWatchDetail
                    self.currentSelectedVersion = priorSelectedVersion
                    self.activePreparedProtocolV3 = priorPreparedProtocolV3
                    self.lastLoadRequest = priorLastLoadRequest
                    self.pendingAudioFfIndex = priorPendingAudioFfIndex
                    self.pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                    self.pendingSidecarSubtitleTrackId = priorPendingSidecarSubtitleTrackId
                    self.pendingServerRenderedSubtitleTrackId = priorPendingServerRenderedSubtitleTrackId
                    self.duration = priorDuration
                    self.currentTime = priorCurrentTime
                    self.activeQualityId = priorActiveQualityId
                    self.activeBandwidthCap = priorActiveBandwidthCap
                    self.qualityOptions = priorQualityOptions
                    self.resolvedServerUrl = priorResolvedServerUrl
                    self.prefsForCurrentItem = priorPrefsForCurrentItem
                    self.prefsResolvedForCurrentItem = priorPrefsResolvedForCurrentItem
                }
                return
            } catch {
                let loadFailure = Self.protocolV3LoadFailureRecovery(error)
                if let uncommittedPrepared {
                    if loadFailure.shouldAdvanceRoute {
                        // Vivid rejected the replacement before it could
                        // commit. Preserve that exact failed plan as the V3
                        // attempt being reported, then advance the bounded
                        // route ladder. No realtime/first-frame/success event
                        // is published.
                        if await self.sessionBridge.promotePendingProtocolV3TransitionForRecovery(
                            uncommittedPrepared
                        ) {
                            chainedLoadFailureRecovery = (
                                position,
                                loadFailure.classification,
                                loadFailure.message
                            )
                            return
                        }
                    }
                    await self.sessionBridge.rollbackPendingProtocolV3Transition(uncommittedPrepared)
                }
                if currentStreamLoadGeneration == self.streamLoadGeneration {
                    self.activePlaybackSessionId = priorActivePlaybackSessionId
                    self.currentWatchDetail = priorWatchDetail
                    self.currentSelectedVersion = priorSelectedVersion
                    self.activePreparedProtocolV3 = priorPreparedProtocolV3
                    self.lastLoadRequest = priorLastLoadRequest
                    self.pendingAudioFfIndex = priorPendingAudioFfIndex
                    self.pendingSubtitleFfIndex = priorPendingSubtitleFfIndex
                    self.pendingSidecarSubtitleTrackId = priorPendingSidecarSubtitleTrackId
                    self.pendingServerRenderedSubtitleTrackId = priorPendingServerRenderedSubtitleTrackId
                    self.duration = priorDuration
                    self.currentTime = priorCurrentTime
                    self.activeQualityId = priorActiveQualityId
                    self.activeBandwidthCap = priorActiveBandwidthCap
                    self.qualityOptions = priorQualityOptions
                    self.resolvedServerUrl = priorResolvedServerUrl
                    self.prefsForCurrentItem = priorPrefsForCurrentItem
                    self.prefsResolvedForCurrentItem = priorPrefsResolvedForCurrentItem
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

    static func protocolV3LoadFailureRecovery(
        _ error: Error
    ) -> (shouldAdvanceRoute: Bool, classification: String, message: String) {
        if let error = error as? ApplePlaybackV3PlanError,
           case .invalidEmbeddedSubtitle = error {
            return (true, "subtitle_embedded_failed", error.localizedDescription)
        }
        if let failure = error as? VividPlaybackController.EmbeddedSubtitleSelectionError {
            return (true, "subtitle_embedded_failed", failure.localizedDescription)
        }
        if let loadFailure = error as? VividPlaybackController.LoadFailure {
            let failure = loadFailure.failure
            // Route-independent failures are not evidence that another
            // decode/remux rung is suitable. All other typed open failures are
            // useful V3 ladder evidence and remain bounded by the bridge's
            // attempt limit.
            return (
                !routeIndependentFailureKinds.contains(failure.kind),
                failure.kind.rawValue,
                failure.message
            )
        }
        let message = error.localizedDescription
        return (true, protocolV3FailureClassification(message), message)
    }
}
