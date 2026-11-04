import AVFoundation
import Foundation
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// How the iOS player handles screen orientation. Saved, so the next session
/// keeps the viewer's choice.
enum PlayerOrientationMode: String {
    case landscapeLocked = "landscapeLocked"
    case rotateFreely = "rotateFreely"

    var isLandscapeLocked: Bool { self == .landscapeLocked }
}

/// How the picture fills the player, as the display layer's video gravity.
enum VideoGravity: String, CaseIterable {
    case fit = "fit"
    case fill = "fill"
    case stretch = "stretch"

    var avGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var label: String {
        switch self {
        case .fit: return String(localized: "Fit", comment: "Video aspect option")
        case .fill: return String(localized: "Fill", comment: "Video aspect option")
        case .stretch: return String(localized: "Stretch", comment: "Video aspect option")
        }
    }
}

/// How far ahead of the playhead the engine reads.
enum BufferAheadMode: String, CaseIterable {
    case automatic = "automatic"
    case seconds20 = "seconds20"
    case seconds30 = "seconds30"

    #if os(tvOS)
    case fiveMinutes, maximum, unlimited
    #endif

    /// Forward buffer size in segments, or nil for the engine's own default.
    var forwardBufferSegments: Int? {
        switch self {
        case .automatic: return nil
        case .seconds20: return 15
        case .seconds30: return 20
        #if os(tvOS)
        case .fiveMinutes: return 75
        case .maximum: return 150
        case .unlimited: return Int.max
        #endif
        }
    }

    var label: String {
        guard let segments = forwardBufferSegments else {
            return String(localized: "Automatic", comment: "Buffer ahead option")
        }
        #if os(tvOS)
        switch self {
        case .seconds20: return String(localized: "1 minute", comment: "Buffer ahead option")
        case .fiveMinutes: return String(localized: "5 minutes", comment: "Buffer ahead option")
        case .maximum: return String(localized: "10 minutes", comment: "Buffer ahead option")
        case .unlimited: return String(localized: "Whole file", comment: "Buffer ahead option")
        default: return String(localized: "\(segments * 4) seconds", comment: "Buffer ahead option")
        }
        #else
        return String(localized: "\(segments * 2) seconds", comment: "Buffer ahead option")
        #endif
    }

    static var explanation: String {
        String(localized: "Lucid buffers ahead automatically, with up to 256 MB ahead and 16 MB behind for seeking. Playback starts before the buffer fills.")
    }
}

/// The player's preferences on this device.
///
/// Everything is local. Values live in `UserDefaults` under keys partitioned
/// by server, profile and device (``currentScopeIdentifier``), falling back to
/// the bare key when there's no active scope. Installed apps already hold
/// values under these keys, so none of them may change. Each property writes
/// itself back when it changes.
@Observable
final class PlayerSettings {
    enum RefreshResult: Equatable {
        case refreshed
    }

    static let shared = PlayerSettings()

    private let defaults: UserDefaults

    // MARK: - Quality

    /// The in-player fallback rung the viewer last chose, kept only while the
    /// stored quality pair still matches it.
    private var fallbackModeID: String? = nil {
        didSet { storeOrRemove(fallbackModeID, Keys.fallbackMode) }
    }

    var fallbackMode: PlaybackFallbackMode? {
        guard let id = fallbackModeID, let mode = PlaybackFallbackMode(rawValue: id),
              preferredQualityResolution == mode.resolution,
              maxBitrateKbps == mode.maximumKbps else { return nil }
        return mode
    }

    /// The resolution half of the quality preference, a member of the
    /// contract's `playback.preferred_quality` enum.
    ///
    /// The stored pair (this and ``maxBitrateKbps``) is the source of truth.
    /// A compound tier id isn't stored because ``VividQualityPresets`` and
    /// ``ApplePlaybackQuality`` both spell a rung `1080p-high` and mean
    /// different bitrates by it (10 and 20 Mbps). Each table reads the pair
    /// in its own terms instead.
    var preferredQualityResolution: String = "auto" {
        didSet { store(preferredQualityResolution, Keys.preferredQuality) }
    }

    /// The bandwidth half of the quality preference; nil is uncapped. Uncapped
    /// is stored as no value, as it is on the wire.
    var maxBitrateKbps: Int? = nil {
        didSet { storeOrRemove(maxBitrateKbps, Keys.maxBitrateKbps) }
    }

    /// The stored pair as an ``ApplePlaybackQuality`` id, the rung playback
    /// asks for. Derived so a pair saved by a client with a different ladder
    /// still resolves to a rung this one can request (see AppleQualityAxes.swift).
    var preferredQuality: String {
        if let fallbackMode { return fallbackMode.rawValue }
        return AppleQualityAxes.join(resolution: preferredQualityResolution, bitrateKbps: maxBitrateKbps)
    }

    /// The shared preset matching the stored pair, or nil when no preset
    /// covers it. Settings then describes the pair rather than snapping to a
    /// nearby preset.
    var currentQualityPreset: VividQualityPreset? {
        if let fallbackMode { return fallbackMode.preset }
        return VividQualityPresets.preset(resolution: preferredQualityResolution, bitrateKbps: maxBitrateKbps)
    }

    /// A label for the stored pair, preset or not.
    var preferredQualityLabel: String {
        if let fallbackMode { return fallbackMode.option.labelWithBitrate }
        return VividQualityPresets.describe(resolution: preferredQualityResolution, bitrateKbps: maxBitrateKbps)
    }

    // MARK: - Audio and subtitle choice

    var audioLanguage: String = "" {
        didSet { store(audioLanguage, Keys.audioLanguage) }
    }

    var preferredSubtitleLanguage: String = PlaybackPrefSentinel.none {
        didSet { store(preferredSubtitleLanguage, Keys.subtitleLanguage) }
    }

    /// Used only when a title has no subtitles in `preferredSubtitleLanguage`.
    var preferredSubtitleBackupLanguage: String = PlaybackPrefSentinel.none {
        didSet { store(preferredSubtitleBackupLanguage, Keys.subtitleBackupLanguage) }
    }

    var preferredSubtitleMode: String = "auto" {
        didSet { store(preferredSubtitleMode, Keys.subtitleMode) }
    }

    var showForcedSubtitles: Bool = true {
        didSet { store(showForcedSubtitles, Keys.subtitleForced) }
    }

    // MARK: - Skipping and Next Up

    /// IntroDB and TheIntroDB marker lookups. Saved under
    /// ``VividSkipSource/defaultsKey`` as `introdb` or `off`.
    var introDBEnabled: Bool = true {
        didSet { defaults.set(introDBEnabled ? "introdb" : "off", forKey: VividSkipSource.defaultsKey) }
    }

    var autoSkipIntro: Bool = false {
        didSet { store(autoSkipIntro, Keys.autoSkipIntro) }
    }

    var autoSkipCredits: Bool = false {
        didSet { store(autoSkipCredits, Keys.autoSkipCredits) }
    }

    var autoPlayNextEpisode: Bool = true {
        didSet { store(autoPlayNextEpisode, Keys.autoPlayNextEpisode) }
    }

    /// Blur the still and scramble the title and overview of episodes after
    /// the viewer's current position. See `EpisodeSpoilerPolicy`.
    var hideFutureEpisodeSpoilers: Bool = false {
        didSet { store(hideFutureEpisodeSpoilers, Keys.hideFutureEpisodeSpoilers) }
    }

    var nextUpPromptSeconds: Int = 30 {
        didSet { store(nextUpPromptSeconds, Keys.nextUpPromptSeconds) }
    }

    // MARK: - Engine and sound

    /// Whether video keeps playing as the app leaves the foreground (Picture
    /// in Picture and background audio on iOS, the PiP keepalive on tvOS).
    /// Off tears the session down when the app is backgrounded. A habit of
    /// this device, so it's never synced.
    var backgroundPlaybackEnabled: Bool = true {
        didSet { store(backgroundPlaybackEnabled, Keys.backgroundPlaybackEnabled) }
    }

    var preferLosslessAudio: Bool = false {
        didSet { store(preferLosslessAudio, Keys.preferLosslessAudio) }
    }

    /// How far ahead Vivid may buffer. Never synced.
    var bufferAhead: BufferAheadMode = .automatic {
        didSet { store(bufferAhead.rawValue, Keys.bufferAhead) }
    }

    /// Volume Boost. Off plays at the standard level and keeps
    /// ``volumeBoostPercent``, so turning it back on restores the level.
    var volumeBoostEnabled: Bool = false {
        didSet { store(volumeBoostEnabled, Keys.volumeBoostEnabled) }
    }

    /// The Volume Boost level, one of ``VividAudioEnhancement/boostLevels``.
    var volumeBoostPercent: Int = VividAudioEnhancement.defaultBoostLevel {
        didSet { store(volumeBoostPercent, Keys.volumeBoostPercent) }
    }

    /// Enhanced Dialogue, which lowers music and effects so voices are easier
    /// to hear.
    var enhancedDialogueEnabled: Bool = false {
        didSet { store(enhancedDialogueEnabled, Keys.enhancedDialogueEnabled) }
    }

    /// What the player applies to the next load.
    var audioEnhancement: VividAudioEnhancement {
        VividAudioEnhancement(
            boostPercent: volumeBoostEnabled ? volumeBoostPercent : 100,
            enhancedDialogue: enhancedDialogueEnabled
        )
    }

    var playbackSpeed: Double = 1.0 {
        didSet { store(playbackSpeed, Keys.playbackSpeed) }
    }

    var videoGravity: VideoGravity = .fit {
        didSet { store(videoGravity.rawValue, Keys.videoGravity) }
    }

    var playerOrientationMode: PlayerOrientationMode = .landscapeLocked {
        didSet { store(playerOrientationMode.rawValue, Keys.playerOrientationMode) }
    }

    // MARK: - Subtitle appearance

    /// Saved as the sanitised appearance's JSON.
    var subtitleAppearance: SubtitleAppearance = .default {
        didSet { store(subtitleAppearance.sanitized().jsonString, Keys.subtitleAppearance) }
    }

    var subtitleUsesDeviceAppearanceOverride: Bool = false {
        didSet { store(subtitleUsesDeviceAppearanceOverride, Keys.subtitleUsesDeviceAppearanceOverride) }
    }

    /// When true, subtitles follow the system's Subtitles & Captioning
    /// settings instead of the Vivid appearance. About this device's
    /// accessibility set-up, so it's never synced.
    var subtitleMatchesSystemAppearance: Bool = false {
        didSet { store(subtitleMatchesSystemAppearance, Keys.subtitleMatchesSystemAppearance) }
    }

    /// The system caption settings as last read. Read again when
    /// MediaAccessibility says they changed and when the app becomes active.
    var subtitleSystemAppearance: SubtitleAppearance = SystemCaptionAppearance.current()
    var subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()

    /// The appearance the player draws with.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        if subtitleMatchesSystemAppearance { return subtitleSystemAppearance }
        return subtitleUsesDeviceAppearanceOverride ? subtitleAppearance : .default
    }

    var subtitleSyncMs: Int = 0 {
        didSet { store(subtitleSyncMs, Keys.subtitleSyncMs) }
    }

    // MARK: - Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Registered under the bare keys, so they answer only when there's no
        // active scope. `maxBitrateKbps` has none: a registered value would
        // make uncapped look like a cap.
        defaults.register(defaults: [
            Keys.preferredQuality: "auto",
            Keys.audioLanguage: "",
            Keys.autoSkipIntro: false,
            Keys.autoSkipCredits: false,
            Keys.backgroundPlaybackEnabled: true,
            Keys.bufferAhead: BufferAheadMode.automatic.rawValue,
            Keys.volumeBoostEnabled: false,
            Keys.volumeBoostPercent: VividAudioEnhancement.defaultBoostLevel,
            Keys.enhancedDialogueEnabled: false,
            Keys.subtitleAppearance: SubtitleAppearance.default.jsonString,
            Keys.subtitleUsesDeviceAppearanceOverride: false,
            Keys.subtitleMatchesSystemAppearance: false,
            Keys.subtitleSyncMs: 0,
            Keys.playbackSpeed: 1.0,
            Keys.videoGravity: VideoGravity.fit.rawValue,
            Keys.playerOrientationMode: PlayerOrientationMode.landscapeLocked.rawValue,
            Keys.autoPlayNextEpisode: true,
            Keys.hideFutureEpisodeSpoilers: false,
            Keys.nextUpPromptSeconds: 30,
        ])
        loadSavedSettings()

        NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSubtitleSystemAppearance()
        }
        #if os(iOS) || os(tvOS)
        // Caption settings only change outside Vivid (Accessibility, or an
        // AVKit app's subtitle menu on Apple TV), so read them again on the
        // way back in rather than relying on the notification alone.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSubtitleSystemAppearance()
        }
        #endif
    }

    /// Read the system caption settings again. Assigns only real changes, so
    /// returning to the app doesn't redraw every view that reads them.
    func refreshSubtitleSystemAppearance() {
        let appearance = SystemCaptionAppearance.current()
        if appearance != subtitleSystemAppearance { subtitleSystemAppearance = appearance }
        let selection = SystemCaptionSelectionPreferences.current()
        if selection != subtitleSystemSelectionPreferences { subtitleSystemSelectionPreferences = selection }
    }

    /// Load the new scope's settings after an account or profile change.
    @discardableResult
    @MainActor
    func reloadForCurrentProfile() async -> RefreshResult {
        loadSavedSettings()
        return .refreshed
    }

    // MARK: - Setters

    /// Set the quality from an ``ApplePlaybackQuality`` id, as the in-player
    /// switcher does. The id is split into the contract's two axes before
    /// it's stored (see AppleQualityAxes.swift).
    func setPreferredQuality(_ value: String) {
        let axes = AppleQualityAxes.split(ApplePlaybackQuality.normalizeStoredId(value))
        setQualityAxes(resolution: axes.resolution, bitrateKbps: axes.bitrateKbps)
        fallbackModeID = PlaybackFallbackMode(rawValue: value)?.rawValue
    }

    /// Set the quality from a shared preset, as Settings does.
    func setQualityPreset(_ preset: VividQualityPreset) {
        setQualityAxes(resolution: preset.resolution, bitrateKbps: preset.bitrateKbps)
        fallbackModeID = PlaybackFallbackMode(rawValue: preset.id)?.rawValue
    }

    /// Both axes are always written, so a stale cap can't keep throttling a
    /// tier the viewer just widened.
    private func setQualityAxes(resolution: String, bitrateKbps: Int?) {
        fallbackModeID = nil
        preferredQualityResolution = VividQualityPresets.normalizeResolution(resolution)
        maxBitrateKbps = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
    }

    func setAudioLanguage(_ value: String) { audioLanguage = value }
    func setAutoSkipIntro(_ enabled: Bool) { autoSkipIntro = enabled }
    func setAutoSkipCredits(_ enabled: Bool) { autoSkipCredits = enabled }
    func setAutoPlayNextEpisode(_ enabled: Bool) { autoPlayNextEpisode = enabled }
    func setNextUpPromptSeconds(_ seconds: Int) { nextUpPromptSeconds = Self.clampNextUpPromptSeconds(seconds) }
    func setBackgroundPlaybackEnabled(_ enabled: Bool) { backgroundPlaybackEnabled = enabled }
    func setBufferAhead(_ mode: BufferAheadMode) { bufferAhead = mode }
    func setVolumeBoostEnabled(_ enabled: Bool) { volumeBoostEnabled = enabled }
    /// Snapped to an offered level.
    func setVolumeBoostPercent(_ percent: Int) { volumeBoostPercent = VividAudioEnhancement.boostLevel(percent) }
    func setEnhancedDialogueEnabled(_ enabled: Bool) { enhancedDialogueEnabled = enabled }
    func setPlaybackSpeed(_ rate: Double) { playbackSpeed = Self.clampPlaybackSpeed(rate) }
    func setVideoGravity(_ gravity: VideoGravity) { videoGravity = gravity }
    func setPlayerOrientationMode(_ mode: PlayerOrientationMode) { playerOrientationMode = mode }
    func setSubtitleSyncMs(_ milliseconds: Int) { subtitleSyncMs = max(-10000, min(milliseconds, 10000)) }

    /// A manual edit takes over from the system appearance.
    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        subtitleAppearance = appearance.sanitized()
        subtitleUsesDeviceAppearanceOverride = true
        subtitleMatchesSystemAppearance = false
    }

    /// Follow the system caption settings, or stop. The saved Vivid
    /// appearance is untouched, so switching back restores it.
    func setSubtitleMatchesSystemAppearance(_ enabled: Bool) {
        guard enabled != subtitleMatchesSystemAppearance else { return }
        if enabled {
            subtitleSystemAppearance = SystemCaptionAppearance.current()
            subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()
        }
        subtitleMatchesSystemAppearance = enabled
    }

    @MainActor
    func setSubtitleDeviceOverrideEnabled(_ enabled: Bool) async {
        subtitleUsesDeviceAppearanceOverride = enabled
    }

    @MainActor
    func resetAllDeviceSettings() async {
        fallbackModeID = nil
        introDBEnabled = true
        backgroundPlaybackEnabled = true
        preferLosslessAudio = false
        bufferAhead = .automatic
        volumeBoostEnabled = false
        volumeBoostPercent = VividAudioEnhancement.defaultBoostLevel
        enhancedDialogueEnabled = false
        subtitleMatchesSystemAppearance = false
        writeResetValues(scopeID: Self.currentScopeIdentifier)
        loadSavedSettings()
        preferredSubtitleLanguage = PlaybackPrefSentinel.none
        preferredSubtitleBackupLanguage = PlaybackPrefSentinel.none
        preferredSubtitleMode = "auto"
        showForcedSubtitles = true
    }

    // MARK: - Scope and storage

    /// The base64 of `server|profile|device` this device's settings belong
    /// to, or nil when any part is missing. Existing installs keep their
    /// settings under this partition, so its format can't change.
    static var currentScopeIdentifier: String? {
        let serverURL = ServerRegistry.shared.activeServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = AuthService.shared.profileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceID = AppleDeviceIdentity.current.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !profileID.isEmpty, !deviceID.isEmpty else { return nil }
        return Data("\(serverURL)|\(profileID)|\(deviceID)".utf8).base64EncodedString()
    }

    /// Read every saved value for the current scope. Each assignment writes
    /// itself back, which also finishes a legacy key's migration.
    private func loadSavedSettings() {
        fallbackModeID = defaults.string(forKey: Self.cacheKey(Keys.fallbackMode))
        preferredSubtitleLanguage = savedString(Keys.subtitleLanguage) ?? PlaybackPrefSentinel.none
        preferredSubtitleBackupLanguage = savedString(Keys.subtitleBackupLanguage) ?? PlaybackPrefSentinel.none
        preferredSubtitleMode = savedString(Keys.subtitleMode) ?? "auto"
        showForcedSubtitles = savedBool(Keys.subtitleForced, default: true)

        // Builds that stored a tier id wrote `1080p-high` and the like into
        // this key. Normalising keeps the resolution; the separate bitrate key
        // holds any cap.
        preferredQualityResolution = VividQualityPresets.normalizeResolution(savedString(Keys.preferredQuality))
        maxBitrateKbps = savedMaxBitrateKbps()
        audioLanguage = savedString(Keys.audioLanguage) ?? ""
        introDBEnabled = (defaults.string(forKey: VividSkipSource.defaultsKey) ?? "introdb") == "introdb"
        autoSkipIntro = savedBool(Keys.autoSkipIntro, default: false)
        autoSkipCredits = savedBool(Keys.autoSkipCredits, default: false)
        autoPlayNextEpisode = savedBool(Keys.autoPlayNextEpisode, legacyKey: Keys.legacyAutoPlayNextEpisode, default: true)
        hideFutureEpisodeSpoilers = savedBool(Keys.hideFutureEpisodeSpoilers, default: false)
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(savedInt(Keys.nextUpPromptSeconds, default: 30))
        backgroundPlaybackEnabled = savedBool(Keys.backgroundPlaybackEnabled, default: true)
        preferLosslessAudio = defaults.bool(forKey: Self.cacheKey(Keys.preferLosslessAudio))
        bufferAhead = BufferAheadMode(rawValue: savedString(Keys.bufferAhead) ?? "") ?? .automatic
        volumeBoostEnabled = savedBool(Keys.volumeBoostEnabled, default: false)
        volumeBoostPercent = VividAudioEnhancement.boostLevel(
            savedInt(Keys.volumeBoostPercent, default: VividAudioEnhancement.defaultBoostLevel)
        )
        enhancedDialogueEnabled = savedBool(Keys.enhancedDialogueEnabled, default: false)
        playbackSpeed = Self.clampPlaybackSpeed(savedDouble(Keys.playbackSpeed, default: 1.0))
        subtitleSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))
        videoGravity = VideoGravity(rawValue: savedString(Keys.videoGravity) ?? "") ?? .fit
        playerOrientationMode = PlayerOrientationMode(rawValue: savedString(Keys.playerOrientationMode) ?? "")
            ?? .landscapeLocked
        subtitleUsesDeviceAppearanceOverride = savedBool(Keys.subtitleUsesDeviceAppearanceOverride, default: false)
        subtitleMatchesSystemAppearance = savedBool(Keys.subtitleMatchesSystemAppearance, default: false)
        subtitleAppearance = SubtitleAppearance.decode(from: savedString(Keys.subtitleAppearance))
    }

    /// The reset state for one scope. `maxBitrateKbps` is removed, as
    /// uncapped is stored as no value.
    private func writeResetValues(scopeID: String?) {
        func key(_ base: String) -> String { Self.cacheKey(base, scopeID: scopeID) }
        defaults.set("auto", forKey: key(Keys.preferredQuality))
        defaults.removeObject(forKey: key(Keys.maxBitrateKbps))
        defaults.set("", forKey: key(Keys.audioLanguage))
        defaults.set(false, forKey: key(Keys.autoSkipIntro))
        defaults.set(false, forKey: key(Keys.autoSkipCredits))
        defaults.set(true, forKey: key(Keys.autoPlayNextEpisode))
        defaults.set(false, forKey: key(Keys.hideFutureEpisodeSpoilers))
        defaults.set(30, forKey: key(Keys.nextUpPromptSeconds))
        defaults.set(1.0, forKey: key(Keys.playbackSpeed))
        defaults.set(0, forKey: key(Keys.subtitleSyncMs))
        defaults.set(VideoGravity.fit.rawValue, forKey: key(Keys.videoGravity))
        defaults.set(PlayerOrientationMode.landscapeLocked.rawValue, forKey: key(Keys.playerOrientationMode))
        defaults.set(SubtitleAppearance.default.jsonString, forKey: key(Keys.subtitleAppearance))
        defaults.set(false, forKey: key(Keys.subtitleUsesDeviceAppearanceOverride))
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: Self.cacheKey(key))
    }

    private func storeOrRemove(_ value: Any?, _ key: String) {
        if let value {
            defaults.set(value, forKey: Self.cacheKey(key))
        } else {
            defaults.removeObject(forKey: Self.cacheKey(key))
        }
    }

    private func savedString(_ key: String) -> String? {
        defaults.string(forKey: Self.cacheKey(key))
    }

    /// A saved Bool, or a legacy unscoped one copied into the scoped key. On
    /// iOS the legacy value is used only when the scope matches the recorded
    /// migration owner.
    private func savedBool(_ key: String, legacyKey: String? = nil, default defaultValue: Bool) -> Bool {
        let scopedKey = Self.cacheKey(key)
        if defaults.object(forKey: scopedKey) != nil {
            return defaults.bool(forKey: scopedKey)
        }
        #if os(iOS)
        if Self.currentScopeIdentifier != defaults.string(forKey: Keys.legacyMigrationOwner) { return defaultValue }
        #endif
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let legacyValue = defaults.bool(forKey: legacyKey)
            defaults.set(legacyValue, forKey: scopedKey)
            return legacyValue
        }
        return defaultValue
    }

    private func savedInt(_ key: String, default defaultValue: Int) -> Int {
        let scopedKey = Self.cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else { return defaultValue }
        return defaults.integer(forKey: scopedKey)
    }

    private func savedDouble(_ key: String, default defaultValue: Double) -> Double {
        let scopedKey = Self.cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else { return defaultValue }
        return defaults.double(forKey: scopedKey)
    }

    /// Read through `object(forKey:)`, because `integer(forKey:)` answers 0
    /// for a missing key and 0 isn't a cap.
    private func savedMaxBitrateKbps() -> Int? {
        let key = Self.cacheKey(Keys.maxBitrateKbps)
        guard defaults.object(forKey: key) != nil else { return nil }
        let stored = defaults.integer(forKey: key)
        return stored > 0 ? stored : nil
    }

    private static func cacheKey(_ baseKey: String) -> String {
        cacheKey(baseKey, scopeID: currentScopeIdentifier)
    }

    private static func cacheKey(_ baseKey: String, scopeID: String?) -> String {
        guard let scopeID else { return baseKey }
        return "player.serverDeviceSettings.\(scopeID).\(baseKey)"
    }

    private static func clampNextUpPromptSeconds(_ seconds: Int) -> Int {
        max(0, min(seconds, 120))
    }

    /// Clamp to the contract's range and step for `player.playback_speed`
    /// (0.25 to 3.0 in steps of 0.05), so the value shown is one the server
    /// accepts. Rounded to hundredths afterwards because 0.05 isn't exact in
    /// binary (0.25 + 30 * 0.05 is 1.7500000000000002).
    private static func clampPlaybackSpeed(_ rate: Double) -> Double {
        let bounded = max(0.25, min(rate, 3.0))
        let steps = ((bounded - 0.25) / 0.05).rounded()
        let aligned = ((0.25 + steps * 0.05) * 100).rounded() / 100
        return min(3.0, max(0.25, aligned))
    }

    private enum Keys {
        static let fallbackMode = "vivid.quality.fallbackMode"
        static let subtitleLanguage = "vivid.subtitle.language"
        static let subtitleBackupLanguage = "vivid.subtitle.backupLanguage"
        static let subtitleMode = "vivid.subtitle.mode"
        static let subtitleForced = "vivid.subtitle.forced"
        static let preferredQuality = "preferredQuality"
        static let maxBitrateKbps = "playback.maxBitrateKbps"
        static let audioLanguage = "preferredAudioLanguage"
        static let autoSkipIntro = "skipIntros"
        static let autoSkipCredits = "skipCredits"
        static let backgroundPlaybackEnabled = "player.backgroundPlaybackEnabled"
        static let preferLosslessAudio = "player.preferLosslessAudio"
        static let bufferAhead = "player.bufferAhead"
        static let volumeBoostEnabled = "player.volumeBoostEnabled"
        static let volumeBoostPercent = "player.volumeBoostPercent"
        static let enhancedDialogueEnabled = "player.enhancedDialogueEnabled"
        static let subtitleAppearance = "player.subtitleAppearance"
        static let subtitleUsesDeviceAppearanceOverride = "player.subtitleUsesDeviceAppearanceOverride"
        static let subtitleMatchesSystemAppearance = "player.subtitleMatchesSystemAppearance"
        static let subtitleSyncMs = "player.subtitleSyncMs"
        static let playbackSpeed = "player.playbackSpeed"
        static let videoGravity = "player.videoGravity"
        static let playerOrientationMode = "player.playerOrientationMode"
        static let autoPlayNextEpisode = "autoPlayNext"
        static let legacyAutoPlayNextEpisode = "player.autoPlayNextEpisode"
        static let legacyMigrationOwner = "player.legacyMigrationOwner"
        static let hideFutureEpisodeSpoilers = "player.hideFutureEpisodeSpoilers"
        static let nextUpPromptSeconds = "player.nextUpPromptSeconds"
    }
}

/// Vivid looks up skip markers itself, whichever server is connected.
enum VividSkipSource {
    static var defaultsKey: String {
        #if os(iOS)
        if let scope = PlayerSettings.currentScopeIdentifier { return "vivid.playback.skipSource.\(scope)" }
        #endif
        return "vivid.playback.skipSource"
    }

    static var isEnabled: Bool { PlayerSettings.shared.introDBEnabled }
}

// Everything from here to the end of the file is compiled on its own, with a
// stand-in `TimeRange`, by scripts/ci/check-introdb-client.sh.

/// Anonymous IntroDB and TheIntroDB marker lookups, cached for an hour.
actor VividIntroDBClient {
    static let shared = VividIntroDBClient()

    struct Episode: Hashable, Sendable {
        let imdbID: String
        let season: Int
        let episode: Int
        /// Nil unless positive.
        let tmdbID: Int?

        init(imdbID: String, season: Int, episode: Int, tmdbID: Int? = nil) {
            self.imdbID = imdbID
            self.season = season
            self.episode = episode
            self.tmdbID = tmdbID.flatMap { $0 > 0 ? $0 : nil }
        }

        /// TheIntroDB's lookup ID: the TMDB ID, otherwise a valid IMDb ID.
        var theIntroDBIdentifier: URLQueryItem? {
            if let tmdbID, tmdbID > 0 {
                return URLQueryItem(name: "tmdb_id", value: String(tmdbID))
            }
            guard VividIntroDBClient.isIMDbID(imdbID) else { return nil }
            return URLQueryItem(name: "imdb_id", value: imdbID)
        }
    }

    /// A marker in milliseconds. A nil end runs to the end of the media,
    /// which only TheIntroDB's credits produce.
    struct Segment: Decodable, Sendable {
        let start_ms: Double
        let end_ms: Double?

        init(start_ms: Double, end_ms: Double?) {
            self.start_ms = start_ms
            self.end_ms = end_ms
        }

        init?(range: TimeRange?) {
            guard let range, range.start.isFinite, range.end.isFinite,
                  range.start >= 0, range.end > range.start,
                  (range.start * 1000).isFinite, (range.end * 1000).isFinite else { return nil }
            self.init(start_ms: range.start * 1000, end_ms: range.end * 1000)
        }

        private enum CodingKeys: String, CodingKey { case start_ms, end_ms }

        /// IntroDB always sends an end, so decoding requires one.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            start_ms = try values.decode(Double.self, forKey: .start_ms)
            end_ms = try values.decode(Double.self, forKey: .end_ms)
        }

        /// The marker in seconds, clamped to the duration, or nil when it
        /// isn't a usable range within it (an end up to a second past the
        /// duration is allowed).
        func range(duration: Double) -> TimeRange? {
            let start = start_ms / 1000
            let end = end_ms.map { $0 / 1000 } ?? duration
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  duration.isFinite, duration > 0, end <= duration + 1, start < duration else { return nil }
            return TimeRange(start: start, end: min(end, duration))
        }
    }

    /// One episode's markers, in IntroDB's response shape.
    struct Segments: Decodable, Sendable {
        let imdb_id: String
        let season: Int
        let episode: Int
        let intro: Segment?
        let outro: Segment?
        var recap: Segment? = nil
        var tmdb_id: Int? = nil

        /// These markers with any missing kind taken from `fallback`, when it
        /// is for the same series (by IMDb or TMDB ID, with neither ID
        /// contradicting) and the same episode.
        func fillingMissing(from fallback: Segments?) -> Segments {
            guard let fallback,
                  (!imdb_id.isEmpty && fallback.imdb_id == imdb_id) ||
                    (tmdb_id != nil && fallback.tmdb_id == tmdb_id),
                  imdb_id.isEmpty || fallback.imdb_id.isEmpty || fallback.imdb_id == imdb_id,
                  tmdb_id == nil || fallback.tmdb_id == nil || fallback.tmdb_id == tmdb_id,
                  fallback.season == season, fallback.episode == episode else { return self }
            return Segments(imdb_id: imdb_id, season: season, episode: episode,
                            intro: intro ?? fallback.intro, outro: outro ?? fallback.outro,
                            recap: recap ?? fallback.recap, tmdb_id: tmdb_id ?? fallback.tmdb_id)
        }
    }

    /// TheIntroDB's v4 `/media` response. v4 keys every response by TVDB and
    /// no longer returns `tmdb_id`.
    struct TheIntroDBResponse: Decodable, Sendable {
        let tvdb_id: Int?
        let season: Int?
        let episode: Int?
        let intro: [Timestamp]?
        let credits: [Timestamp]?
        let recap: [Timestamp]?

        struct Timestamp: Decodable, Sendable {
            let start_ms: Double?
            let end_ms: Double?

            /// A null start means zero, except for credits, which need one.
            /// Only credits may have a null end.
            func segment(credits: Bool) -> Segment? {
                guard !credits || start_ms != nil else { return nil }
                let start = start_ms ?? 0
                guard start.isFinite, start >= 0 else { return nil }
                if let end = end_ms {
                    guard end.isFinite, end > start else { return nil }
                } else if !credits {
                    return nil
                }
                return Segment(start_ms: start, end_ms: end_ms)
            }
        }

        /// The earliest valid segment of each kind. Vivid shows one prompt
        /// per kind and never joins ranges across the scenes between them.
        func segments(for episode: Episode) -> Segments {
            func first(_ timestamps: [Timestamp]?, credits: Bool) -> Segment? {
                timestamps?.compactMap { $0.segment(credits: credits) }
                    .sorted { $0.start_ms < $1.start_ms }.first
            }
            return Segments(imdb_id: episode.imdbID, season: episode.season, episode: episode.episode,
                            intro: first(intro, credits: false), outro: first(credits, credits: true),
                            recap: first(recap, credits: false), tmdb_id: episode.tmdbID)
        }
    }

    private static let cacheLifetime: TimeInterval = 3600
    private static let cacheLimit = 200
    private static let maximumResponseBytes = 100_000

    private var theIntroDBCache: [Episode: (Date, Segments)] = [:]
    private var cache: [Episode: (Date, Segments)] = [:]
    /// An ephemeral session of its own, so no media server token or cookie
    /// is ever attached.
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// TheIntroDB markers for an episode. TMDB and IMDb IDs are resolved
    /// with that provider's episode numbering, so no TVDB episode-order
    /// mapping is sent.
    func theIntroDBSegments(for episode: Episode) async throws -> Segments? {
        guard let identifier = episode.theIntroDBIdentifier,
              episode.season > 0, episode.episode > 0 else { return nil }
        if let cached = Self.fresh(theIntroDBCache[episode]) { return cached }
        let query = [identifier,
                     URLQueryItem(name: "season", value: String(episode.season)),
                     URLQueryItem(name: "episode", value: String(episode.episode))]
        guard let data = try await fetch("https://api.theintrodb.org/v4/media", query: query) else { return nil }
        let response = try JSONDecoder().decode(TheIntroDBResponse.self, from: data)
        // With no tmdb_id to compare, the series rests on TheIntroDB resolving
        // the ID sent. A TVDB ID and the echoed episode are required, which
        // also rejects the version and episode-list shapes.
        guard let tvdbID = response.tvdb_id, tvdbID > 0,
              response.season == episode.season,
              response.episode == episode.episode else { return nil }
        let result = response.segments(for: episode)
        Self.insert(result, for: episode, into: &theIntroDBCache)
        return result
    }

    /// IntroDB markers for an episode, which needs a valid IMDb ID.
    func introDBSegments(for episode: Episode) async throws -> Segments? {
        guard Self.isIMDbID(episode.imdbID), episode.season > 0, episode.episode > 0 else { return nil }
        if let cached = Self.fresh(cache[episode]) { return cached }
        let query = [URLQueryItem(name: "imdb_id", value: episode.imdbID),
                     URLQueryItem(name: "season", value: String(episode.season)),
                     URLQueryItem(name: "episode", value: String(episode.episode))]
        guard let data = try await fetch("https://api.introdb.app/segments", query: query) else { return nil }
        let result = try JSONDecoder().decode(Segments.self, from: data)
        guard result.imdb_id == episode.imdbID, result.season == episode.season,
              result.episode == episode.episode else { return nil }
        Self.insert(result, for: episode, into: &cache)
        return result
    }

    /// The body of a 200 response under the size limit, or nil for any other
    /// answer (404, rate limiting and so on). Public requests, with no API
    /// key, server credentials or shared cookies.
    private func fetch(_ endpoint: String, query: [URLQueryItem]) async throws -> Data? {
        var components = URLComponents(string: endpoint)!
        components.queryItems = query
        let (data, response) = try await session.data(from: components.url!)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, data.count < Self.maximumResponseBytes else { return nil }
        return data
    }

    private static func isIMDbID(_ value: String) -> Bool {
        value.range(of: "^tt[0-9]{7,8}$", options: .regularExpression) != nil
    }

    private static func fresh(_ entry: (Date, Segments)?) -> Segments? {
        guard let entry, Date().timeIntervalSince(entry.0) < cacheLifetime else { return nil }
        return entry.1
    }

    private static func insert(_ segments: Segments, for episode: Episode, into cache: inout [Episode: (Date, Segments)]) {
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[episode] = (Date(), segments)
    }
}

/// Vivid's own watched rule, applied on top of each server's resume rules.
/// Partial progress has no Vivid threshold: the server decides what to keep.
enum PlaybackCompletionPolicy {
    /// Complete at 90% of the duration, at a valid credits marker, or at a
    /// natural end with any progress.
    static func isComplete(position: Double, duration: Double, credits: TimeRange? = nil,
                           endedNaturally: Bool = false) -> Bool {
        guard position.isFinite, position >= 0 else { return false }
        if endedNaturally { return position > 0 }
        guard duration.isFinite, duration > 0 else { return false }
        if position / duration >= 0.9 { return true }
        guard let credits, credits.start.isFinite, credits.end.isFinite,
              credits.start > 0, credits.end > credits.start,
              credits.end <= duration else { return false }
        return position >= credits.start
    }
}
