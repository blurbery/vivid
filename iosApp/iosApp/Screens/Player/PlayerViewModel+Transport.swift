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
    /// Re-run the last `loadAndPlay` from scratch after an error. Currently a
    /// fresh session — simpler than retrying just the stream load, and
    /// tolerates stale server-side sessions that may have been reaped.
    func retry() {
        guard let last = lastLoadRequest else { return }
        Self.logger.info("Retrying playback for contentId=\(last.contentId, privacy: .public)")
        beginFreshLoad(
            request: last,
            progressPosition: currentTime,
            resumePositionOverride: currentTime,
            allowNearEndResume: true
        )
    }

    func togglePlayPause() {
        // `isPlaying` is driven by the backend's `onPauseChange` callback;
        // let that be the single writer so the UI can't drift out of sync
        // with the actual pipeline state on error paths.
        if isPlaying {
            vividPlaybackController.pause()
        } else {
            vividPlaybackController.play()
        }
        scheduleHideControls()
    }

    #if os(tvOS)
    /// Native-player Select behavior for timeline entry: pause immediately
    /// and keep the full transport mounted. When controls were hidden,
    /// `TVPlayerControls` consumes a separate request token to focus and
    /// activate its timeline scrubber.
    func pauseForTimelineSelection() {
        guard !isLoading, !hasReachedEndOfFile else { return }
        if isPlaying {
            vividPlaybackController.pause()
        }
        pinControlsVisible()
    }
    #endif

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
            do { try await Task.sleep(for: .seconds(PlaybackFallbackGate.delay)) }
            catch { return }
            guard let self, !Task.isCancelled, self.activeVividLoadEpoch == epoch else { return }
            self.qualityFallbackTask = nil
            guard let mode = self.playbackFallbackMode,
                  self.playbackFallbackGate.consumeIfReady(
                    now: ProcessInfo.processInfo.systemUptime, eligible: self.canUseQualityFallback
                  ) else { return }
            self.performQualitySwitch(mode.fallbackID, isFallback: true)
        }
    }

    func switchQuality(_ qualityId: String) {
        performQualitySwitch(qualityId, isFallback: false)
    }

    private func performQualitySwitch(_ qualityId: String, isFallback: Bool) {
        let resolvedQualityId = activePreparedProtocolV3 == nil
            ? ApplePlaybackQuality.normalizeStoredId(qualityId)
            : ApplePlaybackQuality.protocolV3QualityId(qualityId)
        guard resolvedQualityId != activeQualityId || qualitySwitchError != nil
                || (!isFallback && playbackFallbackMode != nil
                    && resolvedQualityId != playbackFallbackMode?.rawValue) else { return }

        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        if !isFallback {
            playbackFallbackMode = PlaybackFallbackMode(rawValue: qualityId)
            playbackFallbackGate = PlaybackFallbackGate()
        }

        let target = currentTime.isFinite ? max(0, currentTime) : 0
        isQualitySwitching = true
        qualitySwitchError = nil
        showControls = true
        hideControlsTask?.cancel()

        if activePreparedProtocolV3 != nil {
            // A rejected replan already cleared `isQualitySwitching`, but
            // without a message the sheet just silently snapped back to the
            // old quality with no explanation.
            if !attemptProtocolV3Replan(
                position: target,
                classification: "quality_changed",
                message: "User selected playback quality \(resolvedQualityId).",
                operation: PlaybackProtocolV3.ReplanOperation.qualityChange,
                qualityPreference: resolvedQualityId,
                completesQualitySwitch: true
            ) {
                isQualitySwitching = false
                qualitySwitchError = "Couldn't change quality right now. Try again."
            }
            return
        }

        guard var request = lastLoadRequest,
              request.offlineDownloadId == nil else {
            isQualitySwitching = false
            qualitySwitchError = "Quality selection is unavailable for offline playback."
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
        // A new choice derives its own cap; a cap carried from earlier
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
