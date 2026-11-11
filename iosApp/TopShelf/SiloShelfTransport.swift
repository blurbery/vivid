import Foundation

/// A Silo API route, kept in its v1 form. `SiloAPICompatibility` rewrites it
/// for a v2 server.
struct SiloRoute: Equatable, Sendable {
    /// The v1 path as the compatibility layer names it.
    let path: String
    /// The same path, escaped for a URL.
    private let encodedPath: String

    static let imageCapability = SiloRoute(fixed: "images/capability")
    static let homeSections = SiloRoute(fixed: "home/sections")
    static let refresh = SiloRoute(fixed: "auth/refresh")

    static func item(_ id: String) throws -> SiloRoute {
        try SiloRoute(before: "catalog/items/", id: id, after: "")
    }

    private init(fixed tail: String) {
        path = "/api/v1/" + tail
        encodedPath = path
    }

    /// IDs come from the server's replies, so one is escaped to stay a single
    /// path segment and can't point the request at another route.
    private init(before: String, id: String, after: String) throws {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard !id.isEmpty, id != ".", id != "..",
              let segment = id.addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw ShelfFailure.badResponse }
        path = "/api/v1/" + before + id + after
        encodedPath = "/api/v1/" + before + segment + after
    }

    /// This route under `server`, which may itself sit under a path. The
    /// query is sorted by name so the same request always has the same URL.
    func url(server: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: server),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false
        else { throw ShelfFailure.badAddress }
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + encodedPath
        components.fragment = nil
        components.queryItems = query.isEmpty
            ? nil
            : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw ShelfFailure.badAddress }
        return url
    }
}

/// Sends one request to a Silo server, whichever API version it speaks.
/// It knows nothing about tokens: callers add their own headers.
struct SiloTransport: Sendable {
    struct Reply: Sendable {
        let status: Int
        /// Already in its v1 shape when the request succeeded.
        let body: Data
        /// Where the request went, for resolving relative artwork paths.
        let url: URL

        var succeeded: Bool { (200..<300).contains(status) }
    }

    /// Short-lived and stateless like the native client's session: no
    /// cookies and no cache.
    static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: SameServerRedirectPolicy(), delegateQueue: nil)

    let server: String
    let session: URLSession
    /// Asked just before each request leaves. False means the viewer may no
    /// longer be shown, so nothing more is sent on their behalf.
    let stillAllowed: @Sendable () -> Bool

    /// - Parameter mapsReply: false for a reply that must be read as sent,
    ///   without the v2 to v1 reshaping.
    func send(
        _ route: SiloRoute,
        query: [String: String] = [:],
        mapsReply: Bool = true,
        prepare: (inout URLRequest) -> Void
    ) async throws -> Reply {
        let url = try route.url(server: server, query: query)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        prepare(&request)

        let usesV2 = try await SiloAPIDiscovery.shared.usesV2(for: url, session: session)
        if usesV2 { request = try SiloAPICompatibility.request(request) }

        guard stillAllowed() else { throw ShelfFailure.viewerChanged }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ShelfFailure.badResponse }

        var body = data
        if usesV2, mapsReply, (200..<300).contains(http.statusCode) {
            body = try SiloAPICompatibility.response(data, path: route.path, requestURL: request.url)
        }
        return Reply(status: http.statusCode, body: body, url: request.url ?? url)
    }
}

/// The access token for one run. When the server turns the stored one down,
/// a single refresh is shared by every request that needs it.
///
/// The new token lives only in this actor. Silo refresh tokens stay valid
/// after use, so the pair the app has stored keeps working and the extension
/// never needs to write a credential anywhere.
actor SiloAccessTokens {
    private(set) var current: String
    private let renew: @Sendable () async throws -> String
    /// Kept once started, finished or not, so a run refreshes at most once
    /// and a failed refresh gives every caller the same answer.
    private var refresh: Task<String, Error>?

    init(current: String, renew: @escaping @Sendable () async throws -> String) {
        self.current = current
        self.renew = renew
    }

    /// A token to retry with after the server answered 401 to `rejected`, or
    /// nil when there's nothing newer to try. Throws what the refresh threw.
    func replacement(for rejected: String) async throws -> String? {
        // Another request already brought a newer token back.
        if rejected != current { return current }
        if let refresh {
            let fresh = try await refresh.value
            return fresh == rejected ? nil : fresh
        }
        // Unstructured on purpose: several requests wait on it, so one of
        // them being cancelled mustn't take it away from the others.
        let task = Task { [renew] in try await renew() }
        refresh = task
        let fresh = try await task.value
        current = fresh
        return fresh
    }
}

/// Follows a redirect only when it stays on the same server, so the bearer
/// and profile tokens never travel to another host or down to plain http.
private final class SameServerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.staysOnServer(from: response.url, to: request.url) ? request : nil)
    }

    static func staysOnServer(from: URL?, to: URL?) -> Bool {
        guard let from, let to,
              let host = from.host?.lowercased(), host == to.host?.lowercased(),
              let fromScheme = from.scheme?.lowercased(), let toScheme = to.scheme?.lowercased()
        else { return false }
        if fromScheme == toScheme { return from.port == to.port }
        // The one change of scheme allowed is the usual upgrade to https.
        return fromScheme == "http" && toScheme == "https" && from.port == nil && to.port == nil
    }
}
