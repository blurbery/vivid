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
    static var expectedHost = "api.introdb.app"
    static var expectedIDName = "imdb_id"
    static var expectedID = "tt0944947"
    static var code = 200
    static var body = #"{"imdb_id":"tt0944947","season":1,"episode":1,"intro":{"start_ms":1000,"end_ms":60000},"outro":{"start_ms":1700000,"end_ms":1800000}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        precondition(request.url?.host == Self.expectedHost)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == Self.expectedIDName }?.value == Self.expectedID)
        precondition(query.filter { ["imdb_id", "tmdb_id"].contains($0.name) }.count == 1)
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
        MockIntroDB.body = #"{"imdb_id":"tt0944947","season":1,"episode":1,"intro":{"start_ms":30000,"end_ms":60000},"outro":{"start_ms":1700000,"end_ms":1800000},"recap":{"start_ms":0,"end_ms":20000}}"#
        let separate = try await client().segments(for: identity)
        precondition(separate?.recap?.range(duration: 1800)?.start == 0)
        precondition(separate?.recap?.range(duration: 1800)?.end == 20)
        precondition(separate?.intro?.range(duration: 1800)?.start == 30)
        precondition(separate?.outro?.range(duration: 1800)?.start == 1700)
        MockIntroDB.expectedHost = "api.theintrodb.org"
        MockIntroDB.expectedIDName = "tmdb_id"
        MockIntroDB.expectedID = "1399"
        MockIntroDB.body = #"{"tmdb_id":1399,"intro":[{"start_ms":10000,"end_ms":20000}],"credits":[{"start_ms":90000,"end_ms":null}],"recap":[{"start_ms":null,"end_ms":5000}]}"#
        let tmdbOnly = VividIntroDBClient.Episode(imdbID: "", season: 1, episode: 1, tmdbID: 1399)
        let fallbackClient = client()
        let before = MockIntroDB.count
        let noIMDb = try await fallbackClient.segments(for: tmdbOnly)
        precondition(noIMDb == nil && MockIntroDB.count == before, "Skip only the IMDb provider")
        let tmdbResult = try await fallbackClient.fallbackSegments(for: tmdbOnly)
        precondition(tmdbResult?.intro?.range(duration: 100)?.end == 20)
        precondition(tmdbResult?.outro?.range(duration: 100)?.end == 100)
        precondition(tmdbResult?.recap?.range(duration: 100)?.end == 5)
        _ = try await fallbackClient.fallbackSegments(for: tmdbOnly)
        precondition(MockIntroDB.count == before + 1, "TMDB results are cached")
        let primary = VividIntroDBClient.Segments(imdb_id: "", season: 1, episode: 1,
            intro: .init(start_ms: 30000, end_ms: 40000), outro: nil, tmdb_id: 1399)
        let merged = primary.fillingMissing(from: tmdbResult)
        precondition(merged.intro?.range(duration: 100)?.start == 30, "Fallback cannot replace existing intro")
        precondition(merged.outro?.range(duration: 100)?.start == 90)
        precondition(merged.recap?.range(duration: 100)?.end == 5)
        let other = VividIntroDBClient.Segments(imdb_id: "", season: 1, episode: 1,
            intro: nil, outro: tmdbResult?.outro, tmdb_id: 999)
        precondition(primary.fillingMissing(from: other).outro == nil, "Empty IMDb must not match different series")
        let anotherEpisode = VividIntroDBClient.Segments(imdb_id: "", season: 1, episode: 2,
            intro: nil, outro: tmdbResult?.outro, tmdb_id: 1399)
        precondition(primary.fillingMissing(from: anotherEpisode).outro == nil)
        let both = VividIntroDBClient.Episode(imdbID: "tt0944947", season: 1, episode: 1, tmdbID: 1399)
        _ = try await client().fallbackSegments(for: both)
        MockIntroDB.body = #"{"tmdb_id":999,"intro":[{"start_ms":1000,"end_ms":2000}]}"#
        let wrongSeries = try await client().fallbackSegments(for: tmdbOnly)
        precondition(wrongSeries == nil, "Reject mismatched TMDB response")
        MockIntroDB.body = #"{"intro":[{"start_ms":1000,"end_ms":2000}]}"#
        let unidentified = try await client().fallbackSegments(for: tmdbOnly)
        precondition(unidentified == nil, "TMDB response must identify the requested series")
        MockIntroDB.expectedIDName = "imdb_id"
        MockIntroDB.expectedID = "tt0944947"
        let imdbFallback = try await client().fallbackSegments(for: identity)
        precondition(imdbFallback?.intro?.range(duration: 100)?.end == 2)
        let invalidIDs = VividIntroDBClient.Episode(imdbID: "", season: 1, episode: 1, tmdbID: -1)
        let invalidResult = try await client().fallbackSegments(for: invalidIDs)
        precondition(invalidResult == nil)
        print("IntroDB checks passed: anonymous requests, milliseconds, bounds, TMDB-only fallback, provider merging, separate intro/credits/recap, cache, invalid IDs, missing data, rate limiting and episode identity.")
    }
}
SWIFT
} > "$intro_tmp/check.swift"
xcrun swiftc -parse-as-library "$intro_tmp/check.swift" -o "$intro_tmp/check"
"$intro_tmp/check"
