#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit

/// A saved Seerr login. Kept in Keychain as JSON, so the property names
/// are the stored keys.
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

/// Seerr gets its own session and cookie jar per account, never the media
/// server's session or headers, and redirects are never followed.
private final class TVSeerrRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Talks to one Seerr instance with one login. It signs in on first use
/// and once more when the session has expired.
actor TVSeerrClient {
    private let configuration: TVSeerrConfiguration
    private let baseURL: URL
    private let session: URLSession
    private var permissions = 0
    private var signedIn = false

    /// The address as typed, trimmed: http or https with a host, and no
    /// login, query or fragment.
    static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw TVSeerrError(message: String(localized: "Enter a complete Seerr URL, including https:// or http://."))
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

    // MARK: Signing in

    /// An address with an @ is a local Seerr account; anything else is a
    /// user Seerr imported from Jellyfin or Emby.
    func authenticate() async throws {
        let isLocal = configuration.username.contains("@")
        let body = [isLocal ? "email" : "username": configuration.username, "password": configuration.password]
        let (data, status) = try await send(isLocal ? "auth/local" : "auth/jellyfin", body: body)
        let user = try JSONDecoder().decode(SeerrUser.self, from: checked(data, status: status))
        permissions = user.permissions
        signedIn = true
    }

    // MARK: Requests

    func search(_ query: String) async throws -> RequestMediaPage {
        let page: SeerrPage = try await request("search", query: [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "page", value: "1"),
        ])
        return RequestMediaPage(
            page: page.page, totalPages: page.totalPages, totalResults: page.totalResults,
            results: page.results.compactMap { item in
                guard let type = item.type else { return nil }
                return RequestMediaResult(
                    mediaType: type, tmdbId: item.id, title: item.displayTitle,
                    year: item.year, overview: item.overview,
                    posterPath: item.posterPath, backdropPath: item.backdropPath,
                    releaseDate: item.date, voteAverage: item.voteAverage,
                    availability: Self.availability(item.mediaInfo), libraryContentId: nil,
                    request: state(item.mediaInfo, type: type))
            })
    }

    func detail(type: RequestMediaType, id: Int) async throws -> RequestMediaDetail {
        let item: SeerrItem = try await request("\(Self.path(type))/\(id)")
        return RequestMediaDetail(
            mediaType: type, tmdbId: id,
            imdbId: item.externalIds?.imdbId, tvdbId: item.externalIds?.tvdbId,
            title: item.displayTitle, tagline: item.tagline, overview: item.overview,
            posterPath: item.posterPath, backdropPath: item.backdropPath,
            releaseDate: item.date, year: item.year,
            runtime: item.runtime ?? item.episodeRunTime?.first,
            genres: item.genres?.map(\.name),
            voteAverage: item.voteAverage, voteCount: item.voteCount, contentRating: nil,
            // Specials (season 0) aren't counted.
            numberOfSeasons: item.seasons?.filter { $0.seasonNumber != 0 }.count,
            numberOfEpisodes: item.numberOfEpisodes,
            networks: item.networks?.map(\.name), director: nil,
            creators: item.createdBy?.map(\.name), recommendations: nil,
            availability: Self.availability(item.mediaInfo), libraryContentId: nil,
            request: state(item.mediaInfo, type: type))
    }

    /// Always a standard (not 4K) request, and every season of a series.
    func create(_ input: CreateRequestInput) async throws -> MediaRequest {
        var body: [String: Any] = ["mediaType": Self.path(input.mediaType), "mediaId": input.tmdbId, "is4k": false]
        if input.mediaType == .series { body["seasons"] = "all" }
        let result: SeerrRequest = try await request("request", body: body)
        return MediaRequest(
            id: String(result.id), mediaType: input.mediaType, tmdbId: input.tmdbId,
            title: input.title, year: input.year, overview: input.overview,
            posterPath: input.posterPath, backdropPath: input.backdropPath,
            status: result.status == SeerrRequest.pending ? .pending : .approved,
            outcome: .active, targets: nil, libraryContentId: nil, lastError: nil,
            createdAt: Date(), updatedAt: Date(), completedAt: nil)
    }

    // MARK: Mapping

    private static func path(_ type: RequestMediaType) -> String {
        type == .movie ? "movie" : "tv"
    }

    private static func availability(_ info: SeerrMediaInfo?) -> RequestAvailability {
        info?.status == SeerrMediaInfo.available ? .available : .missing
    }

    /// The title's standard request, and whether this account may request
    /// it. 4K requests are ignored.
    private func state(_ info: SeerrMediaInfo?, type: RequestMediaType) -> RequestState {
        let active = info?.requests?.first {
            ($0.status == SeerrRequest.pending || $0.status == SeerrRequest.approved) && $0.is4k != true
        }
        let status: RequestStatus?
        if let active {
            status = active.status == SeerrRequest.pending ? .pending : .approved
        } else if info?.status == SeerrMediaInfo.pending {
            status = .pending
        } else if info?.status == SeerrMediaInfo.processing {
            status = .approved
        } else {
            status = nil
        }
        let allowed = permissions & SeerrPermission.requests(for: type) != 0
        let blocked = info?.status == SeerrMediaInfo.blocked
        let requestable = allowed && !blocked && status == nil && info?.status != SeerrMediaInfo.available
        let reason: String? = blocked ? "blocked" : allowed ? nil : "permission_denied"
        return RequestState(status: status, requestable: requestable, reason: reason, requestId: active.map { String($0.id) })
    }

    // MARK: Transport

    /// Signs in first if needed, and once more if Seerr says the session
    /// has expired.
    private func request<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> T {
        if !signedIn { try await authenticate() }
        var (data, status) = try await send(path, query: query, body: body)
        if status == 401 {
            signedIn = false
            try await authenticate()
            (data, status) = try await send(path, query: query, body: body)
        }
        return try JSONDecoder().decode(T.self, from: checked(data, status: status))
    }

    /// A GET, or a JSON POST when there's a body.
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
            throw TVSeerrError(message: String(localized: "Seerr returned an invalid response."))
        }
        return (data, response.statusCode)
    }

    /// The body of a successful answer. A failure is described by its status
    /// only, never by the body, which can echo the submitted login.
    private func checked(_ data: Data, status: Int) throws -> Data {
        guard !(200..<300).contains(status) else { return data }
        let message: String
        switch status {
        case 301...399: message = String(localized: "Use the final Seerr URL; this address redirects elsewhere.")
        case 401: message = String(localized: "Seerr could not sign in. Check your username and password.")
        case 403: message = String(localized: "Seerr rejected the login or this account does not have permission.")
        case 409: message = String(localized: "This title has already been requested.")
        case 429: message = String(localized: "Seerr's request limit was reached. Try again later.")
        default: message = String(localized: "Seerr could not complete this request (\(status)). Check its connection and request settings.")
        }
        throw TVSeerrError(message: message)
    }
}

// MARK: - Seerr's API

/// Seerr's permission bits that allow standard requests.
private enum SeerrPermission {
    static let admin = 2
    static let request = 32
    static let requestMovie = 262_144
    static let requestTV = 524_288

    static func requests(for type: RequestMediaType) -> Int {
        admin | request | (type == .movie ? requestMovie : requestTV)
    }
}

private struct SeerrUser: Decodable {
    let permissions: Int
}

private struct SeerrPage: Decodable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [SeerrItem]
}

private struct SeerrRequest: Decodable {
    static let pending = 1
    static let approved = 2

    let id: Int
    let status: Int
    let is4k: Bool?
}

private struct SeerrMediaInfo: Decodable {
    static let pending = 2
    static let processing = 3
    static let available = 5
    static let blocked = 6

    let status: Int
    let requests: [SeerrRequest]?
}

private struct SeerrName: Decodable {
    let name: String
}

private struct SeerrSeason: Decodable {
    let seasonNumber: Int
}

private struct SeerrExternalIDs: Decodable {
    let imdbId: String?
    let tvdbId: Int?
}

/// A movie or series from search or detail. Movies have a title and a
/// release date, series a name and a first air date.
private struct SeerrItem: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let tagline: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let numberOfEpisodes: Int?
    let seasons: [SeerrSeason]?
    let genres: [SeerrName]?
    let networks: [SeerrName]?
    let createdBy: [SeerrName]?
    let externalIds: SeerrExternalIDs?
    let mediaInfo: SeerrMediaInfo?

    /// People and anything else that isn't a movie or series is nil.
    var type: RequestMediaType? {
        switch mediaType {
        case "movie": .movie
        case "tv": .series
        default: nil
        }
    }
    var displayTitle: String { title ?? name ?? String(localized: "Untitled") }
    var date: String? { releaseDate ?? firstAirDate }
    var year: Int? { date.flatMap { Int($0.prefix(4)) } }
}

// MARK: - Saved connection

/// The Seerr connection for the active server account and profile.
///
/// It's kept in Keychain under the account's vault key, so it syncs with
/// the person's other devices. A connection saved by an earlier version
/// under a key of its own is moved across the first time it's read.
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

    /// The server, account and profile, hashed.
    private var scope: String {
        let parts = [ServerRegistry.shared.activeServerId ?? "", accountContext, AuthService.shared.profileId ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The Keychain key, moving a connection saved under the old key first.
    private var key: String {
        let legacy = "vivid.seerr.\(scope)"
        guard let canonical = VividCloudPreferences.activeCredentialKey("seerr") else { return legacy }
        if keychain.get(canonical) == nil, let value = keychain.get(legacy), keychain.set(value, for: canonical) {
            _ = keychain.delete(legacy)
        }
        return canonical
    }

    /// Nil without a matching saved account, so nothing is read for a
    /// server or profile the connection doesn't belong to.
    var configuration: TVSeerrConfiguration? {
        _ = revision
        guard VividCloudPreferences.matchingActiveAccount != nil,
              let string = keychain.get(key), let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TVSeerrConfiguration.self, from: data)
    }

    /// Changes whenever the account, profile or saved connection does, so
    /// an answer that arrives after a change is dropped.
    var identity: String { "\(scope):\(configuration?.id.uuidString ?? "none")" }
    var isConfigured: Bool { configuration != nil }

    /// The vault brought in a change from another device.
    func cloudPreferencesChanged() {
        clients.removeAll()
        revision += 1
    }

    /// Signs in before saving. A blank password keeps the saved one when the
    /// address and username are unchanged.
    func connect(url: String, username: String, password: String) async throws {
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw CancellationError() }
        let start = identity
        let cleanedURL = try TVSeerrClient.validatedURL(url).absoluteString
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = configuration
        let sameLogin = existing?.url == cleanedURL && existing?.username == username
        let password = password.isEmpty && sameLogin ? existing?.password ?? "" : password
        guard !username.isEmpty, !password.isEmpty else {
            throw TVSeerrError(message: String(localized: "Enter your Seerr username and password."))
        }
        let config = TVSeerrConfiguration(url: cleanedURL, username: username, password: password)
        let client = try TVSeerrClient(configuration: config)
        try await client.authenticate()
        guard start == identity else { throw CancellationError() }
        guard let value = String(data: try JSONEncoder().encode(config), encoding: .utf8),
              keychain.set(value, for: key) else {
            throw TVSeerrError(message: String(localized: "Couldn't securely save this connection."))
        }
        clients = [config.id: client]
        revision += 1
        VividCloudPreferences.shared.schedule()
    }

    func disconnect() throws {
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw CancellationError() }
        guard keychain.delete(key) else {
            throw TVSeerrError(message: String(localized: "Couldn't remove the saved connection."))
        }
        clients.removeAll()
        revision += 1
        VividCloudPreferences.shared.schedule()
    }

    func search(_ query: String) async throws -> RequestMediaPage {
        try await current { try await $0.search(query) }
    }

    func detail(type: RequestMediaType, id: Int) async throws -> RequestMediaDetail {
        try await current { try await $0.detail(type: type, id: id) }
    }

    func create(_ input: CreateRequestInput) async throws -> MediaRequest {
        try await current { try await $0.create(input) }
    }

    /// Runs a call on the saved connection's client, dropping the answer if
    /// the account, profile or connection changed meanwhile.
    private func current<T>(_ call: (TVSeerrClient) async throws -> T) async throws -> T {
        let start = identity
        let result = try await call(client())
        guard start == identity else { throw CancellationError() }
        return result
    }

    /// One client per saved connection, so its sign-in is reused.
    private func client() throws -> TVSeerrClient {
        guard let config = configuration else {
            throw TVSeerrError(message: String(localized: "Configure Seerr in Settings to request titles."))
        }
        if let cached = clients[config.id] { return cached }
        let client = try TVSeerrClient(configuration: config)
        clients = [config.id: client]
        return client
    }
}
#endif
