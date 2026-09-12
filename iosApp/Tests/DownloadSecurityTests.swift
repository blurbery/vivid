import XCTest
@testable import Vivid

final class DownloadSecurityTests: XCTestCase {
    func testPreparationRejectsIdentityChangesAtCredentialCaptureBeforeDispatch() async throws {
        for mutation in 0..<4 {
            for endpoint in 0..<4 {
                let name = "DownloadPreparationTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
                defer { defaults.removePersistentDomain(forName: name) }
                let store = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                                       defaults: SharedDefaults(suite: defaults, standard: defaults))
                await store.switchActiveServer(serverId: "server-a")
                await store.setServerUrl("https://a.example.test/proxy")
                await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
                await store.setProfileId("profile-a")
                _ = await store.setProfileToken("proof-a")
                let captured = await store.captureOrdinaryRequestAuth()
                let auth = try XCTUnwrap(captured)
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [DownloadPreparationStub.self]
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                DownloadPreparationStub.reset()
                let http = HTTPClient(session: session, tokenStore: store, requestCaptureBarrier: {
                    // Deterministically interleave a scope change after the
                    // API receives the old download identity, before dispatch.
                    switch mutation {
                    case 0: await store.setProfileId("profile-b")
                    case 1: _ = await store.setProfileToken("proof-b")
                    case 2: await store.saveTokens(accessToken: "new-account", refreshToken: "new-refresh")
                    default:
                        await store.clearTokens()
                        await store.switchActiveServer(serverId: "server-b")
                        await store.setServerUrl("https://b.example.test")
                        await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
                    }
                })
                let api = VividAPI(http: http, tokenStore: store)
                do {
                    switch endpoint {
                    case 0: _ = try await api.fetchManifest(downloadId: "download-1", auth: auth)
                    case 1: _ = try await api.fetchDownloadAssetData(path: "/api/v1/downloads/download-1/poster", auth: auth)
                    case 2: _ = try await api.fetchDownloadAssetData(path: "https://a.example.test/proxy/api/v1/downloads/download-1/poster", auth: auth)
                    default: try await api.patchDownloadStatus(id: "download-1", status: "downloading", auth: auth)
                    }
                    XCTFail("Stale preparation work reached the transport")
                } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
                XCTAssertTrue(DownloadPreparationStub.requests.isEmpty)
                await store.clearTokens()
            }
        }
    }

    func testPreparationPreservesSameAccountRefreshManifestArtworkAndStatus() async throws {
        let name = "DownloadPreparationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                               defaults: SharedDefaults(suite: defaults, standard: defaults))
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://a.example.test/proxy")
        await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
        await store.setProfileId("profile-a")
        _ = await store.setProfileToken("proof-a")
        let captured = await store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadPreparationStub.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DownloadPreparationStub.reset()
        let http = HTTPClient(session: session, tokenStore: store, requestCaptureBarrier: {
            guard let refresh = await store.captureRefreshCredential(expected: auth.account) else {
                return XCTFail("Expected the original account")
            }
            let saved = await store.saveRefreshedTokens("rotated-a", "rotated-refresh", replacing: refresh)
            XCTAssertTrue(saved)
        })
        let api = VividAPI(http: http, tokenStore: store)
        let manifest = try await api.fetchManifest(downloadId: "download-1", auth: auth)
        XCTAssertEqual(manifest.downloadId, "download-1")
        let relative = try await api.fetchDownloadAssetData(path: "/api/v1/downloads/download-1/poster", auth: auth)
        let absolute = try await api.fetchDownloadAssetData(path: "https://a.example.test/proxy/api/v1/downloads/download-1/poster", auth: auth)
        XCTAssertEqual(relative, Data("artwork".utf8))
        XCTAssertEqual(absolute, relative)
        try await api.patchDownloadStatus(id: "download-1", status: "downloading", auth: auth)
        let requests = DownloadPreparationStub.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            XCTAssertEqual(request.url?.host, "a.example.test")
            XCTAssertTrue(request.url?.path.hasPrefix("/proxy/api/v1/downloads/download-1") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        }
        XCTAssertEqual(requests.last?.httpMethod, "PATCH")
        await store.clearTokens()
    }

    func testConfiguredHTTPDownloadsRemainSupported() throws {
        for server in ["silo-local", "emby:local"] {
            let auth = CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: server, serverURL: "http://media.example.test:8096",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: server), accessToken: "local-token",
                profileId: "profile", profileToken: "proof")
            let request = try DownloadAuthHeaders.request(url: URL(string: "http://media.example.test:8096/file")!,
                                                         allowsCellular: false, auth: auth)
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertNotNil(request.value(forHTTPHeaderField: server.hasPrefix("emby:") ? "X-Emby-Token" : "Authorization"))
        }
        // testDownloadOriginValidationAndEmbyHeaders covers rejecting a
        // downgrade when the configured server uses HTTPS.
    }

    func testRequestPathsRejectMalformedDeepLinksAndPreserveEncodedAssets() throws {
        for path in ["/api/v1/items/%", "/api/v1/items/%2", "/api/v1/items/%GG",
                     "/api/v1/items/a b", "/api/v1/items/a?b", "/api/v1/items/a#b"] {
            XCTAssertThrowsError(try HTTPClient.validatedRequestPath(path), path)
        }
        for path in ["/api/v1/items/123", "/proxy/api/v1/assets/a%20b.jpg",
                     "/api/v1/items/%25", "/api/v1/items/%E2%9C%93", "/api/v1/assets/a%2Fb"] {
            XCTAssertEqual(try HTTPClient.validatedRequestPath(path), path)
        }
        let link = try XCTUnwrap(URL(string: "vivid://item/%25"))
        let id = try XCTUnwrap(link.pathComponents.last)
        XCTAssertThrowsError(try HTTPClient.validatedRequestPath("/api/v1/items/\(id)"))
    }

    func testDownloadCredentialsRejectAccountProfileAndGenerationChanges() async throws {
        let name = "DownloadSecurityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://a.example.test/proxy")
        await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
        await store.setProfileId("profile-a")
        _ = await store.setProfileToken("proof-a")
        let captured = await store.captureOrdinaryRequestAuth()
        let original = try XCTUnwrap(captured)
        let url = try XCTUnwrap(URL(string: "https://a.example.test/proxy/api/v1/downloads/1/file"))
        let request = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: false,
                                                                    expected: original, tokenStore: store)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        XCTAssertFalse(request.allowsCellularAccess)

        // A successful refresh keeps the same owner and is allowed to supply
        // the new access token without losing the captured profile proof.
        let refresh = await store.captureRefreshCredential(expected: original.account)
        let saved = await store.saveRefreshedTokens("rotated-a", "rotated-refresh-a", replacing: try XCTUnwrap(refresh))
        XCTAssertTrue(saved)
        let rotated = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: true,
                                                                    expected: original, tokenStore: store)
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-a")
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")

        await store.setProfileId("profile-b")
        await assertIdentityRejected(url, original, store)
        await store.setProfileId("profile-a")
        _ = await store.setProfileToken("proof-b")
        await assertIdentityRejected(url, original, store)
        _ = await store.setProfileToken("proof-a")
        await store.saveTokens(accessToken: "another-account", refreshToken: "another-refresh")
        await assertIdentityRejected(url, original, store)
        await store.clearTokens()
        await store.switchActiveServer(serverId: "server-b")
        await store.setServerUrl("https://b.example.test")
        await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
        await assertIdentityRejected(url, original, store)
        await store.clearTokens()
    }

    func testDownloadOriginValidationAndEmbyHeaders() throws {
        for server in ["silo-a", "emby:a"] {
            let auth = CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: server, serverURL: "https://media.example.test/proxy",
                                                credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: server), accessToken: "test-access",
                profileId: "test-profile", profileToken: "test-proof")
            for destination in ["https://other.example.test/proxy/file", "http://media.example.test/proxy/file",
                                "https://media.example.test:444/proxy/file", "https://media.example.test/outside/file",
                                "https://user:pass@media.example.test/proxy/file"] {
                XCTAssertThrowsError(try DownloadAuthHeaders.request(url: URL(string: destination)!, allowsCellular: true, auth: auth))
            }
            let request = try DownloadAuthHeaders.request(url: URL(string: "https://media.example.test:443/proxy/file")!,
                                                         allowsCellular: true, auth: auth)
            if server.hasPrefix("emby:") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "test-access")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Emby-Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "test-proof")
            }
        }
    }

    private func assertIdentityRejected(_ url: URL, _ expected: CapturedOrdinaryRequestAuth, _ store: TokenStore) async {
        do {
            _ = try await DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: true, expected: expected, tokenStore: store)
            XCTFail("A stale download must not receive the new account's credentials")
        } catch HTTPError.requestIdentityChanged {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

private final class DownloadPreparationStub: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recordedRequests } }
    static func reset() { lock.withLock { recordedRequests.removeAll() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.recordedRequests.append(request) }
        let url = request.url!
        let payload: Data
        if url.path.hasSuffix("/manifest") {
            payload = Data(#"{"download_id":"download-1","content_id":"item-1","type":"movie","quality":"original","media_file_id":1,"title":"Movie"}"#.utf8)
        } else if request.httpMethod == "PATCH" {
            payload = Data()
        } else {
            payload = Data("artwork".utf8)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
