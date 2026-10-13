import Foundation

/// Text for the player's Stream pills: the selected file's dynamic range and
/// the codec of the audio track that's playing.
///
/// The detail screens keep their own labels (`DetailPlaybackFormatting`,
/// `TVDetailHero`, `TVFocusMarquee`), so nothing here changes what they show.
///
/// Where each provider's dynamic-range facts come from:
///
/// | Field on `VideoTrack` | Silo (`/api/v1/watch`)                      | Jellyfin `MediaStream`              | Emby `MediaStream`                           |
/// |-----------------------|---------------------------------------------|-------------------------------------|----------------------------------------------|
/// | `dolbyVision`         | `dolby_vision`, "Profile 8" (number only)   | not mapped                          | not mapped                                   |
/// | `videoRange`          | `video_range`, "DolbyVision", "HDR" or none | not mapped                          | not mapped                                   |
/// | `videoRangeType`      | `video_range_type`                          | `VideoRangeType`                    | from `ExtendedVideoType`, else `VideoRange`  |
/// | `dvProfile`           | `dv_profile`                                | `DvProfile`                         | from `ExtendedVideoSubtype` ("DoviProfile81")|
/// | `dvBlCompatId`        | `dv_bl_compat_id` (left out when 0)         | `DvBlSignalCompatibilityId`         | from `ExtendedVideoSubtype` ("DoviProfile81")|
/// | `hdr10Plus`           | `hdr10_plus`                                | `Hdr10PlusPresentFlag`              | not reported (the type says HDR10+)          |
/// | `colorTransfer`       | `color_transfer`                            | not mapped                          | not mapped                                   |
///
/// `videoRangeType` uses Jellyfin's vocabulary, which Silo shares: `SDR`,
/// `HDR10`, `HDR10Plus`, `HLG`, `DOVI`, `DOVIWithHDR10`, `DOVIWithHDR10Plus`,
/// `DOVIWithSDR`, `DOVIWithHLG`, `DOVIWithEL`, `DOVIWithELHDR10Plus`, plus
/// Jellyfin's `DOVIInvalid` and `Unknown`. The Emby adapter translates
/// `ExtendedVideoType` (`DolbyVision`, `Hdr10`, `Hdr10Plus`, `HyperLogGamma`)
/// into the same words.
///
/// Badge rules, first match wins:
/// - Any video track with Dolby Vision shows "DV P<profile>", or "DV" when the
///   profile isn't known. Profile 8 adds its base-layer compatibility ID
///   ("DV P8.1", "DV P8.2", "DV P8.4"), taken from the compatibility ID, a
///   "Profile 8.1" style label, or the `DOVIWith…` range type. Other profiles
///   show the profile number only ("DV P5", "DV P7"), even though Emby and
///   Jellyfin name profile 7 as 7.6. Jellyfin's `DOVIInvalid` (Dolby Vision
///   signalling outside the spec, played as its base layer) isn't shown as DV.
/// - Otherwise "HDR10+", "HDR10" or "HLG" from the range type, the video
///   range, the HDR10+ flag or the colour transfer (PQ is "HDR10", ARIB
///   STD-B67 is "HLG").
/// - Otherwise "HDR" when the file is HDR but the type is unknown, and no
///   badge for SDR.
enum PlayerStreamBadges {
    static func dynamicRange(_ version: FileVersion) -> String? {
        let tracks = version.videoTracks ?? []
        if let dolbyVision = tracks.first(where: isDolbyVision) {
            return dolbyVisionProfile(dolbyVision).map { "DV P\($0)" } ?? "DV"
        }
        if let type = tracks.lazy.compactMap(hdrType).first {
            return type
        }
        return version.hdr == true ? "HDR" : nil
    }

    /// The codec the Info panel's Audio row shows for this track ("AC3",
    /// "EAC3", "TRUEHD"), so the audio pill and that row always agree.
    static func audioCodec(_ track: PlayerTrack?) -> String? {
        guard let codec = track?.codec, !codec.isEmpty else { return nil }
        return codec.uppercased()
    }

    // MARK: - Dolby Vision

    private static func isDolbyVision(_ track: VideoTrack) -> Bool {
        let rangeType = token(track.videoRangeType)
        if rangeType == "doviinvalid" { return false }
        if nonEmpty(track.dolbyVision) != nil { return true }
        if (track.dvProfile ?? 0) > 0 { return true }
        if rangeType.hasPrefix("dovi") { return true }
        let range = token(track.videoRange)
        return range.contains("dolbyvision") || range.hasPrefix("dovi")
    }

    /// "5", "7", "8.1", or nil when no profile number is known.
    private static func dolbyVisionProfile(_ track: VideoTrack) -> String? {
        let label = parsedProfileLabel(track.dolbyVision)
        guard let profile = track.dvProfile.flatMap({ $0 > 0 ? $0 : nil }) ?? label?.profile else {
            return nil
        }
        guard profile == 8 else { return String(profile) }
        let compatibility = track.dvBlCompatId.flatMap { $0 > 0 ? $0 : nil }
            ?? (label?.profile == 8 ? label?.compatibility : nil)
            ?? compatibilityFromRangeType(track.videoRangeType)
        return compatibility.map { "8.\($0)" } ?? "8"
    }

    /// Reads "Profile 8", "Profile 8.1", "Dolby Vision Profile 8.1 (HDR10)"
    /// or a bare "8.1". Codec strings such as "dvhe.08.06" are ignored, because
    /// their second number is the level, not the compatibility ID.
    private static func parsedProfileLabel(_ raw: String?) -> (profile: Int, compatibility: Int?)? {
        guard var text = nonEmpty(raw)?.lowercased() else { return nil }
        if let marker = text.range(of: "profile") {
            text = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if text.contains(where: { !$0.isNumber && $0 != "." }) {
            return nil
        }
        let parts = text.prefix { $0.isNumber || $0 == "." }
            .split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let profile = Int(first), profile > 0 else { return nil }
        let compatibility = parts.count > 1 ? Int(parts[1]).flatMap { $0 > 0 ? $0 : nil } : nil
        return (profile, compatibility)
    }

    private static func compatibilityFromRangeType(_ raw: String?) -> Int? {
        switch token(raw) {
        case "doviwithhdr10", "doviwithhdr10plus": return 1
        case "doviwithsdr": return 2
        case "doviwithhlg": return 4
        default: return nil
        }
    }

    // MARK: - HDR without Dolby Vision

    private static func hdrType(_ track: VideoTrack) -> String? {
        if track.hdr10Plus == true { return "HDR10+" }
        for value in [token(track.videoRangeType), token(track.videoRange)] {
            if value.contains("hdr10plus") || value.contains("hdr10+") { return "HDR10+" }
            if value == "hdr10" { return "HDR10" }
            if value == "hlg" { return "HLG" }
        }
        let transfer = token(track.colorTransfer)
        if transfer.contains("smpte2084") { return "HDR10" }
        if transfer.contains("aribstdb67") { return "HLG" }
        return nil
    }

    // MARK: - Helpers

    /// Lowercased with spaces, hyphens and underscores removed, so "HDR 10",
    /// "Dolby Vision" and "arib-std-b67" compare as "hdr10", "dolbyvision" and
    /// "aribstdb67".
    private static func token(_ raw: String?) -> String {
        (raw ?? "").lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
