#!/bin/bash
# Runs Vivid's real Simkl client and sync store against a simulated Simkl and
# a simulated media server: sign-in, the first sync, completed watches, the
# watchlist rules, token renewal, the daily limit and disconnecting. Nothing
# reaches the network.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/vivid-simkl-check.XXXXXX)"
# The simulation's settings live in their own domain, removed afterwards.
trap 'rm -rf "$test_dir"; defaults delete vivid-simkl-simulation >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/vivid-simkl-simulation.plist"' EXIT
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
store = (root/'iosApp/iosApp/Plugins/SimklSyncStore.swift').read_text()
assert store.startswith('#if os(iOS) || os(tvOS)\n') and store.endswith('#endif\n')
assert 'init(client: SimklClient = SimklClient())' in store
(temporary/'Store.swift').write_text(store.removeprefix('#if os(iOS) || os(tvOS)\n').removesuffix('#endif\n'))
(temporary/'Client.swift').write_text((root/'iosApp/iosApp/Plugins/SimklClient.swift').read_text())
PY
cat > "$test_dir/Simulation.swift" <<'SWIFT'
import Foundation

// MARK: Stand-ins for the app

struct Account: Equatable { var serverId = "server"; var serverURL = "https://media.example"; var credentialGenerationID = UUID() }
struct CapturedOrdinaryRequestAuth { var account = Account(); var profileId: String? = "profile"; var accessToken: String? = "server-token" }
@MainActor final class TokenStore {
    static let shared = TokenStore()
    var auth = CapturedOrdinaryRequestAuth()
    func captureOrdinaryRequestAuth() async -> CapturedOrdinaryRequestAuth? { auth }
}
struct HTTPRequestIdentity { let serverId: String; let serverURL: String; let profileId: String; let clientFamily: String; let credentialGenerationID: UUID }
enum HTTPError: Error { case http(statusCode: Int, body: String) }
struct SharedKeychain {
    enum Audience { case currentUser }
    nonisolated(unsafe) static var values: [String: String] = [:]
    init(audience: Audience) {}
    func get(_ key: String) -> String? { Self.values[key] }
    @discardableResult func set(_ value: String, for key: String) -> Bool { Self.values[key] = value; return true }
    @discardableResult func delete(_ key: String) -> Bool { Self.values[key] = nil; return true }
}
@MainActor final class VividCloudPreferences {
    struct Profile { var id = "profile" }
    struct Saved { var serverID = "server"; var userID = "user"; var profile: Profile? = Profile() }
    static var matchingActiveAccount: Saved? = Saved()
    static let testScope = "simulation-" + UUID().uuidString.lowercased()
    static func pluginScope(server: String, user: String, profile: String) -> String { testScope }
}
struct UserData: Codable { var played: Bool? }
struct ItemDetail: Codable {
    var contentId: String
    var type: String
    var title: String
    var tmdbId: String?
    var imdbId: String?
    var tvdbId: String?
    var seriesId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var userData: UserData?
}
struct BrowseItem: Codable { var contentId: String }
struct CatalogResponse: Codable { var items: [BrowseItem]; var hasMore: Bool?; var total: Int?; var snapshot: String? }
@MainActor final class ResponseCache { static let shared = ResponseCache(); func remove(_ key: String) {}; func invalidateAllItemMetadata() {} }
enum CacheKey { static let watchlist = "watchlist" }

/// The media server: a catalogue, a watchlist and the watched flags.
@MainActor final class HTTPClient {
    static let shared = HTTPClient()
    struct Response { let data: Data }
    var items: [String: ItemDetail] = [:]
    var watchlist: [String] = []

    func requestData(method: String, path: String, query: [String: String] = [:],
                     requestIdentity: HTTPRequestIdentity) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        func page(_ ids: [String]) throws -> Response {
            Response(data: try encoder.encode(CatalogResponse(items: ids.map { BrowseItem(contentId: $0) },
                                                              hasMore: false, total: ids.count, snapshot: "snapshot")))
        }
        if method == "GET" && path == "/api/v1/watchlist" { return try page(watchlist) }
        if method == "GET" && path == "/api/v1/catalog" {
            let words = (query["q"] ?? "").lowercased()
            return try page(items.values.filter { $0.type == query["type"] && $0.title.lowercased().contains(words) }
                .map(\.contentId).sorted())
        }
        if method == "GET", path.hasPrefix("/api/v1/catalog/items/") {
            guard let item = items[String(path.dropFirst("/api/v1/catalog/items/".count))] else {
                throw HTTPError.http(statusCode: 404, body: "")
            }
            return Response(data: try encoder.encode(item))
        }
        if path.hasPrefix("/api/v1/watchlist/") {
            let id = String(path.dropFirst("/api/v1/watchlist/".count))
            if method == "PUT", !watchlist.contains(id) { watchlist.append(id) }
            if method == "DELETE" { watchlist.removeAll { $0 == id } }
            return Response(data: Data())
        }
        fatalError("Unexpected media-server request \(method) \(path)")
    }
}

// MARK: Simulated Simkl

/// Follows Simkl's documented API: the device sign-in, activity timestamps,
/// `date_from` deltas, ID-only lists, the write endpoints and their
/// `not_found` answers, token renewal and the daily allowance header. It
/// also records anything Vivid does that Simkl asks apps not to.
final class FakeSimkl: @unchecked Sendable {
    static let shared = FakeSimkl()
    let lock = NSLock()

    struct Title { let simkl: Int; let type: String; let ids: [String: Any]; let listed: [String: Any]; let name: String; let animeType: String? }
    struct Entry { var status: String; var watched: Int; var lastWatched: String?; var changed: String }

    var titles: [Int: Title] = [:]
    var library: [Int: Entry] = [:]
    var stamps: [String: [String: String]] = [:]
    var clock = 0
    var tokenNumber = 1
    var accessToken = "simkl_at_1"
    let refreshToken = "simkl_rt_1"
    var refreshAllowed = true
    var polls = 0
    var remaining = 450
    var brokenIDsReply = false
    /// Replies for the next ID lookups, before they work again.
    var lookupFailures: [Int] = []
    var failedActivities = 0

    var requests: [String] = []
    var lastHistoryBody: [String: Any] = [:]
    var watches: [String] = []
    var planAdds: [String] = []
    var removals: [String] = []
    var revoked: [String] = []
    var problems: [String] = []
    var lastPost: Date?
    var shortestPostGap = Double.infinity
    var inFlight = 0
    var mostInFlight = 0

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }()

    static func domain(_ type: String) -> String { type == "shows" ? "tv_shows" : type }
    static func string(_ value: Any?) -> String? { (value as? String) ?? (value as? NSNumber)?.stringValue }

    func touch(_ type: String, _ key: String) -> String {
        clock += 1
        let stamp = formatter.string(from: Date(timeIntervalSince1970: 1_793_318_400 + Double(clock)))
        stamps[Self.domain(type), default: [:]][key] = stamp
        return stamp
    }

    func put(_ simkl: Int, _ status: String, watched: Int = 0, lastWatched: String? = nil) {
        library[simkl] = Entry(status: status, watched: watched, lastWatched: lastWatched, changed: touch(titles[simkl]!.type, status))
    }

    func expireAccessToken() { tokenNumber += 1; accessToken = "simkl_at_\(tokenNumber)" }

    /// The person watching or deleting something with another Simkl app.
    func watchedElsewhere(_ simkl: Int) { put(simkl, "completed", lastWatched: "2026-10-30T09:00:00Z") }
    func deletedElsewhere(_ simkl: Int) { library[simkl] = nil; _ = touch(titles[simkl]!.type, "removed_from_list") }

    private func tokens() -> [String: Any] {
        ["access_token": accessToken, "refresh_token": refreshToken, "token_type": "Bearer",
         "expires_in": 604_800, "scope": "media:read media:write"]
    }

    private func resolve(_ ids: [String: Any], movie: Bool) -> Title? {
        titles.values.first { title in
            (title.type == "movies") == movie && ["simkl", "tmdb", "imdb", "tvdb"].contains { key in
                Self.string(ids[key]) != nil && Self.string(ids[key]) == Self.string(title.ids[key])
            }
        }
    }

    func handle(_ request: URLRequest, body: Data?) -> (Int, [String: String], Any?) {
        let method = request.httpMethod ?? "GET"
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let path = components.path
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var summary = "\(method) \(path)"
        if query["date_from"] != nil { summary += " since last sync" }
        if query["extended"] == "simkl_ids_only" { summary += " (IDs only)" }
        if path == "/oauth2/token", let grant = json?["grant_type"] as? String { summary += grant == "refresh_token" ? " (renew)" : " (poll)" }
        requests.append(summary)

        if components.host != "api.simkl.com" { problems.append("request to \(components.host ?? "?")") }
        if query["client_id"] != "test-client" || query["app-name"] != "vivid" || (query["app-version"] ?? "").isEmpty {
            problems.append("\(summary) was missing client_id, app-name or app-version")
        }
        if request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Vivid/") != true { problems.append("\(summary) had no User-Agent") }
        if method == "POST" {
            if let lastPost { shortestPostGap = min(shortestPostGap, Date().timeIntervalSince(lastPost)) }
            lastPost = Date()
        }

        switch (method, path) {
        case ("POST", "/oauth2/device"):
            polls = 0
            if json?["scope"] as? String != "media:read media:write" { problems.append("sign-in didn't ask to update lists") }
            return (200, [:], ["device_code": "device-secret", "user_code": "TEST-CODE", "verification_uri": "https://simkl.com/pin",
                               "verification_uri_complete": "https://simkl.com/pin?user_code=TEST-CODE", "expires_in": 900, "interval": 5])
        case ("POST", "/oauth2/token"):
            switch json?["grant_type"] as? String {
            case "urn:ietf:params:oauth:grant-type:device_code"?:
                guard json?["device_code"] as? String == "device-secret" else { return (400, [:], ["error": "invalid_grant"]) }
                polls += 1
                // The person hasn't approved it yet on the first check.
                if polls == 1 { return (400, [:], ["error": "authorization_pending"]) }
                return (200, [:], tokens())
            case "refresh_token"?:
                guard refreshAllowed, json?["refresh_token"] as? String == refreshToken else { return (400, [:], ["error": "invalid_grant"]) }
                expireAccessToken()
                return (200, [:], tokens())
            default:
                return (400, [:], ["error": "unsupported_grant_type"])
            }
        case ("POST", "/oauth2/revoke"):
            revoked.append(json?["token"] as? String ?? "")
            return (200, [:], [String: Any]())
        case ("GET", "/redirect"):
            if request.value(forHTTPHeaderField: "Authorization") != nil { problems.append("the ID lookup sent the sign-in token") }
            if !lookupFailures.isEmpty { return (lookupFailures.removeFirst(), [:], nil) }
            let movie = query["type"] == "movie"
            let found = titles.values.first { title in
                (title.type == "movies") == movie && ["tmdb", "imdb", "tvdb"].contains { query[$0] != nil && Self.string(title.ids[$0]) == query[$0] }
            }
            guard let found else { return (301, ["Location": "https://simkl.com/search/?q="], nil) }
            let section = found.type == "movies" ? "movies" : found.type == "shows" ? "tv" : "anime"
            return (301, ["Location": "https://simkl.com/\(section)/\(found.simkl)/title"], nil)
        default: break
        }

        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(accessToken)" else {
            return (401, [:], ["error": "invalid_token", "code": 401])
        }
        remaining -= 1
        let headers = ["X-RateLimit-Remaining": String(remaining)]
        switch (method, path) {
        case ("GET", "/users/settings"):
            return (200, headers, ["user": ["name": "tester"], "account": ["id": 4242, "type": "free"]])
        case ("GET", "/sync/activities"):
            if failedActivities > 0 {
                failedActivities -= 1
                return (503, headers, ["error": "unavailable"])
            }
            var object: [String: Any] = ["settings": ["all": NSNull()]]
            var all: String?
            for domain in ["movies", "tv_shows", "anime"] {
                var block: [String: Any] = [:]
                for key in SimklActivities.statusKeys + ["removed_from_list"] { block[key] = stamps[domain]?[key] ?? NSNull() }
                let latest = stamps[domain]?.values.max()
                block["all"] = latest ?? NSNull()
                object[domain] = block
                if let latest, latest > (all ?? "") { all = latest }
            }
            object["all"] = all ?? NSNull()
            return (200, headers, object)
        case ("POST", "/sync/history"):
            return (201, headers, history(json ?? [:]))
        case ("POST", "/sync/add-to-list"):
            return (201, headers, addToPlan(json ?? [:]))
        case ("POST", "/sync/history/remove"):
            return (201, headers, remove(json ?? [:]))
        default:
            if method == "GET", path.hasPrefix("/sync/all-items/") { return (200, headers, allItems(path, query)) }
            problems.append("unexpected request \(summary)")
            return (404, headers, ["error": "id_err"])
        }
    }

    private func allItems(_ path: String, _ query: [String: String]) -> Any {
        let parts = path.split(separator: "/").map(String.init)
        let type = parts[2]
        let status = parts.count > 3 ? parts[3] : nil
        let key = type == "movies" ? "movie" : "show"
        let rows = library.filter { simkl, entry in
            titles[simkl]?.type == type && (status == nil || entry.status == status)
                && (query["date_from"].map { entry.changed > $0 } ?? true)
        }.sorted { $0.key < $1.key }
        if query["extended"] == "simkl_ids_only" {
            if brokenIDsReply || rows.isEmpty { return [String: Any]() }
            let ids: [[String: Any]] = rows.map { row in [key: ["ids": ["simkl": row.key]]] }
            return [type: ids]
        }
        guard !rows.isEmpty else { return [String: Any]() }
        return [type: rows.map { simkl, entry -> [String: Any] in
            let title = titles[simkl]!
            var row: [String: Any] = ["status": entry.status, "watched_episodes_count": entry.watched,
                                      "last_watched_at": entry.lastWatched ?? NSNull(),
                                      key: ["title": title.name, "year": 2000, "ids": title.listed]]
            if let animeType = title.animeType { row["anime_type"] = animeType }
            return row
        }]
    }

    private func history(_ json: [String: Any]) -> [String: Any] {
        lastHistoryBody = json
        var counts = ["movies": 0, "shows": 0, "episodes": 0]
        var statuses: [[String: Any]] = []
        var notFound: [String: [[String: Any]]] = ["movies": [], "shows": [], "episodes": []]
        for (bucket, movie) in [("movies", true), ("shows", false)] {
            for item in json[bucket] as? [[String: Any]] ?? [] {
                if item["title"] != nil || item["year"] != nil { problems.append("a watch was sent with a title") }
                guard let title = resolve(item["ids"] as? [String: Any] ?? [:], movie: movie) else {
                    notFound[bucket]!.append(item)
                    continue
                }
                var entry = library[title.simkl] ?? Entry(status: "plantowatch", watched: 0, lastWatched: nil, changed: "")
                if movie {
                    entry.status = "completed"
                    entry.lastWatched = item["watched_at"] as? String
                    entry.changed = touch(title.type, "completed")
                    counts["movies"]! += 1
                    watches.append(title.name)
                } else {
                    if item["use_tvdb_anime_seasons"] as? Bool != true { problems.append("an episode was sent without TVDB season numbering") }
                    for season in item["seasons"] as? [[String: Any]] ?? [] {
                        for episode in season["episodes"] as? [[String: Any]] ?? [] {
                            entry.watched += 1
                            entry.lastWatched = episode["watched_at"] as? String
                            counts["episodes"]! += 1
                            watches.append("\(title.name) S\(season["number"] ?? "?")E\(episode["number"] ?? "?")")
                        }
                    }
                    entry.status = "watching"
                    entry.changed = touch(title.type, "watching")
                }
                library[title.simkl] = entry
                var echoed = item
                echoed["type"] = movie ? "movie" : "show"
                statuses.append(["request": echoed, "response": ["status": entry.status,
                    "simkl_type": title.type == "movies" ? "movie" : title.type == "shows" ? "tv" : "anime",
                    "anime_type": title.animeType ?? NSNull()]])
            }
        }
        var added: [String: Any] = counts
        added["statuses"] = statuses
        return ["added": added, "not_found": notFound]
    }

    private func addToPlan(_ json: [String: Any]) -> [String: Any] {
        var added: [String: [[String: Any]]] = ["movies": [], "shows": []]
        var notFound: [String: [[String: Any]]] = ["movies": [], "shows": []]
        for (bucket, movie) in [("movies", true), ("shows", false)] {
            for item in json[bucket] as? [[String: Any]] ?? [] {
                if item["title"] != nil { problems.append("a watchlist add was sent with a title") }
                guard item["to"] as? String == "plantowatch" else { problems.append("a title was moved to \(item["to"] ?? "?")"); continue }
                guard let title = resolve(item["ids"] as? [String: Any] ?? [:], movie: movie) else {
                    notFound[bucket]!.append(item)
                    continue
                }
                if let existing = library[title.simkl] { problems.append("\(title.name) was moved from \(existing.status) to Plan to Watch") }
                put(title.simkl, "plantowatch")
                added[bucket]!.append(item)
                planAdds.append(title.name)
            }
        }
        return ["added": added, "not_found": notFound]
    }

    private func remove(_ json: [String: Any]) -> [String: Any] {
        var deleted = ["movies": 0, "shows": 0, "episodes": 0]
        var notFound: [String: [[String: Any]]] = ["movies": [], "shows": [], "episodes": []]
        for bucket in ["movies", "shows"] {
            for item in json[bucket] as? [[String: Any]] ?? [] {
                let ids = item["ids"] as? [String: Any] ?? [:]
                if Set(ids.keys) != ["simkl"] || item["seasons"] != nil || item["episodes"] != nil {
                    problems.append("a removal wasn't by Simkl ID alone")
                }
                guard let simkl = Self.string(ids["simkl"]).flatMap({ Int($0) }), let entry = library[simkl],
                      let title = titles[simkl] else { notFound[bucket]!.append(item); continue }
                if entry.watched > 0 || entry.lastWatched != nil { problems.append("the watch history of \(title.name) was deleted") }
                if entry.status != "plantowatch" { problems.append("\(title.name) was removed from \(entry.status)") }
                library[simkl] = nil
                _ = touch(title.type, "removed_from_list")
                deleted[bucket]! += 1
                removals.append(title.name)
            }
        }
        return ["deleted": deleted, "not_found": notFound]
    }
}

final class FakeSimklProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fake = FakeSimkl.shared
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        // Holding each request briefly shows any that overlap.
        fake.lock.withLock { fake.inFlight += 1; fake.mostInFlight = max(fake.mostInFlight, fake.inFlight) }
        usleep(20_000)
        let (status, headers, json) = fake.lock.withLock { fake.handle(request, body: body) }
        fake.lock.withLock { fake.inFlight -= 1 }
        let data = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current })!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: The simulation

@MainActor var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1 }
    print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
}
@MainActor func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return condition()
}

@main @MainActor struct SimklSimulation {
    static let scope = VividCloudPreferences.testScope
    static let checkpointKey = "vivid.simkl.state.v1." + scope
    static let tokenKey = "vivid.simkl.tokens.v1." + scope
    static var cacheFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Simkl", isDirectory: true).appendingPathComponent("library-v1-\(scope).json")
    }

    @MainActor static func main() async {
        do { try await run() } catch { check(false, "the simulation stopped: \(error)") }
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        UserDefaults.standard.removePersistentDomain(forName: "vivid-simkl-simulation")
        if let cacheFile {
            try? FileManager.default.removeItem(at: cacheFile)
            let folder = cacheFile.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        print(failures == 0 ? "Simkl simulation passed." : "Simkl simulation failed: \(failures) checks.")
        exit(failures == 0 ? 0 : 1)
    }

    /// Like opening Vivid again: the checkpoint, the cached library and the
    /// Keychain carry over, and the next sync is due straight away unless
    /// `keepingSchedule` leaves the times saved by the last one.
    @MainActor static func relaunch(_ client: SimklClient, keepingSchedule: Bool = false) throws -> SimklSyncStore {
        if !keepingSchedule, let data = UserDefaults.standard.data(forKey: checkpointKey) {
            var state = try JSONDecoder().decode(SimklSyncStore.Checkpoint.self, from: data)
            state.lastAttempt = nil
            state.backoffUntil = nil
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: checkpointKey)
        }
        return SimklSyncStore(client: client)
    }

    @MainActor static func run() async throws {
        let fake = FakeSimkl.shared
        let server = HTTPClient.shared
        let auth = TokenStore.shared.auth
        func movie(_ id: String, _ title: String, tmdb: String, imdb: String? = nil) -> ItemDetail {
            ItemDetail(contentId: id, type: "movie", title: title, tmdbId: tmdb, imdbId: imdb, userData: UserData(played: false))
        }
        server.items = [
            "m-inception": movie("m-inception", "Inception", tmdb: "27205", imdb: "tt1375666"),
            "m-arrival": movie("m-arrival", "Arrival", tmdb: "329865"),
            "m-heat": movie("m-heat", "Heat", tmdb: "949"),
            "m-tenet": movie("m-tenet", "Tenet", tmdb: "577922"),
            "m-dune": movie("m-dune", "Dune", tmdb: "693134"),
            "m-up": movie("m-up", "Up", tmdb: "14160"),
            "s-bebop": ItemDetail(contentId: "s-bebop", type: "series", title: "Cowboy Bebop", tmdbId: "30991"),
            "s-bb": ItemDetail(contentId: "s-bb", type: "series", title: "Breaking Bad", tmdbId: "1396", imdbId: "tt0903747", tvdbId: "81189"),
            "e-bb-101": ItemDetail(contentId: "e-bb-101", type: "episode", title: "Pilot", seriesId: "s-bb",
                                   seasonNumber: 1, episodeNumber: 1, userData: UserData(played: false)),
        ]
        server.watchlist = ["m-arrival", "s-bebop", "m-inception"]
        fake.lock.withLock {
            func title(_ simkl: Int, _ type: String, _ name: String, _ ids: [String: Any], listed: [String: Any]? = nil, anime: String? = nil) {
                var all = ids
                all["simkl"] = simkl
                var shown = listed ?? ids
                shown["simkl"] = simkl
                fake.titles[simkl] = .init(simkl: simkl, type: type, ids: all, listed: shown, name: name, animeType: anime)
            }
            title(472214, "movies", "Inception", ["tmdb": "27205", "imdb": "tt1375666"])
            title(1015859, "movies", "Dune", ["tmdb": "693134"])
            title(500, "movies", "Heat", ["tmdb": "949"])
            title(600, "movies", "Arrival", ["tmdb": "329865"])
            title(700, "movies", "Tenet", ["tmdb": "577922"])
            title(800, "movies", "Up", ["tmdb": "14160"])
            title(11121, "shows", "Breaking Bad", ["tmdb": "1396", "tvdb": "81189", "imdb": "tt0903747"])
            // Simkl often lists anime under anime IDs only.
            title(37089, "anime", "Cowboy Bebop", ["tmdb": "30991", "mal": "1"], listed: ["mal": "1"], anime: "tv")
            fake.put(472214, "plantowatch")
            fake.put(500, "plantowatch")
            fake.put(700, "plantowatch")
            fake.put(37089, "completed", watched: 26, lastWatched: "2026-01-02T00:00:00Z")
            fake.put(11121, "watching", watched: 3, lastWatched: "2026-02-03T00:00:00Z")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeSimklProtocol.self]
        let client = SimklClient(configuration: configuration, clientID: "test-client")
        var mark = 0
        func since() -> [String] { fake.lock.withLock { Array(fake.requests[mark...]) } }
        func step(_ title: String) { print(title); mark = fake.lock.withLock { fake.requests.count } }
        print("Simkl: Inception, Heat and Tenet on Plan to Watch; Cowboy Bebop completed (anime IDs only); Breaking Bad watching.")
        print("Server watchlist: Arrival, Cowboy Bebop, Inception.\n")

        step("1. Sign in with a code")
        var store = SimklSyncStore(client: client)
        store.reload()
        store.beginSignIn()
        check(await waitUntil(5) { store.signIn != nil }, "shows a code to approve")
        check(store.signIn?.userCode == "TEST-CODE" && store.signIn?.approvalURL.absoluteString == "https://simkl.com/pin?user_code=TEST-CODE",
              "the code is TEST-CODE and the approval link has it filled in")
        check(await waitUntil(20) { store.isConnected }, "connects once the code is approved, after one 'not yet' answer")
        check(since().filter { $0 == "POST /oauth2/token (poll)" }.count == 2, "checked for approval twice, five seconds apart")
        check(SharedKeychain.values[tokenKey]?.contains("simkl_rt_1") == true, "keeps the sign-in in this device's Keychain")

        step("\n2. First sync (starts by itself after signing in)")
        check(await waitUntil(30) { !store.isSyncing && store.status == "Watched history and watchlist are synced." },
              "finishes: \(store.status)")
        // It starts the moment sign-in finishes, so count from the start.
        let first = fake.lock.withLock { fake.requests }
        check(["movies", "shows", "anime"].allSatisfy { type in first.filter { $0 == "GET /sync/all-items/\(type)" }.count == 1 },
              "reads the whole library once, one type at a time")
        check(fake.planAdds == ["Arrival"], "adds Arrival, only on the server watchlist, to Plan to Watch (added: \(fake.planAdds))")
        check(server.watchlist.contains("m-heat") && server.watchlist.contains("m-tenet"), "adds Heat and Tenet from Plan to Watch to the server watchlist")
        check(fake.lock.withLock { fake.library[37089]?.status } == "completed", "leaves Cowboy Bebop completed: matched through Simkl's ID lookup, not moved back")
        check(!server.watchlist.contains("s-bb"), "doesn't add Breaking Bad, which Simkl has as Watching")
        check(fake.removals.isEmpty, "removes nothing")

        step("\n3. Sync now straight after")
        await store.sync(force: true)
        check(since().isEmpty, "waits a minute before another manual sync")

        step("\n4. Finish Dune and Breaking Bad S1E1")
        server.items["m-dune"]?.userData = UserData(played: true)
        server.items["e-bb-101"]?.userData = UserData(played: true)
        await store.completedWatch(contentID: "m-dune", expected: auth)
        await store.completedWatch(contentID: "e-bb-101", expected: auth)
        store = try relaunch(client)
        await store.sync()
        let watched = since()
        check(fake.watches == ["Dune", "Breaking Bad S1E1"], "sends both watches in one batch (\(fake.watches))")
        check(watched.filter { $0 == "POST /sync/history" }.count == 1, "uses one history request")
        let body = fake.lock.withLock { fake.lastHistoryBody }
        let sentMovie = (body["movies"] as? [[String: Any]])?.first
        let sentShow = (body["shows"] as? [[String: Any]])?.first
        check((sentMovie?["ids"] as? [String: Any])?["tmdb"] as? String == "693134" && sentMovie?["watched_at"] != nil,
              "Dune goes by its TMDb ID with the time it finished")
        check((sentShow?["ids"] as? [String: Any])?["tvdb"] as? String == "81189"
              && ((sentShow?["seasons"] as? [[String: Any]])?.first?["number"] as? Int) == 1,
              "the episode goes by the show's IDs with season 1, episode 1")
        check(watched.contains("GET /sync/all-items/movies since last sync") && !watched.contains("GET /sync/all-items/movies"),
              "reads only what changed since the last sync")
        check(fake.lock.withLock { fake.library[11121]?.watched } == 4, "Simkl now counts four Breaking Bad episodes")

        step("\n5. Nothing changed")
        await store.completedWatch(contentID: "m-dune", expected: auth)
        store = try relaunch(client)
        await store.sync()
        mark = fake.lock.withLock { fake.requests.count }
        store = try relaunch(client)
        await store.sync()
        check(since() == ["GET /sync/activities"], "an idle sync is one request: \(since())")
        check(fake.watches.count == 2, "doesn't send Dune again")

        step("\n6. Take Inception (unwatched) off the server watchlist")
        server.watchlist.removeAll { $0 == "m-inception" }
        await store.watchlistChanged(expected: auth)
        store = try relaunch(client)
        await store.sync()
        check(fake.removals == ["Inception"], "removes Inception from Plan to Watch, by its Simkl ID")

        step("\n7. Heat is watched in another app, then taken off the server watchlist")
        fake.lock.withLock { fake.watchedElsewhere(500) }
        store = try relaunch(client)
        await store.sync()
        check(server.watchlist.contains("m-heat"), "keeps Heat on the server watchlist after Simkl moves it to Completed")
        server.watchlist.removeAll { $0 == "m-heat" }
        store = try relaunch(client)
        await store.sync()
        check(fake.removals == ["Inception"] && fake.lock.withLock { fake.library[500]?.status } == "completed",
              "never removes Heat from Simkl, because it has been watched")

        step("\n8. Tenet is deleted on Simkl")
        fake.lock.withLock { fake.deletedElsewhere(700) }
        store = try relaunch(client)
        await store.sync()
        check(since().contains("GET /sync/all-items/movies (IDs only)"), "compares the list of Simkl IDs")
        check(!server.watchlist.contains("m-tenet"), "takes Tenet off the server watchlist")

        step("\n9. Simkl answers the removal check with an empty list")
        fake.lock.withLock {
            fake.brokenIDsReply = true
            _ = fake.touch("movies", "removed_from_list")
        }
        store = try relaunch(client)
        await store.sync()
        fake.lock.withLock { fake.brokenIDsReply = false }
        let reread = since()
        check(reread.contains("GET /sync/all-items/movies (IDs only)") && reread.contains("GET /sync/all-items/movies"),
              "doesn't trust it, and reads the movies again in full")
        check(server.watchlist.contains("m-arrival"), "Arrival stays on the server watchlist")

        step("\n9b. Simkl's ID lookup fails for a new watchlist title")
        server.watchlist.append("m-up")
        fake.lock.withLock { fake.lookupFailures = [408, 503] }
        await store.watchlistChanged(expected: auth)
        store = try relaunch(client)
        await store.sync()
        check(since().filter { $0 == "GET /redirect" }.count == 1 && !fake.planAdds.contains("Up"),
              "leaves Up alone after a timed-out lookup")
        // Nothing else changes, so only the failed lookup brings the watchlist back.
        mark = fake.lock.withLock { fake.requests.count }
        store = try relaunch(client)
        await store.sync()
        check(since().contains("GET /redirect") && !fake.planAdds.contains("Up"), "tries again on the next check, and leaves it alone when Simkl is down")
        store = try relaunch(client)
        await store.sync()
        check(fake.planAdds.last == "Up", "adds Up to Plan to Watch once the lookup works")

        step("\n9c. A sync fails, then Vivid is opened again")
        fake.lock.withLock { fake.failedActivities = 1 }
        server.items["m-up"]?.userData = UserData(played: true)
        store = try relaunch(client)
        await store.sync()
        check(since() == ["GET /sync/activities"] && store.status == "Simkl is unavailable. Sync will try again later.",
              "stops at the failed request: \(store.status)")
        mark = fake.lock.withLock { fake.requests.count }
        await store.completedWatch(contentID: "m-up", expected: auth)
        store = try relaunch(client, keepingSchedule: true)
        await store.sync()
        check(since().isEmpty, "waits out the backoff after opening again, even with a watch to send")
        store = try relaunch(client)
        await store.sync()
        check(fake.watches.last == "Up" && store.status == "Watched history and watchlist are synced.",
              "sends Up once the backoff ends: \(store.status)")

        step("\n10. The access token expires")
        fake.lock.withLock { fake.expireAccessToken() }
        store = try relaunch(client)
        await store.sync()
        check(since().contains("POST /oauth2/token (renew)"), "renews the token once")
        check(store.isConnected && store.status == "Watched history and watchlist are synced.", "and finishes the sync: \(store.status)")
        check(SharedKeychain.values[tokenKey]?.contains(fake.lock.withLock { fake.accessToken }) == true, "saves the new token")

        step("\n11. Vivid is removed from Simkl's Connected Apps")
        fake.lock.withLock {
            fake.refreshAllowed = false
            fake.expireAccessToken()
        }
        store = try relaunch(client)
        await store.sync()
        check(!store.isConnected && store.signInMessage == "Your Simkl sign-in has ended. Sign in again to keep syncing.",
              "signs out and says so: \(store.signInMessage ?? "no message")")
        check(SharedKeychain.values[tokenKey] == nil, "deletes the sign-in from Keychain")

        step("\n12. Sign in again")
        fake.lock.withLock { fake.refreshAllowed = true }
        store.beginSignIn()
        check(await waitUntil(20) { store.isConnected }, "connects")
        store = try relaunch(client)
        await store.sync()
        let again = since()
        check(!again.contains { $0.hasPrefix("GET /sync/all-items/") && !$0.contains("since last sync") && !$0.contains("IDs only") },
              "carries on from the saved library instead of reading it all again")
        check(fake.planAdds == ["Arrival", "Up"] && fake.removals == ["Inception"], "and changes nothing on either list")

        step("\n13. Simkl's daily allowance runs low")
        fake.lock.withLock {
            fake.remaining = 20
            fake.watchedElsewhere(600)
        }
        store = try relaunch(client)
        await store.sync()
        check(store.status == "Simkl’s daily request limit was reached. Sync will continue after it resets.",
              "stops before it runs out: \(store.status)")
        let used = fake.lock.withLock { fake.requests.count }
        store = try relaunch(client)
        await store.sync()
        await store.sync(force: true)
        check(fake.lock.withLock { fake.requests.count } == used, "and doesn't try again until Simkl resets it")

        step("\n14. Disconnect")
        try store.disconnect()
        check(await waitUntil(5) { fake.lock.withLock { fake.revoked } == ["simkl_rt_1"] }, "ends the sign-in on Simkl")
        check(!store.isConnected && SharedKeychain.values[tokenKey] == nil, "and removes it from this device")

        print("\nAcross the whole run")
        let summary = fake.lock.withLock { (fake.problems, fake.shortestPostGap, fake.mostInFlight, fake.requests.count) }
        check(summary.0.isEmpty, "nothing Simkl asks apps not to do: \(summary.0.isEmpty ? "none" : summary.0.joined(separator: "; "))")
        check(summary.1 >= 1.0, String(format: "at least a second between writes (shortest %.1f s)", summary.1))
        check(summary.2 == 1, "one request at a time")
        print("  \(summary.3) Simkl requests in total")
    }
}
SWIFT
swiftc -module-cache-path "$test_dir/module-cache" -parse-as-library \
  "$test_dir/Client.swift" "$test_dir/Store.swift" "$test_dir/Simulation.swift" -o "$test_dir/vivid-simkl-simulation"
"$test_dir/vivid-simkl-simulation"
