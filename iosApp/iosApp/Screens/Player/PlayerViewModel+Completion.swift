import Foundation

/// Watched completion for the current movie or episode.
///
/// Reaching 90% of the duration, a valid credits marker or a confirmed
/// natural end latches the item as watched, once, without stopping playback.
/// The server (or, offline, the download store) gets the real position
/// straight away; the watched write itself follows progress and Stop.
extension PlayerViewModel {
    func completionProgressPositionForCurrentItem() -> Double {
        currentTime.isFinite ? max(0, currentTime) : 0
    }

    func updatePlaybackCompletion(at position: Double, endedNaturally: Bool = false) {
        let newlyCompleted = latchPlaybackCompletionIfReached(at: position, endedNaturally: endedNaturally)
        // An item marked watched earlier still needs its final end position.
        guard newlyCompleted || endedNaturally, position.isFinite, position >= 0 else { return }
        if let offline = offlinePlaybackContext {
            recordOfflineProgress(context: offline, position: position,
                                  markCompleted: completedPlaybackContentId != nil)
            return
        }
        let contentId = completedPlaybackContentId
        let prior = naturalEndProgressTask
        let paused = !isPlaying
        let eligible = newlyCompleted || progressIsEligible
        let refreshHome = refreshHomeAfterPlaybackWrite
        #if DEBUG
        testRecorder?.record(.progressReport(position: position, completedContentId: contentId))
        #endif
        // Chained so the writes reach the server in order, and so teardown and
        // autoplay can await the last one before stopping the session.
        naturalEndProgressTask = Task { [sessionBridge] in
            await prior?.value
            let result = await sessionBridge.reportProgress(
                position: position, isPaused: paused, eligible: eligible,
                completedContentId: contentId)
            if result == .success { refreshHome?() }
        }
    }

    /// Latches completion for the current item the first time it qualifies.
    /// Returns true only on that first time.
    private func latchPlaybackCompletionIfReached(at position: Double, endedNaturally: Bool) -> Bool {
        guard completedPlaybackContentId == nil,
              let detail = currentWatchDetail,
              ["movie", "episode"].contains(detail.type),
              PlaybackCompletionPolicy.isComplete(
                  position: position, duration: duration,
                  credits: currentSelectedVersion?.credits ?? creditsRange,
                  endedNaturally: endedNaturally) else {
            return false
        }
        completedPlaybackContentId = detail.contentId
        recordCurrentPlaybackMutation(markedCompleted: true)
        #if DEBUG
        testRecorder?.record(.watchedMutation(contentId: detail.contentId))
        #endif
        return true
    }

    /// Notes every detail page the current item's playback changes, before a
    /// replacement load or teardown clears `currentWatchDetail`. The series
    /// and its season page are included because Apple TV keeps the combined
    /// series page loaded while its episode plays.
    func recordCurrentPlaybackMutation(markedCompleted: Bool) {
        guard progressIsEligible else { return }
        let currentContentId = currentWatchDetail?.contentId ?? lastLoadRequest?.contentId
        if let currentContentId, !currentContentId.isEmpty {
            contentIdsNeedingDetailRefresh.insert(currentContentId)
            if markedCompleted || completedPlaybackContentId != nil {
                completedContentIdsNeedingDetailAdvance.insert(currentContentId)
            }
        }

        guard let detail = currentWatchDetail,
              let seriesId = detail.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seriesId.isEmpty else { return }
        contentIdsNeedingDetailRefresh.insert(seriesId)
        if let seasonNumber = detail.seasonNumber {
            contentIdsNeedingDetailRefresh.insert("\(seriesId)-S\(seasonNumber)")
        }
    }
}
