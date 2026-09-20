import Foundation

struct TopShelfNativeClient {
    enum Provider { case emby, jellyfin }
    enum Failure: Error { case invalidURL, invalidItem, status(Int) }

    let provider: Provider
    let serverURL: String
    let userID: String
    let token: String
    var session: URLSession = Self.session

    static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: TopShelfNativeRedirectPolicy(), delegateQueue: nil)

    func fetchHomeSections() async throws -> TopShelfSectionsResponse {
        let user = try safeID(userID)
        let resumePath = provider == .emby ? "/Users/\(user)/Items/Resume" : "/UserItems/Resume"
        async let resume = items(resumePath,
            query: provider == .emby ? ["IncludeNextUp": "false"] : [:],
            fallback: provider == .jellyfin ? "/Users/\(user)/Items/Resume" : nil)
        async let next = items("/Shows/NextUp", query: provider == .emby
            ? ["LegacyNextUp": "true"] : ["EnableResumable": "false"])
        return try await TopShelfSectionsResponse(sections: [
            TopShelfSection(id: "continue_watching", sectionType: "continue_watching", title: "Continue Watching", items: resume),
            TopShelfSection(id: "next_up", sectionType: "next_up", title: "Next Up", items: next)
        ])
    }

    private func items(_ path: String, query: [String: String], fallback: String? = nil) async throws -> [TopShelfItem] {
        let query = ["UserId": userID, "Limit": "12", "MediaTypes": "Video", "EnableUserData": "true",
                     "EnableImages": "true", "ImageTypeLimit": "1"].merging(query) { _, new in new }
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let client = "Client=\"Vivid\", Device=\"Apple TV Top Shelf\", DeviceId=\"vivid-topshelf\", Version=\"0.14.3\""
        switch provider {
        case .emby:
            request.setValue("Emby " + client, forHTTPHeaderField: "X-Emby-Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        case .jellyfin:
            request.setValue("MediaBrowser " + client + ", Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        if http.statusCode == 404, let fallback { return try await items(fallback, query: query) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidItem }
        return try (object["Items"] as? [[String: Any]] ?? []).map(item)
    }

    func item(_ raw: [String: Any]) throws -> TopShelfItem {
        guard let id = raw["Id"] as? String, let name = raw["Name"] as? String else { throw Failure.invalidItem }
        _ = try safeID(id)
        let type = (raw["Type"] as? String ?? "Movie").lowercased()
        let seriesID = raw["SeriesId"] as? String
        let tags = raw["ImageTags"] as? [String: String] ?? [:]
        let user = raw["UserData"] as? [String: Any] ?? [:]
        let poster: String?
        if type == "episode", let seriesID {
            poster = try image(seriesID, kind: "Primary", tag: raw["SeriesPrimaryImageTag"] as? String)
        } else {
            poster = try image(id, kind: "Primary", tag: tags["Primary"])
        }
        return TopShelfItem(contentId: id, type: type, title: name, seriesId: seriesID,
            seriesTitle: raw["SeriesName"] as? String, seasonNumber: raw["ParentIndexNumber"] as? Int,
            episodeNumber: raw["IndexNumber"] as? Int,
            positionSeconds: seconds(user["PlaybackPositionTicks"]), durationSeconds: seconds(raw["RunTimeTicks"]),
            progressUpdatedAt: user["LastPlayedDate"] as? String,
            posterUrl: poster, backdropUrl: nil)
    }

    private func seconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return max(0, number.doubleValue / 10_000_000)
    }

    private func image(_ id: String, kind: String, tag: String?) throws -> String {
        var query = ["maxWidth": "780", "quality": "90"]
        if let tag, !tag.isEmpty { query["tag"] = tag }
        return try url("/Items/\(safeID(id))/Images/\(kind)", query: query).absoluteString
    }

    private func safeID(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw Failure.invalidItem }
        return value
    }

    func url(_ path: String, query: [String: String]) throws -> URL {
        guard var base = URLComponents(string: serverURL), ["https", "http"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw Failure.invalidURL
        }
        var prefix = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider == .emby, prefix.split(separator: "/").last?.lowercased() != "emby" {
            prefix += prefix.isEmpty ? "emby" : "/emby"
        }
        base.path = (prefix.isEmpty ? "" : "/" + prefix) + path
        base.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = base.url else { throw Failure.invalidURL }
        return url
    }
}

private final class TopShelfNativeRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
