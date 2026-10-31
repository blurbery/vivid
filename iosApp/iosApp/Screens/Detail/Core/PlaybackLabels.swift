import Foundation

/// The text detail pages and the download sheet show for a title's files:
/// version readouts, the playback selectors' rules and the audio the player
/// will start with. The subtitle preview is in `SubtitlePreview.swift`.
enum DetailPlaybackFormatting {
    /// A space, a middle dot and a space.
    static let separator = " \u{00B7} "

    // MARK: - Versions

    /// The compact iPhone Version readout: a quality class and the dynamic
    /// range (or the video codec).
    static func mobileVersionSummary(_ version: FileVersion?) -> String {
        guard let version else { return String(localized: "Auto") }
        let resolution = (version.resolution ?? "").lowercased()
        let height = Int(String(resolution.filter(\.isNumber))) ?? 0
        let quality: String?
        if resolution.contains("4k") || resolution.contains("uhd") || height >= 2160 {
            quality = "4K"
        } else if height >= 1080 || resolution.contains("fhd") {
            quality = "FHD"
        } else if resolution.isEmpty {
            quality = nil
        } else {
            quality = "HD"
        }
        let range = dynamicRangeLabel(version) ?? normalizedVideoCodec(version.codecVideo)
        return joined([quality, range])
    }

    static func versionShortLabel(_ version: FileVersion?) -> String {
        guard let version else { return String(localized: "Auto") }
        let label = joined(shortParts(version))
        return label.isEmpty ? String(localized: "Auto") : label
    }

    /// Not shown anywhere. Kept only because main's Apple TV selector row
    /// still names it, from `TVPlaybackActionSelectors.versionValue`, a
    /// private property nothing reads; this stops that file failing to
    /// build. A clean-up after the detail rewrites removes both together.
    static func versionCompactLabel(_ version: FileVersion?) -> String {
        guard let version else { return String(localized: "Auto") }
        let label = joined([trimmedText(version.resolution), dynamicRangeLabel(version)])
        return label.isEmpty ? String(localized: "Auto") : label
    }

    static func versionDetailLabel(_ version: FileVersion) -> String {
        let container = trimmedText(version.container)?.uppercased()
        let size = version.fileSize.map { fileSizeFormatter.string(fromByteCount: $0) }
        return joined([trimmedText(normalizedVideoCodec(version.codecVideo)), container, size])
    }

    /// The short label's parts, else the file's name without its extension,
    /// else "Version" and the file id.
    static func versionPrimaryText(_ version: FileVersion) -> String {
        let label = joined(shortParts(version))
        if !label.isEmpty { return label }
        if let fileName = trimmedText(version.fileName) {
            // The extension as a file URL sees it.
            let base = URL(fileURLWithPath: fileName, isDirectory: false).deletingPathExtension().lastPathComponent
            if let name = trimmedText(base) { return name }
        }
        return String(localized: "Version \(String(version.fileId))")
    }

    static func versionSecondaryText(_ version: FileVersion) -> String? {
        trimmedText(versionDetailLabel(version))
    }

    static func dynamicRangeLabel(_ version: FileVersion) -> String? {
        PlayerStreamBadges.dynamicRange(version)
    }

    private static func shortParts(_ version: FileVersion) -> [String?] {
        [
            trimmedText(version.resolution),
            trimmedText(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            trimmedText(normalizedAudioCodec(version.codecAudio)),
        ]
    }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    // MARK: - Selector rules

    /// The edition holding the current file, else the first edition.
    static func currentEdition(versions: [FileVersion], currentVersion: FileVersion?) -> PlaybackEditions.Edition? {
        PlaybackEditions.edition(owning: currentVersion?.fileId, in: versions)
            ?? PlaybackEditions.editions(from: versions).first
    }

    /// With more than one edition the Version menu lists the current
    /// edition's files only.
    static func versionSelectorVersions(versions: [FileVersion], currentVersion: FileVersion?) -> [FileVersion] {
        guard PlaybackEditions.editions(from: versions).count > 1,
              let edition = currentEdition(versions: versions, currentVersion: currentVersion) else { return versions }
        return edition.versions
    }

    static func shouldEnableVersionSelector(versions: [FileVersion], currentVersion: FileVersion?) -> Bool {
        versionSelectorVersions(versions: versions, currentVersion: currentVersion).count > 1
    }

    static func shouldShowAudioValue(version: FileVersion?) -> Bool {
        (version?.audioTracks?.count ?? 0) > 0
    }

    static func shouldEnableAudioSelector(version: FileVersion?) -> Bool {
        (version?.audioTracks?.count ?? 0) > 1
    }

    /// Any file shows the Subtitles row, even one without subtitles: it
    /// reads Off and still opens the subtitle search.
    static func shouldShowSubtitleValue(version: FileVersion?) -> Bool {
        version != nil
    }

    static func shouldEnableSubtitleSelector(version: FileVersion?) -> Bool {
        (version?.subtitleTracks?.count ?? 0) > 1
    }

    // MARK: - Audio

    struct AudioOption: Identifiable, Hashable {
        let ordinal: Int
        let title: String
        let detail: String
        let isSelected: Bool
        var id: Int { ordinal }
    }

    /// The audio track the player will start with: the player's own rule
    /// (Settings language, then English, then the file's default). A picked
    /// index counts only when the file has that track. The server's
    /// remembered track is never used.
    static func resolvedAudioOrdinal(version: FileVersion?, selectedAudioTrackIndex: Int?, preferredLanguage: String = PlayerSettings.shared.audioLanguage) -> Int? {
        guard let tracks = version?.audioTracks, !tracks.isEmpty else { return nil }
        let manual = selectedAudioTrackIndex.flatMap { tracks.indices.contains($0) ? $0 : nil }
        return VividInitialAudioPreference.selectedOrdinal(manual: manual, tracks: tracks, preferredLanguage: preferredLanguage)
    }

    static func audioOptions(version: FileVersion?, selectedAudioTrackIndex: Int?, preferredLanguage: String = PlayerSettings.shared.audioLanguage) -> [AudioOption] {
        guard let version else { return [] }
        let tracks = version.audioTracks ?? []
        let resolved = resolvedAudioOrdinal(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, preferredLanguage: preferredLanguage)
        return tracks.enumerated().map { position, track in
            AudioOption(ordinal: position, title: audioOptionTitle(track, position: position),
                        detail: audioOptionDetail(track, position: position), isSelected: position == resolved)
        }
    }

    /// Language, codec and channels of the track playback starts with. With
    /// `annotateAuto` and no pick it reads "Auto: …".
    static func audioValueLabel(version: FileVersion?, selectedAudioTrackIndex: Int?, annotateAuto: Bool = false, preferredLanguage: String = PlayerSettings.shared.audioLanguage) -> String {
        guard let track = resolvedAudioTrack(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, preferredLanguage: preferredLanguage) else {
            return String(localized: "Unknown")
        }
        var label = joined([
            languageLabel(track.track.language, inAppLanguage: true),
            trimmedText(normalizedAudioCodec(track.track.codec)),
            shortChannelLabel(track.track),
        ])
        if label.isEmpty { label = audioOptionTitle(track.track, position: track.ordinal) }
        if annotateAuto && selectedAudioTrackIndex == nil {
            return String(localized: "Auto: \(label)")
        }
        return label
    }

    /// Codec and channels, space separated, as the hero's badges read.
    static func audioTechnicalSummary(version: FileVersion?, selectedAudioTrackIndex: Int?, preferredLanguage: String = PlayerSettings.shared.audioLanguage) -> String? {
        guard let version,
              let track = resolvedAudioTrack(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, preferredLanguage: preferredLanguage) else {
            return normalizedAudioCodec(version?.codecAudio)
        }
        let codec = normalizedAudioCodec(track.track.codec) ?? normalizedAudioCodec(version.codecAudio)
        return [codec, shortChannelLabel(track.track)].compactMap { $0 }.joined(separator: " ")
    }

    private static func resolvedAudioTrack(version: FileVersion?, selectedAudioTrackIndex: Int?, preferredLanguage: String) -> (track: AudioTrack, ordinal: Int)? {
        guard let version, let tracks = version.audioTracks,
              let ordinal = resolvedAudioOrdinal(version: version, selectedAudioTrackIndex: selectedAudioTrackIndex, preferredLanguage: preferredLanguage),
              tracks.indices.contains(ordinal) else { return nil }
        return (tracks[ordinal], ordinal)
    }

    private static func audioOptionTitle(_ track: AudioTrack, position: Int) -> String {
        languageLabel(track.language, inAppLanguage: true)
            ?? informativeAudioTitle(track)
            ?? String(localized: "Track \(position + 1)")
    }

    private static func audioOptionDetail(_ track: AudioTrack, position: Int) -> String {
        var parts: [String?] = []
        if let title = informativeAudioTitle(track),
           title != audioOptionTitle(track, position: position),
           title != languageLabel(track.language, inAppLanguage: false) {
            parts.append(title)
        }
        parts.append(normalizedAudioCodec(track.codec))
        parts.append(shortChannelLabel(track))
        if track.isDefault == true {
            parts.append(String(localized: "Default", comment: "The file's default track"))
        }
        return joined(parts)
    }

    /// Codec jargon in a title says nothing a person can use, so such
    /// titles are left out.
    private static let audioTitleJargon = ["atsc", "a/52", "ac-3", "e-ac-3", "eac3", "truehd", "dts", "aac", "flac"]

    private static func informativeAudioTitle(_ track: AudioTrack) -> String? {
        guard let title = trimmedText(track.title) ?? trimmedText(track.embeddedTitle) else { return nil }
        let lowered = title.lowercased()
        if audioTitleJargon.contains(where: { lowered.contains($0) }) { return nil }
        return tidiedTitle(title)
    }

    static func shortChannelLabel(_ track: AudioTrack) -> String? {
        if let layout = trimmedText(track.channelLayout) {
            let lowered = layout.lowercased()
            if lowered.contains("atmos") { return "Atmos" }
            if lowered.contains("7.1") { return "7.1" }
            if lowered.contains("5.1") { return "5.1" }
            if lowered.contains("stereo") { return String(localized: "Stereo") }
            return layout
        }
        switch track.channels {
        case 1?: return String(localized: "Mono")
        case 2?: return String(localized: "Stereo")
        case 6?: return "5.1"
        case 8?: return "7.1"
        case let count?: return String(localized: "\(count)ch", comment: "Audio channel count, e.g. 3ch")
        case nil: return nil
        }
    }

    // MARK: - Codecs and names

    static func normalizedVideoCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        let lowered = codec.lowercased()
        if lowered.contains("hevc") || lowered.contains("h265") { return "HEVC" }
        if lowered.contains("av1") { return "AV1" }
        if lowered.contains("avc") || lowered.contains("h264") { return "H.264" }
        return codec.uppercased()
    }

    static func normalizedAudioCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        let lowered = codec.lowercased()
        if lowered.contains("eac3") || lowered.contains("e-ac-3") || lowered.contains("ec-3") { return "EAC3" }
        if lowered.contains("ac3") || lowered.contains("ac-3") { return "AC3" }
        if lowered.contains("aac") { return "AAC" }
        if lowered.contains("mp3") { return "MP3" }
        if lowered.contains("truehd") { return "TrueHD" }
        if lowered.contains("dts") { return "DTS" }
        if lowered.contains("flac") { return "FLAC" }
        return codec.uppercased()
    }

    /// Subtitle format names, used only to spot a title that just repeats
    /// the format.
    static func normalizedSubtitleCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        let lowered = codec.lowercased()
        if lowered == "srt" || lowered.contains("subrip") { return "SRT" }
        if lowered.contains("ass") { return "ASS" }
        if lowered.contains("ssa") { return "SSA" }
        if lowered == "vtt" || lowered.contains("webvtt") { return "WebVTT" }
        if lowered.contains("pgs") || lowered.contains("hdmv") { return "PGS" }
        if lowered.contains("dvd") || lowered.contains("vobsub") { return "VobSub" }
        if lowered.contains("mov_text") || lowered.contains("tx3g") { return "TX3G" }
        return codec.uppercased()
    }

    /// A track title with the common abbreviations written properly.
    static func tidiedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "sdh": return "SDH"
        case "cc": return "CC"
        case "srt", "subrip": return "SubRip"
        case "webvtt", "vtt": return "WebVTT"
        default: return trimmed
        }
    }

    /// A language code or name as a display name, in the app's language or
    /// in English. A value longer than a code is already a name.
    static func languageLabel(_ value: String?, inAppLanguage: Bool) -> String? {
        guard let trimmed = trimmedText(value) else { return nil }
        // Empty pieces are skipped, so a value starting with a separator is
        // judged by its first real piece.
        let pieces: [Substring] = trimmed.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
        let base = pieces.first ?? ""
        if base.count > 3 { return trimmed.capitalized }
        if let key = SubtitleDisplayOrder.canonicalLanguageKey(trimmed) {
            return inAppLanguage
                ? SubtitleDisplayOrder.displayLanguageName(key)
                : SubtitleDisplayOrder.languageDisplayName(key)
        }
        return trimmed.uppercased()
    }

    // MARK: - Text helpers

    /// The text without surrounding whitespace, or nil when nothing is left.
    static func trimmedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The parts that are present, joined with the dot separator.
    static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.joined(separator: separator)
    }
}
