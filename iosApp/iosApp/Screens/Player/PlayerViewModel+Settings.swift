import Foundation

/// Player settings applied to the engine: speed, video gravity, subtitle
/// appearance and delay, and where the automatic subtitle pick takes its
/// preferences from.
extension PlayerViewModel {
    // MARK: - Applying settings

    func applySettingsToPlayer() {
        vividPlaybackController.setSpeed(settings.playbackSpeed)
        vividPlaybackController.engine.videoGravity = settings.videoGravity.avGravity
    }

    func applySubtitleAppearanceToPlayer() {
        vividPlaybackController.engine.applySubtitleSettings(
            appearance: settings.effectiveSubtitleAppearance,
            delayMilliseconds: subtitleDelayMs,
            secondaryDelayMilliseconds: secondarySubtitleDelayMs
        )
    }

    @MainActor
    func refreshSettingsFromServer() async {
        await settings.reloadForCurrentProfile()
        applySettingsToPlayer()
    }

    // MARK: - Speed and gravity

    func setPlaybackSpeed(_ rate: Double) {
        settings.setPlaybackSpeed(rate)
        vividPlaybackController.setSpeed(settings.playbackSpeed)
        scheduleHideControls()
    }

    /// Touch-and-hold fast forward on iPhone and iPad. The rate goes straight
    /// to the engine and `settings.playbackSpeed` is left alone, so letting go
    /// restores the viewer's speed. Does nothing while paused, since a held
    /// 2x on a paused player means nothing.
    func beginHoldFastForward(rate: Double = 2.0) {
        guard !isHoldFastForwarding, isPlaying else { return }
        isHoldFastForwarding = true
        vividPlaybackController.setSpeed(rate)
    }

    /// Always restores the viewer's speed, even if playback paused during the
    /// hold: the engine doesn't start a paused clock on `setSpeed`, and a
    /// leftover hold rate would make the next play resume at 2x.
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

    // MARK: - Subtitle delay

    /// The delay the Subtitle Delay controls show and change: an OpenSubtitles
    /// file's own offset while it's the main subtitle, otherwise the normal
    /// subtitle delay.
    var subtitleDelayMs: Int {
        #if os(iOS) || os(tvOS)
        if let entry = selectedOpenSubtitle { return entry.offsetMs }
        #endif
        return settings.subtitleSyncMs
    }

    /// The secondary subtitle's delay: its own offset when it's an
    /// OpenSubtitles file, otherwise the normal subtitle delay.
    var secondarySubtitleDelayMs: Int {
        #if os(iOS) || os(tvOS)
        if let id = selectedSecondarySubtitleId, let entry = openSubtitleFiles.entries[id] { return entry.offsetMs }
        #endif
        return settings.subtitleSyncMs
    }

    /// A live change while the control is being adjusted; nothing is saved
    /// until `setSubtitleSyncMilliseconds`.
    func previewSubtitleDelay(_ milliseconds: Int) {
        #if os(iOS) || os(tvOS)
        if selectedOpenSubtitle != nil {
            setOpenSubtitleOffset(milliseconds, save: false)
            return
        }
        #endif
        settings.subtitleSyncMs = milliseconds
    }

    func setSubtitleSyncMilliseconds(_ milliseconds: Int) {
        #if os(iOS) || os(tvOS)
        if selectedOpenSubtitle != nil {
            setOpenSubtitleOffset(milliseconds, save: true)
            return
        }
        #endif
        settings.setSubtitleSyncMs(milliseconds)
        applySubtitleAppearanceToPlayer()
    }

    // MARK: - Subtitle appearance

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        let followedDeviceSettings = settings.subtitleMatchesSystemAppearance
        await settings.setSubtitleAppearance(appearance)
        applySubtitleAppearanceToPlayer()
        // Editing the style leaves Use Device Settings, and the subtitle choice
        // goes back to Settings > Subtitles with it.
        if followedDeviceSettings, !settings.subtitleMatchesSystemAppearance {
            subtitleSettingsSourceDidChange()
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
        subtitleSettingsSourceDidChange()
    }

    /// The device's caption settings may have changed (MediaAccessibility's
    /// notification, or a return to the app). With Use Device Settings on, the
    /// new style reaches the engine and Auto picks again, unless a subtitle
    /// was picked in this viewing.
    @MainActor
    func systemCaptionSettingsDidChange() {
        guard !isDisposed, settings.subtitleMatchesSystemAppearance else { return }
        settings.refreshSubtitleSystemAppearance()
        applySubtitleAppearanceToPlayer()
        subtitleOrderingLanguage = settings.subtitleSystemSelectionPreferences.preferredLanguages.first
        guard !hasExplicitSubtitleChoice, viewingSubtitlePrefs == nil else { return }
        prefsForCurrentItem = systemCaptionPrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }

    /// Use Device Settings changed, so the automatic pick starts again from
    /// the settings now in charge, and a pick made in this viewing is dropped.
    @MainActor
    private func subtitleSettingsSourceDidChange() {
        subtitleOrderingLanguage = settings.subtitleMatchesSystemAppearance
            ? settings.subtitleSystemSelectionPreferences.preferredLanguages.first
            : settings.preferredSubtitleLanguage
        hasExplicitSubtitleChoice = false
        viewingSubtitlePrefs = nil
        prefsForCurrentItem = automaticSubtitlePrefsSnapshot()
        prefsResolvedForCurrentItem = false
        applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
    }
}
