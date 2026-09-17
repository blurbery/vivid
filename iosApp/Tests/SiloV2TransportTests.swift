import XCTest
@testable import Vivid

final class SiloV2TransportTests: XCTestCase {
    func testDiscoveredDownloadsFollowCursorAndMergePages() async throws {
        let http = await makeClient()
        SiloV2TransportStub.configure { request in
            switch request.url!.path {
            case "/api/v2/system/info": return (200, [:], #"{"api_major":2}"#)
            case "/api/v2/downloads":
                let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
                if cursor == nil {
                    return (200, [:], #"{"items":[{"id":"download-a"}],"page":{"has_more":true,"next_cursor":"page-2"}}"#)
                }
                XCTAssertEqual(cursor, "page-2")
                return (200, [:], #"{"items":[{"id":"download-b"}],"page":{"has_more":false}}"#)
            default: throw URLError(.badURL)
            }
        }
        let response = try await http.requestData(method: "GET", path: "/api/v1/downloads")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        let rows = try XCTUnwrap(document["downloads"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, ["download-a", "download-b"])
        let requests = SiloV2TransportStub.requests()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/v2/system/info", "/api/v2/downloads", "/api/v2/downloads"])
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "X-Profile-Id"), "profile-a")
    }

    func testSubscriptionPatchUsesValidatorFromPrecedingGet() async throws {
        let http = await makeClient()
        SiloV2TransportStub.configure { request in
            if request.url!.path == "/api/v2/system/info" { return (200, [:], #"{"api_major":2}"#) }
            XCTAssertEqual(request.url!.path, "/api/v2/downloads/subscriptions/sub-a")
            if request.httpMethod == "GET" {
                return (200, ["ETag": "\"revision-7\""], #"{"id":"sub-a","active":true}"#)
            }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"revision-7\"")
            return (200, [:], #"{"id":"sub-a","active":false}"#)
        }
        _ = try await http.requestData(method: "PATCH", path: "/api/v1/downloads/subscriptions/sub-a", body: Data(#"{"active":false}"#.utf8))
        XCTAssertEqual(SiloV2TransportStub.requests().map(\.httpMethod), ["GET", "GET", "PATCH"])
    }

    func testDiscoveryTransportFailureKeepsHTTPNetworkErrorContract() async throws {
        let http = await makeClient()
        SiloV2TransportStub.configure { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await http.requestData(method: "GET", path: "/api/v1/downloads")
            XCTFail("Expected a transport failure")
        } catch HTTPError.network(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(SiloV2TransportStub.requests().count, 1)
    }

    func testUnsupportedDiscoveryRemainsCompatibilityFailure() async throws {
        let http = await makeClient()
        SiloV2TransportStub.configure { _ in (503, [:], "{}") }
        do {
            _ = try await http.requestData(method: "GET", path: "/api/v1/downloads")
            XCTFail("Expected a compatibility failure")
        } catch SiloAPICompatibility.Failure.unsupportedStatus(let status) {
            XCTAssertEqual(status, 503)
        }
        XCTAssertEqual(SiloV2TransportStub.requests().count, 1)
    }

    private func makeClient() async -> HTTPClient {
        let name = "SiloV2TransportTests." + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                                defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server-a")
        await tokens.setServerUrl("http://silo-v2-test.invalid")
        await tokens.setProfileId("profile-a")
        await tokens.saveTokens(accessToken: "fake", refreshToken: "dummy")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SiloV2TransportStub.self]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            UserDefaults().removePersistentDomain(forName: name)
        }
        return HTTPClient(apiDiscovery: SiloAPIDiscovery(), session: session, tokenStore: tokens)
    }
}

private final class SiloV2TransportStub: URLProtocol {
    typealias Reply = (Int, [String: String], String)
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
            let (status, headers, body) = try Self.response(for: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: headers.merging(["Content-Type": "application/json"]) { existing, _ in existing })!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
