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

    func refreshIntroDBPreference() {
        if let detail = currentWatchDetail { loadVividMarkers(for: detail) }
        else { applyMarkerRanges(intro: nil, credits: nil) }
    }

    func loadVividMarkers(for detail: WatchDetail) {
        introDBLookupTask?.cancel()
        updateIntroDBSegments(nil)
        guard VividSkipSource.isEnabled, offlinePlaybackContext == nil else { return }
        // Use only the selected file's markers, never another edition's
        // item-level timestamps. Keep them visible if a public lookup fails.
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
            do {
                // Use the series identity, never an episode-level TMDB ID.
                let series = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
                try Task.checkCancellation()
                guard VividSkipSource.isEnabled else { return }
                let imdb = series.imdbId ?? ""
                let identity = VividIntroDBClient.Episode(imdbID: imdb, season: season, episode: episode,
                    tmdbID: series.tmdbId.flatMap(Int.init))
                guard identity.fallbackIdentifier != nil else { return }
                let fetched = try? await VividIntroDBClient.shared.segments(for: identity)
                let markers = VividIntroDBClient.Segments(
                    imdb_id: imdb, season: season, episode: episode,
                    intro: fileMarkers.intro, outro: fileMarkers.outro, tmdb_id: identity.tmdbID
                ).fillingMissing(from: fetched)
                guard let self, !Task.isCancelled, VividSkipSource.isEnabled,
                      self.activePlaybackSessionId == sessionID,
                      self.currentWatchDetail?.contentId == detail.contentId,
                      self.currentSelectedVersion?.fileId == fileID else { return }
                self.updateIntroDBSegments(markers)
                // Publish the primary result immediately. A slow or failed
                // fallback must never delay an existing intro or credits prompt.
                guard markers.intro == nil || markers.outro == nil || markers.recap == nil else { return }
                let fallback = try? await VividIntroDBClient.shared.fallbackSegments(for: identity)
                guard !Task.isCancelled, VividSkipSource.isEnabled,
                      self.activePlaybackSessionId == sessionID,
                      self.currentWatchDetail?.contentId == detail.contentId,
                      self.currentSelectedVersion?.fileId == fileID else { return }
                guard let fallback, fallback.intro != nil || fallback.outro != nil || fallback.recap != nil else { return }
                let combined = markers.fillingMissing(from: fallback)
                self.updateIntroDBSegments(combined)
            } catch {
                // Missing timestamps or temporary service failure never block playback.
            }
        }
    }

    // Keep the raw response until the engine supplies a finite duration. A
    // fast/cached lookup can finish before probing, especially on native HLS.
    func updateIntroDBSegments(_ segments: VividIntroDBClient.Segments?) {
        loadedIntroDBSegments = segments
        recapRange = segments?.recap?.range(duration: duration)
        applyMarkerRanges(intro: segments?.intro?.range(duration: duration),
                          credits: segments?.outro?.range(duration: duration))
    }

    func applyLoadedIntroDBSegments() {
        guard let segments = loadedIntroDBSegments else { return }
        recapRange = segments.recap?.range(duration: duration)
        applyMarkerRanges(intro: segments.intro?.range(duration: duration),
                          credits: segments.outro?.range(duration: duration))
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
                guard let self,
                      !Task.isCancelled,
                      self.pendingAutoSkipIntroKey == key else {
                    return
                }
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

    func autoSkipCreditsIfNeeded(at time: Double) {
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

        // Set the latch before seeking: a synchronous backend time callback
        // caused by the seek must see this marker as already handled.
        autoSkippedCreditsKey = key
        Self.logger.info(
            "[CMP-MARKERS] auto-skip credits target=\(target, privacy: .public) current=\(time, privacy: .public)"
        )
        performCreditsSkip(to: target)
    }

    func performCreditsSkip(to target: Double) {
        // Vivid deliberately parks a programmatic seek at the exact duration
        // in a paused state. TheIntroDB uses that exact bound when credits run
        // to EOF, so complete the item through Silo's normal end/Next Up path
        // instead of leaving a frozen final frame.
        if duration.isFinite,
           duration > 0,
           target >= duration - 0.5 {
            currentTime = duration
            handleEndOfFile()
            return
        }
        seekTo(seconds: target, revealingControls: false)
    }

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
