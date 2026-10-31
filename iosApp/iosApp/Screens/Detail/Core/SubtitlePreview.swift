import Foundation

/// The subtitle a detail page promises: the player's automatic pick run
/// against the file's catalogue tracks (and Silo's stored subtitles) with
/// the audio the player will start with, so the page and playback agree. It
/// reads the same on Silo, Emby and Jellyfin, and never uses a server's
/// remembered subtitle choice.
extension DetailPlaybackFormatting {
    /// The preferences the automatic pick runs with.
    struct SubtitleAutoContext {
        var preferredLanguage: String?
        var mode: String?
        var signature: SubtitleTrackSignature?
        var audioLanguage: String?
        var showForced: Bool = false
        var additionalPreferredLanguages: [String] = []
        var forcedOnly = false
        var preferAccessibilityTracks = false
        var disableWhenNoLanguageMatch = false
        var fallbackLanguages: [String] = []
        var forcedFollowsAudio = false
    }

    /// "Auto: …" when the subtitle mode is Auto, otherwise the outcome
    /// alone.
    @MainActor static func automaticSubtitleLabel(version: FileVersion?, selectedAudioTrackIndex: Int?, settings: PlayerSettings = .shared) -> String {
        guard version != nil else { return String(localized: "Auto") }
        let outcome = automaticSubtitleOutcome(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, settings: settings)
        if PlayerViewModel.settingsSubtitlePrefs(settings).mode == .auto {
            return String(localized: "Auto: \(outcome)")
        }
        return outcome
    }

    /// The short label of the subtitle playback would pick, or Off.
    @MainActor static func automaticSubtitleOutcome(version: FileVersion?, selectedAudioTrackIndex: Int?, settings: PlayerSettings = .shared) -> String {
        guard let version else { return String(localized: "Off") }
        let context = SubtitleAutoContext(
            prefs: PlayerViewModel.settingsSubtitlePrefs(settings),
            audioLanguage: startingAudioLanguage(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, settings: settings))
        let stored = SiloStoredSubtitles.shared.subtitles(fileID: version.fileId)
        guard let pick = automaticSubtitle(version: version, context: context, stored: stored) else {
            return String(localized: "Off")
        }
        return subtitleShortLabel(pick.track, ordinal: pick.ordinal)
    }

    /// Runs the player's resolver over the file's subtitles in plan order,
    /// then Silo's stored ones. A stored pick comes back as a stand-in
    /// external track, numbered by its combined index.
    static func automaticSubtitle(version: FileVersion?, context: SubtitleAutoContext, stored: [SiloStoredSubtitle] = []) -> (track: SubtitleTrack, ordinal: Int)? {
        let catalogue = version?.subtitleTracks ?? []
        let usable = catalogue.enumerated().filter { _, track in
            track.external != true || ServerSubtitleSidecars.isMountable(codec: track.codec)
        }
        let ordered = usable.filter { $0.element.external == true } + usable.filter { $0.element.external != true }
        let candidates = SubtitleTrackCandidates.playerTracks(from: ordered.map(\.element))
        let storedRows = ServerSubtitleSidecars.storedRows(stored, catalog: version?.subtitleTracks)

        let selection = SubtitleAutoResolver.resolve(SubtitleAutoResolver.Inputs(
            preferredLanguage: context.preferredLanguage,
            additionalPreferredLanguages: context.additionalPreferredLanguages,
            mode: SubtitleMode(rawValue: context.mode ?? ""),
            showForced: context.showForced,
            forcedOnly: context.forcedOnly,
            forcedFollowsAudio: context.forcedFollowsAudio,
            preferAccessibilityTracks: context.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: context.disableWhenNoLanguageMatch,
            trackSignature: context.signature,
            fallbackLanguages: context.fallbackLanguages,
            availableSubtitles: candidates + storedRows,
            currentAudioLanguage: context.audioLanguage))
        guard case .select(let picked) = selection else { return nil }

        if let index = candidates.firstIndex(where: { $0.trackId == picked.trackId }) {
            return (track: ordered[index].element, ordinal: ordered[index].offset)
        }
        if let row = storedRows.first(where: { $0.trackId == picked.trackId }) {
            let track = SubtitleTrack(
                index: nil, codec: row.codec, language: row.lang, title: row.title, embeddedTitle: nil,
                forced: false, hearingImpaired: row.isHearingImpaired, isDefault: false,
                external: true, externalPath: nil)
            return (track: track, ordinal: row.srcId ?? catalogue.count)
        }
        return nil
    }

    /// The language the player's subtitle policy sees at the start: the
    /// language of the audio track playback will choose.
    @MainActor static func startingAudioLanguage(version: FileVersion?, selectedAudioTrackIndex: Int?, settings: PlayerSettings) -> String? {
        let ordinal = resolvedAudioOrdinal(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex,
                                           preferredLanguage: settings.audioLanguage)
        return SubtitleAutoResolver.policyAudioLanguage(live: nil, catalog: version?.audioTracks ?? [], ordinal: ordinal)
    }

    // MARK: - Short label

    /// The subtitle's name with "(SDH)" and "(Forced)" added when the name
    /// doesn't already say so.
    static func subtitleShortLabel(_ track: SubtitleTrack, ordinal: Int) -> String {
        let name = languageLabel(track.language, inAppLanguage: true)
            ?? informativeSubtitleTitle(track)
            ?? String(localized: "Track \(ordinal + 1)")
        let titleForFlags = track.title ?? track.embeddedTitle
        let isForced = track.forced == true || SubtitleAutoResolver.titleIndicatesForced(titleForFlags)
        let isHearingImpaired = track.hearingImpaired == true || SubtitleAutoResolver.titleIndicatesHearingImpaired(titleForFlags)

        let lowered = name.lowercased()
        let words = lowered.split(whereSeparator: { !$0.isLetter })
        let namesAccessibility = words.contains { ["sdh", "cc", "hi"].contains(String($0)) }
            || lowered.contains("hearing impaired")
        let addsSDH = isHearingImpaired && !namesAccessibility
        let addsForced = isForced && !name.localizedCaseInsensitiveContains("forced")

        switch (addsSDH, addsForced) {
        case (true, true): return String(localized: "\(name) (SDH) (Forced)")
        case (true, false): return String(localized: "\(name) (SDH)")
        case (false, true): return String(localized: "\(name) (Forced)")
        case (false, false): return name
        }
    }

    /// Words that only flag the track, which the label adds itself.
    private static let subtitleFlagTitles: Set<String> = ["forced", "sdh", "cc", "hi", "hearing impaired"]

    private static func informativeSubtitleTitle(_ track: SubtitleTrack) -> String? {
        guard let title = trimmedText(track.title) ?? trimmedText(track.embeddedTitle) else { return nil }
        let lowered = title.lowercased()
        if subtitleFlagTitles.contains(lowered) || isUninformativeSubtitleTitle(lowered, track: track) { return nil }
        return tidiedTitle(title)
    }

    /// A title that only repeats "subtitles", the language or the format.
    private static func isUninformativeSubtitleTitle(_ lowered: String, track: SubtitleTrack) -> Bool {
        if lowered == "subtitle" || lowered == "subtitles" { return true }
        if let english = languageLabel(track.language, inAppLanguage: false), lowered == english.lowercased() { return true }
        if let code = track.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), lowered == code { return true }
        if let codec = track.codec {
            if lowered == normalizedSubtitleCodec(codec)?.lowercased() || lowered == codec.lowercased() { return true }
        }
        return false
    }
}

extension DetailPlaybackFormatting.SubtitleAutoContext {
    /// The context Settings (or the device's caption settings, when Vivid
    /// follows them) gives, with the audio language the player starts with.
    init(prefs: PlayerViewModel.PrefsSnapshot, audioLanguage: String?) {
        self.init(
            preferredLanguage: prefs.preferredLanguage,
            mode: prefs.mode?.rawValue,
            signature: prefs.trackSignature,
            audioLanguage: audioLanguage,
            showForced: prefs.showForced,
            additionalPreferredLanguages: prefs.additionalPreferredLanguages,
            forcedOnly: prefs.forcedOnly,
            preferAccessibilityTracks: prefs.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: prefs.disableWhenNoLanguageMatch,
            fallbackLanguages: prefs.fallbackLanguages,
            forcedFollowsAudio: prefs.forcedFollowsAudio)
    }
}
