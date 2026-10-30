#if !os(tvOS)
import Foundation

/// A token in the hero's facts row. `.text` items get a middle-dot
/// separator between them; `.rating` renders a green check + maturity
/// label; `.chip` renders an outlined uppercase pill (4K / HDR / ATMOS / CC).
enum PhoneHeroFactToken: Hashable {
    case text(String)
    case rating(String)
    case chip(String)
}

/// Builds the eyebrow / source / facts / starring strings shown by the
/// phone hero from an `ItemDetail`. Mirrors `TVHeroMetadata` — the same
/// editorial logic, just exposed under an iOS-only namespace so the
/// tvOS surface doesn't leak across.
enum PhoneHeroMetadata {

    // MARK: - Source row

    static func movieSourceTokens(from detail: ItemDetail) -> [String] {
        if detail.type == "episode" {
            var tokens: [String] = []
            if let label = episodeNumberLabel(from: detail) { tokens.append(label) }
            if let genres = detail.genres, !genres.isEmpty {
                tokens.append(genres.prefix(1).joined(separator: ", "))
            }
            return tokens
        }
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func seriesSourceTokens(from detail: ItemDetail) -> [String] {
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func seasonSourceTokens(from detail: ItemDetail, episodeCount: Int) -> [String] {
        var tokens: [String] = []
        let count = detail.episodeCount ?? episodeCount
        if count > 0 { tokens.append(String(localized: "\(count) Episodes")) }
        if let genres = detail.genres, !genres.isEmpty {
            tokens.append(contentsOf: genres.prefix(2))
        }
        return tokens
    }

    static func contentRatingChip(from detail: ItemDetail) -> String? {
        guard let rating = detail.contentRating?
            .trimmingCharacters(in: .whitespaces), !rating.isEmpty
        else { return nil }
        return rating
    }

    // MARK: - iPad technical row

    /// Year and runtime for the iPad technical row, as Apple TV shows them.
    static func releaseFacts(year: Int?, runtime: Int?) -> [String] {
        var facts: [String] = []
        if let year, year > 0 { facts.append(String(year)) }
        if let runtime, runtime > 0 {
            facts.append(runtime >= 60 ? String(localized: "\(runtime / 60)h \(runtime % 60)m") : String(localized: "\(runtime)m"))
        }
        return facts
    }

    static func isResolutionBadge(_ badge: String) -> Bool {
        if ["4K", "8K", "UHD", "FHD", "HD", "SD"].contains(badge) { return true }
        let digits = badge.hasSuffix("P") ? String(badge.dropLast()) : badge
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Quality badges for the iPad technical row, the same as Apple TV's
    /// (`TVHeroMetadata.sourceBadges`): resolution, dynamic range or codec,
    /// Atmos and CC.
    static func sourceBadges(_ version: FileVersion?, summary: OverlaySummary? = nil) -> [String] {
        var badges: [String] = []
        let resolution = version.flatMap(sourceResolutionLabel) ?? summary?.resolution?.uppercased()
        if let resolution, !resolution.isEmpty {
            badges.append(["2160", "2160P", "4K", "UHD"].contains(resolution) ? "4K"
                : ["4320", "4320P", "8K"].contains(resolution) ? "8K" : resolution)
        }
        // The file's own label stays one badge ("DV P8.1"); summary text is split.
        if let version, version.videoTracks?.isEmpty == false {
            if let video = sourceVideoLabel(version) { badges.append(video.uppercased()) }
        } else if let video = summary?.hdr ?? version.flatMap(sourceVideoLabel) ?? summary?.videoCodec {
            badges.append(contentsOf: video.uppercased().split(separator: " ").map(String.init))
        }
        let tracks = version?.audioTracks ?? []
        let audio = tracks.first(where: { $0.isDefault == true }) ?? tracks.first
        let audioMetadata = [audio?.codec, audio?.channelLayout, audio?.title, audio?.embeddedTitle]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if audioMetadata.contains("atmos") || (tracks.isEmpty && summary?.audio?.lowercased().contains("atmos") == true) {
            badges.append("ATMOS")
        }
        if version?.subtitleTracks?.isEmpty == false || (version?.subtitleTracks == nil && summary?.multiSub == true) {
            badges.append("CC")
        }
        return badges
    }

    /// The file's dynamic range as one label ("DV P8.1", "HDR10"), or its
    /// video codec for SDR.
    private static func sourceVideoLabel(_ version: FileVersion) -> String? {
        PlayerStreamBadges.dynamicRange(version) ?? DetailPlaybackFormatting.normalizedVideoCodec(version.codecVideo)
    }

    private static func sourceResolutionLabel(_ version: FileVersion) -> String? {
        let raw = version.resolution?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.contains("8k") { return "4320P" }
        if raw.contains("4k") || raw.contains("uhd") { return "2160P" }
        // Prefer the file's named tier, which survives cinematic letterbox cropping.
        for tier in [4320, 2160, 1440, 1080, 720, 576, 480] {
            if raw == "\(tier)" || raw == "\(tier)p" { return "\(tier)P" }
        }
        if raw == "fhd" { return "1080P" }
        let dimensions = raw.replacingOccurrences(of: "×", with: "x").split(separator: "x")
        let rawWidth = dimensions.first.flatMap { Int($0) }
        let rawHeight = dimensions.count == 2 ? Int(dimensions[1]) : nil
        let track = version.videoTracks?.first
        let width = track?.width ?? rawWidth ?? 0
        let height = track?.height ?? rawHeight ?? 0
        // Width identifies the standard tier for cropped sources such as 3840×1920.
        let tier: Int?
        if width >= 7680 || height >= 4320 { tier = 4320 }
        else if width >= 3840 || height >= 2160 { tier = 2160 }
        else if width >= 2560 || height >= 1440 { tier = 1440 }
        else if width >= 1920 || height >= 1080 { tier = 1080 }
        else if width >= 1280 || height >= 720 { tier = 720 }
        else if height >= 576 { tier = 576 }
        else if height > 0 { tier = 480 }
        else { tier = nil }
        return tier.map { "\($0)P" }
    }

    // MARK: - Facts row

    static func movieFactsLine(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if detail.type == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(imdbRating(imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail, version: selectedVersion))
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = detail.year, year > 0 { tokens.append(.text(String(year))) }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text(String(localized: "\(count) Seasons")))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(imdbRating(imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail))
        return tokens
    }

    // MARK: - Eyebrow

    static func eyebrow(from detail: ItemDetail) -> String? {
        if detail.type == "episode" {
            if let seriesTitle = detail.seriesTitle?
                .trimmingCharacters(in: .whitespaces), !seriesTitle.isEmpty {
                return seriesTitle
            }
        }
        if let status = detail.status?
            .trimmingCharacters(in: .whitespaces), !status.isEmpty,
           detail.type == "series" {
            switch status.lowercased() {
            case "continuing", "returning series", "returning":
                return String(localized: "Continuing Series")
            case "ended":
                return String(localized: "Complete Series")
            case "in production":
                return String(localized: "New Season Coming")
            default: break
            }
        }
        return nil
    }

    // MARK: - Credits

    static func creditText(from detail: ItemDetail) -> String? {
        if detail.type == "movie" {
            let directors = detail.crew?
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name) ?? []
            guard !directors.isEmpty else { return nil }
            let names = directors.prefix(2).joined(separator: ", ")
            return String(localized: "Directed by \(names)")
        }
        if detail.type == "episode" { return nil }
        guard let cast = detail.cast, !cast.isEmpty else { return nil }
        let names = cast.prefix(3).map(\.name).joined(separator: ", ")
        return String(localized: "Starring \(names)")
    }

    // MARK: - Title parts

    /// Splits "Monarch: Legacy of Monsters" into ("Monarch", "Legacy of
    /// Monsters") so the hero can stack a heavier primary line over a
    /// lighter subtitle.
    static func splitTitle(_ raw: String) -> (primary: String, subtitle: String?) {
        let separators: [String] = [": ", " — ", " – ", " - "]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let head = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !tail.isEmpty {
                    return (head, tail)
                }
            }
        }
        return (raw, nil)
    }

    // MARK: - Helpers

    private static func episodeNumberLabel(from detail: ItemDetail) -> String? {
        let seasonPart: String?
        if let season = detail.seasonNumber {
            seasonPart = season == 0 ? String(localized: "Specials") : String(localized: "Season \(String(season))")
        } else {
            seasonPart = nil
        }
        let episodePart = detail.episodeNumber.flatMap { n in n > 0 ? String(localized: "Episode \(String(n))") : nil }

        switch (seasonPart, episodePart) {
        case let (.some(s), .some(e)): return "\(s) \u{00B7} \(e)"
        case let (.some(s), .none):    return s
        case let (.none, .some(e)):    return e
        case (.none, .none):           return nil
        }
    }

    private static func qualityTokens(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [PhoneHeroFactToken] {
        guard let version = selectedVersion ?? preferredVersion(from: detail) else { return [] }
        var tokens: [PhoneHeroFactToken] = []
        if let res = resolutionLabel(version.resolution) { tokens.append(.chip(res)) }
        if let range = PlayerStreamBadges.dynamicRange(version) { tokens.append(.chip(range)) }
        if let audio = primaryAudioLabel(version: version) { tokens.append(.chip(audio)) }
        if hasSubtitles(version: version) { tokens.append(.chip("CC")) }
        return tokens
    }

    private static func preferredVersion(from detail: ItemDetail) -> FileVersion? {
        guard let versions = detail.versions, !versions.isEmpty else { return nil }
        if let lastId = detail.userData?.lastFileId,
           let lastVersion = versions.first(where: { $0.fileId == lastId }) {
            return lastVersion
        }
        return versions.first
    }

    private static func resolutionLabel(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        if raw.contains("2160") || raw.contains("4k") { return "4K" }
        if raw.contains("1080") { return "HD" }
        if raw.contains("720") { return "HD" }
        if raw.contains("480") { return "SD" }
        return nil
    }

    private static func primaryAudioLabel(version: FileVersion) -> String? {
        let tracks = version.audioTracks ?? []
        let defaultTrack = tracks.first(where: { $0.isDefault == true }) ?? tracks.first
        guard let track = defaultTrack else { return nil }

        if let layout = track.channelLayout?.lowercased() {
            if layout.contains("atmos") { return "ATMOS" }
            if layout.contains("7.1") { return "7.1" }
            if layout.contains("5.1") { return "5.1" }
            if layout.contains("stereo") || layout == "2.0" { return nil }
        }
        if let channels = track.channels {
            switch channels {
            case 8: return "7.1"
            case 6: return "5.1"
            default: return nil
            }
        }
        return nil
    }

    private static func hasSubtitles(version: FileVersion) -> Bool {
        !(version.subtitleTracks ?? []).isEmpty
    }

    static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return String(localized: "\(minutes / 60)h \(minutes % 60)m")
        }
        return String(localized: "\(minutes) min")
    }

    /// "★ 7.4", with the decimal separator of the app's language.
    private static func imdbRating(_ rating: Double) -> String {
        let value = rating.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "★ \(value)")
    }
}
#endif
