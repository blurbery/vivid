import Foundation

/// A leaf identifier. Episode IDs always refer to the episode, never its show.
struct MDBListItemID: Codable, Hashable, Sendable {
    let type: String
    let provider: String
    let value: String

    init?(type: String, provider: String, value: String?) {
        guard type == "movie" || type == "episode", let rawValue = value else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "imdb" {
            guard type == "movie", value.hasPrefix("tt"),
                  value.dropFirst(2).allSatisfy(\.isNumber), value.count > 2 else { return nil }
        } else {
            guard provider == "tmdb" || (type == "episode" && provider == "tvdb"),
                  let number = Int(value), number > 0 else { return nil }
        }
        self.type = type
        self.provider = provider
        self.value = provider == "imdb" ? value : String(Int(value)!)
    }

    var key: String { "\(type):\(provider):\(value)" }
    var payload: [String: Any] {
        ["ids": [provider: provider == "imdb" ? value as Any : Int(value)! as Any]]
    }
}

struct MDBListHistoryItem: Sendable {
    let ids: Set<MDBListItemID>
}

enum MDBListFailure: LocalizedError {
    case invalidKey, invalidResponse, quota, unavailable, storage, noProfile, incomplete
    var errorDescription: String? {
        switch self {
        case .invalidKey: return "Check your MDBList API key and try again."
        case .invalidResponse: return "MDBList returned an unreadable response. Sync will try again later."
        case .quota: return "MDBList’s request limit was reached. Sync will try again later."
        case .unavailable: return "MDBList is unavailable. Sync will try again later."
        case .storage: return "Vivid couldn’t save the MDBList connection securely."
        case .noProfile: return "Select a signed-in server account and viewing profile first."
        case .incomplete: return "Sync is incomplete. It will continue on the next check."
        }
    }
}

private final class MDBListRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Separate transport: media-server credentials never enter MDBList requests.
final class MDBListClient: @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: MDBListRedirectPolicy(), delegateQueue: nil)
    }

    func validate(key: String) async throws -> Int {
        let response = try await request("/user", key: key)
        guard let id = response["user_id"] as? Int, id > 0 else { throw MDBListFailure.invalidResponse }
        return id
    }

    func history(key: String) async throws -> [MDBListHistoryItem] {
        var result: [MDBListHistoryItem] = []
        for type in ["movie", "episode"] {
            var cursor: String?
            var seen = Set<String>()
            for page in 0..<1000 {
                try Task.checkCancellation()
                var query = ["mediatype": type, "limit": "1000"]
                if let cursor { query["cursor"] = cursor }
                let response = try await request("/sync/watched", key: key, query: query)
                let items = try Self.parseHistory(response, type: type)
                result += items
                guard let next = try Self.historyNextCursor(response, itemCount: items.count) else { break }
                guard seen.insert(next).inserted, page < 999 else { throw MDBListFailure.incomplete }
                cursor = next
            }
        }
        return result
    }

    static func historyNextCursor(_ response: [String: Any], itemCount: Int) throws -> String? {
        if let pagination = response["pagination"], !(pagination is [String: Any]) {
            throw MDBListFailure.invalidResponse
        }
        let pagination = response["pagination"] as? [String: Any]
        let raw = response["next_cursor"] ?? pagination?["next_cursor"]
        if let raw, !(raw is NSNull) {
            guard let next = raw as? String else { throw MDBListFailure.invalidResponse }
            if !next.isEmpty { return next }
        }
        guard response["_vividHasMore"] as? Bool != true else { throw MDBListFailure.incomplete }
        if let total = pagination?["total"] as? Int {
            let offset = pagination?["offset"] as? Int ?? 0
            guard total >= 0, offset >= 0, offset + itemCount >= total else { throw MDBListFailure.incomplete }
        } else if itemCount >= 1000 {
            throw MDBListFailure.incomplete
        }
        return nil
    }

    static func parseHistory(_ response: [String: Any], type: String) throws -> [MDBListHistoryItem] {
        let bucket = type == "movie" ? "movies" : "episodes"
        let rows: [[String: Any]]
        if let raw = response[bucket] {
            guard let values = raw as? [[String: Any]] else { throw MDBListFailure.invalidResponse }
            rows = values
        } else {
            let buckets = ["movies", "shows", "seasons", "episodes"].compactMap { response[$0] }
            let total = (response["pagination"] as? [String: Any])?["total"] as? Int
            guard total == 0 || (!buckets.isEmpty && buckets.allSatisfy { ($0 as? [Any])?.isEmpty == true }) else {
                throw MDBListFailure.invalidResponse
            }
            rows = []
        }
        return try rows.map { row in
            guard let item = row[type] as? [String: Any], let ids = item["ids"] as? [String: Any] else {
                throw MDBListFailure.invalidResponse
            }
            let resolved = Set(["tmdb", "imdb", "tvdb"].compactMap { provider -> MDBListItemID? in
                let raw = ids[provider]
                let value = (raw as? String) ?? (raw as? NSNumber)?.stringValue
                return MDBListItemID(type: type, provider: provider, value: value)
            })
            return MDBListHistoryItem(ids: resolved)
        }
    }

    func add(_ item: MDBListItemID, watchedAt: String, key: String) async throws {
        let accepted = try await addBatch([(item, watchedAt)], key: key)
        guard accepted.contains(item) else { throw MDBListFailure.incomplete }
    }

    /// Only confirmed entries advance the checkpoint; unresolved IDs can be retried later.
    func addBatch(_ items: [(MDBListItemID, String)], key: String) async throws -> Set<MDBListItemID> {
        guard !items.isEmpty else { return [] }
        guard items.count <= 50 else { throw MDBListFailure.incomplete }
        var body: [String: [[String: Any]]] = [:]
        for (item, date) in items {
            var entry = item.payload
            entry["watched_at"] = date
            body[item.type == "movie" ? "movies" : "episodes", default: []].append(entry)
        }
        let response = try await request("/sync/watched", key: key, method: "POST", body: body)
        guard let updated = response["updated"] as? [String: Any], !updated.isEmpty,
              let missing = response["not_found"] as? [String: Any] else { throw MDBListFailure.invalidResponse }
        let errors = response["errors"] as? [Any] ?? []
        if response["errors"] != nil && !(response["errors"] is [Any]) { throw MDBListFailure.invalidResponse }
        var hasMissing = false
        for value in missing.values {
            if let array = value as? [Any] { hasMissing = hasMissing || !array.isEmpty }
            else if let count = value as? Int, count >= 0 { hasMissing = hasMissing || count > 0 }
            else { throw MDBListFailure.invalidResponse }
        }
        if !hasMissing && errors.isEmpty { return Set(items.map { $0.0 }) }
        var confirmed = Set<MDBListItemID>()
        for play in response["plays"] as? [[String: Any]] ?? [] {
            guard let type = play["type"] as? String, let ids = play["ids"] as? [String: Any] else { continue }
            for (provider, value) in ids {
                if let id = MDBListItemID(type: type, provider: provider, value: (value as? String) ?? (value as? NSNumber)?.stringValue) { confirmed.insert(id) }
            }
        }
        return Set(items.map { $0.0 }).intersection(confirmed)
    }

    func watchlist(key: String) async throws -> [MDBListWatchlistItem] {
        var result: [MDBListWatchlistItem] = []
        for type in ["movie", "show"] {
            var cursor: String?
            var seen = Set<String>()
            for page in 0..<1000 {
                var query = ["mediatype": type, "limit": "1000"]
                if let cursor { query["cursor"] = cursor }
                let response = try await request("/watchlist/items", key: key, query: query)
                let items = try Self.parseWatchlist(response, type: type)
                result += items
                guard let next = try Self.watchlistNextCursor(response, itemCount: items.count) else { break }
                guard seen.insert(next).inserted, page < 999 else { throw MDBListFailure.incomplete }
                cursor = next
            }
        }
        return result
    }

    static func watchlistNextCursor(_ response: [String: Any], itemCount: Int) throws -> String? {
        if let pagination = response["pagination"], !(pagination is [String: Any]) {
            throw MDBListFailure.invalidResponse
        }
        let raw = response["next_cursor"] ?? (response["pagination"] as? [String: Any])?["next_cursor"]
        if let raw, !(raw is NSNull) {
            guard let next = raw as? String else { throw MDBListFailure.invalidResponse }
            if !next.isEmpty { return next }
        }
        guard response["_vividHasMore"] as? Bool != true, itemCount < 1000 else {
            throw MDBListFailure.incomplete
        }
        return nil
    }

    static func parseWatchlist(_ response: [String: Any], type: String) throws -> [MDBListWatchlistItem] {
        let bucket = type == "movie" ? "movies" : "shows"
        let rows: [[String: Any]]
        if let raw = response[bucket] {
            guard let values = raw as? [[String: Any]] else { throw MDBListFailure.invalidResponse }
            rows = values
        } else {
            let buckets = ["movies", "shows"].compactMap { response[$0] }
            let total = (response["pagination"] as? [String: Any])?["total"] as? Int
            guard total == 0 || (!buckets.isEmpty && buckets.allSatisfy { ($0 as? [Any])?.isEmpty == true }) else {
                throw MDBListFailure.invalidResponse
            }
            rows = []
        }
        return try rows.map { row in
            let ids = row["ids"] as? [String: Any] ?? [:]
            func string(_ value: Any?) -> String? {
                (value as? String) ?? (value as? NSNumber)?.stringValue
            }
            guard let item = MDBListWatchlistItem(type: type, title: row["title"] as? String ?? "",
                tmdb: string(ids["tmdb"] ?? row["id"]), imdb: string(ids["imdb"] ?? row["imdb_id"])) else {
                throw MDBListFailure.invalidResponse
            }
            return item
        }
    }

    func setWatchlist(_ item: MDBListWatchlistItem, present: Bool, key: String) async throws {
        // The shared remove schema is inconsistent about result counters. The sync
        // coordinator verifies membership with a fresh snapshot before acknowledging.
        _ = try await request(present ? "/watchlist/items/add" : "/watchlist/items/remove",
            key: key, method: "POST",
            body: [item.type == "movie" ? "movies" : "shows": [["ids": item.payload]]])
    }

    private func request(_ path: String, key: String, method: String = "GET",
                         query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        var components = URLComponents(string: "https://api.mdblist.com" + path)!
        components.queryItems = (query.merging(["apikey": key]) { _, key in key }).sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Vivid/0.14.3", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            // Never surface URLSession's URL, which includes the personal API key.
            throw MDBListFailure.unavailable
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MDBListFailure.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MDBListFailure.invalidKey
        case 429: throw MDBListFailure.quota
        default: throw MDBListFailure.unavailable
        }
        let decoded = try? JSONSerialization.jsonObject(with: data)
        var value: [String: Any]
        if let object = decoded as? [String: Any] {
            value = object
        } else if ["/sync/watched", "/watchlist/items"].contains(path), let array = decoded as? [Any], array.isEmpty {
            value = ["movies": [], "episodes": [], "shows": []]
        } else { throw MDBListFailure.invalidResponse }

        value["_vividHasMore"] = ["true", "1"].contains(http.value(forHTTPHeaderField: "X-Has-More")?.lowercased() ?? "")
        return value
    }
}

/// Imports never infer an unwatched item from missing server state.
enum MDBListImportPolicy {
    static func isEligible(played: Bool?, inProgress: Bool?, position: Double?, locallyStarted: Bool) -> Bool {
        guard !locallyStarted, played == false, inProgress != true,
              let position, position.isFinite, position == 0 else { return false }
        return true
    }

    static func matches(_ ids: [MDBListItemID], records: [[MDBListItemID]]) -> Bool {
        let local = Set(ids)
        guard !local.isEmpty else { return false }
        let candidates = Set(records.map(Set.init)).filter { !$0.isDisjoint(with: local) }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        // An overlapping ID cannot override a contradictory ID from the same provider.
        return !local.contains { id in
            candidate.contains { $0.type == id.type && $0.provider == id.provider && $0.value != id.value }
        }
    }
}

/// Separate movie/show IDs keep watchlist matching out of episode history imports.
struct MDBListWatchlistItem: Codable, Hashable, Sendable {
    let type: String
    let title: String
    let tmdb: String?
    let imdb: String?

    init?(type: String, title: String, tmdb: String?, imdb: String?) {
        guard type == "movie" || type == "show" else { return nil }
        self.type = type
        self.title = title
        self.tmdb = MDBListItemID(type: "movie", provider: "tmdb", value: tmdb)?.value
        self.imdb = MDBListItemID(type: "movie", provider: "imdb", value: imdb)?.value
        guard self.tmdb != nil || self.imdb != nil else { return nil }
    }
    var keys: Set<String> {
        Set([tmdb.map { "\(type):tmdb:\($0)" }, imdb.map { "\(type):imdb:\($0)" }].compactMap { $0 })
    }
    var payload: [String: Any] {
        var result: [String: Any] = [:]
        if let tmdb { result["tmdb"] = Int(tmdb)! }
        if let imdb { result["imdb"] = imdb }
        return result
    }
    func matches(_ other: Self) -> Bool {
        guard type == other.type, !keys.isDisjoint(with: other.keys) else { return false }
        if let tmdb, let theirs = other.tmdb, tmdb != theirs { return false }
        if let imdb, let theirs = other.imdb, imdb != theirs { return false }
        return true
    }
}

enum MDBListWatchlistPolicy {
    static func desired(local: Bool, remote: Bool, previousLocal: Bool?, previousRemote: Bool?) -> Bool {
        if previousLocal == true && !local { return false }
        if previousRemote == true && !remote { return false }
        return local || remote
    }
}

struct MDBListSyncProgress: Equatable, Sendable {
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
        let stage = "Step \(step) of 4 · \(label)"
        guard let total else { return stage }
        return stage + " · \(min(max(0, completed), max(0, total))) of \(max(0, total))"
    }
}
