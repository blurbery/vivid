import Foundation

/// Lets code written against Silo's v1 API talk to a v2 server: requests are
/// rewritten on the way out and replies turned back into the v1 shapes the
/// models decode. Pure, stateless and safe on any thread.
enum SiloAPICompatibility {
    enum Failure: Error {
        case invalidDiscovery
        case unsupportedStatus(Int)
        case missingWindow
    }

    private static let legacyPrefix = "/api/v1/"
    private static let modernPrefix = "/api/v2/"

    static func legacyPath(_ url: URL) -> String? {
        let path = url.path
        guard let range = path.range(of: legacyPrefix) else { return nil }
        return String(path[range.lowerBound...])
    }

    static func discoveryURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        guard let range = path.range(of: legacyPrefix) else { return nil }
        components.percentEncodedPath = String(path[..<range.lowerBound]) + "/api/v2/system/info"
        components.percentEncodedQuery = nil
        components.percentEncodedFragment = nil
        return components.url
    }

    // MARK: - Routes

    private static let renamedRoutes = [
        "/api/v1/auth/me": "/api/v2/account/me",
        "/api/v1/health": "/api/v2/system/info",
        "/api/v1/images/capability": "/api/v2/images/capabilities",
        "/api/v1/playback/capability": "/api/v2/playback/capabilities",
        "/api/v1/downloads/capability": "/api/v2/capabilities/downloads",
        "/api/v1/metadata/ai/status": "/api/v2/capabilities/metadata-ai",
    ]

    /// The v2 path and method for a v1 path and method.
    static func route(_ path: String, method: String) -> (String, String) {
        var mapped: String
        if let renamed = renamedRoutes[path] {
            mapped = renamed
        } else if path == "/api/v1/auth/setup", method == "GET" {
            mapped = "/api/v2/system/setup"
        } else if path.hasPrefix("/api/v1/people/") || path.hasPrefix("/api/v1/items/") {
            mapped = replacingFirstLegacyPrefix(in: path).replacingOccurrences(of: modernPrefix, with: "/api/v2/catalog/")
        } else {
            mapped = replacingFirstLegacyPrefix(in: path)
        }
        while mapped.hasSuffix("/") { mapped.removeLast() }
        return (mapped, routedMethod(path: path, method: method))
    }

    private static func replacingFirstLegacyPrefix(in path: String) -> String {
        guard let range = path.range(of: legacyPrefix) else { return path }
        return path.replacingCharacters(in: range, with: modernPrefix)
    }

    /// v2 updates a single profile, collection or collection group with PATCH.
    private static func routedMethod(path: String, method: String) -> String {
        guard method == "PUT", path.hasPrefix("/api/v1/profiles/") || path.hasPrefix("/api/v1/collections/") else {
            return method
        }
        let pieces = path.split(separator: "/")
        if pieces.count == 4, !["sort-preference", "order", "groups"].contains(pieces[3]) { return "PATCH" }
        if pieces.count == 5, pieces[3] == "groups", pieces[4] != "order" { return "PATCH" }
        return method
    }

    // MARK: - Requests

    static func request(_ original: URLRequest) throws -> URLRequest {
        guard let url = original.url,
              let legacy = legacyPath(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let range = components.percentEncodedPath.range(of: legacyPrefix)
        else { return original }
        let encodedPath = components.percentEncodedPath
        let method = original.httpMethod ?? "GET"
        let (mappedPath, mappedMethod) = route(legacy, method: method)
        components.percentEncodedPath = String(encodedPath[..<range.lowerBound])
            + route(String(encodedPath[range.lowerBound...]), method: method).0

        if mappedPath == "/api/v2/catalog" {
            rewriteCatalogueQuery(&components, source: nil)
        } else if method == "GET", let list = personalList(legacy) {
            let path = components.percentEncodedPath
            let base = path.range(of: modernPrefix).map { String(path[..<$0.lowerBound]) } ?? path
            components.percentEncodedPath = base + "/api/v2/catalog"
            rewriteCatalogueQuery(&components, source: list)
        } else if mappedPath.hasPrefix("/api/v2/settings/values") {
            rewriteQuery(&components) { item in
                guard ["keys", "library_ids", "series_ids"].contains(item.name), let value = item.value else { return [item] }
                return value.split(separator: ",", omittingEmptySubsequences: false)
                    .map { URLQueryItem(name: item.name, value: String($0)) }
            }
        } else if mappedPath == "/api/v2/catalog/filters" {
            rewriteQuery(&components) { item in
                guard item.name == "include_technical" else { return [item] }
                return [URLQueryItem(name: "skip_technical", value: item.value == "true" ? "false" : "true")]
            }
        } else if mappedPath == "/api/v2/notifications/sync" {
            rewriteQuery(&components) { item in
                guard item.name == "since" else { return [item] }
                guard let value = item.value, value.hasPrefix("v2:") else { return [] }
                return [URLQueryItem(name: "cursor", value: String(value.dropFirst(3)))]
            }
        }

        var request = original
        request.url = components.url
        request.httpMethod = mappedMethod
        if let body = original.httpBody, let json = try? JSONSerialization.jsonObject(with: body) {
            let encoded = try rewriteBody(json, mappedPath: mappedPath, method: mappedMethod)
            request.httpBody = try JSONSerialization.data(withJSONObject: encoded, options: jsonOutput)
        }
        return request
    }

    private static func personalList(_ legacyPath: String) -> String? {
        switch legacyPath {
        case "/api/v1/favorites": "favorites"
        case "/api/v1/watchlist": "watchlist"
        case "/api/v1/history": "history"
        default: nil
        }
    }

    private static func rewriteQuery(_ components: inout URLComponents, _ transform: (URLQueryItem) -> [URLQueryItem]) {
        components.queryItems = (components.queryItems ?? []).flatMap(transform)
    }

    /// v2 pages the catalogue with `seek` and `cursor`, sorts descending with a
    /// leading `-`, and takes its filter groups as one JSON value.
    private static func rewriteCatalogueQuery(_ components: inout URLComponents, source: String?) {
        let incoming = components.queryItems ?? []
        var values: [String: String] = [:]
        for item in incoming { values[item.name] = item.value ?? "" }
        if let source { values["source"] = source }
        let hadSnapshot = values["snapshot"] != nil

        var groups = GroupFilters()
        var hasGroupKeys = false
        for (name, value) in values where name.hasPrefix("groups[") {
            hasGroupKeys = true
            if groups.absorb(name: name, value: value) { values[name] = nil }
        }
        if hasGroupKeys { values["groups"] = groups.json() }

        if let order = values.removeValue(forKey: "order"), order == "desc", let sort = values["sort"], !sort.hasPrefix("-") {
            values["sort"] = "-" + sort
        }
        if let offset = values.removeValue(forKey: "offset"), offset != "0" || hadSnapshot {
            values["seek"] = offset
        }
        if let snapshot = values.removeValue(forKey: "snapshot"), !snapshot.isEmpty {
            values["cursor"] = snapshot
        }
        if let includeTotal = values.removeValue(forKey: "include_total") {
            values["skip_total"] = includeTotal == "false" ? "true" : "false"
        }
        components.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// The catalogue's bracketed filter keys, gathered into groups and rules.
    private struct GroupFilters {
        private var matches: [Int: String] = [:]
        private var rules: [Int: [Int: [String: Any]]] = [:]

        private static func pieces(_ name: String) -> [String] {
            name.split(whereSeparator: { $0 == "[" || $0 == "]" }).map(String.init)
        }

        /// True when the name is consumed, either into a group or ignored.
        /// False when it stays in the query unchanged.
        mutating func absorb(name: String, value: String) -> Bool {
            let parts = Self.pieces(name)
            guard parts.count >= 3, let group = Int(parts[1]) else { return false }
            if parts[2] == "match" {
                matches[group] = value
                return true
            }
            guard parts.count >= 5, let rule = Int(parts[3]) else { return true }
            let field = parts[4]
            if parts.count == 6, let position = Int(parts[5]) {
                var list = rules[group]?[rule]?[field] as? [String] ?? []
                while list.count <= position { list.append("") }
                list[position] = value
                rules[group, default: [:]][rule, default: [:]][field] = list
            } else {
                rules[group, default: [:]][rule, default: [:]][field] = value
            }
            return true
        }

        func json() -> String {
            let groupNumbers = Set(matches.keys).union(rules.keys).sorted()
            let array: [[String: Any]] = groupNumbers.map { number in
                var object: [String: Any] = [:]
                if let match = matches[number] { object["match"] = match }
                if let groupRules = rules[number], !groupRules.isEmpty {
                    object["rules"] = groupRules.keys.sorted().compactMap { groupRules[$0].map(typedRule) }
                }
                return object
            }
            let data = (try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static let booleanFields: Set<String> = ["watched", "favorited", "in_watchlist", "in_progress", "hdr", "dolby_vision"]
    private static let numericFields: Set<String> = ["year", "rating_imdb", "bitrate"]

    /// The server compares some rule values as Booleans or numbers.
    private static func typedRule(_ rule: [String: Any]) -> [String: Any] {
        guard let field = rule["field"] as? String, let value = rule["value"] else { return rule }
        var typed = rule
        if let list = value as? [Any] {
            typed["value"] = list.map { element in (element as? String).map { typedValue($0, field: field) } ?? element }
        } else if let text = value as? String {
            typed["value"] = typedValue(text, field: field)
        }
        return typed
    }

    private static func typedValue(_ text: String, field: String) -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if booleanFields.contains(field) {
            switch trimmed.lowercased() {
            case "true": return true
            case "false": return false
            default: return text
            }
        }
        if numericFields.contains(field) {
            if let integer = Int(trimmed) { return integer }
            if let number = Double(trimmed), number.isFinite { return number }
        }
        return text
    }

    // MARK: - Request bodies

    private static let numericIDKeys: Set<String> = [
        "effective_media_file_id", "file_id", "impersonator_user_id", "last_file_id", "library_id",
        "media_file_id", "person_id", "requested_media_file_id", "switched_file_id",
    ]
    private static let opaqueKeys: Set<String> = ["value", "headers", "diagnostics", "platform_details"]
    private static let jsonOutput: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]

    private static func rewriteBody(_ json: Any, mappedPath: String, method: String) throws -> Any {
        var body = encodeIDs(json, key: nil)
        guard var object = body as? [String: Any] else { return body }
        if method == "POST", mappedPath == "/api/v2/downloads" {
            if let fileID = object.removeValue(forKey: "file_id") {
                object["media_file_id"] = fileID
            } else {
                object["media_file_id"] = nil
            }
            if object["season_number"] != nil { object["series"] = true }
        }
        if mappedPath == "/api/v2/sync/progress", let items = object["items"] as? [Any] {
            let entries = items.compactMap { $0 as? [String: Any] }
            if entries.count == items.count {
                object["items"] = try entries.map(progressItemInMilliseconds)
            }
        }
        body = object
        return body
    }

    /// Numbers and Booleans under ID keys become text, as v2 expects.
    private static func encodeIDs(_ value: Any, key: String?) -> Any {
        if let object = value as? [String: Any] {
            var encoded: [String: Any] = [:]
            for (childKey, child) in object {
                encoded[childKey] = opaqueKeys.contains(childKey) ? child : encodeIDs(child, key: childKey)
            }
            return encoded
        }
        if let array = value as? [Any] {
            let elementKey = key == "allowed_library_ids" ? "library_id" : key
            return array.map { encodeIDs($0, key: elementKey) }
        }
        if let key, numericIDKeys.contains(key), !(value is String), let number = value as? NSNumber {
            return number.stringValue
        }
        return value
    }

    private static func progressItemInMilliseconds(_ item: [String: Any]) throws -> [String: Any] {
        var item = item
        for (seconds, milliseconds) in [("position", "position_ms"), ("duration", "duration_ms")] {
            // Only a number that is exactly a double counts; Booleans read as 1 or 0.
            guard let value = item.removeValue(forKey: seconds), let number = value as? Double else { continue }
            let rounded = (number * 1_000).rounded(.toNearestOrAwayFromZero)
            guard rounded.isFinite, rounded >= 0, rounded < 9_223_372_036_854_775_808.0 else {
                throw Failure.invalidDiscovery
            }
            item[milliseconds] = Int(rounded)
        }
        return item
    }

    // MARK: - Responses

    static func response(_ data: Data, path: String, requestURL: URL? = nil) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return data }
        let topLevelHasObjectIDs = path == "/api/v1/auth/me" || path == "/api/v1/user/libraries"
            || path.hasPrefix("/api/v1/people/")
        var result = decodeIDs(json, key: nil, hasObjectIDs: topLevelHasObjectIDs)
        if let object = result as? [String: Any] {
            result = reshapeTopLevel(object, path: path)
        }
        if let requestURL {
            result = resolveArtwork(result, relativeTo: requestURL)
        }
        return try JSONSerialization.data(withJSONObject: result, options: jsonOutput)
    }

    /// Text IDs become integers again, and marker times gain their v1 names.
    private static func decodeIDs(_ value: Any, key: String?, hasObjectIDs: Bool) -> Any {
        if var object = value as? [String: Any] {
            if key == "intro" || key == "credits" {
                copyIfMissing(&object, from: "start_seconds", to: "start")
                copyIfMissing(&object, from: "end_seconds", to: "end")
            }
            if key == "versions" {
                copyIfMissing(&object, from: "duration_seconds", to: "duration")
            }
            let isCredit = key == "cast" || key == "crew"
            var decoded: [String: Any] = [:]
            for (childKey, child) in object {
                if opaqueKeys.contains(childKey) || (isCredit && childKey == "person_id") {
                    decoded[childKey] = child
                } else if hasObjectIDs, childKey == "id", let text = child as? String, let number = Int(text) {
                    decoded[childKey] = number
                } else {
                    let childHasObjectIDs: Bool
                    switch childKey {
                    case "user", "cast", "crew": childHasObjectIDs = true
                    case "items": childHasObjectIDs = hasObjectIDs
                    default: childHasObjectIDs = false
                    }
                    decoded[childKey] = decodeIDs(child, key: childKey, hasObjectIDs: childHasObjectIDs)
                }
            }
            return decoded
        }
        if let array = value as? [Any] {
            let elementKey = key == "allowed_library_ids" ? "library_id" : key
            return array.map { decodeIDs($0, key: elementKey, hasObjectIDs: hasObjectIDs) }
        }
        if let key, numericIDKeys.contains(key), let text = value as? String, let number = Int(text) {
            return number
        }
        return value
    }

    private static func copyIfMissing(_ object: inout [String: Any], from source: String, to target: String) {
        guard object[target] == nil, let value = object[source] else { return }
        object[target] = value
    }

    private static let itemAliases: [(matches: (String) -> Bool, key: String)] = [
        ({ $0 == "/api/v1/profiles" }, "profiles"),
        ({ $0.hasSuffix("/seasons") }, "seasons"),
        ({ $0.hasSuffix("/episodes") }, "episodes"),
        ({ $0 == "/api/v1/downloads" }, "downloads"),
        ({ $0 == "/api/v1/downloads/subscriptions" }, "subscriptions"),
        ({ $0.hasSuffix("/manifests") }, "manifests"),
        ({ $0 == "/api/v1/collections" }, "collections"),
        ({ $0 == "/api/v1/recommendations/discover" }, "rows"),
        ({ $0 == "/api/v1/settings/values/effective" }, "settings"),
        ({ $0 == "/api/v1/notifications/sync" }, "notifications"),
    ]

    private static func reshapeTopLevel(_ original: [String: Any], path: String) -> Any {
        if path == "/api/v1/user/libraries" {
            return original["items"] ?? original
        }
        var object = original
        if let items = object["items"], let alias = itemAliases.first(where: { $0.matches(path) }) {
            object[alias.key] = items
        }
        if let page = object["page"] as? [String: Any] {
            object["has_more"] = page["has_more"]
        }
        if let cursor = object["window_cursor"] {
            object["snapshot"] = cursor
        }
        if path == "/api/v1/images/capability" {
            object["schema_version"] = 1
        }
        if path == "/api/v1/sync/progress", let items = object["items"] as? [Any] {
            let entries = items.compactMap { $0 as? [String: Any] }
            if entries.count == items.count {
                object["results"] = entries.map { entry -> [String: Any] in
                    var result = entry
                    result["status"] = (entry["status"] as? String) == "success" ? "ok" : "error"
                    return result
                }
            }
        }
        if path == "/api/v1/settings/contract/capabilities" {
            object["revision"] = object["manifest_revision"]
        }
        if path == "/api/v1/notifications/sync" {
            if let cursor = (object["page"] as? [String: Any])?["next_cursor"] as? String {
                object["next_cursor"] = "v2:" + cursor
            } else if let cursor = object["sync_cursor"] as? String {
                object["next_cursor"] = "v2:" + cursor
            }
        }
        if path == "/api/v1/metadata/ai/status" {
            object["enabled"] = isAvailableAndAllowed(object)
        }
        if path.hasPrefix("/api/v1/playback/") {
            object["native_api_major"] = 2
            if var plan = object["playback_plan"] as? [String: Any] {
                plan["native_api_major"] = 2
                object["playback_plan"] = plan
            }
        }
        if path == "/api/v1/playback/capability" {
            object["enabled"] = isAvailableAndAllowed(object)
            if object["transformations"] == nil { object["transformations"] = [Any]() }
        }
        if path == "/api/v1/health" {
            object["status"] = "ok"
        }
        if path.hasPrefix("/api/v1/downloads/subscriptions"), object["id"] != nil {
            object = ["subscription": object, "registered": 0]
        }
        if path == "/api/v1/auth/device/poll", let tokens = object.removeValue(forKey: "tokens") {
            if let tokens = tokens as? [String: Any] {
                object.merge(tokens) { _, token in token }
            }
        }
        return object
    }

    private static func isAvailableAndAllowed(_ object: [String: Any]) -> Bool {
        (object["state"] as? String) == "available" && (object["allowed"] as? Bool) == true
    }

    private static let artworkKeys: Set<String> = [
        "avatar_url", "backdrop_url", "image_url", "logo_url", "photo_url", "poster_url",
        "series_backdrop_url", "still_url", "thumbnail_url",
    ]

    /// Root-relative artwork paths become absolute URLs on the server that
    /// answered.
    private static func resolveArtwork(_ value: Any, relativeTo requestURL: URL) -> Any {
        if let object = value as? [String: Any] {
            var resolved: [String: Any] = [:]
            for (key, child) in object {
                if artworkKeys.contains(key), let text = child as? String, text.hasPrefix("/"), !text.hasPrefix("//") {
                    resolved[key] = artworkURL(text, relativeTo: requestURL)?.absoluteString ?? text
                } else {
                    resolved[key] = resolveArtwork(child, relativeTo: requestURL)
                }
            }
            return resolved
        }
        if let array = value as? [Any] {
            return array.map { element -> Any in
                element is String ? element : resolveArtwork(element, relativeTo: requestURL)
            }
        }
        return value
    }

    // MARK: - Artwork

    static func artworkURL(_ raw: String, relativeTo serverURL: URL?) -> URL? {
        guard let parsed = URL(string: raw) else { return nil }
        guard raw.hasPrefix("/"), !raw.hasPrefix("//") else { return parsed }
        guard let serverURL,
              let scheme = serverURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = serverURL.host,
              let resolved = URL(string: raw, relativeTo: serverURL)?.absoluteURL,
              resolved.scheme?.lowercased() == scheme,
              resolved.host?.lowercased() == host.lowercased(),
              resolved.port == serverURL.port
        else { return nil }
        return resolved
    }

    /// When a signed artwork URL stops working, from its signature parameters.
    static func artworkExpiry(_ raw: String) -> Date? {
        guard raw.contains("exp=") || raw.contains("X-Amz-Expires=") || raw.contains("verify="),
              let items = URLComponents(string: raw)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if value("sig") != nil, let expiry = value("exp").flatMap({ Int($0) }) {
            return Date(timeIntervalSince1970: TimeInterval(expiry))
        }
        if value("X-Amz-Signature") != nil,
           let signedAt = value("X-Amz-Date").flatMap({ amazonDateFormatter.date(from: $0) }),
           let lifetime = value("X-Amz-Expires").flatMap({ Int($0) }) {
            return signedAt.addingTimeInterval(TimeInterval(lifetime))
        }
        if let verify = value("verify"), let dash = verify.firstIndex(of: "-"),
           verify.index(after: dash) < verify.endIndex,
           let issued = Int(verify[..<dash]) {
            return Date(timeIntervalSince1970: TimeInterval(issued) + 10_800)
        }
        return nil
    }

    private static let amazonDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}

/// Finds out whether a Silo server speaks v2, by asking its system info.
/// Answers are cached per server for a while and refreshed in the background.
actor SiloAPIDiscovery {
    static let shared = SiloAPIDiscovery()

    private static let freshAge: TimeInterval = 60
    private static let usableAge: TimeInterval = 600
    private static let cacheLimit = 32

    private struct Answer {
        let usesV2: Bool
        let storedAt: Date
    }

    private struct Check {
        let id: UUID
        let task: Task<Bool, Error>
    }

    private let legacyOnly: Bool
    private let now: @Sendable () -> Date
    private var answers: [URL: Answer] = [:]
    private var checks: [URL: Check] = [:]

    init(legacyOnly: Bool = false, now: @escaping @Sendable () -> Date = Date.init) {
        self.legacyOnly = legacyOnly
        self.now = now
    }

    func usesV2(for url: URL, session: URLSession) async throws -> Bool {
        guard !legacyOnly, let discovery = SiloAPICompatibility.discoveryURL(for: url) else { return false }
        if let answer = answers[discovery] {
            let age = now().timeIntervalSince(answer.storedAt)
            if age < Self.freshAge { return answer.usesV2 }
            if age < Self.usableAge {
                if checks[discovery] == nil { _ = startCheck(discovery, session: session) }
                return answer.usesV2
            }
        }
        let task = checks[discovery]?.task ?? startCheck(discovery, session: session)
        let usesV2 = try await task.value
        try Task.checkCancellation()
        return usesV2
    }

    private func startCheck(_ discovery: URL, session: URLSession) -> Task<Bool, Error> {
        let id = UUID()
        let task = Task {
            do {
                let usesV2 = try await Self.probe(discovery, session: session)
                finishCheck(id, discovery: discovery, usesV2: usesV2)
                return usesV2
            } catch {
                finishCheck(id, discovery: discovery, usesV2: nil)
                throw error
            }
        }
        checks[discovery] = Check(id: id, task: task)
        return task
    }

    private func finishCheck(_ id: UUID, discovery: URL, usesV2: Bool?) {
        if checks[discovery]?.id == id { checks[discovery] = nil }
        guard let usesV2 else { return }
        if answers[discovery] == nil, answers.count >= Self.cacheLimit { answers.removeAll() }
        answers[discovery] = Answer(usesV2: usesV2, storedAt: now())
    }

    private static func probe(_ url: URL, session: URLSession) async throws -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SiloAPICompatibility.Failure.invalidDiscovery }
        switch http.statusCode {
        case 404, 405:
            return false
        case 200:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let major = object?["api_major"] as? Int {
                guard major == 2 else { throw SiloAPICompatibility.Failure.invalidDiscovery }
                return true
            }
            if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true { return false }
            throw SiloAPICompatibility.Failure.invalidDiscovery
        default:
            throw SiloAPICompatibility.Failure.unsupportedStatus(http.statusCode)
        }
    }
}
