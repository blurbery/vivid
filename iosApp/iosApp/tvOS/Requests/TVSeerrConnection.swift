#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit

struct TVSeerrConfiguration: Codable {
    var id = UUID()
    let url: String
    let username: String
    let password: String
}

struct TVSeerrError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A private cookie jar per configured account; never shares Silo's session or headers.
private final class TVSeerrRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor TVSeerrClient {
    private let configuration: TVSeerrConfiguration
    private let baseURL: URL
    private let session: URLSession
    private var permissions = 0
    private var signedIn = false

    static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TVSeerrError(message: "Enter a complete Seerr URL, including https:// or http://.")
        }
        return url
    }

    init(configuration: TVSeerrConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) throws {
        self.configuration = configuration
        baseURL = try Self.validatedURL(configuration.url)
        let options = sessionConfiguration
        options.timeoutIntervalForRequest = 20
        options.timeoutIntervalForResource = 30
        options.urlCache = nil
        session = URLSession(configuration: options, delegate: TVSeerrRedirectPolicy(), delegateQueue: nil)
    }

    private func send(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw TVSeerrError(message: "Seerr returned an invalid response.")
        }
        return (data, response.statusCode)
    }

    private func checked(_ data: Data, _ status: Int) throws -> Data {
        guard (200..<300).contains(status) else {
            // Never render raw server bodies, which may echo submitted credentials.
            let message: String
            switch status {
            case 301...399: message = "Use the final Seerr URL; this address redirects elsewhere."
            case 401: message = "Seerr could not sign in. Check your username and password."
            case 403: message = "Seerr rejected the login or this account does not have permission."
            case 409: message = "This title has already been requested."
            case 429: message = "Seerr's request limit was reached. Try again later."
            default: message = "Seerr could not complete this request (\(status)). Check its connection and request settings."
            }
            throw TVSeerrError(message: message)
        }
        return data
    }

    func authenticate() async throws {
        let local = configuration.username.contains("@")
        let body = [local ? "email" : "username": configuration.username, "password": configuration.password]
        let (data, code) = try await send(local ? "auth/local" : "auth/jellyfin", body: body)
        let user = try JSONDecoder().decode(SeerrUser.self, from: checked(data, code))
        permissions = user.permissions
        signedIn = true
    }

    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        if !signedIn { try await authenticate() }
        var (data, status) = try await send(path, query: query, body: body)
        if status == 401 {
            signedIn = false
            try await authenticate()
            (data, status) = try await send(path, query: query, body: body)
        }
        return try JSONDecoder().decode(T.self, from: checked(data, status))
    }

    private func state(_ info: SeerrMediaInfo?, type: RequestMediaType) -> RequestState {
        let active = info?.requests?.first { [1, 2].contains($0.status) && $0.is4k != true }
        let status: RequestStatus? = active.map { $0.status == 1 ? .pending : .approved }
            ?? (info?.status == 2 ? .pending : info?.status == 3 ? .approved : nil)
        let allowed = permissions & (2 | 32 | (type == .movie ? 262144 : 524288)) != 0
        let blocked = info?.status == 6
        return RequestState(status: status, requestable: allowed && !blocked && status == nil && info?.status != 5,
                            reason: blocked ? "blocked" : !allowed ? "permission_denied" : nil,
                            requestId: active.map { String($0.id) })
    }

    func search(_ query: String) async throws -> RequestMediaPage {
        let page: SeerrPage = try await request("search", query: [.init(name: "query", value: query), .init(name: "page", value: "1")])
        return RequestMediaPage(page: page.page, totalPages: page.totalPages, totalResults: page.totalResults,
            results: page.results.compactMap { item in
                guard let type = item.type else { return nil }
                return RequestMediaResult(mediaType: type, tmdbId: item.id, title: item.displayTitle,
                    year: item.year, overview: item.overview, posterPath: item.posterPath, backdropPath: item.backdropPath,
                    releaseDate: item.date, voteAverage: item.voteAverage,
                    availability: item.mediaInfo?.status == 5 ? .available : .missing, libraryContentId: nil,
                    request: state(item.mediaInfo, type: type))
            })
    }

    func detail(type: RequestMediaType, id: Int) async throws -> RequestMediaDetail {
        let item: SeerrItem = try await request("\(type == .movie ? "movie" : "tv")/\(id)")
        return RequestMediaDetail(mediaType: type, tmdbId: id, imdbId: item.externalIds?.imdbId,
            tvdbId: item.externalIds?.tvdbId, title: item.displayTitle, tagline: item.tagline, overview: item.overview,
            posterPath: item.posterPath, backdropPath: item.backdropPath, releaseDate: item.date, year: item.year,
            runtime: item.runtime ?? item.episodeRunTime?.first, genres: item.genres?.map(\.name),
            voteAverage: item.voteAverage, voteCount: item.voteCount, contentRating: nil,
            numberOfSeasons: item.seasons?.filter { $0.seasonNumber != 0 }.count,
            numberOfEpisodes: item.numberOfEpisodes, networks: item.networks?.map(\.name), director: nil,
            creators: item.createdBy?.map(\.name), recommendations: nil,
            availability: item.mediaInfo?.status == 5 ? .available : .missing, libraryContentId: nil,
            request: state(item.mediaInfo, type: type))
    }

    func create(_ input: CreateRequestInput) async throws -> MediaRequest {
        var body: [String: Any] = ["mediaType": input.mediaType == .movie ? "movie" : "tv", "mediaId": input.tmdbId, "is4k": false]
        if input.mediaType == .series { body["seasons"] = "all" }
        let result: SeerrRequest = try await request("request", body: body)
        return MediaRequest(id: String(result.id), mediaType: input.mediaType, tmdbId: input.tmdbId,
            title: input.title, year: input.year, overview: input.overview, posterPath: input.posterPath,
            backdropPath: input.backdropPath, status: result.status == 1 ? .pending : .approved,
            outcome: .active, targets: nil, libraryContentId: nil, lastError: nil,
            createdAt: Date(), updatedAt: Date(), completedAt: nil)
    }
}

private struct SeerrUser: Decodable { let permissions: Int }
private struct SeerrPage: Decodable { let page: Int; let totalPages: Int; let totalResults: Int; let results: [SeerrItem] }
private struct SeerrRequest: Decodable { let id: Int; let status: Int; let is4k: Bool? }
private struct SeerrMediaInfo: Decodable { let status: Int; let requests: [SeerrRequest]? }
private struct SeerrName: Decodable { let name: String }
private struct SeerrSeason: Decodable { let seasonNumber: Int }
private struct SeerrExternalIDs: Decodable { let imdbId: String?; let tvdbId: Int? }
private struct SeerrItem: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?; let name: String?; let tagline: String?; let overview: String?
    let posterPath: String?; let backdropPath: String?; let releaseDate: String?; let firstAirDate: String?
    let voteAverage: Double?; let voteCount: Int?; let runtime: Int?; let episodeRunTime: [Int]?
    let numberOfEpisodes: Int?; let seasons: [SeerrSeason]?
    let genres: [SeerrName]?; let networks: [SeerrName]?; let createdBy: [SeerrName]?
    let externalIds: SeerrExternalIDs?; let mediaInfo: SeerrMediaInfo?
    var type: RequestMediaType? { mediaType == "movie" ? .movie : mediaType == "tv" ? .series : nil }
    var displayTitle: String { title ?? name ?? "Untitled" }
    var date: String? { releaseDate ?? firstAirDate }
    var year: Int? { date.flatMap { Int($0.prefix(4)) } }
}

@Observable @MainActor
final class TVSeerrConnectionStore {
    static let shared = TVSeerrConnectionStore()
    private var revision = 0
    private let keychain = SharedKeychain(audience: .currentUser)
    private var clients: [UUID: TVSeerrClient] = [:]
    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }
    private var scope: String {
        let parts = [ServerRegistry.shared.activeServerId ?? "", accountContext, AuthService.shared.profileId ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var key: String {
        let legacy = "vivid.seerr.\(scope)"
        guard let canonical = VividCloudPreferences.activeCredentialKey("seerr") else { return legacy }
        if keychain.get(canonical) == nil, let value = keychain.get(legacy), keychain.set(value, for: canonical) {
            _ = keychain.delete(legacy)
        }
        return canonical
    }
    func cloudPreferencesChanged() { clients.removeAll(); revision += 1 }
    var configuration: TVSeerrConfiguration? {
        _ = revision
        guard let string = keychain.get(key), let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TVSeerrConfiguration.self, from: data)
    }
    var identity: String { "\(scope):\(configuration?.id.uuidString ?? "none")" }
    var isConfigured: Bool { configuration != nil }

    func connect(url: String, username: String, password: String) async throws {
        let start = identity
        let cleanedURL = try TVSeerrClient.validatedURL(url).absoluteString
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = configuration
        let sameLogin = existing?.url == cleanedURL && existing?.username == username
        let password = password.isEmpty && sameLogin ? existing?.password ?? "" : password
        guard !username.isEmpty, !password.isEmpty else { throw TVSeerrError(message: "Enter your Seerr username and password.") }
        let config = TVSeerrConfiguration(url: cleanedURL, username: username, password: password)
        let client = try TVSeerrClient(configuration: config)
        try await client.authenticate()
        guard start == identity else { throw CancellationError() }
        let encoded = try JSONEncoder().encode(config)
        guard let value = String(data: encoded, encoding: .utf8), keychain.set(value, for: key) else {
            throw TVSeerrError(message: "Couldn't securely save this connection.")
        }
        clients = [config.id: client]
        revision += 1
        VividCloudPreferences.shared.schedule()
    }
    func disconnect() throws {
        guard keychain.delete(key) else { throw TVSeerrError(message: "Couldn't remove the saved connection.") }
        clients.removeAll()
        revision += 1
        VividCloudPreferences.shared.schedule()
    }
    private func client() throws -> TVSeerrClient {
        guard let config = configuration else { throw TVSeerrError(message: "Configure Seerr in Settings to request titles.") }
        if let cached = clients[config.id] { return cached }
        let client = try TVSeerrClient(configuration: config)
        clients = [config.id: client]
        return client
    }
    func search(_ query: String) async throws -> RequestMediaPage {
        let start = identity
        let result = try await client().search(query)
        guard start == identity else { throw CancellationError() }
        return result
    }
    func detail(type: RequestMediaType, id: Int) async throws -> RequestMediaDetail {
        let start = identity
        let result = try await client().detail(type: type, id: id)
        guard start == identity else { throw CancellationError() }
        return result
    }
    func create(_ input: CreateRequestInput) async throws -> MediaRequest {
        let start = identity
        let result = try await client().create(input)
        guard start == identity else { throw CancellationError() }
        return result
    }
}
#endif
