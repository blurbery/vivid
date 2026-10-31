import SwiftUI

#if !os(tvOS)
/// The hero's metadata: source tokens, facts, eyebrow, credit, release facts
/// and quality badges, worked out from the loaded item.
enum MobileHeroRules {
    private static let spacesAndTabs = CharacterSet(charactersIn: " \t")

    static func trimmingSpaces(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: spacesAndTabs), !text.isEmpty else { return nil }
        return text
    }

    static func isBlank(_ text: String?) -> Bool {
        (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Source tokens

    /// Movies and other leaf items: the first two genres as one token. An
    /// episode leads with its position, then its first genre.
    static func movieSourceTokens(_ detail: ItemDetail) -> [String] {
        let genres = detail.genres ?? []
        if detail.type == "episode" {
            var tokens: [String] = []
            if let label = episodePositionLabel(season: detail.seasonNumber, episode: detail.episodeNumber) {
                tokens.append(label)
            }
            if let genre = genres.first {
                tokens.append(genre)
            }
            return tokens
        }
        return genres.isEmpty ? [] : [genres.prefix(2).joined(separator: ", ")]
    }

    static func seriesSourceTokens(_ detail: ItemDetail) -> [String] {
        let genres = detail.genres ?? []
        return genres.isEmpty ? [] : [genres.prefix(2).joined(separator: ", ")]
    }

    /// The episode count, from the item or else the loaded episodes, then
    /// the first two genres.
    static func seasonSourceTokens(_ detail: ItemDetail, liveEpisodeCount: Int) -> [String] {
        var tokens: [String] = []
        let count = detail.episodeCount ?? liveEpisodeCount
        if count > 0 {
            tokens.append(String(localized: "\(count) Episodes"))
        }
        tokens.append(contentsOf: (detail.genres ?? []).prefix(2))
        return tokens
    }

    /// "Season 2 · Episode 5", or whichever half is known.
    static func episodePositionLabel(season: Int?, episode: Int?) -> String? {
        let seasonPart = season.map { number in
            number == 0 ? String(localized: "Specials") : String(localized: "Season \(String(number))")
        }
        let episodePart = episode.flatMap { number in
            number > 0 ? String(localized: "Episode \(String(number))") : nil
        }
        switch (seasonPart, episodePart) {
        case let (season?, episode?): return season + " · " + episode
        case let (season?, nil): return season
        case let (nil, episode?): return episode
        case (nil, nil): return nil
        }
    }

    // MARK: Age rating

    static func ageRating(_ detail: ItemDetail) -> String? {
        trimmingSpaces(detail.contentRating)
    }

    // MARK: Facts line

    static func movieFacts(_ detail: ItemDetail) -> [String] {
        var tokens: [String] = []
        if detail.type == "episode", let aired = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(aired)
        } else if let year = detail.year, year > 0 {
            tokens.append(String(year))
        }
        if let runtime = detail.runtime, runtime > 0 {
            if runtime >= 60 {
                tokens.append(String(localized: "\(runtime / 60)h \(runtime % 60)m"))
            } else {
                tokens.append(String(localized: "\(runtime) min"))
            }
        }
        if let rating = imdbRating(detail) {
            tokens.append(rating)
        }
        return tokens
    }

    static func seriesFacts(_ detail: ItemDetail) -> [String] {
        var tokens: [String] = []
        if let year = detail.year, year > 0 {
            tokens.append(String(year))
        }
        if let seasons = detail.seasonCount, seasons > 0 {
            tokens.append(String(localized: "\(seasons) Seasons"))
        }
        if let rating = imdbRating(detail) {
            tokens.append(rating)
        }
        return tokens
    }

    private static func imdbRating(_ detail: ItemDetail) -> String? {
        guard let rating = detail.ratingImdb else { return nil }
        let value = rating.formatted(.number.precision(.fractionLength(1)))
        return String(localized: "★ \(value)")
    }

    /// The facts, then each genre or label from the source tokens that isn't
    /// already there.
    static func pillTokens(facts: [String], sources: [String]) -> [String] {
        var tokens = facts
        for source in sources {
            for part in source.components(separatedBy: ", ") where !tokens.contains(part) {
                tokens.append(part)
            }
        }
        return tokens
    }

    /// The genres the iPad hero's heading lists after its own tokens.
    static func genreParts(_ sources: [String]) -> [String] {
        sources.flatMap { $0.components(separatedBy: ", ") }
    }

    // MARK: Eyebrow

    static func eyebrow(_ detail: ItemDetail) -> String? {
        if detail.type == "episode", let series = trimmingSpaces(detail.seriesTitle) {
            return series
        }
        guard detail.type == "series", let status = trimmingSpaces(detail.status) else { return nil }
        switch status.lowercased() {
        case "continuing", "returning series", "returning":
            return String(localized: "Continuing Series")
        case "ended":
            return String(localized: "Complete Series")
        case "in production":
            return String(localized: "New Season Coming")
        default:
            return nil
        }
    }

    // MARK: Credit

    static func credit(_ detail: ItemDetail) -> String? {
        switch detail.type {
        case "movie":
            let directors = (detail.crew ?? [])
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name)
            guard !directors.isEmpty else { return nil }
            let names = directors.prefix(2).joined(separator: ", ")
            return String(localized: "Directed by \(names)")
        case "episode":
            return nil
        default:
            let cast = (detail.cast ?? []).map(\.name)
            guard !cast.isEmpty else { return nil }
            let names = cast.prefix(3).joined(separator: ", ")
            return String(localized: "Starring \(names)")
        }
    }

    // MARK: iPad technical row

    static func releaseFacts(year: Int?, runtime: Int?) -> [String] {
        var facts: [String] = []
        if let year, year > 0 {
            facts.append(String(year))
        }
        if let runtime, runtime > 0 {
            if runtime >= 60 {
                facts.append(String(localized: "\(runtime / 60)h \(runtime % 60)m"))
            } else {
                facts.append(String(localized: "\(runtime)m"))
            }
        }
        return facts
    }

    static func qualityBadges(version: FileVersion?, summary: OverlaySummary?) -> [String] {
        var badges: [String] = []

        let resolution = version.flatMap(versionResolution) ?? summary?.resolution?.uppercased()
        if let resolution, !resolution.isEmpty {
            switch resolution {
            case "2160", "2160P", "4K", "UHD": badges.append("4K")
            case "4320", "4320P", "8K": badges.append("8K")
            default: badges.append(resolution)
            }
        }

        if let version, !(version.videoTracks ?? []).isEmpty {
            if let video = versionVideoLabel(version) {
                badges.append(video.uppercased())
            }
        } else {
            // The first value present wins, even a blank one, which then
            // gives no video badge.
            let candidates: [String?] = [summary?.hdr, version.flatMap(versionVideoLabel), summary?.videoCodec]
            if let video = candidates.lazy.compactMap({ $0 }).first {
                badges.append(contentsOf: video.uppercased().split(separator: " ").map(String.init))
            }
        }

        if hasAtmos(version: version, summary: summary) {
            badges.append("ATMOS")
        }

        if let subtitles = version?.subtitleTracks {
            if !subtitles.isEmpty { badges.append("CC") }
        } else if summary?.multiSub == true {
            badges.append("CC")
        }
        return badges
    }

    /// Resolution badges draw filled.
    static func isResolutionBadge(_ badge: String) -> Bool {
        if ["4K", "8K", "UHD", "FHD", "HD", "SD"].contains(badge) { return true }
        let digits = badge.hasSuffix("P") ? String(badge.dropLast()) : badge
        return !digits.isEmpty && digits.allSatisfy(\.isASCIIDigitCharacter)
    }

    private static func versionVideoLabel(_ version: FileVersion) -> String? {
        PlayerStreamBadges.dynamicRange(version) ?? DetailPlaybackFormatting.normalizedVideoCodec(version.codecVideo)
    }

    private static func hasAtmos(version: FileVersion?, summary: OverlaySummary?) -> Bool {
        let tracks = version?.audioTracks ?? []
        if let track = tracks.first(where: { $0.isDefault == true }) ?? tracks.first {
            let text = [track.codec, track.channelLayout, track.title, track.embeddedTitle]
                .compactMap { $0 }
                .joined(separator: " ")
            return text.range(of: "atmos", options: .caseInsensitive) != nil
        }
        return summary?.audio?.range(of: "atmos", options: .caseInsensitive) != nil
    }

    /// The file's height class, such as "1080P", from its resolution text or
    /// its first video track.
    private static func versionResolution(_ version: FileVersion) -> String? {
        let text = (version.resolution ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("8k") { return "4320P" }
        if text.contains("4k") || text.contains("uhd") { return "2160P" }
        for height in ["4320", "2160", "1440", "1080", "720", "576", "480"] where text == height || text == height + "p" {
            return height + "P"
        }
        if text == "fhd" { return "1080P" }

        // Each dimension comes from the first video track when it has one
        // (a 0 counts), otherwise from the text. The text's parts are read as
        // they are, so "1920 x 1080" gives nothing, and a lone number is a
        // width.
        let parts = text.replacingOccurrences(of: "×", with: "x").split(separator: "x")
        let textWidth = parts.first.flatMap { Int($0) }
        let textHeight = parts.count > 1 ? Int(parts[1]) : nil
        let track = version.videoTracks?.first
        let width = track?.width ?? textWidth ?? 0
        let height = track?.height ?? textHeight ?? 0

        let heightClass: Int
        if width >= 7680 || height >= 4320 {
            heightClass = 4320
        } else if width >= 3840 || height >= 2160 {
            heightClass = 2160
        } else if width >= 2560 || height >= 1440 {
            heightClass = 1440
        } else if width >= 1920 || height >= 1080 {
            heightClass = 1080
        } else if width >= 1280 || height >= 720 {
            heightClass = 720
        } else if height >= 576 {
            heightClass = 576
        } else if height > 0 {
            heightClass = 480
        } else {
            return nil
        }
        return String(heightClass) + "P"
    }

    // MARK: Title

    /// Splits "Title: Subtitle" (or a dash) into a main line and a smaller
    /// subtitle. Titles without one stay whole.
    static func splitTitle(_ title: String) -> (main: String, subtitle: String?) {
        for separator in [": ", " \u{2014} ", " – ", " - "] {
            guard let range = title.range(of: separator) else { continue }
            let main = String(title[..<range.lowerBound]).trimmingCharacters(in: spacesAndTabs)
            let subtitle = String(title[range.upperBound...]).trimmingCharacters(in: spacesAndTabs)
            if !main.isEmpty, !subtitle.isEmpty {
                return (main, subtitle)
            }
        }
        return (title, nil)
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool {
        ("0"..."9").contains(self)
    }
}
#endif
