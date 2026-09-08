#!/bin/bash
# Offline API-contract checks using the production client and an isolated URLProtocol.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d /private/tmp/vivid-seerr-check.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
source=(root/'iosApp/iosApp/tvOS/Requests/TVSeerrConnection.swift').read_text()
source=source.split('@Observable @MainActor')[0].replace('#if os(tvOS) || os(iOS)\n','',1)
(temporary/'Client.swift').write_text(source)
(temporary/'Models.swift').write_text((root/'iosApp/iosApp/Networking/RequestsModels.swift').read_text())
PY
cat > "$test_dir/Checks.swift" <<'SWIFT'
import Foundation

final class Stub: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int, String) = { _ in fatalError("Unexpected request") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct Checks {
    static func client(_ username: String = "test@example.invalid") throws -> TVSeerrClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return try TVSeerrClient(configuration: TVSeerrConfiguration(url: "https://example.invalid/seerr", username: username, password: "fake-test-only"), sessionConfiguration: config)
    }
    static func main() async throws {
        for invalid in ["file:///tmp/test", "https://name:secret@example.invalid", "https://example.invalid?secret=x", "https://example.invalid#fragment", "example.invalid"] {
            do { _ = try TVSeerrClient.validatedURL(invalid); fatalError("Accepted invalid URL") }
            catch is TVSeerrError {}
        }
        var loginCount = 0
        var searchCount = 0
        Stub.handler = { request in
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            let path = request.url!.path
            if path == "/seerr/api/v1/auth/local" {
                loginCount += 1
                return (200, "{\"permissions\":32}")
            }
            precondition(path == "/seerr/api/v1/search")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value == "a & b")
            searchCount += 1
            if searchCount == 1 { return (401, "{}") }
            return (200, """
            {"page":1,"totalPages":1,"totalResults":4,"results":[
            {"id":1,"mediaType":"movie","title":"Available","mediaInfo":{"status":5}},
            {"id":2,"mediaType":"tv","name":"Pending","mediaInfo":{"status":2,"requests":[{"id":44,"status":1,"is4k":false}]}},
            {"id":3,"mediaType":"person","name":"Person"},
            {"id":4,"mediaType":"movie","title":"Blocked","mediaInfo":{"status":6}}]}
            """)
        }
        let local = try client()
        let page = try await local.search("a & b")
        precondition(loginCount == 2 && searchCount == 2)
        precondition(page.results.count == 3)
        precondition(page.results[0].availability == .available)
        precondition(page.results[1].mediaType == .series && page.results[1].request.status == .pending)
        precondition(!page.results[2].request.requestable)
        Stub.handler = { request in
            switch request.url!.path {
            case "/seerr/api/v1/auth/jellyfin": return (200, "{\"permissions\":0}")
            case "/seerr/api/v1/tv/8": return (200, "{\"id\":8,\"name\":\"Series\",\"seasons\":[{\"seasonNumber\":0},{\"seasonNumber\":1}],\"externalIds\":{\"tvdbId\":123}}")
            default: fatalError("Wrong login or detail route")
            }
        }
        let imported = try client("imported-user")
        let detail = try await imported.detail(type: .series, id: 8)
        precondition(detail.title == "Series" && detail.numberOfSeasons == 1 && !detail.request.requestable)
        Stub.handler = { request in
            precondition(request.url!.path == "/seerr/api/v1/request" && request.httpMethod == "POST")
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = stream.read(&bytes, maxLength: bytes.count)
            let body = try JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as! [String: Any]
            precondition(body["mediaType"] as? String == "tv" && body["seasons"] as? String == "all")
            precondition(body["mediaId"] as? Int == 8)
            return (201, "{\"id\":55,\"status\":1}")
        }
        let record = try await local.create(CreateRequestInput(mediaType: .series, tmdbId: 8, tvdbId: nil, imdbId: nil, title: "Series", year: nil, overview: nil, posterPath: nil, backdropPath: nil))
        precondition(record.id == "55" && record.status == .pending)
        Stub.handler = { _ in (403, "fake-test-only") }
        do { try await client().authenticate(); fatalError("Accepted failed login") }
        catch let error as TVSeerrError { precondition(!error.localizedDescription.contains("fake-test-only")) }
        print("PASS: URL validation, private headers, base paths, query encoding, session renewal, local/imported login routes, media/permission mapping, TV request body and redacted errors")
    }
}
SWIFT
swiftc -swift-version 5 -parse-as-library "$test_dir/Client.swift" "$test_dir/Models.swift" "$test_dir/Checks.swift" -o "$test_dir/checks"
"$test_dir/checks"
