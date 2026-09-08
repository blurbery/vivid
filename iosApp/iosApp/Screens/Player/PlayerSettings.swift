import AVFoundation
import Foundation
import SwiftUI

/// How the iOS player should manage screen orientation while playback is
/// visible. This is persisted so the next session reuses the user's choice.
enum PlayerOrientationMode: String {
    case landscapeLocked = "landscapeLocked"
    case rotateFreely = "rotateFreely"

    var isLandscapeLocked: Bool {
        self == .landscapeLocked
    }
}

/// How the video frame fills the player bounds. Maps directly to
/// `AVLayerVideoGravity` values on the display layer.
enum VideoGravity: String, CaseIterable {
    case fit = "fit"
    case fill = "fill"
    case stretch = "stretch"

    var avGravity: AVLayerVideoGravity {
        switch self {
        case .fit:     return .resizeAspect
        case .fill:    return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var label: String {
        switch self {
        case .fit:     return "Fit"
        case .fill:    return "Fill"
        case .stretch: return "Stretch"
        }
    }
}

/// VividKit read-ahead targets, expressed in two-second adapter units.
enum BufferAheadMode: String, CaseIterable {
    case automatic = "automatic"
    case seconds10 = "seconds10"
    case seconds20 = "seconds20"
    case seconds30 = "seconds30"

    var forwardBufferSegments: Int? {
        switch self {
        case .automatic: return nil
        case .seconds10: return 5
        case .seconds20: return 10
        case .seconds30: return 15
        }
    }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .seconds10: return "10 seconds"
        case .seconds20: return "20 seconds"
        case .seconds30: return "30 seconds"
        }
    }

    static let explanation = "Automatic buffers about 10 seconds ahead. Playback starts before the target fills, and memory limits can shorten the buffer. Changes apply to the next video; streaming playlists manage their own buffer."
}

@Observable
final class PlayerSettings {
    enum RefreshResult: Equatable {
        case refreshed
    }

    static let shared = PlayerSettings()

    var preferredSubtitleLanguage: String = PlaybackPrefSentinel.none {
        didSet { defaults.set(preferredSubtitleLanguage, forKey: Self.cacheKey("vivid.subtitle.language")) }
    }
    var preferredSubtitleMode: String = "auto" {
        didSet { defaults.set(preferredSubtitleMode, forKey: Self.cacheKey("vivid.subtitle.mode")) }
    }
    var showForcedSubtitles: Bool = true {
        didSet { defaults.set(showForcedSubtitles, forKey: Self.cacheKey("vivid.subtitle.forced")) }
    }

    /// The resolution half of the quality preference: a member of the
    /// contract's `playback.preferred_quality` enum.
    ///
    /// The stored *pair* — this and ``maxBitrateKbps`` — is the local source of
    /// truth. Storing a compound tier id was safe while this client had one
    /// quality table; it stopped being safe when the settings picker adopted
    /// the cross-client presets, because both tables spell a rung `1080p-high`
    /// and mean different bitrates by it (10 Mbps in ``VividQualityPresets``,
    /// 20 Mbps in ``ApplePlaybackQuality``). A stored id would silently change
    /// meaning depending on which table read it back; a stored pair says what
    /// it means and each table interprets it rather than owning it.
    var preferredQualityResolution: String {
        didSet {
            defaults.set(preferredQualityResolution, forKey: Self.cacheKey(Keys.preferredQuality))
        }
    }

    /// The bandwidth half of the quality preference; nil is uncapped.
    var maxBitrateKbps: Int? {
        didSet {
            let key = Self.cacheKey(Keys.maxBitrateKbps)
            // Removed rather than stored as a sentinel, so "uncapped" is the
            // absence of a value locally exactly as it is on the wire.
            if let maxBitrateKbps {
                defaults.set(maxBitrateKbps, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The stored pair as an id from this client's in-player ladder.
    ///
    /// Read-only, and derived rather than stored: playback's ~12 call sites ask
    /// "which transcode rung" and have always been answered with an
    /// ``ApplePlaybackQuality`` id, so they keep working unchanged. The
    /// derivation honours both caps, which is why a pair authored on web or
    /// Android — whose ladders differ from this one — still resolves to a rung
    /// this client can actually request. See AppleQualityAxes.swift.
    var preferredQuality: String {
        AppleQualityAxes.join(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    /// The shared preset the stored pair corresponds to, or nil when the pair
    /// is a combination no preset covers — set through the API, or written by a
    /// client whose ladder has a rung this table does not. The settings picker
    /// shows the pair's own description in that case rather than snapping to a
    /// nearby preset, which would misreport what is stored.
    var currentQualityPreset: VividQualityPreset? {
        VividQualityPresets.preset(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    /// A user-facing label for the stored pair, preset or not.
    var preferredQualityLabel: String {
        VividQualityPresets.describe(
            resolution: preferredQualityResolution,
            bitrateKbps: maxBitrateKbps
        )
    }

    var audioLanguage: String {
        didSet { defaults.set(audioLanguage, forKey: Self.cacheKey(Keys.audioLanguage)) }
    }

    var introDBEnabled: Bool {
        didSet { defaults.set(introDBEnabled ? "introdb" : "off", forKey: VividSkipSource.defaultsKey) }
    }

    var autoSkipIntro: Bool {
        didSet { defaults.set(autoSkipIntro, forKey: Self.cacheKey(Keys.autoSkipIntro)) }
    }

    var autoSkipCredits: Bool {
        didSet { defaults.set(autoSkipCredits, forKey: Self.cacheKey(Keys.autoSkipCredits)) }
    }

    /// Device-local: when true, video playback keeps running as the app leaves
    /// the foreground — Picture in Picture and background audio on iOS, the
    /// PiP keepalive on tvOS. When false the engine tears the session down as
    /// soon as the app is backgrounded, so audio stops with the app.
    ///
    /// Never synced to the server, and deliberately not a contract key: whether
    /// leaving the app should keep a video's audio going is a habit of *this*
    /// device, not a preference that should follow the profile onto a TV.
    /// Default on, which is Vivid's own default.
    var backgroundPlaybackEnabled: Bool {
        didSet {
            defaults.set(
                backgroundPlaybackEnabled,
                forKey: Self.cacheKey(Keys.backgroundPlaybackEnabled)
            )
        }
    }

    /// Device-local: how far ahead of the playhead Vivid may buffer.
    ///
    /// Never synced to the server, and deliberately not a contract key — see
    /// ``BufferAheadMode``. Default ``BufferAheadMode/automatic``, which buffers approximately ten seconds, within the memory limit.
    var bufferAhead: BufferAheadMode {
        didSet {
            defaults.set(bufferAhead.rawValue, forKey: Self.cacheKey(Keys.bufferAhead))
        }
    }

    var subtitleAppearance: SubtitleAppearance {
        didSet {
            let sanitized = subtitleAppearance.sanitized()
            defaults.set(sanitized.jsonString, forKey: Self.cacheKey(Keys.subtitleAppearance))
        }
    }

    var subtitleUsesDeviceAppearanceOverride: Bool {
        didSet {
            defaults.set(
                subtitleUsesDeviceAppearanceOverride,
                forKey: Self.cacheKey(Keys.subtitleUsesDeviceAppearanceOverride)
            )
        }
    }

    /// Device-local: when true, subtitle styling mirrors the system's
    /// Subtitles & Captioning accessibility preferences instead of the
    /// Vivid appearance. Never synced to the server — it is inherently
    /// about *this* device's accessibility configuration.
    var subtitleMatchesSystemAppearance: Bool {
        didSet {
            defaults.set(
                subtitleMatchesSystemAppearance,
                forKey: Self.cacheKey(Keys.subtitleMatchesSystemAppearance)
            )
        }
    }

    /// Latest mapping of the system caption preferences. Refreshed when
    /// MediaAccessibility posts its settings-changed notification.
    var subtitleSystemAppearance: SubtitleAppearance = SystemCaptionAppearance.current()
    var subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()

    /// The appearance the player should actually render with.
    var effectiveSubtitleAppearance: SubtitleAppearance {
        if subtitleMatchesSystemAppearance { return subtitleSystemAppearance }
        return subtitleUsesDeviceAppearanceOverride
            ? subtitleAppearance
            : .default
    }

    var subtitleSyncMs: Int {
        didSet { defaults.set(subtitleSyncMs, forKey: Self.cacheKey(Keys.subtitleSyncMs)) }
    }

    var playbackSpeed: Double {
        didSet { defaults.set(playbackSpeed, forKey: Self.cacheKey(Keys.playbackSpeed)) }
    }

    var videoGravity: VideoGravity {
        didSet { defaults.set(videoGravity.rawValue, forKey: Self.cacheKey(Keys.videoGravity)) }
    }

    var playerOrientationMode: PlayerOrientationMode {
        didSet { defaults.set(playerOrientationMode.rawValue, forKey: Self.cacheKey(Keys.playerOrientationMode)) }
    }

    var autoPlayNextEpisode: Bool {
        didSet { defaults.set(autoPlayNextEpisode, forKey: Self.cacheKey(Keys.autoPlayNextEpisode)) }
    }

    var nextUpPromptSeconds: Int {
        didSet { defaults.set(nextUpPromptSeconds, forKey: Self.cacheKey(Keys.nextUpPromptSeconds)) }
    }

    private let defaults: UserDefaults

    /// Local preferences retain the existing device/profile cache partition.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.preferredQuality: "auto",
            // maxBitrateKbps deliberately has no registered default: the
            // contract's default is null, and a registered value would make
            // "uncapped" indistinguishable from "capped at that number".
            Keys.audioLanguage: "",
            Keys.autoSkipIntro: false,
            Keys.autoSkipCredits: false,

            Keys.backgroundPlaybackEnabled: true,
            Keys.bufferAhead: BufferAheadMode.automatic.rawValue,

            Keys.subtitleAppearance: SubtitleAppearance.default.jsonString,

            Keys.subtitleUsesDeviceAppearanceOverride: false,
            Keys.subtitleMatchesSystemAppearance: false,

            Keys.subtitleSyncMs: 0,
            Keys.playbackSpeed: 1.0,
            Keys.videoGravity: VideoGravity.fit.rawValue,
            Keys.playerOrientationMode: PlayerOrientationMode.landscapeLocked.rawValue,
            Keys.autoPlayNextEpisode: true,
            Keys.nextUpPromptSeconds: 30,
        ])

        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        introDBEnabled = (defaults.string(forKey: VividSkipSource.defaultsKey) ?? "introdb") == "introdb"
        autoSkipIntro = Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        backgroundPlaybackEnabled = Self.cachedBool(
            defaults,
            key: Keys.backgroundPlaybackEnabled,
            defaultValue: true
        )
        bufferAhead = Self.cachedBufferAhead(defaults)
        subtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
        subtitleUsesDeviceAppearanceOverride = Self.cachedBool(
            defaults,
            key: Keys.subtitleUsesDeviceAppearanceOverride,
            defaultValue: false
        )
        subtitleMatchesSystemAppearance = Self.cachedBool(
            defaults,
            key: Keys.subtitleMatchesSystemAppearance,
            defaultValue: false
        )
        subtitleSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))
        playbackSpeed = Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
        videoGravity = VideoGravity(rawValue: defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode)) ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked
        autoPlayNextEpisode = Self.cachedBool(
            defaults,
            key: Keys.autoPlayNextEpisode,
            legacyKey: Keys.legacyAutoPlayNextEpisode,
            defaultValue: true
        )
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
        )
        applyCachedSettingsForCurrentScope()

        NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSubtitleSystemAppearance()
        }
    }

    /// Re-read the system caption preferences. Idempotent; also called by
    /// the player when the system posts a settings-changed notification so
    /// re-application never races this class's own observer.
    func refreshSubtitleSystemAppearance() {
        subtitleSystemAppearance = SystemCaptionAppearance.current()
        subtitleSystemSelectionPreferences = SystemCaptionSelectionPreferences.current()
    }

    /// Reload preferences from this device after an account/profile change.
    @discardableResult
    @MainActor
    func reloadForCurrentProfile() async -> RefreshResult {
        applyCachedSettingsForCurrentScope()
        return .refreshed
    }

    /// Set the quality from a tier id on this client's in-player ladder.
    ///
    /// The in-player switcher's entry point: it offers ``ApplePlaybackQuality``
    /// rungs, so the id is decomposed into the contract's two axes before it is
    /// stored. Sending the compound id would fail the enum with
    /// `invalid_value`; see AppleQualityAxes.swift.
    func setPreferredQuality(_ value: String) {
        let axes = AppleQualityAxes.split(ApplePlaybackQuality.normalizeStoredId(value))
        setQualityAxes(resolution: axes.resolution, bitrateKbps: axes.bitrateKbps)
    }

    /// Set the quality from a shared preset — the settings screens' entry
    /// point, on every platform and in the web and Android clients.
    func setQualityPreset(_ preset: VividQualityPreset) {
        setQualityAxes(resolution: preset.resolution, bitrateKbps: preset.bitrateKbps)
    }

    /// Store one (resolution, bitrate) pair as the contract's two keys.
    ///
    /// Both axes are always written, never just the one that changed: the two
    /// resolve independently, so leaving a stale cap behind would keep
    /// throttling a tier the user just widened. Uncapped is an explicit JSON
    /// null rather than an omitted write for the same reason.
    private func setQualityAxes(resolution: String, bitrateKbps: Int?) {
        preferredQualityResolution = VividQualityPresets.normalizeResolution(resolution)
        maxBitrateKbps = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
    }

    func setAudioLanguage(_ value: String) {
        audioLanguage = value
        // The contract's language_tag rejects "": "no preference" is JSON null.
    }

    func setAutoSkipIntro(_ enabled: Bool) {
        autoSkipIntro = enabled
    }

    func setAutoSkipCredits(_ enabled: Bool) {
        autoSkipCredits = enabled
    }

    func setAutoPlayNextEpisode(_ enabled: Bool) {
        autoPlayNextEpisode = enabled
    }

    func setNextUpPromptSeconds(_ seconds: Int) {
        let normalized = Self.clampNextUpPromptSeconds(seconds)
        nextUpPromptSeconds = normalized
    }

    /// Choose whether video playback survives leaving the app. Purely local —
    /// there is no contract key to enqueue.
    func setBackgroundPlaybackEnabled(_ enabled: Bool) {
        backgroundPlaybackEnabled = enabled
    }

    /// Choose how far ahead Vivid buffers. Purely local — there is no contract
    /// key to enqueue.
    func setBufferAhead(_ mode: BufferAheadMode) {
        bufferAhead = mode
    }

    func setPlaybackSpeed(_ rate: Double) {
        let normalized = Self.clampPlaybackSpeed(rate)
        playbackSpeed = normalized
    }

    func setVideoGravity(_ gravity: VideoGravity) {
        videoGravity = gravity
    }

    func setPlayerOrientationMode(_ mode: PlayerOrientationMode) {
        playerOrientationMode = mode
    }

    func setSubtitleSyncMs(_ milliseconds: Int) {
        subtitleSyncMs = max(-10000, min(milliseconds, 10000))
    }

    @MainActor
    func setSubtitleAppearance(_ appearance: SubtitleAppearance) async {
        let sanitized = appearance.sanitized()
        subtitleAppearance = sanitized
        subtitleUsesDeviceAppearanceOverride = true
        // A manual edit takes over from the system-matching source.
        subtitleMatchesSystemAppearance = false
    }

    /// Toggle mirroring the device's Subtitles & Captioning accessibility
    /// preferences. Purely local; the saved Vivid appearance is untouched
    /// so switching back restores it.
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
        introDBEnabled = true
        resetDeviceLocalPreferences()
        cachePlaybackDefaults(for: Self.currentScopeIdentifier)
        applyCachedSettingsForCurrentScope()
        preferredSubtitleLanguage = PlaybackPrefSentinel.none
        preferredSubtitleMode = "auto"
        showForcedSubtitles = true
    }

    /// Restore device playback and caption-source preferences to defaults.
    private func resetDeviceLocalPreferences() {
        backgroundPlaybackEnabled = true
        bufferAhead = .automatic
        subtitleMatchesSystemAppearance = false
    }

    private func applyCachedSettingsForCurrentScope() {
        preferredSubtitleLanguage = defaults.string(forKey: Self.cacheKey("vivid.subtitle.language")) ?? PlaybackPrefSentinel.none
        preferredSubtitleMode = defaults.string(forKey: Self.cacheKey("vivid.subtitle.mode")) ?? "auto"
        showForcedSubtitles = Self.cachedBool(defaults, key: "vivid.subtitle.forced", defaultValue: true)

        preferredQualityResolution = Self.cachedQualityResolution(defaults)
        maxBitrateKbps = Self.cachedMaxBitrateKbps(defaults)
        audioLanguage = defaults.string(forKey: Self.cacheKey(Keys.audioLanguage)) ?? ""
        introDBEnabled = (defaults.string(forKey: VividSkipSource.defaultsKey) ?? "introdb") == "introdb"
        autoSkipIntro = Self.cachedBool(defaults, key: Keys.autoSkipIntro, defaultValue: false)
        autoSkipCredits = Self.cachedBool(defaults, key: Keys.autoSkipCredits, defaultValue: false)
        autoPlayNextEpisode = Self.cachedBool(
            defaults,
            key: Keys.autoPlayNextEpisode,
            legacyKey: Keys.legacyAutoPlayNextEpisode,
            defaultValue: true
        )
        nextUpPromptSeconds = Self.clampNextUpPromptSeconds(
            Self.cachedInt(defaults, key: Keys.nextUpPromptSeconds, defaultValue: 30)
        )
        backgroundPlaybackEnabled = Self.cachedBool(
            defaults,
            key: Keys.backgroundPlaybackEnabled,
            defaultValue: true
        )
        bufferAhead = Self.cachedBufferAhead(defaults)
        playbackSpeed = Self.clampPlaybackSpeed(
            Self.cachedDouble(defaults, key: Keys.playbackSpeed, defaultValue: 1.0)
        )
        subtitleSyncMs = defaults.integer(forKey: Self.cacheKey(Keys.subtitleSyncMs))
        videoGravity = VideoGravity(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.videoGravity)) ?? VideoGravity.fit.rawValue
        ) ?? .fit
        playerOrientationMode = PlayerOrientationMode(
            rawValue: defaults.string(forKey: Self.cacheKey(Keys.playerOrientationMode)) ?? PlayerOrientationMode.landscapeLocked.rawValue
        ) ?? .landscapeLocked
        subtitleUsesDeviceAppearanceOverride = Self.cachedBool(
            defaults,
            key: Keys.subtitleUsesDeviceAppearanceOverride,
            defaultValue: false
        )
        subtitleMatchesSystemAppearance = Self.cachedBool(
            defaults,
            key: Keys.subtitleMatchesSystemAppearance,
            defaultValue: false
        )
        subtitleAppearance = SubtitleAppearance.decode(from: defaults.string(forKey: Self.cacheKey(Keys.subtitleAppearance)))
    }

    /// The (server, profile, device) triple this device's settings belong to.
    ///
    /// Keep the established cache partition so existing preferences survive
    /// upgrades and remain isolated across profiles and servers.
    static var currentScopeIdentifier: String? {
        let serverURL = ServerRegistry.shared.activeServerUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = AuthService.shared.profileId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceID = AppleDeviceIdentity.current.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverURL.isEmpty, !profileID.isEmpty, !deviceID.isEmpty else {
            return nil
        }
        let raw = "\(serverURL)|\(profileID)|\(deviceID)"
        return Data(raw.utf8).base64EncodedString()
    }

    /// Store the canonical reset state in one explicit cache partition.
    /// All writes are local and target the same active profile partition.
    private func cachePlaybackDefaults(for scopeID: String?) {
        func key(_ baseKey: String) -> String {
            Self.cacheKey(baseKey, scopeID: scopeID)
        }

        defaults.set("auto", forKey: key(Keys.preferredQuality))
        defaults.removeObject(forKey: key(Keys.maxBitrateKbps))
        defaults.set("", forKey: key(Keys.audioLanguage))
        defaults.set(false, forKey: key(Keys.autoSkipIntro))
        defaults.set(false, forKey: key(Keys.autoSkipCredits))
        defaults.set(true, forKey: key(Keys.autoPlayNextEpisode))
        defaults.set(30, forKey: key(Keys.nextUpPromptSeconds))
        defaults.set(1.0, forKey: key(Keys.playbackSpeed))
        defaults.set(0, forKey: key(Keys.subtitleSyncMs))
        defaults.set(VideoGravity.fit.rawValue, forKey: key(Keys.videoGravity))
        defaults.set(
            PlayerOrientationMode.landscapeLocked.rawValue,
            forKey: key(Keys.playerOrientationMode)
        )
        defaults.set(SubtitleAppearance.default.jsonString, forKey: key(Keys.subtitleAppearance))
        defaults.set(false, forKey: key(Keys.subtitleUsesDeviceAppearanceOverride))
    }

    private static func cacheKey(_ baseKey: String) -> String {
        cacheKey(baseKey, scopeID: currentScopeIdentifier)
    }

    private static func cacheKey(_ baseKey: String, scopeID: String?) -> String {
        guard let scopeID else {
            return baseKey
        }
        return "player.serverDeviceSettings.\(scopeID).\(baseKey)"
    }

    private static func cachedBool(
        _ defaults: UserDefaults,
        key: String,
        legacyKey: String? = nil,
        defaultValue: Bool
    ) -> Bool {
        let scopedKey = cacheKey(key)
        if defaults.object(forKey: scopedKey) != nil {
            return defaults.bool(forKey: scopedKey)
        }
        #if os(iOS)
        if currentScopeIdentifier != defaults.string(forKey: "player.legacyMigrationOwner") { return defaultValue }
        #endif
        if let legacyKey, defaults.object(forKey: legacyKey) != nil {
            let legacyValue = defaults.bool(forKey: legacyKey)
            defaults.set(legacyValue, forKey: scopedKey)
            return legacyValue
        }
        return defaultValue
    }

    /// The cached resolution axis, tolerating a compound value written by a
    /// build that stored the tier id.
    ///
    /// Those builds wrote `1080p-high` and friends into this very key, so the
    /// value read here may be either spelling.
    /// ``VividQualityPresets/normalizeResolution(_:)`` reduces both to a
    /// contract member, dropping the bitrate half — which is correct, because
    /// the companion key below carries it. An upgrading device therefore keeps
    /// its resolution and loses only a cap it never stored separately, and the
    /// companion local bitrate key preserves any explicit cap.
    private static func cachedQualityResolution(_ defaults: UserDefaults) -> String {
        VividQualityPresets.normalizeResolution(
            defaults.string(forKey: cacheKey(Keys.preferredQuality))
        )
    }

    /// The cached bitrate axis. Absent is uncapped, which is why this reads
    /// through `object(forKey:)` rather than `integer(forKey:)` — the latter
    /// answers 0 for a missing key, and 0 is not a cap the contract accepts.
    private static func cachedMaxBitrateKbps(_ defaults: UserDefaults) -> Int? {
        guard defaults.object(forKey: cacheKey(Keys.maxBitrateKbps)) != nil else { return nil }
        let stored = defaults.integer(forKey: cacheKey(Keys.maxBitrateKbps))
        return stored > 0 ? stored : nil
    }

    private static func cachedBufferAhead(_ defaults: UserDefaults) -> BufferAheadMode {
        BufferAheadMode(
            rawValue: defaults.string(forKey: cacheKey(Keys.bufferAhead))
                ?? BufferAheadMode.automatic.rawValue
        ) ?? .automatic
    }

    private static func cachedDouble(_ defaults: UserDefaults, key: String, defaultValue: Double) -> Double {
        let scopedKey = cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else {
            return defaultValue
        }
        return defaults.double(forKey: scopedKey)
    }

    private static func cachedInt(_ defaults: UserDefaults, key: String, defaultValue: Int) -> Int {
        let scopedKey = cacheKey(key)
        guard defaults.object(forKey: scopedKey) != nil else {
            return defaultValue
        }
        return defaults.integer(forKey: scopedKey)
    }

    private static func clampNextUpPromptSeconds(_ seconds: Int) -> Int {
        max(0, min(seconds, 120))
    }

    /// Clamp to the contract's declared range *and* step for
    /// `player.playback_speed` (0.25…3.0, step 0.05).
    ///
    /// The step is the part worth stating: the server rejects a value off the
    /// grid with `invalid_value`, and a UI that ever offers 1.33× — or a
    /// double that lands at 1.7499999999999998 after arithmetic — would queue a
    /// write that can never succeed. Rounding here means the value the user
    /// sees is the value the server accepts.
    private static func clampPlaybackSpeed(_ rate: Double) -> Double {
        let bounded = max(0.25, min(rate, 3.0))
        let steps = ((bounded - 0.25) / 0.05).rounded()
        // Re-rounded to hundredths because 0.05 is not representable in binary:
        // 0.25 + 30 * 0.05 is 1.7500000000000002, which serializes as that.
        let aligned = ((0.25 + steps * 0.05) * 100).rounded() / 100
        return min(3.0, max(0.25, aligned))
    }

    private enum Keys {
        static let preferredQuality = "preferredQuality"
        static let maxBitrateKbps = "playback.maxBitrateKbps"
        static let audioLanguage = "preferredAudioLanguage"
        static let autoSkipIntro = "skipIntros"
        static let autoSkipCredits = "skipCredits"
        static let backgroundPlaybackEnabled = "player.backgroundPlaybackEnabled"
        static let bufferAhead = "player.bufferAhead"
        static let subtitleAppearance = "player.subtitleAppearance"
        static let subtitleUsesDeviceAppearanceOverride = "player.subtitleUsesDeviceAppearanceOverride"
        static let subtitleMatchesSystemAppearance = "player.subtitleMatchesSystemAppearance"
        static let subtitleSyncMs = "player.subtitleSyncMs"
        static let playbackSpeed = "player.playbackSpeed"
        static let videoGravity = "player.videoGravity"
        static let playerOrientationMode = "player.playerOrientationMode"
        static let autoPlayNextEpisode = "autoPlayNext"
        static let legacyAutoPlayNextEpisode = "player.autoPlayNextEpisode"
        static let nextUpPromptSeconds = "player.nextUpPromptSeconds"
    }
}

/// Vivid owns marker lookup independently of the connected media server.
enum VividSkipSource {
    static var defaultsKey: String {
        #if os(iOS)
        if let scope = PlayerSettings.currentScopeIdentifier { return "vivid.playback.skipSource.\(scope)" }
        #endif
        return "vivid.playback.skipSource"
    }
    static var isEnabled: Bool { PlayerSettings.shared.introDBEnabled }
}

actor VividIntroDBClient {
    static let shared = VividIntroDBClient()

    struct Episode: Hashable, Sendable {
        let imdbID: String
        let season: Int
        let episode: Int
    }
    struct Segment: Decodable, Sendable {
        let start_ms: Double
        let end_ms: Double

        func range(duration: Double) -> TimeRange? {
            let start = start_ms / 1000
            let end = end_ms / 1000
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  duration > 0, end <= duration + 1, start < duration else { return nil }
            return TimeRange(start: start, end: min(end, duration))
        }
    }
    struct Segments: Decodable, Sendable {
        let imdb_id: String
        let season: Int
        let episode: Int
        let intro: Segment?
        let outro: Segment?
    }
    private var cache: [Episode: (Date, Segments)] = [:]
    private let session: URLSession
    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        self.session = session ?? URLSession(configuration: configuration)
    }

    func segments(for episode: Episode) async throws -> Segments? {
        guard episode.imdbID.range(of: "^tt[0-9]{7,8}$", options: .regularExpression) != nil,
              episode.season > 0, episode.episode > 0 else { return nil }
        if let cached = cache[episode], Date().timeIntervalSince(cached.0) < 3600 { return cached.1 }
        var url = URLComponents(string: "https://api.introdb.app/segments")!
        url.queryItems = [URLQueryItem(name: "imdb_id", value: episode.imdbID),
                         URLQueryItem(name: "season", value: String(episode.season)),
                         URLQueryItem(name: "episode", value: String(episode.episode))]
        // Separate session: never attach a media-server token or cookie.
        let (data, response) = try await session.data(from: url.url!)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { return nil }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200, data.count < 100_000 else { return nil }
        let result = try JSONDecoder().decode(Segments.self, from: data)
        guard result.imdb_id == episode.imdbID, result.season == episode.season,
              result.episode == episode.episode else { return nil }
        if cache.count >= 200 { cache.removeAll() }
        cache[episode] = (Date(), result)
        return result
    }
}
