import Foundation
import OSLog

/// Recap, intro and credits markers, and their skips.
///
/// The selected file's own markers from the server are published first, so a
/// prompt is there straight away. While the Intro & Credit Skipper is on, an
/// episode's TheIntroDB markers then take priority, IntroDB fills any kind
/// TheIntroDB lacks, and the server's markers only fill what neither has.
/// With it off, only the server's markers are used. Each lookup is fenced to
/// the playback session, item and file it started for, and none of them ever
/// blocks playback. Automatic skips happen at most once per session, file and
/// marker range: the intro (or recap) after a five-second countdown the viewer
/// can cancel, credits straight away.
extension PlayerViewModel {
    // MARK: - Loading markers

    /// Re-reads markers after the Intro & Credit Skipper setting changes.
    func refreshIntroDBPreference() {
        if let detail = currentWatchDetail {
            loadVividMarkers(for: detail)
        } else {
            updateIntroDBSegments(nil)
        }
    }

    func loadVividMarkers(for detail: WatchDetail) {
        introDBLookupTask?.cancel()
        updateIntroDBSegments(nil)
        guard offlinePlaybackContext == nil else { return }
        // Only the selected file's markers, never another edition's
        // item-level ones. They stay up if a public lookup fails.
        let serverMarkers = VividIntroDBClient.Segments(
            imdb_id: "", season: detail.seasonNumber ?? 0, episode: detail.episodeNumber ?? 0,
            intro: .init(range: currentSelectedVersion?.intro),
            outro: .init(range: currentSelectedVersion?.credits),
            recap: .init(range: currentSelectedVersion?.recap))
        updateIntroDBSegments(serverMarkers)
        guard VividSkipSource.isEnabled, detail.type == "episode" else { return }
        guard let seriesID = detail.seriesId,
              let season = detail.seasonNumber, let episode = detail.episodeNumber else {
            Self.logger.info("[CMP-MARKERS] public lookup skipped: the episode has no series, season or episode number")
            return
        }
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
                guard identity.theIntroDBIdentifier != nil else {
                    Self.logger.info("[CMP-MARKERS] public lookup skipped: the series has no TMDB or IMDb ID")
                    return
                }
                // TheIntroDB first; its result is published straight away,
                // over the server's markers.
                let theIntroDB = await Self.publicMarkers("TheIntroDB") {
                    try await VividIntroDBClient.shared.theIntroDBSegments(for: identity)
                }
                let fetched = VividIntroDBClient.Segments(
                    imdb_id: imdb, season: season, episode: episode,
                    intro: nil, outro: nil, tmdb_id: identity.tmdbID
                ).fillingMissing(from: theIntroDB)
                guard let self, isCurrent(self) else { return }
                self.updateIntroDBSegments(Self.preferring(fetched, over: serverMarkers))
                // IntroDB only fills what TheIntroDB lacks, so a slow or
                // failed lookup never delays a prompt that's already there.
                guard fetched.intro == nil || fetched.outro == nil || fetched.recap == nil else { return }
                let gaps = await Self.publicMarkers("IntroDB") {
                    try await VividIntroDBClient.shared.introDBSegments(for: identity)
                }
                guard isCurrent(self),
                      let gaps, gaps.intro != nil || gaps.outro != nil || gaps.recap != nil else { return }
                self.updateIntroDBSegments(Self.preferring(fetched.fillingMissing(from: gaps), over: serverMarkers))
            } catch is CancellationError {
                // A newer item or setting change took over.
            } catch {
                // The series lookup failed. Missing markers never block
                // playback. Only the error's type is logged, never its text,
                // which can name the server.
                Self.logger.info("[CMP-MARKERS] series lookup failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// One public service's markers, or nil when it has none or fails. A
    /// failure (other than cancellation) logs the service and the error's
    /// type, never its text; a service with no markers answers nil itself.
    static func publicMarkers(
        _ service: String,
        _ lookup: () async throws -> VividIntroDBClient.Segments?
    ) async -> VividIntroDBClient.Segments? {
        do {
            return try await lookup()
        } catch is CancellationError {
            return nil
        } catch {
            // A cancelled task's request fails with URLError, not a
            // CancellationError, and isn't a service failure.
            guard !Task.isCancelled else { return nil }
            logger.info("[CMP-MARKERS] \(service, privacy: .public) lookup failed: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// The looked-up markers, with any kind they lack taken from the
    /// server's markers for the selected file.
    static func preferring(_ lookedUp: VividIntroDBClient.Segments,
                           over server: VividIntroDBClient.Segments) -> VividIntroDBClient.Segments {
        VividIntroDBClient.Segments(
            imdb_id: lookedUp.imdb_id, season: lookedUp.season, episode: lookedUp.episode,
            intro: lookedUp.intro ?? server.intro, outro: lookedUp.outro ?? server.outro,
            recap: lookedUp.recap ?? server.recap, tmdb_id: lookedUp.tmdb_id)
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
        guard settings.autoSkipIntro,
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
                  self.settings.autoSkipIntro,
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
        // Until the next episode is known, these may be such credits (a
        // resume inside them gets here first). This runs again on the next
        // time report.
        guard !isLoadingNextUpEpisode else { return }
        let key = creditsRange.flatMap(currentCreditsSkipKey(for:))
        guard let target = CreditsAutoSkipPolicy.target(
            enabled: settings.autoSkipCredits,
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
