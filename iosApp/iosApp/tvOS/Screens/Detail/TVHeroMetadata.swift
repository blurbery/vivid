#if os(tvOS)
import Foundation

/// Text rules for the Apple TV detail hero: source tokens, facts, credit
/// lines and the quality badges. Everything here is nonisolated, because
/// `sourceBadges` is also checked from tests that run off the main actor.
enum TVHeroMetadata {
    private static let separator = " \u{00B7} "

    // MARK: Source tokens

    /// The older layout's source tokens: an episode's number label, or the
    /// first two genres of anything else.
    static func olderSourceTokens(_ detail: ItemDetail) -> [String] {
        if detail.type == "episode" {
            return episodeNumberLabel(detail).map { [$0] } ?? []
        }
        return genreTokens(detail)
    }

    static func genreTokens(_ detail: ItemDetail) -> [String] {
        Array((detail.genres ?? []).prefix(2))
    }

    /// "Season 2 · Episode 5", "Specials · Episode 1", either part alone, or
    /// nil when the item carries neither number.
    static func episodeNumberLabel(_ detail: ItemDetail) -> String? {
        var parts: [String] = []
        if let season = detail.seasonNumber {
            parts.append(season == 0 ? String(localized: "Specials") : String(localized: "Season \(String(season))"))
        }
        if let episode = detail.episodeNumber, episode > 0 {
            parts.append(String(localized: "Episode \(String(episode))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    static func contentRating(_ detail: ItemDetail) -> String? {
        contentRating(detail.contentRating)
    }

    static func contentRating(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Facts

    /// The older layout's facts: an episode's air date (or the year), then
    /// the runtime.
    static func olderFacts(_ detail: ItemDetail) -> [String] {
        var facts: [String] = []
        if detail.type == "episode", let aired = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            facts.append(aired)
        } else if let year = detail.year, year > 0 {
            facts.append(String(year))
        }
        if let runtime = detail.runtime, runtime > 0 {
            facts.append(runtime >= 60 ? hoursAndMinutes(runtime) : String(localized: "\(runtime) min"))
        }
        return facts
    }

    /// The year and the number of seasons.
    static func seriesFacts(_ detail: ItemDetail) -> [String] {
        var facts: [String] = []
        if let year = detail.year, year > 0 {
            facts.append(String(year))
        }
        if let count = detail.seasonCount, count > 0 {
            facts.append(String(localized: "\(count) Seasons"))
        }
        return facts
    }

    /// The year and runtime at the front of the technical row.
    static func releaseFacts(year: Int?, runtime: Int?) -> [String] {
        var facts: [String] = []
        if let year, year > 0 {
            facts.append(String(year))
        }
        if let runtime, runtime > 0 {
            facts.append(shortRuntime(runtime))
        }
        return facts
    }

    /// "1h 52m" from an hour, otherwise "48m".
    static func shortRuntime(_ minutes: Int) -> String {
        minutes >= 60 ? hoursAndMinutes(minutes) : String(localized: "\(minutes)m")
    }

    static func hoursAndMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        return String(localized: "\(hours)h \(rest)m")
    }

    // MARK: Credit line

    /// Directors for a movie, otherwise the first three cast members.
    static func creditLine(_ detail: ItemDetail) -> String? {
        if detail.type == "movie" {
            let directors = (detail.crew ?? [])
                .filter { ($0.job ?? "").caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name)
            guard !directors.isEmpty else { return nil }
            let names = directors.prefix(2).joined(separator: ", ")
            return String(localized: "Directed by \(names)")
        }
        let cast = (detail.cast ?? []).prefix(3).map(\.name)
        guard !cast.isEmpty else { return nil }
        let names = cast.joined(separator: ", ")
        return String(localized: "Starring \(names)")
    }

    // MARK: Source badges

    /// The quality badges shown for a file: resolution, video, Atmos and
    /// captions. A Dolby Vision file keeps its profile in one badge.
    static func sourceBadges(_ version: FileVersion?, summary: OverlaySummary? = nil) -> [String] {
        var badges: [String] = []

        // The catalogue summary fills in when the file gives no resolution.
        let resolution = version.flatMap(resolutionLabel) ?? summary?.resolution?.uppercased() ?? ""
        if !resolution.isEmpty {
            badges.append(normalisedResolution(resolution))
        }

        if let version, !(version.videoTracks ?? []).isEmpty {
            if let label = videoLabel(version) {
                badges.append(label.uppercased())
            }
        } else {
            // The first value present wins, even a blank one, which then
            // gives no video badge.
            let text = summary?.hdr ?? version.flatMap(videoLabel) ?? summary?.videoCodec
            if let text {
                badges.append(contentsOf: text.uppercased().split(separator: " ").map(String.init))
            }
        }

        if hasAtmos(version, summary: summary) {
            badges.append("ATMOS")
        }

        let subtitleTracks = version?.subtitleTracks
        if let subtitleTracks {
            if !subtitleTracks.isEmpty { badges.append("CC") }
        } else if summary?.multiSub == true {
            badges.append("CC")
        }
        return badges
    }

    private static func normalisedResolution(_ label: String) -> String {
        switch label {
        case "2160", "2160P", "4K", "UHD": "4K"
        case "4320", "4320P", "8K": "8K"
        default: label
        }
    }

    private static func hasAtmos(_ version: FileVersion?, summary: OverlaySummary?) -> Bool {
        let tracks = version?.audioTracks ?? []
        if let track = tracks.first(where: { $0.isDefault == true }) ?? tracks.first {
            let text = [track.codec, track.channelLayout, track.title, track.embeddedTitle]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            return text.contains("atmos")
        }
        return summary?.audio?.range(of: "atmos", options: .caseInsensitive) != nil
    }

    /// The file's resolution as a tier label such as "2160P", read from its
    /// text or, failing that, from its dimensions.
    static func resolutionLabel(_ version: FileVersion) -> String? {
        let text = (version.resolution ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("8k") { return "4320P" }
        if text.contains("4k") || text.contains("uhd") { return "2160P" }
        let bare = text.hasSuffix("p") ? String(text.dropLast()) : text
        if ["4320", "2160", "1440", "1080", "720", "576", "480"].contains(bare) {
            return bare + "P"
        }
        if text == "fhd" { return "1080P" }

        // The parts are read as they are, so "1920 x 1080" gives nothing.
        let parts = text.split(whereSeparator: { $0 == "x" || $0 == "\u{00D7}" })
        let track = version.videoTracks?.first
        let width = track?.width ?? parts.first.flatMap { Int($0) } ?? 0
        let height = track?.height ?? (parts.count == 2 ? Int(parts[1]) : nil) ?? 0

        let tier: Int
        if width >= 7680 || height >= 4320 {
            tier = 4320
        } else if width >= 3840 || height >= 2160 {
            tier = 2160
        } else if width >= 2560 || height >= 1440 {
            tier = 1440
        } else if width >= 1920 || height >= 1080 {
            tier = 1080
        } else if width >= 1280 || height >= 720 {
            tier = 720
        } else if height >= 576 {
            tier = 576
        } else if height > 0 {
            tier = 480
        } else {
            return nil
        }
        return "\(tier)P"
    }

    /// The player's dynamic range label for the file, else its codec.
    static func videoLabel(_ version: FileVersion) -> String? {
        PlayerStreamBadges.dynamicRange(version) ?? DetailPlaybackFormatting.normalizedVideoCodec(version.codecVideo)
    }

    /// Resolution badges are drawn filled.
    static func isResolutionBadge(_ badge: String) -> Bool {
        if ["4K", "8K", "UHD", "FHD", "HD", "SD"].contains(badge) { return true }
        let digits = badge.hasSuffix("P") ? badge.dropLast() : Substring(badge)
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }

    // MARK: Episode counts

    private static let airDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser
    }()

    /// Episodes that have aired by now. Without a readable air date an
    /// episode counts only when it has a file.
    static func releasedEpisodeCount(_ episodes: [EpisodeListItem], now: Date = Date()) -> Int {
        var released = Set<String>()
        for episode in episodes {
            let aired: Bool
            if let raw = episode.airDate, let date = airDateParser.date(from: String(raw.prefix(10))) {
                aired = date <= now
            } else {
                aired = !(episode.files ?? []).isEmpty
            }
            if aired { released.insert(episode.contentId) }
        }
        return released.count
    }

    // MARK: Compact heading

    /// The facts after "Series" in the compact heading: the number of
    /// seasons, or for a single-season series the number of released
    /// episodes.
    static func seriesHeadingFacts(
        detail: ItemDetail,
        seasons: [Season],
        selectedSeason: Season?,
        selectedEpisodes: [EpisodeListItem],
        isLoadingEpisodes: Bool,
        pages: [Int: [EpisodeListItem]]
    ) -> [String] {
        let regular = seasons.filter { $0.seasonNumber > 0 }
        let count = regular.isEmpty ? (detail.seasonCount ?? 0) : regular.count
        let year = detail.year.map { String($0) }
        guard count == 1 else {
            return seriesFacts(detail).filter { $0 != year }
        }
        let number = regular.first?.seasonNumber ?? 1
        let episodes: [EpisodeListItem]?
        if let page = pages[number] {
            episodes = page
        } else if selectedSeason?.seasonNumber == number, !isLoadingEpisodes {
            episodes = selectedEpisodes
        } else {
            episodes = nil
        }
        // Once the season's page is loaded the count shows, even "0 Episodes";
        // before that the fact is just "Episodes".
        let fact = episodes.map { String(localized: "\(releasedEpisodeCount($0)) Episodes") }
            ?? String(localized: "Episodes")
        return [fact].filter { $0 != year }
    }
}
#endif
