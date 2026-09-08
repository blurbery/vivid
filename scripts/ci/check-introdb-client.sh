#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
intro_tmp=$(mktemp -d /private/tmp/vivid-introdb-check.XXXXXX)
trap 'rm -rf "$intro_tmp"' EXIT
{
    echo 'import Foundation'
    echo 'struct TimeRange { let start: Double; let end: Double }'
    sed -n '/^actor VividIntroDBClient {/,$p' iosApp/iosApp/Screens/Player/PlayerSettings.swift
    cat <<'SWIFT'
final class MockIntroDB: URLProtocol, @unchecked Sendable {
    static var count = 0
    static var code = 200
    static var body = #"{"imdb_id":"tt0944947","season":1,"episode":1,"intro":{"start_ms":1000,"end_ms":60000},"outro":{"start_ms":1700000,"end_ms":1800000}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        precondition(request.url?.host == "api.introdb.app")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.count == 3)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Test {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockIntroDB.self]
        func client() -> VividIntroDBClient { VividIntroDBClient(session: URLSession(configuration: config)) }
        let identity = VividIntroDBClient.Episode(imdbID: "tt0944947", season: 1, episode: 1)
        let service = client()
        let result = try await service.segments(for: identity)
        precondition(result?.intro?.range(duration: 1800)?.end == 60)
        precondition(result?.outro?.range(duration: 1800)?.end == 1800)
        precondition(result?.outro?.range(duration: 1000) == nil)
        _ = try await service.segments(for: identity)
        precondition(MockIntroDB.count == 1, "Repeated episode lookup should use cache")
        let invalid = try await service.segments(for: .init(imdbID: "invalid", season: 1, episode: 1))
        precondition(invalid == nil && MockIntroDB.count == 1)
        MockIntroDB.code = 404
        let missing = try await client().segments(for: identity)
        precondition(missing == nil)
        MockIntroDB.code = 429
        let limited = try await client().segments(for: identity)
        precondition(limited == nil)
        MockIntroDB.code = 200
        MockIntroDB.body = #"{"imdb_id":"tt0944947","season":1,"episode":2,"intro":null,"outro":null}"#
        let mismatch = try await client().segments(for: identity)
        precondition(mismatch == nil, "Never apply another episode's timestamps")
        precondition(VividIntroDBClient.Segment(start_ms: -1, end_ms: 1000).range(duration: 100) == nil)
        precondition(VividIntroDBClient.Segment(start_ms: 2000, end_ms: 1000).range(duration: 100) == nil)
        print("IntroDB checks passed: anonymous requests, milliseconds, bounds, cache, invalid IDs, missing data, rate limiting and episode identity.")
    }
}
SWIFT
} > "$intro_tmp/check.swift"
xcrun swiftc -parse-as-library "$intro_tmp/check.swift" -o "$intro_tmp/check"
"$intro_tmp/check"
