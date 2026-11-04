import Foundation

/// Caps how many requests run at once. Each `run` waits for a free slot.
actor RequestGate {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        // A finished request hands its slot straight to the next one waiting.
        defer {
            if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

// MARK: - Saved files

/// The matched results, saved per server and profile.
struct StudioNetworkResultsFile: Codable, Sendable {
    let savedAt: Date
    let results: [String: StudioNetworkResult]
    /// How the results were matched. Results saved by an older version are
    /// matched again on the next load instead of waiting for the daily refresh.
    var revision: Int?
    /// True when a trending list didn't load, so the trending lists are read
    /// again an hour on instead of waiting for the daily refresh.
    var missesTrending: Bool?
}

/// Every library title. Reading the library is the slow part, so it's saved
/// on its own and the quicker TMDb matching can run again without it.
struct StudioNetworkIndexFile: Codable, Sendable {
    let savedAt: Date
    let movies: [String: BrowseItem]
    let series: [String: BrowseItem]
    /// Library titles by the brand the server tags them with, in title order.
    var tagged: [String: [BrowseItem]]?
    /// The index revision the tags were read with. An index saved before tags
    /// were read, or before a brand's names changed, is read again.
    var revision: Int?
}

/// Only the movie cards from a saved library index. Decoding this skips the
/// series and every field a poster card doesn't use.
struct StudioNetworkIndexMovieCards: Decodable, Sendable {
    let savedAt: Date
    let movies: [String: SimilarPosterItem]
}

/// The movie and series cards from a saved library index, for Search.
/// Decoding this skips the brand tags' copies of them.
struct StudioNetworkIndexTitles: Decodable, Sendable {
    let movies: [String: BrowseItem]
    let series: [String: BrowseItem]
}

/// Library movies with just what a poster card needs, keyed like the library
/// index. Saved beside it, so a movie page can find the rest of its TMDb
/// collection without searching the server.
struct LibraryMovieLookup: Codable, Sendable {
    struct Movie: Codable, Sendable {
        let card: SimilarPosterItem
        var tmdbId: String?
    }

    let savedAt: Date
    let movies: [Movie]
    /// A TMDb ID or title and year key, to a position in `movies`.
    let keys: [String: Int]

    init(index: [String: BrowseItem], savedAt: Date) {
        self.init(cards: index.mapValues(SimilarPosterItem.init(item:)), savedAt: savedAt)
    }

    init(cards: [String: SimilarPosterItem], savedAt: Date) {
        var movies: [Movie] = []
        var positions: [String: Int] = [:]
        var keys: [String: Int] = [:]
        for (key, card) in cards {
            // A title kept under two keys is stored once.
            let position: Int
            if let existing = positions[card.contentId] {
                position = existing
            } else {
                position = movies.count
                positions[card.contentId] = position
                movies.append(Movie(card: card))
            }
            keys[key] = position
            // Title and year keys are never plain numbers.
            if Int(key) != nil { movies[position].tmdbId = key }
        }
        self.savedAt = savedAt
        self.movies = movies
        self.keys = keys
    }

    /// By TMDb ID first, then by exact title and year from a movie that
    /// doesn't carry a different TMDb ID.
    func movie(tmdbId: Int, titles: [String], year: Int?) -> SimilarPosterItem? {
        if let movie = movie(forKey: String(tmdbId)) { return movie.card }
        guard let year else { return nil }
        for title in titles {
            if let movie = movie(forKey: StudiosNetworksStore.titleKey(title, year: year)), movie.tmdbId == nil {
                return movie.card
            }
        }
        return nil
    }

    private func movie(forKey key: String) -> Movie? {
        guard let position = keys[key], movies.indices.contains(position) else { return nil }
        return movies[position]
    }
}

// MARK: - Library pages

/// A catalogue item with the TMDb ID providers attach, as text or a number.
private struct StudioNetworkIndexedItem: Decodable, Sendable {
    let item: BrowseItem
    let tmdbId: String?

    private enum Keys: String, CodingKey { case tmdbId }

    init(from decoder: Decoder) throws {
        item = try BrowseItem(from: decoder)
        let container = try decoder.container(keyedBy: Keys.self)
        if let text = try? container.decode(String.self, forKey: .tmdbId) {
            tmdbId = text
        } else if let number = try? container.decode(Int.self, forKey: .tmdbId) {
            tmdbId = String(number)
        } else {
            tmdbId = nil
        }
    }
}

private struct StudioNetworkIndexPage: Decodable, Sendable {
    let items: [StudioNetworkIndexedItem]
    let hasMore: Bool?
    /// Asked for on the first page only, so the rest can load together.
    let total: Int?
}

/// Builds one type's library index as its pages arrive.
private struct StudioNetworkIndexBuilder {
    /// Keyed by TMDb ID and by title and year, first title wins.
    private(set) var index: [String: BrowseItem] = [:]
    /// By the brands the server tags each title with.
    private(set) var tagged: [String: [BrowseItem]] = [:]
    /// A title added while reading shifts later pages, so one can arrive
    /// twice. Each is tagged once.
    private var taggedIDs = Set<String>()

    mutating func add(_ page: StudioNetworkIndexPage) {
        for entry in page.items { add(entry) }
    }

    private mutating func add(_ entry: StudioNetworkIndexedItem) {
        let item = entry.item
        var kept = false
        if let id = entry.tmdbId, !id.isEmpty, index[id] == nil {
            index[id] = item
            kept = true
        }
        // Servers that leave provider IDs out of lists still match here.
        if let year = item.year {
            let key = StudiosNetworksStore.titleKey(item.title, year: year)
            if index[key] == nil {
                index[key] = item
                kept = true
            }
        }
        // A title with neither key, or whose keys an earlier title took
        // (such as a second copy of a film), is kept for Search, which reads
        // every title. Nothing looks a title up by this key.
        if !kept { index["c:" + item.contentId] = item }
        // Every title is checked for tags, including those the keys above
        // can't hold.
        let brands = StudiosNetworksStore.tagMatcher.brandIDs(for: item)
        if !brands.isEmpty, taggedIDs.insert(item.contentId).inserted {
            for brand in brands { tagged[brand, default: []].append(item) }
        }
    }
}

extension StudiosNetworksStore {
    /// Library pages read at once after the first page gives the total.
    private nonisolated static let concurrentLibraryPages = 4
    /// 200 per page, the same shape as the app's browse queries.
    private nonisolated static let libraryPageSize = 200
    /// The most pages read of one type, in each pass.
    private nonisolated static let maxLibraryPages = 500

    /// Every library title of one type, keyed by TMDb ID and by title and
    /// year, and by the brands the server tags it with. Runs off the main
    /// actor: building the index folds every library title, which would
    /// stall scrolling during the daily refresh.
    nonisolated static func libraryIndex(
        type: String,
        report: @MainActor (String, Int) -> Void
    ) async throws -> (index: [String: BrowseItem], tagged: [String: [BrowseItem]]) {
        @Sendable func page(_ offset: Int, total: Bool) async throws -> StudioNetworkIndexPage {
            try await VividAPI.shared.catalog(query: [
                "source": "query", "type": type, "offset": String(offset), "limit": String(libraryPageSize),
                "sort": "title", "order": "asc", "match": "all", "include_total": total ? "true" : "false",
            ], as: StudioNetworkIndexPage.self)
        }
        var builder = StudioNetworkIndexBuilder()
        try Task.checkCancellation()
        let first = try await page(0, total: true)
        builder.add(first)
        var offset = first.items.count
        var more = first.hasMore == true && !first.items.isEmpty
        await report(type, offset)

        // With a total and a full first page, the rest load a few at a time
        // and are added in title order. A server that sends smaller pages
        // than asked, or no total, is read one page at a time below.
        if more, first.items.count == libraryPageSize, let total = first.total, total > offset {
            let offsets = Array(stride(from: offset, to: min(total, libraryPageSize * maxLibraryPages), by: libraryPageSize))
            for start in stride(from: 0, to: offsets.count, by: concurrentLibraryPages) {
                try Task.checkCancellation()
                let batch = Array(offsets[start..<min(start + concurrentLibraryPages, offsets.count)])
                let pages = try await withThrowingTaskGroup(of: (Int, StudioNetworkIndexPage).self) { group in
                    for pageOffset in batch {
                        group.addTask { (pageOffset, try await page(pageOffset, total: false)) }
                    }
                    var found: [Int: StudioNetworkIndexPage] = [:]
                    for try await (pageOffset, result) in group { found[pageOffset] = result }
                    return batch.compactMap { found[$0] }
                }
                for result in pages { builder.add(result) }
                guard let lastOffset = batch.last, let last = pages.last else { break }
                offset = lastOffset + last.items.count
                more = last.hasMore == true && !last.items.isEmpty
                await report(type, offset)
                if !more { break }
            }
        }

        // Titles added while reading, or a server without a total.
        for _ in 0..<maxLibraryPages where more {
            try Task.checkCancellation()
            let result = try await page(offset, total: false)
            builder.add(result)
            offset += result.items.count
            more = result.hasMore == true && !result.items.isEmpty
            await report(type, offset)
        }
        return (builder.index, builder.tagged)
    }

    // MARK: TMDb lists

    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// TMDb discover filters for a brand's series and films. Series come from
    /// the network or company, studio films from the company, and network
    /// films from the streaming list, as do a few networks' series.
    nonisolated static func discoverQueries(for brand: StudioNetworkBrand) -> (series: [String: String], movies: [String: String]?) {
        let companies = ([brand.tmdbId] + brand.labelIds).map(String.init).joined(separator: "|")
        let network = ["with_networks": String(brand.tmdbId)]
        let streaming: [String: String]? = brand.watchProviderIds.isEmpty ? nil : [
            "with_watch_providers": brand.watchProviderIds.map(String.init).joined(separator: "|"),
            "watch_region": brand.watchRegion,
            "with_watch_monetization_types": "flatrate",
        ]
        switch brand.kind {
        case .studio:
            return (["with_companies": companies], ["with_companies": companies])
        case .network:
            let series = brand.listsSeriesByWatchProvider ? streaming ?? network : network
            return (series, streaming)
        }
    }

    nonisolated static func moviePages(for brand: StudioNetworkBrand) -> Int {
        brand.kind == .network ? networkMoviePages : pagesPerList
    }

    /// Every brand's lists at once. The request gate, not the brand count,
    /// limits how much reaches TMDb. Any brand's failure throws.
    nonisolated static func brandLists(
        _ brands: [StudioNetworkBrand],
        loaded: @escaping @MainActor () -> Void
    ) async throws -> [String: BrandLists] {
        let today = Date()
        let from = dayFormatter.string(from: Calendar.current.date(byAdding: .month, value: -12, to: today) ?? today)
        let to = dayFormatter.string(from: today)
        let gate = RequestGate(limit: concurrentRequests)
        return try await withThrowingTaskGroup(of: (String, BrandLists).self) { group in
            for brand in brands {
                group.addTask { (brand.id, try await lists(for: brand, from: from, to: to, gate: gate)) }
            }
            var all: [String: BrandLists] = [:]
            for try await (id, found) in group {
                all[id] = found
                await loaded()
            }
            return all
        }
    }

    private nonisolated static func lists(
        for brand: StudioNetworkBrand, from: String, to: String, gate: RequestGate
    ) async throws -> BrandLists {
        let (seriesQuery, movieQuery) = discoverQueries(for: brand)
        let recentSeriesQuery = seriesQuery.merging(["air_date.gte": from, "air_date.lte": to]) { $1 }
        let recentMovieQuery = movieQuery?.merging(["primary_release_date.gte": from, "primary_release_date.lte": to]) { $1 }

        async let logo = logoURL(for: brand, gate: gate)
        async let series = discoverResults("tv", seriesQuery, pages: pagesPerList, gate: gate)
        async let recentSeries = discoverResults("tv", recentSeriesQuery, pages: pagesPerList, gate: gate)
        async let movies = discoverResults("movie", movieQuery, pages: moviePages(for: brand), gate: gate)
        async let recentMovies = discoverResults("movie", recentMovieQuery, pages: pagesPerList, gate: gate)
        return try await BrandLists(logoURL: logo, series: series, recentSeries: recentSeries,
                                    movies: movies, recentMovies: recentMovies)
    }

    private nonisolated static func logoURL(for brand: StudioNetworkBrand, gate: RequestGate) async throws -> URL? {
        guard !brand.usesWordmark else { return nil }
        let kind = brand.kind == .network ? "network" : "company"
        return try await retryingOnce {
            try await gate.run { try await TVTMDbStore.shared.logoURL(kind: kind, id: brand.tmdbId) }
        }
    }

    /// The first `pages` pages of one TMDb discover list, in popularity order.
    /// The first page says how many there are, and the rest load together.
    private nonisolated static func discoverResults(
        _ media: String, _ query: [String: String]?, pages: Int, gate: RequestGate
    ) async throws -> [TVTMDbStore.DiscoverPage.Result] {
        guard let query else { return [] }
        @Sendable func page(_ number: Int) async throws -> TVTMDbStore.DiscoverPage {
            try await retryingOnce {
                try await gate.run { try await TVTMDbStore.shared.discover(media: media, query: query, page: number) }
            }
        }
        let first = try await page(1)
        let last = min(pages, first.totalPages ?? 1)
        guard last > 1 else { return first.results }
        let rest = try await withThrowingTaskGroup(of: (Int, [TVTMDbStore.DiscoverPage.Result]).self) { group in
            for number in 2...last {
                group.addTask { (number, try await page(number).results) }
            }
            var found: [Int: [TVTMDbStore.DiscoverPage.Result]] = [:]
            for try await (number, results) in group { found[number] = results }
            return (2...last).flatMap { found[$0] ?? [] }
        }
        return first.results + rest
    }

    /// This week's trending series and movies, side by side.
    nonisolated static func trendingLists() async -> TrendingLists {
        let gate = RequestGate(limit: concurrentTrendingBlocks)
        async let series = trendingResults("tv", gate: gate)
        async let movies = trendingResults("movie", gate: gate)
        return await TrendingLists(series: series, movies: movies)
    }

    /// One whole trending list, in trending order, or nil when a block fails:
    /// a gap would move the titles after it up. A failed list never fails the
    /// refresh. The rows keep each brand's previous trending titles, and the
    /// trending lists alone are read again an hour on.
    private nonisolated static func trendingResults(
        _ media: String, gate: RequestGate
    ) async -> [TVTMDbStore.DiscoverPage.Result]? {
        @Sendable func block(_ number: Int) async -> [TVTMDbStore.DiscoverPage.Result]? {
            try? await retryingOnce {
                try await gate.run { try await TVTMDbStore.shared.trendingBlock(media: media, block: number).results }
            }
        }
        guard let first = await block(1) else { return nil }
        let rest = await withTaskGroup(
            of: (Int, [TVTMDbStore.DiscoverPage.Result]?).self, returning: [TVTMDbStore.DiscoverPage.Result]?.self
        ) { group in
            for number in 2...trendingBlocks {
                group.addTask { (number, await block(number)) }
            }
            var found: [Int: [TVTMDbStore.DiscoverPage.Result]] = [:]
            for await (number, results) in group {
                guard let results else {
                    // The list is no use with a gap, so the other blocks stop.
                    group.cancelAll()
                    return nil
                }
                found[number] = results
            }
            return (2...trendingBlocks).flatMap { found[$0] ?? [] }
        }
        return rest.map { first + $0 }
    }

    /// Retries a TMDb request once after a short pause, for a dropped
    /// connection or a brief rate limit, then lets the error through.
    private nonisolated static func retryingOnce<T>(_ request: () async throws -> T) async throws -> T {
        do {
            return try await request()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await Task.sleep(for: .seconds(1))
            return try await request()
        }
    }

    // MARK: Disk

    /// The library index runs to tens of megabytes, so files are read and
    /// written off the main actor to keep Home and focus smooth.
    nonisolated static func read<T: Decodable & Sendable>(_ type: T.Type, _ url: URL?) async -> T? {
        await Task.detached(priority: .utility) {
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }.value
    }

    nonisolated static func write<T: Encodable & Sendable>(_ value: T, _ url: URL?) async {
        await Task.detached(priority: .utility) {
            guard let url, let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
