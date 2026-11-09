import Foundation

/// One brand's matched library titles. The TMDb lists keep TMDb's popularity
/// order, and the trending lists TMDb's trending order.
struct StudioNetworkResult: Codable, Equatable {
    var logoURL: URL?
    var movies: [BrowseItem] = []
    var series: [BrowseItem] = []
    /// Series with episodes aired in the past 12 months.
    var recentSeries: [BrowseItem] = []
    /// Movies released in the past 12 months.
    var recentMovies: [BrowseItem] = []
    /// The brand's series and movies in this week's TMDb trending lists,
    /// which lead its Popular rows. Nil in results saved before trending was
    /// read.
    var trendingSeries: [BrowseItem]?
    var trendingMovies: [BrowseItem]?
    /// Titles the Popular rows leave out: talk shows, and anime unless the
    /// brand keeps it. All in Your Library still lists them.
    var leftOutOfRows: Set<String>?
    /// The content IDs of every library title the server tags with the
    /// brand, plus every TMDb match, for the All in Your Library grid. It has
    /// no cap, so it holds IDs only: a brand page reads the titles from the
    /// saved library when it opens.
    var allIDs: [String] = []
    /// The titles in `allIDs`. Ranks the automatic picks.
    var matchCount = 0

    var count: Int { matchCount }

    /// Every title the rows can show, for reading poster expiry. The grid's
    /// come from the saved library, which keeps its own.
    var items: [BrowseItem] {
        let popular = movies + series + recentSeries + recentMovies
        let trending = (trendingSeries ?? []) + (trendingMovies ?? [])
        return popular + trending
    }
}

/// What a brand page's grid was read for. See `libraryGridKey(for:)`.
struct StudioLibraryGridKey: Equatable {
    let ids: [String]
    let revision: Int
}

/// Finds a library title by TMDb ID or by title and year.
protocol StudioTitleLookup: Sendable {
    func title(forKey key: String) -> BrowseItem?
}

extension Dictionary: StudioTitleLookup where Key == String, Value == BrowseItem {
    func title(forKey key: String) -> BrowseItem? { self[key] }
}

/// One kind of title in the saved library.
struct StudioLibraryTitles: StudioTitleLookup {
    let library: StudioLibraryDatabase
    let media: StudioLibraryDatabase.Media

    func title(forKey key: String) -> BrowseItem? { library.item(media: media, key: key) }
}

extension StudiosNetworksStore {
    /// One brand's TMDb lists, before they're matched with the library.
    struct BrandLists: Sendable {
        var logoURL: URL?
        var series: [TVTMDbStore.DiscoverPage.Result] = []
        var recentSeries: [TVTMDbStore.DiscoverPage.Result] = []
        var movies: [TVTMDbStore.DiscoverPage.Result] = []
        var recentMovies: [TVTMDbStore.DiscoverPage.Result] = []
    }

    /// This week's worldwide trending series and movies, read once for every
    /// brand. A list is nil when it didn't load whole.
    struct TrendingLists: Sendable {
        var series: [TVTMDbStore.DiscoverPage.Result]?
        var movies: [TVTMDbStore.DiscoverPage.Result]?
        var isComplete: Bool { series != nil && movies != nil }
    }

    /// A trending title matched with the library, keeping TMDb's details so
    /// each brand can leave out what its rows don't show.
    struct TrendingMatch {
        let item: BrowseItem
        let result: TVTMDbStore.DiscoverPage.Result
    }

    /// TMDb's Animation and Talk genres.
    nonisolated static let animationGenre = 16
    nonisolated static let talkGenre = 10767

    // MARK: Picks

    /// The brands with at least six matches, most first, ties in catalogue
    /// order, up to 20.
    static func automaticPicks(counts: [String: Int]) -> [String] {
        typealias Ranked = (position: Int, id: String, count: Int)
        let eligible: [Ranked] = catalogue.enumerated().compactMap { position, brand in
            let count = counts[brand.id] ?? 0
            return count >= minimumCount ? (position, brand.id, count) : nil
        }
        let ranked = eligible.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs.position < rhs.position
        }
        return ranked.prefix(maxPicks).map { $0.id }
    }

    /// Keeps up to 20 eligible chosen brands. A set below six is topped up
    /// with the most-matched brands not already chosen, so Home never shows
    /// a sparse row; six or more are kept exactly as chosen.
    static func filled(_ chosen: [String], counts: [String: Int]) -> [String] {
        let eligible = Array(chosen.filter { (counts[$0] ?? 0) >= minimumCount }.prefix(maxPicks))
        guard eligible.count < minimumPicks else { return eligible }
        let extra = automaticPicks(counts: counts).filter { !eligible.contains($0) }
        return Array((eligible + extra).prefix(minimumPicks))
    }

    // MARK: Page rows

    /// Rows for a brand page, series first for a network and movies first for
    /// a studio. This week's trending titles lead and the brand's popular
    /// titles fill the rest: a network's from the past 12 months, or all time
    /// when fewer than six of those show, and a studio's from all time, as
    /// studios release few films a year. Rows below six titles are left out.
    static func pageRows(for brand: StudioNetworkBrand?, result: StudioNetworkResult) -> [(title: String, items: [BrowseItem])] {
        let isStudio = brand?.kind == .studio
        let leftOut = result.leftOutOfRows ?? []
        func shown(_ items: [BrowseItem]) -> [BrowseItem] {
            items.filter { !leftOut.contains($0.contentId) }
        }
        func popular(recent: [BrowseItem], allTime: [BrowseItem]) -> [BrowseItem] {
            isStudio || shown(recent).count < minimumCount ? allTime : recent
        }
        func row(trending: [BrowseItem]?, popular: [BrowseItem]) -> [BrowseItem] {
            var seen = Set<String>()
            return shown((trending ?? []) + popular).filter { seen.insert($0.contentId).inserted }
        }
        let series = (title: String(localized: "Popular TV Shows"),
                      items: row(trending: result.trendingSeries, popular: popular(recent: result.recentSeries, allTime: result.series)))
        let movies = (title: String(localized: "Popular Movies"),
                      items: row(trending: result.trendingMovies, popular: popular(recent: result.recentMovies, allTime: result.movies)))
        return (isStudio ? [movies, series] : [series, movies])
            .filter { $0.items.count >= minimumCount }
            .map { (title: $0.title, items: Array($0.items.prefix(rowLimit))) }
    }

    // MARK: Library matching

    /// A case, accent and punctuation insensitive key for title and year.
    nonisolated static func titleKey(_ title: String, year: Int) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let letters = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        return "t:\(letters)|\(year)"
    }

    /// TMDb ID first, then exact title and year. Allowing a year either side
    /// matched unrelated titles sharing a name in large libraries.
    nonisolated static func lookup(_ result: TVTMDbStore.DiscoverPage.Result, in index: some StudioTitleLookup) -> BrowseItem? {
        if let item = index.title(forKey: String(result.id)) { return item }
        guard let title = result.title ?? result.name,
              let date = result.releaseDate ?? result.firstAirDate,
              let year = Int(date.prefix(4)) else { return nil }
        return index.title(forKey: titleKey(title, year: year))
    }

    /// Library matches for one TMDb list, in its order, each title once.
    nonisolated static func matches(
        _ results: [TVTMDbStore.DiscoverPage.Result],
        _ index: some StudioTitleLookup
    ) -> [(item: BrowseItem, popularity: Double)] {
        var seen = Set<String>()
        return results.compactMap { result in
            guard let item = lookup(result, in: index), seen.insert(item.contentId).inserted else { return nil }
            return (item, result.popularity ?? 0)
        }
    }

    /// Library matches for a whole trending list, in trending order. The list
    /// runs to about 10,000 titles, so it's matched once for every brand.
    nonisolated static func trendingMatches(
        _ results: [TVTMDbStore.DiscoverPage.Result], _ index: some StudioTitleLookup
    ) -> [TrendingMatch] {
        var seen = Set<String>()
        return results.compactMap { result in
            guard let item = lookup(result, in: index), seen.insert(item.contentId).inserted else { return nil }
            return TrendingMatch(item: item, result: result)
        }
    }

    /// A brand's trending titles for a Popular row. The trending list has no
    /// brand filter, so a title counts when it's one of the brand's library
    /// titles: anything All in Your Library lists, or a recent match.
    nonisolated static func trendingTitles(
        _ matches: [TrendingMatch], brandTitles: Set<String>, keepsAnime: Bool
    ) -> [BrowseItem] {
        Array(matches.lazy
            .filter { brandTitles.contains($0.item.contentId) && showsInPopularRows($0.result, keepsAnime: keepsAnime) }
            .prefix(rowLimit)
            .map(\.item))
    }

    /// Whether a title belongs in a Popular row. Talk shows never do, and
    /// anime (Japanese animation, by original language or country of origin)
    /// only on a brand that keeps it.
    nonisolated static func showsInPopularRows(_ result: TVTMDbStore.DiscoverPage.Result, keepsAnime: Bool) -> Bool {
        let genres = result.genreIds ?? []
        if genres.contains(talkGenre) { return false }
        guard !keepsAnime, genres.contains(animationGenre) else { return true }
        return result.originalLanguage != "ja" && !(result.originCountry ?? []).contains("JP")
    }

    /// All in Your Library: every title the server tags with the brand, then
    /// the TMDb matches it doesn't, each title once. TMDb is the only source
    /// of a network's films, and finds a studio's films a server lists
    /// without the studio.
    nonisolated static func libraryTitles(tagged: [String], matched: [String]) -> [String] {
        var seen = Set<String>()
        return (tagged + matched).filter { seen.insert($0).inserted }
    }

    /// Matches every brand's lists with the library, off the main actor so
    /// matching never competes with drawing.
    nonisolated static func matched(
        _ lists: [String: BrandLists], trending: TrendingLists, previous: [String: StudioNetworkResult],
        library: StudioLibraryDatabase
    ) async -> [String: StudioNetworkResult] {
        await Task.detached(priority: .utility) {
            let movies = StudioLibraryTitles(library: library, media: .movie)
            let series = StudioLibraryTitles(library: library, media: .series)
            let trendingSeries = trending.series.map { trendingMatches($0, series) }
            let trendingMovies = trending.movies.map { trendingMatches($0, movies) }
            return Dictionary(uniqueKeysWithValues: lists.map { id, brandLists in
                (id, result(for: brandLists, trendingSeries: trendingSeries, trendingMovies: trendingMovies,
                            previous: previous[id], keepsAnime: keepsAnime(id), movieIndex: movies,
                            seriesIndex: series, tagged: library.taggedIDs(brand: id)))
            })
        }.value
    }

    /// The saved results with freshly read trending titles. A brand's titles
    /// are the ones its saved results list.
    nonisolated static func withTrending(
        _ trending: TrendingLists, in results: [String: StudioNetworkResult], library: StudioLibraryDatabase
    ) async -> [String: StudioNetworkResult] {
        await Task.detached(priority: .utility) {
            guard let series = trending.series, let movies = trending.movies else { return results }
            let seriesMatches = trendingMatches(series, StudioLibraryTitles(library: library, media: .series))
            let movieMatches = trendingMatches(movies, StudioLibraryTitles(library: library, media: .movie))
            var updated = results
            for (id, saved) in results {
                let titles = brandTitles(of: saved)
                let keepsAnime = Self.keepsAnime(id)
                updated[id]?.trendingSeries = trendingTitles(seriesMatches, brandTitles: titles, keepsAnime: keepsAnime)
                updated[id]?.trendingMovies = trendingTitles(movieMatches, brandTitles: titles, keepsAnime: keepsAnime)
            }
            return updated
        }.value
    }

    /// One brand's matched lists. A trending list that didn't load keeps the
    /// brand's trending titles from `previous`.
    private nonisolated static func result(
        for lists: BrandLists, trendingSeries: [TrendingMatch]?, trendingMovies: [TrendingMatch]?,
        previous: StudioNetworkResult?, keepsAnime: Bool,
        movieIndex: some StudioTitleLookup, seriesIndex: some StudioTitleLookup, tagged: [String]
    ) -> StudioNetworkResult {
        let series = matches(lists.series, seriesIndex).map(\.item)
        let movies = matches(lists.movies, movieIndex).map(\.item)
        let recentSeries = matches(lists.recentSeries, seriesIndex).map(\.item)
        let recentMovies = matches(lists.recentMovies, movieIndex).map(\.item)
        let all = libraryTitles(tagged: tagged, matched: (movies + series).map(\.contentId))
        let brandTitles = Set(all + (recentSeries + recentMovies).map(\.contentId))
        func leftOut(_ results: [TVTMDbStore.DiscoverPage.Result], _ index: some StudioTitleLookup) -> [String] {
            matches(results.filter { !showsInPopularRows($0, keepsAnime: keepsAnime) }, index).map(\.item.contentId)
        }
        let leftOutOfRows = leftOut(lists.series + lists.recentSeries, seriesIndex)
            + leftOut(lists.movies + lists.recentMovies, movieIndex)
        return StudioNetworkResult(
            logoURL: lists.logoURL,
            movies: movies,
            series: series,
            recentSeries: recentSeries,
            recentMovies: recentMovies,
            trendingSeries: trendingSeries.map { trendingTitles($0, brandTitles: brandTitles, keepsAnime: keepsAnime) }
                ?? previous?.trendingSeries,
            trendingMovies: trendingMovies.map { trendingTitles($0, brandTitles: brandTitles, keepsAnime: keepsAnime) }
                ?? previous?.trendingMovies,
            leftOutOfRows: Set(leftOutOfRows),
            allIDs: all,
            matchCount: all.count
        )
    }

    private nonisolated static func brandTitles(of result: StudioNetworkResult) -> Set<String> {
        Set(result.allIDs + (result.recentSeries + result.recentMovies).map(\.contentId))
    }

    private nonisolated static func keepsAnime(_ id: String) -> Bool {
        catalogue.first { $0.id == id }?.keepsAnime ?? false
    }

    // MARK: Poster links

    /// The results with every title replaced by its entry from a fresh
    /// library read, which carries current artwork. Titles no longer in the
    /// library drop out, so an expired link can't linger, and the match count
    /// follows, so a brand that falls below six leaves Home. All in Your
    /// Library takes the fresh server tags, so titles added since the daily
    /// refresh show without asking TMDb again.
    nonisolated static func replacingArtwork(
        in results: [String: StudioNetworkResult],
        with current: [String: BrowseItem],
        tagged: [String: [String]]
    ) -> [String: StudioNetworkResult] {
        func refreshed(_ items: [BrowseItem]) -> [BrowseItem] { items.compactMap { current[$0.contentId] } }
        var updated = results
        for (id, saved) in results {
            var result = saved
            result.movies = refreshed(saved.movies)
            result.series = refreshed(saved.series)
            result.recentSeries = refreshed(saved.recentSeries)
            result.recentMovies = refreshed(saved.recentMovies)
            result.trendingSeries = saved.trendingSeries.map(refreshed)
            result.trendingMovies = saved.trendingMovies.map(refreshed)
            result.allIDs = libraryTitles(tagged: tagged[id] ?? [], matched: (result.movies + result.series).map(\.contentId))
            result.matchCount = result.allIDs.count
            updated[id] = result
        }
        return updated
    }

    /// The earliest expiry among signed poster links, or nil when none has one.
    nonisolated static func artworkExpiry(of items: some Sequence<BrowseItem>) -> Date? {
        var earliest: Date?
        var seen = Set<String>()
        for item in items {
            guard let url = item.posterUrl, seen.insert(url).inserted,
                  let expiry = SiloAPICompatibility.artworkExpiry(url) else { continue }
            earliest = min(earliest ?? expiry, expiry)
        }
        return earliest
    }

    /// Links without an expiry (Emby, Jellyfin, unsigned) never lapse.
    nonisolated static func artworkHasLapsed(expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < artworkRefreshLead
    }

    nonisolated static func artworkExpiry(in results: [String: StudioNetworkResult]) async -> Date? {
        await Task.detached(priority: .utility) {
            artworkExpiry(of: results.values.lazy.flatMap(\.items))
        }.value
    }
}
