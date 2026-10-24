import Foundation

/// Episode context for card captions. Episode cards are captioned with the
/// series name, so the season/episode code and episode title live on the
/// secondary line ("S01E02 · Pilot") in place of the year. The line is always
/// rendered single-line and tail-truncated so card heights stay uniform
/// across a row.
enum EpisodeCardCaption {
    /// "S01E02" — zero-padded so codes line up across a row.
    static func code(season: Int, episode: Int) -> String {
        let paddedSeason = String(format: "%02d", season)
        let paddedEpisode = String(format: "%02d", episode)
        return String(localized: "S\(paddedSeason)E\(paddedEpisode)", comment: "Episode code with zero-padded season and episode numbers, e.g. S01E02")
    }

    static func isEpisode(_ item: SectionItem) -> Bool {
        item.type.lowercased() == "episode"
    }

    static func code(for item: SectionItem) -> String? {
        guard isEpisode(item),
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return code(season: season, episode: episode)
    }

    /// The episode's own title, or `nil` when it is empty or merely repeats
    /// the series name (some scanners fill unknown titles that way).
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

    /// Secondary caption line: "S01E02 · Pilot". Falls back to whichever part
    /// is available; `nil` for non-episodes.
    static func line(for item: SectionItem) -> String? {
        let parts = [code(for: item), episodeTitle(for: item)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken form for accessibility: "Season 1, Episode 2, Pilot".
    static func accessibilityLabel(for item: SectionItem) -> String? {
        guard isEpisode(item) else { return nil }
        var parts: [String] = []
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append(season == 0
                ? String(localized: "Specials, Episode \(episode)", comment: "Spoken episode position in the specials season")
                : String(localized: "Season \(season), Episode \(episode)", comment: "Spoken episode position"))
        }
        if let title = episodeTitle(for: item) {
            parts.append(title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
