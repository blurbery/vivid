import Foundation
import OSLog

/// Watch progress: the ten-second report while playing, the immediate flush
/// when the app leaves the foreground or playback fails, and a download's
/// offline queue.
extension PlayerViewModel {
    /// Reports the position every ten seconds until cancelled. Started at the
    /// load's startup milestone (and, for Silo, once its plan has committed).
    /// A download records into its offline queue instead. A lost session is
    /// renewed; a successful report gives a changed bearer to the engine.
    func startProgressReporting() {
        progressTask?.cancel()
        progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if let offline = self.offlinePlaybackContext {
                    self.recordOfflineProgress(context: offline)
                    continue
                }
                let result = await self.sessionBridge.reportProgress(
                    position: self.currentTime,
                    isPaused: !self.isPlaying,
                    eligible: self.progressIsEligible,
                    completedContentId: self.completedPlaybackContentId
                )
                if result == .missingSession {
                    _ = self.attemptStaleSessionRenewal(reason: "progress", observedPosition: self.currentTime)
                } else {
                    await self.updateProtocolV3AuthenticationAfterProgress(result)
                }
            }
        }
    }

    /// Best-effort write of the current resume point outside the ten-second
    /// cadence, for when the app leaves the foreground or playback fails and
    /// the next tick may never run. Doesn't stop the session: Picture in
    /// Picture and background audio carry on.
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
            _ = await sessionBridge.reportProgress(
                position: position, isPaused: isPaused, eligible: eligible, completedContentId: completedContentId
            )
        }
    }

    /// Queues one progress sample for a download's next sync. `position`
    /// lets the final writes (natural end, closing the player) save the end
    /// state rather than the last tick, and `markCompleted` marks it watched
    /// on a natural end even when the file's duration never resolved.
    /// Nothing is saved before the item's first picture unless it's watched.
    func recordOfflineProgress(
        context: OfflinePlaybackContext,
        position: Double? = nil,
        markCompleted: Bool = false
    ) {
        let watched = markCompleted || completedPlaybackContentId != nil
        guard hasStartedPlayback || watched else { return }
        let position = position ?? currentTime
        guard position.isFinite, position >= 0 else { return }
        let duration = duration.isFinite && duration > 0 ? duration : 0
        #if DEBUG
        if let testRecorder {
            testRecorder.record(.offlineProgress(position: position, completed: watched))
            return
        }
        #endif
        DownloadManager.shared.recordOfflineProgress(
            mediaItemId: context.mediaItemId,
            position: position,
            duration: duration,
            completed: watched
        )
    }
}
