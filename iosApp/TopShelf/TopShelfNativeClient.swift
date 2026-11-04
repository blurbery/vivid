import Foundation

/// Reads the Top Shelf rows (Continue Watching and Next Up) straight from an
/// Emby or Jellyfin server. Foundation only, so the extension builds it
/// without any app code.
struct TopShelfNativeClient {
    enum Provider { case emby, jellyfin }
    enum Failure: Error { case invalidURL, invalidItem, status(Int) }

    let provider: Provider
    let serverURL: String
    let userID: String
    let token: String
    var session: URLSession = Self.session

    /// Short-lived and stateless: no cookies, no cache, and redirects are
    /// refused so the token never follows one to another host.
    static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: TopShelfNativeRedirectPolicy(), delegateQueue: nil)

    private static let clientFields =
        "Client=\"Vivid\", Device=\"Apple TV Top Shelf\", DeviceId=\"vivid-topshelf\", Version=\"0.14.3\""

    func fetchHomeSections() async throws -> TopShelfSectionsResponse {
        let user = try safeID(userID)
        let userResumePath = "/Users/\(user)/Items/Resume"
        let resumeRoute: (path: String, query: [String: String], fallback: String?)
        let nextUpQuery: [String: String]
        switch provider {
        case .emby:
            resumeRoute = (userResumePath, ["IncludeNextUp": "false"], nil)
            nextUpQuery = ["LegacyNextUp": "true"]
        case .jellyfin:
            // Older Jellyfin servers only have the per-user route.
            resumeRoute = ("/UserItems/Resume", [:], userResumePath)
            nextUpQuery = ["EnableResumable": "false"]
        }
        async let resume = items(resumeRoute.path, query: resumeRoute.query, fallback: resumeRoute.fallback)
        async let next = items("/Shows/NextUp", query: nextUpQuery)
        return try await TopShelfSectionsResponse(sections: [
            TopShelfSection(id: "continue_watching", sectionType: "continue_watching", title: "Continue Watching", items: resume),
            TopShelfSection(id: "next_up", sectionType: "next_up", title: "Next Up", items: next),
        ])
    }

    /// Fetches one row. A 404 retries once at `fallback` with the same query.
    private func items(_ path: String, query: [String: String], fallback: String? = nil) async throws -> [TopShelfItem] {
        let base = [
            "UserId": userID,
            "Limit": "12",
            "MediaTypes": "Video",
            "EnableUserData": "true",
            "EnableImages": "true",
            "ImageTypeLimit": "1",
        ]
        let query = base.merging(query) { _, new in new }
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch provider {
        case .emby:
            request.setValue("Emby " + Self.clientFields, forHTTPHeaderField: "X-Emby-Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        case .jellyfin:
            request.setValue("MediaBrowser " + Self.clientFields + ", Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        if http.statusCode == 404, let fallback {
            return try await items(fallback, query: query)
        }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidItem
        }
        return try (object["Items"] as? [[String: Any]] ?? []).map(item)
    }

    /// One server item as a Top Shelf item. An episode uses its series' poster.
    func item(_ raw: [String: Any]) throws -> TopShelfItem {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { throw Failure.invalidItem }
        _ = try safeID(id)
        let type = (raw["Type"] as? String ?? "Movie").lowercased()
        let seriesID = raw["SeriesId"] as? String
        let imageTags = raw["ImageTags"] as? [String: String] ?? [:]
        let userData = raw["UserData"] as? [String: Any] ?? [:]

        let poster: String
        if type == "episode", let seriesID {
            poster = try imageURL(seriesID, kind: "Primary", tag: raw["SeriesPrimaryImageTag"] as? String)
        } else {
            poster = try imageURL(id, kind: "Primary", tag: imageTags["Primary"])
        }

        return TopShelfItem(
            contentId: id,
            type: type,
            title: name,
            seriesId: seriesID,
            seriesTitle: raw["SeriesName"] as? String,
            seasonNumber: raw["ParentIndexNumber"] as? Int,
            episodeNumber: raw["IndexNumber"] as? Int,
            positionSeconds: seconds(fromTicks: userData["PlaybackPositionTicks"]),
            durationSeconds: seconds(fromTicks: raw["RunTimeTicks"]),
            progressUpdatedAt: userData["LastPlayedDate"] as? String,
            posterUrl: poster,
            backdropUrl: nil
        )
    }

    /// Server ticks (100 ns) as seconds, never negative.
    private func seconds(fromTicks value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return max(0, number.doubleValue / 10_000_000)
    }

    private func imageURL(_ id: String, kind: String, tag: String?) throws -> String {
        var query = ["maxWidth": "780", "quality": "90"]
        if let tag, !tag.isEmpty { query["tag"] = tag }
        return try url("/Items/\(safeID(id))/Images/\(kind)", query: query).absoluteString
    }

    /// The ID itself when it's only ASCII letters, digits, `-` and `_`, so it
    /// can go into a path as is.
    private func safeID(_ value: String) throws -> String {
        let isSafe = !value.isEmpty && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
        guard isSafe else { throw Failure.invalidItem }
        return value
    }

    /// `path` under the server address, with the query sorted by name. The
    /// address must be plain http or https with a host and nothing else
    /// (no credentials, query or fragment). Emby routes sit under `/emby`,
    /// which is added unless the address already ends in it.
    func url(_ path: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: serverURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw Failure.invalidURL
        }
        var prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider == .emby, prefix.split(separator: "/").last?.lowercased() != "emby" {
            prefix += prefix.isEmpty ? "emby" : "/emby"
        }
        components.path = (prefix.isEmpty ? "" : "/" + prefix) + path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Failure.invalidURL }
        return url
    }
}

/// Refuses every redirect.
private final class TopShelfNativeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
