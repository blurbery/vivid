import Foundation
import OSLog

/// Play and pause, Retry, and quality: the viewer's choice and the automatic
/// step down when playback keeps stalling.
extension PlayerViewModel {
    // MARK: - Play, pause and retry

    /// Starts the last load again after an error, as a fresh session. That
    /// also copes with a server session that has been cleaned up meanwhile.
    func retry() {
        guard let last = lastLoadRequest else { return }
        Self.logger.info("Retrying playback for contentId=\(last.contentId, privacy: .public)")
        // A load that never opened is repeated as it was. Once the item has
        // played, it resumes where it stopped (a Play from Beginning would
        // ignore `currentTime`) with the audio that was playing, which may be
        // a track switched to since.
        var request = last
        if hasStartedPlayback {
            request = last.resumingInPlace()
            request.preferredAudioTrackIndex = resolvedAudioTrackIndexForResume()
        }
        beginFreshLoad(
            request: request,
            progressPosition: currentTime,
            resumePositionOverride: currentTime,
            allowNearEndResume: true
        )
    }

    func togglePlayPause(revealedBy cause: PlayerControlsCause = .control) {
        // The engine's pause callback is the only writer of `isPlaying`, so
        // the controls can't drift from the real state on an error path.
        if isPlaying {
            vividPlaybackController.pause()
        } else {
            vividPlaybackController.play()
        }
        scheduleHideControls(revealedBy: cause)
    }

    #if os(tvOS)
    /// Select entering the timeline, as in Apple's player: pause at once and
    /// keep the full transport up. When the controls were hidden,
    /// `TVPlayerControls` takes a separate request to focus the scrubber.
    func pauseForTimelineSelection() {
        guard !isLoading, !hasReachedEndOfFile else { return }
        if isPlaying {
            vividPlaybackController.pause()
        }
        pinControlsVisible()
    }
    #endif

    // MARK: - Quality

    func switchQuality(_ qualityId: String) {
        performQualitySwitch(qualityId, isFallback: false)
    }

    /// Steps quality down once playback has stalled for long enough, when the
    /// viewer chose a fallback mode. Fed by every buffering change.
    func updateQualityFallback(buffering: Bool) {
        let eligible = canUseQualityFallback
        playbackFallbackGate.update(buffering: buffering, eligible: eligible,
                                    now: ProcessInfo.processInfo.systemUptime)
        guard buffering, eligible, !playbackFallbackGate.consumed else {
            qualityFallbackTask?.cancel()
            qualityFallbackTask = nil
            return
        }
        guard qualityFallbackTask == nil else { return }
        let epoch = activeVividLoadEpoch
        qualityFallbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(PlaybackFallbackGate.delay)) } catch { return }
            guard let self, !Task.isCancelled, self.activeVividLoadEpoch == epoch else { return }
            self.qualityFallbackTask = nil
            guard let mode = self.playbackFallbackMode,
                  self.playbackFallbackGate.consumeIfReady(
                      now: ProcessInfo.processInfo.systemUptime, eligible: self.canUseQualityFallback
                  ) else { return }
            self.performQualitySwitch(mode.fallbackID, isFallback: true)
        }
    }

    /// A stall counts towards a fallback only during settled streaming
    /// playback with a lower quality to go to and nothing else in flight,
    /// with more than ten seconds of the item and under a second of buffer
    /// left.
    private var canUseQualityFallback: Bool {
        playbackFallbackMode != nil && !isDisposed && isPlaying
            && playbackFallbackMode?.isActive(qualityID: activeQualityId) == true
            && activeVividLoadEpoch != nil && startedVividLoadEpoch == activeVividLoadEpoch
            && !isAudioOnlyVividLoad && lastLoadRequest?.offlineDownloadId == nil
            && qualityOptions.contains(where: { !$0.isAuto && !$0.isOriginal })
            && !isScrubbing && seekTargetTime == nil && !isQualitySwitching
            && protocolV3ReplanTask == nil && error == nil
            && !hasReachedEndOfFile && !showNextUpScreen
            && (duration <= 0 || duration - currentTime > 10)
            && bufferedAheadSeconds < 1
    }

    /// Silo asks the server for a replan at the new quality. Emby, Jellyfin
    /// and direct play reload the same file and tracks at the current
    /// position.
    private func performQualitySwitch(_ qualityId: String, isFallback: Bool) {
        let resolvedQualityId = activePreparedProtocolV3 == nil
            ? ApplePlaybackQuality.normalizeStoredId(qualityId)
            : ApplePlaybackQuality.protocolV3QualityId(qualityId)
        // Picking a different fallback mode counts as a change even when it
        // resolves to the quality already playing.
        let changesFallbackMode = !isFallback && playbackFallbackMode != nil
            && resolvedQualityId != playbackFallbackMode?.rawValue
        guard resolvedQualityId != activeQualityId || qualitySwitchError != nil || changesFallbackMode else { return }

        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        if !isFallback {
            playbackFallbackMode = PlaybackFallbackMode(rawValue: qualityId)
            playbackFallbackGate = PlaybackFallbackGate()
        }

        let target = currentTime.isFinite ? max(0, currentTime) : 0
        isQualitySwitching = true
        qualitySwitchError = nil
        setControlsVisible(true, cause: .qualitySwitch)
        hideControlsTask?.cancel()

        if activePreparedProtocolV3 != nil {
            let replanStarted = attemptProtocolV3Replan(
                position: target,
                classification: "quality_changed",
                message: "User selected playback quality \(resolvedQualityId).",
                operation: PlaybackProtocolV3.ReplanOperation.qualityChange,
                qualityPreference: resolvedQualityId,
                completesQualitySwitch: true
            )
            if !replanStarted {
                // The refusal already cleared `isQualitySwitching`; without a
                // message the menu just snapped back to the old quality.
                isQualitySwitching = false
                qualitySwitchError = String(localized: "Couldn't change quality right now. Try again.")
            }
            return
        }

        guard var request = lastLoadRequest, request.offlineDownloadId == nil else {
            isQualitySwitching = false
            qualitySwitchError = String(localized: "Quality selection is unavailable for offline playback.")
            return
        }
        request = request.copyForRecovery(
            preferredFileId: isFallback ? (currentSelectedVersion?.fileId ?? request.preferredFileId) : request.preferredFileId,
            preferredAudioTrackIndex: resolvedAudioTrackIndexForResume(),
            preferredSubtitleTrackIndex: resolvedSubtitleTrackIndexForResume(),
            preferredSidecarSubtitleTrackId: resolvedSidecarSubtitleTrackIdForResume(),
            offlineDownloadId: nil,
            serverSubtitlesDisabled: hasDisabledServerSubtitlesForResume
        )
        request.preferredQualityOverride = resolvedQualityId
        request.keepsAutomaticSubtitles = !hasExplicitSubtitleChoice
        // A new choice works out its own cap; one carried from earlier
        // playback must not apply to it.
        request.carriedBandwidthCap = nil
        beginFreshLoad(
            request: request,
            progressPosition: target,
            finalizeCurrentSession: true,
            resumePositionOverride: target,
            allowNearEndResume: true
        )
    }
}
