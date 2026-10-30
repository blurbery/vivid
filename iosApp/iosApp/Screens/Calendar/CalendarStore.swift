import CryptoKit
import Foundation
import Observation

/// An episode of a series from the profile's Continue Watching, Watchlist or
/// history that airs soon.
struct UpcomingEpisode: Identifiable, Hashable, Sendable {
    /// Where the series came from, most personal first.
    enum Source: Int, Codable, Comparable, Hashable, Sendable {
        case continueWatching, watchlist, history

        var label: String {
            switch self {
            case .continueWatching: String(localized: "Continue Watching")
            case .watchlist: String(localized: "Watchlist")
            case .history: String(localized: "History")
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
struct TrendingTitle: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, series }

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
///
/// Each series' air dates are kept on the device for that profile, and the
/// list is rebuilt from them and the profile's current series on every visit.
/// So a show added to or taken off the Watchlist shows or goes at once, while
/// only new series and ones that are due are looked up again.
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
    /// How long a series' air dates are kept before it's looked up again. It
    /// still shows while that runs. The relay keeps TVmaze's answers for 6
    /// hours, so sooner would mostly get the same answer.
    nonisolated static let seriesLifetime: TimeInterval = 12 * 60 * 60
    /// A stand-in saved while TVmaze or TMDb was busy is tried again sooner.
    nonisolated static let retryLifetime: TimeInterval = 30 * 60

    private(set) var upcoming: [UpcomingEpisode] = []
    private(set) var trendingSeries: [TrendingTitle] = []
    private(set) var trendingMovies: [TrendingTitle] = []
    var isLoadingUpcoming: Bool { upcomingLoad?.context == context }
    var isLoadingTrending: Bool { trendingLoad?.context == context }
    private(set) var upcomingFailed = false
    private(set) var trendingSeriesFailed = false
    private(set) var trendingMoviesFailed = false
    /// Either Trending list failed, so an empty page can offer a retry.
    var trendingFailed: Bool { trendingSeriesFailed || trendingMoviesFailed }

    /// Each load in flight, with the server and profile it's for. The store
    /// owns it, so switching sub-tabs or leaving the page doesn't cancel it,
    /// and another call waits for it rather than starting a second one. A
    /// server or profile switch cancels it and starts its own.
    private var upcomingLoad: (context: String, task: Task<Void, Never>)?
    private var trendingLoad: (context: String, task: Task<Void, Never>)?
    /// The server and profile the lists and `saved` belong to.
    @ObservationIgnored private var loadedContext: String?
    @ObservationIgnored private var saved = Saved()
    @ObservationIgnored private var savedURL: URL?
    @ObservationIgnored private var trendingLoadedAt: Date?
    private let session = URLSession(configuration: .ephemeral)

    private var context: String { TVTMDbStore.shared.contextKey }

    /// Picks up a server or profile switch: drops the old lists and any load
    /// still on its way, and shows what's saved for the new profile.
    private func prepare(_ context: String) {
        guard loadedContext != context else { return }
        loadedContext = context
        upcomingLoad?.task.cancel()
        upcomingLoad = nil
        trendingLoad?.task.cancel()
        trendingLoad = nil
        savedURL = Self.savedFileURL()
        saved = Self.read(savedURL)
        upcoming = Self.upcoming(for: saved.candidates, saved: saved.series, window: Self.upcomingWindow())
        upcomingFailed = false
        let today = Calendar.current.startOfDay(for: Date())
        trendingSeries = saved.trendingSeries.filter { $0.day >= today }
        trendingMovies = saved.trendingMovies.filter { $0.day >= today }
        trendingLoadedAt = saved.trendingSavedAt
        trendingSeriesFailed = false
        trendingMoviesFailed = false
    }

    // MARK: Upcoming

    func loadUpcoming(force: Bool = false) async {
        let context = context
        prepare(context)
        if let upcomingLoad, upcomingLoad.context == context {
            await upcomingLoad.task.value
            return
        }
        guard TVTMDbStore.shared.isConfigured else { return }
        let task = Task { await fetchUpcoming(context: context, force: force) }
        upcomingLoad = (context, task)
        await task.value
        if upcomingLoad?.task == task { upcomingLoad = nil }
    }

    /// Reads the profile's series on every visit and shows the list from what's
    /// saved straight away, so a series taken off the Watchlist goes at once.
    /// Then looks up the new and due series, or every one when forced.
    private func fetchUpcoming(context: String, force: Bool) async {
        let read: (candidates: [Candidate], failed: Set<UpcomingEpisode.Source>)
        do {
            read = try await Self.candidateSeries()
        } catch {
            guard self.context == context else { return }
            if upcoming.isEmpty { upcomingFailed = true }
            return
        }
        guard self.context == context, !Task.isCancelled else { return }
        let candidates = Self.candidates(read.candidates, carryingOver: saved.candidates, from: read.failed)
        let window = Self.upcomingWindow()
        saved.candidates = candidates
        upcoming = Self.upcoming(for: candidates, saved: saved.series, window: window)
        upcomingFailed = false

        let due = Self.seriesToLookUp(candidates, saved: saved.series, now: Date(), force: force)
        if !due.isEmpty {
            let found = await lookUp(due, context: context)
            guard self.context == context, !Task.isCancelled else { return }
            let now = Date()
            for (contentId, lookup) in found {
                switch lookup {
                case .complete(let series):
                    saved.series[contentId] = series
                case .partial(let series):
                    // Air dates saved before beat a stand-in, which may have
                    // no time or nothing at all, while any are still to come.
                    if saved.series[contentId]?.episodes.contains(where: { window.contains($0.day) }) == true {
                        saved.series[contentId]?.refreshAfter = now.addingTimeInterval(Self.retryLifetime)
                    } else {
                        saved.series[contentId] = series
                    }
                case .failed:
                    break
                }
            }
            upcoming = Self.upcoming(for: candidates, saved: saved.series, window: window)
        }
        // Keeps the file small: a series that's gone and due would be looked
        // up again anyway.
        let current = Set(candidates.map(\.contentId))
        let now = Date()
        saved.series = saved.series.filter { current.contains($0.key) || $0.value.refreshAfter > now }
        save()
    }

    struct Candidate: Codable, Hashable, Sendable {
        let contentId: String
        /// Every list the series is in, so one that fails to load next time
        /// can keep it.
        var sources: Set<UpcomingEpisode.Source>

        init(contentId: String, sources: Set<UpcomingEpisode.Source>) {
            self.contentId = contentId
            self.sources = sources
        }

        /// The most personal list, shown on its rows.
        var source: UpcomingEpisode.Source { sources.min() ?? .history }
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

    /// The profile's series, most personal source first, and the sources that
    /// didn't load. Each source is read on its own, so one that fails still
    /// leaves the others.
    private static func candidateSeries() async throws -> (candidates: [Candidate], failed: Set<UpcomingEpisode.Source>) {
        var order: [String] = []
        var sources: [String: Set<UpcomingEpisode.Source>] = [:]
        func add(_ id: String?, _ source: UpcomingEpisode.Source) {
            guard let id, !id.isEmpty else { return }
            if sources[id] == nil { order.append(id) }
            sources[id, default: []].insert(source)
        }

        // Continue Watching and Next Up, from Home's cache when it has one.
        // Building Home again is slow on Emby, so a miss goes through Home's
        // own fetch, which fills that cache for the next visit and joins a
        // fetch already running.
        var home: SectionsResponse? = ResponseCache.shared.get(CacheKey.homeSections)
        if home == nil { home = try? await StartupContentPrefetcher.fetchHomeSections() }
        var failed: Set<UpcomingEpisode.Source> = home == nil ? [.continueWatching] : []
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
            for item in watchlist.items { add(item.contentId, .watchlist) }
        } else {
            failed.insert(.watchlist)
        }
        if let history = await history {
            for item in history.items {
                add(VividMediaType.isSeries(item.type) ? item.contentId : item.seriesId, .history)
            }
        } else {
            failed.insert(.history)
        }
        guard failed.count < 3 else { throw URLError(.cannotLoadFromNetwork) }
        return (ranked(order.map { Candidate(contentId: $0, sources: sources[$0]!) }), failed)
    }

    /// Most personal source first, keeping each source's own order, up to
    /// `maxSeries`.
    nonisolated private static func ranked(_ candidates: [Candidate]) -> [Candidate] {
        let sorted = candidates.enumerated().sorted {
            $0.element.source == $1.element.source ? $0.offset < $1.offset : $0.element.source < $1.element.source
        }
        return Array(sorted.map(\.element).prefix(maxSeries))
    }

    /// The profile's series, with every series the last list had in a source
    /// that didn't load carried over, so a busy Watchlist or history read
    /// doesn't drop its series. Only the failed sources come over: the ones
    /// that loaded say where each series is now. With every source loaded,
    /// it's the list as it is now, so a series taken off the Watchlist goes at
    /// once.
    nonisolated static func candidates(
        _ current: [Candidate], carryingOver previous: [Candidate], from failed: Set<UpcomingEpisode.Source>
    ) -> [Candidate] {
        guard !failed.isEmpty else { return current }
        var merged = current
        var positions = Dictionary(current.enumerated().map { ($1.contentId, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in previous {
            let kept = candidate.sources.intersection(failed)
            guard !kept.isEmpty else { continue }
            if let position = positions[candidate.contentId] {
                merged[position].sources.formUnion(kept)
            } else {
                positions[candidate.contentId] = merged.count
                merged.append(Candidate(contentId: candidate.contentId, sources: kept))
            }
        }
        return ranked(merged)
    }

    /// What's saved for one series: enough to list it without asking the
    /// server or TVmaze again.
    struct SavedSeries: Codable, Sendable {
        struct Episode: Codable, Sendable {
            let season: Int?
            let number: Int?
            let name: String?
            let day: Date
            let airsAt: Date?
        }

        /// The show itself, by its TVDB, IMDb or TMDb ID or else its name.
        let show: String
        let seriesContentId: String
        let title: String
        let posterUrl: String?
        let posterThumbhash: String?
        /// A few more than are shown, so ones that air while it's saved are
        /// replaced by the next.
        let episodes: [Episode]
        /// When it's looked up again.
        var refreshAfter: Date
    }

    /// The list from the profile's series as they are now and what's saved
    /// for them. A series no longer in Continue Watching, the Watchlist or
    /// history drops out even though its air dates are kept, and each one
    /// shows where it comes from now. A show in two libraries is listed once,
    /// from its most personal source.
    nonisolated static func upcoming(
        for candidates: [Candidate], saved: [String: SavedSeries], window: DateInterval
    ) -> [UpcomingEpisode] {
        var shows = Set<String>()
        var results: [UpcomingEpisode] = []
        for candidate in candidates {
            guard let series = saved[candidate.contentId] else { continue }
            let episodes = series.episodes.filter { window.contains($0.day) }.prefix(maxEpisodesPerSeries)
            guard !episodes.isEmpty, shows.insert(series.show).inserted else { continue }
            results += episodes.map {
                UpcomingEpisode(
                    seriesContentId: series.seriesContentId, seriesTitle: series.title,
                    posterUrl: series.posterUrl, posterThumbhash: series.posterThumbhash,
                    season: $0.season, number: $0.number, name: $0.name, day: $0.day, airsAt: $0.airsAt,
                    source: candidate.source
                )
            }
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

    /// The series with nothing saved yet or that are due, or all of them.
    nonisolated static func seriesToLookUp(
        _ candidates: [Candidate], saved: [String: SavedSeries], now: Date, force: Bool
    ) -> [Candidate] {
        candidates.filter { force || (saved[$0.contentId]?.refreshAfter ?? .distantPast) <= now }
    }

    private static func upcomingWindow() -> DateInterval {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: upcomingDays, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private enum Lookup: Sendable {
        /// Every answer came back, including TVmaze not knowing the show.
        case complete(SavedSeries)
        /// TVmaze or TMDb was busy or unreachable, so this is a stand-in.
        case partial(SavedSeries)
        /// The server's details for the series didn't load.
        case failed
    }

    /// Three series at a time: TVmaze's limit is per address, and every
    /// device shares the relay's.
    private func lookUp(_ candidates: [Candidate], context: String) async -> [String: Lookup] {
        let window = Self.upcomingWindow()
        var found: [String: Lookup] = [:]
        var next = 0
        await withTaskGroup(of: (String, Lookup).self) { group in
            func start() {
                guard next < candidates.count else { return }
                let contentId = candidates[next].contentId
                next += 1
                group.addTask { (contentId, await self.lookUp(contentId, window: window)) }
            }
            for _ in 0..<3 { start() }
            for await (contentId, lookup) in group {
                found[contentId] = lookup
                if self.context == context, !Task.isCancelled { start() }
            }
        }
        return found
    }

    private func lookUp(_ contentId: String, window: DateInterval) async -> Lookup {
        guard let detail = try? await MetadataRequestPool.shared.itemDetail(contentId: contentId) else { return .failed }
        let show = [("tvdb", detail.tvdbId), ("imdb", detail.imdbId), ("tmdb", detail.tmdbId)]
            .first { !($0.1 ?? "").isEmpty }.map { "\($0.0):\($0.1!)" } ?? "title:\(detail.title.lowercased())"
        func series(_ episodes: [SavedSeries.Episode], complete: Bool) -> Lookup {
            let saved = SavedSeries(
                show: show, seriesContentId: detail.contentId, title: detail.title,
                posterUrl: detail.posterUrl, posterThumbhash: detail.posterThumbhash,
                episodes: Array(episodes.prefix(Self.maxEpisodesPerSeries * 2)),
                refreshAfter: Date().addingTimeInterval(complete ? Self.seriesLifetime : Self.retryLifetime)
            )
            return complete ? .complete(saved) : .partial(saved)
        }
        guard VividMediaType.isSeries(detail.type) else { return series([], complete: true) }
        if let status = detail.showStatus?.lowercased(), ["ended", "canceled", "cancelled"].contains(status) {
            return series([], complete: true)
        }

        var tvmazeAnswered = true
        switch await tvmazeID(for: detail) {
        case .found(let showID):
            if let seasons: [TVmazeSeason] = try? await get(Self.tvmazeBase + "shows/\(showID)/seasons") {
                // Only the seasons that overlap the window: a long daily show's
                // whole episode list runs to several megabytes. A day either
                // side covers seasons dated in another time zone.
                let current = seasons.filter { season in
                    guard let premiere = Self.localDay(season.premiereDate) else { return false }
                    let lastDay = Self.localDay(season.endDate)
                    return premiere <= window.end.addingTimeInterval(86_400)
                        && (lastDay.map { $0 >= window.start.addingTimeInterval(-86_400) } ?? true)
                }
                // A season that fails could hold the next episodes, so TMDb's
                // date stands in unless every season loaded.
                var episodes: [SavedSeries.Episode] = []
                var loaded = true
                for season in current.suffix(2) {
                    guard let schedule: [TVmazeEpisode] = try? await get(Self.tvmazeBase + "seasons/\(season.id)/episodes") else {
                        loaded = false
                        break
                    }
                    episodes += schedule.compactMap { item in
                        guard let airing = item.airing, window.contains(airing.day) else { return nil }
                        return SavedSeries.Episode(season: item.season, number: item.number, name: item.name, day: airing.day, airsAt: airing.time)
                    }
                }
                if loaded { return series(episodes, complete: true) }
            }
            tvmazeAnswered = false
        case .none:
            break
        case .unavailable:
            tvmazeAnswered = false
        }

        // Without TVmaze, TMDb knows the next episode's day but not its time.
        guard let tmdbID = Int(detail.tmdbId ?? ""), tmdbID > 0 else { return series([], complete: tvmazeAnswered) }
        let tmdb: TMDbSeries
        do {
            tmdb = try await get(TVTMDbStore.urlRequest("tv/\(tmdbID)", language: VividAppLanguage.tmdbLanguage).url?.absoluteString ?? "")
        } catch RelayError.notFound {
            return series([], complete: tvmazeAnswered)
        } catch {
            return series([], complete: false)
        }
        guard let next = tmdb.next_episode_to_air, let day = Self.localDay(next.air_date), window.contains(day) else {
            return series([], complete: tvmazeAnswered)
        }
        return series(
            [SavedSeries.Episode(season: next.season_number, number: next.episode_number, name: next.name, day: day, airsAt: nil)],
            complete: tvmazeAnswered
        )
    }

    // MARK: TVmaze

    private struct TVmazeShow: Decodable { let id: Int }
    private struct TVmazeSeason: Decodable {
        let id: Int
        let premiereDate: String?
        let endDate: String?
    }
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
    /// Lookups TVmaze had no show for, and when. The relay doesn't cache a
    /// miss, so they're kept for a few days rather than asked again on every
    /// refresh, which would spend the TVmaze limit every device shares.
    private static let tvmazeMissesKey = "vivid.calendar.tvmazeMisses.v1"
    private static let tvmazeMissLifetime: TimeInterval = 3 * 24 * 60 * 60
    private var tvmazeMisses: [String: Date] = (UserDefaults.standard.dictionary(forKey: CalendarStore.tvmazeMissesKey) as? [String: Date] ?? [:])
        .filter { Date().timeIntervalSince($0.value) < CalendarStore.tvmazeMissLifetime }

    private enum TVmazeMatch {
        case found(Int)
        /// No ID to look up by, or TVmaze has no show for it.
        case none
        /// The relay, TVmaze or TMDb was busy or unreachable.
        case unavailable
    }

    private func tvmazeID(for detail: ItemDetail) async -> TVmazeMatch {
        var tvdb = detail.tvdbId.flatMap(Int.init).flatMap { $0 > 0 ? String($0) : nil }
        var imdb = detail.imdbId.flatMap { $0.range(of: "^tt[0-9]{7,10}$", options: .regularExpression) != nil ? $0 : nil }
        if tvdb == nil, imdb == nil, let tmdbID = Int(detail.tmdbId ?? ""), tmdbID > 0 {
            do {
                let ids: TMDbExternalIDs = try await get(TVTMDbStore.relayBase + "tv/\(tmdbID)/external_ids")
                tvdb = ids.tvdb_id.flatMap { $0 > 0 ? String($0) : nil }
                imdb = ids.imdb_id.flatMap { $0.range(of: "^tt[0-9]{7,10}$", options: .regularExpression) != nil ? $0 : nil }
            } catch RelayError.notFound {
            } catch {
                return .unavailable
            }
        }
        for (name, value) in [("thetvdb", tvdb), ("imdb", imdb)] {
            guard let value else { continue }
            let key = "\(name):\(value)"
            if let known = tvmazeIDs[key] { return .found(known) }
            if let missed = tvmazeMisses[key], Date().timeIntervalSince(missed) < Self.tvmazeMissLifetime { continue }
            do {
                let show: TVmazeShow = try await get(Self.tvmazeBase + "lookup/shows?\(name)=\(value)")
                tvmazeIDs[key] = show.id
                UserDefaults.standard.set(tvmazeIDs, forKey: Self.tvmazeIDsKey)
                return .found(show.id)
            } catch RelayError.notFound {
                tvmazeMisses[key] = Date()
                UserDefaults.standard.set(tvmazeMisses, forKey: Self.tvmazeMissesKey)
            } catch {
                // Busy or unreachable: TMDb's date stands in this time.
                return .unavailable
            }
        }
        return .none
    }

    // MARK: Trending

    func loadTrending(force: Bool = false) async {
        let context = context
        prepare(context)
        if let trendingLoad, trendingLoad.context == context {
            await trendingLoad.task.value
            return
        }
        if !force, let trendingLoadedAt, Date().timeIntervalSince(trendingLoadedAt) < 6 * 60 * 60 { return }
        guard TVTMDbStore.shared.isConfigured else { return }
        let task = Task { await fetchTrending(context: context) }
        trendingLoad = (context, task)
        await task.value
        if trendingLoad?.task == task { trendingLoad = nil }
    }

    private func fetchTrending(context: String) async {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: Self.trendingDays, to: start) ?? start
        let from = Self.dayString(start), to = Self.dayString(end)
        async let series = trending(media: "tv", kind: .series, query: ["first_air_date.gte": from, "first_air_date.lte": to])
        async let movies = trending(media: "movie", kind: .movie, query: ["primary_release_date.gte": from, "primary_release_date.lte": to])
        let (seriesResult, moviesResult) = await (series, movies)
        guard self.context == context, !Task.isCancelled else { return }
        if let seriesResult {
            trendingSeries = seriesResult
            saved.trendingSeries = seriesResult
        }
        if let moviesResult {
            trendingMovies = moviesResult
            saved.trendingMovies = moviesResult
        }
        // A list that failed is tried again on the next visit, not in 6 hours.
        trendingSeriesFailed = seriesResult == nil
        trendingMoviesFailed = moviesResult == nil
        if !trendingFailed {
            trendingLoadedAt = Date()
            saved.trendingSavedAt = trendingLoadedAt
        }
        save()
    }

    /// Two pages of the most popular titles in the window. Results without
    /// a poster or a date are left out.
    private func trending(media: String, kind: TrendingTitle.Kind, query: [String: String]) async -> [TrendingTitle]? {
        var titles: [TrendingTitle] = []
        var seen = Set<Int>()
        for page in 1...2 {
            guard let result = try? await TVTMDbStore.shared.discover(media: media, query: query, page: page, localized: true) else {
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

    // MARK: Saved on the device

    /// One profile's Calendar, in the Caches folder, so the system can clear
    /// it when space runs low: which series are in its Continue Watching,
    /// Watchlist and history, their titles, posters and air dates, and
    /// Trending.
    private struct Saved: Codable {
        /// Saved days are local, so another time zone starts again.
        var timeZone = TimeZone.current.identifier
        /// TMDb's episode names and Trending come in Vivid's language, so
        /// another language starts again too. `nil` is English.
        var language = VividAppLanguage.tmdbLanguage
        var candidates: [Candidate] = []
        var series: [String: SavedSeries] = [:]
        var trendingSeries: [TrendingTitle] = []
        var trendingMovies: [TrendingTitle] = []
        var trendingSavedAt: Date?
    }

    /// Reads and writes in order, off the main thread.
    nonisolated private static let files = DispatchQueue(label: "co.vividapp.calendar.saved", qos: .utility)

    /// A folder for each server account, so deleting the account removes
    /// every profile's file.
    nonisolated private static func folder(serverID: String, accountID: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let account = SHA256.hash(data: Data("\(serverID)\n\(accountID)".utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("Vivid/Calendar/v1/\(account)", isDirectory: true)
    }

    nonisolated private static func savedFileURL() -> URL? {
        guard let identity = VividCacheScope.currentIdentity,
              let folder = folder(serverID: identity.serverID, accountID: identity.accountID) else { return nil }
        let scope = VividCacheScope.key(serverID: identity.serverID, accountID: identity.accountID, profileID: identity.profileID)
        return folder.appendingPathComponent(scope + ".json")
    }

    nonisolated private static func read(_ url: URL?) -> Saved {
        guard let url else { return Saved() }
        let data = files.sync { try? Data(contentsOf: url) }
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.timeZone == TimeZone.current.identifier,
              saved.language == VividAppLanguage.tmdbLanguage else { return Saved() }
        return saved
    }

    private func save() {
        guard let url = savedURL, let data = try? JSONEncoder().encode(saved) else { return }
        Self.files.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Removes what the Calendar keeps for every profile of a deleted account.
    nonisolated static func deleteSavedData(serverID: String, accountID: String) {
        guard let folder = folder(serverID: serverID, accountID: accountID) else { return }
        files.async { try? FileManager.default.removeItem(at: folder) }
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
