import Foundation
import SwiftUI

/// What showed or hid the player controls. On iPhone and iPad the Latest
/// Playback report counts the controls going away soon after they appear,
/// by what showed them and what hid them. The raw values are what it records.
enum PlayerControlsCause: String {
    case videoTap = "video_tap"
    case backgroundTap = "background_tap"
    case loadingTap = "loading_tap"
    case nextUpTap = "next_up_tap"
    case doubleTapPlayPause = "double_tap_play_pause"
    case control
    case qualitySwitch = "quality_switch"
    case playbackEnded = "playback_ended"
    case autoHide = "auto_hide"
    case dismissed
    case fileLoaded = "file_loaded"
    case newLoad = "new_load"
    case nextUp = "next_up"
    case other
}

/// The transport controls' visibility and auto-hide, and the Apple TV HUD.
///
/// Visible controls hide five seconds after the last interaction while
/// playing. They stay up while scrubbing, while paused, while a control is
/// held, and while the HUD or a pinning menu is open.
extension PlayerViewModel {
    /// How long the controls stay up after the last interaction.
    private static let autoHideSeconds: UInt64 = 5

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

    /// Shows the controls and restarts the auto-hide. `cause` is what showed
    /// them, when this call is the one that does.
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
        // The HUD pins its host visible. Actions taken inside it (track
        // picks, remote play and pause) come through here and must not start
        // the auto-hide under it: on Apple TV the hide puts the press-capture
        // sink back beneath the HUD, splitting remote presses between two
        // owners. `closeHUD()` calls back in once the flag is clear.
        if isHUDPresented {
            pinControlsVisible()
            return
        }
        hideControlsTask?.cancel()
        setControlsVisible(true, cause: cause)
        hideControlsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoHideSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isScrubbing, self.isPlaying else { return }
            withAnimation { self.setControlsVisible(false, cause: .autoHide) }
        }
    }

    /// Hides the controls at once, cancelling the auto-hide. The Siri Remote's
    /// Menu button uses it, and pressing Menu again closes the player.
    func dismissControls() {
        if isHoldSeeking {
            cancelHoldSeek()
        }
        hideControlsTask?.cancel()
        withAnimation { setControlsVisible(false, cause: .dismissed) }
    }

    /// Keeps the controls up with no auto-hide, while a menu or the HUD is
    /// open; otherwise the auto-hide would pull their host out from under it.
    func pinControlsVisible() {
        #if os(iOS)
        touchControlsPinned = true
        #endif
        hideControlsTask?.cancel()
        setControlsVisible(true, cause: .control)
    }

    /// Ends a pin and restarts the auto-hide.
    func resumeAutoHide() {
        #if os(iOS)
        touchControlsPinned = false
        #endif
        scheduleHideControls()
    }

    #if os(iOS)
    /// How long after the controls appear a tap on the dimmed background
    /// keeps them up instead of hiding them. A finger that just misses a
    /// centre button, or a quick second tap, landed there and hid the
    /// controls within half a second on a tester's iPad, before play or
    /// pause could be reached.
    static let backgroundTapGraceSeconds: TimeInterval = 1.5

    /// A tap on the dimmed background behind the controls. Hides them, unless
    /// they appeared within `backgroundTapGraceSeconds`: then it counts as
    /// interaction and restarts the auto-hide.
    func backgroundTapped(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if showControls, let appearedAt = controlsAppearedAt,
           now - appearedAt < Self.backgroundTapGraceSeconds {
            revealControls()
            return
        }
        toggleControls(cause: .backgroundTap)
    }

    /// A finger on a control holds the controls up until it lifts.
    func touchControlPressChanged(_ pressed: Bool) {
        guard showControls else {
            touchControlPressed = false
            return
        }
        touchControlPressed = pressed
        if pressed {
            hideControlsTask?.cancel()
        } else {
            scheduleHideControls()
        }
    }
    #endif

    // MARK: - Apple TV HUD

    /// Opens the options HUD. Synchronous, so the Menu handler and the
    /// transport see the same state within one run loop pass.
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

    func consumeTVHUDEntryRequest() {
        requestedTVHUDEntryPoint = nil
    }
    #endif

    /// Closes the HUD and restarts the auto-hide. Safe to call when it's
    /// already closed.
    func closeHUD() {
        guard isHUDPresented else { return }
        isHUDPresented = false
        scheduleHideControls()
    }
}
