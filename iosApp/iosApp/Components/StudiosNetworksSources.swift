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

/// Results saved before the library index moved to SQLite, when each brand's
/// grid held full titles. Read once after the update, as IDs, so Home keeps
/// its row while the first load runs; that load matches them again.
struct LegacyStudioNetworkResultsFile: Decodable {
    struct Result: Decodable {
        var logoURL: URL?
        var movies: [BrowseItem]
        var series: [BrowseItem]
        var recentSeries: [BrowseItem]
        var recentMovies: [BrowseItem]
        var trendingSeries: [BrowseItem]?
        var trendingMovies: [BrowseItem]?
        var leftOutOfRows: Set<String>?
        var all: [BrowseItem]
        var matchCount: Int
    }

    let savedAt: Date
    let results: [String: Result]
    var missesTrending: Bool?

    /// Larger files are left: reading one would need the memory this
    /// version saves, and the row comes back once the first load finishes.
    static let largestRead = 64 * 1024 * 1024

    /// The same results, with no revision so they're matched again.
    var current: StudioNetworkResultsFile {
        StudioNetworkResultsFile(savedAt: savedAt, results: results.mapValues { old in
            StudioNetworkResult(
                logoURL: old.logoURL, movies: old.movies, series: old.series,
                recentSeries: old.recentSeries, recentMovies: old.recentMovies,
                trendingSeries: old.trendingSeries, trendingMovies: old.trendingMovies,
                leftOutOfRows: old.leftOutOfRows, allIDs: old.all.map(\.contentId), matchCount: old.matchCount
            )
        }, revision: nil, missesTrending: missesTrending)
    }
}

/// Finds library movies for a movie page's TMDb collection row in the saved
/// library index, so the page never searches the server.
struct LibraryMovieLookup: Sendable {
    let library: StudioLibraryDatabase

    /// By TMDb ID first, then by exact title and year from a movie the server
    /// lists without a TMDb ID.
    func movie(tmdbId: Int, titles: [String], year: Int?) -> SimilarPosterItem? {
        if let found = library.item(media: .movie, key: String(tmdbId)) { return SimilarPosterItem(item: found) }
        guard let year else { return nil }
        for title in titles {
            let key = StudiosNetworksStore.titleKey(title, year: year)
            if let found = library.lookup(media: .movie, key: key), found.tmdbId == nil {
                return SimilarPosterItem(item: found.item)
            }
        }
        return nil
    }
}

// MARK: - Writing saved files

/// A saved file `JSONPieceWriter` can write. Its fields must use the names
/// and shapes its `Codable` conformance reads.
protocol PiecewiseJSONFile: Sendable {
    func writeFields(to writer: inout JSONPieceWriter) throws
}

/// Writes one JSON object to a file a piece at a time, so the whole encoding
/// is never in memory. `JSONEncoder` builds a tree several times the size of
/// its output before writing a byte, which for a large library's index was
/// hundreds of megabytes on top of the index itself: enough for tvOS to
/// close the app partway through the first Studios & Networks load. Each
/// piece here is a couple of hundred entries, written straight to disk, and
/// the file reads back with the same `Codable` types as before.
struct JSONPieceWriter {
    /// Entries encoded at once.
    static let piece = 200

    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var hasField = false

    private init(handle: FileHandle) { self.handle = handle }

    /// Writes the object to a file beside `url` and moves it over `url` once
    /// it's whole, so a reader never sees half a file.
    static func write(to url: URL, _ fields: (inout JSONPieceWriter) throws -> Void) throws {
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            var writer = JSONPieceWriter(handle: handle)
            do {
                try writer.raw("{")
                try fields(&writer)
                try writer.raw("}")
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(partial.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// A field holding one small value, left out when nil as synthesised
    /// `Codable` does.
    mutating func field<T: Encodable>(_ name: String, _ value: T?) throws {
        guard let value else { return }
        try key(name)
        try handle.write(contentsOf: encoder.encode(value))
    }

    /// A field holding a dictionary, written `piece` entries at a time.
    mutating func objectField<V: Encodable>(_ name: String, _ dictionary: [String: V]?, piece: Int = Self.piece) throws {
        guard let dictionary else { return }
        try key(name)
        try raw("{")
        var first = true
        var chunk: [String: V] = [:]
        chunk.reserveCapacity(piece)
        for (entryKey, value) in dictionary {
            chunk[entryKey] = value
            guard chunk.count >= piece else { continue }
            try inner(chunk, first: &first)
            chunk.removeAll(keepingCapacity: true)
        }
        try inner(chunk, first: &first)
        try raw("}")
    }

    private mutating func key(_ name: String) throws {
        if hasField { try raw(",") }
        hasField = true
        try handle.write(contentsOf: encoder.encode(name))
        try raw(":")
    }

    /// A piece's entries without the brackets around them, after a comma
    /// unless they're the first.
    private func inner<T: Encodable>(_ piece: T, first: inout Bool) throws {
        let data = try encoder.encode(piece)
        // An empty piece, `{}` or `[]`, adds nothing.
        guard data.count > 2 else { return }
        if !first { try raw(",") }
        first = false
        try handle.write(contentsOf: data.dropFirst().dropLast())
    }

    private func raw(_ text: String) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}

extension StudioNetworkResultsFile: PiecewiseJSONFile {
    /// One brand at a time.
    func writeFields(to writer: inout JSONPieceWriter) throws {
        try writer.field("savedAt", savedAt)
        try writer.objectField("results", results, piece: 1)
        try writer.field("revision", revision)
        try writer.field("missesTrending", missesTrending)
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

extension StudiosNetworksStore {
    /// Library pages read at once after the first page gives the total.
    private nonisolated static let concurrentLibraryPages = 4
    /// 200 per page, the same shape as the app's browse queries.
    private nonisolated static let libraryPageSize = 200
    /// The most pages read of one type, in each pass: a million titles,
    /// well past any real library, so a server that never says it has no
    /// more can't keep the read going for ever.
    private nonisolated static let maxLibraryPages = 5_000

    /// Reads every library title of one type into `library`, a page at a
    /// time, carrying on from where an earlier read of the same file stopped.
    /// Each page is written with the progress it brings, so memory holds a
    /// few pages at most however large the library is.
    nonisolated static func readLibrary(
        _ media: StudioLibraryDatabase.Media,
        into library: StudioLibraryDatabase,
        report: @MainActor (String, Int) -> Void
    ) async throws {
        let type = media.rawValue
        // One four-hour allowance for the player across the whole read.
        let playerDeadline = Date().addingTimeInterval(playerWaitLimit)
        @Sendable func page(_ offset: Int, total: Bool) async throws -> StudioNetworkIndexPage {
            try await VividAPI.shared.catalog(query: [
                "source": "query", "type": type, "offset": String(offset), "limit": String(libraryPageSize),
                "sort": "title", "order": "asc", "match": "all", "include_total": total ? "true" : "false",
            ], as: StudioNetworkIndexPage.self)
        }
        func save(_ result: StudioNetworkIndexPage, endingAt offset: Int, more: Bool) throws {
            try library.add(result.items.map { StudioLibraryDatabase.Entry(item: $0.item, tmdbId: $0.tmdbId) },
                            media: media, progress: .init(offset: offset, isDone: !more))
        }

        var offset = library.progress(media)?.offset ?? 0
        if library.progress(media)?.isDone == true {
            await report(type, offset)
            return
        }
        try await waitWhilePlayerOpen(until: playerDeadline)
        let first = try await page(offset, total: true)
        offset += first.items.count
        var more = first.hasMore == true && !first.items.isEmpty
        try save(first, endingAt: offset, more: more)
        await report(type, offset)

        // With a total and a full first page, the rest load a few at a time
        // and are added in title order. A server that sends smaller pages
        // than asked, or no total, is read one page at a time below.
        if more, first.items.count == libraryPageSize, let total = first.total, total > offset {
            let offsets = Array(stride(from: offset, to: min(total, offset + libraryPageSize * maxLibraryPages), by: libraryPageSize))
            for start in stride(from: 0, to: offsets.count, by: concurrentLibraryPages) {
                try await waitWhilePlayerOpen(until: playerDeadline)
                let batch = Array(offsets[start..<min(start + concurrentLibraryPages, offsets.count)])
                let pages = try await withThrowingTaskGroup(of: (Int, StudioNetworkIndexPage).self) { group in
                    for pageOffset in batch {
                        group.addTask { (pageOffset, try await page(pageOffset, total: false)) }
                    }
                    var found: [Int: StudioNetworkIndexPage] = [:]
                    for try await (pageOffset, result) in group { found[pageOffset] = result }
                    return batch.compactMap { pageOffset in found[pageOffset].map { (pageOffset, $0) } }
                }
                for (pageOffset, result) in pages {
                    let end = pageOffset + result.items.count
                    let pageHasMore = result.hasMore == true && !result.items.isEmpty
                    try save(result, endingAt: end, more: pageHasMore)
                    offset = end
                    more = pageHasMore
                }
                await report(type, offset)
                if !more { break }
            }
        }

        // Titles added while reading, or a server without a total.
        for _ in 0..<maxLibraryPages where more {
            try await waitWhilePlayerOpen(until: playerDeadline)
            let result = try await page(offset, total: false)
            offset += result.items.count
            more = result.hasMore == true && !result.items.isEmpty
            try save(result, endingAt: offset, more: more)
            await report(type, offset)
        }
    }

    /// How long a library read or matching waits for the player in all,
    /// in case the player's closing was never recorded.
    nonisolated static let playerWaitLimit: TimeInterval = 4 * 60 * 60

    /// Holds the library read and matching while the player is open, so a
    /// large read never adds to what a film is already using, and carries on
    /// within a couple of seconds of it closing, or at `deadline` anyway.
    nonisolated static func waitWhilePlayerOpen(until deadline: Date) async throws {
        try Task.checkCancellation()
        while AppHealthContext.snapshot().playerOpen, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
        }
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

    /// Writes a saved file a piece at a time (see `JSONPieceWriter`).
    nonisolated static func write<T: PiecewiseJSONFile>(_ value: T, _ url: URL?) async {
        await Task.detached(priority: .utility) {
            guard let url else { return }
            try? JSONPieceWriter.write(to: url) { try value.writeFields(to: &$0) }
        }.value
    }

    nonisolated static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
