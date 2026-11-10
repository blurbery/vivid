import Foundation
import OSLog

/// What the engine reports back: state, time, inventory, statistics, the
/// startup milestone and failures, each routed to the player's own state or
/// its recovery.
extension PlayerViewModel {
    // MARK: Engine events

    /// Handles an event from the controller. Events from any load other than
    /// the active one are dropped.
    func handleVividEvent(_ scopedEvent: VividPlaybackController.ScopedEvent) {
        guard !isDisposed, scopedEvent.epoch == activeVividLoadEpoch else { return }
        switch scopedEvent.event {
        case .state(let state):
            switch state {
            case .playing:
                isPlaying = true
                restoreNowPlayingAfterEndIfNeeded()
                pushNowPlayingSnapshot()
                // An audio-only load has no picture, so the `.firstFrame`
                // milestone never comes. Its audio route starting is the same
                // milestone; without it the load would never report progress
                // and would lose its server session mid-listen.
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
            case .playing, .paused, .seeking, .ended, .idle, .error:
                isLoading = false
            }
            refreshPlaybackStats(force: true)
        case .playerTime(let playerSeconds):
            handlePlayerTime(playerSeconds)
        case .duration(let reportedDuration):
            // The engine reports duration on the player axis, but
            // `currentTime` (and every marker, chapter and progress report
            // made from it) is on the source axis. Taking the raw value under
            // an HLS reanchor would shorten the scrubber by the timeline
            // offset, so it's converted first. Only the first finite duration
            // is taken.
            if duration <= 0, reportedDuration.isFinite, reportedDuration > 0 {
                if let timeline = vividPlaybackController.activeSpec?.timeline {
                    duration = timeline.sourcePosition(forPlayerTime: reportedDuration)
                } else {
                    duration = reportedDuration
                }
            }
        case .buffering(let buffering):
            isBuffering = buffering
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
            // The engine tore its media session down in the background and
            // rebuilding it for this Play failed. That's a source failure like
            // any other after the load (the plan may simply have expired while
            // suspended), so it takes the same recovery. A refused audio
            // session was already published as a typed failure and stopped at
            // Retry; recovering here would step the route down.
            if vividPlaybackController.engine.errorInfo?.kind == .audioSessionUnavailable { return }
            handlePlaybackError(message)
        }
    }

    /// A new playhead from the engine, on the player axis. Dropped after the
    /// end, when it jumps backwards with no seek asked for, or while it's
    /// still nearer a seek's origin than its target.
    private func handlePlayerTime(_ playerSeconds: Double) {
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
        prematureEndRecoveryGate.observe(
            position: movieTime,
            uptime: ProcessInfo.processInfo.systemUptime,
            playing: isAdvancing,
            rate: settings.playbackSpeed
        )
        currentTime = movieTime
        updatePlaybackCompletion(at: movieTime)
        updateNextUpPresentation(for: movieTime)
        autoSkipIntroIfNeeded(at: movieTime)
        autoSkipCreditsIfNeeded(at: movieTime)
        pushNowPlayingIfDue()
        refreshPlaybackStats()
    }

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

    // MARK: Failures

    /// Engine failures the server can answer with another route.
    private static let serverAdaptableFailureKinds: Set<PlaybackErrorKind> = [
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

    /// Routes a typed engine failure to exactly one handler.
    ///
    /// The engine publishes its failure before a throwing load returns, so a
    /// load or replan that's still settling handles it itself; reacting here
    /// too would recover the same failure twice. Otherwise, in order: an
    /// expired bearer reloads the same route, a recognised connection error
    /// reopens it, a refused audio session stops at Retry, a failure the
    /// server can adapt to asks Silo for another route, rate limiting shows a
    /// notice, and anything else takes `handlePlaybackError`.
    func handleVividFailure(_ failure: PlaybackErrorInfo) {
        guard !hasReachedEndOfFile else { return }
        suppressNextUpForPlaybackFailure()
        if failure.kind == .audioTrackSwitchFailed {
            // The engine tore its pipeline down for the switch and the rebuild
            // failed, so nothing is playing whatever the phase. It also put
            // `activeAudioTrackIndex` back, so publish that before any
            // recovery reads the selection.
            lastVividAudioTrackSwitchFailure = failure
            selectedAudioId = vividPlaybackController.engine.activeAudioTrackIndex.map(Int64.init)
            isBuffering = false
            isLoadingSubtitles = false
            bufferingProgress = nil
            isQualitySwitching = false
            if freshLoadOwnsFailureHandling || !isVividLoadEstablished {
                // The load this switch killed is unwinding now, and
                // `resolveAbandonedVividLoad` turns its cancellation into this
                // failure, so exactly one handler recovers it.
                return
            }
            // Mid-playback the switch was the viewer's pick, so recover the
            // session like any other failure after the load rather than
            // leaving a spinner.
            showNotice(
                title: String(localized: "Couldn't change audio"),
                message: String(localized: "The audio track couldn't be switched. The previous track was kept."),
                tone: .warning,
                duration: 5
            )
            handlePlaybackError(failure.message, failure: failure)
            return
        }
        // The load task is the only handler while it runs, on every path
        // (Silo, direct play and offline), because only it knows the load's
        // origin and so whether the failure gets Retry or the Next Up surface.
        if freshLoadOwnsFailureHandling {
            return
        }
        // Likewise a replan's load owns recovery of its provisional route;
        // reacting here too would start two competing replans.
        if activePreparedProtocolV3 != nil, committedProtocolV3LoadEpoch == nil {
            return
        }
        if authenticationReloadGeneration == streamLoadGeneration, protocolV3ReplanTask != nil {
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
            // Still refused after the engine's brief retries. Every route
            // needs the same audio session, so a lower rung would only
            // transcode for nothing.
            finalizeTerminalPlaybackError(failure.message)
            return
        }
        if Self.serverAdaptableFailureKinds.contains(failure.kind),
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
                title: String(localized: "Playback delayed"),
                message: String(localized: "The media source is rate limiting requests. Try again in a moment."),
                tone: .info,
                duration: 5
            )
            return
        }
        handlePlaybackError(failure.message, failure: failure)
    }

    // MARK: Startup milestone

    /// Whether the active load asked the engine for its audio-only route,
    /// which publishes no video signal at all.
    var isAudioOnlyVividLoad: Bool {
        vividPlaybackController.activeSpec?.options.audioOnly == true
    }

    /// The one place a load's startup milestone is taken.
    ///
    /// Latched per epoch, because it has two sources that must never both
    /// count: the first frame for anything with a picture, and the audio
    /// route starting for an audio-only load. Everything a started load owes
    /// the server hangs off this call: progress reporting and Silo's
    /// first-frame report. It also ends a Next Up hand-off and starts
    /// the Next Up and On Deck fetches held for it.
    private func handleVividStartupMilestone(epoch: VividPlaybackController.LoadEpoch) {
        guard startedVividLoadEpoch != epoch else { return }
        startedVividLoadEpoch = epoch
        hasStartedPlayback = true
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
        setControlsVisible(false, cause: .fileLoaded)
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: true,
            playbackRate: settings.playbackSpeed
        )
    }

    /// The engine can show its first frame while a Silo plan is still
    /// provisional. That's held until the load and the bridge's transition
    /// have both committed, so a failed or cancelled candidate never shows as
    /// presented in Playback V3 telemetry.
    func markProtocolV3VividLoadCommitted() {
        guard activePreparedProtocolV3 != nil, let epoch = activeVividLoadEpoch else { return }
        committedProtocolV3LoadEpoch = epoch
        completeProtocolV3FirstFrameIfCommitted(epoch)
    }

    private func completeProtocolV3FirstFrameIfCommitted(_ epoch: VividPlaybackController.LoadEpoch) {
        guard committedProtocolV3LoadEpoch == epoch,
              pendingProtocolV3FirstFrameEpoch == epoch,
              let planId = activePreparedProtocolV3?.plan.planId,
              let sessionId = activePlaybackSessionId else { return }
        pendingProtocolV3FirstFrameEpoch = nil
        startProgressReporting()
        Task { [sessionBridge] in
            await sessionBridge.reportProtocolV3FirstFrame(planId: planId, sessionId: sessionId, milliseconds: nil)
        }
    }

    // MARK: Playback statistics

    #if DEBUG
    /// Tests start a load epoch without opening media or a server session.
    func debugPreparePlaybackStatsLoad(_ spec: VividLoadSpec) {
        activeVividLoadEpoch = vividPlaybackController.beginLoad(spec, shouldPlayWhenReady: false)
    }
    #endif

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

    private func refreshPlaybackStats(force: Bool = false) {
        refreshPlaybackStats(force: force, telemetry: vividPlaybackController.engine.liveTelemetry)
    }

    /// Publishes the buffer readings at once and the statistics panel at most
    /// once per cadence interval. A sample that arrives inside the interval
    /// is kept, and one pending refresh publishes the latest when it ends.
    /// `force` publishes now and drops the pending one.
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

        // The quality fallback and the Apple TV timeline see every buffer
        // sample, an unavailable one included. Unchanged values aren't
        // written again, so the buffer bar redraws only when it moves.
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
                    guard !Task.isCancelled, let self, !isDisposed, activeVividLoadEpoch == epoch else { return }
                    let latestTelemetry = pendingPlaybackStatsTelemetry
                    playbackStatsRefreshTask = nil
                    refreshPlaybackStats(force: true, telemetry: latestTelemetry)
                }
            }
            return
        }
        cancelPlaybackStatsRefresh()

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
        playbackStats = VividPlaybackStatsProjection.make(
            snapshot: VividPlaybackStatsSnapshot(engine: vividPlaybackController.engine, telemetry: telemetry),
            source: source,
            sampledAt: Date()
        )
    }
}
