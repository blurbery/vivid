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

/// What showed or hid the player controls. On iPhone and iPad the Latest
/// Playback report counts the controls going away soon after they appear,
/// by what showed them and what hid them.
enum PlayerControlsCause: String {
    case videoTap = "video_tap"
    case backgroundTap = "background_tap"
    case loadingTap = "loading_tap"
    case nextUpTap = "next_up_tap"
    case doubleTapPlayPause = "double_tap_play_pause"
    case control
    case autoHide = "auto_hide"
    case dismissed
    case fileLoaded = "file_loaded"
    case newLoad = "new_load"
    case nextUp = "next_up"
    case other
}

extension PlayerViewModel {
    /// Sets `showControls`, noting what changed it for the Latest Playback
    /// report. The only way a cause is recorded, so none can carry over to a
    /// later change.
    func setControlsVisible(_ visible: Bool, cause: PlayerControlsCause) {
        pendingControlsCause = cause
        showControls = visible
    }

    func toggleControls(cause: PlayerControlsCause = .other) {
        setControlsVisible(!showControls, cause: cause)
        if showControls {
            scheduleHideControls()
        }
    }

    func revealControls() {
        scheduleHideControls()
    }

    #if os(iOS)
    func touchControlPressChanged(_ pressed: Bool) {
        guard showControls else { touchControlPressed = false; return }
        touchControlPressed = pressed
        if pressed { hideControlsTask?.cancel() }
        else { scheduleHideControls() }
    }
    #endif

    /// Hide the controls overlay immediately, cancelling any pending
    /// auto-hide. Wired to the Siri Remote Menu button on tvOS so the user
    /// can dismiss the overlay without waiting out the 5s timer; tapping
    /// Menu again falls through to player dismissal via `PlayerView`.
    func dismissControls() {
        if isHoldSeeking {
            cancelHoldSeek()
        }
        hideControlsTask?.cancel()
        withAnimation { setControlsVisible(false, cause: .dismissed) }
    }

    /// Keep the controls overlay visible and cancel the pending auto-hide.
    /// Used while the HUD is presented — otherwise the auto-hide timer can
    /// tear the HUD's host out from under it.
    func pinControlsVisible() {
        #if os(iOS)
        touchControlsPinned = true
        #endif
        hideControlsTask?.cancel()
        setControlsVisible(true, cause: .control)
    }

    /// Resume the standard auto-hide behavior after a pin.
    func resumeAutoHide() {
        #if os(iOS)
        touchControlsPinned = false
        #endif
        scheduleHideControls()
    }

    /// Open the tvOS options HUD. Synchronous so the shell-level Menu handler
    /// and the transport overlay see a consistent state within one run loop.
    func openHUD() {
        if isHoldSeeking {
            cancelHoldSeek()
        }
        pinControlsVisible()
        isHUDPresented = true
    }

    #if os(tvOS)
    func openSettingsHUD() {
        requestedTVHUDEntryPoint = .settings
        openHUD()
    }

    func openPlaybackHUD() {
        requestedTVHUDEntryPoint = .playback
        openHUD()
    }

    func consumeTVHUDEntryRequest() {
        requestedTVHUDEntryPoint = nil
    }
    #endif

    /// Close the tvOS options HUD and resume normal auto-hide. Safe to call
    /// when the HUD is already closed.
    func closeHUD() {
        guard isHUDPresented else { return }
        isHUDPresented = false
        scheduleHideControls()
    }

    /// Duration the transport overlay stays on-screen after the last user
    /// interaction before auto-hiding while playing.
    private static let autoHideSeconds: UInt64 = 5

    /// `cause` is what showed the controls, when this call is the one that
    /// shows them.
    func scheduleHideControls(revealedBy cause: PlayerControlsCause = .control) {
        #if os(iOS)
        if touchControlPressed {
            hideControlsTask?.cancel()
            return
        }
        if touchControlsPinned {
            pinControlsVisible()
            return
        }
        #endif
        // The HUD pins its host visible (`pinControlsVisible` in `openHUD`).
        // Actions taken from inside it — track selection, remote play/pause —
        // funnel through here and must not re-arm the auto-hide out from
        // under the open HUD: on tvOS the hide swaps the press-capture sink
        // in beneath it, splitting remote presses across two owners.
        // `closeHUD()` calls back in after clearing the flag, which restores
        // the normal auto-hide lifecycle.
        if isHUDPresented {
            pinControlsVisible()
            return
        }
        hideControlsTask?.cancel()
        setControlsVisible(true, cause: cause)
        hideControlsTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.autoHideSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                break
            }
            guard let self, !self.isScrubbing else { return }
            guard self.isPlaying else { return }
            withAnimation { self.setControlsVisible(false, cause: .autoHide) }
        }
    }
}
