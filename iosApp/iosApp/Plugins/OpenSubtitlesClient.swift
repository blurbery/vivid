import Foundation

struct OpenSubtitleResult: Identifiable, Sendable {
    let id: Int
    let name: String
    let language: String
    let hearingImpaired: Bool
}

struct OpenSubtitleQuery: Equatable, Sendable {
    let title: String
    let type: String
    let season: Int?
    let episode: Int?

    func parameters(language: String) -> [String: String] {
        var query = ["query": title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), "languages": language, "type": type == "episode" ? "episode" : "movie"]
        if type == "episode" {
            if let season { query["season_number"] = String(season) }
            if let episode { query["episode_number"] = String(episode) }
        }
        return query
    }
}

enum OpenSubtitlesError: LocalizedError {
    case credentials, quota, response, unavailable, file, context, notConfigured
    case httpStatus(Int)
    case network(URLError.Code)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Connect OpenSubtitles in Settings → Plugins before searching for subtitles."
        case .httpStatus(let status): return "OpenSubtitles rejected the request (HTTP \(status)). Please try again."
        case .network(let code):
            if code == .notConnectedToInternet { return "No internet connection. Reconnect and try searching again." }
            if code == .timedOut { return "OpenSubtitles took too long to respond. Please try again." }
            return "Could not connect to OpenSubtitles. Please try again."
        case .credentials: return "Check your OpenSubtitles API key. An account may be required by OpenSubtitles for this download."
        case .quota: return "OpenSubtitles’ download or request limit has been reached. Try again after your quota resets."
        case .response: return "OpenSubtitles returned an unreadable response."
        case .unavailable: return "OpenSubtitles is unavailable. Please try again later."
        case .file: return "This subtitle file could not be loaded. Choose another result."
        case .context: return "The connection or playing item changed. Please search again."
        }
    }
}

private final class OpenSubtitlesRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let original = task.originalRequest, original.value(forHTTPHeaderField: "Api-Key") != nil {
            completionHandler(OpenSubtitlesClient.canonicalSearchRedirect(original: original, proposed: request))
            return
        }
        guard let url = request.url, OpenSubtitlesClient.isDownloadURL(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

final class OpenSubtitlesClient: @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: OpenSubtitlesRedirectPolicy(), delegateQueue: nil)
    }

    func validate(key: String) async throws {
        let response = try await request("/infos/languages", key: key)
        guard let languages = response["data"] as? [[String: Any]], !languages.isEmpty,
              languages.allSatisfy({ row in
                  guard let code = row["language_code"] as? String,
                        let name = row["language_name"] as? String else { return false }
                  return !code.isEmpty && !name.isEmpty
              }) else { throw OpenSubtitlesError.response }
    }

    func search(_ query: OpenSubtitleQuery, language: String, key: String) async throws -> [OpenSubtitleResult] {
        let value = try await request("/subtitles", key: key, query: query.parameters(language: language))
        return try Self.parseResults(value)
    }

    static func parseResults(_ value: [String: Any]) throws -> [OpenSubtitleResult] {
        guard let rows = value["data"] as? [[String: Any]] else { throw OpenSubtitlesError.response }
        var seen = Set<Int>()
        return rows.flatMap { row -> [OpenSubtitleResult] in
            guard let attributes = row["attributes"] as? [String: Any],
                  let language = attributes["language"] as? String,
                  let files = attributes["files"] as? [[String: Any]] else { return [] }
            return files.compactMap { file in
                guard let id = file["file_id"] as? Int, id > 0, seen.insert(id).inserted else { return nil }
                return OpenSubtitleResult(id: id,
                    name: (file["file_name"] as? String) ?? (attributes["release"] as? String) ?? "Subtitle",
                    language: language, hearingImpaired: attributes["hearing_impaired"] as? Bool ?? false)
            }
        }
    }

    func download(_ result: OpenSubtitleResult, key: String) async throws -> Data {
        let value = try await request("/download", key: key, body: ["file_id": result.id, "sub_format": "srt"])
        guard let link = value["link"] as? String, let url = URL(string: link), Self.isDownloadURL(url) else {
            throw OpenSubtitlesError.file
        }
        // Deliberately separate from API requests: no API key or server credentials.
        let data = try await fetch(URLRequest(url: url), limit: 5 * 1024 * 1024)
        guard Self.isSubtitle(data) else { throw OpenSubtitlesError.file }
        return data
    }

    /// Search canonicalisation can redirect on the same endpoint. No credential may leave it.
    static func canonicalSearchRedirect(original: URLRequest, proposed: URLRequest) -> URLRequest? {
        guard let source = original.url, let target = proposed.url,
              original.httpMethod == "GET", proposed.httpMethod == "GET" else { return nil }
        for url in [source, target] {
            guard url.scheme == "https", url.host?.lowercased() == "api.opensubtitles.com" else { return nil }
            guard url.port == nil || url.port == 443 else { return nil }
            guard url.user == nil, url.password == nil, url.path == "/api/v1/subtitles" else { return nil }
        }
        var request = proposed
        request.setValue(original.value(forHTTPHeaderField: "Api-Key"), forHTTPHeaderField: "Api-Key")
        return request
    }

    static func isDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["opensubtitles.com", "opensubtitles.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func isSubtitle(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 5 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return false }
        return text.contains("-->") && !text.lowercased().contains("<html")
    }

    private func request(_ path: String, key: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenSubtitlesError.notConfigured }
        var url = URLComponents(string: "https://api.opensubtitles.com/api/v1" + path)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.setValue(key, forHTTPHeaderField: "Api-Key")
        request.setValue("Vivid v0.14.3", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data = try await fetch(request, limit: 2 * 1024 * 1024)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenSubtitlesError.response }
        return value
    }

    private func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw OpenSubtitlesError.response }
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw OpenSubtitlesError.credentials
            case 406, 429: throw OpenSubtitlesError.quota
            default: throw OpenSubtitlesError.httpStatus(http.statusCode)
            }
            guard response.expectedContentLength <= limit else { throw OpenSubtitlesError.file }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw OpenSubtitlesError.file }
                data.append(byte)
            }
            return data
        } catch let error as OpenSubtitlesError { throw error }
        catch let error as URLError { try Task.checkCancellation(); throw OpenSubtitlesError.network(error.code) }
        catch { try Task.checkCancellation(); throw OpenSubtitlesError.unavailable }
    }
}

struct OpenSubtitlePlaybackContext: Equatable, Sendable {
    let contentID: String
    let generation: UInt64
    let query: OpenSubtitleQuery
}

/// Owns downloaded subtitles for one playing item across replacement loads.
struct OpenSubtitleSessionFiles {
    struct Entry {
        let id: Int64
        let url: URL
        let name: String
        let language: String
        let hearingImpaired: Bool
    }
    private(set) var contentID: String?
    private(set) var entries: [Int64: Entry] = [:]
    var selectedID: Int64?

    mutating func prepare(contentID: String) -> [URL] {
        guard self.contentID != contentID else { return [] }
        let removed = clear()
        self.contentID = contentID
        return removed
    }
    mutating func register(_ entry: Entry) -> URL? {
        entries.updateValue(entry, forKey: entry.id)?.url
    }
    mutating func clear() -> [URL] {
        let urls = entries.values.map(\.url)
        entries = [:]
        selectedID = nil
        contentID = nil
        return urls
    }
}

/// Session-only, bounded reuse. The owning store clears this on account/key changes.
struct OpenSubtitleDownloadCache {
    private(set) var entries: [Int: Data] = [:]
    private var order: [Int] = []
    let byteLimit: Int
    let countLimit: Int
    init(byteLimit: Int = 10 * 1024 * 1024, countLimit: Int = 8) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
    }
    mutating func value(for id: Int) -> Data? {
        guard let value = entries[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return value
    }
    mutating func insert(_ value: Data, for id: Int) {
        guard !value.isEmpty, value.count <= byteLimit, countLimit > 0 else { return }
        entries[id] = value
        order.removeAll { $0 == id }; order.append(id)
        while entries.count > countLimit || entries.values.reduce(0, { $0 + $1.count }) > byteLimit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }
}
