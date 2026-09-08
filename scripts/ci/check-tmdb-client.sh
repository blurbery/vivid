#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/vivid-tmdb-check.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source=(root/'iosApp/iosApp/tvOS/TVTMDbStore.swift').read_text()
source=source.removeprefix('#if os(tvOS)\n').removesuffix('#endif\n')
source = source.replace('#if os(iOS)', '#if true')
helpers = (root/'iosApp/iosApp/Navigation/UICustomizationPreferences.swift').read_text()
helpers = helpers[helpers.index('@MainActor\nenum MobileProfilePreferenceKeys'):]
source += '\n' + helpers.replace('#if os(iOS)', '#if true')

source += (root/'iosApp/iosApp/tvOS/TVLibrarySimilarityStore.swift').read_text().removeprefix('#if os(tvOS)\n').removesuffix('#endif\n')
(temporary/'Client.swift').write_text(source)
PY
cat > "$test_dir/Checks.swift" <<'SWIFT'
import Foundation

struct SharedKeychain {
    enum Audience { case currentUser }
    static var values: [String: String] = [:]
    init(audience: Audience) {}
    func get(_ key: String) -> String? { Self.values[key] }
    func set(_ value: String, for key: String) -> Bool { Self.values[key] = value; return true }
    func delete(_ key: String) -> Bool { Self.values[key] = nil; return true }
}
@MainActor final class ServerRegistry { static let shared = ServerRegistry(); var activeServerId: String? = "server-a" }
@MainActor final class TVSavedAccountStore { static let shared = TVSavedAccountStore(); var activeID: String? = "account-a" }
@MainActor final class AuthService { static let shared = AuthService(); var profileId: String? = "profile-a" }
@MainActor enum MediaServerProvider { case silo, emby; static var active: Self = .silo }
enum VividMediaType { static func isSeries(_ type: String) -> Bool { type == "series" } }
struct ItemDetail { let contentId: String; let type: String; let tmdbId: String?; var seriesId: String? = nil; var genres: [String]? = ["Drama"]; var studios: [String]? = nil; var networks: [String]? = nil; var year: Int? = 2020; var imdbId: String? = nil }
struct ItemVideo { let kind: String; let site: String; let siteKey: String; let name: String?; let language: String?; let isOfficial: Bool }
struct SimilarPosterItem { let contentId: String; init(detail: ItemDetail) { contentId = detail.contentId }; init(item: BrowseItem) { contentId = item.contentId } }
struct BrowseItem { let contentId: String; var type = "movie"; var title = "Title"; var genres: [String]? = ["Drama"]; var studios: [String]? = nil; var networks: [String]? = nil; var year: Int? = 2020 }
struct CatalogResponse { let items: [BrowseItem]; var total: Int? = 1000; var hasMore: Bool? = true; var snapshot: String? = nil }
enum CatalogSortKey { case title, ratingImdb }
struct CatalogFilterState { var sort = CatalogSortKey.title; var genres = Set<String>(); var studios = Set<String>(); var networks = Set<String>(); var matchAll = true }
enum BrowseMediaType: String { case movie, series }
enum CatalogQueryBuilder {
    static func build(_ state: CatalogFilterState, libraryId: Int?, mediaType: BrowseMediaType, offset: Int, limit: Int, snapshot: String?, includeTotal: Bool) -> [String: String] {
        precondition(!state.matchAll && state.genres.contains("Drama"))
        precondition(libraryId == nil && ((limit == 1 && includeTotal) || (limit == 100 && !includeTotal)))
        return ["type": mediaType.rawValue, "offset": String(offset), "limit": String(limit)]
    }
}
@MainActor final class MetadataRequestPool {
    static let shared = MetadataRequestPool()
    var failedID: String?
    var count = 0
    var beforeReturn: (() -> Void)?
    func itemDetail(contentId: String) async throws -> ItemDetail {
        count += 1
        if contentId == failedID { throw URLError(.timedOut) }
        if let action = beforeReturn { beforeReturn = nil; action() }
        if contentId == "show" { return ItemDetail(contentId: contentId, type: "series", tmdbId: "42") }
        if contentId == "movie" { return ItemDetail(contentId: contentId, type: "movie", tmdbId: "7") }
        if contentId == "imdb-only" { return ItemDetail(contentId:contentId,type:"movie",tmdbId:nil,imdbId:"tt1234567") }
        if contentId == "no-id" { return ItemDetail(contentId: contentId, type: "movie", tmdbId: nil) }
        return ItemDetail(contentId: contentId, type: Stub.seriesMatches ? "series" : "movie", tmdbId: contentId == "1" ? "999" : contentId)
    }
}
@MainActor final class VividAPI {
    static let shared = VividAPI()
    var count = 0
    var failedTitle: String?
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
final class Stub: URLProtocol, @unchecked Sendable {
    static var calls = 0
    static var sparse = false
    static var seriesMatches = false
    static var similarCalls = 0
    static var status = 200
    static var useToken = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        precondition(request.url!.host == "api.themoviedb.org")
        precondition(request.value(forHTTPHeaderField:"X-Emby-Token") == nil)
        if Self.useToken {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-read-token")
            precondition(request.url!.query == nil)
        } else { precondition(request.url!.query!.contains("api_key=")) }
        let body: String
        switch request.url!.path {
        case "/3/find/tt1234567":
            precondition(request.url!.query!.contains("external_source=imdb_id"))
            body = #"{"movie_results":[{"id":7}],"tv_results":[]}"#
        case "/3/authentication": body = "{\"success\":true}"
        case "/3/tv/42": body = "{\"seasons\":[{\"season_number\":0},{\"season_number\":1},{\"season_number\":3}]}"
        case "/3/movie/7/recommendations", "/3/tv/42/recommendations":
            body = "{\"results\":[" + (1...(Self.sparse ? 3 : 15)).map { "{\"id\":\($0),\"title\":\"\($0)\"}" }.joined(separator: ",") + "]}"
        case "/3/movie/7/similar", "/3/tv/42/similar":
            Self.similarCalls += 1
            body = "{\"results\":[" + (3...18).map { "{\"id\":\($0),\"title\":\"\($0)\"}" }.joined(separator: ",") + "]}"
        default:
            let season = request.url!.path.contains("season/3")
            precondition(request.url!.path.hasSuffix("videos"))
            let keys = season ? ["season00001", "season00002", "season00003"] : ["main0000001", "main0000001", "movie000002", "movie000003", "movie000004"]
            body = "{\"results\":[" + keys.enumerated().map { index, key in
                "{\"key\":\"\(key)\",\"name\":\"\(index == 0 ? "Official Trailer" : "Trailer 2")\",\"site\":\"YouTube\",\"type\":\"Trailer\",\"official\":true,\"published_at\":\"2026-01-01\"}"
            }.joined(separator: ",") + "]}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        let store = TVTMDbStore(sessionConfiguration: config)
        let absent = try await store.videos(contentId: "movie")
        precondition(absent.isEmpty && Stub.calls == 0)
        let fakeKey = String(repeating: "a", count: 32)
        Stub.status = 401
        do { try await store.connect(fakeKey); fatalError("Invalid key accepted") }
        catch { precondition(!error.localizedDescription.contains(fakeKey)) }
        precondition(!store.isConfigured && SharedKeychain.values.isEmpty)
        Stub.status = 302
        do { try await store.connect(fakeKey); fatalError("Redirect accepted") } catch {}
        precondition(!store.isConfigured)
        Stub.status = 200
        try await store.connect(fakeKey)
        let movie = try await store.videos(contentId: "movie")
        precondition(movie.count == 3 && movie.first!.siteKey == "main0000001")
        precondition(Set(movie.map(\.siteKey)).count == 3)
        let beforeCache = Stub.calls
        _ = try await store.videos(contentId: "movie")
        precondition(Stub.calls == beforeCache)
        let show = try await store.videos(contentId: "show")
        precondition(show.map(\.siteKey) == ["main0000001", "season00001", "season00002"])
        // Library similarity requires neither a TMDb key nor TMDb identifiers.
        try store.disconnect()
        let library = TVLibrarySimilarityStore()
        let beforeLocal = Stub.calls
        let local = try await library.suggestions(contentId: "no-id")
        precondition(local.count == 10 && Stub.calls == beforeLocal)
        let beforeLocalCache = VividAPI.shared.count
        _ = try await library.suggestions(contentId: "no-id")
        precondition(VividAPI.shared.count == beforeLocalCache)
        precondition(beforeLocalCache == 4, "Read the count and sample all three catalog ranges")
        let offsets = TVLibrarySimilarityStore.candidateOffsets(total: 1000, seed: "source")
        for (index, offset) in offsets.enumerated() {
            precondition(offset >= 1000 * index / 3 && offset + 100 <= 1000 * (index + 1) / 3)
        }
        precondition(TVLibrarySimilarityStore.candidateOffsets(total: 0, seed: "source").isEmpty)
        precondition(TVLibrarySimilarityStore.candidateOffsets(total: 150, seed: "source") == [0, 100])
        let equalItems = (0..<30).map { BrowseItem(contentId: String($0), title: "A" + String($0)) }
        let tieSource = ItemDetail(contentId: "tie", type: "movie", tmdbId: nil)
        let firstOrder = TVLibrarySimilarityStore.rank(equalItems, relativeTo: tieSource).map(\.contentId)
        let renamedItems = equalItems.reversed().map { item -> BrowseItem in var copy = item; copy.title = "Z" + item.title; return copy }
        precondition(firstOrder == TVLibrarySimilarityStore.rank(renamedItems, relativeTo: tieSource).map(\.contentId))
        let beforeSource = MetadataRequestPool.shared.count
        _ = try await library.suggestions(contentId: "loaded", sourceDetail: ItemDetail(contentId: "loaded", type: "movie", tmdbId: nil))
        precondition(MetadataRequestPool.shared.count == beforeSource, "Loaded source must not be requested again")
        let source = ItemDetail(contentId: "source", type: "movie", tmdbId: nil, genres: ["Drama", "Crime"])
        let ranked = TVLibrarySimilarityStore.rank([
            BrowseItem(contentId: "source"),
            BrowseItem(contentId: "wrong-type", type: "series", genres: ["Drama", "Crime"]),
            BrowseItem(contentId: "unrelated", genres: ["Comedy"]),
            BrowseItem(contentId: "partial", genres: ["Drama"]),
            BrowseItem(contentId: "best", genres: ["crime", " DRAMA "]),
            BrowseItem(contentId: "best", genres: ["Drama"])
        ], relativeTo: source)
        precondition(ranked.map(\.contentId) == ["best", "partial"])
        let series = try await library.suggestions(contentId: "show")
        precondition(series.count == 10 && Stub.calls == beforeLocal)
        VividAPI.shared.beforeReturn = { AuthService.shared.profileId = "profile-local-change" }
        do { _ = try await library.suggestions(contentId: "different"); fatalError("Stale library results accepted") }
        catch is CancellationError {}
        AuthService.shared.profileId = "profile-a"
        try await store.connect(fakeKey)
        let noID = try await store.videos(contentId: "no-id")
        precondition(noID.isEmpty)
        let beforeFallback = Stub.calls
        let siloMissing = try await store.videos(contentId:"imdb-only")
        precondition(siloMissing.isEmpty && Stub.calls == beforeFallback)
        MediaServerProvider.active = .emby
        ServerRegistry.shared.activeServerId = "emby:server-a"
        store.reloadForCurrentProfile()
        precondition(!store.isConfigured)
        try await store.connect(fakeKey)
        let beforeEmbyFallback = Stub.calls
        let embyFallback = try await store.videos(contentId:"imdb-only")
        precondition(embyFallback.count == 3 && Stub.calls == beforeEmbyFallback + 2)
        MediaServerProvider.active = .silo
        ServerRegistry.shared.activeServerId = "server-a"
        MetadataRequestPool.shared.beforeReturn = { AuthService.shared.profileId = "profile-b" }
        do { _ = try await store.videos(contentId: "different"); fatalError("Stale context accepted") }
        catch is CancellationError {}
        store.reloadForCurrentProfile()
        precondition(!store.isConfigured)
        let retainedCredentials = SharedKeychain.values.count
        try store.disconnect()
        precondition(SharedKeychain.values.count == retainedCredentials)
        AuthService.shared.profileId = "profile-a"
        store.reloadForCurrentProfile()
        precondition(store.isConfigured)
        try store.disconnect()
        ServerRegistry.shared.activeServerId = "emby:server-a"
        store.reloadForCurrentProfile()
        precondition(store.isConfigured)
        try store.disconnect()
        ServerRegistry.shared.activeServerId = "server-a"
        store.reloadForCurrentProfile()
        precondition(!store.isConfigured && SharedKeychain.values.isEmpty)
        let beforeDisconnect = Stub.calls
        _ = try await store.videos(contentId: "movie")
        precondition(Stub.calls == beforeDisconnect)
        Stub.useToken = true
        try await store.connect("fake-read-token")
        precondition(store.isConfigured)
        print("TMDb checks passed: opt-in, auth errors, redirects, secure token header, trailer ranking/deduplication/cap, latest season, local similarity without TMDb, genre ranking, media scope, deduplication, ten-title cap, caches, identity changes, disconnect.")
    }
}
SWIFT
xcrun swiftc -swift-version 5 -parse-as-library "$test_dir/Client.swift" "$test_dir/Checks.swift" -o "$test_dir/checks"
"$test_dir/checks"
