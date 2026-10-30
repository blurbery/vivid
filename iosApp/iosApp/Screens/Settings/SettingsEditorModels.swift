import SwiftUI

/// Reads and choices shared by the iPhone, iPad and Apple TV settings
/// models. Everything is stored by `PlayerSettings`; nothing here keeps a
/// value of its own.
private enum PlaybackChoices {
    static var settings: PlayerSettings { .shared }

    /// The stored preset's id, when it's one Settings offers.
    static func selectablePresetID(_ settings: PlayerSettings) -> String? {
        guard let id = settings.currentQualityPreset?.id else { return nil }
        return VividQualityPresets.selectable.contains { $0.id == id } ? id : nil
    }

    static func audioOptions(current: String) -> [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(for: .playbackAudioLanguage, currentValue: current, runtimeValues: [])
    }

    static func subtitleOptions(current: String) -> [PlaybackLanguageOption] {
        PlaybackLanguageOption.options(for: .playbackSubtitleLanguage, currentValue: current, runtimeValues: [])
    }

    /// Subtitle languages for the backup, without the main language.
    static func backupOptions() -> [PlaybackLanguageOption] {
        let language = settings.preferredSubtitleLanguage
        return subtitleOptions(current: settings.preferredSubtitleBackupLanguage)
            .filter { !SubtitleAutoResolver.languagesMatch($0.code, language) }
    }

    static var backupApplies: Bool {
        settings.preferredSubtitleLanguage != PlaybackPrefSentinel.none
            && settings.preferredSubtitleMode != SubtitleMode.off.rawValue
    }

    /// Stores the subtitle language, and drops a backup that's now the same
    /// language.
    static func setSubtitleLanguage(_ value: String) {
        settings.preferredSubtitleLanguage = value
        if SubtitleAutoResolver.languagesMatch(settings.preferredSubtitleBackupLanguage, value) {
            settings.preferredSubtitleBackupLanguage = PlaybackPrefSentinel.none
        }
    }
}

#if os(iOS)
/// The values the iPhone and iPad Playback and Subtitles pages show, and
/// the changes they make.
@MainActor @Observable
final class SettingsViewModel {
    var qualityPresetID: String?
    var qualityLabel: String
    var audioLanguage: String
    var autoPlayNextEpisode: Bool
    var nextUpPromptSeconds: Int
    var autoSkipIntro: Bool
    var autoSkipCredits: Bool
    var backgroundPlaybackEnabled: Bool
    var volumeBoostEnabled: Bool
    var volumeBoostPercent: Int
    var enhancedDialogueEnabled: Bool
    var subtitleAppearance: SubtitleAppearance
    var usesCustomSubtitleAppearance: Bool
    var followsDeviceCaptions: Bool

    init() {
        let settings = PlayerSettings.shared
        qualityPresetID = PlaybackChoices.selectablePresetID(settings)
        qualityLabel = settings.preferredQualityLabel
        audioLanguage = settings.audioLanguage
        autoPlayNextEpisode = settings.autoPlayNextEpisode
        nextUpPromptSeconds = settings.nextUpPromptSeconds
        autoSkipIntro = settings.autoSkipIntro
        autoSkipCredits = settings.autoSkipCredits
        backgroundPlaybackEnabled = settings.backgroundPlaybackEnabled
        volumeBoostEnabled = settings.volumeBoostEnabled
        volumeBoostPercent = settings.volumeBoostPercent
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    private var settings: PlayerSettings { .shared }

    // MARK: Read live

    var effectiveSubtitleAppearance: SubtitleAppearance { settings.effectiveSubtitleAppearance }

    var editorSubtitleLanguage: String {
        get { settings.preferredSubtitleLanguage }
        set { PlaybackChoices.setSubtitleLanguage(newValue) }
    }

    var subtitleBackupLanguage: String {
        get { settings.preferredSubtitleBackupLanguage }
        set { settings.preferredSubtitleBackupLanguage = newValue }
    }

    var subtitleMode: String {
        get { settings.preferredSubtitleMode }
        set { settings.preferredSubtitleMode = newValue }
    }

    var showsForcedSubtitles: Bool {
        get { settings.showForcedSubtitles }
        set { settings.showForcedSubtitles = newValue }
    }

    var audioLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.audioOptions(current: audioLanguage) }
    var subtitleLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.subtitleOptions(current: editorSubtitleLanguage) }
    var backupLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.backupOptions() }
    var backupApplies: Bool { PlaybackChoices.backupApplies }

    var serverDisplayName: String {
        ServerRegistry.shared.activeServer?.displayName ?? String(localized: "Not configured")
    }

    var serverAddress: String { ServerRegistry.shared.activeServerUrl }

    // MARK: Changes

    func load() async {
        await settings.reloadForCurrentProfile()
        readAll()
    }

    func selectQuality(_ id: String) {
        guard let preset = VividQualityPresets.preset(id: id) else { return }
        settings.setQualityPreset(preset)
        readQuality()
    }

    func setAudioLanguage(_ value: String) {
        settings.setAudioLanguage(value)
        audioLanguage = settings.audioLanguage
    }

    func setAutoPlayNextEpisode(_ value: Bool) {
        settings.setAutoPlayNextEpisode(value)
        autoPlayNextEpisode = settings.autoPlayNextEpisode
    }

    func setNextUpPromptSeconds(_ value: Int) {
        settings.setNextUpPromptSeconds(value)
        nextUpPromptSeconds = settings.nextUpPromptSeconds
    }

    func setAutoSkipIntro(_ value: Bool) {
        settings.setAutoSkipIntro(value)
        autoSkipIntro = settings.autoSkipIntro
    }

    func setAutoSkipCredits(_ value: Bool) {
        settings.setAutoSkipCredits(value)
        autoSkipCredits = settings.autoSkipCredits
    }

    func setBackgroundPlaybackEnabled(_ value: Bool) {
        settings.setBackgroundPlaybackEnabled(value)
        backgroundPlaybackEnabled = settings.backgroundPlaybackEnabled
    }

    func setVolumeBoostEnabled(_ value: Bool) {
        settings.setVolumeBoostEnabled(value)
        volumeBoostEnabled = settings.volumeBoostEnabled
    }

    func setVolumeBoostPercent(_ value: Int) {
        settings.setVolumeBoostPercent(value)
        volumeBoostPercent = settings.volumeBoostPercent
    }

    func setEnhancedDialogueEnabled(_ value: Bool) {
        settings.setEnhancedDialogueEnabled(value)
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
    }

    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await settings.setSubtitleAppearance(appearance)
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    func setUsesCustomSubtitleAppearance(_ enabled: Bool) async {
        await settings.setSubtitleDeviceOverrideEnabled(enabled)
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
    }

    func setFollowsDeviceCaptions(_ enabled: Bool) {
        settings.setSubtitleMatchesSystemAppearance(enabled)
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    /// Restores this device and profile's playback defaults.
    func resetPlaybackSettings() async {
        await settings.resetAllDeviceSettings()
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
        readQuality()
        audioLanguage = settings.audioLanguage
        autoPlayNextEpisode = settings.autoPlayNextEpisode
        nextUpPromptSeconds = settings.nextUpPromptSeconds
        autoSkipIntro = settings.autoSkipIntro
        autoSkipCredits = settings.autoSkipCredits
        backgroundPlaybackEnabled = settings.backgroundPlaybackEnabled
        volumeBoostEnabled = settings.volumeBoostEnabled
        volumeBoostPercent = settings.volumeBoostPercent
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
    }

    private func readQuality() {
        qualityPresetID = PlaybackChoices.selectablePresetID(settings)
        qualityLabel = settings.preferredQualityLabel
    }

    private func readAll() {
        readQuality()
        audioLanguage = settings.audioLanguage
        autoPlayNextEpisode = settings.autoPlayNextEpisode
        nextUpPromptSeconds = settings.nextUpPromptSeconds
        autoSkipIntro = settings.autoSkipIntro
        autoSkipCredits = settings.autoSkipCredits
        backgroundPlaybackEnabled = settings.backgroundPlaybackEnabled
        volumeBoostEnabled = settings.volumeBoostEnabled
        volumeBoostPercent = settings.volumeBoostPercent
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }
}
#endif

#if os(tvOS)
/// The values the Apple TV Playback and Subtitles panes show, and the
/// changes they make.
@MainActor @Observable
final class TVSettingsViewModel {
    var qualityPresetID: String?
    var qualityLabel: String
    var audioLanguage: String
    var autoPlayNextEpisode: Bool
    var nextUpPromptSeconds: Int
    var autoSkipIntro: Bool
    var autoSkipCredits: Bool
    var volumeBoostEnabled: Bool
    var volumeBoostPercent: Int
    var enhancedDialogueEnabled: Bool
    var subtitleAppearance: SubtitleAppearance
    var usesCustomSubtitleAppearance: Bool
    var followsDeviceCaptions: Bool

    init() {
        let settings = PlayerSettings.shared
        qualityPresetID = PlaybackChoices.selectablePresetID(settings)
        qualityLabel = settings.preferredQualityLabel
        audioLanguage = settings.audioLanguage
        autoPlayNextEpisode = settings.autoPlayNextEpisode
        nextUpPromptSeconds = settings.nextUpPromptSeconds
        autoSkipIntro = settings.autoSkipIntro
        autoSkipCredits = settings.autoSkipCredits
        volumeBoostEnabled = settings.volumeBoostEnabled
        volumeBoostPercent = settings.volumeBoostPercent
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    private var settings: PlayerSettings { .shared }

    // MARK: Read live

    var effectiveSubtitleAppearance: SubtitleAppearance { settings.effectiveSubtitleAppearance }

    var editorSubtitleLanguage: String {
        get { settings.preferredSubtitleLanguage }
        set { PlaybackChoices.setSubtitleLanguage(newValue) }
    }

    var subtitleBackupLanguage: String {
        get { settings.preferredSubtitleBackupLanguage }
        set { settings.preferredSubtitleBackupLanguage = newValue }
    }

    var subtitleMode: String {
        get { settings.preferredSubtitleMode }
        set { settings.preferredSubtitleMode = newValue }
    }

    var showsForcedSubtitles: Bool {
        get { settings.showForcedSubtitles }
        set { settings.showForcedSubtitles = newValue }
    }

    var audioLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.audioOptions(current: audioLanguage) }
    var subtitleLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.subtitleOptions(current: editorSubtitleLanguage) }
    var backupLanguageOptions: [PlaybackLanguageOption] { PlaybackChoices.backupOptions() }
    var backupApplies: Bool { PlaybackChoices.backupApplies }

    var serverDisplayName: String { ServerRegistry.shared.activeServer?.displayName ?? "" }
    var serverAddress: String { ServerRegistry.shared.activeServerUrl }

    // MARK: Changes

    func load() async {
        await settings.reloadForCurrentProfile()
        readAll()
    }

    func selectQuality(_ id: String) {
        guard let preset = VividQualityPresets.preset(id: id) else { return }
        settings.setQualityPreset(preset)
        readQuality()
    }

    func setAudioLanguage(_ value: String) {
        settings.setAudioLanguage(value)
        audioLanguage = settings.audioLanguage
    }

    func setAutoPlayNextEpisode(_ value: Bool) {
        settings.setAutoPlayNextEpisode(value)
        autoPlayNextEpisode = settings.autoPlayNextEpisode
    }

    func setNextUpPromptSeconds(_ value: Int) {
        settings.setNextUpPromptSeconds(value)
        nextUpPromptSeconds = settings.nextUpPromptSeconds
    }

    func setAutoSkipIntro(_ value: Bool) {
        settings.setAutoSkipIntro(value)
        autoSkipIntro = settings.autoSkipIntro
    }

    func setAutoSkipCredits(_ value: Bool) {
        settings.setAutoSkipCredits(value)
        autoSkipCredits = settings.autoSkipCredits
    }

    func setVolumeBoostEnabled(_ value: Bool) {
        settings.setVolumeBoostEnabled(value)
        volumeBoostEnabled = settings.volumeBoostEnabled
    }

    func setVolumeBoostPercent(_ value: Int) {
        settings.setVolumeBoostPercent(value)
        volumeBoostPercent = settings.volumeBoostPercent
    }

    func setEnhancedDialogueEnabled(_ value: Bool) {
        settings.setEnhancedDialogueEnabled(value)
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
    }

    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        await settings.setSubtitleAppearance(appearance)
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    func setUsesCustomSubtitleAppearance(_ enabled: Bool) async {
        await settings.setSubtitleDeviceOverrideEnabled(enabled)
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
    }

    func setFollowsDeviceCaptions(_ enabled: Bool) {
        settings.setSubtitleMatchesSystemAppearance(enabled)
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }

    /// Puts the custom appearance back to the defaults, which also turns
    /// custom appearance on and following the device off.
    func resetCustomAppearance() async {
        await setSubtitleAppearance(.default)
    }

    private func readQuality() {
        qualityPresetID = PlaybackChoices.selectablePresetID(settings)
        qualityLabel = settings.preferredQualityLabel
    }

    private func readAll() {
        readQuality()
        audioLanguage = settings.audioLanguage
        autoPlayNextEpisode = settings.autoPlayNextEpisode
        nextUpPromptSeconds = settings.nextUpPromptSeconds
        autoSkipIntro = settings.autoSkipIntro
        autoSkipCredits = settings.autoSkipCredits
        volumeBoostEnabled = settings.volumeBoostEnabled
        volumeBoostPercent = settings.volumeBoostPercent
        enhancedDialogueEnabled = settings.enhancedDialogueEnabled
        subtitleAppearance = settings.subtitleAppearance
        usesCustomSubtitleAppearance = settings.subtitleUsesDeviceAppearanceOverride
        followsDeviceCaptions = settings.subtitleMatchesSystemAppearance
    }
}
#endif
