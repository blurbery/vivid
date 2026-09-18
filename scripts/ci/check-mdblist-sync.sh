#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/vivid-mdblist-check.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source=(root/'iosApp/iosApp/Plugins/MDBListSyncStore.swift').read_text()
assert 'client.history(' not in source and '"source": "history"' not in source
assert 'func decorate' not in source
(temporary/'Store.swift').write_text(source.removeprefix('#if os(iOS) || os(tvOS)\n').removesuffix('#endif\n'))
client=(root/'iosApp/iosApp/Plugins/MDBListClient.swift').read_text()
a=client.index('final class MDBListClient:'); b=client.index('\nenum MDBListImportPolicy',a)
(temporary/'Models.swift').write_text(client[:a]+client[b:])
view=(root/'iosApp/iosApp/Plugins/PluginsSettingsView.swift').read_text()
assert 'await store.sync(' not in view
api=(root/'iosApp/iosApp/Networking/VividAPI.swift').read_text()
method=api[api.index('    func setWatched('):api.index('    // --- Collections')]
assert method.index('try await http.requestData') < method.index('completedWatch(')
assert 'requestIdentity: identity' in method
bridge=(root/'iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift').read_text()
assert 'completedWatch(contentID: contentId, expected: connection.identity)' in bridge
PY
cat > "$test_dir/Checks.swift" <<'SWIFT'
import Foundation
struct Account: Equatable { var serverId = "server"; var serverURL = "url"; var credentialGenerationID = UUID() }
struct CapturedOrdinaryRequestAuth { var account = Account(); var profileId: String? = "profile"; var accessToken: String? = "token" }
@MainActor final class TokenStore { static let shared = TokenStore(); var auth = CapturedOrdinaryRequestAuth(); func captureOrdinaryRequestAuth() async -> CapturedOrdinaryRequestAuth? { auth } }
struct HTTPRequestIdentity { let serverId: String; let serverURL: String; let profileId: String; let clientFamily: String; let credentialGenerationID: UUID }
enum HTTPError: Error { case http(statusCode: Int, body: String) }
struct SharedKeychain {
    enum Audience { case currentUser }
    @MainActor static var values: [String: String] = [:]
    init(audience: Audience) {}
    @MainActor func get(_ key: String) -> String? { Self.values[key] }
}
@MainActor final class VividCloudPreferences {
    static let shared = VividCloudPreferences()
    static let testScope = "test-" + UUID().uuidString
    struct Profile { var id = "profile" }
    struct Saved { var serverID = "server"; var userID = "user"; var profile: Profile? = Profile() }
    static var matchingActiveAccount: Saved? = Saved()
    static func pluginScope(server: String, user: String, profile: String) -> String { testScope + profile }
    func setPluginCredential(_ value: String?, for key: String) throws { SharedKeychain.values[key] = value }
    func schedule() {}
}
struct ItemDetail: Codable { var type = "movie"; var title = "Movie"; var tmdbId: String? = "123"; var imdbId: String?; var tvdbId: String?; var userData: UserData? = UserData() }
struct UserData: Codable { var played = true }
struct BrowseItem: Codable { var contentId: String }
struct CatalogResponse: Codable { var items: [BrowseItem] = []; var hasMore: Bool? = false; var total: Int? = 0; var snapshot: String? }
@MainActor final class HTTPClient {
    static let shared = HTTPClient()
    var paths: [String] = []; var played = true
    struct Response { let data: Data }
    func requestData(method: String, path: String, query: [String:String] = [:], requestIdentity: HTTPRequestIdentity) async throws -> Response {
        paths.append(path)
        if path == "/api/v1/watchlist" { return Response(data: try JSONEncoder().encode(CatalogResponse())) }
        precondition(path.hasPrefix("/api/v1/catalog/items/"), "Unexpected historical scan")
        var detail = ItemDetail(); detail.userData?.played = played
        if path.hasSuffix("unmatched") { detail.tmdbId = "999" }
        if path.hasSuffix("next") { detail.tmdbId = "456" }
        return Response(data: try JSONEncoder().encode(detail))
    }
}
@MainActor final class ResponseCache { static let shared = ResponseCache(); func remove(_ key: String) {}; func invalidateAllItemMetadata() {} }
enum CacheKey { static let watchlist = "watchlist" }
@MainActor final class MDBListClient {
    static var additions: [String] = []; static var attempts: [String] = []
    static var fail = false; static var quota = false; static var validations = 0
    static var afterAdd: (() -> Void)?
    func validate(key: String) async throws -> Int { Self.validations += 1; if Self.quota { throw MDBListFailure.quota }; return 1 }
    func watchlist(key: String) async throws -> [MDBListWatchlistItem] { [] }
    func setWatchlist(_ item: MDBListWatchlistItem, present: Bool, key: String) async throws {}
    func add(_ item: MDBListItemID, watchedAt: String, key: String) async throws {
        Self.attempts.append(watchedAt)
        if item.value == "999" { throw MDBListFailure.incomplete }
        if Self.fail { throw MDBListFailure.unavailable }
        Self.additions.append(watchedAt)
        let callback = Self.afterAdd; Self.afterAdd = nil; callback?()
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let scope = VividCloudPreferences.testScope + "profile"
        let checkpointKey = "vivid.mdblist.history.v1." + scope
        defer {
            for suffix in ["profile", "other"] {
                for prefix in ["vivid.mdblist.history.v1.", "vivid.mdblist.watchlist.v1."] {
                    UserDefaults.standard.removeObject(forKey: prefix + VividCloudPreferences.testScope + suffix)
                }
            }
        }
        let old = Data(#"{"userID":1,"acknowledged":[],"exportedContentIDs":[],"pending":{},"remoteWatched":[]}"#.utf8)
        let checkpoint = try JSONDecoder().decode(MDBListSyncStore.Checkpoint.self, from: old)
        precondition(checkpoint.pendingCompletions == nil)
        let store = MDBListSyncStore()
        try await store.connect("test-key")
        precondition(store.isConnected && !store.isSyncing && MDBListClient.validations == 1)
        precondition(HTTPClient.shared.paths.isEmpty && MDBListClient.additions.isEmpty, "Connect only validates the key")
        await store.sync(force: true)
        precondition(HTTPClient.shared.paths == ["/api/v1/watchlist"])
        let auth = TokenStore.shared.auth
        await store.completedWatch(contentID: "movie", expected: auth)
        MDBListClient.fail = true
        await store.sync(force: true)
        let failedTimestamp = MDBListClient.attempts.last
        let reloaded = MDBListSyncStore()
        MDBListClient.fail = false
        await reloaded.sync(force: true)
        precondition(MDBListClient.additions.count == 1 && MDBListClient.additions.last == failedTimestamp)
        await reloaded.completedWatch(contentID: "movie", expected: auth)
        await reloaded.sync(force: true)
        precondition(MDBListClient.additions.count == 1)
        var wrong = auth; wrong.profileId = "other"
        await reloaded.completedWatch(contentID: "wrong", expected: wrong)
        await reloaded.sync(force: true)
        precondition(!HTTPClient.shared.paths.contains("/api/v1/catalog/items/wrong"))
        await reloaded.completedWatch(contentID: "unwatched", expected: auth)
        HTTPClient.shared.played = false
        await reloaded.sync(force: true)
        precondition(MDBListClient.additions.count == 1)
        try reloaded.disconnect()
        await reloaded.completedWatch(contentID: "disconnected", expected: auth)
        await reloaded.sync(force: true)
        precondition(!HTTPClient.shared.paths.contains("/api/v1/catalog/items/disconnected"))
        try await reloaded.connect("test-key")
        HTTPClient.shared.played = true
        let queued = MDBListSyncStore.Checkpoint(userID: 1, pendingCompletions: [
            "unmatched": "2026-09-18T01:00:00Z", "next": "2026-09-18T02:00:00Z"])
        UserDefaults.standard.set(try JSONEncoder().encode(queued), forKey: checkpointKey)
        let partial = MDBListSyncStore()
        let reads = HTTPClient.shared.paths.filter { $0 == "/api/v1/watchlist" }.count
        await partial.sync(force: true)
        precondition(MDBListClient.additions.count == 2)
        precondition(HTTPClient.shared.paths.filter { $0 == "/api/v1/watchlist" }.count == reads + 1)
        let remaining = try JSONDecoder().decode(MDBListSyncStore.Checkpoint.self, from: UserDefaults.standard.data(forKey: checkpointKey)!)
        precondition(remaining.pendingCompletions?.count == 1 && remaining.pendingCompletions?["unmatched"] != nil)
        UserDefaults.standard.set(try JSONEncoder().encode(MDBListSyncStore.Checkpoint(userID: 1)), forKey: checkpointKey)
        let race = MDBListSyncStore()
        await race.completedWatch(contentID: "next", expected: auth)
        MDBListClient.afterAdd = {
            TokenStore.shared.auth.profileId = "other"
            VividCloudPreferences.matchingActiveAccount?.profile?.id = "other"
        }
        await race.sync(force: true)
        let original = try JSONDecoder().decode(MDBListSyncStore.Checkpoint.self, from: UserDefaults.standard.data(forKey: checkpointKey)!)
        precondition(original.pendingCompletions?["next"] != nil)
        precondition(UserDefaults.standard.data(forKey: "vivid.mdblist.history.v1." + VividCloudPreferences.testScope + "other") == nil)
        TokenStore.shared.auth = auth
        VividCloudPreferences.matchingActiveAccount?.profile?.id = "profile"
        MDBListClient.quota = true
        await reloaded.sync(force: true)
        let attempts = MDBListClient.validations
        await reloaded.sync(force: true)
        precondition(MDBListClient.validations == attempts)
        print("MDBList checks passed: connect-only validation, no history scans, legacy checkpoint, retry/reload, timestamp preservation, duplicates, disconnect, unwatch, partial exports, account switching and quota backoff")
    }
}
SWIFT
swiftc -module-cache-path "$test_dir/module-cache" -parse-as-library "$test_dir/Store.swift" "$test_dir/Models.swift" "$test_dir/Checks.swift" -o "$test_dir/checks"
"$test_dir/checks"
