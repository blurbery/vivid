import Foundation

// The Jellyfin connection: errors, the signed transport (with Jellyfin's
// older per-user routes as a fallback), sign-in (username and password or
// Quick Connect), the people ID store and the library directory. The adapter
// that turns Jellyfin's API into Vivid's is in `JellyfinProvider+Items.swift`
// and `JellyfinProvider+Routes.swift`. Nothing here is shared with Emby.

enum JellyfinError: LocalizedError {
    case invalidResponse, invalidURL, unsupportedFeature, signInRequired, playbackUnavailable
    case quickConnectDisabled, quickConnectExpired, quickConnectUnavailable
    case filterRequestFailed(step: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .filterRequestFailed(let step, let status): filterRequestFailureText(step: step, status: status)
        case .invalidResponse: String(localized: "Jellyfin returned an unexpected response.")
        case .invalidURL: String(localized: "The Jellyfin server returned an invalid address.")
        case .unsupportedFeature: String(localized: "This feature is not available with Jellyfin yet.")
        case .signInRequired: String(localized: "Please sign in to Jellyfin again.")
        case .playbackUnavailable: String(localized: "Jellyfin could not provide a playable media source.")
        case .quickConnectDisabled: String(localized: "Quick Connect isn’t turned on for this Jellyfin server.")
        case .quickConnectExpired: String(localized: "This Quick Connect code has expired.")
        case .quickConnectUnavailable: String(localized: "This server doesn’t offer Quick Connect. Check that the address is your Jellyfin server.")
        }
    }
}

/// Refuses every redirect, so a token never follows one to another host.
final class JellyfinRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

// MARK: - People

/// Person route IDs mapped to Jellyfin's native IDs, one bounded dictionary
/// per server and user (stored under `<partition>.people`) instead of a
/// defaults key per person. Older per-person keys (`<partition>.person.<id>`)
/// move in on first use so existing links keep working.
final class JellyfinPeopleStore: @unchecked Sendable {
    static let shared = JellyfinPeopleStore()

    private let limit: Int
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var partitions: [String: [String: String]] = [:]
    /// Route IDs remembered this launch, oldest first.
    private var order: [String: [String]] = [:]
    private var pending = Set<String>()

    init(defaults: UserDefaults = .standard, limit: Int = 4_000) {
        self.defaults = defaults
        self.limit = limit
    }

    static func key(_ partition: String) -> String { partition + ".people" }

    func remember(routeID: String, nativeID: String, partition: String) {
        lock.lock()
        defer { lock.unlock() }
        var people = load(partition)
        guard people[routeID] != nativeID else { return }
        people[routeID] = nativeID
        var recent = order[partition, default: []]
        recent.removeAll { $0 == routeID }
        recent.append(routeID)
        if people.count > limit {
            // Entries loaded from disk count as oldest, so the cap drops those first.
            let recentSet = Set(recent)
            var older = people.keys.filter { !recentSet.contains($0) }
            while people.count > limit {
                people[older.popLast() ?? recent.removeFirst()] = nil
            }
        }
        partitions[partition] = people
        order[partition] = recent
        // A detail page maps its whole cast at once, so save once afterwards.
        guard pending.insert(partition).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in save(partition) }
    }

    func nativeID(routeID: String, partition: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load(partition)[routeID]
    }

    func save(_ partition: String) {
        lock.lock()
        pending.remove(partition)
        let people = partitions[partition]
        lock.unlock()
        if let people { defaults.set(people, forKey: Self.key(partition)) }
    }

    /// Called with the lock held.
    private func load(_ partition: String) -> [String: String] {
        if let people = partitions[partition] { return people }
        var people = defaults.dictionary(forKey: Self.key(partition)) as? [String: String] ?? [:]
        let legacyPrefix = partition + ".person."
        let legacy = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(legacyPrefix) }
        if !legacy.isEmpty {
            for (key, value) in legacy {
                if let native = value as? String { people[String(key.dropFirst(legacyPrefix.count))] = native }
            }
            // Save the merged map before removing anything it replaces.
            defaults.set(people, forKey: Self.key(partition))
            for key in legacy.keys { defaults.removeObject(forKey: key) }
        }
        partitions[partition] = people
        return people
    }
}

/// Servers seen to need Jellyfin's pre-12 user routes during this launch.
/// In memory only, so each launch checks again once.
final class JellyfinLegacyRoutes: @unchecked Sendable {
    static let shared = JellyfinLegacyRoutes()

    private let lock = NSLock()
    private var servers = Set<String>()

    func prefersLegacy(_ server: String) -> Bool {
        lock.withLock { servers.contains(server) }
    }

    func remember(_ server: String) {
        lock.withLock { _ = servers.insert(server) }
    }

    func forget(_ server: String) {
        lock.withLock { _ = servers.remove(server) }
    }

    func reset() {
        lock.withLock { servers.removeAll() }
    }
}

// MARK: - Connection

/// One Jellyfin account's transport: its address, token and user, plus the
/// captured sign-in it belongs to. Every request checks that sign-in is still
/// the active one before and after it goes out.
struct JellyfinConnection: Sendable {
    let serverURL: String
    let token: String?
    let userID: String?
    let identity: CapturedOrdinaryRequestAuth?
    var sessionOverride: URLSession? = nil

    /// The active Jellyfin account. Throws `signInRequired` without one.
    static func current() async throws -> Self {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              MediaServerProvider.forServerID(auth.account.serverId) == .jellyfin,
              let token = auth.accessToken, !token.isEmpty
        else { throw JellyfinError.signInRequired }
        guard let userID = await TokenStore.shared.nativeUserID(expected: auth.account), !userID.isEmpty else {
            throw JellyfinError.signInRequired
        }
        return Self(serverURL: auth.account.serverURL, token: token, userID: userID, identity: auth)
    }

    /// The active Jellyfin account, only when it's still the sign-in
    /// `expected` captured (same account, profile and profile proof).
    static func current(matching expected: CapturedOrdinaryRequestAuth) async throws -> Self {
        let connection = try await current()
        guard connection.identity?.account == expected.account,
              connection.identity?.profileId == expected.profileId,
              connection.identity?.profileToken == expected.profileToken
        else { throw HTTPError.requestIdentityChanged }
        return connection
    }

    /// Throws when the task was cancelled or the captured sign-in is no
    /// longer the active one.
    func validate() async throws {
        try Task.checkCancellation()
        if let identity,
           await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: identity) != identity {
            throw HTTPError.requestIdentityChanged
        }
    }

    /// `path` under the server address, with the query sorted by name. The
    /// address must be plain http or https with a host and nothing else; the
    /// path must be absolute and can't climb out with `..`.
    static func url(serverURL: String, path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: serverURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("..")
        else { throw JellyfinError.invalidURL }
        let base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (base.isEmpty ? "" : "/" + base) + path
        components.queryItems = query.isEmpty
            ? nil
            : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw JellyfinError.invalidURL }
        return url
    }

    /// The ID itself when it's only ASCII letters, digits, `-` and `_`, so it
    /// can go into a path as is.
    static func id(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy(isIDByte) else { throw JellyfinError.invalidResponse }
        return value
    }

    private static func isIDByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "-"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    /// This installation's Jellyfin device ID, made once and kept.
    static let deviceID: String = {
        let key = "vivid.jellyfin.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    var headers: [String: String] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        var authorization = "MediaBrowser Client=\"Vivid\", Device=\"Apple\", DeviceId=\"\(Self.deviceID)\", Version=\"\(version)\""
        if let token { authorization += ", Token=\"\(token)\"" }
        return ["Authorization": authorization]
    }

    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: JellyfinRedirectPolicy(), delegateQueue: nil)

    // MARK: Requests

    /// The decoded JSON reply; an empty body reads as an empty object.
    func request(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any {
        let data = try await data(method, path, query: query, body: body)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// Jellyfin 12 moved user-scoped routes out of `/Users/{id}`. Older
    /// releases are only asked at the old route when the new one is missing.
    func legacyPath(for path: String) -> String? {
        guard let userID else { return nil }
        switch path {
        case "/UserViews": return "/Users/\(userID)/Views"
        case "/UserItems/Resume": return "/Users/\(userID)/Items/Resume"
        case "/Items/Latest": return "/Users/\(userID)/Items/Latest"
        default: break
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "Items", (try? Self.id(parts[1])) != nil, !["Filters", "Filters2", "Latest"].contains(parts[1]) {
            return "/Users/\(userID)/Items/\(parts[1])"
        }
        if ["UserFavoriteItems", "UserPlayedItems"].contains(parts[0]) {
            return "/Users/\(userID)/\(parts[0].dropFirst(4))/\(parts[1])"
        }
        return nil
    }

    /// The raw reply, trying the older route where needed. A server already
    /// seen to need the older routes goes straight to them; if that route has
    /// since gone (an in-place upgrade), the current route is tried and the
    /// preference forgotten. Otherwise a 404 on the current route tries the
    /// older one, and only a successful older route marks an older server: an
    /// ordinary missing item 404s on both.
    func data(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Data {
        try await validate()
        let legacy = legacyPath(for: path)
        if let legacy, JellyfinLegacyRoutes.shared.prefersLegacy(serverURL) {
            let response = try await send(method, legacy, query: query, body: body)
            guard response.1.statusCode == 404 else { return try await handle(response) }
            JellyfinLegacyRoutes.shared.forget(serverURL)
            return try await handle(try await send(method, path, query: query, body: body))
        }
        let response = try await send(method, path, query: query, body: body)
        guard response.1.statusCode == 404, let legacy else { return try await handle(response) }
        let fallback = try await send(method, legacy, query: query, body: body)
        if (200..<300).contains(fallback.1.statusCode) { JellyfinLegacyRoutes.shared.remember(serverURL) }
        return try await handle(fallback)
    }

    /// Sends one request. The connection's own user always goes as `UserId`.
    private func send(_ method: String, _ path: String, query: [String: String], body: Any?) async throws -> (Data, HTTPURLResponse) {
        let scopedQuery = userID.map { query.merging(["UserId": $0]) { _, captured in captured } } ?? query
        var request = URLRequest(url: try Self.url(serverURL: serverURL, path: path, query: scopedQuery))
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await (sessionOverride ?? Self.session).data(for: request)
        try await validate()
        guard let response = response as? HTTPURLResponse else { throw JellyfinError.invalidResponse }
        return (data, response)
    }

    /// A 401 retires this sign-in's token (posting the session expiry once)
    /// and throws `signInRequired`; any other non-2xx throws `HTTPError.http`
    /// without a body.
    private func handle(_ result: (Data, HTTPURLResponse)) async throws -> Data {
        let (data, response) = result
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            if let identity,
               let event = await TokenStore.shared.invalidateNativeToken(identity),
               await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) {
                await MainActor.run { NotificationCenter.default.post(name: .vividSessionExpired, object: event) }
            }
            throw JellyfinError.signInRequired
        default:
            throw HTTPError.http(statusCode: response.statusCode, body: nil)
        }
    }

    /// An artwork or file URL the server returned, fetched through this
    /// signed transport. It must sit under this server's base.
    func assetData(_ raw: String) async throws -> Data {
        let base = try Self.url(serverURL: serverURL, path: "/")
        guard let url = URL(string: raw),
              let path = ServerAssetPath.relative(url, base: base),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw JellyfinError.invalidURL }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        return try await data("GET", path, query: query)
    }

    /// The reply as a JSON object; anything else throws `invalidResponse`.
    func object(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        guard let object = try await request(method, path, query: query, body: body) as? [String: Any] else {
            throw JellyfinError.invalidResponse
        }
        return object
    }

    // MARK: Sign-in

    /// Checks the address is a Jellyfin server and returns its name.
    static func probe(serverURL: String) async throws -> String? {
        let info = try await signIn(serverURL: serverURL).object("GET", "/System/Info/Public")
        guard info["Id"] is String, info["Version"] is String else { throw JellyfinError.invalidResponse }
        return info["ServerName"] as? String
    }

    static func login(serverURL: String, username: String, password: String) async throws -> (token: String, userID: String) {
        let result = try await signIn(serverURL: serverURL)
            .object("POST", "/Users/AuthenticateByName", body: ["Username": username, "Pw": password])
        let login = try JellyfinLogin(result)
        return (login.token, login.userID)
    }

    /// An unauthenticated connection for signing in.
    static func signIn(serverURL: String) -> Self {
        Self(serverURL: serverURL, token: nil, userID: nil, identity: nil)
    }

    // MARK: Quick Connect

    /// Jellyfin answers a bare `true` or `false`. Any other answer, or no
    /// route at all, comes from a server that isn't Jellyfin 10.8 or later,
    /// such as another server's address left in the form.
    func quickConnectEnabled() async throws -> Bool {
        let body: Data
        do {
            body = try await data("GET", "/QuickConnect/Enabled")
        } catch HTTPError.http(let status, _) where status == 404 {
            throw JellyfinError.quickConnectUnavailable
        }
        switch String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: throw JellyfinError.quickConnectUnavailable
        }
    }

    /// Starts a request and returns the code the user approves from a
    /// signed-in Jellyfin app. Jellyfin ties the request to this device's ID
    /// in the authorisation header.
    func initiateQuickConnect() async throws -> JellyfinQuickConnectCode {
        let result: [String: Any]
        do {
            do {
                result = try await object("POST", "/QuickConnect/Initiate")
            } catch HTTPError.http(let status, _) where status == 404 || status == 405 {
                // Jellyfin 10.8 starts Quick Connect with GET.
                result = try await object("GET", "/QuickConnect/Initiate")
            }
        } catch JellyfinError.signInRequired {
            throw JellyfinError.quickConnectDisabled
        }
        guard let code = result["Code"] as? String, !code.isEmpty,
              let secret = result["Secret"] as? String, !secret.isEmpty
        else { throw JellyfinError.invalidResponse }
        return JellyfinQuickConnectCode(code: code, secret: secret)
    }

    /// Whether the code has been approved yet. Jellyfin forgets a request
    /// once it expires, after about ten minutes.
    func quickConnectApproved(secret: String) async throws -> Bool {
        do {
            let result = try await object("GET", "/QuickConnect/Connect", query: ["secret": secret])
            return result["Authenticated"] as? Bool == true
        } catch HTTPError.http(let status, _) where status == 404 {
            throw JellyfinError.quickConnectExpired
        } catch JellyfinError.signInRequired {
            throw JellyfinError.quickConnectDisabled
        }
    }

    /// Exchanges an approved request for a session, like a password sign-in.
    func authenticate(quickConnectSecret secret: String) async throws -> JellyfinLogin {
        try JellyfinLogin(try await object("POST", "/Users/AuthenticateWithQuickConnect", body: ["Secret": secret]))
    }
}

struct JellyfinQuickConnectCode: Sendable, Equatable {
    let code: String
    let secret: String
}

/// A new Jellyfin session from `AuthenticateByName` or Quick Connect.
struct JellyfinLogin: Sendable, Equatable {
    let token: String
    let userID: String
    let username: String

    init(token: String, userID: String, username: String) {
        self.token = token
        self.userID = userID
        self.username = username
    }

    init(_ result: [String: Any]) throws {
        guard let token = result["AccessToken"] as? String, !token.isEmpty,
              let user = result["User"] as? [String: Any],
              let userID = user["Id"] as? String
        else { throw JellyfinError.invalidResponse }
        self.init(token: token, userID: try JellyfinConnection.id(userID), username: user["Name"] as? String ?? "")
    }
}

// MARK: - Directory

/// Library IDs from Views, under the number Vivid uses for each, kept for
/// five minutes per credential owner and user (at most eight). Only this
/// directory is cached, never catalogue or user state.
actor JellyfinLibraryDirectory {
    static let shared = JellyfinLibraryDirectory()

    private struct Key: Hashable {
        let account: RefreshAccountIdentity
        let user: String
    }

    private struct Entry {
        let expires: Date
        let ids: [String: String]
    }

    private var entries: [Key: Entry] = [:]

    func remember(_ rows: [[String: Any]], connection: JellyfinConnection, now: Date = Date()) {
        guard let key = Self.key(connection) else { return }
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= 8, entries[key] == nil { entries.removeAll() }
        let pairs = rows.compactMap { row -> (String, String)? in
            guard let id = row["Id"] as? String else { return nil }
            return (String(JellyfinAdapter.numberID(id)), id)
        }
        entries[key] = Entry(expires: now.addingTimeInterval(300), ids: Dictionary(pairs) { first, _ in first })
    }

    func nativeID(_ number: String, connection: JellyfinConnection, now: Date = Date()) -> String? {
        guard let key = Self.key(connection), let entry = entries[key], entry.expires > now else { return nil }
        return entry.ids[number]
    }

    private static func key(_ connection: JellyfinConnection) -> Key? {
        guard let account = connection.identity?.account, let user = connection.userID else { return nil }
        return Key(account: account, user: user)
    }
}
