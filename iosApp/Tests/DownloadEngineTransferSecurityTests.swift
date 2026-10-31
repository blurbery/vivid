import XCTest
@testable import Vivid

/// Download requests carry only the identity they were made for, and only
/// to the account's own server.
final class DownloadEngineTransferSecurityTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        TransferStub.reset()
        super.tearDown()
    }

    // MARK: Set-up

    /// A token store of its own, signed in to server-a with profile-a.
    private func signedInStore(_ name: String) async throws -> TokenStore {
        let suiteName = "vivid.tests.download-security.\(name).\(UUID().uuidString)"
        suites.append(suiteName)
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = TokenStore(
            keychain: SharedKeychain(service: "vivid.tests.download-security.\(name).\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://a.example.test/proxy")
        await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
        await store.setProfileId("profile-a")
        await store.setProfileToken("proof-a")
        return store
    }

    /// An API whose every request goes to the recording stub, on v1 paths.
    private func api(_ store: TokenStore, beforeEachRequest: @escaping @Sendable () async -> Void) -> VividAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferStub.self]
        let client = HTTPClient(
            apiDiscovery: SiloAPIDiscovery(legacyOnly: true),
            session: URLSession(configuration: configuration),
            tokenStore: store,
            requestCaptureBarrier: beforeEachRequest
        )
        return VividAPI(http: client, tokenStore: store)
    }

    private static let calls: [(name: String, run: @Sendable (VividAPI, CapturedOrdinaryRequestAuth) async throws -> Void)] = [
        ("manifest", { api, auth in _ = try await api.fetchManifest(downloadId: "download-1", auth: auth) }),
        ("relative asset", { api, auth in
            _ = try await api.fetchDownloadAssetData(path: "/api/v1/downloads/download-1/poster", auth: auth)
        }),
        ("absolute asset", { api, auth in
            _ = try await api.fetchDownloadAssetData(
                path: "https://a.example.test/proxy/api/v1/downloads/download-1/poster", auth: auth
            )
        }),
        ("status", { api, auth in try await api.patchDownloadStatus(id: "download-1", status: "downloading", auth: auth) }),
    ]

    private static let changes: [(name: String, apply: @Sendable (TokenStore) async -> Void)] = [
        ("profile", { await $0.setProfileId("profile-b") }),
        ("profile proof", { await $0.setProfileToken("proof-b") }),
        ("another account", { await $0.saveTokens(accessToken: "access-other", refreshToken: "refresh-other") }),
        ("another server", { store in
            await store.clearTokens()
            await store.switchActiveServer(serverId: "server-b")
            await store.setServerUrl("https://b.example.test")
            await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
        }),
    ]

    private func assertIdentityChanged(_ error: Error, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case HTTPError.requestIdentityChanged? = error as? HTTPError else {
            return XCTFail("\(message): \(error)", file: file, line: line)
        }
    }

    // MARK: Requests

    func testIdentityChangesBeforeDispatchAreRefused() async throws {
        for change in Self.changes {
            for call in Self.calls {
                TransferStub.reset()
                let store = try await signedInStore("refused")
                let auth = try unwrapped(await store.captureOrdinaryRequestAuth())
                let api = api(store) { await change.apply(store) }
                do {
                    try await call.run(api, auth)
                    XCTFail("\(change.name), \(call.name): the request went ahead")
                } catch {
                    assertIdentityChanged(error, "\(change.name), \(call.name)")
                }
                XCTAssertTrue(TransferStub.requests.isEmpty, "\(change.name), \(call.name): nothing is sent")
                await store.clearTokens()
            }
        }
    }

    func testASameAccountRefreshIsAllowedThrough() async throws {
        let store = try await signedInStore("refresh")
        let auth = try unwrapped(await store.captureOrdinaryRequestAuth())
        let accepted = RefreshLog()
        let api = api(store) {
            guard let account = await store.captureOrdinaryRequestAuth()?.account,
                  let credential = await store.captureRefreshCredential(expected: account) else {
                return accepted.append(false)
            }
            accepted.append(await store.saveRefreshedTokens("rotated-a", "rotated-refresh", replacing: credential))
        }

        let manifest = try await api.fetchManifest(downloadId: "download-1", auth: auth)
        XCTAssertEqual(manifest.downloadId, "download-1")
        let relative = try await api.fetchDownloadAssetData(path: "/api/v1/downloads/download-1/poster", auth: auth)
        let absolute = try await api.fetchDownloadAssetData(
            path: "https://a.example.test/proxy/api/v1/downloads/download-1/poster", auth: auth
        )
        XCTAssertEqual(relative, Data("artwork".utf8))
        XCTAssertEqual(relative, absolute)
        try await api.patchDownloadStatus(id: "download-1", status: "downloading", auth: auth)

        XCTAssertEqual(accepted.values, [true, true, true, true], "Every refresh is accepted")
        let requests = TransferStub.requests
        XCTAssertEqual(requests.count, 4)
        for request in requests {
            XCTAssertEqual(request.url?.host, "a.example.test")
            XCTAssertTrue(request.url?.path.hasPrefix("/proxy/api/v1/downloads/download-1") == true, "\(request.url?.path ?? "")")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        }
        XCTAssertEqual(requests.last?.httpMethod, "PATCH")
        await store.clearTokens()
    }

    func testPlainHTTPServersStillWork() throws {
        for serverId in ["silo-local", "emby:local"] {
            let identity = Self.identity(serverId: serverId, url: "http://media.example.test:8096",
                                         access: "local-token", profile: "profile", proof: "proof")
            let request = try DownloadEngine.TransferRequest.build(
                url: try XCTUnwrap(URL(string: "http://media.example.test:8096/file")), allowsCellular: false,
                identity: identity
            )
            XCTAssertEqual(request.url?.scheme, "http", serverId)
            let header = serverId.hasPrefix("emby:") ? "X-Emby-Token" : "Authorization"
            XCTAssertNotNil(request.value(forHTTPHeaderField: header), serverId)
        }
    }

    /// Networking's request path check, kept with the downloads tests.
    func testRequestPathsAreValidated() throws {
        for rejected in ["/api/v1/items/%", "/api/v1/items/%2", "/api/v1/items/%GG", "/api/v1/items/a b",
                         "/api/v1/items/a?b", "/api/v1/items/a#b"] {
            XCTAssertThrowsError(try HTTPClient.validatedRequestPath(rejected), rejected)
        }
        for accepted in ["/api/v1/items/123", "/proxy/api/v1/assets/a%20b.jpg", "/api/v1/items/%25",
                         "/api/v1/items/%E2%9C%93", "/api/v1/assets/a%2Fb"] {
            XCTAssertEqual(try HTTPClient.validatedRequestPath(accepted), accepted)
        }
        // A link whose last path component decodes to a bare percent sign.
        let link = try XCTUnwrap(URL(string: "vivid://item/%25"))
        XCTAssertEqual(link.lastPathComponent, "%")
        XCTAssertThrowsError(try HTTPClient.validatedRequestPath("/api/v1/items/\(link.lastPathComponent)"))
    }

    // MARK: Transfers

    func testTransferCredentialsFollowTheCapturedIdentity() async throws {
        let store = try await signedInStore("transfer")
        let expected = try unwrapped(await store.captureOrdinaryRequestAuth())
        let url = try XCTUnwrap(URL(string: "https://a.example.test/proxy/api/v1/downloads/1/file"))

        let first = try await DownloadEngine.TransferRequest.make(url: url, allowsCellular: false, expected: expected, tokenStore: store)
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer access-a")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        XCTAssertFalse(first.allowsCellularAccess)

        let account = try unwrapped(await store.captureOrdinaryRequestAuth()).account
        let credential = try unwrapped(await store.captureRefreshCredential(expected: account))
        let refreshed = await store.saveRefreshedTokens("rotated-a", "rotated-refresh", replacing: credential)
        XCTAssertTrue(refreshed)
        let rotated = try await DownloadEngine.TransferRequest.make(url: url, allowsCellular: true, expected: expected, tokenStore: store)
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "Authorization"), "Bearer rotated-a")
        XCTAssertEqual(rotated.value(forHTTPHeaderField: "X-Profile-Token"), "proof-a")
        XCTAssertTrue(rotated.allowsCellularAccess)

        let steps: [(String, @Sendable (TokenStore) async -> Void)] = [
            ("profile", { await $0.setProfileId("profile-b") }),
            ("profile proof", { store in
                await store.setProfileId("profile-a")
                await store.setProfileToken("proof-b")
            }),
            ("another account", { store in
                await store.setProfileToken("proof-a")
                await store.saveTokens(accessToken: "access-other", refreshToken: "refresh-other")
            }),
            ("another server", { store in
                await store.clearTokens()
                await store.switchActiveServer(serverId: "server-b")
                await store.setServerUrl("https://b.example.test")
                await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
            }),
        ]
        for (name, step) in steps {
            await step(store)
            do {
                _ = try await DownloadEngine.TransferRequest.make(url: url, allowsCellular: false, expected: expected, tokenStore: store)
                XCTFail("\(name): the transfer was allowed")
            } catch {
                assertIdentityChanged(error, name)
            }
        }
        await store.clearTokens()
    }

    func testTransfersStayOnTheServerAndEmbyGetsItsOwnHeaders() throws {
        let refused = [
            "https://other.example.test/proxy/file", "http://media.example.test/proxy/file",
            "https://media.example.test:444/proxy/file", "https://media.example.test/outside/file",
            "https://user:pass@media.example.test/proxy/file",
        ]
        for serverId in ["silo-a", "emby:a"] {
            let identity = Self.identity(serverId: serverId, url: "https://media.example.test/proxy",
                                         access: "test-access", profile: "test-profile", proof: "test-proof")
            for text in refused {
                XCTAssertThrowsError(try DownloadEngine.TransferRequest.build(
                    url: try XCTUnwrap(URL(string: text)), allowsCellular: false, identity: identity
                ), "\(serverId) \(text)")
            }
            let request = try DownloadEngine.TransferRequest.build(
                url: try XCTUnwrap(URL(string: "https://media.example.test:443/proxy/file")), allowsCellular: false,
                identity: identity
            )
            if serverId.hasPrefix("emby:") {
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

    private static func identity(serverId: String, url: String, access: String, profile: String,
                                 proof: String) -> CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(serverId: serverId, serverURL: url, credentialGenerationID: UUID()),
            credentialOwner: .persistentServer(serverId: serverId),
            accessToken: access, profileId: profile, profileToken: proof
        )
    }
}

/// Unwraps an optional produced by an `await`.
private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// Results of the refreshes a request barrier makes.
private final class RefreshLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Records every request and answers 200: a manifest for `/manifest`, an
/// empty body for PATCH and the bytes `artwork` for anything else.
private final class TransferStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let body: Data
        if request.url?.path.hasSuffix("/manifest") == true {
            body = Data(#"{"download_id":"download-1","content_id":"item-1","type":"movie","quality":"original","media_file_id":1,"title":"Movie"}"#.utf8)
        } else if request.httpMethod == "PATCH" {
            body = Data()
        } else {
            body = Data("artwork".utf8)
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": request.url?.path.hasSuffix("/manifest") == true ? "application/json" : "application/octet-stream"]
        )
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
