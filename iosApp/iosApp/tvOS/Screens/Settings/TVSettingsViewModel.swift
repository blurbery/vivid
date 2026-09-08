#if os(tvOS)
import Foundation

/// Device-local playback and embedded-subtitle preferences for this Apple TV.
@Observable
final class TVSettingsViewModel {
    /// Friendly label for the active server. Reads through the registry
    /// so a rename or switch reflects without reloading the screen.
    var serverDisplayName: String {
        ServerRegistry.shared.activeServer?.displayName ?? ""
    }

    /// Raw URL of the active server. Shown as the caption under the
    /// friendly name. Reads through the registry so it tracks switches.
    var serverUrl: String {
        ServerRegistry.shared.activeServerUrl
    }

    // Playback preferences saved locally for this device/profile.

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
    /// VividKit's asynchronous read-ahead target.
    var bufferAhead: BufferAheadMode = PlayerSettings.shared.bufferAhead

    // Local text-subtitle appearance.
    var subtitleAppearance: SubtitleAppearance = PlayerSettings.shared.subtitleAppearance
    var subtitleUsesDeviceAppearanceOverride: Bool = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
    var subtitleMatchesSystemAppearance: Bool = PlayerSettings.shared.subtitleMatchesSystemAppearance

    /// What the player will actually render with: system captions, the
    /// device override, or Vivid defaults.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        PlayerSettings.shared.effectiveSubtitleAppearance
    }

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

    // MARK: - Load / save

    @MainActor
    func load() async {
        await PlayerSettings.shared.reloadForCurrentProfile()
        adoptQualityFromPlayerSettings()
        preferredAudioLanguage = PlayerSettings.shared.audioLanguage
        autoPlayNext = PlayerSettings.shared.autoPlayNextEpisode
        nextUpPromptSeconds = PlayerSettings.shared.nextUpPromptSeconds
        skipIntros = PlayerSettings.shared.autoSkipIntro
        skipCredits = PlayerSettings.shared.autoSkipCredits
        bufferAhead = PlayerSettings.shared.bufferAhead
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance

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
    func setBufferAhead(_ mode: BufferAheadMode) async {
        PlayerSettings.shared.setBufferAhead(mode)
        bufferAhead = PlayerSettings.shared.bufferAhead
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
    func resetSubtitleAppearance() async {
        await PlayerSettings.shared.setSubtitleAppearance(.default)
        subtitleAppearance = PlayerSettings.shared.subtitleAppearance
        subtitleUsesDeviceAppearanceOverride = PlayerSettings.shared.subtitleUsesDeviceAppearanceOverride
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

    @MainActor
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) async {
        PlayerSettings.shared.setSubtitleMatchesSystemAppearance(enabled)
        subtitleMatchesSystemAppearance = PlayerSettings.shared.subtitleMatchesSystemAppearance
    }

}
#endif
