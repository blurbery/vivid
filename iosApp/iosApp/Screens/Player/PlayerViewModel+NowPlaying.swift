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
    /// Pushes the current item's poster into the Now Playing artwork field
    /// so the lock-screen, Control Center, and Apple TV "What's Playing"
    /// surface have a thumbnail. The poster URL is derived from the
    /// content's library catalog entry rather than `WatchDetail`, which
    /// doesn't expose image fields. The fetch runs in a background task on
    /// the Vivid video Now Playing coordinator and is best-effort: any
    /// failure leaves the existing artwork (or none) unchanged.
    func pushNowPlayingArtwork(contentId: String) {
        guard !contentId.isEmpty else { return }
        // The presenter (e.g. ItemDetailView) already had the catalog
        // item loaded — when it routed us through `applyArtworkURLHints`
        // we can publish artwork without a second `/catalog/items/{id}`
        // round-trip. Fall through to the fetch only when no hint was
        // supplied.
        if let candidate = preferredArtworkCandidate(),
           let url = URL(string: candidate) {
            nowPlaying.setArtworkURL(url)
            return
        }
        Task { [weak self] in
            let detail: ItemDetail
            do {
                detail = try await VividAPI.shared.itemDetail(contentId: contentId)
            } catch {
                Self.logger.warning(
                    "NowPlaying artwork itemDetail fetch failed for \(contentId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            // Prefer poster; fall back to backdrop for items (notably some
            // episodes) that don't surface a dedicated poster.
            let posterCandidate = detail.posterUrl?.isEmpty == false ? detail.posterUrl : nil
            let backdropCandidate = detail.backdropUrl?.isEmpty == false ? detail.backdropUrl : nil
            guard let candidate = posterCandidate ?? backdropCandidate,
                  let url = URL(string: candidate) else {
                return
            }
            guard let self else { return }
            await MainActor.run {
                self.nowPlaying.setArtworkURL(url)
            }
        }
    }

    private func preferredArtworkCandidate() -> String? {
        if let poster = artworkPosterURLHint, !poster.isEmpty {
            return poster
        }
        if let backdrop = artworkBackdropURLHint, !backdrop.isEmpty {
            return backdrop
        }
        return nil
    }

    /// Caller-supplied artwork URLs piped through `PlayerView.onAppear`.
    /// Used by `pushNowPlayingArtwork` to skip its own catalog item fetch.
    func applyArtworkURLHints(posterURL: String?, backdropURL: String?) {
        artworkPosterURLHint = posterURL
        artworkBackdropURLHint = backdropURL
    }

    /// Push Now Playing at most every 2 seconds; the OS animates the
    /// scrubber between updates using `playbackRate`.
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

    func attachNowPlayingIfNeeded() {
        syncNowPlayingDestination()
    }

    /// Rebind commands and publication whenever Vivid swaps its effective
    /// video route. Native video uses Vivid's player-scoped session;
    /// software video (and macOS, where upstream has no video session) uses
    /// the shared fallback. Rebinding clears the previous destination first.
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
            // On tvOS the physical Play/Pause button can arrive through the
            // player-scoped media command center instead of SwiftUI's
            // `onPlayPauseCommand`. Keep that route visually consistent with
            // Select by revealing the transport controls as playback changes.
            play:        { [weak self] in self?.handleNowPlayingPlay() },
            pause:       { [weak self] in self?.handleNowPlayingPause() },
            isPaused:    { [weak self] in
                guard let self else { return true }
                return self.hasReachedEndOfFile || self.vividPlaybackController.isPaused
            },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            // Remote-position events use the source axis published above and
            // must pass through the VM so a bounded V3 transport can replan.
            seek:        { [weak self] t in self?.seekTo(seconds: t) },
            // A command answered `.success` while the controller has no load
            // reports work the system will never observe.
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
        #else
        nowPlaying.attach(
            useSharedFallback: vividPlaybackController.shouldUseSharedVideoNowPlayingFallback,
            handlers: handlers
        )
        #endif
    }

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
}
