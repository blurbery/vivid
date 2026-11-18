import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Search looks in the other saved profiles' libraries without switching to
/// them. These cover which profiles it may look in, and that a search signs
/// with that profile's own credentials and never touches the active session.
final class OtherProfileSearchTests: XCTestCase {
    // MARK: Which profiles

    func testOnlyASiloKidsOrUnknownSiloProfileHidesOtherProfiles() {
        func profile(child: Bool) -> UserProfile {
            UserProfile(id: "p", name: "Member", avatarEmoji: nil, hasPin: false, isChild: child)
        }
        // Emby and Jellyfin have no kids profiles, loaded or not.
        XCTAssertTrue(OtherProfileSearch.allowsOtherProfiles(activeProvider: .emby, liveProfile: nil, savedProfile: nil))
        XCTAssertTrue(OtherProfileSearch.allowsOtherProfiles(activeProvider: .jellyfin, liveProfile: nil, savedProfile: nil))
        // Silo: the saved card stands in until the live profile loads.
        XCTAssertTrue(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: nil, savedProfile: profile(child: false)))
        XCTAssertTrue(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: profile(child: false), savedProfile: nil))
        XCTAssertFalse(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: nil, savedProfile: nil))
        XCTAssertFalse(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: profile(child: true), savedProfile: nil))
        XCTAssertFalse(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: nil, savedProfile: profile(child: true)))
        XCTAssertFalse(OtherProfileSearch.allowsOtherProfiles(activeProvider: .silo, liveProfile: profile(child: false), savedProfile: profile(child: true)))
        // No profile in use at all.
        XCTAssertFalse(OtherProfileSearch.allowsOtherProfiles(activeProvider: nil, liveProfile: nil, savedProfile: nil))
    }

    func testSearchableTruthTable() {
        let plainSilo = account("silo")
        let emby = account("emby", serverID: "emby:c2VydmVy")
        let jellyfin = account("jellyfin", serverID: "jellyfin:c2VydmVy")
        func searchable(_ account: TVSavedAccount, activeID: String? = "active", hasLocalPIN: Bool = false,
                        hasSession: Bool = true) -> Bool {
            OtherProfileSearch.isSearchable(account, activeID: activeID, hasLocalPIN: hasLocalPIN, hasSession: hasSession)
        }

        XCTAssertTrue(searchable(plainSilo))
        XCTAssertTrue(searchable(emby))
        XCTAssertTrue(searchable(jellyfin))
        XCTAssertTrue(searchable(plainSilo, activeID: nil))

        XCTAssertFalse(searchable(plainSilo, activeID: "silo"), "the active profile already has its own results")
        XCTAssertFalse(searchable(account("login", requiresLogin: true)), "needs sign-in")
        XCTAssertFalse(searchable(plainSilo, hasSession: false), "no saved session")
        XCTAssertFalse(searchable(emby, hasLocalPIN: true), "Vivid PIN")
        XCTAssertFalse(searchable(account("enabled", pinEnabled: true)), "PIN flag on the card")
        XCTAssertFalse(searchable(account("locked", profileHasPin: true)), "Silo profile PIN")
    }

    // MARK: What a search sends

    func testSiloTargetUsesTheCardsOwnProfileAndOnlyItsProof() {
        let session = TVSavedAccountSession(accessToken: "access", refreshToken: "refresh",
                                            profile: profile("member-a"), profileToken: "proof-a")
        let unbound = OtherProfileSearch.Target(account("unbound"), session: session, serverURL: "https://other.invalid/")
        XCTAssertEqual(unbound?.profileID, "member-a")
        XCTAssertEqual(unbound?.profileToken, "proof-a")
        XCTAssertEqual(unbound?.serverURL, "https://other.invalid")

        var bound = account("bound")
        bound.siloProfileID = "member-b"
        let boundTarget = OtherProfileSearch.Target(bound, session: session, serverURL: "https://other.invalid")
        XCTAssertEqual(boundTarget?.profileID, "member-b")
        XCTAssertNil(boundTarget?.profileToken, "another member's proof must not travel with it")

        let noProfile = TVSavedAccountSession(accessToken: "access", refreshToken: "refresh", profile: nil, profileToken: nil)
        XCTAssertNil(OtherProfileSearch.Target(account("none"), session: noProfile, serverURL: "https://other.invalid"))
    }

    func testNativeTargetNeedsItsServerUser() {
        let jellyfin = account("jellyfin", serverID: "jellyfin:c2VydmVy")
        let without = TVSavedAccountSession(accessToken: "token", refreshToken: "", profile: nil, profileToken: nil)
        XCTAssertNil(OtherProfileSearch.Target(jellyfin, session: without, serverURL: "https://jf.invalid"))
        let with = TVSavedAccountSession(accessToken: "token", refreshToken: "", profile: nil, profileToken: nil,
                                         nativeUserID: "user-1")
        let target = OtherProfileSearch.Target(jellyfin, session: with, serverURL: "https://jf.invalid")
        XCTAssertEqual(target?.provider, .jellyfin)
        XCTAssertNil(target?.profileID)
    }

    func testV2SearchSignsWithTheProfilesOwnCredentials() async throws {
        let (http, tokens) = await makeClient()
        OtherProfileSearchStub.configure { request in
            switch request.url!.path {
            case "/api/v2/system/info":
                return (200, #"{"api_major":2}"#)
            case "/api/v2/catalog":
                return (200, #"{"items":[{"content_id":"movie:one","type":"movie","title":"One","poster_url":"/api/v2/artwork/poster?sig=a"},{"content_id":"person:two","type":"person","title":"Two"}]}"#)
            default:
                throw URLError(.badURL)
            }
        }

        let items = try await OtherProfileSearch.search(siloTarget(), query: " One ", type: "video", limit: 20, client: http)

        XCTAssertEqual(items.map(\.title), ["One"], "unsupported types are left out")
        XCTAssertEqual(items.first?.posterUrl, "http://other.invalid/api/v2/artwork/poster?sig=a")
        let requests = OtherProfileSearchStub.requests()
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "other.invalid" })
        let catalogue = try XCTUnwrap(requests.first { $0.url!.path == "/api/v2/catalog" })
        XCTAssertEqual(catalogue.value(forHTTPHeaderField: "Authorization"), "Bearer other-access")
        XCTAssertEqual(catalogue.value(forHTTPHeaderField: "X-Profile-Id"), "member-b")
        XCTAssertEqual(catalogue.value(forHTTPHeaderField: "X-Profile-Token"), "proof-b")
        let accessToken = await tokens.getAccessToken()
        XCTAssertEqual(accessToken, "active-access")
    }

    func testV1ExpiredTokenRefreshesInMemoryOnly() async throws {
        let (http, tokens) = await makeClient()
        let expired = expectation(forNotification: .vividSessionExpired, object: nil)
        expired.isInverted = true
        OtherProfileSearchStub.configure { request in
            switch request.url!.path {
            case "/api/v2/system/info":
                return (404, "{}")
            case "/api/v1/auth/refresh":
                return (200, #"{"access_token":"fresh-access","refresh_token":"rotated","expires_in":3600}"#)
            case "/api/v1/catalog":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access" else { return (401, "{}") }
                return (200, #"{"items":[{"content_id":"7","type":"series","title":"Seven","poster_url":"/images/7.jpg","backdrop_url":"https://cdn.invalid/7.jpg"}]}"#)
            default:
                throw URLError(.badURL)
            }
        }

        let items = try await OtherProfileSearch.search(siloTarget(), query: "seven", type: "series", limit: 20, client: http)

        XCTAssertEqual(items.first?.posterUrl, "http://other.invalid/images/7.jpg")
        XCTAssertEqual(items.first?.backdropUrl, "https://cdn.invalid/7.jpg")
        let catalogue = try XCTUnwrap(OtherProfileSearchStub.requests().last { $0.url!.path == "/api/v1/catalog" })
        let names = Set((URLComponents(url: catalogue.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name))
        XCTAssertEqual(names, ["source", "q", "type", "limit", "offset"], "no image-size entries")
        // The active session is exactly as it was, and nothing expired.
        let accessToken = await tokens.getAccessToken()
        XCTAssertEqual(accessToken, "active-access")
        await fulfillment(of: [expired], timeout: 0.2)
    }

    func testRelativeArtworkThatCantBeResolvedIsDropped() throws {
        let data = Data(#"{"items":[{"content_id":"1","type":"movie","title":"A","poster_url":"/p.jpg","backdrop_url":"/b.jpg"}]}"#.utf8)
        let joined = try OtherProfileSearch.catalogItems(from: data, serverURL: "https://silo.invalid:8443/")
        XCTAssertEqual(joined.first?.posterUrl, "https://silo.invalid:8443/p.jpg")
        let unresolved = try OtherProfileSearch.catalogItems(from: data, serverURL: "not a server")
        XCTAssertNil(unresolved.first?.posterUrl, "a relative path would otherwise load from the active server")
        XCTAssertNil(unresolved.first?.backdropUrl)
    }

    // MARK: Helpers

    private func account(
        _ id: String,
        serverID: String = "c2VydmVy",
        requiresLogin: Bool = false,
        pinEnabled: Bool? = nil,
        profileHasPin: Bool = false
    ) -> TVSavedAccount {
        TVSavedAccount(id: id, serverID: serverID, userID: "1", username: "viewer",
                       profile: profile("member-a", hasPin: profileHasPin), requiresLogin: requiresLogin,
                       pinEnabled: pinEnabled)
    }

    private func profile(_ id: String, hasPin: Bool = false) -> UserProfile {
        UserProfile(id: id, name: "Member", avatarEmoji: nil, hasPin: hasPin, isChild: false)
    }

    /// A Silo card on another server than the active one, with a fresh
    /// account ID so the in-memory token cache starts empty.
    private func siloTarget() throws -> OtherProfileSearch.Target {
        var card = account(UUID().uuidString)
        card.siloProfileID = "member-b"
        let session = TVSavedAccountSession(accessToken: "other-access", refreshToken: "other-refresh",
                                            profile: profile("member-b"), profileToken: "proof-b")
        return try XCTUnwrap(OtherProfileSearch.Target(card, session: session, serverURL: "http://other.invalid"))
    }

    private func makeClient() async -> (HTTPClient, TokenStore) {
        let name = "OtherProfileSearchTests." + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                                defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server-active")
        await tokens.setServerUrl("http://active.invalid")
        await tokens.setProfileId("active-profile")
        await tokens.saveTokens(accessToken: "active-access", refreshToken: "active-refresh")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OtherProfileSearchStub.self]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            UserDefaults().removePersistentDomain(forName: name)
        }
        return (HTTPClient(apiDiscovery: SiloAPIDiscovery(), session: session, tokenStore: tokens), tokens)
    }
}

private final class OtherProfileSearchStub: URLProtocol {
    typealias Reply = (Int, String)
    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Reply)?
    private static var recorded: [URLRequest] = []

    static func configure(_ body: @escaping (URLRequest) throws -> Reply) {
        lock.lock(); defer { lock.unlock() }
        handler = body
        recorded = []
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private static func response(for request: URLRequest) throws -> Reply {
        lock.lock()
        recorded.append(request)
        let body = handler
        lock.unlock()
        guard let body else { throw URLError(.badServerResponse) }
        return try body(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try Self.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
