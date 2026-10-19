import Foundation

enum DetailPlaybackFormatting {
    static func mobileVersionSummary(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        let resolution = (version.resolution ?? "").lowercased()
        let height = Int(resolution.filter(\.isNumber)) ?? 0
        let quality = resolution.contains("4k") || resolution.contains("uhd") || height >= 2160 ? "4K" : height >= 1080 || resolution.contains("fhd") ? "FHD" : resolution.isEmpty ? nil : "HD"
        return [quality, dynamicRangeLabel(version) ?? normalizedVideoCodec(version.codecVideo)].compactMap { $0 }.joined(separator: " · ")
    }

    struct AudioOption: Identifiable, Hashable {
        let ordinal: Int
        let title: String
        let detail: String
        let isSelected: Bool
        var id: Int { ordinal }
    }

    struct SubtitleOption: Identifiable, Hashable {
        let selectionIndex: Int?
        let title: String
        let detail: String
        let isSelected: Bool
        let isSelectable: Bool
        let stableId: String
        var id: String { stableId }
    }

    static func versionShortLabel(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        let tokens = [
            nonEmpty(version.resolution),
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            nonEmpty(normalizedAudioCodec(version.codecAudio)),
        ].compactMap { $0 }
        return tokens.isEmpty ? "Auto" : tokens.joined(separator: " · ")
    }

    /// Resting-state video summary for the compact tvOS selector segment.
    /// Keep the two facts viewers need at a glance (resolution + HDR family),
    /// while the focused segment expands to ``versionShortLabel(_:)``.
    static func versionCompactLabel(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        let tokens = [
            nonEmpty(version.resolution),
            dynamicRangeLabel(version),
        ].compactMap { $0 }
        return tokens.isEmpty ? "Auto" : tokens.joined(separator: " · ")
    }

    static func versionDetailLabel(_ version: FileVersion) -> String {
        let tokens = [
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            nonEmpty(version.container)?.uppercased(),
            version.fileSize.map(formatFileSize),
        ].compactMap { $0 }
        return tokens.joined(separator: " · ")
    }

    static func versionPrimaryText(_ version: FileVersion) -> String {
        let tokens = [
            nonEmpty(version.resolution),
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            nonEmpty(normalizedAudioCodec(version.codecAudio)),
        ].compactMap { $0 }
        if !tokens.isEmpty {
            return tokens.joined(separator: " · ")
        }
        if let fileName = normalizedFileName(version.fileName) {
            return fileName
        }
        return "Version \(version.fileId)"
    }

    static func versionSecondaryText(_ version: FileVersion) -> String? {
        let tokens = [
            nonEmpty(versionDetailLabel(version)),
        ].compactMap { $0 }
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }

    static func currentEdition(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> PlaybackEditions.Edition? {
        PlaybackEditions.edition(forFileId: currentVersion?.fileId, in: versions)
            ?? PlaybackEditions.editions(from: versions).first
    }

    static func versionSelectorVersions(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> [FileVersion] {
        let editions = PlaybackEditions.editions(from: versions)
        if editions.count > 1,
           let currentEdition = currentEdition(versions: versions, currentVersion: currentVersion) {
            return currentEdition.versions
        }
        return versions
    }

    static func shouldEnableVersionSelector(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> Bool {
        versionSelectorVersions(versions: versions, currentVersion: currentVersion).count > 1
    }

    static func shouldShowAudioValue(version: FileVersion?) -> Bool {
        !(version?.audioTracks ?? []).isEmpty
    }

    static func shouldEnableAudioSelector(version: FileVersion?) -> Bool {
        (version?.audioTracks ?? []).count > 1
    }

    /// The subtitle row always shows once the file is known, even for a file
    /// with no subtitles: it reads "Off" and still opens OpenSubtitles search.
    static func shouldShowSubtitleValue(version: FileVersion?) -> Bool {
        version != nil
    }

    static func shouldEnableSubtitleSelector(version: FileVersion?) -> Bool {
        (version?.subtitleTracks ?? []).count > 1
    }

    static func audioOptions(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> [AudioOption] {
        guard let version else { return [] }
        let selectedOrdinal = resolvedAudioOrdinal(
            version: version,
            selectedAudioTrackIndex: selectedAudioTrackIndex
        )
        return (version.audioTracks ?? []).enumerated().map { ordinal, track in
            AudioOption(
                ordinal: ordinal,
                title: audioTitle(track, ordinal: ordinal),
                detail: audioDetail(track, ordinal: ordinal, version: version),
                isSelected: selectedOrdinal == ordinal
            )
        }
    }

    static func resolvedAudioOrdinal(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> Int? {
        guard let version,
              let tracks = version.audioTracks,
              !tracks.isEmpty else {
            return nil
        }
        if let selectedAudioTrackIndex, tracks.indices.contains(selectedAudioTrackIndex) {
            return selectedAudioTrackIndex
        }
        if let effective = version.effectiveAudioTrackIndex, tracks.indices.contains(effective) {
            return effective
        }
        if let defaultIndex = tracks.firstIndex(where: { $0.isDefault == true }) {
            return defaultIndex
        }
        return tracks.startIndex
    }

    static func audioValueLabel(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        annotateAuto: Bool = false
    ) -> String {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return "Unknown"
        }
        let summary = audioSummary(track, ordinal: ordinal)
        // With no explicit pick, the shown track is whatever Auto resolved to
        // (preferred/default). Prefix "Auto:" so the row makes clear the
        // choice was automatic rather than user-selected.
        if annotateAuto, selectedAudioTrackIndex == nil {
            return "Auto: \(summary)"
        }
        return summary
    }

    /// Compact codec/layout disclosure for a passive UI readout. Unlike the
    /// interactive selector value, this intentionally omits language and the
    /// "Auto" prefix (for example, "EAC3 5.1").
    static func audioTechnicalSummary(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> String? {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return normalizedAudioCodec(version?.codecAudio)
        }
        return [
            normalizedAudioCodec(track.codec) ?? normalizedAudioCodec(version.codecAudio),
            compactAudioLayout(track),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// Language of the track that `audioValueLabel` would display, used to
    /// feed the subtitle auto-resolver (Auto mode hides subs when the audio
    /// is already in the preferred subtitle language).
    static func resolvedAudioLanguage(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> String? {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return nil
        }
        return track.language
    }

    static func audioTitle(_ track: AudioTrack, ordinal: Int) -> String {
        if let language = languageDisplayName(track.language) { return language }
        if let title = usefulAudioTitle(track) { return title }
        return "Track \(ordinal + 1)"
    }

    static func audioDetail(_ track: AudioTrack, ordinal: Int, version: FileVersion?) -> String {
        var tokens: [String] = []
        if let title = usefulAudioTitle(track), title != audioTitle(track, ordinal: ordinal) {
            tokens.append(title)
        }
        if let codec = normalizedAudioCodec(track.codec) {
            tokens.append(codec)
        }
        if let layout = compactAudioLayout(track) {
            tokens.append(layout)
        }
        if track.isDefault == true {
            tokens.append("Default")
        }
        if version?.effectiveAudioTrackIndex == ordinal {
            tokens.append("Preferred")
        }
        return tokens.joined(separator: " · ")
    }

    private static func audioSummary(_ track: AudioTrack, ordinal: Int) -> String {
        let tokens = [
            languageDisplayName(track.language),
            nonEmpty(normalizedAudioCodec(track.codec)),
            compactAudioLayout(track),
        ].compactMap { $0 }
        return tokens.isEmpty ? audioTitle(track, ordinal: ordinal) : tokens.joined(separator: " · ")
    }

    /// What the detail page's subtitle row shows while nothing is picked this
    /// visit: the track playback will choose from Settings > Subtitles, or
    /// from the device's caption settings when Vivid follows them. It runs the
    /// player's own resolver on this file's tracks, with the audio the player
    /// will start, so the row and playback agree on Silo, Emby and Jellyfin.
    /// Auto reads "Auto: English (Forced)" or "Auto: Off"; Always and Off read
    /// as the track or "Off".
    @MainActor
    static func automaticSubtitleLabel(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        settings: PlayerSettings = .shared
    ) -> String {
        guard let version else { return "Auto" }
        let outcome = automaticSubtitleOutcome(
            version: version,
            selectedAudioTrackIndex: selectedAudioTrackIndex,
            settings: settings
        )
        return PlayerViewModel.settingsSubtitlePrefs(settings).mode == .auto
            ? "Auto: \(outcome)"
            : outcome
    }

    /// The track the automatic pick lands on, as "English (Forced)", or
    /// "Off" for no subtitles.
    @MainActor
    static func automaticSubtitleOutcome(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        settings: PlayerSettings = .shared
    ) -> String {
        let context = SubtitleAutoContext(
            prefs: PlayerViewModel.settingsSubtitlePrefs(settings),
            audioLanguage: playbackAudioLanguage(
                version: version,
                selectedAudioTrackIndex: selectedAudioTrackIndex,
                settings: settings
            )
        )
        return automaticSubtitle(version: version, context: context)
            .map { subtitleShortLabel($0.track, ordinal: $0.ordinal) } ?? "Off"
    }

    /// The language of the audio playback will start with: the track picked
    /// on this page, otherwise the player's own choice from Settings >
    /// Playback > Audio Language (`VividInitialAudioPreference`). Not the
    /// server's remembered audio, which playback doesn't use either.
    @MainActor
    static func playbackAudioLanguage(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        settings: PlayerSettings = .shared
    ) -> String? {
        let tracks = version?.audioTracks ?? []
        let manual = selectedAudioTrackIndex.flatMap { tracks.indices.contains($0) ? $0 : nil }
        let ordinal = VividInitialAudioPreference.selectedOrdinal(
            manual: manual,
            tracks: tracks,
            preferredLanguage: settings.audioLanguage
        )
        return SubtitleAutoResolver.policyAudioLanguage(live: nil, catalog: tracks, ordinal: ordinal)
    }

    /// The track `SubtitleAutoResolver` picks from this file's catalogue
    /// tracks, or nil for no subtitles. The candidates, their order and their
    /// identities are the player's (`SubtitleTrackCandidates`), and a server
    /// subtitle file the player can't render is left out. `ordinal` is the
    /// catalogue offset, so "Track N" labels match `subtitleOptions`.
    static func automaticSubtitle(
        version: FileVersion?,
        context: SubtitleAutoContext
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        let catalog = Array((version?.subtitleTracks ?? []).enumerated())
        let playable = catalog.filter {
            $0.element.external != true || ServerSubtitleSidecars.isMountable(codec: $0.element.codec)
        }
        let ordered = playable.filter { $0.element.external == true }
            + playable.filter { $0.element.external != true }
        let candidates = SubtitleTrackCandidates.playerTracks(from: ordered.map(\.element))
        let pick = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: context.preferredLanguage,
            additionalPreferredLanguages: context.additionalPreferredLanguages,
            mode: SubtitleMode(rawValue: context.mode ?? ""),
            showForced: context.showForced,
            forcedOnly: context.forcedOnly,
            preferAccessibilityTracks: context.preferAccessibilityTracks,
            disableWhenNoLanguageMatch: context.disableWhenNoLanguageMatch,
            trackSignature: context.signature,
            availableSubtitles: candidates,
            currentAudioLanguage: context.audioLanguage
        ))
        guard case .select(let track) = pick,
              let position = candidates.firstIndex(where: { $0.trackId == track.trackId }) else {
            return nil
        }
        return (ordered[position].element, ordered[position].offset)
    }

    static func subtitleOptions(
        version: FileVersion?,
        selectedSubtitleTrackIndex: Int?,
        preferredLanguage: String?
    ) -> [SubtitleOption] {
        // Group by language + sort by preferred format. The original array
        // index is carried through as `ordinal` so the stable id and any
        // "Track N" fallback label stay put regardless of display order —
        // selection keys off the FFmpeg `index`, never the position.
        let indexed = Array((version?.subtitleTracks ?? []).enumerated())
        let ordered = SubtitleDisplayOrder.order(
            indexed,
            preferredLanguage: preferredLanguage
        ) { ordinal, track in
            let type = subtitleType(track, ordinal: ordinal)
            return SubtitleDisplayOrder.Descriptor(
                language: track.language,
                codec: track.codec,
                isForced: track.forced ?? false,
                isHearingImpaired: type == "SDH" || type == "CC",
                isDefault: track.isDefault ?? false
            )
        }
        return ordered.map { ordinal, track in
            // `selectionIndex` reads an embedded nil index as stream 0, so
            // only external sidecars without a stream index are unselectable.
            let index = track.selectionIndex
            let isSelectable = index != nil
            return SubtitleOption(
                selectionIndex: index,
                title: subtitleTitle(track, ordinal: ordinal),
                detail: subtitleDetail(track, isSelectable: isSelectable),
                isSelected: index != nil && selectedSubtitleTrackIndex == index,
                isSelectable: isSelectable,
                stableId: "\(ordinal)|\(track.id)"
            )
        }
    }

    /// `SubtitleAutoResolver.Inputs` without the tracks: the preferences the
    /// automatic pick resolves, and the audio it compares them with.
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
    }

    static func subtitleTitle(_ track: SubtitleTrack, ordinal: Int) -> String {
        if let language = languageDisplayName(track.language) { return language }
        if let title = meaningfulSubtitleTitle(track) { return title }
        return "Track \(ordinal + 1)"
    }

    static func subtitleDetail(_ track: SubtitleTrack, isSelectable: Bool) -> String {
        var tokens: [String] = []
        if let title = meaningfulSubtitleTitle(track) {
            tokens.append(title)
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            tokens.append(codec)
        }
        if isForced(track) {
            tokens.append("Forced")
        }
        if isHearingImpaired(track) {
            tokens.append("SDH")
        }
        if track.isDefault == true {
            tokens.append("Default")
        }
        if track.external == true {
            tokens.append("External")
        }
        if !isSelectable {
            tokens.append("Available in player")
        }
        return tokens.joined(separator: " · ")
    }

    /// "English", "English (Forced)" or "English (SDH)": a track as the
    /// subtitle row names it.
    static func subtitleShortLabel(_ track: SubtitleTrack, ordinal: Int) -> String {
        var name = subtitleTitle(track, ordinal: ordinal)
        if isHearingImpaired(track), !containsAccessibilityMarker(name) {
            name += " (SDH)"
        }
        if isForced(track), !name.localizedCaseInsensitiveContains("forced") {
            name += " (Forced)"
        }
        return name
    }

    static func normalizedVideoCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("hevc") || codec.contains("h265") { return "HEVC" }
        if codec.contains("av1") { return "AV1" }
        if codec.contains("avc") || codec.contains("h264") { return "H.264" }
        return codec.uppercased()
    }

    /// "DV P8.1", "HDR10+", "HDR10", "HLG", "HDR" or nil for SDR, the same
    /// label as the player's Stream pill (`PlayerStreamBadges`).
    static func dynamicRangeLabel(_ version: FileVersion) -> String? {
        PlayerStreamBadges.dynamicRange(version)
    }

    static func normalizedAudioCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("eac3") || codec.contains("e-ac-3") || codec.contains("ec-3") {
            return "EAC3"
        }
        if codec.contains("ac3") || codec.contains("ac-3") { return "AC3" }
        if codec.contains("aac") { return "AAC" }
        if codec.contains("mp3") { return "MP3" }
        if codec.contains("truehd") { return "TrueHD" }
        if codec.contains("dts") { return "DTS" }
        if codec.contains("flac") { return "FLAC" }
        return codec.uppercased()
    }

    static func normalizedSubtitleCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec == "srt" || codec.contains("subrip") { return "SRT" }
        if codec == "ass" || codec.contains("ass") { return "ASS" }
        if codec == "ssa" || codec.contains("ssa") { return "SSA" }
        if codec == "vtt" || codec.contains("webvtt") { return "WebVTT" }
        if codec.contains("pgs") || codec.contains("hdmv") { return "PGS" }
        if codec.contains("dvd") || codec.contains("vobsub") { return "VobSub" }
        if codec.contains("mov_text") || codec.contains("tx3g") { return "TX3G" }
        return codec.uppercased()
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func compactAudioLayout(_ track: AudioTrack) -> String? {
        if let layout = nonEmpty(track.channelLayout) {
            let lowered = layout.lowercased()
            if lowered.contains("atmos") { return "Atmos" }
            if lowered.contains("7.1") { return "7.1" }
            if lowered.contains("5.1") { return "5.1" }
            if lowered.contains("stereo") { return "Stereo" }
            return layout
        }
        switch track.channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let channels?: return "\(channels)ch"
        case nil: return nil
        }
    }

    private static func subtitleType(_ track: SubtitleTrack, ordinal: Int) -> String? {
        if let title = nonEmpty(track.title) {
            let lowered = title.lowercased()
            if lowered.contains("sdh") || lowered.contains("hearing") {
                return "SDH"
            }
            if lowered.contains("closed caption") || lowered == "cc" {
                return "CC"
            }
            if lowered.contains("forced") {
                return "Forced"
            }
            if !isRedundantSubtitleTitle(title, track: track) {
                return displayTitle(title)
            }
        }
        if track.forced == true {
            return "Forced"
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            return codec
        }
        return nil
    }

    private static func usefulAudioTitle(_ track: AudioTrack) -> String? {
        guard let title = nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle) else { return nil }
        let lowered = title.lowercased()
        let technicalTerms = [
            "atsc",
            "a/52",
            "ac-3",
            "e-ac-3",
            "eac3",
            "truehd",
            "dts",
            "aac",
            "flac",
        ]
        if technicalTerms.contains(where: { lowered.contains($0) }) {
            return nil
        }
        return displayTitle(title)
    }

    private static func meaningfulSubtitleTitle(_ track: SubtitleTrack) -> String? {
        guard let title = nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle),
              !isRedundantSubtitleTitle(title, track: track) else {
            return nil
        }
        let lowered = title.lowercased()
        if lowered == "forced" || ["sdh", "cc", "hi", "hearing impaired"].contains(lowered) {
            return nil
        }
        return displayTitle(title)
    }

    private static func isHearingImpaired(_ track: SubtitleTrack) -> Bool {
        (track.hearingImpaired ?? false)
            || SubtitleAutoResolver.titleIndicatesHearingImpaired(track.title ?? track.embeddedTitle)
    }

    private static func isForced(_ track: SubtitleTrack) -> Bool {
        (track.forced ?? false)
            || SubtitleAutoResolver.titleIndicatesForced(track.title ?? track.embeddedTitle)
    }

    private static func containsAccessibilityMarker(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let words = lowered
            .split { !$0.isLetter }
            .map(String.init)
        return words.contains("sdh")
            || words.contains("cc")
            || words.contains("hi")
            || lowered.contains("hearing impaired")
    }

    private static func isRedundantSubtitleTitle(_ title: String, track: SubtitleTrack) -> Bool {
        let lowered = title.lowercased()
        let language = languageDisplayName(track.language)?.lowercased()
        let languageCode = nonEmpty(track.language)?.lowercased()
        if lowered == "subtitle" || lowered == "subtitles" {
            return true
        }
        if let language, lowered == language {
            return true
        }
        if let languageCode, lowered == languageCode {
            return true
        }
        if let codec = normalizedSubtitleCodec(track.codec)?.lowercased(),
           lowered == codec.lowercased() || lowered == track.codec?.lowercased() {
            return true
        }
        return false
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "sdh": return "SDH"
        case "cc": return "CC"
        case "srt", "subrip": return "SubRip"
        case "webvtt", "vtt": return "WebVTT"
        default: return trimmed
        }
    }

    private static func languageDisplayName(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let primary = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        // A token longer than a 3-letter ISO tag is already a spelled-out
        // name (e.g. free-text metadata); show it as-is.
        if primary.count > 3 {
            return value.capitalized
        }
        // Share the canonical ISO 639 folding + English display-name table
        // with the track-ordering core so the detail page's grouping and
        // its row labels never disagree on a language.
        if let key = SubtitleDisplayOrder.canonicalLanguageKey(value) {
            return SubtitleDisplayOrder.languageDisplayName(key)
        }
        return value.uppercased()
    }

    private static func normalizedFileName(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        return nonEmpty(name)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension DetailPlaybackFormatting.SubtitleAutoContext {
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
            disableWhenNoLanguageMatch: prefs.disableWhenNoLanguageMatch
        )
    }
}
