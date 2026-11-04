import Foundation

// The Emby connection: errors, the signed transport, sign-in (username and
// password or Emby Connect) and the short-lived per-account directory. The
// adapter that turns Emby's API into Vivid's is in `EmbyProvider+Items.swift`,
// `EmbyProvider+Home.swift` and `EmbyProvider+Routes.swift`. Nothing here is
// shared with Jellyfin.

enum EmbyError: LocalizedError {
    case invalidResponse, invalidURL, unsupportedFeature, signInRequired, playbackUnavailable
    case connectUnavailable, connectPINExpired, connectServerNotLinked
    case filterRequestFailed(step: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .filterRequestFailed(let step, let status): filterRequestFailureText(step: step, status: status)
        case .invalidResponse: String(localized: "Emby returned an unexpected response.")
        case .invalidURL: String(localized: "The Emby server returned an invalid address.")
        case .unsupportedFeature: String(localized: "This feature is not available with Emby yet.")
        case .signInRequired: String(localized: "Please sign in to Emby again.")
        case .playbackUnavailable: String(localized: "Emby could not provide a playable media source.")
        case .connectUnavailable: String(localized: "Emby Connect couldn’t be reached. Please try again later.")
        case .connectPINExpired: String(localized: "This Emby Connect PIN has expired.")
        case .connectServerNotLinked: String(localized: "This Emby Connect account isn’t linked to a user on this server.")
        }
    }
}

/// "Genres: HTTP 500" in the app language. `step` stays the English value
/// the error carries ("Library lookup", "Genres", "Ratings"); only its
/// displayed name is translated.
func filterRequestFailureText(step: String, status: Int) -> String {
    let stepTitle = switch step {
    case "Library lookup": String(localized: "Library lookup", comment: "Filter loading step that failed: finding the library")
    case "Genres": String(localized: "Genres", comment: "Filter loading step that failed: the genre list")
    case "Ratings": String(localized: "Ratings", comment: "Filter loading step that failed: the age rating list")
    default: step
    }
    return String(localized: "\(stepTitle): HTTP \(status)", comment: "Filter loading failure: the step that failed, then the HTTP status code")
}

/// Refuses every redirect, so a token never follows one to another host.
final class EmbyRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

// MARK: - Connection

/// One Emby account's transport: its address, token and user, plus the
/// captured sign-in it belongs to. Every request checks that sign-in is still
/// the active one before and after it goes out.
struct EmbyConnection: Sendable {
    let serverURL: String
    let token: String?
    let userID: String?
    let identity: CapturedOrdinaryRequestAuth?
    var sessionOverride: URLSession? = nil

    /// The active Emby account. Throws `signInRequired` without one.
    static func current() async throws -> Self {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              MediaServerProvider.forServerID(auth.account.serverId) == .emby,
              let token = auth.accessToken, !token.isEmpty
        else { throw EmbyError.signInRequired }
        guard let userID = await TokenStore.shared.nativeUserID(expected: auth.account), !userID.isEmpty else {
            throw EmbyError.signInRequired
        }
        return Self(serverURL: auth.account.serverURL, token: token, userID: userID, identity: auth)
    }

    /// The active Emby account, only when it's still the sign-in `expected`
    /// captured (same account, profile and profile proof).
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

    /// `path` under the server's `/emby` base (added unless the address
    /// already ends in it), with the query sorted by name. The address must
    /// be plain http or https with a host and nothing else; the path must be
    /// absolute and can't climb out with `..`.
    static func url(serverURL: String, path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: serverURL),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("..")
        else { throw EmbyError.invalidURL }
        var base = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.split(separator: "/").last?.lowercased() != "emby" {
            base += base.isEmpty ? "emby" : "/emby"
        }
        components.path = "/" + base + path
        components.queryItems = query.isEmpty ? nil : sortedQueryItems(query)
        guard let url = components.url else { throw EmbyError.invalidURL }
        return url
    }

    /// The ID itself when it's only ASCII letters, digits, `-` and `_`, so it
    /// can go into a path as is.
    static func id(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy(isIDByte) else { throw EmbyError.invalidResponse }
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

    /// This installation's Emby device ID, made once and kept.
    static let deviceID: String = {
        let key = "vivid.emby.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var headers: [String: String] {
        let client = "Emby Client=\"Vivid\", Device=\"Apple\", DeviceId=\"\(Self.deviceID)\", Version=\"\(Self.appVersion)\""
        var fields = ["X-Emby-Authorization": client]
        if let token { fields["X-Emby-Token"] = token }
        return fields
    }

    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: EmbyRedirectPolicy(), delegateQueue: nil)

    // MARK: Requests

    /// The decoded JSON reply; an empty body reads as an empty object.
    func request(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Any {
        let data = try await data(method, path, query: query, body: body)
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
    }

    /// The raw reply. A 401 retires this sign-in's token (posting the
    /// session expiry once) and throws `signInRequired`; any other non-2xx
    /// throws `HTTPError.http` without a body.
    func data(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> Data {
        try await validate()
        var request = URLRequest(url: try Self.url(serverURL: serverURL, path: path, query: query))
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await (sessionOverride ?? Self.session).data(for: request)
        try await validate()
        guard let response = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            await expireSession()
            throw EmbyError.signInRequired
        default:
            throw HTTPError.http(statusCode: response.statusCode, body: nil)
        }
    }

    private func expireSession() async {
        guard let identity,
              let event = await TokenStore.shared.invalidateNativeToken(identity),
              await TokenStore.shared.shouldConsumeSessionExpiryEvent(event)
        else { return }
        await MainActor.run { NotificationCenter.default.post(name: .vividSessionExpired, object: event) }
    }

    /// An artwork or file URL the server returned, fetched through this
    /// signed transport. It must sit under this server's base.
    func assetData(_ raw: String) async throws -> Data {
        let base = try Self.url(serverURL: serverURL, path: "/")
        guard let url = URL(string: raw),
              let path = ServerAssetPath.relative(url, base: base),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw EmbyError.invalidURL }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { _, last in last }
        return try await data("GET", path, query: query)
    }

    /// The reply as a JSON object; anything else throws `invalidResponse`.
    func object(_ method: String = "GET", _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        guard let object = try await request(method, path, query: query, body: body) as? [String: Any] else {
            throw EmbyError.invalidResponse
        }
        return object
    }

    // MARK: Sign-in

    private static func anonymous(_ serverURL: String, token: String? = nil, session: URLSession? = nil) -> Self {
        Self(serverURL: serverURL, token: token, userID: nil, identity: nil, sessionOverride: session)
    }

    /// Checks the address is an Emby server and returns its name.
    static func probe(serverURL: String) async throws -> String? {
        let info = try await anonymous(serverURL).object("GET", "/System/Info/Public")
        guard info["Id"] is String, info["Version"] is String else { throw EmbyError.invalidResponse }
        return info["ServerName"] as? String
    }

    static func login(serverURL: String, username: String, password: String) async throws -> (token: String, userID: String) {
        let result = try await anonymous(serverURL)
            .object("POST", "/Users/AuthenticateByName", body: ["Username": username, "Pw": password])
        guard let token = result["AccessToken"] as? String, !token.isEmpty,
              let user = result["User"] as? [String: Any],
              let userID = user["Id"] as? String
        else { throw EmbyError.invalidResponse }
        return (token, try id(userID))
    }

    /// Signs in to this server as the local user linked to an approved Emby
    /// Connect account. Only this server's own address is used; the
    /// addresses Emby Connect reports for it are ignored.
    static func login(serverURL: String, connect account: EmbyConnectAccount, session: URLSession? = nil) async throws -> EmbyLogin {
        let info = try await anonymous(serverURL, session: session).object("GET", "/System/Info/Public")
        guard let systemID = info["Id"] as? String,
              let server = try await EmbyConnectService.servers(for: account, session: session)
                .first(where: { $0.systemID == systemID })
        else { throw EmbyError.connectServerNotLinked }

        let exchange: [String: Any]
        do {
            exchange = try await anonymous(serverURL, token: server.accessKey, session: session)
                .object("GET", "/Connect/Exchange", query: ["format": "json", "ConnectUserId": account.userID])
        } catch EmbyError.signInRequired {
            throw EmbyError.connectServerNotLinked
        } catch HTTPError.http(let status, _) where status == 404 {
            throw EmbyError.connectServerNotLinked
        }
        guard let token = exchange["AccessToken"] as? String, !token.isEmpty,
              let localUser = exchange["LocalUserId"] as? String
        else { throw EmbyError.invalidResponse }

        let userID = try id(localUser)
        let user = try await anonymous(serverURL, token: token, session: session).object("GET", "/Users/\(userID)")
        return EmbyLogin(token: token, userID: userID, username: user["Name"] as? String ?? "")
    }
}

/// Query items sorted by name, so URLs are the same every time.
private func sortedQueryItems(_ query: [String: String]) -> [URLQueryItem] {
    query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
}

/// A new Emby session from Emby Connect.
struct EmbyLogin: Sendable, Equatable {
    let token: String
    let userID: String
    let username: String
}

/// An Emby Connect account approved through a PIN. Used once to find this
/// server and never stored.
struct EmbyConnectAccount: Sendable, Equatable {
    let userID: String
    let token: String
}

struct EmbyConnectPIN: Sendable, Equatable {
    let pin: String
    let deviceID: String
}

// MARK: - Emby Connect

/// Emby Connect PIN sign-in through Emby's service at connect.emby.media,
/// as Emby's own TV apps do: the user enters the PIN at emby.media/pin with
/// their Emby Connect email and password, which Vivid never sees.
enum EmbyConnectService {
    static let baseURL = URL(string: "https://connect.emby.media/service")!

    struct Server: Sendable, Equatable {
        let systemID: String
        let accessKey: String
    }

    private static let session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }(), delegate: EmbyRedirectPolicy(), delegateQueue: nil)

    static func createPIN() async throws -> EmbyConnectPIN {
        let result = try await object("POST", "/pin", form: ["deviceId": EmbyConnection.deviceID])
        guard let pin = result["Pin"] as? String, !pin.isEmpty else { throw EmbyError.invalidResponse }
        return EmbyConnectPIN(pin: pin, deviceID: result["DeviceId"] as? String ?? EmbyConnection.deviceID)
    }

    /// Whether the PIN has been entered at emby.media/pin yet.
    static func isConfirmed(_ pin: EmbyConnectPIN) async throws -> Bool {
        let result: [String: Any]
        do {
            result = try await object("GET", "/pin", query: ["pin": pin.pin, "deviceId": pin.deviceID])
        } catch HTTPError.http(let status, _) where status == 404 || status == 410 {
            // The service no longer knows this PIN.
            throw EmbyError.connectPINExpired
        }
        if result["IsExpired"] as? Bool == true { throw EmbyError.connectPINExpired }
        return result["IsConfirmed"] as? Bool == true
    }

    static func authenticate(_ pin: EmbyConnectPIN) async throws -> EmbyConnectAccount {
        let result = try await object("POST", "/pin/authenticate", form: ["deviceId": pin.deviceID, "pin": pin.pin])
        guard let token = result["AccessToken"] as? String, !token.isEmpty else { throw EmbyError.invalidResponse }
        // The service has sent the user ID as text and as a number.
        let userID: String
        switch result["UserId"] {
        case let text as String: userID = text
        case let number as Int: userID = String(number)
        default: throw EmbyError.invalidResponse
        }
        return EmbyConnectAccount(userID: userID, token: token)
    }

    /// The servers linked to the account, each with the key that exchanges
    /// the account for its linked local user.
    static func servers(for account: EmbyConnectAccount, session: URLSession? = nil) async throws -> [Server] {
        let data = try await send("GET", "/servers", query: ["userId": account.userID], token: account.token, session: session)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EmbyError.invalidResponse
        }
        return rows.compactMap { row in
            guard let systemID = row["SystemId"] as? String,
                  let key = row["AccessKey"] as? String, !key.isEmpty
            else { return nil }
            return Server(systemID: systemID, accessKey: key)
        }
    }

    private static func object(_ method: String, _ path: String, query: [String: String] = [:], form: [String: String]? = nil) async throws -> [String: Any] {
        let data = try await send(method, path, query: query, form: form)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbyError.invalidResponse
        }
        return object
    }

    /// A network failure, timeout, rate limit or server error says nothing
    /// about the PIN, so those throw `connectUnavailable`. Other statuses
    /// throw `HTTPError.http`.
    private static func send(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        form: [String: String]? = nil,
        token: String? = nil,
        session sessionOverride: URLSession? = nil
    ) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(String(path.dropFirst())),
            resolvingAgainstBaseURL: false
        ) else { throw EmbyError.invalidURL }
        components.queryItems = query.isEmpty ? nil : sortedQueryItems(query)
        guard let url = components.url else { throw EmbyError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        request.setValue("Vivid/\(version)", forHTTPHeaderField: "X-Application")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Connect-UserToken") }
        if let form {
            var body = URLComponents()
            body.queryItems = sortedQueryItems(form)
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (sessionOverride ?? session).data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw EmbyError.connectUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let temporary = http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500
            throw temporary ? EmbyError.connectUnavailable : HTTPError.http(statusCode: http.statusCode, body: nil)
        }
        return data
    }
}

// MARK: - Directory

/// Short-lived per-account answers the adapter would otherwise fetch again on
/// every Home load and browse page: library IDs from Views (five minutes) and
/// the server version (ten minutes). Keyed by the exact credential owner, so
/// a new sign-in starts fresh; at most eight accounts are kept.
actor EmbyServerDirectory {
    static let shared = EmbyServerDirectory()

    private struct Key: Hashable {
        let account: RefreshAccountIdentity
        let user: String
    }

    private struct Entry<Value> {
        let expires: Date
        let value: Value
    }

    private static let capacity = 8
    private var libraries: [Key: Entry<[String: String]>] = [:]
    private var versions: [Key: Entry<String>] = [:]

    private static func key(_ connection: EmbyConnection) -> Key? {
        guard let account = connection.identity?.account, let user = connection.userID else { return nil }
        return Key(account: account, user: user)
    }

    /// Remembers each library's Emby ID under the number Vivid uses for it.
    func rememberLibraries(_ rows: [[String: Any]], connection: EmbyConnection, now: Date = Date()) {
        guard let key = Self.key(connection) else { return }
        let pairs = rows.compactMap { row -> (String, String)? in
            guard let id = row["Id"] as? String else { return nil }
            return (String(EmbyAdapter.numberID(id)), id)
        }
        let byNumber = Dictionary(pairs) { first, _ in first }
        Self.store(byNumber, for: key, lifetime: 300, in: &libraries, now: now)
    }

    func libraryID(_ number: String, connection: EmbyConnection, now: Date = Date()) -> String? {
        guard let key = Self.key(connection), let entry = libraries[key], entry.expires > now else { return nil }
        return entry.value[number]
    }

    func rememberVersion(_ version: String, connection: EmbyConnection, now: Date = Date()) {
        guard let key = Self.key(connection) else { return }
        Self.store(version, for: key, lifetime: 600, in: &versions, now: now)
    }

    func version(connection: EmbyConnection, now: Date = Date()) -> String? {
        guard let key = Self.key(connection), let entry = versions[key], entry.expires > now else { return nil }
        return entry.value
    }

    /// Drops expired entries, and everything when a new account would go
    /// past the capacity, then stores the value.
    private static func store<Value>(
        _ value: Value,
        for key: Key,
        lifetime: TimeInterval,
        in entries: inout [Key: Entry<Value>],
        now: Date
    ) {
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= capacity, entries[key] == nil { entries.removeAll() }
        entries[key] = Entry(expires: now.addingTimeInterval(lifetime), value: value)
    }
}
