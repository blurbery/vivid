import Foundation
import Observation

/// An episode of a series from the profile's Continue Watching, Watchlist or
/// history that airs soon.
struct UpcomingEpisode: Identifiable, Hashable, Sendable {
    /// Where the series came from, most personal first.
    enum Source: Int, Comparable, Hashable, Sendable {
        case continueWatching, watchlist, history

        var label: String {
            switch self {
            case .continueWatching: "Continue Watching"
            case .watchlist: "Watchlist"
            case .history: "History"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let seriesContentId: String
    let seriesTitle: String
    let posterUrl: String?
    let posterThumbhash: String?
    let season: Int?
    let number: Int?
    let name: String?
    /// The local day it airs.
    let day: Date
    /// The exact time, when TVmaze knows it. A streaming drop or a TMDb date
    /// has a day only.
    let airsAt: Date?
    let source: Source

    var id: String { "\(seriesContentId):\(season ?? -1):\(number ?? -1):\(day.timeIntervalSince1970)" }
    var isPremiere: Bool { number == 1 }
}

/// A popular movie or series from TMDb that comes out soon.
struct TrendingTitle: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case movie, series }

    let tmdbId: Int
    let kind: Kind
    let title: String
    let overview: String?
    let posterURL: URL?
    /// The local day it comes out.
    let day: Date

    var id: String { "\(kind.rawValue):\(tmdbId)" }
}

/// Loads the Calendar tab. Upcoming reads the profile's own series from the
/// active server, then their air times from TVmaze through Vivid's relay,
/// falling back to TMDb's next air date. Trending is TMDb's popular upcoming
/// titles. Everything belongs to one server and profile, so a switch drops
/// the old lists and any answer still on its way.
@Observable @MainActor
final class CalendarStore {
    static let shared = CalendarStore()

    /// Vivid's relay, beside TMDb's `TVTMDbStore.relayBase`.
    nonisolated static let tvmazeBase = "https://tmdb.vividapp.co/tvmaze/"
    /// How far ahead Upcoming and Trending look.
    nonisolated static let upcomingDays = 90
    nonisolated static let trendingDays = 60
    /// Enough series for a busy Continue Watching, Watchlist and history.
    nonisolated static let maxSeries = 60
    /// Keeps a daily show from flooding the list.
    nonisolated static let maxEpisodesPerSeries = 6

    private(set) var upcoming: [UpcomingEpisode] = []
    private(set) var trendingSeries: [TrendingTitle] = []
    private(set) var trendingMovies: [TrendingTitle] = []
    var isLoadingUpcoming: Bool { loadingUpcoming == context }
    var isLoadingTrending: Bool { loadingTrending == context }
    private(set) var upcomingFailed = false
    private(set) var trendingFailed = false

    /// The server and profile each load is for, so a switch can start its
    /// own load while an older one finishes and is dropped.
    private var loadingUpcoming: String?
    private var loadingTrending: String?
    private var upcomingContext: String?
    private var upcomingLoadedAt: Date?
    private var trendingContext: String?
    private var trendingLoadedAt: Date?
    private let session = URLSession(configuration: .ephemeral)

    private var context: String { TVTMDbStore.shared.contextKey }

    // MARK: Upcoming

    func loadUpcoming(force: Bool = false) async {
        let context = context
        if upcomingContext != context {
            upcomingContext = context
            upcoming = ResponseCache.shared.get(Self.upcomingCacheKey(context)) ?? []
            upcomingLoadedAt = nil
            upcomingFailed = false
        }
        if !force, let upcomingLoadedAt, Date().timeIntervalSince(upcomingLoadedAt) < 30 * 60 { return }
        guard loadingUpcoming != context, TVTMDbStore.shared.isConfigured else { return }
        loadingUpcoming = context
        defer { if loadingUpcoming == context { loadingUpcoming = nil } }
        do {
            let candidates = try await Self.candidateSeries()
            let episodes = await upcomingEpisodes(for: candidates, context: context)
            guard self.context == context, !Task.isCancelled else { return }
            upcoming = episodes
            upcomingLoadedAt = Date()
            upcomingFailed = false
            ResponseCache.shared.set(episodes, for: Self.upcomingCacheKey(context))
        } catch {
            guard self.context == context else { return }
            if upcoming.isEmpty { upcomingFailed = true }
        }
    }

    private static func upcomingCacheKey(_ context: String) -> String { "calendar:upcoming:\(context)" }

    private struct Candidate: Sendable {
        let contentId: String
        var source: UpcomingEpisode.Source
    }

    /// A catalogue item with the series link `BrowseItem` leaves out.
    private struct CatalogEntry: Decodable, Sendable {
        let contentId: String
        let type: String
        let seriesId: String?
    }

    private struct CatalogPage: Decodable, Sendable {
        let items: [CatalogEntry]
    }

    /// The profile's series, most personal source first. Each source is read
    /// on its own, so one that fails still leaves the others.
    private static func candidateSeries() async throws -> [Candidate] {
        var order: [String] = []
        var sources: [String: UpcomingEpisode.Source] = [:]
        func add(_ id: String?, _ source: UpcomingEpisode.Source) {
            guard let id, !id.isEmpty else { return }
            if let existing = sources[id] {
                if source < existing { sources[id] = source }
            } else {
                sources[id] = source
                order.append(id)
            }
        }

        // Continue Watching and Next Up, from Home's cache when it has one.
        // Building Home again is slow on Emby.
        var home: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        if home == nil { home = try? await VividAPI.shared.homeSections() }
        var anySource = home != nil
        for section in home?.sections ?? [] where ["continue_watching", "next_up"].contains(section.sectionType) {
            for item in section.items {
                add(VividMediaType.isSeries(item.type) ? item.contentId : item.seriesId, .continueWatching)
            }
        }

        async let watchlist = try? VividAPI.shared.catalog(query: [
            "source": "watchlist", "type": "series", "offset": "0", "limit": "200", "include_total": "false",
        ], as: CatalogPage.self)
        async let history = try? VividAPI.shared.catalog(query: [
            "source": "history", "offset": "0", "limit": "150", "include_total": "false",
        ], as: CatalogPage.self)
        if let watchlist = await watchlist {
            anySource = true
            for item in watchlist.items { add(item.contentId, .watchlist) }
        }
        if let history = await history {
            anySource = true
            for item in history.items {
                add(VividMediaType.isSeries(item.type) ? item.contentId : item.seriesId, .history)
            }
        }
        guard anySource else { throw URLError(.cannotLoadFromNetwork) }
        let ranked = order.enumerated().sorted {
            let lhs = sources[$0.element]!, rhs = sources[$1.element]!
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }
        return ranked.prefix(maxSeries).map { Candidate(contentId: $0.element, source: sources[$0.element]!) }
    }

    /// Two or three series at a time: TVmaze's limit is per address, and every
    /// device shares the relay's. A show in two libraries is listed once, from
    /// its most personal source.
    private func upcomingEpisodes(for candidates: [Candidate], context: String) async -> [UpcomingEpisode] {
        let window = Self.upcomingWindow()
        var found: [Int: SeriesEpisodes] = [:]
        var next = 0
        await withTaskGroup(of: (Int, SeriesEpisodes).self) { group in
            func start() {
                guard next < candidates.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await self.episodes(for: candidates[index], window: window)) }
            }
            for _ in 0..<3 { start() }
            for await (index, series) in group {
                found[index] = series
                if self.context == context, !Task.isCancelled { start() }
            }
        }
        var shows = Set<String>()
        var results: [UpcomingEpisode] = []
        for index in candidates.indices {
            guard let series = found[index], !series.episodes.isEmpty, shows.insert(series.show).inserted else { continue }
            results.append(contentsOf: series.episodes)
        }
        return results.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            switch ($0.airsAt, $1.airsAt) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.seriesTitle.localizedStandardCompare($1.seriesTitle) == .orderedAscending
            }
        }
    }

    private static func upcomingWindow() -> DateInterval {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: upcomingDays, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private struct SeriesEpisodes: Sendable {
        /// The show itself, by its TVDB, IMDb or TMDb ID or else its name.
        let show: String
        let episodes: [UpcomingEpisode]
    }

    private func episodes(for candidate: Candidate, window: DateInterval) async -> SeriesEpisodes {
        let none = SeriesEpisodes(show: candidate.contentId, episodes: [])
        guard let detail = try? await MetadataRequestPool.shared.itemDetail(contentId: candidate.contentId),
              VividMediaType.isSeries(detail.type) else { return none }
        if let status = detail.showStatus?.lowercased(), ["ended", "canceled", "cancelled"].contains(status) { return none }
        let show = [("tvdb", detail.tvdbId), ("imdb", detail.imdbId), ("tmdb", detail.tmdbId)]
            .first { !($0.1 ?? "").isEmpty }.map { "\($0.0):\($0.1!)" } ?? "title:\(detail.title.lowercased())"
        func episode(season: Int?, number: Int?, name: String?, day: Date, airsAt: Date?) -> UpcomingEpisode {
            UpcomingEpisode(
                seriesContentId: detail.contentId, seriesTitle: detail.title,
                posterUrl: detail.posterUrl, posterThumbhash: detail.posterThumbhash,
                season: season, number: number, name: name, day: day, airsAt: airsAt, source: candidate.source
            )
        }

        if let showID = await tvmazeID(for: detail),
           let schedule: [TVmazeEpisode] = try? await get(Self.tvmazeBase + "shows/\(showID)/episodes") {
            let upcoming = schedule.compactMap { item -> UpcomingEpisode? in
                guard let airing = item.airing, window.contains(airing.day) else { return nil }
                return episode(season: item.season, number: item.number, name: item.name, day: airing.day, airsAt: airing.time)
            }
            return SeriesEpisodes(show: show, episodes: Array(upcoming.prefix(Self.maxEpisodesPerSeries)))
        }

        // Without TVmaze, TMDb knows the next episode's day but not its time.
        guard let tmdbID = Int(detail.tmdbId ?? ""), tmdbID > 0,
              let series: TMDbSeries = try? await get(TVTMDbStore.relayBase + "tv/\(tmdbID)"),
              let next = series.next_episode_to_air, let day = Self.localDay(next.air_date),
              window.contains(day) else { return SeriesEpisodes(show: show, episodes: []) }
        return SeriesEpisodes(show: show, episodes: [episode(season: next.season_number, number: next.episode_number, name: next.name, day: day, airsAt: nil)])
    }

    // MARK: TVmaze

    private struct TVmazeShow: Decodable { let id: Int }
    private struct TVmazeEpisode: Decodable {
        let season: Int?
        let number: Int?
        let name: String?
        let airdate: String?
        let airtime: String?
        let airstamp: String?

        var airing: (day: Date, time: Date?)? {
            CalendarStore.airing(airdate: airdate, airtime: airtime, airstamp: airstamp)
        }
    }

    private struct TMDbExternalIDs: Decodable { let tvdb_id: Int?; let imdb_id: String? }
    private struct TMDbSeries: Decodable {
        struct Episode: Decodable {
            let air_date: String?
            let season_number: Int?
            let episode_number: Int?
            let name: String?
        }
        let next_episode_to_air: Episode?
    }

    /// TVmaze IDs found before, by TVDB or IMDb ID. They don't change.
    private static let tvmazeIDsKey = "vivid.calendar.tvmazeIDs.v1"
    private var tvmazeIDs: [String: Int] = UserDefaults.standard.dictionary(forKey: CalendarStore.tvmazeIDsKey) as? [String: Int] ?? [:]
    /// Lookups TVmaze had no show for, this session.
    private var tvmazeMisses: Set<String> = []

    private func tvmazeID(for detail: ItemDetail) async -> Int? {
        var tvdb = detail.tvdbId.flatMap(Int.init).flatMap { $0 > 0 ? String($0) : nil }
        var imdb = detail.imdbId.flatMap { $0.range(of: "^tt[0-9]{7,10}$", options: .regularExpression) != nil ? $0 : nil }
        if tvdb == nil, imdb == nil, let tmdbID = Int(detail.tmdbId ?? ""), tmdbID > 0,
           let ids: TMDbExternalIDs = try? await get(TVTMDbStore.relayBase + "tv/\(tmdbID)/external_ids") {
            tvdb = ids.tvdb_id.flatMap { $0 > 0 ? String($0) : nil }
            imdb = ids.imdb_id.flatMap { $0.range(of: "^tt[0-9]{7,10}$", options: .regularExpression) != nil ? $0 : nil }
        }
        for (name, value) in [("thetvdb", tvdb), ("imdb", imdb)] {
            guard let value else { continue }
            let key = "\(name):\(value)"
            if let known = tvmazeIDs[key] { return known }
            if tvmazeMisses.contains(key) { continue }
            do {
                let show: TVmazeShow = try await get(Self.tvmazeBase + "lookup/shows?\(name)=\(value)")
                tvmazeIDs[key] = show.id
                UserDefaults.standard.set(tvmazeIDs, forKey: Self.tvmazeIDsKey)
                return show.id
            } catch RelayError.notFound {
                tvmazeMisses.insert(key)
            } catch {
                // Busy or unreachable: TMDb's date stands in this time.
                return nil
            }
        }
        return nil
    }

    // MARK: Trending

    func loadTrending(force: Bool = false) async {
        let context = context
        if trendingContext != context {
            trendingContext = context
            trendingSeries = []
            trendingMovies = []
            trendingLoadedAt = nil
            trendingFailed = false
        }
        if !force, let trendingLoadedAt, Date().timeIntervalSince(trendingLoadedAt) < 6 * 60 * 60 { return }
        guard loadingTrending != context, TVTMDbStore.shared.isConfigured else { return }
        loadingTrending = context
        defer { if loadingTrending == context { loadingTrending = nil } }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: Self.trendingDays, to: start) ?? start
        let from = Self.dayString(start), to = Self.dayString(end)
        async let series = trending(media: "tv", kind: .series, query: ["first_air_date.gte": from, "first_air_date.lte": to])
        async let movies = trending(media: "movie", kind: .movie, query: ["primary_release_date.gte": from, "primary_release_date.lte": to])
        let (seriesResult, moviesResult) = await (series, movies)
        guard self.context == context, !Task.isCancelled else { return }
        if let seriesResult { trendingSeries = seriesResult }
        if let moviesResult { trendingMovies = moviesResult }
        if seriesResult != nil || moviesResult != nil {
            trendingLoadedAt = Date()
            trendingFailed = false
        } else if trendingSeries.isEmpty, trendingMovies.isEmpty {
            trendingFailed = true
        }
    }

    /// Two pages of the most popular titles in the window, poster or not
    /// left out.
    private func trending(media: String, kind: TrendingTitle.Kind, query: [String: String]) async -> [TrendingTitle]? {
        var titles: [TrendingTitle] = []
        var seen = Set<Int>()
        for page in 1...2 {
            guard let result = try? await TVTMDbStore.shared.discover(media: media, query: query, page: page) else {
                if page == 1 { return nil }
                break
            }
            for item in result.results where seen.insert(item.id).inserted {
                guard let name = item.title ?? item.name, let posterPath = item.posterPath,
                      let day = Self.localDay(item.releaseDate ?? item.firstAirDate) else { continue }
                titles.append(TrendingTitle(
                    tmdbId: item.id, kind: kind, title: name, overview: item.overview,
                    posterURL: URL(string: "https://image.tmdb.org/t/p/w342" + posterPath), day: day
                ))
            }
            if (result.totalPages ?? 1) <= page { break }
        }
        return titles
    }

    // MARK: Requests and dates

    private enum RelayError: Error { case notFound, unavailable }

    private func get<T: Decodable>(_ address: String) async throws -> T {
        guard let url = URL(string: address) else { throw RelayError.unavailable }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw RelayError.notFound }
        guard status == 200, data.count <= 2_000_000 else { throw RelayError.unavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The local day and time a TVmaze episode airs. `airstamp` is UTC, so a
    /// 9 pm US show lands on the next morning in Australia. TVmaze leaves
    /// `airtime` empty for a streaming drop and puts a placeholder time in
    /// `airstamp`, so that keeps the day it lists, with no time.
    nonisolated static func airing(
        airdate: String?, airtime: String?, airstamp: String?, calendar: Calendar = .current
    ) -> (day: Date, time: Date?)? {
        if let airtime, !airtime.isEmpty, let airstamp,
           let time = ISO8601DateFormatter().date(from: airstamp) {
            return (calendar.startOfDay(for: time), time)
        }
        return localDay(airdate, calendar: calendar).map { ($0, nil) }
    }

    /// A "yyyy-MM-dd" date as that day here. Built from its parts, so the day
    /// never shifts in a time zone behind UTC.
    nonisolated static func localDay(_ text: String?, calendar: Calendar = .current) -> Date? {
        guard let parts = text?.split(separator: "-").compactMap({ Int($0) }), parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    nonisolated static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
