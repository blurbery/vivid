import Foundation

/// The year line under a series poster: "2021 - Present" while it's still
/// airing, "2005 - 2017" once it has ended in a later year, otherwise the
/// year alone, as Emby's own apps show it. Other titles show their year.
func posterYearCaption(type: String, year: Int?, showStatus: String?, endDate: String?) -> String? {
    guard let year else { return nil }
    guard type == "series" else { return String(year) }
    let status = showStatus?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    if ["continuing", "returning", "returning series"].contains(status) {
        return String(localized: "\(String(year)) - Present", comment: "Year line under a series poster that is still airing, e.g. 2021 - Present")
    }
    if let endYear = endDate.flatMap({ Int($0.prefix(4)) }), endYear > year {
        return "\(year) - \(endYear)"
    }
    return String(year)
}

extension BrowseItem {
    /// Silo sends the newest aired episode's date; Emby and Jellyfin send the
    /// series' end date.
    var posterYearCaption: String? {
        Vivid.posterYearCaption(type: type, year: year, showStatus: showStatus, endDate: endDate ?? lastAirDate)
    }
}

/// What VoiceOver reads for a poster card.
func mediaCardAccessibilityLabel(title: String, episodeLabel: String?, year: Int?, isWatched: Bool) -> String {
    var parts = [title]
    if let episodeLabel, !episodeLabel.isEmpty { parts.append(episodeLabel) }
    if let year { parts.append(String(year)) }
    if isWatched { parts.append(String(localized: "Watched", comment: "Spoken status of a watched title")) }
    return parts.joined(separator: ", ")
}

/// What VoiceOver reads for an episode in a season rail.
func episodeRailAccessibilityLabel(
    seasonNumber: Int,
    episodeNumber: Int,
    title: String?,
    metadata: String?,
    isCurrent: Bool,
    isPlayed: Bool
) -> String {
    var parts = [EpisodeCardCaption.spokenPosition(season: seasonNumber, episode: episodeNumber)]
    if let title, !title.isEmpty { parts.append(title) }
    if let metadata, !metadata.isEmpty { parts.append(metadata) }
    if isCurrent {
        parts.append(String(localized: "Now viewing", comment: "Spoken status of the episode whose page is open"))
    }
    if isPlayed { parts.append(String(localized: "Watched", comment: "Spoken status of a watched title")) }
    return parts.joined(separator: ", ")
}

/// The episode code and title cards show under episode artwork.
enum EpisodeCardCaption {
    private static func code(season: Int, episode: Int) -> String {
        let seasonText = String(format: "%02ld", season)
        let episodeText = String(format: "%02ld", episode)
        return String(
            localized: "S\(seasonText)E\(episodeText)",
            comment: "Episode code with zero-padded season and episode numbers, e.g. S01E02"
        )
    }

    static func isEpisode(_ item: SectionItem) -> Bool {
        item.type.lowercased() == "episode"
    }

    private static func code(for item: SectionItem) -> String? {
        guard isEpisode(item), let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
        return code(season: season, episode: episode)
    }

    /// The episode's own title, unless it only repeats the series title.
    static func episodeTitle(for item: SectionItem) -> String? {
        guard isEpisode(item) else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let series = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           series.caseInsensitiveCompare(title) == .orderedSame {
            return nil
        }
        return title
    }

    static func line(for item: SectionItem) -> String? {
        let parts = [code(for: item), episodeTitle(for: item)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func accessibilityLabel(for item: SectionItem) -> String? {
        guard isEpisode(item) else { return nil }
        var parts: [String] = []
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append(spokenPosition(season: season, episode: episode))
        }
        if let title = episodeTitle(for: item) { parts.append(title) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    fileprivate static func spokenPosition(season: Int, episode: Int) -> String {
        let episodeText = String(episode)
        if season == 0 {
            return String(
                localized: "Specials, Episode \(episodeText)",
                comment: "Spoken episode position in the specials season"
            )
        }
        let seasonText = String(season)
        return String(localized: "Season \(seasonText), Episode \(episodeText)", comment: "Spoken episode position")
    }
}
