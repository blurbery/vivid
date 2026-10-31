import Foundation

// MARK: - List order and monitoring modes

/// How the Downloads list is sorted. The raw values are saved.
enum DownloadListOrder: String, CaseIterable, Identifiable, Sendable {
    case biggestFirst = "largestFirst"
    case newestFirst = "recentlyAdded"
    case byName = "alphabetical"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .biggestFirst: String(localized: "Largest first")
        case .newestFirst: String(localized: "Recently added")
        case .byName: String(localized: "Name (A–Z)")
        }
    }

    var iconName: String {
        switch self {
        case .biggestFirst: "arrow.down.to.line"
        case .newestFirst: "clock"
        case .byName: "textformat"
        }
    }
}

/// Which episodes series monitoring downloads. The raw values are the
/// server's mode names.
enum MonitoringRule: String, CaseIterable, Sendable {
    case everySeason = "all"
    case upcomingOnly = "future"
    case latestSeasonOnward = "latest_season"
    case chosenSeasons = "specific_seasons"

    var title: String {
        switch self {
        case .everySeason: String(localized: "All Seasons")
        case .upcomingOnly: String(localized: "New Episodes Only")
        case .latestSeasonOnward: String(localized: "Latest Season & Newer")
        case .chosenSeasons: String(localized: "Specific Seasons")
        }
    }
}

// MARK: - Grouped downloads

/// One season of a downloaded series, episodes in episode order.
struct DownloadedSeason: Identifiable, Hashable, Sendable {
    let seasonKey: Int
    let episodes: [DownloadRecord]
    let storedBytes: Int64
    let watchedEpisodes: Int

    var id: Int { seasonKey }
    var episodeTotal: Int { episodes.count }
    var holdsSpecials: Bool { seasonKey <= 0 }
}

/// One downloaded series, seasons in display order.
struct DownloadedSeries: Identifiable, Hashable, Sendable {
    let seriesId: String
    let displayTitle: String
    let artworkHash: String?
    let seasonGroups: [DownloadedSeason]
    let storedBytes: Int64
    let episodeTotal: Int
    let watchedEpisodes: Int
    let hasMonitoring: Bool
    let newestRegistration: Date

    var id: String { seriesId }
    var seasonTotal: Int { seasonGroups.count }
    var everyRecord: [DownloadRecord] { seasonGroups.flatMap(\.episodes) }
    var fullyWatched: Bool { episodeTotal > 0 && watchedEpisodes == episodeTotal }
}

/// One row of the Downloads list: a series or a movie.
enum DownloadShelfEntry: Identifiable, Hashable {
    case show(DownloadedSeries)
    case film(DownloadRecord)

    var id: String {
        switch self {
        case .show(let series): "series:\(series.seriesId)"
        case .film(let record): "movie:\(record.id)"
        }
    }

    var storedBytes: Int64 {
        switch self {
        case .show(let series): series.storedBytes
        case .film(let record): record.fileSize
        }
    }

    var recordIds: [String] {
        switch self {
        case .show(let series): series.everyRecord.map(\.id)
        case .film(let record): [record.id]
        }
    }

    var nameForSorting: String {
        switch self {
        case .show(let series): series.displayTitle
        case .film(let record): record.title ?? record.contentId
        }
    }

    var newestRegistration: Date {
        switch self {
        case .show(let series): series.newestRegistration
        case .film(let record): record.registeredAt
        }
    }
}

/// Where the scope's bytes go.
struct StorageSplit: Hashable, Sendable {
    let seriesBytes: Int64
    let movieBytes: Int64
    let unfinishedBytes: Int64
    let otherBytes: Int64

    var allBytes: Int64 { seriesBytes + movieBytes + unfinishedBytes + otherBytes }
}

extension DownloadEngine {
    /// Grouping and sorting for the Downloads pages, with the watched state,
    /// subscription titles and monitored series passed in.
    enum Shelf {
        /// Records on the device (playable or kept after revocation), newest
        /// registration first.
        static func onDevice(_ records: [DownloadRecord]) -> [DownloadRecord] {
            newestFirst(records.filter { $0.localStatus == .completed || $0.localStatus == .revoked })
        }

        static func newestFirst(_ records: [DownloadRecord]) -> [DownloadRecord] {
            records.sorted { lhs, rhs in
                lhs.registeredAt != rhs.registeredAt ? lhs.registeredAt > rhs.registeredAt : lhs.id < rhs.id
            }
        }

        /// Episode records grouped by series and season. `records` keeps the
        /// newest-first order, so "first" means the newest that qualifies.
        static func series(
            from records: [DownloadRecord],
            isWatched: (DownloadRecord) -> Bool,
            subscriptionTitle: (String) -> String?,
            isMonitored: (String) -> Bool
        ) -> [DownloadedSeries] {
            var order: [String] = []
            var bySeries: [String: [DownloadRecord]] = [:]
            for record in records {
                guard let seriesId = record.seriesId else { continue }
                if bySeries[seriesId] == nil { order.append(seriesId) }
                bySeries[seriesId, default: []].append(record)
            }
            return order.map { seriesId in
                let episodes = bySeries[seriesId] ?? []
                let seasons = seasonGroups(episodes, isWatched: isWatched)
                let title = episodes.lazy.compactMap(\.seriesTitle).first
                    ?? subscriptionTitle(seriesId)
                    ?? episodes.first?.title
                    ?? seriesId
                return DownloadedSeries(
                    seriesId: seriesId,
                    displayTitle: title,
                    artworkHash: episodes.lazy.compactMap(\.posterThumbhash).first,
                    seasonGroups: seasons,
                    storedBytes: seasons.reduce(0) { $0 + $1.storedBytes },
                    episodeTotal: seasons.reduce(0) { $0 + $1.episodeTotal },
                    watchedEpisodes: seasons.reduce(0) { $0 + $1.watchedEpisodes },
                    hasMonitoring: isMonitored(seriesId),
                    newestRegistration: episodes.map(\.registeredAt).max() ?? .distantPast
                )
            }
        }

        /// Seasons above 0 from the highest down, then Specials, also from the
        /// highest number down.
        private static func seasonGroups(_ episodes: [DownloadRecord], isWatched: (DownloadRecord) -> Bool) -> [DownloadedSeason] {
            let bySeason = Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
            let keys = bySeason.keys.sorted { lhs, rhs in
                if (lhs > 0) != (rhs > 0) { return lhs > 0 }
                return lhs > rhs
            }
            return keys.map { key in
                let sorted = (bySeason[key] ?? []).sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
                return DownloadedSeason(
                    seasonKey: key,
                    episodes: sorted,
                    storedBytes: sorted.reduce(0) { $0 + $1.fileSize },
                    watchedEpisodes: sorted.filter(isWatched).count
                )
            }
        }

        static func sorted(_ entries: [DownloadShelfEntry], by order: DownloadListOrder) -> [DownloadShelfEntry] {
            switch order {
            case .biggestFirst:
                entries.sorted { $0.storedBytes > $1.storedBytes }
            case .newestFirst:
                entries.sorted { $0.newestRegistration > $1.newestRegistration }
            case .byName:
                entries.sorted { $0.nameForSorting.localizedCaseInsensitiveCompare($1.nameForSorting) == .orderedAscending }
            }
        }
    }
}
