import XCTest
@testable import Vivid

final class SiloThemeMusicTests: XCTestCase {
    // MARK: - Pure helpers

    func testFirstThemeTakesTheOwnerAndFirstSong() {
        let detail = #"{"content_id":"episode:9","type":"episode","themes":{"owner_id":"series:4","items":[{"id":"12","title":"Opening","duration_seconds":31,"container":"MP3"},{"id":"13","title":"Other","duration_seconds":20,"container":"m4a"}]}}"#
        XCTAssertEqual(SiloThemeMusic.firstTheme(inDetail: Data(detail.utf8)),
                       .found(ThemeSongLookup(ownerID: "series:4", songID: "12", container: "mp3")))
    }

    func testMissingOrEmptyThemesMeanNoneAndBadDocumentsFail() {
        for detail in [
            #"{"content_id":"movie:1","type":"movie"}"#,
            #"{"content_id":"movie:1","themes":{"owner_id":"movie:1","items":[]}}"#,
        ] {
            XCTAssertEqual(SiloThemeMusic.firstTheme(inDetail: Data(detail.utf8)), ThemeSongLookupResult.none, detail)
        }
        for detail in [
            #"{"content_id":"movie:1","themes":{"owner_id":"","items":[{"id":"1"}]}}"#,
            "not json",
        ] {
            XCTAssertEqual(SiloThemeMusic.firstTheme(inDetail: Data(detail.utf8)), .failed, detail)
        }
    }

    func testCapabilityNeedsAvailableAndNotRefused() {
        // nil is a document that doesn't decode, which the lookup reports
        // as a failure rather than "no theme music".
        let cases: [(String, Bool?)] = [
            (#"{"state":"available","allowed":true,"delivery":"routed"}"#, true),
            (#"{"state":"available"}"#, true),
            (#"{"state":"available","allowed":false}"#, false),
            (#"{"state":"disabled","allowed":true}"#, false),
            (#"{"allowed":true}"#, nil),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(SiloThemeMusic.capabilityAllowsPlayback(Data(body.utf8)), expected, body)
        }
    }

    func testGrantURLResolvesAgainstTheServer() {
        let server = "https://silo.example.com:8443"
        XCTAssertEqual(SiloThemeMusic.resolveGrantURL("/api/v2/catalog/items/movie%3A1/themes/7/audio?token=a%2Fb", serverURL: server)?.absoluteString,
                       "https://silo.example.com:8443/api/v2/catalog/items/movie%3A1/themes/7/audio?token=a%2Fb")
        XCTAssertEqual(SiloThemeMusic.resolveGrantURL("https://proxy.example.com/theme?token=x", serverURL: server)?.absoluteString,
                       "https://proxy.example.com/theme?token=x")
        XCTAssertNil(SiloThemeMusic.resolveGrantURL("//proxy.example.com/theme", serverURL: server))
        XCTAssertNil(SiloThemeMusic.resolveGrantURL("ftp://proxy.example.com/theme", serverURL: server))
        XCTAssertNil(SiloThemeMusic.resolveGrantURL("api/v2/theme", serverURL: server))
        XCTAssertNil(SiloThemeMusic.resolveGrantURL("", serverURL: server))
    }

    func testGrantBodyListsWhatAVPlayerOpens() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SiloThemeMusic.grantRequestBody) as? [String: Any])
        let formats = try XCTUnwrap(object["accepted_formats"] as? [[String: String]])
        XCTAssertTrue(formats.contains { $0["container"] == "mp4" && $0["audio_codec"] == "aac" }, "AAC in MP4 lets Silo convert")
        XCTAssertTrue(formats.contains { $0["container"] == "mp3" && $0["audio_codec"] == "mp3" })
        XCTAssertFalse(formats.contains { $0["container"] == "ogg" || $0["container"] == "opus" })
        XCTAssertFalse(formats.contains { $0["audio_codec"] == "vorbis" || $0["audio_codec"] == "opus" })
    }

    func testPathSegmentEncodesReservedCharacters() {
        XCTAssertEqual(SiloThemeMusic.pathSegment("movie:42"), "movie:42")
        XCTAssertEqual(SiloThemeMusic.pathSegment("a/b?c#d"), "a%2Fb%3Fc%23d")
        XCTAssertNil(SiloThemeMusic.pathSegment(""))
    }

    // MARK: - Requests

    func testLookupAndOriginalStreamUseTheSignedV2Routes() async throws {
        let (http, tokens) = await makeClient()
        SiloThemeStub.configure { request in
            switch (request.httpMethod ?? "", request.url!.path) {
            case ("GET", "/api/v2/system/info"): return (200, #"{"api_major":2}"#)
            case ("GET", "/api/v2/catalog/themes/capabilities"): return (200, #"{"state":"available","allowed":true}"#)
            case ("GET", "/api/v2/catalog/items/season:3"):
                return (200, #"{"content_id":"season:3","themes":{"owner_id":"series:1","items":[{"id":"8","container":"mp3"}]}}"#)
            case ("POST", "/api/v2/catalog/items/series:1/themes/8/playback"):
                return (200, #"{"url":"/api/v2/catalog/items/series:1/themes/8/audio?token=grant","expires_at":"2026-11-18T00:05:00Z","delivery":"original","content_type":"audio/mpeg"}"#)
            default: throw URLError(.badURL)
            }
        }

        let item = ThemeMusicItem(contentID: "season:3", type: "season", seriesID: "series:1")
        let found = await SiloThemeMusic.lookup(for: item, http: http, tokenStore: tokens, capabilities: SiloThemeCapabilityCache())
        guard case .found(let lookup) = found else { return XCTFail("Expected a theme, got \(found)") }
        XCTAssertEqual(lookup, ThemeSongLookup(ownerID: "series:1", songID: "8", container: "mp3"))
        let opened = await SiloThemeMusic.stream(for: lookup, http: http)
        let stream = try XCTUnwrap(opened)
        XCTAssertEqual(stream.url.absoluteString, "http://silo-theme-test.invalid/api/v2/catalog/items/series:1/themes/8/audio?token=grant")
        XCTAssertTrue(stream.headers.isEmpty)

        let requests = SiloThemeStub.requests()
        let grant = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(grant.value(forHTTPHeaderField: "Authorization"), "Bearer fake")
        XCTAssertEqual(grant.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        XCTAssertEqual(grant.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(SiloThemeStub.body(of: grant), SiloThemeMusic.grantRequestBody)
    }

    func testV1ServerHasNoThemes() async throws {
        let (http, tokens) = await makeClient()
        SiloThemeStub.configure { request in
            if request.url!.path == "/api/v2/system/info" { return (404, "{}") }
            XCTFail("Unexpected request to \(request.url!.path)")
            return (500, "{}")
        }
        let item = ThemeMusicItem(contentID: "movie:1", type: "movie", seriesID: nil)
        let lookup = await SiloThemeMusic.lookup(for: item, http: http, tokenStore: tokens, capabilities: SiloThemeCapabilityCache())
        XCTAssertEqual(lookup, ThemeSongLookupResult.none)
    }

    func testRefusedGrantNeverRefreshesOrSignsOut() async throws {
        let (http, tokens) = await makeClient()
        SiloThemeStub.configure { request in
            switch request.url!.path {
            case "/api/v2/system/info": return (200, #"{"api_major":2}"#)
            default: return (401, #"{"type":"authentication_required"}"#)
            }
        }
        let expired = expectation(forNotification: .vividSessionExpired, object: nil)
        expired.isInverted = true

        let lookup = ThemeSongLookup(ownerID: "movie:1", songID: "2", container: nil)
        let stream = await SiloThemeMusic.stream(for: lookup, http: http)
        XCTAssertNil(stream)
        let capable = await SiloThemeCapabilityCache().isPlayable(http: http, tokenStore: tokens)
        XCTAssertNotEqual(capable, true)

        await fulfillment(of: [expired], timeout: 0.5)
        // Exactly the discovery, the refused grant and the refused
        // capabilities: no refresh and no retry.
        XCTAssertEqual(SiloThemeStub.requests().map { "\($0.httpMethod ?? "") \($0.url!.path)" }, [
            "GET /api/v2/system/info",
            "POST /api/v2/catalog/items/movie:1/themes/2/playback",
            "GET /api/v2/catalog/themes/capabilities",
        ])
        let access = await tokens.getAccessToken()
        let refresh = await tokens.getRefreshToken()
        XCTAssertEqual(access, "fake")
        XCTAssertEqual(refresh, "dummy")
    }

    // MARK: - Helpers

    private func makeClient() async -> (HTTPClient, TokenStore) {
        let name = "SiloThemeMusicTests." + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                                defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server-a")
        await tokens.setServerUrl("http://silo-theme-test.invalid")
        await tokens.setProfileId("profile-a")
        await tokens.saveTokens(accessToken: "fake", refreshToken: "dummy")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloThemeStub.self]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            UserDefaults().removePersistentDomain(forName: name)
        }
        return (HTTPClient(apiDiscovery: SiloAPIDiscovery(), session: session, tokenStore: tokens), tokens)
    }
}

private final class SiloThemeStub: URLProtocol {
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

    /// A URLProtocol sees an uploaded body as a stream, not `httpBody`.
    static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
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
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
