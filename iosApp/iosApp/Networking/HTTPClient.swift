import Foundation
import OSLog

/// The routing identity of a request that must not follow the app's active
/// server and profile (the settings outbox, for one). It's captured before
/// the work is queued; `TokenStore` then checks it and reads the matching
/// credentials in one actor turn before anything is sent.
struct HTTPRequestIdentity: Equatable, Sendable {
    let serverId: String
    let serverURL: String
    let profileId: String
    let clientFamily: String
    var credentialGenerationID: UUID? = nil
}

enum CapturedHTTPRequestCredentialOwner: Equatable, Sendable {
    case persistentServer(serverId: String)
}

/// The credentials for one request with a captured identity.
struct CapturedHTTPRequestAuth: Sendable {
    let account: RefreshAccountIdentity
    let serverURL: String
    let accessToken: String?
    let refreshToken: String?
    let profileId: String
    let profileToken: String?
    let credentialOwner: CapturedHTTPRequestCredentialOwner

    init(
        account: RefreshAccountIdentity,
        serverURL: String,
        accessValue: String?,
        refreshValue value: String?,
        profileId: String,
        profileValue otherValue: String?,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) {
        self.account = account
        self.serverURL = serverURL
        accessToken = accessValue
        refreshToken = value
        self.profileId = profileId
        profileToken = otherValue
        self.credentialOwner = credentialOwner
    }
}

/// Which request path joined an existing refresh flight, so tests can prove
/// both paths share one.
enum RefreshFlightJoinKind: Sendable {
    case scoped
    case ordinary
}

/// The exclusive lease for an identity switch, from its first cancellation
/// to the final defaults and `TokenStore` commit. Requests are refused while
/// one is held, so none can read a half-switched set of credentials.
struct HTTPIdentityTransitionLease: Hashable, Sendable {
    fileprivate let id: UUID
}

/// The app's HTTP client.
///
/// - Builds requests against the active server's address and signs them
///   (`Authorization: Bearer`, `X-Profile-Id`, `X-Profile-Token` and the
///   device headers), except `/auth/refresh` and `/auth/login`.
/// - Hands an Emby or Jellyfin account's requests to its adapter, and maps
///   Silo requests to v2 where the server has it.
/// - On a 401, joins every concurrent failure for the same account into one
///   refresh and retries once with the new token. A refused refresh is sent
///   again after 3 and 6 seconds, inside the same flight, before the session
///   is treated as expired.
/// - Keeps a gate that identity switches close: while a switch or a
///   cancellation pass runs, new requests are refused, and responses that
///   arrive for requests sent before it are dropped.
/// - Codes JSON with snake_case conversion, so models use camelCase
///   properties and only need `CodingKeys` where a wire name isn't the plain
///   snake_case of the property.
actor HTTPClient {
    static let shared = HTTPClient()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "HTTPClient"
    )

    private let session: URLSession
    /// For endpoints that hold the connection past the standard timeout
    /// (`HTTPTimeout.extended`). A separate session keeps the timeout clear.
    private let longWaitSession: URLSession
    private let apiDiscovery: SiloAPIDiscovery
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    /// Pauses before a refused refresh is sent again.
    private let refusedRefreshRetryDelays: [Duration]

    // Test hooks. Production passes nil for all of them.
    private let refreshFlightJoinObserver: (@Sendable (RefreshFlightJoinKind) -> Void)?
    /// Runs at the start of each cancellation pass.
    private let cancellationPassBarrier: (@Sendable () async -> Void)?
    /// Runs after each session's tasks are cancelled, with its number.
    private let cancellationSessionBarrier: (@Sendable (Int) async -> Void)?
    /// Runs between a successful scoped refresh and its retry.
    private let scopedRefreshRetryBarrier: (@Sendable () async -> Void)?
    private let requestCaptureBarrier: (@Sendable () async -> Void)?
    private let responseReceivedBarrier: (@Sendable () async -> Void)?

    /// Refresh tokens rotate per server account, so ordinary and
    /// captured-identity requests share one flight per account.
    private var inFlightRefreshes: [RefreshAccountIdentity: RefreshFlight] = [:]
    /// Cancellation passes run one after another, so a new identity can wait
    /// for its own pass without an older one cancelling its requests later.
    private var cancellationTail: CancellationFlight?
    private var activeIdentityTransitionLease: HTTPIdentityTransitionLease?
    private var identityTransitionWaiters: [IdentityTransitionWaiter] = []
    private var requestDispatchWaiters: [RequestDispatchWaiter] = []
    /// Bumped by every switch and cancellation pass, so a request captured
    /// before one is refused even if a short switch began and ended while it
    /// was waiting on another actor.
    private var requestDispatchRevision: UInt64 = 0

    /// Silo v2 state, cleared by every cancellation pass: catalogue window
    /// cursors (keyed with the credentials, never logged), the playback
    /// installation per server, and each playback session's installation and
    /// progress sequence.
    private var siloCatalogWindows: [String: String] = [:]
    private var siloPlaybackInstallations: [URL: String] = [:]
    private var siloPlaybackSessions: [String: (installation: String, sequence: Int)] = [:]

    private struct RefreshFlight {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private struct CancellationFlight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct IdentityTransitionWaiter {
        let id: UUID
        let lease: HTTPIdentityTransitionLease
        let continuation: CheckedContinuation<HTTPIdentityTransitionLease?, Never>
    }

    private struct RequestDispatchWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    init(
        apiDiscovery: SiloAPIDiscovery = SiloAPIDiscovery(),
        session: URLSession? = nil,
        tokenStore: TokenStore = .shared,
        refusedRefreshRetryDelays: [Duration] = HTTPClient.defaultRefusedRefreshRetryDelays,
        refreshFlightJoinObserver: (@Sendable (RefreshFlightJoinKind) -> Void)? = nil,
        cancellationPassBarrier: (@Sendable () async -> Void)? = nil,
        cancellationSessionBarrier: (@Sendable (Int) async -> Void)? = nil,
        scopedRefreshRetryBarrier: (@Sendable () async -> Void)? = nil,
        requestCaptureBarrier: (@Sendable () async -> Void)? = nil,
        responseReceivedBarrier: (@Sendable () async -> Void)? = nil
    ) {
        self.apiDiscovery = apiDiscovery
        // An injected session (tests) serves both timeouts, so mocks see
        // every request.
        self.session = session ?? Self.makeSession(requestTimeout: 15)
        self.longWaitSession = session ?? Self.makeSession(requestTimeout: 90)
        self.tokenStore = tokenStore
        self.refusedRefreshRetryDelays = refusedRefreshRetryDelays
        self.refreshFlightJoinObserver = refreshFlightJoinObserver
        self.cancellationPassBarrier = cancellationPassBarrier
        self.cancellationSessionBarrier = cancellationSessionBarrier
        self.scopedRefreshRetryBarrier = scopedRefreshRetryBarrier
        self.requestCaptureBarrier = requestCaptureBarrier
        self.responseReceivedBarrier = responseReceivedBarrier
        self.decoder = Self.makeJSONDecoder()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    /// Snake_case keys, and ISO 8601 dates with or without fractional
    /// seconds (Silo sends `2026-04-13T04:46:42.211273Z`, which the built-in
    /// `.iso8601` strategy rejects).
    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = Self.isoFractional.date(from: text) { return date }
            if let date = Self.isoWhole.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable ISO-8601 date: \(text)")
        }
        return decoder
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoWhole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// No shared HTTP cache: a URL-keyed cache ignores the auth and profile
    /// headers, so a response fetched for one profile (or a cached 401) could
    /// be served to another. The timeout is the longest quiet gap between
    /// bytes, not a total, so a slow but live server is unaffected while a
    /// dead one fails in seconds rather than a minute.
    private static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        return URLSession(configuration: configuration)
    }

    // MARK: - Requests

    /// `sendsProfile: false` sends the account credential without the
    /// profile headers, for an account-level read that must still answer
    /// after the active profile has been removed.
    func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        expectedAuth: CapturedOrdinaryRequestAuth? = nil,
        sendsProfile: Bool = true
    ) async throws -> T {
        try await send(method: "GET", path: path, query: query, body: Optional<String>.none,
                       expectedAuth: expectedAuth, sendsProfile: sendsProfile)
    }

    /// Asks a server the user is adding, without touching the active routing
    /// or sending the active server's credentials.
    func getUnauthenticated<T: Decodable>(
        serverURL: String,
        path: String,
        quietStatuses: Set<Int> = [],
        diagnosticPath: String? = nil
    ) async throws -> T {
        let data = try await sendDetached(serverURL: serverURL, method: "GET", path: path, body: nil, quietStatuses: quietStatuses)
        return try decode(T.self, from: data, path: diagnosticPath ?? path)
    }

    #if os(tvOS) || os(iOS)
    func loginSavedAccount(serverURL: String, username: String, password: String) async throws -> LoginResponse {
        let data = try await sendDetached(serverURL: serverURL, method: "POST", path: "/api/v1/auth/login",
                                          body: LoginRequest(username: username, password: password))
        return try decoder.decode(LoginResponse.self, from: data)
    }

    /// Checks a viewing profile's PIN for a session other than the active
    /// one; Silo binds the returned proof to that session. Nil means the PIN
    /// didn't match.
    func verifyProfilePIN(serverURL: String, accessToken: String, profileID: String, pin: String) async throws -> String? {
        let data = try await sendDetached(serverURL: serverURL, method: "POST", path: "/api/v1/profiles/\(profileID)/verify-pin",
                                          body: VerifyPinRequest(pin: pin), accessToken: accessToken)
        let result = try decoder.decode(VerifyPinResponse.self, from: data)
        return result.valid ? result.profileToken : nil
    }

    /// Ends a session other than the active one, best effort.
    func logoutSession(serverURL: String, accessToken: String) async {
        guard let revision = try? captureRequestDispatchRevision(),
              var request = try? buildRequest(serverUrl: ServerRegistry.normalize(url: serverURL), method: "POST",
                                              path: "/api/v1/auth/logout", query: [:], body: nil)
        else { return }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await perform(request: request, dispatchRevision: revision, reportReachability: false)
    }
    #endif

    func post<T: Decodable>(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:],
        timeout: HTTPTimeout = .standard,
        expectedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws -> T {
        try await send(method: "POST", path: path, query: query, body: body, timeout: timeout, expectedAuth: expectedAuth)
    }

    func postVoid(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:],
        expectedAccount: RefreshAccountIdentity? = nil
    ) async throws {
        _ = try await performWithAuthRetry(method: "POST", path: path, timeout: .standard, expectedAccount: expectedAccount) { serverUrl in
            try self.buildRequest(serverUrl: serverUrl, method: "POST", path: path, query: query, body: body)
        }
    }

    func put<T: Decodable>(_ path: String, body: (any Encodable)? = nil, query: [String: String] = [:]) async throws -> T {
        try await send(method: "PUT", path: path, query: query, body: body)
    }

    func putVoid(_ path: String, body: (any Encodable)? = nil, query: [String: String] = [:]) async throws {
        _ = try await sendRaw(method: "PUT", path: path, query: query, body: body)
    }

    func delete(_ path: String, query: [String: String] = [:], expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws {
        _ = try await sendRaw(method: "DELETE", path: path, query: query, body: Optional<String>.none, expectedAuth: expectedAuth)
    }

    func patch<T: Decodable>(_ path: String, body: (any Encodable)? = nil, query: [String: String] = [:]) async throws -> T {
        try await send(method: "PATCH", path: path, query: query, body: body)
    }

    func patchVoid(
        _ path: String,
        body: (any Encodable)? = nil,
        query: [String: String] = [:],
        expectedAuth: CapturedOrdinaryRequestAuth? = nil
    ) async throws {
        _ = try await sendRaw(method: "PATCH", path: path, query: query, body: body, expectedAuth: expectedAuth)
    }

    /// The undecoded body of an endpoint that returns bytes rather than
    /// JSON (the download artwork and subtitle proxies), with the same
    /// signing and 401 refresh as `get`.
    func getData(_ path: String, query: [String: String] = [:], expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> Data {
        try await sendRaw(method: "GET", path: path, query: query, body: Optional<String>.none, expectedAuth: expectedAuth)
    }

    /// True for any 2xx and false for 404, for endpoints that answer by
    /// status alone (`/favorites/{id}` answers 204 or 404). Anything else
    /// throws. The 404 is quiet, so it isn't logged as a failure.
    func exists(_ path: String, query: [String: String] = [:]) async throws -> Bool {
        do {
            _ = try await sendRaw(method: "GET", path: path, query: query, body: Optional<String>.none, quietStatuses: [404])
            return true
        } catch HTTPError.http(let code, _) where code == 404 {
            return false
        }
    }

    /// Sends a ready-made body with extra headers and no JSON coding, and
    /// returns the status and headers with the bytes. The typed settings API
    /// needs this: its values must keep their object keys exactly, it sends
    /// `X-Silo-Mutation-Id` and it reads `X-Silo-Idempotent-Replay`.
    ///
    /// `headers` go on after the auth, profile and device headers, so a
    /// caller can address another profile. With a `requestIdentity` the
    /// request is pinned to that server and profile: it's refused if either
    /// has changed, and only refreshes for that same account.
    func requestData(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout = .standard,
        requestIdentity: HTTPRequestIdentity? = nil
    ) async throws -> HTTPRawResponse {
        guard let requestIdentity else {
            let (data, response) = try await performWithAuthRetry(
                method: method, path: path, additionalHeaders: headers, quietStatuses: quietStatuses, timeout: timeout
            ) { serverUrl in
                var request = try self.buildRequest(serverUrl: serverUrl, method: method, path: path, query: query, body: Optional<String>.none)
                if let body {
                    request.httpBody = body
                    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                }
                return request
            }
            return HTTPRawResponse(data: data, statusCode: response.statusCode, headers: response.allHeaderFields)
        }

        switch MediaServerProvider.forServerID(requestIdentity.serverId) {
        case .jellyfin, .emby:
            return try await routeScopedToNativeAdapter(method: method, path: path, query: query, body: body, identity: requestIdentity)
        case .silo:
            return try await sendScoped(
                method: method, path: path, query: query, body: body, contentType: contentType,
                headers: headers, quietStatuses: quietStatuses, timeout: timeout, identity: requestIdentity
            )
        }
    }

    // MARK: - Sending

    private func send<T: Decodable>(
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?,
        timeout: HTTPTimeout = .standard,
        expectedAuth: CapturedOrdinaryRequestAuth? = nil,
        sendsProfile: Bool = true
    ) async throws -> T {
        let data = try await sendRaw(method: method, path: path, query: query, body: body, timeout: timeout,
                                     expectedAuth: expectedAuth, sendsProfile: sendsProfile)
        if data.isEmpty, let empty = EmptyResponse.empty as? T { return empty }
        return try decode(T.self, from: data, path: path)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Self.logDecodingFailure(type: String(describing: T.self), path: path, error: error, data: data)
            throw HTTPError.decodingFailed(type: String(describing: T.self), underlying: error)
        }
    }

    /// The body of a signed request, with the 401 refresh and non-2xx errors.
    private func sendRaw(
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?,
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout = .standard,
        expectedAuth: CapturedOrdinaryRequestAuth? = nil,
        sendsProfile: Bool = true
    ) async throws -> Data {
        try await performWithAuthRetry(
            method: method, path: path, quietStatuses: quietStatuses, timeout: timeout,
            expectedAuth: expectedAuth, sendsProfile: sendsProfile
        ) { serverUrl in
            try self.buildRequest(serverUrl: serverUrl, method: method, path: path, query: query, body: body)
        }.0
    }

    /// A request to a server that isn't (or isn't yet) the active one: no
    /// active credentials, no reachability reports. `accessToken` signs it
    /// for a session other than the active one.
    private func sendDetached(
        serverURL: String,
        method: String,
        path: String,
        body: (any Encodable)?,
        accessToken: String? = nil,
        quietStatuses: Set<Int> = []
    ) async throws -> Data {
        let revision = try captureRequestDispatchRevision()
        var request = try buildRequest(serverUrl: ServerRegistry.normalize(url: serverURL), method: method, path: path, query: [:], body: body)
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await perform(request: request, dispatchRevision: revision, reportReachability: false)
        try ensureSuccess(data, response, method: method, quietStatuses: quietStatuses)
        return data
    }

    /// The signing, provider hand-off, 401 refresh and success check every
    /// ordinary request shares. `makeRequest` builds a fresh unsigned request
    /// for each attempt, so the retry carries the new token with the
    /// caller's body intact. `additionalHeaders` go on last, so they can
    /// override the session's (to address another profile, say);
    /// `sendsProfile: false` leaves the profile headers off both attempts.
    private func performWithAuthRetry(
        method: String,
        path: String,
        additionalHeaders: [String: String] = [:],
        quietStatuses: Set<Int> = [],
        timeout: HTTPTimeout,
        expectedAccount: RefreshAccountIdentity? = nil,
        expectedAuth: CapturedOrdinaryRequestAuth? = nil,
        sendsProfile: Bool = true,
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let dispatchRevision = try captureRequestDispatchRevision()
        if let requestCaptureBarrier { await requestCaptureBarrier() }
        let capturedAuth: CapturedOrdinaryRequestAuth?
        if let expectedAuth {
            guard let matching = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: expectedAuth) else {
                throw HTTPError.requestIdentityChanged
            }
            capturedAuth = matching
        } else {
            capturedAuth = await tokenStore.captureOrdinaryRequestAuth()
        }
        if let expectedAccount, capturedAuth?.account != expectedAccount {
            throw HTTPError.requestIdentityChanged
        }
        let serverUrl = if let capturedAuth { capturedAuth.account.serverURL } else { await tokenStore.getServerUrl() }
        guard !serverUrl.isEmpty else { throw HTTPError.serverUrlNotConfigured }

        switch MediaServerProvider.forServerID(capturedAuth?.account.serverId) {
        case .jellyfin, .emby:
            return try await routeToNativeAdapter(
                method: method, path: path, serverUrl: serverUrl, capturedAuth: capturedAuth,
                additionalHeaders: additionalHeaders, makeRequest: makeRequest
            )
        case .silo:
            break
        }

        func signed(_ auth: CapturedOrdinaryRequestAuth?) async throws -> URLRequest {
            var request = try makeRequest(serverUrl)
            if let auth {
                attachOrdinaryAuthHeaders(&request, auth: auth, sendsProfile: sendsProfile)
            } else {
                await attachLegacyAuthHeaders(&request, sendsProfile: sendsProfile)
            }
            Self.apply(additionalHeaders, to: &request)
            return request
        }

        let (data, response) = try await perform(request: try await signed(capturedAuth), timeout: timeout, dispatchRevision: dispatchRevision)
        if response.statusCode == 401, shouldAttemptRefresh(path: path) {
            // Retry only with one complete, still-current snapshot of the
            // account and profile; if any of it moved during the shared
            // refresh, the original 401 stands rather than mixing credentials.
            if let capturedAuth,
               let refreshedAuth = await refreshTokens(expected: capturedAuth, dispatchRevision: dispatchRevision),
               refreshedAuth.accessToken != nil,
               await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: refreshedAuth) == refreshedAuth {
                let retry = try await signed(refreshedAuth)
                logRefreshRetry(method: method, path: path, retried: true)
                let (retryData, retryResponse) = try await perform(request: retry, timeout: timeout, dispatchRevision: dispatchRevision)
                try ensureSuccess(retryData, retryResponse, method: method, quietStatuses: quietStatuses)
                return (retryData, retryResponse)
            }
            // No captured credentials, the refresh failed, or the identity
            // moved underneath it.
            logRefreshRetry(method: method, path: path, retried: false)
        }
        try ensureSuccess(data, response, method: method, quietStatuses: quietStatuses)
        return (data, response)
    }

    /// A request pinned to a captured Silo identity. Its 401 only refreshes
    /// that same account, and the retry only goes out under the exact owner
    /// and generation that sent the refused request.
    private func sendScoped(
        method: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String,
        headers: [String: String],
        quietStatuses: Set<Int>,
        timeout: HTTPTimeout,
        identity: HTTPRequestIdentity
    ) async throws -> HTTPRawResponse {
        let dispatchRevision = try captureRequestDispatchRevision()
        if let requestCaptureBarrier { await requestCaptureBarrier() }
        let auth = try await tokenStore.captureRequestAuth(expected: identity)

        func signed(_ auth: CapturedHTTPRequestAuth) throws -> URLRequest {
            var request = try buildRequest(serverUrl: auth.serverURL, method: method, path: path, query: query, body: Optional<String>.none)
            if let body {
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            attachCapturedAuthHeaders(&request, auth: auth)
            Self.apply(headers, to: &request)
            return request
        }

        var (data, response) = try await perform(request: try signed(auth), timeout: timeout, dispatchRevision: dispatchRevision)
        if response.statusCode == 401, shouldAttemptRefresh(path: path) {
            if await refreshScopedTokens(auth: auth, expected: identity, dispatchRevision: dispatchRevision) {
                if let scopedRefreshRetryBarrier { await scopedRefreshRetryBarrier() }
                // The identity carries no credential epoch, so capture again
                // after every suspension and compare with the original.
                if let refreshed = try? await tokenStore.captureRequestAuth(expected: identity),
                   refreshed.account == auth.account,
                   refreshed.credentialOwner == auth.credentialOwner,
                   refreshed.accessToken != nil,
                   refreshed.accessToken != auth.accessToken || refreshed.refreshToken != auth.refreshToken {
                    let retry = try signed(refreshed)
                    logRefreshRetry(method: method, path: path, retried: true)
                    (data, response) = try await perform(request: retry, timeout: timeout, dispatchRevision: dispatchRevision)
                } else {
                    // The refresh said yes but the new capture disagreed, which
                    // from outside looks like no refresh at all.
                    logRefreshRetry(method: method, path: path, retried: false)
                }
            } else {
                // Eligible but declined: another owner, no refresh token, or
                // the gate is closed.
                logRefreshRetry(method: method, path: path, retried: false)
            }
        }
        try ensureSuccess(data, response, method: method, quietStatuses: quietStatuses)
        return HTTPRawResponse(data: data, statusCode: response.statusCode, headers: response.allHeaderFields)
    }

    // MARK: - Emby and Jellyfin

    /// Answers an Emby or Jellyfin account's request from its adapter, as a
    /// 200 with the adapter's JSON. The connection must still be exactly the
    /// captured sign-in, and an explicit `X-Profile-Id` must be its user.
    private func routeToNativeAdapter(
        method: String,
        path: String,
        serverUrl: String,
        capturedAuth: CapturedOrdinaryRequestAuth?,
        additionalHeaders: [String: String],
        makeRequest: (String) throws -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let explicitProfile = additionalHeaders.first { $0.key.lowercased() == "x-profile-id" }?.value
        let route: (_ query: [String: String], _ body: Any?) async throws -> Any
        let outgoing: URLRequest
        if MediaServerProvider.forServerID(capturedAuth?.account.serverId) == .jellyfin {
            let connection = try await JellyfinConnection.current()
            guard connection.identity == capturedAuth else { throw HTTPError.requestIdentityChanged }
            if let explicitProfile, explicitProfile != connection.identity?.profileId { throw HTTPError.requestIdentityChanged }
            outgoing = try makeRequest(serverUrl)
            route = { query, body in
                let result = try await JellyfinAdapter(connection: connection).route(method: method, path: path, query: query, body: body)
                try await connection.validate()
                return result
            }
        } else {
            let connection = try await EmbyConnection.current()
            guard connection.identity == capturedAuth else { throw HTTPError.requestIdentityChanged }
            if let explicitProfile, explicitProfile != connection.identity?.profileId { throw HTTPError.requestIdentityChanged }
            outgoing = try makeRequest(serverUrl)
            route = { query, body in
                let result = try await EmbyAdapter(connection: connection).route(method: method, path: path, query: query, body: body)
                try await connection.validate()
                return result
            }
        }
        let items = URLComponents(url: outgoing.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
        let body = try outgoing.httpBody.map { try JSONSerialization.jsonObject(with: $0) }
        let result = try await route(query, body)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        return (data, HTTPURLResponse(url: outgoing.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// `routeToNativeAdapter` for a request with a captured identity, which
    /// must match the active connection's account and profile.
    private func routeScopedToNativeAdapter(
        method: String,
        path: String,
        query: [String: String],
        body: Data?,
        identity: HTTPRequestIdentity
    ) async throws -> HTTPRawResponse {
        _ = try captureRequestDispatchRevision()
        let auth = try await tokenStore.captureRequestAuth(expected: identity)
        let result: Any
        if MediaServerProvider.forServerID(identity.serverId) == .jellyfin {
            let connection = try await JellyfinConnection.current()
            guard connection.identity?.account == auth.account, connection.identity?.profileId == auth.profileId else {
                throw HTTPError.requestIdentityChanged
            }
            let value = try body.map { try JSONSerialization.jsonObject(with: $0) }
            result = try await JellyfinAdapter(connection: connection).route(method: method, path: path, query: query, body: value)
            try await connection.validate()
        } else {
            let connection = try await EmbyConnection.current()
            guard connection.identity?.account == auth.account, connection.identity?.profileId == auth.profileId else {
                throw HTTPError.requestIdentityChanged
            }
            let value = try body.map { try JSONSerialization.jsonObject(with: $0) }
            result = try await EmbyAdapter(connection: connection).route(method: method, path: path, query: query, body: value)
            try await connection.validate()
        }
        return HTTPRawResponse(data: try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]), statusCode: 200, headers: [:])
    }

    // MARK: - Building and signing

    private func buildRequest(
        serverUrl: String,
        method: String,
        path: String,
        query: [String: String],
        body: (any Encodable)?
    ) throws -> URLRequest {
        guard var components = URLComponents(string: serverUrl) else { throw HTTPError.invalidURL(serverUrl) }
        // `path` may come with or without its leading slash.
        let path = path.hasPrefix("/") ? path : "/" + path
        let base = components.percentEncodedPath
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = try Self.validatedRequestPath(trimmedBase + path)
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw HTTPError.invalidURL(components.description) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(AnyEncodable(body))
            } catch {
                throw HTTPError.encodingFailed(underlying: error)
            }
        }
        return request
    }

    /// Checks a request path without Foundation's trapping
    /// `percentEncodedPath` setter. Already-encoded asset paths keep their
    /// escaping.
    static func validatedRequestPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"),
              let parsed = URLComponents(string: "https://path.invalid" + path, encodingInvalidCharacters: false),
              parsed.host == "path.invalid", parsed.query == nil, parsed.fragment == nil,
              parsed.percentEncodedPath == path
        else { throw HTTPError.invalidURL(path) }
        return parsed.percentEncodedPath
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    /// For the state before any server is registered. Normal requests use
    /// `attachOrdinaryAuthHeaders`, whose credentials are read in one turn.
    private func attachLegacyAuthHeaders(_ request: inout URLRequest, sendsProfile: Bool = true) async {
        let path = request.url?.path ?? ""
        guard !Self.isAuthEndpoint(path) else { return }
        var attached: [String] = []
        if let token = await tokenStore.getAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            attached.append("auth")
        }
        if sendsProfile, let profileId = await tokenStore.getProfileId() {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
            attached.append("profile")
        }
        if sendsProfile, let profileToken = await tokenStore.getProfileToken() {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
            attached.append("profileToken")
        }
        attachIdentityAndTrace(&request, path: path, credentials: attached)
    }

    /// Signs with the snapshot captured before the request was built, with no
    /// actor hops between headers, so a profile change can't mix them.
    private func attachOrdinaryAuthHeaders(_ request: inout URLRequest, auth: CapturedOrdinaryRequestAuth, sendsProfile: Bool = true) {
        let path = request.url?.path ?? ""
        guard !Self.isAuthEndpoint(path) else { return }
        var attached: [String] = []
        if let token = auth.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            attached.append("auth")
        }
        if sendsProfile, let profileId = auth.profileId {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
            attached.append("profile")
        }
        if sendsProfile, let profileToken = auth.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
            attached.append("profileToken")
        }
        attachIdentityAndTrace(&request, path: path, credentials: attached)
    }

    /// The device headers and the one-line request trace, shared by both
    /// signing paths. `credentials` names what was attached; nothing here is
    /// user data, so the line is public.
    private func attachIdentityAndTrace(_ request: inout URLRequest, path: String, credentials: [String]) {
        let device = AppleDeviceIdentity.current
        device.applyHeaders(to: &request)
        let trace = credentials + [
            "device=\(device.platform)/\(device.clientFamily)",
            // The channel is the only thing that tells a re-signed sideload
            // from a release build of the same version.
            "client=\(device.clientName) \(device.appVersion) (\(device.appBuild)) \(device.channel)",
        ]
        let method = request.httpMethod ?? ""
        let attachedDescription = trace.joined(separator: ", ")
        Self.logger.debug("→ \(method, privacy: .public) \(path, privacy: .public) headers=[\(attachedDescription, privacy: .public)]")
    }

    /// Signs a request with a captured identity. These don't use the shared
    /// refresh: after a switch, a 401 is safer than refreshing into the wrong
    /// server's slot.
    private func attachCapturedAuthHeaders(_ request: inout URLRequest, auth: CapturedHTTPRequestAuth) {
        if let token = auth.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(auth.profileId, forHTTPHeaderField: "X-Profile-Id")
        if let profileToken = auth.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        AppleDeviceIdentity.current.applyHeaders(to: &request)
    }

    /// No auth headers go to `/auth/refresh` (it would recurse) or
    /// `/auth/login` (an expired token can't authorise a fresh sign-in), and
    /// a 401 from either isn't refreshed.
    private static func isAuthEndpoint(_ path: String) -> Bool {
        path.hasSuffix("/auth/refresh") || path.hasSuffix("/auth/login")
    }

    private func shouldAttemptRefresh(path: String) -> Bool {
        !Self.isAuthEndpoint(path)
    }
}

// MARK: - Identity transitions

extension HTTPClient {
    /// Cancels every in-flight request and refresh, and closes the gate until
    /// the pass finishes. The registry calls this before retargeting
    /// `TokenStore`, so an old server's answer can't land in the new server's
    /// slot. Passes queue behind each other, and the caller waits for its own.
    func cancelInFlightRequests() async {
        requestDispatchRevision &+= 1
        let previous = cancellationTail?.task
        let flightID = UUID()
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performCancellationPass()
        }
        cancellationTail = CancellationFlight(id: flightID, task: task)
        await task.value
        if cancellationTail?.id == flightID { cancellationTail = nil }
        resumeRequestDispatchWaitersIfOpen()
    }

    /// Waits until the gate opens, for a caller that hasn't captured any
    /// identity yet (so waiting is safe). False when cancelled.
    func waitForRequestDispatchOpen() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isRequestDispatchBlocked else { return true }
        let waiterID = UUID()
        let opened = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else if !isRequestDispatchBlocked {
                    continuation.resume(returning: true)
                } else {
                    requestDispatchWaiters.append(RequestDispatchWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelRequestDispatchWaiter(id: waiterID) }
        }
        return opened && !Task.isCancelled
    }

    /// Takes the exclusive lease for a whole server or account switch.
    /// Switches queue in order, and requests, refreshes and dispatch stay
    /// closed until the holder releases it. Nil when cancelled.
    func beginIdentityTransition() async -> HTTPIdentityTransitionLease? {
        guard !Task.isCancelled else { return nil }
        let lease = HTTPIdentityTransitionLease(id: UUID())
        guard activeIdentityTransitionLease != nil else {
            requestDispatchRevision &+= 1
            activeIdentityTransitionLease = lease
            if Task.isCancelled {
                endIdentityTransition(lease)
                return nil
            }
            return lease
        }
        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HTTPIdentityTransitionLease?, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    identityTransitionWaiters.append(IdentityTransitionWaiter(id: waiterID, lease: lease, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelIdentityTransitionWaiter(id: waiterID) }
        }
        guard let granted else { return nil }
        if Task.isCancelled {
            endIdentityTransition(granted)
            return nil
        }
        return granted
    }

    /// Releases the lease to the next waiting switch, or opens the gate.
    func endIdentityTransition(_ lease: HTTPIdentityTransitionLease) {
        guard activeIdentityTransitionLease == lease else { return }
        guard !identityTransitionWaiters.isEmpty else {
            activeIdentityTransitionLease = nil
            resumeRequestDispatchWaitersIfOpen()
            return
        }
        let next = identityTransitionWaiters.removeFirst()
        activeIdentityTransitionLease = next.lease
        next.continuation.resume(returning: next.lease)
    }

    func isIdentityTransitionActive(_ lease: HTTPIdentityTransitionLease) -> Bool {
        activeIdentityTransitionLease == lease
    }

    func pendingIdentityTransitionCount() -> Int {
        identityTransitionWaiters.count
    }

    func pendingRequestDispatchWaiterCount() -> Int {
        requestDispatchWaiters.count
    }

    private func cancelIdentityTransitionWaiter(id: UUID) {
        guard let index = identityTransitionWaiters.firstIndex(where: { $0.id == id }) else { return }
        identityTransitionWaiters.remove(at: index).continuation.resume(returning: nil)
    }

    private func cancelRequestDispatchWaiter(id: UUID) {
        guard let index = requestDispatchWaiters.firstIndex(where: { $0.id == id }) else { return }
        requestDispatchWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeRequestDispatchWaitersIfOpen() {
        guard !isRequestDispatchBlocked, !requestDispatchWaiters.isEmpty else { return }
        let waiters = requestDispatchWaiters
        requestDispatchWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: true) }
    }

    private func performCancellationPass() async {
        siloCatalogWindows.removeAll()
        siloPlaybackInstallations.removeAll()
        siloPlaybackSessions.removeAll()
        if let cancellationPassBarrier { await cancellationPassBarrier() }
        inFlightRefreshes.values.forEach { $0.task.cancel() }
        inFlightRefreshes.removeAll()
        for (index, session) in [session, longWaitSession].enumerated() {
            await withCheckedContinuation { continuation in
                session.getAllTasks { tasks in
                    for task in tasks { task.cancel() }
                    continuation.resume()
                }
            }
            if let cancellationSessionBarrier { await cancellationSessionBarrier(index + 1) }
        }
    }

    private var isRequestDispatchBlocked: Bool {
        cancellationTail != nil || activeIdentityTransitionLease != nil
    }

    private func captureRequestDispatchRevision() throws -> UInt64 {
        try ensureRequestDispatchAllowed(expectedRevision: requestDispatchRevision)
        return requestDispatchRevision
    }

    private func ensureRequestDispatchAllowed(expectedRevision: UInt64) throws {
        guard !isRequestDispatchBlocked, requestDispatchRevision == expectedRevision else {
            throw HTTPError.requestIdentityChanged
        }
    }

    /// Whether the gate is still open at the revision a request captured.
    private func isDispatchOpen(at revision: UInt64) -> Bool {
        !isRequestDispatchBlocked && requestDispatchRevision == revision
    }
}

// MARK: - Transport

extension HTTPClient {
    /// Sends a request, through Silo's v2 adaptation when the server has v2.
    /// Every ordinary request reaches the network through here and
    /// `performTransport`; the token refresh has its own
    /// `performRefreshTransport`. Nothing else in this file may call
    /// `session.data(for:)`, so every request gets exactly one diagnostics line.
    private func perform(
        request: URLRequest,
        timeout: HTTPTimeout = .standard,
        dispatchRevision: UInt64,
        reportReachability: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        let transport = { (request: URLRequest) in
            try await self.performTransport(request: request, timeout: timeout, dispatchRevision: dispatchRevision,
                                            reportReachability: reportReachability)
        }
        guard let url = request.url, let legacyPath = SiloAPICompatibility.legacyPath(url) else {
            return try await transport(request)
        }
        let usesV2: Bool
        do {
            usesV2 = try await apiDiscovery.usesV2(for: url, session: session)
        } catch let error as URLError {
            try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
            if reportReachability { await Self.noteServerUnreachable(for: error) }
            throw HTTPError.network(underlying: error)
        }
        try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        guard usesV2 else { return try await transport(request) }
        return try await performSiloV2(
            original: request, url: url, legacyPath: legacyPath, timeout: timeout,
            dispatchRevision: dispatchRevision, reportReachability: reportReachability, transport: transport
        )
    }

    /// One network round trip, with its diagnostics line. A request is
    /// refused if the gate has closed since it was captured (a cancellation
    /// pass snapshots each session in turn, so one sent in between could
    /// escape it), and a response is dropped if it closed while it was out.
    private func performTransport(
        request: URLRequest,
        timeout: HTTPTimeout = .standard,
        dispatchRevision: UInt64,
        reportReachability: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        #if os(iOS) || os(tvOS)
        // The URL holds the host and query, so only its template is kept
        // where the lines below can see it.
        let trace = RequestTrace(
            method: request.httpMethod ?? "GET",
            path: HTTPDiagnosticsPath.attribute(for: request.url),
            startedAt: ContinuousClock.now
        )
        #endif
        do {
            try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        } catch {
            #if os(iOS) || os(tvOS)
            trace.identityChanged("request rejected", includesDuration: false)
            #endif
            throw error
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (timeout == .extended ? longWaitSession : session).data(for: request)
        } catch {
            if !isDispatchOpen(at: dispatchRevision) {
                #if os(iOS) || os(tvOS)
                trace.identityChanged("request rejected", includesDuration: true)
                #endif
                throw HTTPError.requestIdentityChanged
            }
            // Every transport failure, apart from a cancellation, tells the
            // connection monitor the server may be down.
            if reportReachability { await Self.noteServerUnreachable(for: error) }
            #if os(iOS) || os(tvOS)
            trace.transportFailure(error)
            #endif
            throw HTTPError.network(underlying: error)
        }
        if let responseReceivedBarrier { await responseReceivedBarrier() }
        // Cancelling a task is best effort, so a finished response can race a
        // switch. Drop it before it reaches reachability or any cache.
        do {
            try ensureRequestDispatchAllowed(expectedRevision: dispatchRevision)
        } catch {
            #if os(iOS) || os(tvOS)
            trace.identityChanged("response rejected", includesDuration: true)
            #endif
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            #if os(iOS) || os(tvOS)
            trace.nonHTTPResponse()
            #endif
            throw HTTPError.invalidResponse
        }
        // Any HTTP status proves the server is up.
        if reportReachability {
            await MainActor.run { ConnectionMonitor.shared.noteServerResponded() }
        }
        #if os(iOS) || os(tvOS)
        trace.responseReceived(status: http.statusCode)
        #endif
        return (data, http)
    }

    /// The only signal that a server is unreachable is having no HTTP
    /// response, and a cancellation says nothing either way.
    private static func noteServerUnreachable(for error: Error) async {
        guard let urlError = error as? URLError, urlError.code != .cancelled else { return }
        await MainActor.run { ConnectionMonitor.shared.noteServerUnreachable() }
    }

    /// Throws `HTTPError.http` with the body for a non-2xx. A status in
    /// `quietStatuses` is expected (an existence probe's 404), so it's logged
    /// at debug level and traced as `quiet`, never as an error.
    private func ensureSuccess(_ data: Data, _ response: HTTPURLResponse, method: String, quietStatuses: Set<Int> = []) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        let isQuiet = quietStatuses.contains(response.statusCode)
        if isQuiet {
            Self.logger.debug("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
        } else {
            Self.logger.error("HTTP \(response.statusCode, privacy: .public) \(method, privacy: .public)")
        }
        #if os(iOS) || os(tvOS)
        // The only essential line for a real HTTP failure (the per-response
        // line is verbose), so it stands on its own. The URL goes through the
        // path template, which drops the host and query.
        DiagTrace.log(
            isQuiet ? .verbose : .essential,
            level: isQuiet ? .debug : .error,
            category: .network,
            tag: "HTTP",
            message: isQuiet ? "expected status" : "http error",
            attrs: [
                "method": .string(method),
                "path": .string(HTTPDiagnosticsPath.attribute(for: response.url)),
                "status": .int(response.statusCode),
                "outcome": .string(isQuiet ? HTTPDiagnosticsOutcome.quiet : HTTPDiagnosticsOutcome.httpError),
                "error_code": .string(HTTPDiagnosticsErrorCode.http(status: response.statusCode)),
            ]
        )
        #endif
        throw HTTPError.http(statusCode: response.statusCode, body: String(data: data, encoding: .utf8))
    }
}

// MARK: - Silo v2

extension HTTPClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// A v1-shaped request sent to a v2 server: the route and body are
    /// mapped, playback calls carry the installation (and progress its
    /// sequence), catalogue pages keep their window cursor, subscription
    /// syncs and paged lists are walked to the end, conditional edits send
    /// the current `ETag`, and the reply is turned back into the v1 shape.
    /// A non-2xx from any step is returned as it is for the caller to handle.
    private func performSiloV2(
        original request: URLRequest,
        url: URL,
        legacyPath: String,
        timeout: HTTPTimeout,
        dispatchRevision: UInt64,
        reportReachability: Bool,
        transport: Transport
    ) async throws -> (Data, HTTPURLResponse) {
        var mapped = try SiloAPICompatibility.request(request)
        let authority = SiloAPICompatibility.discoveryURL(for: url)!
        if legacyPath.hasPrefix("/api/v1/playback/"), legacyPath != "/api/v1/playback/capability" {
            if let failure = try await addPlaybackInstallation(to: &mapped, legacyPath: legacyPath, authority: authority, transport: transport) {
                return failure
            }
        }
        let windowKey: String?
        switch try await applyCatalogueWindow(to: &mapped, original: request, transport: transport) {
        case .failed(let response): return response
        case .key(let key): windowKey = key
        }
        if legacyPath == "/api/v1/downloads/subscriptions/sync", mapped.httpMethod == "POST" {
            return try await syncSubscriptions(
                original: request, url: url, mapped: mapped, timeout: timeout,
                dispatchRevision: dispatchRevision, reportReachability: reportReachability, transport: transport
            )
        }
        // Collection and download monitor edits carry the validator read for
        // this exact account and profile, so a concurrent edit fails its
        // precondition.
        let isConditionalEdit = (legacyPath.hasPrefix("/api/v1/collections/") || legacyPath.hasPrefix("/api/v1/downloads/subscriptions/"))
            && ["PATCH", "DELETE"].contains(mapped.httpMethod ?? "")
        if isConditionalEdit {
            var read = mapped
            read.httpMethod = "GET"
            read.httpBody = nil
            let (readData, readResponse) = try await transport(read)
            guard (200..<300).contains(readResponse.statusCode) else { return (readData, readResponse) }
            guard let etag = readResponse.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
                throw SiloAPICompatibility.Failure.invalidDiscovery
            }
            mapped.setValue(etag, forHTTPHeaderField: "If-Match")
        }

        var (data, response) = try await transport(mapped)
        guard (200..<300).contains(response.statusCode) else {
            let failure = HTTPError.http(statusCode: response.statusCode, body: String(data: data, encoding: .utf8))
            if failure.serverErrorCode == "installation_changed" { siloPlaybackInstallations[authority] = nil }
            return (data, response)
        }
        if legacyPath == "/api/v1/downloads" || legacyPath == "/api/v1/downloads/subscriptions" || legacyPath.hasSuffix("/manifests") {
            switch try await collectRemainingPages(of: data, mapped: mapped, transport: transport) {
            case .failed(let failure): return failure
            case .data(let collected): data = collected
            }
        }
        if legacyPath.hasPrefix("/api/v1/playback/"), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rememberPlaybackState(from: object, legacyPath: legacyPath, mapped: mapped, authority: authority)
        }
        if let windowKey,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cursor = object["window_cursor"] as? String {
            if siloCatalogWindows.count >= 64 { siloCatalogWindows.removeAll() }
            siloCatalogWindows[windowKey] = cursor
        }
        return (try SiloAPICompatibility.response(data, path: legacyPath, requestURL: mapped.url), response)
    }

    /// Adds the installation (fetched once per server from the playback
    /// capabilities) to a playback write, with the progress sequence, a route
    /// event's ID or a stop's ID. Returns the capability response when it
    /// isn't a 2xx.
    private func addPlaybackInstallation(
        to mapped: inout URLRequest,
        legacyPath: String,
        authority: URL,
        transport: Transport
    ) async throws -> (Data, HTTPURLResponse)? {
        var body = mapped.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let parts = legacyPath.split(separator: "/")
        let pathSessionID: String? = if parts.count >= 5, parts[3] == "sessions" {
            String(parts[4])
        } else if parts.count >= 4, !["start", "route-events", "sessions"].contains(String(parts[3])) {
            String(parts[3])
        } else {
            nil
        }
        let sessionKey = (body["session_id"] as? String ?? pathSessionID).map { authority.absoluteString + "|" + $0 }
        var installation = sessionKey.flatMap { siloPlaybackSessions[$0]?.installation } ?? siloPlaybackInstallations[authority]
        if installation == nil {
            var capability = mapped
            capability.httpMethod = "GET"
            capability.httpBody = nil
            capability.url = URL(string: authority.absoluteString.replacingOccurrences(of: "/system/info", with: "/playback/capabilities"))
            let (capabilityData, capabilityResponse) = try await transport(capability)
            guard (200..<300).contains(capabilityResponse.statusCode) else { return (capabilityData, capabilityResponse) }
            installation = (try JSONSerialization.jsonObject(with: capabilityData) as? [String: Any])?["installation_id"] as? String
            siloPlaybackInstallations[authority] = installation
        }
        guard let installation, !installation.isEmpty else { throw HTTPError.invalidResponse }
        guard mapped.httpMethod != "GET" else { return nil }

        body["installation_id"] = installation
        if legacyPath.hasSuffix("/progress"), let sessionKey {
            let sequence = (siloPlaybackSessions[sessionKey]?.sequence ?? 0) + 1
            siloPlaybackSessions[sessionKey] = (installation, sequence)
            body["sequence"] = sequence
        }
        if legacyPath.hasSuffix("/route-events") { body["event_id"] = UUID().uuidString.lowercased() }
        if mapped.httpMethod == "DELETE" { body["stop_id"] = UUID().uuidString.lowercased() }
        mapped.httpBody = try JSONSerialization.data(withJSONObject: body)
        mapped.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return nil
    }

    private enum CatalogueWindow {
        case key(String?)
        case failed((Data, HTTPURLResponse))
    }

    /// v2 catalogue pages after the first need the window's cursor. The
    /// window is keyed by the query (without paging) and the credentials, so
    /// a refreshed token starts a new window rather than crossing identities;
    /// without a remembered cursor the first page is read to get one.
    private func applyCatalogueWindow(to mapped: inout URLRequest, original: URLRequest, transport: Transport) async throws -> CatalogueWindow {
        guard var components = mapped.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              components.path.hasSuffix("/api/v2/catalog")
        else { return .key(nil) }
        var query = components.queryItems ?? []
        let seek = query.first { $0.name == "seek" }?.value
        components.queryItems = query.filter { !["seek", "cursor", "skip_total"].contains($0.name) }
        let key = [
            components.url?.absoluteString ?? "",
            original.value(forHTTPHeaderField: "Authorization") ?? "",
            original.value(forHTTPHeaderField: "X-Profile-Id") ?? "",
            original.value(forHTTPHeaderField: "X-Profile-Token") ?? "",
        ].joined(separator: "|")
        if seek != nil, !query.contains(where: { $0.name == "cursor" }) {
            var cursor = siloCatalogWindows[key]
            if cursor == nil {
                var first = mapped
                first.url = components.url
                let (data, response) = try await transport(first)
                guard (200..<300).contains(response.statusCode) else { return .failed((data, response)) }
                cursor = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["window_cursor"] as? String
            }
            guard let cursor, !cursor.isEmpty else { throw SiloAPICompatibility.Failure.missingWindow }
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = query
        mapped.url = components.url
        return .key(key)
    }

    /// v1's single subscription sync becomes a sync of every active monitor,
    /// each walked through its pages, answering with the total registered.
    private func syncSubscriptions(
        original request: URLRequest,
        url: URL,
        mapped: URLRequest,
        timeout: HTTPTimeout,
        dispatchRevision: UInt64,
        reportReachability: Bool,
        transport: Transport
    ) async throws -> (Data, HTTPURLResponse) {
        var list = request
        list.httpMethod = "GET"
        list.httpBody = nil
        list.url = URL(string: String(url.absoluteString.dropLast(5)))
        let (listData, listResponse) = try await perform(request: list, timeout: timeout, dispatchRevision: dispatchRevision,
                                                         reportReachability: reportReachability)
        guard (200..<300).contains(listResponse.statusCode) else { return (listData, listResponse) }
        guard let document = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let monitors = document["subscriptions"] as? [[String: Any]]
        else { throw HTTPError.invalidResponse }

        var total = 0
        for monitor in monitors where monitor["active"] as? Bool == true {
            guard let id = monitor["id"] as? String, let etag = monitor["etag"] as? String else { throw HTTPError.invalidResponse }
            var sync = mapped
            sync.setValue("application/json", forHTTPHeaderField: "Content-Type")
            sync.httpBody = try JSONSerialization.data(withJSONObject: ["subscription_id": id, "etag": etag])
            var seen = Set<String>()
            while true {
                let (pageData, pageResponse) = try await transport(sync)
                guard (200..<300).contains(pageResponse.statusCode) else { return (pageData, pageResponse) }
                guard let pageDocument = try JSONSerialization.jsonObject(with: pageData) as? [String: Any],
                      let count = pageDocument["registered"] as? Int
                else { throw HTTPError.invalidResponse }
                total += count
                guard let page = pageDocument["page"] as? [String: Any], page["has_more"] as? Bool == true else { break }
                guard let cursor = page["next_cursor"] as? String,
                      seen.insert(cursor).inserted, seen.count <= 2000,
                      var components = sync.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
                else { throw HTTPError.invalidResponse }
                components.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
                sync.url = components.url
            }
        }
        return (try JSONSerialization.data(withJSONObject: ["registered": total]), listResponse)
    }

    private enum CollectedPages {
        case data(Data)
        case failed((Data, HTTPURLResponse))
    }

    /// Reads every following page of a cursor-paged v2 list (at most 2,000,
    /// with no cursor repeated) and returns the first page with all the items.
    private func collectRemainingPages(of data: Data, mapped: URLRequest, transport: Transport) async throws -> CollectedPages {
        guard var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var items = document["items"] as? [Any]
        else { return .data(data) }
        var seen = Set<String>()
        while let page = document["page"] as? [String: Any], page["has_more"] as? Bool == true {
            try Task.checkCancellation()
            guard let cursor = page["next_cursor"] as? String, !cursor.isEmpty,
                  seen.insert(cursor).inserted, seen.count <= 2000,
                  var components = mapped.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            else { throw SiloAPICompatibility.Failure.missingWindow }
            var query = (components.queryItems ?? []).filter { $0.name != "cursor" }
            query.append(URLQueryItem(name: "cursor", value: cursor))
            components.queryItems = query
            var next = mapped
            next.url = components.url
            let (nextData, nextResponse) = try await transport(next)
            guard (200..<300).contains(nextResponse.statusCode) else { return .failed((nextData, nextResponse)) }
            guard let nextDocument = try JSONSerialization.jsonObject(with: nextData) as? [String: Any],
                  let nextItems = nextDocument["items"] as? [Any]
            else { throw HTTPError.invalidResponse }
            items.append(contentsOf: nextItems)
            document = nextDocument
        }
        document["items"] = items
        return .data(try JSONSerialization.data(withJSONObject: document))
    }

    /// Remembers the installation a capability reply names, and the
    /// installation a new playback session was started with.
    private func rememberPlaybackState(from object: [String: Any], legacyPath: String, mapped: URLRequest, authority: URL) {
        if legacyPath == "/api/v1/playback/capability", let installation = object["installation_id"] as? String {
            siloPlaybackInstallations[authority] = installation
        }
        if let sessionID = object["session_id"] as? String,
           let body = mapped.httpBody.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
           let installation = body["installation_id"] as? String {
            let key = authority.absoluteString + "|" + sessionID
            if siloPlaybackSessions[key] == nil { siloPlaybackSessions[key] = (installation, 0) }
        }
    }
}

// MARK: - Token refresh

extension HTTPClient {
    private enum RefreshKind {
        case ordinary
        case scoped

        var logPrefix: String {
            switch self {
            case .ordinary: "Refresh"
            case .scoped: "Scoped refresh"
            }
        }
    }

    /// Refreshes a captured-identity request's account, joining any flight
    /// already running for it. True when that account now has different
    /// credentials (whoever refreshed them).
    private func refreshScopedTokens(auth: CapturedHTTPRequestAuth, expected: HTTPRequestIdentity, dispatchRevision: UInt64) async -> Bool {
        guard isDispatchOpen(at: dispatchRevision) else { return false }
        guard auth.credentialOwner == .persistentServer(serverId: expected.serverId),
              auth.account.serverId == expected.serverId,
              auth.account.serverURL == ServerRegistry.normalize(url: expected.serverURL),
              let refreshValue = auth.refreshToken, !refreshValue.isEmpty,
              URL(string: auth.serverURL + "/api/v1/auth/refresh") != nil
        else { return false }
        if await scopedCredentialsChanged(since: auth, expected: expected) { return true }
        guard isDispatchOpen(at: dispatchRevision) else { return false }

        await runRefreshFlight(for: auth.account, joining: .scoped) {
            [tokenStore, session, decoder, encoder, apiDiscovery, refusedRefreshRetryDelays] in
            await Self.performScopedRefresh(
                auth: auth, tokenStore: tokenStore, session: session, decoder: decoder, encoder: encoder,
                apiDiscovery: apiDiscovery, retryDelays: refusedRefreshRetryDelays
            )
        }
        return await scopedCredentialsChanged(since: auth, expected: expected)
    }

    private func scopedCredentialsChanged(since auth: CapturedHTTPRequestAuth, expected: HTTPRequestIdentity) async -> Bool {
        guard let current = try? await tokenStore.captureRequestAuth(expected: expected),
              current.account == auth.account,
              current.credentialOwner == auth.credentialOwner,
              current.accessToken != nil
        else { return false }
        return current.accessToken != auth.accessToken || current.refreshToken != auth.refreshToken
    }

    /// Refreshes at most once per wave of 401s for an account. If the stored
    /// token already differs from the one this request sent, another request
    /// refreshed it and that's used; otherwise this joins or starts the
    /// account's flight. Each check reads the account, profile and token
    /// together, so a token another flight rotated is only used while the
    /// rest of this request's identity is still current.
    private func refreshTokens(expected: CapturedOrdinaryRequestAuth, dispatchRevision: UInt64) async -> CapturedOrdinaryRequestAuth? {
        guard isDispatchOpen(at: dispatchRevision),
              let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: expected)
        else { return nil }
        if current.accessToken != expected.accessToken, current.accessToken != nil { return current }
        guard isDispatchOpen(at: dispatchRevision) else { return nil }

        await runRefreshFlight(for: expected.account, joining: .ordinary) {
            [tokenStore, session, decoder, encoder, apiDiscovery, refusedRefreshRetryDelays] in
            await Self.performRefresh(
                expected: expected.account, tokenStore: tokenStore, session: session, decoder: decoder,
                encoder: encoder, apiDiscovery: apiDiscovery, retryDelays: refusedRefreshRetryDelays
            )
        }
        return await refreshedOrdinaryAuth(since: expected)
    }

    /// The current credentials when they still match the request's identity
    /// and carry a different (non-nil) access token.
    private func refreshedOrdinaryAuth(since expected: CapturedOrdinaryRequestAuth) async -> CapturedOrdinaryRequestAuth? {
        guard let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: expected),
              current.accessToken != expected.accessToken,
              current.accessToken != nil
        else { return nil }
        return current
    }

    /// Joins the account's running refresh, or starts one and clears it when
    /// it finishes, so the next wave of 401s starts afresh.
    private func runRefreshFlight(
        for key: RefreshAccountIdentity,
        joining kind: RefreshFlightJoinKind,
        start: @escaping @Sendable () async -> Bool
    ) async {
        if let existing = inFlightRefreshes[key] {
            refreshFlightJoinObserver?(kind)
            _ = await existing.task.value
            return
        }
        let task = Task<Bool, Never> { await start() }
        let flightID = UUID()
        inFlightRefreshes[key] = RefreshFlight(id: flightID, task: task)
        _ = await task.value
        if inFlightRefreshes[key]?.id == flightID { inFlightRefreshes.removeValue(forKey: key) }
    }

    private static func performScopedRefresh(
        auth: CapturedHTTPRequestAuth,
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        apiDiscovery: SiloAPIDiscovery,
        retryDelays: [Duration]
    ) async -> Bool {
        guard let refreshValue = auth.refreshToken,
              let url = URL(string: auth.serverURL + "/api/v1/auth/refresh")
        else { return false }
        let captured = CapturedRefreshCredential(account: auth.account, refreshToken: refreshValue, owner: auth.credentialOwner)
        guard await tokenStore.captureRefreshCredential(expected: auth.account) == captured else { return false }
        return await sendRefresh(
            captured, url: url, kind: .scoped, tokenStore: tokenStore, session: session,
            decoder: decoder, encoder: encoder, apiDiscovery: apiDiscovery, retryDelays: retryDelays
        )
    }

    private static func performRefresh(
        expected: RefreshAccountIdentity,
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        apiDiscovery: SiloAPIDiscovery,
        retryDelays: [Duration]
    ) async -> Bool {
        guard let captured = await tokenStore.captureRefreshCredential(expected: expected) else {
            logger.error("Refresh skipped: no refresh token stored")
            return false
        }
        guard let url = URL(string: expected.serverURL + "/api/v1/auth/refresh") else {
            logger.error("Refresh skipped: invalid server URL")
            return false
        }
        return await sendRefresh(
            captured, url: url, kind: .ordinary, tokenStore: tokenStore, session: session,
            decoder: decoder, encoder: encoder, apiDiscovery: apiDiscovery, retryDelays: retryDelays
        )
    }

    /// Sends the refresh and saves the new tokens against the captured
    /// credential. A refusal is sent again after each retry delay while the
    /// same token is still stored, then clears the session and posts its
    /// expiry (once, and only while it still describes the active
    /// credentials). Anything retryable (a 5xx, 429 or network failure)
    /// keeps the credentials. A response that arrives after the flight was
    /// cancelled (by a switch) is dropped rather than saved into what may be
    /// another server's slot.
    private static func sendRefresh(
        _ captured: CapturedRefreshCredential,
        url: URL,
        kind: RefreshKind,
        tokenStore: TokenStore,
        session: URLSession,
        decoder: JSONDecoder,
        encoder: JSONEncoder,
        apiDiscovery: SiloAPIDiscovery,
        retryDelays: [Duration]
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let prefix = kind.logPrefix
        do {
            request.httpBody = try encoder.encode(RefreshRequest(refreshToken: captured.refreshToken))
        } catch {
            switch kind {
            case .ordinary:
                logger.error("Refresh encode failed: \(String(describing: error), privacy: .public)")
            case .scoped:
                logger.error("Scoped refresh threw: \(String(describing: error), privacy: .public)")
            }
            return false
        }

        do {
            var retriesSent = 0
            while true {
                let (data, response) = try await performRefreshTransport(request: request, session: session, apiDiscovery: apiDiscovery)
                if Task.isCancelled {
                    if kind == .ordinary { logger.info("Refresh cancelled post-response; skipping token save") }
                    return false
                }
                guard let http = response as? HTTPURLResponse else {
                    logger.error("\(prefix, privacy: .public): non-HTTP response")
                    return false
                }
                // The refresh doesn't go through `perform`, so it reports
                // reachability itself.
                await MainActor.run { ConnectionMonitor.shared.noteServerResponded() }
                if (200..<300).contains(http.statusCode) {
                    let tokens = try decoder.decode(RefreshResponse.self, from: data)
                    return await tokenStore.saveRefreshedTokens(tokens.accessToken, tokens.refreshToken, replacing: captured)
                }

                let body = String(data: data, encoding: .utf8) ?? ""
                logger.error("\(prefix, privacy: .public) failed: status=\(http.statusCode, privacy: .public) body=\(body, privacy: .private)")
                switch refreshFailureDecision(statusCode: http.statusCode, retriesSent: retriesSent, retryDelays: retryDelays) {
                case .retry(let delay):
                    guard await waitToRetryRefusedRefresh(
                        captured, after: delay, request: request, status: http.statusCode,
                        nextAttempt: retriesSent + 2, tokenStore: tokenStore
                    ) else { return false }
                    retriesSent += 1
                case .preserveCredentials:
                    return false
                case .invalidate:
                    await expireSession(captured, tokenStore: tokenStore)
                    return false
                }
            }
        } catch {
            await noteServerUnreachable(for: error)
            logger.error("\(prefix, privacy: .public) threw: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Clears the refused session and tells the app (which routes to the
    /// account selector, keeping the saved server), unless the flight was
    /// cancelled or the credentials have moved on.
    private static func expireSession(_ captured: CapturedRefreshCredential, tokenStore: TokenStore) async {
        guard let disposition = await tokenStore.invalidateRejectedRefresh(captured) else { return }
        let event = SessionExpiryEvent(account: captured.account, disposition: disposition)
        guard !Task.isCancelled,
              await tokenStore.shouldConsumeSessionExpiryEvent(event),
              !Task.isCancelled
        else { return }
        await MainActor.run {
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .vividSessionExpired, object: event)
        }
    }

    /// Android's refresh-failure rule: a client or auth refusal is terminal;
    /// rate limits, gateway failures and server faults keep the credentials.
    static func shouldInvalidateSessionAfterRefreshFailure(_ statusCode: Int) -> Bool {
        statusCode == 400 || statusCode == 401 || statusCode == 403
    }

    /// What a failed refresh means for the stored credentials.
    enum RefreshFailureDecision: Equatable {
        /// Not a refusal: keep the credentials for the next wave of 401s.
        case preserveCredentials
        /// A refusal that may not last: wait, then send the same token again.
        case retry(after: Duration)
        /// The refusal outlasted every retry: drop the session.
        case invalidate
    }

    /// Three seconds after the first refusal, then six after the second. A
    /// Silo server whose database was briefly down refused a good refresh
    /// token with 401 for about six seconds during crash recovery. The nine
    /// seconds also leave room for the round trips inside the managed stream
    /// reader's 15-second refresh wait.
    static let defaultRefusedRefreshRetryDelays: [Duration] = [.seconds(3), .seconds(6)]

    /// A terminal refusal only ends the session once the same token has been
    /// refused again after each of `retryDelays`, since one refusal can be
    /// the server failing to look the token up. Anything retryable keeps the
    /// credentials straight away, including a 5xx or 429 on a retry.
    /// `retriesSent` is 0 for the first refusal.
    static func refreshFailureDecision(statusCode: Int, retriesSent: Int, retryDelays: [Duration]) -> RefreshFailureDecision {
        guard shouldInvalidateSessionAfterRefreshFailure(statusCode) else { return .preserveCredentials }
        guard retryDelays.indices.contains(retriesSent) else { return .invalidate }
        return .retry(after: retryDelays[retriesSent])
    }

    /// Waits one delay before a refused refresh is sent again, inside the
    /// account's flight, so every 401 meanwhile joins this refresh. False,
    /// leaving the credentials alone, when the flight is cancelled or the
    /// stored refresh token is no longer the one refused (checked before and
    /// after the wait).
    private static func waitToRetryRefusedRefresh(
        _ captured: CapturedRefreshCredential,
        after delay: Duration,
        request: URLRequest,
        status: Int,
        nextAttempt: Int,
        tokenStore: TokenStore
    ) async -> Bool {
        guard !Task.isCancelled,
              await tokenStore.captureRefreshCredential(expected: captured.account) == captured
        else { return false }
        logger.notice(
            "Refresh refused: status=\(status, privacy: .public); retrying in \(String(describing: delay), privacy: .public) (attempt \(nextAttempt, privacy: .public))"
        )
        #if os(iOS) || os(tvOS)
        DiagTrace.log(
            .essential,
            level: .warning,
            category: .network,
            tag: "Auth",
            message: "refresh refusal retry scheduled",
            attrs: [
                "method": .string(request.httpMethod ?? "POST"),
                "path": .string(HTTPDiagnosticsPath.attribute(for: request.url)),
                "status": .int(status),
                "attempt": .int(nextAttempt),
            ]
        )
        #endif
        do {
            try await Task.sleep(for: delay)
        } catch {
            return false
        }
        guard !Task.isCancelled else { return false }
        return await tokenStore.captureRefreshCredential(expected: captured.account) == captured
    }

    /// One refresh round trip, classified like an ordinary request. It only
    /// observes: errors are rethrown and any response is returned, so the
    /// callers' rules are unchanged. The refresh token is in the request
    /// body and new tokens in a 2xx body, so neither body nor the headers are
    /// ever read here; keep the attribute lists literal.
    private static func performRefreshTransport(
        request: URLRequest,
        session: URLSession,
        apiDiscovery: SiloAPIDiscovery
    ) async throws -> (Data, URLResponse) {
        var request = request
        if let url = request.url, try await apiDiscovery.usesV2(for: url, session: session) {
            request = try SiloAPICompatibility.request(request)
        }
        #if os(iOS) || os(tvOS)
        let method = request.httpMethod ?? "POST"
        let path = HTTPDiagnosticsPath.attribute(for: request.url)
        let startedAt = ContinuousClock.now
        #endif
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            #if os(iOS) || os(tvOS)
            let isCancellation = (error as? URLError)?.code == .cancelled
            DiagTrace.log(
                isCancellation ? .verbose : .essential,
                level: isCancellation ? .debug : .error,
                category: .network,
                tag: "Auth",
                message: isCancellation ? "refresh cancelled" : "refresh transport failure",
                attrs: [
                    "method": .string(method),
                    "path": .string(path),
                    "duration_ms": .int(elapsedMilliseconds(since: startedAt)),
                    "outcome": .string(isCancellation ? HTTPDiagnosticsOutcome.cancelled : HTTPDiagnosticsOutcome.transportError),
                    "error_code": .string(HTTPDiagnosticsErrorCode.classify(transport: error)),
                ]
            )
            #endif
            throw error
        }
        #if os(iOS) || os(tvOS)
        // Unlike an ordinary response, nothing downstream judges the status,
        // so this line carries the verdict: a refusal is essential, success
        // verbose.
        let status = (response as? HTTPURLResponse)?.statusCode
        let isSuccess = status.map { (200..<300).contains($0) } ?? false
        var attrs: [String: DiagLogAttributeValue] = [
            "method": .string(method),
            "path": .string(path),
            "duration_ms": .int(elapsedMilliseconds(since: startedAt)),
        ]
        if let status {
            attrs["status"] = .int(status)
            attrs["outcome"] = .string(isSuccess ? HTTPDiagnosticsOutcome.success : HTTPDiagnosticsOutcome.httpError)
            if !isSuccess { attrs["error_code"] = .string(HTTPDiagnosticsErrorCode.http(status: status)) }
        } else {
            attrs["outcome"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
            attrs["error_code"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
        }
        DiagTrace.log(
            isSuccess ? .verbose : .essential,
            level: isSuccess ? .debug : .error,
            category: .network,
            tag: "Auth",
            message: status == nil ? "refresh non-http response" : isSuccess ? "refresh succeeded" : "refresh rejected",
            attrs: attrs
        )
        #endif
        return (data, response)
    }
}

// MARK: - Diagnostics

extension HTTPClient {
    #if os(iOS) || os(tvOS)
    /// The lines for one request, which only ever see its method, templated
    /// path and start time.
    private struct RequestTrace {
        let method: String
        let path: String
        let startedAt: ContinuousClock.Instant

        private func attrs(includesDuration: Bool = true) -> [String: DiagLogAttributeValue] {
            var attrs: [String: DiagLogAttributeValue] = ["method": .string(method), "path": .string(path)]
            if includesDuration { attrs["duration_ms"] = .int(HTTPClient.elapsedMilliseconds(since: startedAt)) }
            return attrs
        }

        /// Essential: to the user this is only "it didn't load", and it's the
        /// sign of the switch races the gate exists for.
        func identityChanged(_ message: String, includesDuration: Bool) {
            var attrs = attrs(includesDuration: includesDuration)
            attrs["outcome"] = .string(HTTPDiagnosticsOutcome.identityChanged)
            attrs["error_code"] = .string(HTTPDiagnosticsOutcome.identityChanged)
            DiagTrace.log(.essential, level: .warning, category: .network, tag: "HTTP", message: message, attrs: attrs)
        }

        /// A cancellation is ordinary and frequent, so verbose; a real
        /// transport failure is the evidence a connection report needs.
        func transportFailure(_ error: Error) {
            let isCancellation = (error as? URLError)?.code == .cancelled
            var attrs = attrs()
            attrs["outcome"] = .string(isCancellation ? HTTPDiagnosticsOutcome.cancelled : HTTPDiagnosticsOutcome.transportError)
            attrs["error_code"] = .string(HTTPDiagnosticsErrorCode.classify(transport: error))
            DiagTrace.log(
                isCancellation ? .verbose : .essential,
                level: isCancellation ? .debug : .error,
                category: .network,
                tag: "HTTP",
                message: isCancellation ? "request cancelled" : "transport failure",
                attrs: attrs
            )
        }

        func nonHTTPResponse() {
            var attrs = attrs()
            attrs["outcome"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
            attrs["error_code"] = .string(HTTPDiagnosticsOutcome.invalidResponse)
            DiagTrace.log(.essential, level: .error, category: .network, tag: "HTTP", message: "non-http response", attrs: attrs)
        }

        /// Verbose: browsing issues hundreds of good requests a minute,
        /// which would push everything else out of the report's ring. Only a
        /// 2xx gets an outcome; whether another status is a fault is for
        /// `ensureSuccess` to say.
        func responseReceived(status: Int) {
            var attrs = attrs()
            attrs["status"] = .int(status)
            if (200..<300).contains(status) { attrs["outcome"] = .string(HTTPDiagnosticsOutcome.success) }
            DiagTrace.log(.verbose, level: .debug, category: .network, tag: "HTTP", message: "response received", attrs: attrs)
        }
    }

    /// Elapsed milliseconds on the monotonic clock, clamped so a report
    /// never shows a negative or overflowing duration.
    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        let milliseconds = seconds.multipliedReportingOverflow(by: 1_000)
        guard !milliseconds.overflow else { return Int(Int32.max) }
        let total = milliseconds.partialValue.addingReportingOverflow(attoseconds / 1_000_000_000_000_000)
        guard !total.overflow else { return Int(Int32.max) }
        return Int(max(0, total.partialValue))
    }
    #endif

    /// The redacted outcome of a 401 retry.
    private func logRefreshRetry(method: String, path: String, retried: Bool) {
        #if os(iOS) || os(tvOS)
        var attrs: [String: DiagLogAttributeValue] = [
            "method": .string(method),
            "path": .string(HTTPDiagnosticsPath.attribute(forRawPath: path)),
            "status": .int(401),
            "outcome": .string(retried ? HTTPDiagnosticsOutcome.retried : HTTPDiagnosticsOutcome.notRetried),
        ]
        if retried { attrs["attempt"] = .int(2) }
        DiagTrace.log(
            .essential,
            level: retried ? .info : .warning,
            category: .network,
            tag: "Auth",
            message: retried ? "401 retry" : "401 not retried",
            attrs: attrs
        )
        #endif
    }

    /// Logs a decoding failure: the endpoint, the `DecodingError` case with
    /// the path where it failed, and the start of the body at private level,
    /// for a developer's own Console.
    private static func logDecodingFailure(type: String, path: String, error: Error, data: Data) {
        let bodyPreview = String(data: data.prefix(1024), encoding: .utf8) ?? "<non-utf8 body>"
        var detail = "decode(\(type)) failed at \(path): "
        if let decodingError = error as? DecodingError {
            // The same path as the diagnostics line, so the two always agree.
            let failurePath = codingPathString(failureCodingPath(decodingError))
            switch decodingError {
            case .keyNotFound(let key, let context):
                detail += "keyNotFound key=\(key.stringValue) path=\(failurePath) — \(context.debugDescription)"
            case .typeMismatch(_, let context):
                detail += "typeMismatch path=\(failurePath) — \(context.debugDescription)"
            case .valueNotFound(_, let context):
                detail += "valueNotFound path=\(failurePath) — \(context.debugDescription)"
            case .dataCorrupted(let context):
                detail += "dataCorrupted path=\(failurePath) — \(context.debugDescription)"
            @unknown default:
                detail += String(describing: decodingError)
            }
        } else {
            detail += String(describing: error)
        }
        logger.error("\(detail, privacy: .public) body=\(bodyPreview, privacy: .private)")
        #if os(iOS) || os(tvOS)
        recordDecodingFailureDiagnostic(type: type, path: path, error: error)
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// A decode failure for reports, by shape only: the type, the route, the
    /// `DecodingError` case and where in the payload. A model mismatch is
    /// rare and breaks a screen, so it's essential. The response body isn't
    /// a parameter, so it can never be logged from here.
    private static func recordDecodingFailureDiagnostic(type: String, path: String, error: Error) {
        let codingPath = (error as? DecodingError).map(failureCodingPath(_:)) ?? []
        DiagTrace.log(
            .essential,
            level: .error,
            category: .network,
            tag: "Decode",
            message: """
                decode failed \
                type=\(HTTPDecodingDiagnostics.typeName(type)) \
                coding path \(HTTPDecodingDiagnostics.codingPath(codingPath))
                """,
            attrs: [
                "path": .string(HTTPDiagnosticsPath.attribute(forRawPath: path)),
                "outcome": .string(HTTPDiagnosticsOutcome.decodeFailed),
                "error_code": .string(HTTPDiagnosticsErrorCode.classify(decoding: error)),
            ]
        )
    }
    #endif

    /// Where a `DecodingError` actually failed. For `keyNotFound` the missing
    /// key comes separately from the context, whose path only names the
    /// container, so it's added back: without it a missing field reads as
    /// its parent, losing the one name that says what to fix.
    static func failureCodingPath(_ error: DecodingError) -> [CodingKey] {
        switch error {
        case .keyNotFound(let key, let context):
            context.codingPath + [key]
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath
        @unknown default:
            []
        }
    }

    private static func codingPathString(_ path: [CodingKey]) -> String {
        path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
    }
}

/// Lets a generic `send` return for an empty body.
private struct EmptyResponse: Decodable {
    static let empty = EmptyResponse()
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Wraps an `any Encodable` body for `JSONEncoder`, which needs a concrete type.
private struct AnyEncodable: Encodable {
    private let wrapped: any Encodable

    init(_ wrapped: any Encodable) {
        self.wrapped = wrapped
    }

    func encode(to encoder: Encoder) throws {
        try wrapped.encode(to: encoder)
    }
}
