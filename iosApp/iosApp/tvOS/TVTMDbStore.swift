import Foundation
import Observation

private final class TMDbRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@Observable @MainActor
final class TVTMDbStore {
    static let shared = TVTMDbStore()
    private(set) var isConfigured = false
    private(set) var revision = 0
    private let keychain = SharedKeychain(audience: .currentUser)
    private var credentialKey: String {
        VividCloudPreferences.activeCredentialKey("tmdb") ?? legacyCredentialKey
    }
    private var legacyCredentialKey: String {
        #if os(iOS)
        MobileProfilePreferenceKeys.key("vivid.tmdb.credential.v1")
        #else
        "vivid.tmdb.credential.v1"
        #endif
    }
    private var loadedCredentialKey: String?
    private var credential = ""
    private let session: URLSession
    private var videoCache: [String: (Date, [ItemVideo])] = [:]
    private var membershipCache: [String: (Date, CollectionMembership?)] = [:]
    private var collectionCache: [String: (Date, CollectionFilms)] = [:]

    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }

    var contextKey: String {
        [ServerRegistry.shared.activeServerId ?? "", accountContext,
         AuthService.shared.profileId ?? "", String(revision)].joined(separator: "|")
    }

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: TMDbRedirectPolicy(), delegateQueue: nil)
        reloadForCurrentProfile()
    }

    func reloadForCurrentProfile(force: Bool = false) {
        guard VividCloudPreferences.matchingActiveAccount != nil else {
            credential = ""
            isConfigured = false
            loadedCredentialKey = nil
            invalidate()
            return
        }
        let key = credentialKey
        guard force || loadedCredentialKey != key else { return }
        if key != legacyCredentialKey, legacyCredentialKey != "vivid.tmdb.credential.v1", keychain.get(key) == nil, let legacy = keychain.get(legacyCredentialKey) {
            if keychain.set(legacy, for: key) { _ = keychain.delete(legacyCredentialKey) }
        }
        loadedCredentialKey = key
        credential = keychain.get(key) ?? ""
        isConfigured = !credential.isEmpty
        invalidate()
    }

    func connect(_ input: String) async throws {
        reloadForCurrentProfile()
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw Failure.unavailable }
        let key = credentialKey
        let context = contextKey
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 4096,
              !candidate.contains(where: { $0.isWhitespace }) else { throw Failure.invalidKey }
        let validation: Validation = try await request("authentication", credential: candidate)
        guard validation.success else { throw Failure.invalidKey }
        try Task.checkCancellation()
        guard key == credentialKey, context == contextKey else { throw CancellationError() }
        guard keychain.set(candidate, for: key) else { throw Failure.storage }
        credential = candidate
        isConfigured = true
        invalidate()
        VividCloudPreferences.shared.schedule()
    }

    func disconnect() throws {
        reloadForCurrentProfile()
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw Failure.unavailable }
        guard keychain.delete(credentialKey) else { throw Failure.storage }
        credential = ""
        isConfigured = false
        invalidate()
        VividCloudPreferences.shared.schedule()
    }

    private func invalidate() {
        revision += 1
        videoCache.removeAll()
        membershipCache.removeAll()
        collectionCache.removeAll()
    }

    func videos(contentId: String) async throws -> [ItemVideo] {
        reloadForCurrentProfile()
        guard isConfigured else { return [] }
        let context = contextKey
        let cacheKey = context + "|" + contentId
        if let cached = videoCache[cacheKey], Date().timeIntervalSince(cached.0) < 1800 { return cached.1 }
        guard let source = try await source(contentId: contentId, context: context) else { return [] }
        try checkContext(context)
        let response: Videos = try await request("\(source.kind)/\(source.id)/videos", credential: credential)
        try checkContext(context)
        let main = Self.rankedTrailers(response.results)
        var candidates = main
        if source.kind == "tv" {
            do {
                let series: Series = try await request("tv/\(source.id)", credential: credential)
                try checkContext(context)
                if let latest = series.seasons.filter({ $0.season_number > 0 }).max(by: { $0.season_number < $1.season_number }) {
                    let season: Videos = try await request("tv/\(source.id)/season/\(latest.season_number)/videos", credential: credential)
                    try checkContext(context)
                    candidates = Array(main.prefix(1)) + Self.rankedTrailers(season.results) + Array(main.dropFirst())
                }
            } catch {
                try checkContext(context)
            }
        }
        var seen = Set<String>()
        let videos = candidates.filter { seen.insert($0.key).inserted }.prefix(3).map {
            ItemVideo(kind: "trailer", site: "youtube", siteKey: $0.key,
                      name: $0.name, language: $0.iso_639_1, isOfficial: $0.official ?? false)
        }
        if videoCache.count >= 40 { videoCache.removeAll() }
        videoCache[cacheKey] = (Date(), videos)
        return videos
    }

    private func source(contentId: String, context: String) async throws -> (kind: String, id: Int)? {
        var detail = try await MetadataRequestPool.shared.itemDetail(contentId: contentId)
        try checkContext(context)
        if detail.type == "episode", let seriesID = detail.seriesId {
            detail = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
            try checkContext(context)
        }
        let kind: String
        if detail.type == "movie" { kind = "movie" }
        else if VividMediaType.isSeries(detail.type) { kind = "tv" }
        else { return nil }
        guard let id = try await tmdbID(kind: kind, detail: detail, context: context) else { return nil }
        return (kind,id)
    }

    /// The item's own TMDb ID, or a lookup by IMDb ID on servers that
    /// leave TMDb out of their provider IDs.
    private func tmdbID(kind: String, detail: ItemDetail, context: String) async throws -> Int? {
        if let id = Int(detail.tmdbId ?? ""), id > 0 { return id }
        guard MediaServerProvider.active.usesNativeUser, let imdb = detail.imdbId, imdb.range(of:"^tt[0-9]{7,10}$",options:.regularExpression) != nil else { return nil }
        let result: ExternalMatches = try await request("find/" + imdb,credential:credential,query:["external_source":"imdb_id"])
        try checkContext(context)
        let matches = kind == "movie" ? result.movie_results : result.tv_results
        guard let id = matches.first?.id, id > 0 else { return nil }
        return id
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

    /// Collections rarely change, so lookups are kept for a day. The films of
    /// a collection are cached once for every movie in it.
    private static let collectionLifetime: TimeInterval = 24 * 60 * 60

    /// The collection a library movie belongs to, or nil when it has none.
    func collection(for detail: ItemDetail) async throws -> MovieCollection? {
        reloadForCurrentProfile()
        guard isConfigured, detail.type == "movie" else { return nil }
        let context = contextKey
        guard let membership = try await collectionMembership(for: detail, context: context),
              let collectionID = membership.collectionId else { return nil }
        let collection = try await collection(id: collectionID, context: context)
        return MovieCollection(id: collection.id, name: collection.name, movieId: membership.movieId, parts: collection.parts)
    }

    private func collectionMembership(for detail: ItemDetail, context: String) async throws -> CollectionMembership? {
        let cacheKey = context + "|" + detail.contentId
        if let cached = membershipCache[cacheKey], Date().timeIntervalSince(cached.0) < Self.collectionLifetime { return cached.1 }
        guard let movieID = try await tmdbID(kind: "movie", detail: detail, context: context) else {
            // No TMDb match is cached too, so the IMDb lookup isn't repeated on every visit.
            storeMembership(nil, for: cacheKey)
            return nil
        }
        let movie: MovieSummary = try await request("movie/\(movieID)", credential: credential)
        try checkContext(context)
        let membership = CollectionMembership(movieId: movieID, collectionId: movie.belongs_to_collection?.id)
        storeMembership(membership, for: cacheKey)
        return membership
    }

    private func storeMembership(_ membership: CollectionMembership?, for cacheKey: String) {
        if membershipCache.count >= 200 { membershipCache.removeAll() }
        membershipCache[cacheKey] = (Date(), membership)
    }

    private func collection(id collectionID: Int, context: String) async throws -> CollectionFilms {
        let cacheKey = context + "|" + String(collectionID)
        if let cached = collectionCache[cacheKey], Date().timeIntervalSince(cached.0) < Self.collectionLifetime { return cached.1 }
        let response: CollectionDetail = try await request("collection/\(collectionID)", credential: credential)
        try checkContext(context)
        let date: (CollectionPart) -> String? = { part in
            part.release_date.flatMap { $0.isEmpty ? nil : $0 }
        }
        let parts = response.parts.enumerated().sorted {
            // Unreleased films without a date go last, keeping TMDb's order.
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
        let films = CollectionFilms(id: response.id, name: response.name, parts: parts)
        if collectionCache.count >= 200 { collectionCache.removeAll() }
        collectionCache[cacheKey] = (Date(), films)
        return films
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

            private enum CodingKeys: String, CodingKey {
                case id, popularity, title, name
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
            }
        }
        let results: [Result]
        let totalPages: Int?

        private enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    private struct BrandDetail: Decodable {
        let logoPath: String?
        private enum CodingKeys: String, CodingKey { case logoPath = "logo_path" }
    }

    /// One page of popularity-ordered titles from TMDb's discover endpoint.
    func discover(media: String, query: [String: String], page: Int) async throws -> DiscoverPage {
        guard isConfigured else { throw Failure.unavailable }
        var q = query
        q["sort_by"] = "popularity.desc"
        q["include_adult"] = "false"
        q["page"] = String(page)
        return try await request("discover/\(media)", credential: credential, query: q)
    }

    /// The logo for a TMDb company or network. `kind` is "company" or "network".
    func logoURL(kind: String, id: Int) async throws -> URL? {
        guard isConfigured else { throw Failure.unavailable }
        let detail: BrandDetail = try await request("\(kind)/\(id)", credential: credential)
        return detail.logoPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500" + $0) }
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard isConfigured, contextKey == expected else { throw CancellationError() }
    }

    private func request<T: Decodable>(_ path: String, credential: String, query: [String:String] = [:]) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        let isAPIKey = credential.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name:$0.key,value:$0.value) } }
        if isAPIKey { components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: credential)] }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !isAPIKey { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
            if response.statusCode == 401 || response.statusCode == 403 { throw Failure.invalidKey }
            guard response.statusCode == 200, data.count <= 2_000_000 else { throw Failure.unavailable }
            return try JSONDecoder().decode(T.self, from: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure.unavailable }
    }

    enum Failure: LocalizedError {
        case invalidKey, unavailable, storage
        var errorDescription: String? {
            switch self {
            case .invalidKey: "TMDb could not validate this API key or read access token."
            case .unavailable: "TMDb is unavailable right now. Please try again."
            case .storage: "Could not update the saved TMDb key on this Apple TV."
            }
        }
    }
    private static func rankedTrailers(_ videos: [Video]) -> [Video] {
        videos.filter {
            $0.site.lowercased() == "youtube" && $0.type.lowercased() == "trailer"
                && $0.key.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        }.sorted {
            let first = $0.official ?? false
            let second = $1.official ?? false
            if first != second { return first }
            let firstMain = ["official trailer", "main trailer", "trailer"].contains(($0.name ?? "").lowercased())
            let secondMain = ["official trailer", "main trailer", "trailer"].contains(($1.name ?? "").lowercased())
            if firstMain != secondMain { return firstMain }
            return ($0.published_at ?? "") > ($1.published_at ?? "")
        }
    }
    private struct MovieSummary: Decodable { let belongs_to_collection: CollectionReference? }
    private struct CollectionReference: Decodable { let id: Int }
    private struct CollectionDetail: Decodable { let id: Int; let name: String; let parts: [CollectionPart] }
    private struct CollectionPart: Decodable {
        let id: Int; let title: String?; let original_title: String?; let release_date: String?
    }
    private struct ExternalMatches: Decodable { let movie_results: [ExternalMatch]; let tv_results: [ExternalMatch] }
    private struct ExternalMatch: Decodable { let id: Int }
    private struct Series: Decodable { let seasons: [Season] }
    private struct Season: Decodable { let season_number: Int }
    private struct Validation: Decodable { let success: Bool }
    private struct Videos: Decodable { let results: [Video] }
    private struct Video: Decodable {
        let key: String; let name: String?; let site: String; let type: String
        let official: Bool?; let iso_639_1: String?; let published_at: String?
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
            let item = part.id == collection.movieId
                ? SimilarPosterItem(detail: detail)
                : library.movie(tmdbId: part.id, titles: [part.title, part.originalTitle].compactMap { $0 }, year: part.year)
                    .flatMap { $0.contentId == detail.contentId ? nil : $0 }
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
