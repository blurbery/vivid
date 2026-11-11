import Foundation
import OSLog

/// Recap, intro and credits markers, and their skips.
///
/// The selected file's own markers are published first. For an episode,
/// TheIntroDB then fills what the file lacks, and IntroDB fills anything
/// still missing. Each lookup is fenced to the playback session, item and
/// file it started for, and none of them ever blocks playback. Automatic
/// skips happen at most once per session, file and marker range: the intro
/// (or recap) after a five-second countdown the viewer can cancel, credits
/// straight away.
extension PlayerViewModel {
    // MARK: - Loading markers

    /// Re-reads markers after the Intro & Credit Skipper setting changes.
    func refreshIntroDBPreference() {
        if let detail = currentWatchDetail {
            loadVividMarkers(for: detail)
        } else {
            applyMarkerRanges(intro: nil, credits: nil)
        }
    }

    func loadVividMarkers(for detail: WatchDetail) {
        introDBLookupTask?.cancel()
        updateIntroDBSegments(nil)
        guard VividSkipSource.isEnabled, offlinePlaybackContext == nil else { return }
        // Only the selected file's markers, never another edition's
        // item-level ones. They stay up if a public lookup fails.
        let fileMarkers = VividIntroDBClient.Segments(
            imdb_id: "", season: detail.seasonNumber ?? 0, episode: detail.episodeNumber ?? 0,
            intro: .init(range: currentSelectedVersion?.intro),
            outro: .init(range: currentSelectedVersion?.credits))
        updateIntroDBSegments(fileMarkers)
        guard detail.type == "episode", let seriesID = detail.seriesId,
              let season = detail.seasonNumber, let episode = detail.episodeNumber else { return }
        let sessionID = activePlaybackSessionId
        let fileID = currentSelectedVersion?.fileId
        introDBLookupTask = Task { @MainActor [weak self] in
            /// Still enabled, and still the session, item and file the
            /// lookup started for.
            @MainActor func isCurrent(_ model: PlayerViewModel) -> Bool {
                guard !Task.isCancelled, VividSkipSource.isEnabled,
                      model.activePlaybackSessionId == sessionID,
                      model.currentWatchDetail?.contentId == detail.contentId,
                      model.currentSelectedVersion?.fileId == fileID else { return false }
                return true
            }
            do {
                // The series' identity, never an episode-level TMDB ID.
                let series = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
                try Task.checkCancellation()
                guard VividSkipSource.isEnabled else { return }
                let imdb = series.imdbId ?? ""
                let identity = VividIntroDBClient.Episode(imdbID: imdb, season: season, episode: episode,
                                                          tmdbID: series.tmdbId.flatMap(Int.init))
                guard identity.theIntroDBIdentifier != nil else { return }
                // TheIntroDB first; its result is published straight away.
                let fetched = try? await VividIntroDBClient.shared.theIntroDBSegments(for: identity)
                let markers = VividIntroDBClient.Segments(
                    imdb_id: imdb, season: season, episode: episode,
                    intro: fileMarkers.intro, outro: fileMarkers.outro, tmdb_id: identity.tmdbID
                ).fillingMissing(from: fetched)
                guard let self, isCurrent(self) else { return }
                self.updateIntroDBSegments(markers)
                // IntroDB only fills what's still missing, so a slow or failed
                // lookup never delays a prompt that's already there.
                guard markers.intro == nil || markers.outro == nil || markers.recap == nil else { return }
                let gaps = try? await VividIntroDBClient.shared.introDBSegments(for: identity)
                guard isCurrent(self),
                      let gaps, gaps.intro != nil || gaps.outro != nil || gaps.recap != nil else { return }
                self.updateIntroDBSegments(markers.fillingMissing(from: gaps))
            } catch {
                // Missing markers or a service outage never block playback.
            }
        }
    }

    /// Publishes a lookup's markers. The raw segments are kept so they can be
    /// resolved again once the engine reports a finite duration, because a
    /// fast or cached lookup can finish before probing does.
    func updateIntroDBSegments(_ segments: VividIntroDBClient.Segments?) {
        loadedIntroDBSegments = segments
        publishMarkerRanges(from: segments)
    }

    /// Resolves the kept segments against a new duration.
    func applyLoadedIntroDBSegments() {
        guard let segments = loadedIntroDBSegments else { return }
        publishMarkerRanges(from: segments)
    }

    private func publishMarkerRanges(from segments: VividIntroDBClient.Segments?) {
        recapRange = segments?.recap?.range(duration: duration)
        applyMarkerRanges(intro: segments?.intro?.range(duration: duration),
                          credits: segments?.outro?.range(duration: duration))
    }

    private func applyMarkerRanges(intro: TimeRange?, credits: TimeRange?) {
        introRange = validTimeRange(intro)
        creditsRange = validTimeRange(credits)
        if let introRange {
            Self.logger.info(
                "[CMP-MARKERS] intro range active start=\(introRange.start, privacy: .public) end=\(introRange.end, privacy: .public)"
            )
        }
        if let creditsRange {
            Self.logger.info(
                "[CMP-MARKERS] credits range active start=\(creditsRange.start, privacy: .public) end=\(creditsRange.end, privacy: .public)"
            )
        }
        autoSkipIntroIfNeeded(at: currentTime)
        autoSkipCreditsIfNeeded(at: currentTime)
    }

    private func validTimeRange(_ range: TimeRange?) -> TimeRange? {
        guard let range,
              range.start.isFinite,
              range.end.isFinite,
              range.start >= 0,
              range.end > range.start else {
            return nil
        }
        return range
    }

    // MARK: - Automatic intro skip

    /// Starts the intro (or recap) countdown on entering its range, and
    /// cancels it on leaving.
    func autoSkipIntroIfNeeded(at time: Double) {
        guard settings.introDBEnabled, settings.autoSkipIntro,
              !isLoading,
              !hasReachedEndOfFile,
              let introRange = activeIntroSkipRange,
              let key = currentIntroSkipKey(for: introRange) else {
            cancelPendingIntroAutoSkip()
            return
        }

        if let pendingAutoSkipIntroKey, pendingAutoSkipIntroKey != key {
            cancelPendingIntroAutoSkip()
        }

        guard time >= introRange.start, time < introRange.end else {
            if pendingAutoSkipIntroKey == key {
                cancelPendingIntroAutoSkip()
            }
            return
        }

        guard autoSkippedIntroKey != key,
              autoSkipIntroCancelledKey != key,
              pendingAutoSkipIntroKey != key else {
            return
        }

        beginIntroAutoSkipCountdown(key: key, range: introRange)
    }

    /// Shows 5, 4, 3, 2, 1 a second apart, then skips if the playhead is
    /// still in the range and nothing cancelled it.
    private func beginIntroAutoSkipCountdown(key: String, range: TimeRange) {
        pendingAutoSkipIntroKey = key
        autoSkipIntroCountdownTask?.cancel()
        introAutoSkipCountdownSeconds = Self.introAutoSkipCountdownDefaultSeconds
        Self.logger.info(
            "[CMP-MARKERS] auto-skip intro countdown started target=\(range.end, privacy: .public)"
        )

        autoSkipIntroCountdownTask = Task { @MainActor [weak self] in
            var remaining = Self.introAutoSkipCountdownDefaultSeconds
            while remaining > 0 {
                guard let self, !Task.isCancelled, self.pendingAutoSkipIntroKey == key else { return }
                self.introAutoSkipCountdownSeconds = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining -= 1
            }

            guard let self,
                  !Task.isCancelled,
                  self.settings.introDBEnabled, self.settings.autoSkipIntro,
                  !self.isLoading,
                  !self.hasReachedEndOfFile,
                  self.pendingAutoSkipIntroKey == key,
                  self.autoSkipIntroCancelledKey != key,
                  self.autoSkippedIntroKey != key,
                  self.currentTime >= range.start,
                  self.currentTime < range.end else {
                self?.cancelPendingIntroAutoSkip()
                return
            }

            self.autoSkippedIntroKey = key
            self.pendingAutoSkipIntroKey = nil
            self.autoSkipIntroCountdownTask = nil
            self.introAutoSkipCountdownSeconds = nil
            Self.logger.info(
                "[CMP-MARKERS] auto-skip intro target=\(range.end, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            self.seekTo(seconds: range.end, revealingControls: false)
        }
    }

    func cancelPendingIntroAutoSkip() {
        autoSkipIntroCountdownTask?.cancel()
        autoSkipIntroCountdownTask = nil
        pendingAutoSkipIntroKey = nil
        introAutoSkipCountdownSeconds = nil
    }

    // MARK: - Automatic credits skip

    func autoSkipCreditsIfNeeded(at time: Double) {
        // Next Up opens over these credits and counts down to the next
        // episode, which is the skip.
        guard creditsNextUpRange == nil else { return }
        let key = creditsRange.flatMap(currentCreditsSkipKey(for:))
        guard let target = CreditsAutoSkipPolicy.target(
            enabled: settings.introDBEnabled && settings.autoSkipCredits,
            playbackEligible: !isLoading && !hasReachedEndOfFile,
            time: time,
            range: creditsRange,
            markerKey: key,
            lastSkippedKey: autoSkippedCreditsKey
        ), let key else {
            return
        }

        // Latch before seeking: a time report the seek causes straight away
        // must see this marker as handled.
        autoSkippedCreditsKey = key
        Self.logger.info(
            "[CMP-MARKERS] auto-skip credits target=\(target, privacy: .public) current=\(time, privacy: .public)"
        )
        performCreditsSkip(to: target)
    }

    /// Skips to the end of the credits. Credits that run to the end of the
    /// file end the item through the normal end and Next Up path, because a
    /// seek to the exact duration would leave the engine paused on the last
    /// frame.
    func performCreditsSkip(to target: Double) {
        if duration.isFinite, duration > 0, target >= duration - 0.5 {
            currentTime = duration
            handleEndOfFile()
            return
        }
        seekTo(seconds: target, revealingControls: false)
    }

    // MARK: - Skip keys

    /// Identifies one intro or recap range in one session and file, so each
    /// is skipped automatically at most once.
    func currentIntroSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = activePlaybackSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):\(range.start):\(range.end)"
    }

    func currentCreditsSkipKey(for range: TimeRange) -> String? {
        guard let sessionId = activePlaybackSessionId,
              let fileId = currentSelectedVersion?.fileId else {
            return nil
        }
        return "\(sessionId):\(fileId):credits:\(range.start):\(range.end)"
    }
}
