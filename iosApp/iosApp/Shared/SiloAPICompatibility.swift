import Foundation

/// The app keeps its existing domain models. This boundary translates only
/// Silo v2's wire contract; v1 requests and responses pass through unchanged.
enum SiloAPICompatibility {
    enum Failure: Error { case invalidDiscovery, unsupportedStatus(Int), missingWindow }
    private static let artworkURLFields: Set<String> = [
        "poster_url", "backdrop_url", "logo_url", "photo_url",
        "still_url", "thumbnail_url", "avatar_url", "image_url"
    ]

    static func legacyPath(_ url: URL) -> String? {
        guard let range = url.path.range(of: "/api/v1/") else { return nil }
        return String(url.path[range.lowerBound...])
    }

    static func discoveryURL(for url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let range = c.percentEncodedPath.range(of: "/api/v1/") else { return nil }
        c.percentEncodedPath = String(c.percentEncodedPath[..<range.lowerBound]) + "/api/v2/system/info"
        c.query = nil
        c.fragment = nil
        return c.url
    }

    static func route(_ path: String, method: String) -> (String, String) {
        var p = path.replacingOccurrences(of: "/api/v1/", with: "/api/v2/", range: path.range(of: "/api/v1/"))
        var verb = method
        let aliases = [
            "/api/v1/auth/me": "/api/v2/account/me",
            "/api/v1/health": "/api/v2/system/info",
            "/api/v1/images/capability": "/api/v2/images/capabilities",
            "/api/v1/playback/capability": "/api/v2/playback/capabilities",
            "/api/v1/downloads/capability": "/api/v2/capabilities/downloads",
            "/api/v1/metadata/ai/status": "/api/v2/capabilities/metadata-ai",
        ]
        p = aliases[path] ?? p
        if path == "/api/v1/auth/setup", method == "GET" { p = "/api/v2/system/setup" }
        if path.hasPrefix("/api/v1/people/") || path.hasPrefix("/api/v1/items/") {
            p = p.replacingOccurrences(of: "/api/v2/", with: "/api/v2/catalog/")
        }
        if method == "PUT", path.hasPrefix("/api/v1/profiles/") || path.hasPrefix("/api/v1/collections/") {
            let parts = path.split(separator: "/")
            if (parts.count == 4 && !["sort-preference", "order", "groups"].contains(String(parts[3]))) || (parts.count == 5 && parts[3] == "groups" && parts[4] != "order") { verb = "PATCH" }
        }
        while p.hasSuffix("/") { p.removeLast() }
        return (p, verb)
    }

    static func request(_ original: URLRequest) throws -> URLRequest {
        guard let url = original.url, let path = legacyPath(url),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let range = c.percentEncodedPath.range(of: "/api/v1/") else { return original }
        var result = original
        let (mapped, method) = route(path, method: original.httpMethod ?? "GET")
        // Preserve percent-encoded path arguments, including escaped slashes.
        let encodedPath = String(c.percentEncodedPath[range.lowerBound...])
        let encodedMapped = route(encodedPath, method: original.httpMethod ?? "GET").0
        c.percentEncodedPath = String(c.percentEncodedPath[..<range.lowerBound]) + encodedMapped
        result.httpMethod = method
        let personalSource = ["/api/v1/favorites": "favorites", "/api/v1/watchlist": "watchlist", "/api/v1/history": "history"][path]
        if mapped == "/api/v2/catalog" || (personalSource != nil && method == "GET") {
            if let personalSource, method == "GET" {
                c.percentEncodedPath = String(c.percentEncodedPath.prefix(upTo: c.percentEncodedPath.range(of: "/api/v2/")!.lowerBound)) + "/api/v2/catalog"
                var items = c.queryItems ?? []
                items.append(URLQueryItem(name: "source", value: personalSource))
                c.queryItems = items
            }
            var q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            if let order = q.removeValue(forKey: "order"), order == "desc", let sort = q["sort"], !sort.hasPrefix("-") { q["sort"] = "-" + sort }
            if let offset = q.removeValue(forKey: "offset"), offset != "0" || q["snapshot"] != nil { q["seek"] = offset }
            if let snapshot = q.removeValue(forKey: "snapshot"), !snapshot.isEmpty { q["cursor"] = snapshot }
            if let include = q.removeValue(forKey: "include_total") { q["skip_total"] = include == "false" ? "true" : "false" }
            let keys = q.keys.filter { $0.hasPrefix("groups[") }
            if !keys.isEmpty {
                var groups: [Int: [String: Any]] = [:]
                var rules: [Int: [Int: [String: Any]]] = [:]
                for key in keys {
                    let tokens = key.split(whereSeparator: { $0 == "[" || $0 == "]" }).map(String.init)
                    guard tokens.count >= 3, let g = Int(tokens[1]), let value = q.removeValue(forKey: key) else { continue }
                    if tokens[2] == "match" { groups[g, default: [:]]["match"] = value }
                    else if tokens.count >= 5, let r = Int(tokens[3]) {
                        if tokens.count == 6, let index = Int(tokens[5]) {
                            var values = rules[g]?[r]?[tokens[4]] as? [String] ?? []
                            while values.count <= index { values.append("") }
                            values[index] = value
                            rules[g, default: [:]][r, default: [:]][tokens[4]] = values
                        } else { rules[g, default: [:]][r, default: [:]][tokens[4]] = value }
                    }
                }
                for g in rules.keys { groups[g, default: [:]]["rules"] = rules[g]!.keys.sorted().map { rules[g]![$0]! } }
                q["groups"] = String(data: try JSONSerialization.data(withJSONObject: groups.keys.sorted().map { groups[$0]! }, options: [.sortedKeys]), encoding: .utf8)
            }
            c.queryItems = q.keys.sorted().map { URLQueryItem(name: $0, value: q[$0]) }
        }
        if mapped.hasPrefix("/api/v2/settings/values") {
            c.queryItems = (c.queryItems ?? []).flatMap { item -> [URLQueryItem] in
                guard ["keys", "library_ids", "series_ids"].contains(item.name), let value = item.value else { return [item] }
                return value.split(separator: ",", omittingEmptySubsequences: false).map {
                    URLQueryItem(name: item.name, value: String($0))
                }
            }
        }
        if mapped == "/api/v2/catalog/filters" {
            c.queryItems = (c.queryItems ?? []).map { item in
                item.name == "include_technical" ? URLQueryItem(name: "skip_technical", value: item.value == "true" ? "false" : "true") : item
            }
        }
        if mapped == "/api/v2/notifications/sync" {
            c.queryItems = (c.queryItems ?? []).compactMap { item in
                guard item.name == "since" else { return item }
                guard let value = item.value, value.hasPrefix("v2:") else { return nil }
                return URLQueryItem(name: "cursor", value: String(value.dropFirst(3)))
            }
        }
        result.url = c.url
        if let body = result.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            var encoded = encodeIDs(json)
            if mapped == "/api/v2/downloads", method == "POST", var object = encoded as? [String: Any] {
                object["media_file_id"] = object.removeValue(forKey: "file_id")
                if object["season_number"] != nil { object["series"] = true }
                encoded = object
            }
            if mapped == "/api/v2/sync/progress", var object = encoded as? [String: Any], let items = object["items"] as? [[String: Any]] {
                object["items"] = try items.map { item -> [String: Any] in
                    var item = item
                    if let seconds = item.removeValue(forKey: "position") as? Double { item["position_ms"] = try milliseconds(seconds) }
                    if let seconds = item.removeValue(forKey: "duration") as? Double { item["duration_ms"] = try milliseconds(seconds) }
                    return item
                }
                encoded = object
            }
            result.httpBody = try JSONSerialization.data(withJSONObject: encoded, options: [.fragmentsAllowed, .sortedKeys])
        }
        return result
    }

    private static func milliseconds(_ seconds: Double) throws -> Int64 {
        let value = (seconds * 1000).rounded()
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { throw Failure.invalidDiscovery }
        return Int64(value)
    }

    private static let numericIDs: Set<String> = ["file_id", "media_file_id", "last_file_id", "switched_file_id", "person_id", "library_id", "impersonator_user_id", "requested_media_file_id", "effective_media_file_id"]
    private static func encodeIDs(_ value: Any, key: String = "") -> Any {
        if let object = value as? [String: Any] { return object.mapValuesWithKeys { ["value", "headers", "diagnostics", "platform_details"].contains($0) ? $1 : encodeIDs($1, key: $0) } }
        if let array = value as? [Any] { return array.map { encodeIDs($0, key: key == "allowed_library_ids" ? "library_id" : key) } }
        if numericIDs.contains(key), let number = value as? NSNumber { return number.stringValue }
        return value
    }

    static func response(_ data: Data, path: String, requestURL: URL? = nil) throws -> Data {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return data }
        var value = decodeIDs(json, numericObjectID: path == "/api/v1/auth/me" || path == "/api/v1/user/libraries" || path.hasPrefix("/api/v1/people/"))
        if var object = value as? [String: Any] {
            if let items = object["items"] {
                if path == "/api/v1/user/libraries" { value = items }
                else {
                    let alias: String?
                    if path == "/api/v1/profiles" { alias = "profiles" }
                    else if path.hasSuffix("/seasons") { alias = "seasons" }
                    else if path.hasSuffix("/episodes") { alias = "episodes" }
                    else if path == "/api/v1/downloads" { alias = "downloads" }
                    else if path == "/api/v1/downloads/subscriptions" { alias = "subscriptions" }
                    else if path.hasSuffix("/manifests") { alias = "manifests" }
                    else if path == "/api/v1/collections" { alias = "collections" }
                    else if path == "/api/v1/recommendations/discover" { alias = "rows" }
                    else if path == "/api/v1/settings/values/effective" { alias = "settings" }
                    else if path == "/api/v1/notifications/sync" { alias = "notifications" }
                    else { alias = nil }
                    if let alias { object[alias] = items }
                }
            }
            if let page = object["page"] as? [String: Any] { object["has_more"] = page["has_more"] }
            if let cursor = object["window_cursor"] { object["snapshot"] = cursor }
            if path == "/api/v1/images/capability" { object["schema_version"] = 1 }
            if path == "/api/v1/sync/progress", let items = object["items"] as? [[String: Any]] {
                object["results"] = items.map { item -> [String: Any] in
                    var item = item
                    item["status"] = item["status"] as? String == "success" ? "ok" : "error"
                    return item
                }
            }
            if path == "/api/v1/settings/contract/capabilities" { object["revision"] = object["manifest_revision"] }
            if path == "/api/v1/notifications/sync" {
                let cursor = (object["page"] as? [String: Any])?["next_cursor"] as? String ?? object["sync_cursor"] as? String
                if let cursor { object["next_cursor"] = "v2:" + cursor }
            }
            if path == "/api/v1/metadata/ai/status" {
                object["enabled"] = (object["state"] as? String == "available") && (object["allowed"] as? Bool == true)
            }
            if path.hasPrefix("/api/v1/playback/") {
                object["native_api_major"] = 2
                if var plan = object["playback_plan"] as? [String: Any] {
                    plan["native_api_major"] = 2
                    object["playback_plan"] = plan
                }
            }
            if path == "/api/v1/playback/capability" {
                object["enabled"] = (object["state"] as? String == "available") && (object["allowed"] as? Bool == true)
                object["transformations"] = object["transformations"] ?? []
            }
            if path.hasPrefix("/api/v1/downloads/subscriptions"), object["id"] != nil {
                object = ["subscription": object, "registered": 0]
            }
            if path == "/api/v1/auth/device/poll", let tokens = object.removeValue(forKey: "tokens") as? [String: Any] {
                object.merge(tokens, uniquingKeysWith: { _, token in token })
            }
            if path == "/api/v1/health" { object["status"] = "ok" }
            if path != "/api/v1/user/libraries" { value = object }
        }
        // Silo v2 signs artwork with root-relative URLs. Resolve them against
        // the server that answered this request before image views fetch them.
        // Absolute CDN URLs and protocol-relative URLs retain their meaning.
        if let requestURL { value = resolveRelativeURLs(value, requestURL: requestURL) }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func resolveRelativeURLs(_ value: Any, requestURL: URL) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValuesWithKeys { key, child in
                if artworkURLFields.contains(key), let path = child as? String,
                   path.hasPrefix("/"), !path.hasPrefix("//"),
                   let absolute = artworkURL(path, relativeTo: requestURL) {
                    return absolute.absoluteString
                }
                return resolveRelativeURLs(child, requestURL: requestURL)
            }
        }
        if let array = value as? [Any] {
            return array.map { resolveRelativeURLs($0, requestURL: requestURL) }
        }
        return value
    }

    /// Resolve cached root-relative Silo artwork as well as fresh responses.
    /// A local Home snapshot can outlive the response conversion that wrote it.
    static func artworkURL(_ raw: String, relativeTo serverURL: URL?) -> URL? {
        guard let parsed = URL(string: raw) else { return nil }
        guard raw.hasPrefix("/"), !raw.hasPrefix("//") else { return parsed }
        guard let serverURL,
              ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""),
              serverURL.host != nil,
              let absolute = URL(string: raw, relativeTo: serverURL)?.absoluteURL,
              absolute.scheme == serverURL.scheme,
              absolute.host == serverURL.host,
              absolute.port == serverURL.port else { return nil }
        return absolute
    }

    private static func decodeIDs(_ value: Any, key: String = "", numericObjectID: Bool = false) -> Any {
        if var object = value as? [String: Any] {
            if ["intro", "credits"].contains(key) {
                object["start"] = object["start"] ?? object["start_seconds"]
                object["end"] = object["end"] ?? object["end_seconds"]
            }
            if key == "versions" {
                object["duration"] = object["duration"] ?? object["duration_seconds"]
            }
            return object.mapValuesWithKeys { field, child in
                if ["value", "headers", "diagnostics", "platform_details"].contains(field) { return child }
                // Credit person IDs are strings in Vivid; other person responses use integers.
                if field == "person_id", key == "cast" || key == "crew" { return child }
                let numeric = field == "user" || field == "cast" || field == "crew" || (field == "items" && numericObjectID)
                if field == "id", numericObjectID, let string = child as? String, let integer = Int(string) { return integer }
                return decodeIDs(child, key: field, numericObjectID: numeric)
            }
        }
        if let array = value as? [Any] { return array.map { decodeIDs($0, key: key == "allowed_library_ids" ? "library_id" : key, numericObjectID: numericObjectID) } }
        if numericIDs.contains(key), let string = value as? String, let integer = Int(string) { return integer }
        return value
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}

/// Discovery is scoped to the complete server base URL, never the active account.
/// Failures do not cache a downgrade. A short cache allows server upgrades in place.
actor SiloAPIDiscovery {
    static let shared = SiloAPIDiscovery()
    private var cache: [URL: (Bool, Date)] = [:]
    private var flights: [URL: Task<Bool, Error>] = [:]
    private let legacyOnly: Bool
    init(legacyOnly: Bool = false) { self.legacyOnly = legacyOnly }

    func usesV2(for url: URL, session: URLSession) async throws -> Bool {
        guard !legacyOnly, let discovery = SiloAPICompatibility.discoveryURL(for: url) else { return false }
        if let (value, expiry) = cache[discovery], expiry > Date() { return value }
        if let flight = flights[discovery] {
            let result = try await flight.value
            try Task.checkCancellation()
            return result
        }
        let flight = Task { try await Self.probe(discovery, session: session) }
        flights[discovery] = flight
        defer { flights[discovery] = nil }
        let result = try await flight.value
        try Task.checkCancellation()
        if cache.count >= 32 { cache.removeAll() }
        cache[discovery] = (result, Date().addingTimeInterval(60))
        return result
    }

    private static func probe(_ discovery: URL, session: URLSession) async throws -> Bool {
        var request = URLRequest(url: discovery, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately no account/profile headers on public discovery.
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SiloAPICompatibility.Failure.invalidDiscovery }
        let v2: Bool
        if http.statusCode == 404 || http.statusCode == 405 { v2 = false }
        else if http.statusCode == 200 {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let major = object["api_major"] as? Int {
                guard major == 2 else { throw SiloAPICompatibility.Failure.invalidDiscovery }
                v2 = true
            } else {
                // Older servers may serve their HTML application for unknown routes.
                guard http.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true else { throw SiloAPICompatibility.Failure.invalidDiscovery }
                v2 = false
            }
        } else { throw SiloAPICompatibility.Failure.unsupportedStatus(http.statusCode) }
        return v2
    }
}
