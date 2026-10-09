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
    func applySettingsToPlayer() {
        vividPlaybackController.setSpeed(settings.playbackSpeed)
        vividPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    func applySubtitleAppearanceToPlayer() {
        vividPlaybackController.engine.applySubtitleSettings(
            appearance: settings.effectiveSubtitleAppearance,
            delayMilliseconds: subtitleDelayMs
        )
    }

    /// The delay the Subtitle Delay controls show and change: an OpenSubtitles
    /// file's own offset while it's the main subtitle, otherwise the normal
    /// subtitle delay.
    var subtitleDelayMs: Int {
        #if os(iOS) || os(tvOS)
        if let entry = selectedOpenSubtitle { return entry.offsetMs }
        #endif
        return settings.subtitleSyncMs
    }

    /// A live change while the control is being adjusted; commit saves it.
    func previewSubtitleDelay(_ milliseconds: Int) {
        #if os(iOS) || os(tvOS)
        if selectedOpenSubtitle != nil { setOpenSubtitleOffset(milliseconds, save: false); return }
        #endif
        settings.subtitleSyncMs = milliseconds
    }

    @MainActor
    func refreshSettingsFromServer() async {
        await settings.reloadForCurrentProfile()
        applySettingsToPlayer()
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await settings.setSubtitleAppearance(appearance)
        applySubtitleAppearanceToPlayer()
    }

    @MainActor
    func setSubtitlePosition(_ position: SubtitlePositionPreset) {
        var next = settings.subtitleAppearance
        guard next.position != position else { return }
        next.position = position
        settings.subtitleAppearance = next.sanitized()
        settings.subtitleUsesDeviceAppearanceOverride = true
        applySubtitleAppearanceToPlayer()
        Task { [settings] in
            await settings.setSubtitleAppearance(next)
        }
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await settings.setSubtitleDeviceOverrideEnabled(enabled)
        applySubtitleAppearanceToPlayer()
    }

    @MainActor
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        settings.setSubtitleMatchesSystemAppearance(enabled)
        applySubtitleAppearanceToPlayer()
        subtitleOrderingLanguage = enabled
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : settings.preferredSubtitleLanguage
        hasExplicitSubtitleChoice = false
        prefsForCurrentItem = enabled
            ? systemCaptionPrefsSnapshot()
            : currentWatchDetail.map(localSubtitlePrefsSnapshot)
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    func setPlaybackSpeed(_ rate: Double) {
        settings.setPlaybackSpeed(rate)
        vividPlaybackController.setSpeed(settings.playbackSpeed)
        scheduleHideControls()
    }

    /// Touch-and-hold fast forward (iOS). Applies `rate` directly to the
    /// backend without touching `settings.playbackSpeed`, so releasing the
    /// hold restores whatever speed the user had configured. No-op while
    /// paused — holding 2× on a paused player means nothing (both backends
    /// only apply rates to an already-running clock, so this is UX, not
    /// safety).
    func beginHoldFastForward(rate: Double = 2.0) {
        guard !isHoldFastForwarding, isPlaying else { return }
        isHoldFastForwarding = true
        vividPlaybackController.setSpeed(rate)
    }

    /// Always restores the configured speed, even if playback paused during
    /// the hold: backends don't start a paused clock on `setSpeed`, and
    /// leaving the hold rate behind would make the next play resume at 2×.
    func endHoldFastForward() {
        guard isHoldFastForwarding else { return }
        isHoldFastForwarding = false
        vividPlaybackController.setSpeed(settings.playbackSpeed)
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        settings.setVideoGravity(gravity)
        guard backendCapabilities.supportsVideoGravity else { return }
        vividPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    func setSubtitleSyncMilliseconds(_ milliseconds: Int) {
        #if os(iOS) || os(tvOS)
        if selectedOpenSubtitle != nil { setOpenSubtitleOffset(milliseconds, save: true); return }
        #endif
        settings.setSubtitleSyncMs(milliseconds)
        applySubtitleAppearanceToPlayer()
    }
}
