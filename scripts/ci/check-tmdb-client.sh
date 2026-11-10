#!/bin/bash
# Offline checks of the TMDb client, the collection row and library similarity,
# using the production sources against a simulated TMDb relay and media server.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/vivid-tmdb-check.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source = (root/'iosApp/iosApp/tvOS/TVTMDbStore.swift').read_text()
source = source.removeprefix('#if os(tvOS)\n').removesuffix('#endif\n')
source = source.replace('#if os(iOS)', '#if true')
# The shared store, which the collection row reads, talks to the simulated relay too.
assert 'static let shared = TVTMDbStore()' in source
source = source.replace('static let shared = TVTMDbStore()', 'static let shared = TVTMDbStore(sessionConfiguration: Stub.configuration())')
helpers = (root/'iosApp/iosApp/Navigation/ProfileScopedKeys.swift').read_text()
source += '\n' + helpers.removeprefix('import Foundation\n')
similarity = (root/'iosApp/iosApp/tvOS/TVLibrarySimilarityStore.swift').read_text()
source += '\n' + similarity.removeprefix('#if os(tvOS)\n').removesuffix('#endif\n')
# The real single-flight actor, so shared movie and series reads are checked too.
pool = (root/'iosApp/iosApp/Networking/MetadataRequestPool.swift').read_text()
start = pool.index('actor MetadataSingleFlight')
end = pool.index('\n}\n', start) + 3
source += '\n' + pool[start:end]
(temporary/'Client.swift').write_text(source)
PY
cat > "$test_dir/Checks.swift" <<'SWIFT'
import Foundation

struct SharedKeychain {
    enum Audience { case currentUser }
    nonisolated(unsafe) static var values: [String: String] = [:]
    init(audience: Audience) {}
    func get(_ key: String) -> String? { Self.values[key] }
    func set(_ value: String, for key: String) -> Bool { Self.values[key] = value; return true }
    func delete(_ key: String) -> Bool { Self.values[key] = nil; return true }
}
@MainActor final class ServerRegistry { static let shared = ServerRegistry(); var activeServerId: String? = "server-a" }
@MainActor final class TVSavedAccountStore { static let shared = TVSavedAccountStore(); var activeID: String? = "account-a" }
@MainActor final class AuthService { static let shared = AuthService(); var profileId: String? = "profile-a" }
struct TVSavedAccount {}
@MainActor final class VividCloudPreferences {
    static let shared = VividCloudPreferences()
    static var signedIn = true
    var retirements = 0
    static var matchingActiveAccount: TVSavedAccount? { signedIn ? TVSavedAccount() : nil }
    static func activeCredentialKey(_ name: String) -> String? {
        guard signedIn else { return nil }
        return "vivid.cloud.credential.\(name).\(ServerRegistry.shared.activeServerId ?? "")|\(AuthService.shared.profileId ?? "")"
    }
    func retireTMDbKeys() {
        retirements += 1
        for key in SharedKeychain.values.keys where key.hasPrefix("vivid.cloud.credential.tmdb.") { SharedKeychain.values[key] = nil }
    }
}
enum VividAppLanguage { nonisolated(unsafe) static var tmdbLanguage: String? }
@MainActor enum MediaServerProvider {
    case silo, emby, jellyfin
    static var active: Self = .silo
    var usesNativeUser: Bool { self == .emby || self == .jellyfin }
}
enum VividMediaType { static func isSeries(_ type: String) -> Bool { type == "series" } }
struct ItemDetail { let contentId: String; let type: String; let tmdbId: String?; var seriesId: String? = nil; var genres: [String]? = ["Drama"]; var studios: [String]? = nil; var networks: [String]? = nil; var year: Int? = 2020; var imdbId: String? = nil }
struct ItemVideo { let kind: String; let site: String; let siteKey: String; let name: String?; let language: String?; let isOfficial: Bool }
struct SimilarPosterItem: Equatable { let contentId: String; init(contentId: String) { self.contentId = contentId }; init(detail: ItemDetail) { contentId = detail.contentId }; init(item: BrowseItem) { contentId = item.contentId } }
struct BrowseItem { let contentId: String; var type = "movie"; var title = "Title"; var genres: [String]? = ["Drama"]; var studios: [String]? = nil; var networks: [String]? = nil; var year: Int? = 2020 }
struct CatalogResponse { let items: [BrowseItem]; var total: Int? = 1000; var hasMore: Bool? = true; var snapshot: String? = nil }
enum CatalogSortKey { case title, addedAt }
struct CatalogFilterState { var sort = CatalogSortKey.title; var genres = Set<String>(); var studios = Set<String>(); var networks = Set<String>(); var matchAll = true }
enum BrowseMediaType: String { case movie, series }
enum CatalogQueryBuilder {
    static func build(_ state: CatalogFilterState, libraryId: Int?, mediaType: BrowseMediaType, offset: Int, limit: Int, snapshot: String?, includeTotal: Bool) -> [String: String] {
        precondition(!state.matchAll && state.genres.contains("Drama") && state.sort == .addedAt)
        precondition(libraryId == nil && limit == 100 && includeTotal == (offset == 0))
        return ["type": mediaType.rawValue, "offset": String(offset), "limit": String(limit)]
    }
}
// Only Silo is used for library similarity here; Emby and Jellyfin have their own similar endpoints.
struct JellyfinConnection {
    static func current() async throws -> JellyfinConnection { fatalError("Jellyfin isn't simulated") }
    static func id(_ value: String) throws -> String { value }
}
struct JellyfinAdapter {
    init(connection: JellyfinConnection) {}
    func items(_ path: String? = nil, query: [String: String] = [:]) async throws -> [String: Any] { [:] }
    static func decode<T>(_ value: Any) throws -> T { fatalError("Jellyfin isn't simulated") }
}
struct EmbyConnection {
    static func current() async throws -> EmbyConnection { fatalError("Emby isn't simulated") }
    static func id(_ value: String) throws -> String { value }
}
struct EmbyAdapter {
    static let browseFields = "Overview"
    init(connection: EmbyConnection) {}
    func items(_ path: String? = nil, query: [String: String] = [:]) async throws -> [String: Any] { [:] }
    static func decode<T>(_ value: Any) throws -> T { fatalError("Emby isn't simulated") }
}
struct LibraryMovieLookup {
    var byTMDb: [Int: String] = [:]
    var byTitle: [String: String] = [:]
    func movie(tmdbId: Int, titles: [String], year: Int?) -> SimilarPosterItem? {
        if let id = byTMDb[tmdbId] { return SimilarPosterItem(contentId: id) }
        guard let year else { return nil }
        for title in titles { if let id = byTitle["\(title)|\(year)"] { return SimilarPosterItem(contentId: id) } }
        return nil
    }
}
@MainActor final class StudiosNetworksStore {
    static let shared = StudiosNetworksStore()
    var lookup: LibraryMovieLookup?
    func movieLookup() async -> LibraryMovieLookup? { lookup }
}
@MainActor final class MetadataRequestPool {
    static let shared = MetadataRequestPool()
    var count = 0
    var beforeReturn: (() -> Void)?
    func itemDetail(contentId: String) async throws -> ItemDetail {
        count += 1
        if let action = beforeReturn { beforeReturn = nil; action() }
        switch contentId {
        case "show": return ItemDetail(contentId: contentId, type: "series", tmdbId: "42")
        case "episode": return ItemDetail(contentId: contentId, type: "episode", tmdbId: "999", seriesId: "show")
        case "movie": return ItemDetail(contentId: contentId, type: "movie", tmdbId: "7")
        case "imdb-only": return ItemDetail(contentId: contentId, type: "movie", tmdbId: nil, imdbId: "tt1234567")
        case "no-id": return ItemDetail(contentId: contentId, type: "movie", tmdbId: nil)
        case "person": return ItemDetail(contentId: contentId, type: "person", tmdbId: "5")
        default: return ItemDetail(contentId: contentId, type: "movie", tmdbId: contentId)
        }
    }
}
@MainActor final class VividAPI {
    static let shared = VividAPI()
    var count = 0
    var beforeReturn: (() -> Void)?
    func get(_ path: String, query: [String: String]) async throws -> CatalogResponse {
        count += 1
        precondition(path == "/api/v1/catalog")
        if let action = beforeReturn { beforeReturn = nil; action() }
        let offset = Int(query["offset"]!)!
        let limit = Int(query["limit"]!)!
        return CatalogResponse(items: (offset..<(offset + limit)).map { BrowseItem(contentId: String($0), type: query["type"]!) })
    }
}

/// A simulated relay. Every request is checked for the relay's rules: no
/// credential, no media server headers, `language` only where it's taken.
final class Stub: URLProtocol, @unchecked Sendable {
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return config
    }
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var failCollectionName = false
    nonisolated(unsafe) static var movieDelay: UInt32 = 0
    static func count(_ path: String) -> Int { requests.filter { $0.url!.path == path }.count }
    static func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(request)
        precondition(url.scheme == "https" && url.host == "tmdb.vividapp.co" && url.path.hasPrefix("/3/"), "\(url)")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let query = Self.query(request)
        precondition(query["api_key"] == nil)
        let path = String(url.path.dropFirst(3))
        if query["language"] != nil { precondition(TVTMDbStore.acceptsLanguage(path), "language sent on \(path)") }
        let french = query["language"] == "fr-FR"
        var status = Self.status
        let body: String
        switch path {
        case "find/tt1234567":
            precondition(query == ["external_source": "imdb_id"])
            body = #"{"movie_results":[{"id":7}],"tv_results":[{"id":42}]}"#
        case "movie/7":
            if Self.movieDelay > 0 { usleep(Self.movieDelay) }
            body = #"{"belongs_to_collection":{"id":10},"vote_average":7.26,"vote_count":10}"#
        case "movie/8": body = #"{"belongs_to_collection":null,"vote_average":0,"vote_count":0}"#
        case "tv/42": body = #"{"seasons":[{"season_number":0},{"season_number":1},{"season_number":3}],"vote_average":8.04,"vote_count":5}"#
        case "collection/10":
            if french && Self.failCollectionName { status = 500 }
            body = french
                ? #"{"id":10,"name":"Saga Scream","parts":[]}"#
                : #"{"id":10,"name":"Scream Collection","parts":[{"id":12,"title":"Scream 3","release_date":"2000-02-04"},{"id":99,"title":"Scream 7","release_date":""},{"id":7,"title":"Scream","original_title":"Scream","release_date":"1996-12-20"},{"id":98,"title":"Scream 8"},{"id":11,"title":"Scream 2","release_date":"1997-12-12"}]}"#
        case "company/2": body = #"{"logo_path":"/logo.png"}"#
        case "network/3": body = #"{"logo_path":null}"#
        case "discover/movie":
            precondition(query["sort_by"] == "popularity.desc" && query["include_adult"] == "false" && query["page"] == "2")
            body = french
                ? #"{"results":[{"id":1,"title":"Un","overview":"Bonjour"},{"id":2,"title":"Deux","overview":""}],"total_pages":4}"#
                : #"{"results":[{"id":1,"title":"One","overview":"Hello"},{"id":2,"title":"Two","overview":"English two"}],"total_pages":4}"#
        case "trending/tv/week":
            precondition(query == ["block": "3"])
            body = #"{"results":[{"id":5,"name":"Five","genre_ids":[18],"origin_country":["GB"]}]}"#
        default:
            precondition(path.hasSuffix("/videos"), "Unexpected path \(path)")
            let season = path.contains("season/3")
            let keys = season ? ["season00001", "season00002", "season00003"] : ["main0000001", "main0000001", "movie000002", "movie000003", "movie000004", "bad key"]
            body = "{\"results\":[" + keys.enumerated().map { index, key in
                "{\"key\":\"\(key)\",\"name\":\"\(index == 0 ? "Official Trailer" : "Trailer 2")\",\"site\":\"YouTube\",\"type\":\"Trailer\",\"official\":true,\"published_at\":\"2026-01-0\(index + 1)\"}"
            }.joined(separator: ",") + ",{\"key\":\"teaser00001\",\"name\":\"Teaser\",\"site\":\"YouTube\",\"type\":\"Teaser\",\"official\":true}]}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Like `precondition`, but the condition can await.
func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
    if !condition { fatalError("Check failed on line \(line) of Checks.swift. \(message())") }
}

@main struct Checks {
    @MainActor static func main() async throws {
        // Signed out: nothing is configured and nothing is sent.
        VividCloudPreferences.signedIn = false
        let store = TVTMDbStore(sessionConfiguration: Stub.configuration())
        check(!store.isConfigured)
        check(try await store.videos(contentId: "movie").isEmpty)
        check(try await store.rating(for: ItemDetail(contentId: "movie", type: "movie", tmdbId: "7")) == nil)
        check(try await store.collection(for: ItemDetail(contentId: "movie", type: "movie", tmdbId: "7")) == nil)
        do { _ = try await store.discover(media: "movie", query: [:], page: 2); fatalError("Discover ran signed out") }
        catch TVTMDbStore.Failure.unavailable {}
        check(Stub.requests.isEmpty && MetadataRequestPool.shared.count == 0)

        // Signing in turns TMDb on and deletes keys earlier versions saved.
        let legacyKey = "vivid.tmdb.credential.v1.profile." + Data("server-a|profile-a".utf8).base64EncodedString()
        SharedKeychain.values = [legacyKey: "old", "vivid.cloud.credential.tmdb.server-a|profile-a": "old", "vivid.mdblist.key": "kept"]
        VividCloudPreferences.signedIn = true
        let revision = store.revision
        store.reloadForCurrentProfile()
        check(store.isConfigured && store.revision == revision + 1)
        check(SharedKeychain.values == ["vivid.mdblist.key": "kept"], "Old TMDb keys must be deleted")
        let retirements = VividCloudPreferences.shared.retirements
        store.reloadForCurrentProfile()
        check(store.revision == revision + 1 && VividCloudPreferences.shared.retirements == retirements, "Reloading the same account changes nothing")
        store.reloadForCurrentProfile(force: true)
        check(store.revision == revision + 2)

        // Requests and failures.
        check(TVTMDbStore.urlRequest("movie/7").url!.absoluteString == "https://tmdb.vividapp.co/3/movie/7")
        check(TVTMDbStore.urlRequest("movie/7", language: "fr-FR").url!.query == "language=fr-FR")
        check(TVTMDbStore.urlRequest("movie/7/videos", language: "fr-FR").url!.query == nil)
        for path in ["movie/7", "tv/42", "collection/10", "discover/movie", "discover/tv"] { check(TVTMDbStore.acceptsLanguage(path)) }
        for path in ["movie/7/videos", "tv/42/season/1/videos", "company/2", "network/3", "find/tt1234567", "trending/tv/week", "tv/42/external_ids", "movie/abc"] {
            check(!TVTMDbStore.acceptsLanguage(path))
        }
        for status in [301, 302, 400, 401, 404, 429, 500, 502, 503] { check(TVTMDbStore.failure(status: status) == .unavailable) }
        check(TVTMDbStore.failure(status: 200) == nil)
        Stub.status = 503
        do { _ = try await store.videos(contentId: "movie"); fatalError("A failed request was accepted") }
        catch let error as TVTMDbStore.Failure { check(error == .unavailable && !error.localizedDescription.lowercased().contains("key")) }
        Stub.status = 302
        do { _ = try await store.logoURL(kind: "company", id: 2); fatalError("A redirect was accepted") } catch TVTMDbStore.Failure.unavailable {}
        Stub.status = 200

        // Trailers: official YouTube trailers first, no duplicates, at most three, then cached.
        Stub.requests.removeAll()
        let movie = try await store.videos(contentId: "movie")
        check(movie.map(\.siteKey) == ["main0000001", "movie000004", "movie000003"], "\(movie.map(\.siteKey))")
        check(movie.allSatisfy { $0.kind == "trailer" && $0.site == "youtube" && $0.isOfficial })
        let afterMovie = Stub.requests.count
        _ = try await store.videos(contentId: "movie")
        check(Stub.requests.count == afterMovie)
        // A series puts its latest season's trailers after its main one; an episode uses its series.
        let show = try await store.videos(contentId: "episode")
        check(show.map(\.siteKey) == ["main0000001", "season00001", "season00003"], "\(show.map(\.siteKey))")
        check(Stub.count("/3/tv/42/season/3/videos") == 1)
        let noID = try await store.videos(contentId: "no-id")
        let person = try await store.videos(contentId: "person")
        check(noID.isEmpty && person.isEmpty)

        // IMDb lookups only on servers that leave TMDb IDs out (Emby, Jellyfin).
        Stub.requests.removeAll()
        let silo = try await store.videos(contentId: "imdb-only")
        check(silo.isEmpty && Stub.requests.isEmpty)
        MediaServerProvider.active = .jellyfin
        let jellyfin = try await store.videos(contentId: "imdb-only")
        check(jellyfin.count == 3 && Stub.count("/3/find/tt1234567") == 1)
        MediaServerProvider.active = .silo

        // Ratings share one movie read with the collection row, and misses are cached.
        Stub.requests.removeAll()
        store.reloadForCurrentProfile(force: true)
        Stub.movieDelay = 200_000
        let scream = ItemDetail(contentId: "movie", type: "movie", tmdbId: "7")
        async let rating = store.rating(for: scream)
        async let collection = store.collection(for: scream)
        let (score, films) = try await (rating, collection)
        Stub.movieDelay = 0
        check(score == 7.3 && Stub.count("/3/movie/7") == 1, "One movie read serves both")
        check(films?.name == "Scream Collection" && films?.movieId == 7 && films?.id == 10)
        check(films?.parts.map(\.id) == [7, 11, 12, 99, 98], "Release order, undated films last in TMDb's order")
        check(films?.parts.first?.year == 1996 && films?.parts[3].year == nil)
        check(try await store.rating(for: ItemDetail(contentId: "show", type: "series", tmdbId: "42")) == 8.0)
        check(try await store.rating(for: ItemDetail(contentId: "unrated", type: "movie", tmdbId: "8")) == nil)
        let reads = Stub.requests.count
        check(try await store.rating(for: ItemDetail(contentId: "unrated", type: "movie", tmdbId: "8")) == nil)
        check(try await store.rating(for: ItemDetail(contentId: "e", type: "episode", tmdbId: "8")) == nil)
        check(try await store.collection(for: ItemDetail(contentId: "unrated", type: "movie", tmdbId: "8")) == nil)
        check(Stub.requests.count == reads)

        // Collection names follow the app's language; a failed name lookup isn't cached.
        VividAppLanguage.tmdbLanguage = "fr-FR"
        Stub.failCollectionName = true
        check(try await store.collection(for: scream)?.name == "Scream Collection")
        Stub.failCollectionName = false
        let before = Stub.count("/3/collection/10")
        check(try await store.collection(for: scream)?.name == "Saga Scream")
        check(Stub.count("/3/collection/10") == before + 2)
        let cachedReads = Stub.requests.count
        _ = try await store.collection(for: scream)
        check(Stub.requests.count == cachedReads)

        // Discover fills untranslated overviews from English; trending and logos.
        let page = try await store.discover(media: "movie", query: ["with_companies": "2"], page: 2, localized: true)
        check(page.results.map(\.overview) == ["Bonjour", "English two"] && page.totalPages == 4)
        let english = try await store.discover(media: "movie", query: [:], page: 2)
        check(english.results.first?.title == "One")
        VividAppLanguage.tmdbLanguage = nil
        let trending = try await store.trendingBlock(media: "tv", block: 3)
        check(trending.results.first?.name == "Five" && trending.results.first?.originCountry == ["GB"])
        check(try await store.logoURL(kind: "company", id: 2)?.absoluteString == "https://image.tmdb.org/t/p/w500/logo.png")
        check(try await store.logoURL(kind: "network", id: 3) == nil)

        // The collection row: library titles only, in release order, and never just the one movie.
        let rows = MovieCollectionRowStore()
        check(await rows.loadRow(for: scream) == nil, "Hidden until the library lookup is saved")
        StudiosNetworksStore.shared.lookup = LibraryMovieLookup(byTMDb: [11: "s2", 7: "other-copy"], byTitle: ["Scream 3|2000": "s3"])
        let row = await rows.loadRow(for: scream)
        check(row?.name == "Scream Collection" && row?.items.map(\.contentId) == ["movie", "s2", "s3"])
        check(rows.canKeep(row, for: scream) && !rows.canKeep(row, for: ItemDetail(contentId: "x", type: "movie", tmdbId: "1")))
        StudiosNetworksStore.shared.lookup = LibraryMovieLookup()
        check(await rows.loadRow(for: scream) == nil)
        check(await rows.loadRow(for: ItemDetail(contentId: "show", type: "series", tmdbId: "42")) == nil)

        // A change of account or profile mid-request is never kept.
        MetadataRequestPool.shared.beforeReturn = { AuthService.shared.profileId = "profile-b" }
        do { _ = try await store.videos(contentId: "different"); fatalError("Stale context accepted") }
        catch is CancellationError {}
        AuthService.shared.profileId = "profile-a"
        VividAppLanguage.tmdbLanguage = "fr-FR"
        let french = store.contextKey
        VividAppLanguage.tmdbLanguage = nil
        check(french != store.contextKey, "Nothing looked up in one language is kept for another")

        // Signing out turns TMDb off again.
        VividCloudPreferences.signedIn = false
        store.reloadForCurrentProfile()
        check(!store.isConfigured)
        Stub.requests.removeAll()
        let signedOut = try await store.videos(contentId: "movie")
        check(signedOut.isEmpty && Stub.requests.isEmpty)
        VividCloudPreferences.signedIn = true

        // Library similarity needs neither TMDb nor TMDb identifiers.
        let library = TVLibrarySimilarityStore()
        let local = try await library.suggestions(contentId: "no-id")
        check(local.count == 10 && Stub.requests.isEmpty)
        let beforeLocalCache = VividAPI.shared.count
        _ = try await library.suggestions(contentId: "no-id")
        check(VividAPI.shared.count == beforeLocalCache)
        check(beforeLocalCache == 4, "Read the count and sample all three catalog ranges")
        let offsets = TVLibrarySimilarityStore.candidateOffsets(total: 1000, seed: "source")
        for (index, offset) in offsets.enumerated() {
            check(offset >= 1000 * index / 3 && offset + 100 <= 1000 * (index + 1) / 3)
        }
        check(TVLibrarySimilarityStore.candidateOffsets(total: 0, seed: "source").isEmpty)
        check(TVLibrarySimilarityStore.candidateOffsets(total: 150, seed: "source") == [0, 100])
        let equalItems = (0..<30).map { BrowseItem(contentId: String($0), title: "A" + String($0)) }
        let tieSource = ItemDetail(contentId: "tie", type: "movie", tmdbId: nil)
        let firstOrder = TVLibrarySimilarityStore.rank(equalItems, relativeTo: tieSource).map(\.contentId)
        let renamedItems = equalItems.reversed().map { item -> BrowseItem in var copy = item; copy.title = "Z" + item.title; return copy }
        check(firstOrder == TVLibrarySimilarityStore.rank(renamedItems, relativeTo: tieSource).map(\.contentId))
        let beforeSource = MetadataRequestPool.shared.count
        _ = try await library.suggestions(contentId: "loaded", sourceDetail: ItemDetail(contentId: "loaded", type: "movie", tmdbId: nil))
        check(MetadataRequestPool.shared.count == beforeSource, "Loaded source must not be requested again")
        let source = ItemDetail(contentId: "source", type: "movie", tmdbId: nil, genres: ["Drama", "Crime"])
        let ranked = TVLibrarySimilarityStore.rank([
            BrowseItem(contentId: "source"),
            BrowseItem(contentId: "wrong-type", type: "series", genres: ["Drama", "Crime"]),
            BrowseItem(contentId: "unrelated", genres: ["Comedy"]),
            BrowseItem(contentId: "partial", genres: ["Drama"]),
            BrowseItem(contentId: "best", genres: ["crime", " DRAMA "]),
            BrowseItem(contentId: "best", genres: ["Drama"])
        ], relativeTo: source)
        check(ranked.map(\.contentId) == ["best", "partial"])
        let series = try await library.suggestions(contentId: "show")
        check(series.count == 10 && Stub.requests.isEmpty)
        VividAPI.shared.beforeReturn = { AuthService.shared.profileId = "profile-local-change" }
        do { _ = try await library.suggestions(contentId: "different"); fatalError("Stale library results accepted") }
        catch is CancellationError {}
        AuthService.shared.profileId = "profile-a"

        print("TMDb checks passed: relay only with no credential, old keys deleted, sign-in scope, language paths, every failure temporary, redirects refused, trailer ranking/deduplication/cap, latest season, IMDb lookups only on Emby and Jellyfin, shared movie reads, ratings, collections and their translated names, discover overviews, trending, logos, the collection row, stale contexts, library similarity without TMDb.")
    }
}
SWIFT
xcrun swiftc -swift-version 5 -parse-as-library "$test_dir/Client.swift" "$test_dir/Checks.swift" -o "$test_dir/checks"
"$test_dir/checks"
