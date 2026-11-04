import XCTest
@testable import Vivid

/// Offline progress sync and series monitoring send only under the sign-in
/// and profile of the scope that started them, and Stop Monitoring keeps the
/// local subscription when the server delete fails.
final class DownloadSyncScopeTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        SyncScopeStub.reset()
        super.tearDown()
    }

    // MARK: Set-up

    /// A token store of its own, signed in to server-a with profile-a.
    private func signedInStore(_ name: String) async throws -> TokenStore {
        let suiteName = "vivid.tests.download-sync-scope.\(name).\(UUID().uuidString)"
        suites.append(suiteName)
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = TokenStore(
            keychain: SharedKeychain(service: "vivid.tests.download-sync-scope.\(name).\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://a.example.test")
        await store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")
        await store.setProfileId("profile-a")
        await store.setProfileToken("proof-a")
        return store
    }

    /// An API whose every request goes to the recording stub, on v1 paths.
    private func api(_ store: TokenStore) -> VividAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncScopeStub.self]
        let client = HTTPClient(
            apiDiscovery: SiloAPIDiscovery(legacyOnly: true),
            session: URLSession(configuration: configuration),
            tokenStore: store
        )
        return VividAPI(http: client, tokenStore: store)
    }

    private static let calls: [(name: String, run: @Sendable (VividAPI, CapturedOrdinaryRequestAuth) async throws -> Void)] = [
        ("progress batch", { api, auth in
            let item = SyncProgressItem(mediaItemId: "item-1", position: 60, duration: 600, forceOverwrite: false,
                                        updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            _ = try await api.syncProgressBatch(items: [item], auth: auth)
        }),
        ("watched", { api, auth in try await api.setWatched(contentId: "item-1", played: true, expectedAuth: auth) }),
        ("progress deltas", { api, auth in _ = try await api.pullProgressDeltas(since: "cursor-1", auth: auth) }),
        ("current progress", { api, auth in _ = try await api.currentProgress(mediaItemIds: ["item-1"], auth: auth) }),
        ("start monitoring", { api, auth in
            let request = CreateSubscriptionRequest(seriesId: "series-1", mode: "every_season", seasonNumbers: nil,
                                                    deleteWatched: false, maxStorageBytes: 0)
            _ = try await api.createSubscription(request, auth: auth)
        }),
        ("change monitoring", { api, auth in
            let request = UpdateSubscriptionRequest(mode: nil, seasonNumbers: nil, deleteWatched: true,
                                                    maxStorageBytes: nil, active: nil)
            _ = try await api.updateSubscription(id: "subscription-1", request, auth: auth)
        }),
        ("monitoring sync", { api, auth in try await api.syncSubscriptions(auth: auth) }),
        ("stop monitoring", { api, auth in try await api.deleteSubscription(id: "subscription-1", auth: auth) }),
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

    // MARK: Pinned requests

    func testASignInChangeAfterTheWorkStartedSendsNothing() async throws {
        for change in Self.changes {
            for call in Self.calls {
                SyncScopeStub.reset()
                let store = try await signedInStore("refused")
                let captured = await store.captureOrdinaryRequestAuth()
                let auth = try XCTUnwrap(captured)
                let api = api(store)
                await change.apply(store)
                do {
                    try await call.run(api, auth)
                    XCTFail("\(change.name), \(call.name): the request went ahead")
                } catch {
                    guard case HTTPError.requestIdentityChanged? = error as? HTTPError else {
                        XCTFail("\(change.name), \(call.name): \(error)")
                        continue
                    }
                }
                XCTAssertTrue(SyncScopeStub.requests.isEmpty, "\(change.name), \(call.name): nothing is sent")
                await store.clearTokens()
            }
        }
    }

    func testTheScopesOwnSignInStillSends() async throws {
        let store = try await signedInStore("sends")
        let captured = await store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)
        let api = api(store)

        let registered = try await api.syncSubscriptions(auth: auth)
        try await api.deleteSubscription(id: "subscription-1", auth: auth)
        try await api.setWatched(contentId: "item-1", played: true, expectedAuth: auth)

        XCTAssertEqual(registered, 2)
        let requests = SyncScopeStub.requests
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "POST /api/v1/downloads/subscriptions/sync",
            "DELETE /api/v1/downloads/subscriptions/subscription-1",
            "POST /api/v1/watched/item-1",
        ])
        for request in requests {
            XCTAssertEqual(request.url?.host, "a.example.test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
        }
        await store.clearTokens()
    }

    // MARK: Stop Monitoring

    func testStopMonitoringDropsTheLocalCopyOnlyWhenTheServerHasNoSubscription() {
        XCTAssertTrue(DownloadEngine.MonitoringRules.deleteRemovesLocalCopy(after: HTTPError.http(statusCode: 404, body: nil)))
        let kept: [Error] = [
            HTTPError.http(statusCode: 500, body: nil),
            HTTPError.http(statusCode: 401, body: nil),
            HTTPError.network(underlying: URLError(.notConnectedToInternet)),
            HTTPError.requestIdentityChanged,
            URLError(.timedOut),
        ]
        for error in kept {
            XCTAssertFalse(DownloadEngine.MonitoringRules.deleteRemovesLocalCopy(after: error), "\(error)")
        }
    }

    /// The server's answer is added once and then replaces the saved copy,
    /// which is how it reaches the scope that asked even after a switch.
    func testTheServersSubscriptionIsAddedThenReplaced() {
        func subscription(deleteWatched: Bool) -> DownloadEngine.ServerSubscription {
            DownloadEngine.ServerSubscription(
                id: "subscription-1", seriesId: "series-1", mode: "every_season", targetSeason: nil, seasonNumbers: nil,
                deleteWatched: deleteWatched, maxStorageBytes: 0, active: true, createdAt: nil, updatedAt: nil
            )
        }
        var saved: [MonitoredSeries] = []
        DownloadEngine.MonitoringRules.mirror(subscription(deleteWatched: false), seriesTitle: "Series", into: &saved)
        DownloadEngine.MonitoringRules.mirror(subscription(deleteWatched: true), seriesTitle: "Series", into: &saved)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.deleteWatched, true)
        XCTAssertEqual(saved.first?.seriesTitle, "Series")
    }
}

/// Records every request and answers 200: `{"registered":2}` for the
/// monitoring sync and an empty JSON object for anything else.
private final class SyncScopeStub: URLProtocol {
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
        let body = request.url?.path.hasSuffix("/subscriptions/sync") == true
            ? Data(#"{"registered":2}"#.utf8)
            : Data("{}".utf8)
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
