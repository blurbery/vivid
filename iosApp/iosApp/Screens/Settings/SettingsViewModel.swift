import Foundation

/// State container for the iOS settings screen.
///
/// Two scopes meet here. Playback choices that belong to *this device* (quality,
/// skip behaviour, sync offsets) and the subtitle language, behaviour and
/// forced trio go through ``PlayerSettings``, saved on this device for the
/// current profile. The subtitle trio is the only input to automatic subtitle
/// choice on every server; no server-side subtitle setting is read or written.
/// The tvOS screen is the twin of this
/// one.
@Observable
class SettingsViewModel {
    var userInfo: UserInfo?
    var activeProfile: UserProfile?
    var isLoading = false
    var error: String?

    /// Active server URL. Reads through the registry so a server switch
    /// reflects here without a reload. Used by the account-card subtitle
    /// to derive a short host label.
    var serverUrl: String { ServerRegistry.shared.activeServerUrl }

    /// Friendly label for the active server, shown in the Settings
    /// `Server` row. User override → server-advertised name → URL.
    var serverDisplayName: String {
        ServerRegistry.shared.activeServer?.displayName ?? String(localized: "Not configured")
    }

    // Playback preferences.

    /// The selected shared preset's id, or nil when the stored pair is a
    /// combination no preset covers. The picker shows ``preferredQualityLabel``
    /// in that case rather than snapping to a nearby preset, which would show
    /// the user a choice they did not make.
    var preferredQualityPresetId: String? = PlayerSettings.shared.currentQualityPreset?.id
    /// A label for whatever pair is stored, preset or not.
    var preferredQualityLabel: String = PlayerSettings.shared.preferredQualityLabel
    var preferredAudioLanguage: String = PlayerSettings.shared.audioLanguage
    var autoPlayNext: Bool = PlayerSettings.shared.autoPlayNextEpisode
    var nextUpPromptSeconds: Int = PlayerSettings.shared.nextUpPromptSeconds
    var skipIntros: Bool = PlayerSettings.shared.autoSkipIntro
    var skipCredits: Bool = PlayerSettings.shared.autoSkipCredits
    /// Local — it is a habit of this device, not of the profile.
    var backgroundPlaybackEnabled: Bool = PlayerSettings.shared.backgroundPlaybackEnabled
    /// Local — it spends this device's temporary storage, not the profile's.
    var bufferAhead: BufferAheadMode = PlayerSettings.shared.bufferAhead
    /// Local, like the rest of the Audio section's switches: how loud a title
    /// needs to be depends on this device's speakers.
    var volumeBoostEnabled: Bool = PlayerSettings.shared.volumeBoostEnabled
    var volumeBoostPercent: Int = PlayerSettings.shared.volumeBoostPercent
    var enhancedDialogueEnabled: Bool = PlayerSettings.shared.enhancedDialogueEnabled

    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    var subtitleMatchesSystemAppearance: Bool = PlayerSettings.shared.subtitleMatchesSystemAppearance

    /// What the player will actually render with: system captions, the
    /// device override, or the inherited server appearance.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

    var editorSubtitleLanguage: String {
        get { PlayerSettings.shared.preferredSubtitleLanguage }
        set {
            PlayerSettings.shared.preferredSubtitleLanguage = newValue
            // A backup in the same language would be a second copy of it.
            if SubtitleAutoResolver.languagesMatch(PlayerSettings.shared.preferredSubtitleBackupLanguage, newValue) {
                PlayerSettings.shared.preferredSubtitleBackupLanguage = PlaybackPrefSentinel.none
            }
        }
    }

    /// Used when a title has no subtitles in `editorSubtitleLanguage`.
    var editorSubtitleBackupLanguage: String {
        get { PlayerSettings.shared.preferredSubtitleBackupLanguage }
        set { PlayerSettings.shared.preferredSubtitleBackupLanguage = newValue }
    }

    var editorSubtitleMode: String {
        get { PlayerSettings.shared.preferredSubtitleMode }
        set { PlayerSettings.shared.preferredSubtitleMode = newValue }
    }

    /// Tri-state bound as "on" / "off".
    var editorShowForcedSubtitles: String {
        get { PlayerSettings.shared.showForcedSubtitles ? "on" : "off" }
        set { PlayerSettings.shared.showForcedSubtitles = newValue == "on" }
    }

    var audioLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .playbackAudioLanguage,
            currentValue: preferredAudioLanguage,
            runtimeValues: []
        )
    }

    var subtitleLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .playbackSubtitleLanguage,
            currentValue: editorSubtitleLanguage,
            runtimeValues: []
        )
    }

    /// Every subtitle language except the main one.
    var subtitleBackupLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .playbackSubtitleLanguage,
            currentValue: editorSubtitleBackupLanguage,
            runtimeValues: []
        )
        .filter { !SubtitleAutoResolver.languagesMatch($0.code, editorSubtitleLanguage) }
    }

    /// A backup only stands in for a chosen language, and Off shows nothing.
    var subtitleBackupLanguageApplies: Bool {
        editorSubtitleLanguage != PlaybackPrefSentinel.none
            && editorSubtitleMode != SubtitleMode.off.rawValue
    }

    /// Main-actor isolated: it publishes into observable state the settings
    /// views are already rendering.
    @MainActor
    func loadSettings() async {
        await PlayerSettings.shared.reloadForCurrentProfile()
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
        bufferAhead = PlayerSettings.shared.bufferAhead
        adoptAudioFromPlayerSettings()
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance

        async let user: UserInfo? = try? VividAPI.shared.get("/api/v1/user/me")
        async let profiles: [UserProfile] = (try? AuthService.shared.getProfiles()) ?? []

        let (loadedUser, loadedProfiles) = await (user, profiles)
        userInfo = loadedUser

        let activeProfileId = AuthService.shared.profileId
        if let activeProfileId {
            activeProfile = loadedProfiles.first(where: { $0.id == activeProfileId })
        } else {
            activeProfile = nil
        }
    }


    /// Apply a shared quality preset, which stores the contract's two axes.
    @MainActor
    func setQualityPreset(_ presetId: String) async {
        guard let preset = VividQualityPresets.preset(id: presetId) else { return }
        PlayerSettings.shared.setQualityPreset(preset)
        adoptQualityFromPlayerSettings()
    }

    private func adoptQualityFromPlayerSettings() {
        preferredQualityPresetId = PlayerSettings.shared.currentQualityPreset?.id
        preferredQualityLabel = PlayerSettings.shared.preferredQualityLabel
    }

    @MainActor
    func setPreferredAudioLanguage(_ value: String) async {
        PlayerSettings.shared.setAudioLanguage(value)
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
    }

    @MainActor
    func setAutoPlayNext(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoPlayNextEpisode(enabled)
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
    }

    @MainActor
    func setNextUpPromptSeconds(_ seconds: Int) async {
        PlayerSettings.shared.setNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
    }

    @MainActor
    func setSkipIntros(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoSkipIntro(enabled)
        skipIntros = PlayerSettings.shared.autoSkipIntro
    }

    @MainActor
    func setSkipCredits(_ enabled: Bool) async {
        PlayerSettings.shared.setAutoSkipCredits(enabled)
        skipCredits = PlayerSettings.shared.autoSkipCredits
    }




    @MainActor
    func setBackgroundPlaybackEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setBackgroundPlaybackEnabled(enabled)
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
    }

    @MainActor
    func setVolumeBoostEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setVolumeBoostEnabled(enabled)
        volumeBoostEnabled = PlayerSettings.shared.volumeBoostEnabled
    }

    @MainActor
    func setVolumeBoostPercent(_ percent: Int) async {
        PlayerSettings.shared.setVolumeBoostPercent(percent)
        volumeBoostPercent = PlayerSettings.shared.volumeBoostPercent
    }

    @MainActor
    func setEnhancedDialogueEnabled(_ enabled: Bool) async {
        PlayerSettings.shared.setEnhancedDialogueEnabled(enabled)
        enhancedDialogueEnabled = PlayerSettings.shared.enhancedDialogueEnabled
    }

    private func adoptAudioFromPlayerSettings() {
        volumeBoostEnabled = PlayerSettings.shared.volumeBoostEnabled
        volumeBoostPercent = PlayerSettings.shared.volumeBoostPercent
        enhancedDialogueEnabled = PlayerSettings.shared.enhancedDialogueEnabled
    }



    @MainActor
    func resetPlaybackDeviceSettings() async {
        await PlayerSettings.shared.resetAllDeviceSettings()
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        // The device-local rows are restored by the same reset, so the screen
        // has to re-adopt them too or it keeps showing the old choice.
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
        bufferAhead = PlayerSettings.shared.bufferAhead
        adoptAudioFromPlayerSettings()
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await PlayerSettings.shared.setSubtitleAppearance(appearance)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        await PlayerSettings.shared.setSubtitleDeviceOverrideEnabled(enabled)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    }

    @MainActor
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) async {
        PlayerSettings.shared.setSubtitleMatchesSystemAppearance(enabled)
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }
}
