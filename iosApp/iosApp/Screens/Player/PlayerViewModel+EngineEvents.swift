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
    /// Best-effort, non-blocking write of the current resume point, outside
    /// the 10s reporting cadence. Used when the app loses the foreground and
    /// on terminal failure, where the next scheduled tick may never run.
    @MainActor
    func flushPlaybackProgressNow(reason: String) {
        guard !isDisposed else { return }
        if let offline = offlinePlaybackContext {
            recordOfflineProgress(context: offline)
            return
        }
        guard activePlaybackSessionId != nil else { return }
        let position = currentTime
        guard position.isFinite, position >= 0 else { return }
        let isPaused = !isPlaying
        let eligible = progressIsEligible
        let completedContentId = completedPlaybackContentId
        Self.logger.debug("Flushing playback progress (\(reason, privacy: .public))")
        Task { [sessionBridge] in
            _ = await sessionBridge.reportProgress(position: position, isPaused: isPaused, eligible: eligible, completedContentId: completedContentId)
        }
    }

    @MainActor
    func handleVividEvent(_ scopedEvent: VividPlaybackController.ScopedEvent) {
        guard !isDisposed, scopedEvent.epoch == activeVividLoadEpoch else { return }
        switch scopedEvent.event {
        case .state(let state):
            if state != .playing { watchTimeGate.interrupt() }
            switch state {
            case .playing:
                isPlaying = true
                pushNowPlayingSnapshot()
                // An audio-only load has no picture, so Vivid's audio route
                // never latches `hasFirstFrameReadyForDisplay` and the
                // `.firstFrame` milestone below never arrives. The audio route
                // reaching playback is the equivalent milestone; without it
                // these loads would never start progress reporting and would
                // lose their server session mid-listen.
                if isAudioOnlyVividLoad {
                    handleVividStartupMilestone(epoch: scopedEvent.epoch)
                }
            case .paused:
                updateQualityFallback(buffering: false)
                isPlaying = false
                pushNowPlayingSnapshot()
            case .idle, .ended, .error:
                updateQualityFallback(buffering: false)
                isPlaying = false
            case .loading, .seeking:
                break
            }
        case .phase(let phase):
            switch phase {
            case .rebuffering, .stalled:
                updateQualityFallback(buffering: true)
            default:
                updateQualityFallback(buffering: false)
            }
            switch phase {
            case .loading, .rebuffering, .stalled:
                isLoading = true
                watchTimeGate.interrupt()
            case .playing, .paused, .seeking, .ended, .idle, .error:
                isLoading = false
            }
            refreshPlaybackStats(force: true)
        case .playerTime(let playerSeconds):
            guard !hasReachedEndOfFile,
                  playerSeconds.isFinite,
                  let timeline = vividPlaybackController.activeSpec?.timeline else { return }
            let movieTime = timeline.sourcePosition(forPlayerTime: playerSeconds)
            if Self.isUnexpectedBackwardPlaybackTime(
                movieTime,
                currentTime: currentTime,
                explicitSeekInFlight: seekTargetTime != nil
            ) {
                pushNowPlayingIfDue()
                return
            }
            if let origin = seekOriginTime, let target = seekTargetTime {
                if abs(movieTime - origin) < abs(movieTime - target) {
                    pushNowPlayingIfDue()
                    return
                }
                seekOriginTime = nil
                seekTargetTime = nil
                seekFilterTimeoutTask?.cancel()
                seekFilterTimeoutTask = nil
            }
            let isAdvancing = isPlaying && !isLoading && !isBuffering && seekTargetTime == nil
            let uptime = ProcessInfo.processInfo.systemUptime
            watchTimeGate.observe(position: movieTime, uptime: uptime,
                                  playing: isAdvancing, rate: settings.playbackSpeed)
            prematureEndRecoveryGate.observe(position: movieTime, uptime: uptime,
                                             playing: isAdvancing, rate: settings.playbackSpeed)
            currentTime = movieTime
            updatePlaybackCompletion(at: movieTime)
            updateNextUpPresentation(for: movieTime)
            autoSkipIntroIfNeeded(at: movieTime)
            autoSkipCreditsIfNeeded(at: movieTime)
            pushNowPlayingIfDue()
            refreshPlaybackStats()
        case .duration(let reportedDuration):
            // Vivid reports duration on the player/transport axis, while
            // `currentTime` (and every marker, chapter and progress report
            // derived from it) is on the source axis. Adopting the raw value
            // under an HLS reanchor would shorten the scrubber by exactly the
            // timeline offset, so convert before publishing.
            if duration <= 0, reportedDuration.isFinite, reportedDuration > 0 {
                if let timeline = vividPlaybackController.activeSpec?.timeline {
                    duration = timeline.sourcePosition(forPlayerTime: reportedDuration)
                } else {
                    duration = reportedDuration
                }
            }
        case .buffering(let buffering):
            isBuffering = buffering
            if buffering { watchTimeGate.interrupt() }
            refreshPlaybackStats(force: true)
        case .subtitleLoading(let loading):
            isLoadingSubtitles = loading
        case .firstFrame:
            handleVividStartupMilestone(epoch: scopedEvent.epoch)
        case .inventoryChanged:
            adoptVividInventory()
            refreshPlaybackStats(force: true)
        case .telemetryChanged(let telemetry):
            refreshPlaybackStats(force: telemetry == nil, telemetry: telemetry)
        case .ended:
            handleEndOfFile()
            refreshPlaybackStats(force: true)
        case .failure(let failure):
            handleVividFailure(failure)
        case .transportRestoreFailed(let message):
            // The engine tore its media session down in the background and the
            // rebuild for this Play failed. That is a source failure like any
            // other post-load one — the committed plan may simply have expired
            // while suspended — so it goes through the same recovery boundary
            // (replan / stale-session renewal) instead of straight to the
            // terminal wall. `handlePlaybackError` still finalizes the cases
            // that genuinely have nowhere left to go.
            // A refused audio session was already published as a typed
            // failure and stopped at Retry; replanning here would step down.
            if vividPlaybackController.engine.errorInfo?.kind == .audioSessionUnavailable { return }
            handlePlaybackError(message)
        }
    }

    @MainActor
    func handleVividControllerEvent(_ event: VividPlaybackController.ControllerEvent) {
        guard !isDisposed else { return }
        switch event {
        case .systemMediaChanged:
            syncNowPlayingDestination()
            refreshPlaybackStats(force: true)
        case .externalPlaybackChanged(let supported, let active):
            supportsExternalPlayback = supported
            isExternalPlaybackActive = active
            refreshPlaybackStats(force: true)
        }
    }

    #if DEBUG
    /// Tests establish a generation without opening media or a server session.
    func debugPreparePlaybackStatsLoad(_ spec: VividLoadSpec) {
        activeVividLoadEpoch = vividPlaybackController.beginLoad(spec, shouldPlayWhenReady: false)
    }
    #endif

    private func refreshPlaybackStats(force: Bool = false) {
        refreshPlaybackStats(force: force, telemetry: vividPlaybackController.engine.liveTelemetry)
    }

    func cancelPlaybackStatsRefresh() {
        playbackStatsRefreshTask?.cancel()
        playbackStatsRefreshTask = nil
        pendingPlaybackStatsTelemetry = nil
    }

    private var playbackStatsUptime: TimeInterval {
        #if DEBUG
        if let debugPlaybackStatsUptime { return debugPlaybackStatsUptime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func refreshPlaybackStats(force: Bool = false, telemetry: LiveTelemetry?) {
        guard let spec = vividPlaybackController.activeSpec else {
            cancelPlaybackStatsRefresh()
            playbackStats = .empty
            bufferedAheadSeconds = 0
            playbackReadAheadSeconds = nil
            playbackStatsCadence.reset()
            playbackStatsEpoch = nil
            return
        }

        // The quality fallback and TV timeline must see every buffer sample,
        // including an unavailable measurement. Only formatting is rate-limited.
        // Unchanged samples are not rewritten, so the buffer bar only
        // re-renders when the buffer actually moves.
        let buffered = max(0, telemetry?.forwardBufferSeconds ?? 0)
        if bufferedAheadSeconds != buffered { bufferedAheadSeconds = buffered }
        if playbackReadAheadSeconds != telemetry?.forwardBufferSeconds {
            playbackReadAheadSeconds = telemetry?.forwardBufferSeconds
        }
        if playbackStatsEpoch != activeVividLoadEpoch {
            cancelPlaybackStatsRefresh()
            playbackStatsCadence.reset()
            playbackStatsEpoch = activeVividLoadEpoch
        }
        let uptime = playbackStatsUptime
        guard playbackStatsCadence.shouldRefresh(at: uptime, force: force) else {
            pendingPlaybackStatsTelemetry = telemetry
            if playbackStatsRefreshTask == nil {
                let epoch = activeVividLoadEpoch
                let delay = playbackStatsCadence.remainingDelay(at: uptime)
                playbackStatsRefreshTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard !Task.isCancelled, let self, !isDisposed,
                          activeVividLoadEpoch == epoch else { return }
                    let latestTelemetry = pendingPlaybackStatsTelemetry
                    playbackStatsRefreshTask = nil
                    refreshPlaybackStats(force: true, telemetry: latestTelemetry)
                }
            }
            return
        }
        cancelPlaybackStatsRefresh()
        let sampledAt = Date()

        let secondaryLabel = selectedSecondarySubtitleId.flatMap { selectedID in
            subtitleTracks.first { $0.trackId == selectedID }?.primaryLabel
        }
        let source = VividPlaybackStatsSourceMetadata(
            sourceURL: spec.sourceURL,
            delivery: spec.delivery,
            container: currentSelectedVersion?.container,
            playbackRate: isHoldFastForwarding ? 2 : settings.playbackSpeed,
            secondarySubtitleLabel: secondaryLabel
        )
        let snapshot = VividPlaybackStatsSnapshot(
            engine: vividPlaybackController.engine,
            telemetry: telemetry
        )
        let projected = VividPlaybackStatsProjection.make(
            snapshot: snapshot,
            source: source,
            sampledAt: sampledAt
        )
        playbackStats = projected
    }

    @MainActor
    func handleVividFailure(_ failure: PlaybackErrorInfo) {
        guard !hasReachedEndOfFile else { return }
        suppressNextUpForPlaybackFailure()
        if failure.kind == .audioTrackSwitchFailed {
            // The engine tore its pipeline down for the switch and the rebuild
            // failed, so there is nothing left playing whatever the phase. It
            // also restored `activeAudioTrackIndex`, so republish the engine's
            // truth before any recovery re-reads the selection.
            lastVividAudioTrackSwitchFailure = failure
            selectedAudioId = vividPlaybackController.engine.activeAudioTrackIndex
                .map(Int64.init)
            isBuffering = false
            isLoadingSubtitles = false
            bufferingProgress = nil
            isQualitySwitching = false
            if freshLoadOwnsFailureHandling || !isVividLoadEstablished {
                // The load this switch killed is unwinding right now;
                // `resolveAbandonedVividLoad` turns its cancellation into this
                // failure so exactly one handler recovers it.
                return
            }
            // Mid-playback, after the load was established: the switch was an
            // explicit pick, so recover the session the same way any other
            // post-load engine failure is recovered rather than stranding the
            // user on a spinner.
            showNotice(
                title: "Couldn't change audio",
                message: "The audio track couldn't be switched. The previous track was kept.",
                tone: .warning,
                duration: 5
            )
            handlePlaybackError(failure.message, failure: failure)
            return
        }
        // Vivid deliberately publishes its typed failure *before* the load
        // throws, so every in-flight load would otherwise be handled twice:
        // once here and once in the load's own catch. The owning load task is
        // the single handler on every path — V3, direct play and offline
        // alike — because only it knows the load's origin, and therefore
        // whether the failure gets the full-screen wall or the recoverable
        // Next Up surface.
        if freshLoadOwnsFailureHandling {
            return
        }
        if activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch == nil {
            // Same rule for a replan's load: it owns provisional-route
            // recovery, and reacting here too would start two competing
            // replans.
            return
        }
        if authenticationReloadGeneration == streamLoadGeneration,
           protocolV3ReplanTask != nil {
            return
        }
        if attemptProtocolV3AuthenticationReload(after: failure) {
            return
        }
        if let code = failure.transientSourceCode,
           vividPlaybackController.activeSpec?.options.nativeRemoteHLS == false,
           beginProtocolV3SameRouteReload(
               fallbackClassification: failure.kind.rawValue,
               fallbackMessage: failure.message,
               transientFailureCode: code
           ) {
            return
        }
        if failure.kind == .audioSessionUnavailable {
            // Activation was still refused after the engine's brief retries.
            // Every route needs the same audio session, so asking the server
            // for a lower rung would only transcode for nothing; stop at Retry.
            guard !hasReachedEndOfFile else { return }
            finalizeTerminalPlaybackError(failure.message)
            return
        }
        let serverCanAdapt: Set<PlaybackErrorKind> = [
            .sourceRefused,
            .vodSourceFailed,
            .nativeItemFailed,
            .noPlayableTrackWithinBudget,
            .masterPlaylistRejected,
            .softwarePipelineFailed,
            .audioBridgeProducedNoOutput,
            .dolbyVisionRequiresHardware,
            .demuxedAudioLiveUnsupported,
        ]
        // Vivid publishes errorInfo before a throwing load returns. Only the
        // owning load task may recover a provisional plan; starting a second
        // replan here would race its rollback/route-ladder handling.
        if serverCanAdapt.contains(failure.kind),
           activePreparedProtocolV3 != nil,
           committedProtocolV3LoadEpoch != nil {
            guard protocolV3ReplanTask == nil else { return }
            if !attemptProtocolV3Replan(
                position: currentTime,
                classification: failure.kind.rawValue,
                message: failure.message
            ) {
                finalizeTerminalPlaybackError(failure.message)
            }
            return
        }
        if failure.kind == .sourceRateLimited {
            showNotice(
                title: "Playback delayed",
                message: "The media source is rate limiting requests. Try again in a moment.",
                tone: .info,
                duration: 5
            )
            return
        }
        handlePlaybackError(failure.message, failure: failure)
    }

    /// Whether the active load asked Vivid for its audio-only route, which
    /// publishes no video-display signal at all.
    var isAudioOnlyVividLoad: Bool {
        vividPlaybackController.activeSpec?.options.audioOnly == true
    }

    /// The single place a load's startup milestone is taken.
    ///
    /// Latched per epoch, because the milestone has two sources that must
    /// never both count: Vivid's first frame for anything with a picture, and
    /// the audio route starting for an audio-only load. Everything a started
    /// load owes the server — progress reporting, keepalives, the Playback V3
    /// first-frame report — hangs off this one call.
    private func handleVividStartupMilestone(epoch: VividPlaybackController.LoadEpoch) {
        guard startedVividLoadEpoch != epoch else { return }
        startedVividLoadEpoch = epoch
        handleFileLoaded()
        if isNextUpTransitioning {
            isNextUpTransitioning = false
            showNextUpScreen = false
            nextUpEpisode = nil
            nextUpOnDeckItems = []
            if let detail = currentWatchDetail {
                loadNextUpCandidate(for: detail)
                loadNextUpOnDeckItems(for: detail)
            }
        } else if nextUpPrefetchPending, let detail = currentWatchDetail {
            nextUpPrefetchPending = false
            loadNextUpCandidate(for: detail)
            loadNextUpOnDeckItems(for: detail)
        }
        if activePreparedProtocolV3 != nil {
            pendingProtocolV3FirstFrameEpoch = epoch
            completeProtocolV3FirstFrameIfCommitted(epoch)
        } else {
            startProgressReporting()
        }
        refreshPlaybackStats(force: true)
    }

    func handleFileLoaded() {
        hasReachedEndOfFile = false
        error = nil
        isLoading = false
        isPlaying = true
        applySettingsToPlayer()
        Self.logger.info(
            "[CMP-SUB] file loaded engine=VividEngine route=\(self.activeRouteLabel, privacy: .public) tracks=\(self.subtitleTracks.count, privacy: .public)"
        )
        hideControlsTask?.cancel()
        showControls = false
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: true,
            playbackRate: settings.playbackSpeed
        )
    }

    /// Vivid may publish its first-frame flag synchronously while the server
    /// plan is still provisional. Hold that observation until the owning load
    /// and bridge transition both commit so a failed/cancelled candidate never
    /// appears as successfully presented in Playback V3 telemetry.
    func markProtocolV3VividLoadCommitted() {
        guard activePreparedProtocolV3 != nil,
              let epoch = activeVividLoadEpoch else { return }
        committedProtocolV3LoadEpoch = epoch
        completeProtocolV3FirstFrameIfCommitted(epoch)
    }

    private func completeProtocolV3FirstFrameIfCommitted(
        _ epoch: VividPlaybackController.LoadEpoch
    ) {
        guard committedProtocolV3LoadEpoch == epoch,
              pendingProtocolV3FirstFrameEpoch == epoch,
              let planId = activePreparedProtocolV3?.plan.planId,
              let sessionId = activePlaybackSessionId else { return }
        pendingProtocolV3FirstFrameEpoch = nil
        startProgressReporting()
        Task { [sessionBridge] in
            await sessionBridge.reportProtocolV3FirstFrame(
                planId: planId,
                sessionId: sessionId,
                milliseconds: nil
            )
        }
    }
}
