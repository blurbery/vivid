import Foundation
import TVServices

/// Continue Watching and Next Up rows for Vivid's Top Shelf, shown while its
/// icon is focused on the Home Screen.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let shared = SharedStorage.suite
        let language = shared.string(forKey: SharedStorage.appLanguageKey).flatMap { $0.isEmpty ? nil : $0 }
        if let language {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        // The extension can outlive a language change, so pick the strings every time.
        let strings = Self.stringsBundle(language: language)

        shared.set(ISO8601DateFormatter().string(from: Date()), forKey: SharedStorage.topShelfLastRunAtKey)

        let client = TopShelfServerClient()
        let identity = client.contentIdentity
        guard client.allowsPersonalizedContent else {
            shared.set("profile-selection-required", forKey: SharedStorage.topShelfLastStatusKey)
            return nil
        }

        let query = await client.imageSizeQuery()
        let response: TopShelfSectionsResponse
        do {
            response = try await client.fetchHomeSections(query: query)
        } catch {
            shared.set("fetch-failed: \(error)", forKey: SharedStorage.topShelfLastStatusKey)
            return nil
        }

        let continueWatching = Self.newestFirst(
            response.sections.filter { $0.sectionType == "continue_watching" || $0.sectionType == "in_progress" }
        )
        let nextUp = Self.newestFirst(response.sections.filter { $0.sectionType.contains("next") })

        let posters = client.isNativeServer
            ? TopShelfEpisodePosters()
            : await TopShelfEpisodePosters.lookUp(for: continueWatching + nextUp, client: client, query: query)

        guard client.allowsPersonalizedContent, client.contentIdentity == identity else { return nil }

        let continueTiles = continueWatching.compactMap { Self.tile(for: $0, posters: posters, strings: strings) }
        let nextTiles = nextUp.compactMap { Self.tile(for: $0, posters: posters, strings: strings) }
        var rows: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        if !continueTiles.isEmpty {
            let row = TVTopShelfItemCollection(items: continueTiles)
            row.title = String(localized: "Continue Watching", bundle: strings, comment: "Top Shelf row title")
            rows.append(row)
        }
        if !nextTiles.isEmpty {
            let row = TVTopShelfItemCollection(items: nextTiles)
            row.title = String(localized: "Next Up", bundle: strings, comment: "Top Shelf row title")
            rows.append(row)
        }

        let types = response.sections.map(\.sectionType).joined(separator: ",")
        shared.set(
            "ok: sections=\(response.sections.count) cw=\(continueTiles.count) nu=\(nextTiles.count) types=\(types)",
            forKey: SharedStorage.topShelfLastStatusKey
        )
        return rows.isEmpty ? nil : TVTopShelfSectionedContent(sections: rows)
    }

    /// The rows' items, most recently watched first. Items watched at the
    /// same moment keep their order.
    private static func newestFirst(_ sections: [TopShelfSection]) -> [TopShelfItem] {
        sections
            .flatMap(\.items)
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.progressUpdatedAt ?? ""
                let right = rhs.element.progressUpdatedAt ?? ""
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
    }

    private static func tile(for item: TopShelfItem, posters: TopShelfEpisodePosters, strings: Bundle) -> TVTopShelfSectionedItem? {
        guard let display = URL(string: "vivid://item/\(item.contentId)"),
              let play = URL(string: "vivid://play/\(item.contentId)") else { return nil }

        let tile = TVTopShelfSectionedItem(identifier: item.contentId)
        tile.imageShape = .poster
        if let progress = item.playbackProgress {
            tile.playbackProgress = progress
        }
        tile.displayAction = TVTopShelfAction(url: display)
        tile.playAction = TVTopShelfAction(url: play)

        let isEpisode = item.type == "episode"
        if isEpisode, let seriesTitle = item.seriesTitle, let season = item.seasonNumber, let episode = item.episodeNumber {
            let seasonText = String(season)
            let episodeText = String(episode)
            tile.title = String(
                localized: "\(seriesTitle) · S\(seasonText)E\(episodeText)",
                bundle: strings,
                comment: "Top Shelf episode tile: series name, then season and episode numbers"
            )
        } else {
            tile.title = item.title
        }

        // Without a poster an episode would show its 16:9 still.
        let image = (isEpisode ? posters.poster(for: item) : nil) ?? item.posterUrl
        if let image, let url = URL(string: image) {
            tile.setImageURL(url, for: .screenScale1x)
            tile.setImageURL(url, for: .screenScale2x)
        }
        return tile
    }

    /// The strings for Vivid's chosen language, else the system's.
    private static func stringsBundle(language: String?) -> Bundle {
        let preferences: [String]
        if let language {
            preferences = [language]
        } else {
            preferences = CFPreferencesCopyValue(
                "AppleLanguages" as CFString,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            ) as? [String] ?? []
        }
        guard let localization = Bundle.preferredLocalizations(
                from: Bundle.main.localizations, forPreferences: preferences
              ).first,
              let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}

/// Season posters for Silo episodes, falling back to the series poster.
struct TopShelfEpisodePosters {
    private var seasonPosters: [String: [Int: String]] = [:]
    private var seriesPosters: [String: String] = [:]

    func poster(for item: TopShelfItem) -> String? {
        guard let seriesId = item.seriesId else { return nil }
        if let season = item.seasonNumber, let poster = seasonPosters[seriesId]?[season] {
            return poster
        }
        return seriesPosters[seriesId]
    }

    static func lookUp(for items: [TopShelfItem], client: TopShelfServerClient, query: [String: String]) async -> TopShelfEpisodePosters {
        var seriesIds: [String] = []
        for item in items where item.type == "episode" {
            if let seriesId = item.seriesId, !seriesIds.contains(seriesId) {
                seriesIds.append(seriesId)
            }
        }
        var posters = TopShelfEpisodePosters()
        guard !seriesIds.isEmpty else { return posters }

        await withTaskGroup(of: (String, [TopShelfSeason]).self) { group in
            for seriesId in seriesIds {
                group.addTask {
                    let seasons = (try? await client.seasons(seriesId: seriesId, query: query))?.seasons ?? []
                    return (seriesId, seasons)
                }
            }
            for await (seriesId, seasons) in group {
                for season in seasons {
                    guard let poster = season.posterUrl else { continue }
                    posters.seasonPosters[seriesId, default: [:]][season.seasonNumber] = poster
                }
            }
        }

        let withoutSeasonPosters = seriesIds.filter { posters.seasonPosters[$0]?.isEmpty ?? true }
        guard !withoutSeasonPosters.isEmpty else { return posters }
        await withTaskGroup(of: (String, String?).self) { group in
            for seriesId in withoutSeasonPosters {
                group.addTask {
                    let detail = try? await client.itemDetail(contentId: seriesId, query: query)
                    return (seriesId, detail?.posterUrl)
                }
            }
            for await (seriesId, poster) in group {
                if let poster {
                    posters.seriesPosters[seriesId] = poster
                }
            }
        }
        return posters
    }
}
