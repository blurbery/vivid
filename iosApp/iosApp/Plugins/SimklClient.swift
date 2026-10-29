import Foundation

/// Vivid's Simkl app registration. The device sign-in has no client secret,
/// so the ID is public. While it's empty the plugin stays hidden.
enum SimklApp {
    static let clientID = "92173761926c2dc0b4a308fa2d6e5e06f675160c24f39165e3a990fc21d66237"
    static var isAvailable: Bool { !clientID.isEmpty }
    static let name = "vivid"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

enum SimklFailure: LocalizedError, Equatable {
    case notConfigured, signInRequired, signInExpired, signInTimedOut, missingWriteAccess
    case unauthorised, invalidResponse, quota(retryAfter: TimeInterval?), rateLimited, writeLocked
    case suspended, unavailable, storage, noProfile, incomplete

    var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Simkl isn’t available in this version of Vivid.")
        case .signInRequired, .unauthorised: return String(localized: "Sign in to Simkl to sync.")
        case .signInExpired: return String(localized: "Your Simkl sign-in has ended. Sign in again to keep syncing.")
        case .signInTimedOut: return String(localized: "The Simkl code expired. Sign in again to get a new one.")
        case .missingWriteAccess: return String(localized: "Simkl didn’t allow Vivid to update your lists. Sign in again and allow access.")
        case .invalidResponse: return String(localized: "Simkl returned an unreadable response. Sync will try again later.")
        case .quota: return String(localized: "Simkl’s daily request limit was reached. Sync will continue after it resets.")
        case .rateLimited, .writeLocked: return String(localized: "Simkl is busy. Sync will try again shortly.")
        case .suspended: return String(localized: "Simkl is limiting requests from Vivid. Sync will try again later.")
        case .unavailable: return String(localized: "Simkl is unavailable. Sync will try again later.")
        case .storage: return String(localized: "Vivid couldn’t save the Simkl sign-in securely.")
        case .noProfile: return String(localized: "Select a signed-in server account and viewing profile first.")
        case .incomplete: return String(localized: "Sync is incomplete. It will continue on the next check.")
        }
    }
}

struct SimklTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String

    var canWrite: Bool { scope.split(separator: " ").contains("media:write") }
}

struct SimklDeviceAuthorization: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let completeURL: URL?
    let expiresAt: Date
    let interval: TimeInterval
}

enum SimklTokenPoll: Equatable, Sendable {
    case pending, slowDown, expired
    case approved(SimklTokens)
}

/// External IDs, normalised. Simkl resolves these itself, so writes never
/// need a lookup first. Titles are never sent: a fuzzy title match could
/// mark the wrong item.
struct SimklIDs: Codable, Hashable, Sendable {
    var simkl: Int?
    var tmdb: String?
    var imdb: String?
    var tvdb: String?

    init(simkl: Int? = nil, tmdb: String? = nil, imdb: String? = nil, tvdb: String? = nil) {
        self.simkl = simkl.flatMap { $0 > 0 ? $0 : nil }
        self.tmdb = Self.number(tmdb)
        self.imdb = Self.imdbValue(imdb)
        self.tvdb = Self.number(tvdb)
    }

    init(json: [String: Any]?) {
        let json = json ?? [:]
        self.init(simkl: SimklClient.string(json["simkl"]).flatMap { Int($0) },
                  tmdb: SimklClient.string(json["tmdb"]),
                  imdb: SimklClient.string(json["imdb"]),
                  tvdb: SimklClient.string(json["tvdb"]))
    }

    var hasExternal: Bool { tmdb != nil || imdb != nil || tvdb != nil }
    var isEmpty: Bool { simkl == nil && !hasExternal }

    var payload: [String: Any] {
        var result: [String: Any] = [:]
        if let simkl { result["simkl"] = simkl }
        if let tmdb { result["tmdb"] = tmdb }
        if let imdb { result["imdb"] = imdb }
        if let tvdb { result["tvdb"] = tvdb }
        return result
    }

    /// The same title: an equal Simkl ID, or at least one shared external ID
    /// with no contradicting one from the same provider.
    func matches(_ other: SimklIDs) -> Bool {
        if let simkl, let theirs = other.simkl { return simkl == theirs }
        var shared = false
        for (mine, theirs) in [(tmdb, other.tmdb), (imdb, other.imdb), (tvdb, other.tvdb)] {
            guard let mine, let theirs else { continue }
            guard mine == theirs else { return false }
            shared = true
        }
        return shared
    }

    private static func number(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.allSatisfy(\.isASCII), let value = Int(raw), value > 0 else { return nil }
        return String(value)
    }

    private static func imdbValue(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), value.hasPrefix("tt"),
              value.count > 2, value.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return value
    }
}

enum SimklKind: String, Codable, Sendable { case movie, show }
enum SimklStatus: String, Codable, Sendable { case watching, plantowatch, hold, completed, dropped }

/// One title in the person's Simkl library. Anime sits with shows, or
/// with movies for an anime film.
struct SimklLibraryItem: Codable, Hashable, Sendable {
    let simkl: Int
    let kind: SimklKind
    /// The library type Simkl lists it under: movies, shows or anime.
    let type: String
    /// Nil for a status this version doesn't know. The title is still in
    /// the library, so it's never treated as removed.
    var status: SimklStatus?
    var ids: SimklIDs
    var title: String
    var year: Int?
    var watchedEpisodes: Int
    var lastWatchedAt: String?

    var isPlanToWatch: Bool { status == .plantowatch }
    var hasHistory: Bool { watchedEpisodes > 0 || lastWatchedAt != nil }
}

/// The `/sync/activities` timestamps Vivid compares between syncs.
struct SimklActivities: Codable, Equatable, Sendable {
    static let domains = ["movies": "movies", "tv_shows": "shows", "anime": "anime"]
    static let statusKeys = ["watching", "plantowatch", "hold", "completed", "dropped"]

    var all: String?
    var stamps: [String: [String: String]]

    init(all: String?, stamps: [String: [String: String]]) {
        self.all = all
        self.stamps = stamps
    }

    init(json: Any?) throws {
        guard let object = json as? [String: Any] else { throw SimklFailure.invalidResponse }
        if let raw = object["all"], !(raw is NSNull) {
            guard let value = raw as? String else { throw SimklFailure.invalidResponse }
            all = value
        } else { all = nil }
        var stamps: [String: [String: String]] = [:]
        for domain in Self.domains.keys {
            guard let block = object[domain] as? [String: Any] else { continue }
            var values: [String: String] = [:]
            for key in Self.statusKeys + ["removed_from_list"] {
                if let value = block[key] as? String { values[key] = value }
            }
            stamps[domain] = values
        }
        self.stamps = stamps
    }

    func statusesMoved(_ domain: String, since old: SimklActivities) -> Bool {
        Self.statusKeys.contains { stamps[domain]?[$0] != old.stamps[domain]?[$0] }
    }

    func removalsMoved(_ domain: String, since old: SimklActivities) -> Bool {
        stamps[domain]?["removed_from_list"] != old.stamps[domain]?["removed_from_list"]
    }
}

/// A finished movie or episode, sent with the movie's or the show's IDs.
struct SimklHistoryEntry: Equatable, Sendable {
    let ids: SimklIDs
    let season: Int?
    let episode: Int?
    let watchedAt: String

    var isMovie: Bool { season == nil }

    var payload: [String: Any] {
        var item: [String: Any] = ["ids": ids.payload]
        if let season, let episode {
            item["seasons"] = [["number": season, "episodes": [["number": episode, "watched_at": watchedAt]]]]
            // Silo, Emby and Jellyfin number anime seasons the way TVDB does.
            item["use_tvdb_anime_seasons"] = true
        } else {
            item["watched_at"] = watchedAt
        }
        return item
    }
}

struct SimklListItem: Equatable, Sendable {
    let kind: SimklKind
    let ids: SimklIDs

    var payload: [String: Any] { ["to": "plantowatch", "ids": ids.payload] }
}

struct SimklHistoryResult: Equatable, Sendable {
    var accepted: Set<Int>
    /// Recorded, but Simkl filed them as another kind of title.
    var mismatched: Set<Int>
}

private final class SimklRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Separate transport: media-server credentials never enter Simkl requests.
/// Requests go one at a time with at least a second between writes, as
/// Simkl asks.
final class SimklClient: @unchecked Sendable {
    private let session: URLSession
    private let clientID: String
    private let lock = NSLock()
    private var lastPost = Date.distantPast
    private var remaining: (count: Int, seen: Date)?

    init(configuration: URLSessionConfiguration = .ephemeral, clientID: String = SimklApp.clientID) {
        self.clientID = clientID
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: SimklRedirectPolicy(), delegateQueue: nil)
    }

    /// Requests left in today's allowance, from the last authorised response.
    /// A count from before Simkl's last daily reset no longer applies.
    var requestsRemaining: Int? {
        lock.withLock {
            guard let remaining,
                  Date() < remaining.seen.addingTimeInterval(Self.secondsUntilQuotaReset(from: remaining.seen)) else { return nil }
            return remaining.count
        }
    }

    /// Simkl's daily allowance resets at midnight in New York. This waits a
    /// few minutes past it.
    static func secondsUntilQuotaReset(from date: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(86_400)
        return max(60, midnight.timeIntervalSince(date) + 5 * 60)
    }

    // MARK: Sign-in

    func requestDeviceCode() async throws -> SimklDeviceAuthorization {
        let (status, json, _) = try await send("/oauth2/device", method: "POST",
            body: ["client_id": clientID, "scope": "media:read media:write"])
        guard status != 401 else { throw SimklFailure.notConfigured }
        guard (200..<300).contains(status) else { throw Self.failure(status: status, json: json, retryAfter: nil) }
        return try Self.parseDeviceAuthorization(json, now: Date())
    }

    func pollToken(deviceCode: String) async throws -> SimklTokenPoll {
        let (status, json, _) = try await send("/oauth2/token", method: "POST", body: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": clientID, "device_code": deviceCode])
        return try Self.parsePoll(status: status, json: json, now: Date())
    }

    func refresh(refreshToken: String) async throws -> SimklTokens {
        let (status, json, _) = try await send("/oauth2/token", method: "POST", body: [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken])
        switch status {
        case 200..<300: return try Self.parseTokens(json, now: Date())
        case 400, 401: throw SimklFailure.signInExpired
        default: throw Self.failure(status: status, json: json, retryAfter: nil)
        }
    }

    /// Ends the grant on Simkl. Best effort: the sign-in is already gone here.
    func revoke(token: String) async {
        _ = try? await send("/oauth2/revoke", method: "POST", body: ["client_id": clientID, "token": token])
    }

    // MARK: Reads

    func accountID(token: String) async throws -> Int {
        let json = try await api("/users/settings", token: token)
        guard let account = (json as? [String: Any])?["account"] as? [String: Any],
              let id = Self.string(account["id"]).flatMap({ Int($0) }), id > 0 else { throw SimklFailure.invalidResponse }
        return id
    }

    func activities(token: String) async throws -> SimklActivities {
        try SimklActivities(json: try await api("/sync/activities", token: token))
    }

    /// One type of the library, or what changed in it after `dateFrom`.
    func library(_ type: String, dateFrom: String?, token: String) async throws -> [SimklLibraryItem] {
        let query = dateFrom.map { ["date_from": $0] } ?? [:]
        do {
            return try Self.parseLibrary(try await api("/sync/all-items/\(type)", query: query, token: token))
        } catch SimklFailure.incomplete {
            // A very large library is read one status at a time.
            var result: [SimklLibraryItem] = []
            let statuses = type == "movies" ? ["plantowatch", "completed", "dropped"] : SimklActivities.statusKeys
            for status in statuses {
                result += try Self.parseLibrary(try await api("/sync/all-items/\(type)/\(status)", query: query, token: token))
            }
            return result
        }
    }

    /// Every Simkl ID of one type, to find titles removed from the library.
    func libraryIDs(_ type: String, token: String) async throws -> Set<Int> {
        try Self.parseLibraryIDs(try await api("/sync/all-items/\(type)",
            query: ["extended": "simkl_ids_only"], token: token))
    }

    /// Looks a title up by its external IDs. `/redirect` is cached and free
    /// of request limits; the answer is in the Location header.
    func resolve(_ ids: SimklIDs, kind: SimklKind) async throws -> Int? {
        guard ids.hasExternal else { return nil }
        var query = ["to": "simkl", "type": kind == .movie ? "movie" : "tv"]
        if let tmdb = ids.tmdb { query["tmdb"] = tmdb }
        if let imdb = ids.imdb { query["imdb"] = imdb }
        if let tvdb = ids.tvdb { query["tvdb"] = tvdb }
        let (status, _, http) = try await send("/redirect", query: query)
        guard (300..<400).contains(status) else {
            if status == 429 || status >= 500 { throw SimklFailure.unavailable }
            return nil
        }
        return Self.parseRedirect(http.value(forHTTPHeaderField: "Location"), kind: kind)
    }

    // MARK: Writes

    func addHistory(_ entries: [SimklHistoryEntry], token: String) async throws -> SimklHistoryResult {
        guard !entries.isEmpty else { return SimklHistoryResult(accepted: [], mismatched: []) }
        guard entries.count <= 50 else { throw SimklFailure.incomplete }
        let json = try await api("/sync/history", method: "POST", body: Self.historyBody(entries), token: token)
        return try Self.historyResult(json, entries: entries)
    }

    func addToPlanToWatch(_ items: [SimklListItem], token: String) async throws -> Set<Int> {
        guard !items.isEmpty else { return [] }
        guard items.count <= 50 else { throw SimklFailure.incomplete }
        let json = try await api("/sync/add-to-list", method: "POST", body: Self.listBody(items), token: token)
        return try Self.addResult(json, items: items)
    }

    /// Removes whole titles by Simkl ID. Callers only pass Plan to Watch
    /// titles without any watch history: this also deletes history.
    func removeFromLibrary(_ items: [SimklLibraryItem], token: String) async throws -> Set<Int> {
        guard !items.isEmpty else { return [] }
        guard items.count <= 50, items.allSatisfy({ $0.isPlanToWatch && !$0.hasHistory }) else { throw SimklFailure.incomplete }
        let json = try await api("/sync/history/remove", method: "POST", body: Self.removeBody(items), token: token)
        return try Self.removeResult(json, items: items)
    }

    // MARK: Transport

    private func api(_ path: String, method: String = "GET", query: [String: String] = [:],
                     body: [String: Any]? = nil, token: String) async throws -> Any? {
        var attempt = 0
        while true {
            attempt += 1
            let (status, json, http) = try await send(path, method: method, query: query, body: body, token: token)
            if let value = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"), let count = Int(value) {
                lock.withLock { remaining = (count, Date()) }
            }
            if (200..<300).contains(status) { return json }
            let error = Self.failure(status: status, json: json,
                                     retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            // A per-second limit clears in a second; a write lock in a few.
            switch error {
            case .rateLimited where attempt < 3:
                try await Task.sleep(for: .milliseconds(1500))
            case .writeLocked where attempt < 4:
                try await Task.sleep(for: .seconds(5))
            default:
                throw error
            }
        }
    }

    private func send(_ path: String, method: String = "GET", query: [String: String] = [:],
                      body: [String: Any]? = nil, token: String? = nil) async throws -> (Int, Any?, HTTPURLResponse) {
        guard !clientID.isEmpty else { throw SimklFailure.notConfigured }
        try Task.checkCancellation()
        if method == "POST" {
            let wait = lock.withLock { () -> TimeInterval in
                let next = max(Date(), lastPost.addingTimeInterval(1.1))
                lastPost = next
                return next.timeIntervalSinceNow
            }
            if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        }
        var components = URLComponents(string: "https://api.simkl.com" + path)!
        let required = ["client_id": clientID, "app-name": SimklApp.name, "app-version": SimklApp.version]
        components.queryItems = query.merging(required) { _, required in required }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Vivid/\(SimklApp.version)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            // Never surface URLSession's error, which carries the request URL.
            throw SimklFailure.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SimklFailure.invalidResponse }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return (http.statusCode, json, http)
    }

    static func failure(status: Int, json: Any?, retryAfter: TimeInterval?) -> SimklFailure {
        let code = ((json as? [String: Any])?["error"] as? String)?.lowercased() ?? ""
        switch status {
        case 400 where code == "rate_limit": return .writeLocked
        case 400 where code == "max_items": return .incomplete
        case 401: return .unauthorised
        case 403 where code == "insufficient_scope": return .missingWriteAccess
        case 403: return .signInRequired
        case 412: return .suspended
        case 429 where code == "rate_limit": return .rateLimited
        case 429: return .quota(retryAfter: retryAfter)
        case 400..<500: return .invalidResponse
        default: return .unavailable
        }
    }

    // MARK: Parsing

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? { string(value).flatMap { Int($0) } }

    static func parseDeviceAuthorization(_ json: Any?, now: Date) throws -> SimklDeviceAuthorization {
        guard let object = json as? [String: Any],
              let deviceCode = object["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = object["user_code"] as? String, !userCode.isEmpty,
              let verification = (object["verification_uri"] as? String).flatMap(URL.init(string:)),
              verification.scheme == "https", let expiresIn = int(object["expires_in"]), expiresIn > 0 else {
            throw SimklFailure.invalidResponse
        }
        let complete = (object["verification_uri_complete"] as? String).flatMap(URL.init(string:))
        return SimklDeviceAuthorization(deviceCode: deviceCode, userCode: userCode, verificationURL: verification,
            completeURL: complete?.scheme == "https" ? complete : nil,
            expiresAt: now.addingTimeInterval(TimeInterval(min(expiresIn, 1800))),
            interval: TimeInterval(min(max(int(object["interval"]) ?? 5, 5), 60)))
    }

    static func parsePoll(status: Int, json: Any?, now: Date) throws -> SimklTokenPoll {
        if (200..<300).contains(status) { return .approved(try parseTokens(json, now: now)) }
        switch (status, (json as? [String: Any])?["error"] as? String) {
        case (400, "authorization_pending"): return .pending
        case (400, "slow_down"), (429, _): return .slowDown
        case (400, "expired_token"), (400, "invalid_grant"), (400, "access_denied"): return .expired
        case (401, _): throw SimklFailure.notConfigured
        case (500..<600, _): throw SimklFailure.unavailable
        default: throw SimklFailure.invalidResponse
        }
    }

    static func parseTokens(_ json: Any?, now: Date) throws -> SimklTokens {
        func valid(_ value: Any?) -> String? {
            guard let token = value as? String, !token.isEmpty, token.count <= 4096,
                  !token.contains(where: { $0.isWhitespace }) else { return nil }
            return token
        }
        guard let object = json as? [String: Any], let access = valid(object["access_token"]),
              let refresh = valid(object["refresh_token"]), let expiresIn = int(object["expires_in"]), expiresIn > 0,
              (object["token_type"] as? String)?.lowercased() == "bearer" else { throw SimklFailure.invalidResponse }
        return SimklTokens(accessToken: access, refreshToken: refresh,
                           expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
                           scope: object["scope"] as? String ?? "")
    }

    /// Accepts the empty shapes Simkl uses for an empty library: `{}`, `[]` or `null`.
    static func parseLibrary(_ json: Any?) throws -> [SimklLibraryItem] {
        guard let object = try libraryObject(json) else { return [] }
        var items: [SimklLibraryItem] = []
        for (bucket, key) in [("movies", "movie"), ("shows", "show"), ("anime", "show")] {
            for row in try rows(object[bucket]) {
                guard let media = row[key] as? [String: Any] else { throw SimklFailure.invalidResponse }
                let ids = SimklIDs(json: media["ids"] as? [String: Any])
                guard let simkl = ids.simkl else { throw SimklFailure.invalidResponse }
                let kind: SimklKind = bucket == "movies" || (bucket == "anime" && row["anime_type"] as? String == "movie")
                    ? .movie : .show
                items.append(SimklLibraryItem(simkl: simkl, kind: kind, type: bucket,
                    status: (row["status"] as? String).flatMap(SimklStatus.init(rawValue:)), ids: ids,
                    title: media["title"] as? String ?? "", year: int(media["year"]),
                    watchedEpisodes: max(0, int(row["watched_episodes_count"]) ?? 0),
                    lastWatchedAt: row["last_watched_at"] as? String))
            }
        }
        return items
    }

    static func parseLibraryIDs(_ json: Any?) throws -> Set<Int> {
        guard let object = try libraryObject(json) else { return [] }
        var result = Set<Int>()
        for (bucket, key) in [("movies", "movie"), ("shows", "show"), ("anime", "show")] {
            for row in try rows(object[bucket]) {
                guard let simkl = SimklIDs(json: (row[key] as? [String: Any])?["ids"] as? [String: Any]).simkl else {
                    throw SimklFailure.invalidResponse
                }
                result.insert(simkl)
            }
        }
        return result
    }

    private static func libraryObject(_ json: Any?) throws -> [String: Any]? {
        if json == nil || json is NSNull { return nil }
        if let array = json as? [Any] {
            guard array.isEmpty else { throw SimklFailure.invalidResponse }
            return nil
        }
        guard let object = json as? [String: Any] else { throw SimklFailure.invalidResponse }
        return object
    }

    private static func rows(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let rows = raw as? [[String: Any]] else { throw SimklFailure.invalidResponse }
        return rows
    }

    static func parseRedirect(_ location: String?, kind: SimklKind) -> Int? {
        guard let location, let url = URL(string: location),
              url.host == nil || url.host == "simkl.com" || url.host == "www.simkl.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let id = Int(parts[1]), id > 0 else { return nil }
        switch parts[0] {
        case "movies": return kind == .movie ? id : nil
        case "tv": return kind == .show ? id : nil
        case "anime": return id
        default: return nil
        }
    }

    static func historyBody(_ entries: [SimklHistoryEntry]) -> [String: Any] {
        var body: [String: [[String: Any]]] = [:]
        for entry in entries { body[entry.isMovie ? "movies" : "shows", default: []].append(entry.payload) }
        return body
    }

    static func listBody(_ items: [SimklListItem]) -> [String: Any] {
        var body: [String: [[String: Any]]] = [:]
        for item in items { body[item.kind == .movie ? "movies" : "shows", default: []].append(item.payload) }
        return body
    }

    static func removeBody(_ items: [SimklLibraryItem]) -> [String: Any] {
        var body: [String: [[String: Any]]] = [:]
        for item in items {
            body[item.kind == .movie ? "movies" : "shows", default: []].append(["ids": ["simkl": item.simkl]])
        }
        return body
    }

    /// Confirms each entry from `not_found`, not from the status code. An
    /// entry Vivid can't account for keeps every entry pending; sending a
    /// watch again changes nothing on Simkl.
    static func historyResult(_ json: Any?, entries: [SimklHistoryEntry]) throws -> SimklHistoryResult {
        guard let object = json as? [String: Any], let added = object["added"] as? [String: Any] else {
            throw SimklFailure.invalidResponse
        }
        let unconfirmed = SimklHistoryResult(accepted: [], mismatched: [])
        let notFound = try notFoundObject(object)
        var missing = Set<Int>()
        for (bucket, movies) in [("movies", true), ("shows", false)] {
            for row in try rows(notFound[bucket]) {
                let ids = SimklIDs(json: row["ids"] as? [String: Any])
                let hits = entries.indices.filter { entries[$0].isMovie == movies && entries[$0].ids.matches(ids) }
                guard !ids.isEmpty, !hits.isEmpty else { return unconfirmed }
                missing.formUnion(hits)
            }
        }
        for row in try rows(notFound["episodes"]) {
            let ids = SimklIDs(json: row["ids"] as? [String: Any])
            var numbers: [(Int, Int)] = []
            for season in try rows(row["seasons"]) {
                guard let number = int(season["number"]) else { return unconfirmed }
                for episode in try rows(season["episodes"]) {
                    guard let value = int(episode["number"]) else { return unconfirmed }
                    numbers.append((number, value))
                }
            }
            for episode in try rows(row["episodes"]) {
                guard let value = int(episode["number"]) else { return unconfirmed }
                numbers.append((1, value))
            }
            let hits = entries.indices.filter { index in
                let entry = entries[index]
                return !entry.isMovie && entry.ids.matches(ids)
                    && numbers.contains { $0.0 == entry.season && $0.1 == entry.episode }
            }
            guard !ids.isEmpty, !hits.isEmpty else { return unconfirmed }
            missing.formUnion(hits)
        }
        let accepted = Set(entries.indices).subtracting(missing)
        var mismatched = Set<Int>()
        for status in try rows(added["statuses"]) {
            guard let request = status["request"] as? [String: Any], let response = status["response"] as? [String: Any],
                  let type = response["simkl_type"] as? String else { continue }
            let ids = SimklIDs(json: request["ids"] as? [String: Any])
            let sentMovie = request["type"] as? String == "movie"
            let filedMovie = type == "movie" || (type == "anime" && response["anime_type"] as? String == "movie")
            guard sentMovie != filedMovie else { continue }
            mismatched.formUnion(entries.indices.filter { entries[$0].isMovie == sentMovie && entries[$0].ids.matches(ids) })
        }
        return SimklHistoryResult(accepted: accepted, mismatched: mismatched.intersection(accepted))
    }

    static func addResult(_ json: Any?, items: [SimklListItem]) throws -> Set<Int> {
        guard let object = json as? [String: Any], object["added"] is [String: Any] else {
            throw SimklFailure.invalidResponse
        }
        let notFound = try notFoundObject(object)
        var missing = Set<Int>()
        for (bucket, kind) in [("movies", SimklKind.movie), ("shows", .show), ("anime", .show)] {
            for row in try rows(notFound[bucket]) {
                let ids = SimklIDs(json: row["ids"] as? [String: Any])
                let hits = items.indices.filter { (bucket == "anime" || items[$0].kind == kind) && items[$0].ids.matches(ids) }
                guard !ids.isEmpty, !hits.isEmpty else { return [] }
                missing.formUnion(hits)
            }
        }
        return Set(items.indices).subtracting(missing)
    }

    static func removeResult(_ json: Any?, items: [SimklLibraryItem]) throws -> Set<Int> {
        guard let object = json as? [String: Any], object["deleted"] is [String: Any] else {
            throw SimklFailure.invalidResponse
        }
        let notFound = try notFoundObject(object)
        var missing = Set<Int>()
        for bucket in ["movies", "shows"] {
            for row in try rows(notFound[bucket]) {
                guard let simkl = SimklIDs(json: row["ids"] as? [String: Any]).simkl else { return [] }
                missing.formUnion(items.indices.filter { items[$0].simkl == simkl })
            }
        }
        return Set(items.indices).subtracting(missing)
    }

    private static func notFoundObject(_ object: [String: Any]) throws -> [String: Any] {
        guard let raw = object["not_found"], !(raw is NSNull) else { return [:] }
        if let array = raw as? [Any], array.isEmpty { return [:] }
        guard let value = raw as? [String: Any] else { throw SimklFailure.invalidResponse }
        return value
    }
}

/// The two-way rules for Plan to Watch. Simkl moves a title out of Plan to
/// Watch once it's started or finished, so only a deletion or a drop on
/// Simkl takes a title off Vivid's watchlist, and Vivid never moves a title
/// Simkl already tracks.
enum SimklWatchlistPolicy {
    enum Action: Equatable { case none, addRemote, removeRemote, addLocal, removeLocal }

    /// `previousLocal` and `previousRemote` are the confirmed state from the
    /// last sync, nil before the first one. `remote` is nil when the title
    /// isn't in the Simkl library.
    static func action(local: Bool, remote: SimklLibraryItem?, mapped: Bool,
                       previousLocal: Bool?, previousRemote: Bool?) -> Action {
        let plan = remote?.isPlanToWatch == true
        guard let previousLocal, let previousRemote else {
            if local && remote == nil && mapped { return .addRemote }
            if !local && plan { return .addLocal }
            return .none
        }
        let localAdded = !previousLocal && local
        let localRemoved = previousLocal && !local
        let remoteAdded = !previousRemote && plan
        let remoteRemoved = previousRemote && !plan
        // Changes on both sides at once cancel out. The next sync records the result.
        if (localAdded || localRemoved) && (remoteAdded || remoteRemoved) { return .none }
        if localRemoved, let remote, plan, !remote.hasHistory { return .removeRemote }
        if localAdded && remote == nil && mapped { return .addRemote }
        if remoteRemoved && local && mapped && (remote == nil || remote?.status == .dropped) { return .removeLocal }
        if remoteAdded && !local { return .addLocal }
        return .none
    }
}

/// Removals only show up as missing IDs. A reply missing most of a library
/// type is more likely a bad answer than a mass deletion, and trusting it
/// would take those titles off the watchlist too.
enum SimklRemovalCheck {
    /// The Simkl IDs to drop, or nil to read the type again in full instead.
    static func removals(cached: [Int], present: Set<Int>) -> Set<Int>? {
        let gone = Set(cached).subtracting(present)
        guard gone.isEmpty || !present.isEmpty, gone.count <= max(5, cached.count / 4) else { return nil }
        return gone
    }
}

struct SimklSyncProgress: Equatable, Sendable {
    let step: Int
    let label: String
    var completed: Int = 0
    var total: Int? = nil

    var fraction: Double? {
        guard let total else { return nil }
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var description: String {
        let stage = String(localized: "Step \(step) of 3 · \(label)", comment: "Simkl sync progress, e.g. Step 1 of 3 · Reading your Simkl library")
        guard let total else { return stage }
        let done = min(max(0, completed), max(0, total))
        let count = max(0, total)
        return String(localized: "\(stage) · \(done) of \(count)", comment: "Simkl sync progress with a count, e.g. Step 2 of 3 · Matching · 5 of 20")
    }
}
