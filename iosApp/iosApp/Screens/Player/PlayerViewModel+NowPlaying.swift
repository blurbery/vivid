import Foundation
import OSLog

/// The system's Now Playing: the lock screen, Control Center and Apple TV's
/// What's Playing, and the remote commands that come back from them.
extension PlayerViewModel {
    // MARK: - Destination

    func attachNowPlayingIfNeeded() {
        syncNowPlayingDestination()
    }

    /// Rebinds commands and publication whenever the engine changes its video
    /// route. Native video uses the engine's player-scoped session; software
    /// video uses the shared fallback. Rebinding clears the previous
    /// destination first.
    func syncNowPlayingDestination() {
        guard !isDisposed else {
            nowPlaying.detach()
            return
        }
        #if os(tvOS)
        nowPlaying.nativeMetadataHandler = { [weak engine = vividPlaybackController.engine] title, artwork in
            engine?.updateNativeMetadata(title: title, artwork: artwork)
        }
        #endif
        let handlers = VividVideoNowPlayingCoordinator.Handlers(
            play: { [weak self] in self?.handleNowPlayingPlay() },
            pause: { [weak self] in self?.handleNowPlayingPause() },
            isPaused: { [weak self] in
                guard let self else { return true }
                return self.hasReachedEndOfFile || self.vividPlaybackController.isPaused
            },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            // Remote positions are on the source axis published here, and go
            // through the view model so a bounded Silo transport can replan.
            seek: { [weak self] seconds in self?.seekTo(seconds: seconds) },
            // A command answered `.success` while the controller has no load
            // reports work the system will never see happen.
            hasActiveLoad: { [weak self] in
                self?.vividPlaybackController.hasActiveLoad ?? false
            }
        )
        #if os(iOS) || os(tvOS)
        nowPlaying.attach(
            session: vividPlaybackController.videoNowPlayingSession,
            useSharedFallback: vividPlaybackController.shouldUseSharedVideoNowPlayingFallback,
            handlers: handlers
        )
        #endif
    }

    // On Apple TV the remote's Play/Pause button can arrive through the
    // player-scoped command centre instead of SwiftUI's `onPlayPauseCommand`.
    // It reveals the controls, as Select does.

    private func handleNowPlayingPlay() {
        vividPlaybackController.play()
        #if os(tvOS)
        scheduleHideControls()
        #endif
    }

    private func handleNowPlayingPause() {
        vividPlaybackController.pause()
        #if os(tvOS)
        scheduleHideControls()
        #endif
    }

    // MARK: - Publishing

    /// Publishes at most every two seconds; the system moves the timeline
    /// between updates from the playback rate.
    func pushNowPlayingIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastNowPlayingPush) > 2.0 else { return }
        lastNowPlayingPush = now
        pushNowPlayingSnapshot()
    }

    func pushNowPlayingSnapshot() {
        guard hasActiveVividSession, !title.isEmpty else { return }
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: isPlaying,
            playbackRate: settings.playbackSpeed
        )
    }

    // MARK: - Artwork

    /// Caller-supplied artwork URLs for the item the player opened, passed on
    /// from `PlayerView.onAppear`, so `pushNowPlayingArtwork` can skip its own
    /// item fetch. Starting the next episode clears them.
    func applyArtworkURLHints(posterURL: String?, backdropURL: String?) {
        artworkPosterURLHint = posterURL
        artworkBackdropURLHint = backdropURL
    }

    /// Publishes the item's poster (or its backdrop when it has no poster) as
    /// Now Playing artwork. The presenter's hint is used when it gave one;
    /// otherwise the item is fetched. Best effort: a failure leaves the
    /// artwork as it was.
    func pushNowPlayingArtwork(contentId: String) {
        guard !contentId.isEmpty else { return }
        if let hint = Self.nonEmptyURLString(artworkPosterURLHint) ?? Self.nonEmptyURLString(artworkBackdropURLHint),
           let url = URL(string: hint) {
            nowPlaying.setArtworkURL(url)
            return
        }
        Task { [weak self] in
            let detail: ItemDetail
            do {
                detail = try await VividAPI.shared.itemDetail(contentId: contentId)
            } catch {
                Self.logger.warning(
                    "NowPlaying artwork itemDetail fetch failed for \(contentId, privacy: .public): \(DiagLog.publicLogText(error), privacy: .public)"
                )
                return
            }
            guard let candidate = Self.nonEmptyURLString(detail.posterUrl) ?? Self.nonEmptyURLString(detail.backdropUrl),
                  let url = URL(string: candidate) else {
                return
            }
            // A slow fetch can finish after another item has started loading,
            // and must not put this item's artwork on it.
            guard let self, !self.isDisposed, self.currentWatchDetail?.contentId == contentId else { return }
            self.nowPlaying.setArtworkURL(url)
        }
    }

    private static func nonEmptyURLString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
