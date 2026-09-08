import Foundation

/// State container for the iOS settings screen.
///
/// Two scopes meet here. Playback choices that belong to *this device* (quality,
/// skip behaviour, sync offsets) go through ``PlayerSettings`` at
/// `profile_device`. The subtitle-language / behavior / forced trio and the
/// metadata language are the *profile's* choices and go through
/// ``ProfileSettingsWriter`` at `profile` — the same keys, scope and wire
/// values the web and Android clients use, so an edit made on any of them reads
/// back the same on the others. The tvOS screen is the twin of this one.
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
        ServerRegistry.shared.activeServer?.displayName ?? "Not configured"
    }

    // Playback preferences (server-backed for this device/profile).

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

    // Subtitle styling (local — applies to renderer overrides, not the
    // language/behavior selection that lives server-side).
    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    var subtitleMatchesSystemAppearance: Bool = PlayerSettings.shared.subtitleMatchesSystemAppearance

    /// What the player will actually render with: system captions, the
    /// device override, or the inherited server appearance.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

    /// Profile-scoped preferences, written at `scope=profile` through the
    /// canonical settings API. Shared with the tvOS screen so the two cannot
    /// drift; the properties below forward to it so this type's existing API
    /// is unchanged for its views.
    let prefs = ProfilePrefsEditor()


    var editorSubtitleLanguage: String {
        get { PlayerSettings.shared.preferredSubtitleLanguage }
        set { PlayerSettings.shared.preferredSubtitleLanguage = newValue }
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

    /// Preferred metadata language. `PlaybackPrefSentinel.none` is the
    /// contract's null ("inherit the library default") on the wire.
    /// Gated on `AICapabilities.shared.metadataEnabled` at the row.
    var editorPreferredMetadataLanguage: String {
        get { prefs.preferredMetadataLanguage }
        set { prefs.preferredMetadataLanguage = newValue }
    }

    /// Surfaces the most recent server save state. The subtitle screen
    /// shows a transient message when this is non-nil.

    /// True when the connected server has no canonical settings API, so the
    /// server-backed controls cannot work and the screens say why.

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

    var metadataLanguageOptions: [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(
            for: .catalogMetadataLanguage,
            currentValue: editorPreferredMetadataLanguage,
            runtimeValues: prefs.metadataLanguageSuggestions
        )
    }

    /// Main-actor isolated: it publishes into observable state the settings
    /// views are already rendering, and seeds the profile editor, which is
    /// itself main-actor bound.
    @MainActor
    func loadSettings() async {
        prefs.bindProfile(id: AuthService.shared.profileId)
        await PlayerSettings.shared.reloadForCurrentProfile()
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
        bufferAhead = PlayerSettings.shared.bufferAhead
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

        // Paint the profile's own values first, then let the batched effective
        // read replace them: it is the only source that accounts for a library,
        // series or device override winning over the profile row.
        prefs.bindProfile(id: activeProfileId)
        prefs.seed(from: activeProfile)

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
    func setBufferAhead(_ mode: BufferAheadMode) async {
        PlayerSettings.shared.setBufferAhead(mode)
        bufferAhead = PlayerSettings.shared.bufferAhead
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


    /// Persist the preferred metadata language at `profile` scope.
    /// Triggered from the settings screen's `onChange` handler.
    @MainActor
    func saveMetadataLanguage() async {
        await prefs.saveMetadataLanguage()
    }
}
