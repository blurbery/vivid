import Foundation
import Observation

/// TMDb requests never follow a redirect.
private final class TMDbRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Answers kept for a while, keyed by context and title. A full cache is
/// emptied before the next answer goes in.
private struct TimedCache<Value> {
    let lifetime: TimeInterval
    let limit: Int
    private var entries: [String: (savedAt: Date, value: Value)] = [:]

    init(lifetime: TimeInterval, limit: Int) {
        self.lifetime = lifetime
        self.limit = limit
    }

    /// The saved answer, or nil when there's none or it's too old. A saved
    /// miss comes back as `.some(nil)`.
    func value(for key: String) -> Value? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.savedAt) < lifetime else { return nil }
        return entry.value
    }

    mutating func store(_ value: Value, for key: String) {
        if entries.count >= limit { entries.removeAll() }
        entries[key] = (Date(), value)
    }

    mutating func removeAll() { entries.removeAll() }
}

/// TMDb trailers, ratings, collections and the Studios & Networks lists,
/// all through Vivid's relay.
///
/// Every answer is tied to a context: the server, account, profile, store
/// revision and TMDb language. An answer that arrives after the context
/// changed is dropped with a `CancellationError`.
@Observable @MainActor
final class TVTMDbStore {
    static let shared = TVTMDbStore()
    /// Vivid's relay answers every TMDb lookup with Vivid's own token, so
    /// nobody needs a TMDb key of their own.
    nonisolated static let relayBase = "https://tmdb.vividapp.co/3/"

    /// TMDb features are available: there's an active account.
    private(set) var isConfigured = false
    private(set) var revision = 0

    private let keychain = SharedKeychain(audience: .currentUser)
    private let session: URLSession
    private var loadedAccount: String?

    /// Collections and ratings rarely change, so they're kept for a day.
    private static let dayLifetime: TimeInterval = 24 * 60 * 60
    private var videoCache = TimedCache<[ItemVideo]>(lifetime: 30 * 60, limit: 40)
    private var membershipCache = TimedCache<CollectionMembership?>(lifetime: TVTMDbStore.dayLifetime, limit: 200)
    private var collectionCache = TimedCache<CollectionFilms>(lifetime: TVTMDbStore.dayLifetime, limit: 200)
    private var movieCache = TimedCache<MovieSummary>(lifetime: TVTMDbStore.dayLifetime, limit: 200)
    private var seriesCache = TimedCache<Series>(lifetime: TVTMDbStore.dayLifetime, limit: 200)
    private var ratingCache = TimedCache<Double?>(lifetime: TVTMDbStore.dayLifetime, limit: 200)
    /// Concurrent readers of the same title share one request, so the rating
    /// and the collection row never both fetch `movie/{id}` before it's cached.
    private let movieFlights = MetadataSingleFlight<String, MovieSummary>()
    private let seriesFlights = MetadataSingleFlight<String, Series>()

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: TMDbRedirectPolicy(), delegateQueue: nil)
        reloadForCurrentProfile()
    }

    // MARK: Account

    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }

    /// Includes the app's TMDb language, so nothing looked up in one
    /// language is kept for another.
    var contextKey: String {
        [ServerRegistry.shared.activeServerId ?? "", accountContext,
         AuthService.shared.profileId ?? "", String(revision),
         VividAppLanguage.tmdbLanguage ?? ""].joined(separator: "|")
    }

    /// Where earlier versions kept a personal TMDb key for this account and profile.
    private var savedKeyName: String {
        VividCloudPreferences.activeCredentialKey("tmdb") ?? legacyKeyName
    }

    private var legacyKeyName: String {
        #if os(iOS)
        MobileProfilePreferenceKeys.key("vivid.tmdb.credential.v1")
        #else
        "vivid.tmdb.credential.v1"
        #endif
    }

    /// TMDb is on whenever there's a matching saved account. Moving to
    /// another account deletes its old keys and empties every cache.
    func reloadForCurrentProfile(force: Bool = false) {
        guard VividCloudPreferences.matchingActiveAccount != nil else {
            isConfigured = false
            loadedAccount = nil
            invalidate()
            return
        }
        let account = savedKeyName
        guard force || loadedAccount != account else { return }
        removeSavedKeys()
        loadedAccount = account
        isConfigured = true
        invalidate()
    }

    /// Personal keys aren't used any more. The vault deletes any saved for a
    /// saved account, here and on the person's other devices. An old key that
    /// was never tied to an account is deleted here only.
    private func removeSavedKeys() {
        if legacyKeyName != savedKeyName, keychain.get(legacyKeyName) != nil { _ = keychain.delete(legacyKeyName) }
        VividCloudPreferences.shared.retireTMDbKeys()
    }

    private func invalidate() {
        revision += 1
        videoCache.removeAll()
        membershipCache.removeAll()
        collectionCache.removeAll()
        movieCache.removeAll()
        seriesCache.removeAll()
        ratingCache.removeAll()
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard isConfigured, contextKey == expected else { throw CancellationError() }
    }

    // MARK: Trailers

    /// Up to three YouTube trailers, official ones first. A series puts its
    /// latest season's trailers after its main one, and an episode uses its
    /// series.
    func videos(contentId: String) async throws -> [ItemVideo] {
        reloadForCurrentProfile()
        guard isConfigured else { return [] }
        let context = contextKey
        let cacheKey = context + "|" + contentId
        if let cached = videoCache.value(for: cacheKey) { return cached }
        guard let source = try await source(contentId: contentId, context: context) else { return [] }
        try checkContext(context)
        let response: Videos = try await request("\(source.kind)/\(source.id)/videos")
        try checkContext(context)
        let main = Self.rankedTrailers(response.results)
        var candidates = main
        if source.kind == "tv" {
            do {
                let series = try await seriesSummary(id: source.id, context: context)
                if let latest = series.seasons.map(\.season_number).filter({ $0 > 0 }).max() {
                    let season: Videos = try await request("tv/\(source.id)/season/\(latest)/videos")
                    try checkContext(context)
                    candidates = Array(main.prefix(1)) + Self.rankedTrailers(season.results) + Array(main.dropFirst())
                }
            } catch {
                // The main trailers are enough, unless the context changed.
                try checkContext(context)
            }
        }
        var seen = Set<String>()
        let videos = candidates.filter { seen.insert($0.key).inserted }.prefix(3).map {
            ItemVideo(kind: "trailer", site: "youtube", siteKey: $0.key,
                      name: $0.name, language: $0.iso_639_1, isOfficial: $0.official ?? false)
        }
        videoCache.store(videos, for: cacheKey)
        return videos
    }

    /// Official first, then the main trailer by name, then the newest.
    private static func rankedTrailers(_ videos: [Video]) -> [Video] {
        let mainNames: Set<String> = ["official trailer", "main trailer", "trailer"]
        return videos.filter {
            $0.site.lowercased() == "youtube" && $0.type.lowercased() == "trailer"
                && $0.key.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        }.sorted {
            let firstOfficial = $0.official ?? false
            let secondOfficial = $1.official ?? false
            if firstOfficial != secondOfficial { return firstOfficial }
            let firstMain = mainNames.contains(($0.name ?? "").lowercased())
            let secondMain = mainNames.contains(($1.name ?? "").lowercased())
            if firstMain != secondMain { return firstMain }
            return ($0.published_at ?? "") > ($1.published_at ?? "")
        }
    }

    /// The TMDb kind and ID of a library movie or series, or of an
    /// episode's series.
    private func source(contentId: String, context: String) async throws -> (kind: String, id: Int)? {
        var detail = try await MetadataRequestPool.shared.itemDetail(contentId: contentId)
        try checkContext(context)
        if detail.type == "episode", let seriesID = detail.seriesId {
            detail = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
            try checkContext(context)
        }
        guard let kind = Self.kind(of: detail),
              let id = try await tmdbID(kind: kind, detail: detail, context: context) else { return nil }
        return (kind, id)
    }

    /// "movie" or "tv", or nil for anything else.
    private static func kind(of detail: ItemDetail) -> String? {
        if detail.type == "movie" { return "movie" }
        if VividMediaType.isSeries(detail.type) { return "tv" }
        return nil
    }

    /// The item's own TMDb ID, or a lookup by IMDb ID on servers that
    /// leave TMDb out of their provider IDs.
    private func tmdbID(kind: String, detail: ItemDetail, context: String) async throws -> Int? {
        if let id = Int(detail.tmdbId ?? ""), id > 0 { return id }
        guard MediaServerProvider.active.usesNativeUser, let imdb = detail.imdbId,
              imdb.range(of: "^tt[0-9]{7,10}$", options: .regularExpression) != nil else { return nil }
        let result: ExternalMatches = try await request("find/" + imdb, query: ["external_source": "imdb_id"])
        try checkContext(context)
        let matches = kind == "movie" ? result.movie_results : result.tv_results
        guard let id = matches.first?.id, id > 0 else { return nil }
        return id
    }

    /// One `movie/{id}` read serves the collection row and the rating.
    private func movieSummary(id: Int, context: String) async throws -> MovieSummary {
        let cacheKey = context + "|movie|" + String(id)
        if let cached = movieCache.value(for: cacheKey) { return cached }
        let movie = try await movieFlights.value(for: cacheKey) { [self] in
            try await request("movie/\(id)") as MovieSummary
        }
        try checkContext(context)
        movieCache.store(movie, for: cacheKey)
        return movie
    }

    /// One `tv/{id}` read serves trailers and the rating.
    private func seriesSummary(id: Int, context: String) async throws -> Series {
        let cacheKey = context + "|tv|" + String(id)
        if let cached = seriesCache.value(for: cacheKey) { return cached }
        let series = try await seriesFlights.value(for: cacheKey) { [self] in
            try await request("tv/\(id)") as Series
        }
        try checkContext(context)
        seriesCache.store(series, for: cacheKey)
        return series
    }

    // MARK: Collections

    /// A TMDb movie collection (Scream Collection, …) with its films in
    /// release order. `movieId` is the TMDb ID of the movie it was looked
    /// up from.
    struct MovieCollection: Equatable, Sendable {
        struct Part: Equatable, Sendable {
            let id: Int
            let title: String
            let originalTitle: String?
            let year: Int?
        }
        let id: Int
        let name: String
        let movieId: Int
        let parts: [Part]
    }

    /// A movie's TMDb ID and the TMDb collection it belongs to, if any.
    private struct CollectionMembership {
        let movieId: Int
        let collectionId: Int?
    }

    /// A collection's name and films, shared by every movie in it.
    private struct CollectionFilms {
        let id: Int
        let name: String
        let parts: [MovieCollection.Part]
    }

    /// The collection a library movie belongs to, or nil when it has none.
    func collection(for detail: ItemDetail) async throws -> MovieCollection? {
        reloadForCurrentProfile()
        guard isConfigured, detail.type == "movie" else { return nil }
        let context = contextKey
        guard let membership = try await collectionMembership(for: detail, context: context),
              let collectionID = membership.collectionId else { return nil }
        let films = try await collectionFilms(id: collectionID, context: context)
        return MovieCollection(id: films.id, name: films.name, movieId: membership.movieId, parts: films.parts)
    }

    private func collectionMembership(for detail: ItemDetail, context: String) async throws -> CollectionMembership? {
        let cacheKey = context + "|" + detail.contentId
        if let cached = membershipCache.value(for: cacheKey) { return cached }
        guard let movieID = try await tmdbID(kind: "movie", detail: detail, context: context) else {
            // No TMDb match is cached too, so the IMDb lookup isn't repeated on every visit.
            membershipCache.store(nil, for: cacheKey)
            return nil
        }
        let movie = try await movieSummary(id: movieID, context: context)
        let membership = CollectionMembership(movieId: movieID, collectionId: movie.belongs_to_collection?.id)
        membershipCache.store(membership, for: cacheKey)
        return membership
    }

    /// The films stay in English, because their titles are matched against
    /// the library. Only the shown name is asked for in the app's language,
    /// keeping the English one when TMDb has no translation.
    private func collectionFilms(id collectionID: Int, context: String) async throws -> CollectionFilms {
        let cacheKey = context + "|" + String(collectionID)
        if let cached = collectionCache.value(for: cacheKey) { return cached }
        async let localizedName = localizedCollectionName(id: collectionID)
        let response: CollectionDetail = try await request("collection/\(collectionID)")
        let localized = await localizedName
        try checkContext(context)
        let films = CollectionFilms(id: response.id, name: localized.name ?? response.name,
                                    parts: Self.releaseOrder(response.parts))
        // A failed name lookup isn't kept, so the translated name is tried again.
        guard !localized.failed else { return films }
        collectionCache.store(films, for: cacheKey)
        return films
    }

    /// Oldest first. Unreleased films without a date go last, keeping
    /// TMDb's order.
    private static func releaseOrder(_ parts: [CollectionPart]) -> [MovieCollection.Part] {
        func date(_ part: CollectionPart) -> String? {
            part.release_date.flatMap { $0.isEmpty ? nil : $0 }
        }
        return parts.enumerated().sorted {
            switch (date($0.element), date($1.element)) {
            case let (first?, second?) where first != second: return first < second
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.offset < $1.offset
            }
        }.map { entry in
            let part = entry.element
            return MovieCollection.Part(
                id: part.id, title: part.title ?? part.original_title ?? "",
                originalTitle: part.original_title,
                year: part.release_date.flatMap { Int($0.prefix(4)) })
        }
    }

    /// The collection's name in the app's language: nil in English or when
    /// TMDb has no translation. `failed` is true when the lookup itself
    /// failed, which is retried rather than cached.
    private func localizedCollectionName(id collectionID: Int) async -> (name: String?, failed: Bool) {
        guard let language = VividAppLanguage.tmdbLanguage else { return (nil, false) }
        guard let response: CollectionName = try? await request("collection/\(collectionID)", language: language) else {
            return (nil, true)
        }
        guard let name = response.name, !name.isEmpty else { return (nil, false) }
        return (name, false)
    }

    // MARK: Ratings

    /// TMDb's user score for a movie or series, out of 10, or nil without an
    /// account, without a TMDb match, or when nobody has rated the title. Kept for
    /// a day per title, like collection lookups, and a miss is cached too.
    func rating(for detail: ItemDetail) async throws -> Double? {
        reloadForCurrentProfile()
        guard isConfigured, let kind = Self.kind(of: detail) else { return nil }
        let context = contextKey
        let cacheKey = context + "|" + detail.contentId
        if let cached = ratingCache.value(for: cacheKey) { return cached }
        var rating: Double?
        if let id = try await tmdbID(kind: kind, detail: detail, context: context) {
            if kind == "movie" {
                let movie = try await movieSummary(id: id, context: context)
                rating = Self.displayRating(average: movie.vote_average, count: movie.vote_count)
            } else {
                let series = try await seriesSummary(id: id, context: context)
                rating = Self.displayRating(average: series.vote_average, count: series.vote_count)
            }
        }
        ratingCache.store(rating, for: cacheKey)
        return rating
    }

    /// One decimal, as TMDb shows it. TMDb reports 0 for unrated titles.
    nonisolated static func displayRating(average: Double?, count: Int?) -> Double? {
        guard let average, average > 0, let count, count > 0 else { return nil }
        return (average * 10).rounded() / 10
    }

    // MARK: Studios & Networks

    struct DiscoverPage: Decodable {
        struct Result: Decodable {
            let id: Int
            let popularity: Double?
            let title: String?
            let name: String?
            let releaseDate: String?
            let firstAirDate: String?
            /// The Calendar's Trending posters and details.
            let posterPath: String?
            var overview: String?
            /// What Studios & Networks leaves out of its Popular rows: anime
            /// and talk shows.
            var genreIds: [Int]?
            var originalLanguage: String?
            var originCountry: [String]?

            private enum CodingKeys: String, CodingKey {
                case id, popularity, title, name, overview
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
                case posterPath = "poster_path"
                case genreIds = "genre_ids"
                case originalLanguage = "original_language"
                case originCountry = "origin_country"
            }
        }
        var results: [Result]
        let totalPages: Int?

        private enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    /// One page of popularity-ordered titles from TMDb's discover endpoint.
    ///
    /// Titles and overviews are in English unless `localized` is true. Pass
    /// it only where they're shown: Studios & Networks matches the English
    /// titles against the library. Overviews TMDb hasn't translated are
    /// filled from English with a second request for the page, made only
    /// when one is missing.
    func discover(media: String, query: [String: String], page: Int, localized: Bool = false) async throws -> DiscoverPage {
        guard isConfigured else { throw Failure.unavailable }
        var query = query
        query["sort_by"] = "popularity.desc"
        query["include_adult"] = "false"
        query["page"] = String(page)
        let path = "discover/\(media)"
        guard localized, let language = VividAppLanguage.tmdbLanguage else { return try await request(path, query: query) }
        var result: DiscoverPage = try await request(path, query: query, language: language)
        guard result.results.contains(where: { ($0.overview ?? "").isEmpty }),
              let english: DiscoverPage = try? await request(path, query: query) else { return result }
        let overviews = Dictionary(english.results.map { ($0.id, $0.overview) }, uniquingKeysWith: { first, _ in first })
        for index in result.results.indices where (result.results[index].overview ?? "").isEmpty {
            if let overview = overviews[result.results[index].id] ?? nil { result.results[index].overview = overview }
        }
        return result
    }

    /// One block of this week's worldwide trending titles, in English: 25 of
    /// TMDb's pages that the relay reads and answers as one, with only the
    /// fields Studios & Networks matches on. It has no filters, so Studios &
    /// Networks keeps each brand's own titles.
    func trendingBlock(media: String, block: Int) async throws -> DiscoverPage {
        guard isConfigured else { throw Failure.unavailable }
        return try await request("trending/\(media)/week", query: ["block": String(block)])
    }

    /// The logo for a TMDb company or network. `kind` is "company" or "network".
    func logoURL(kind: String, id: Int) async throws -> URL? {
        guard isConfigured else { throw Failure.unavailable }
        let detail: BrandDetail = try await request("\(kind)/\(id)")
        return detail.logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) }
    }

    // MARK: Requests

    /// Every request goes to Vivid's relay, which adds Vivid's TMDb token.
    /// The app never holds or sends a TMDb credential. `language` is sent
    /// only on the paths the relay takes it for; the others answer 400.
    nonisolated static func urlRequest(_ path: String, query: [String: String] = [:], language: String? = nil) -> URLRequest {
        var components = URLComponents(string: relayBase + path)!
        var query = query
        if let language, acceptsLanguage(path) { query["language"] = language }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `movie/{id}`, `tv/{id}`, `collection/{id}` and `discover/movie|tv`.
    nonisolated static func acceptsLanguage(_ path: String) -> Bool {
        path.range(of: "^((movie|tv|collection)/[0-9]+|discover/(movie|tv))$", options: .regularExpression) != nil
    }

    /// What a response status means. Anything but success is a temporary
    /// problem: there's no key for anyone to get wrong.
    nonisolated static func failure(status: Int) -> Failure? {
        status == 200 ? nil : .unavailable
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "TMDb is unavailable right now. Please try again.") }
    }

    /// Answers over 2 MB are refused. Any failure other than cancellation
    /// is reported as `.unavailable`.
    private func request<T: Decodable>(_ path: String, query: [String: String] = [:], language: String? = nil) async throws -> T {
        let request = Self.urlRequest(path, query: query, language: language)
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
            if let failure = Self.failure(status: response.statusCode) { throw failure }
            guard data.count <= 2_000_000 else { throw Failure.unavailable }
            return try JSONDecoder().decode(T.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.unavailable
        }
    }

    // MARK: TMDb's answers

    private struct MovieSummary: Decodable {
        let belongs_to_collection: CollectionReference?
        let vote_average: Double?
        let vote_count: Int?
    }
    private struct CollectionReference: Decodable {
        let id: Int
    }
    private struct CollectionDetail: Decodable {
        let id: Int
        let name: String
        let parts: [CollectionPart]
    }
    private struct CollectionName: Decodable {
        let name: String?
    }
    private struct CollectionPart: Decodable {
        let id: Int
        let title: String?
        let original_title: String?
        let release_date: String?
    }
    private struct ExternalMatches: Decodable {
        let movie_results: [ExternalMatch]
        let tv_results: [ExternalMatch]
    }
    private struct ExternalMatch: Decodable {
        let id: Int
    }
    private struct Series: Decodable {
        let seasons: [Season]
        let vote_average: Double?
        let vote_count: Int?
    }
    private struct Season: Decodable {
        let season_number: Int
    }
    private struct Videos: Decodable {
        let results: [Video]
    }
    private struct Video: Decodable {
        let key: String
        let name: String?
        let site: String
        let type: String
        let official: Bool?
        let iso_639_1: String?
        let published_at: String?
    }
    private struct BrandDetail: Decodable {
        let logoPath: String?
        private enum CodingKeys: String, CodingKey { case logoPath = "logo_path" }
    }
}

// MARK: - Collection row

/// Library titles from the TMDb collection a movie belongs to, for the
/// "<Name> Collection" row under More Like This on movie detail pages.
/// Only titles in the library are shown, in release order, including the
/// movie being viewed. The row is skipped when that movie is the only one.
///
/// Titles are matched against the library movies Studios & Networks saves
/// each day, so the row never searches the server. Until that lookup is
/// saved, the row stays hidden.
@MainActor
final class MovieCollectionRowStore {
    static let shared = MovieCollectionRowStore()

    struct Row: Equatable {
        let name: String
        let items: [SimilarPosterItem]
        /// The server, account, profile and TMDb revision it was loaded for.
        let context: String
    }

    var contextKey: String { TVTMDbStore.shared.contextKey }

    /// Whether a shown row can stay up while it refreshes: the same movie,
    /// loaded for the same server, account, profile and TMDb revision.
    func canKeep(_ row: Row?, for detail: ItemDetail) -> Bool {
        guard let row, row.context == contextKey else { return false }
        return row.items.contains { $0.contentId == detail.contentId }
    }

    /// The row for a movie page, or nil to keep it hidden. Movie pages add
    /// the rail only once there is a row, so a hidden row leaves no gap.
    func loadRow(for detail: ItemDetail) async -> Row? {
        guard detail.type == "movie", TVTMDbStore.shared.isConfigured else { return nil }
        let context = contextKey
        let result = try? await row(for: detail)
        guard contextKey == context else { return nil }
        return result
    }

    func row(for detail: ItemDetail) async throws -> Row? {
        let context = contextKey
        guard let collection = try await TVTMDbStore.shared.collection(for: detail) else { return nil }
        try checkContext(context)
        guard let library = await StudiosNetworksStore.shared.movieLookup() else { return nil }
        try checkContext(context)

        var seen = Set<String>()
        let items: [SimilarPosterItem] = collection.parts.compactMap { part in
            let item: SimilarPosterItem?
            if part.id == collection.movieId {
                item = SimilarPosterItem(detail: detail)
            } else {
                // Another copy of the movie being viewed isn't shown twice.
                let titles = [part.title, part.originalTitle].compactMap { $0 }
                item = library.movie(tmdbId: part.id, titles: titles, year: part.year)
                    .flatMap { $0.contentId == detail.contentId ? nil : $0 }
            }
            guard let item, seen.insert(item.contentId).inserted else { return nil }
            return item
        }
        return items.count > 1 ? Row(name: collection.name, items: items, context: context) : nil
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard contextKey == expected else { throw CancellationError() }
    }
}
