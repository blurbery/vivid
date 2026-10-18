import XCTest
@testable import Vivid

final class TMDbRelayTests: XCTestCase {
    func testWithoutAKeyRequestsGoToTheRelayWithNoCredential() throws {
        let request = TVTMDbStore.urlRequest("discover/tv", credential: "", query: ["page": "1", "with_networks": "213"])
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "tmdb.vividapp.co")
        XCTAssertEqual(url.path, "/3/discover/tv")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        XCTAssertEqual(Set(names), ["page", "with_networks"])
    }

    func testAnOwnAPIKeyGoesOnlyToTMDb() throws {
        let key = String(repeating: "a", count: 32)
        let request = TVTMDbStore.urlRequest("movie/7", credential: key)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.themoviedb.org")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value, key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnOwnReadTokenGoesOnlyToTMDbInTheHeader() throws {
        let request = TVTMDbStore.urlRequest("movie/7", credential: "read-token")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "api.themoviedb.org")
        XCTAssertNil(url.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer read-token")
    }

    func testOnlyAnOwnKeyCanBeReportedAsInvalid() {
        XCTAssertNil(TVTMDbStore.failure(status: 200, usesOwnKey: false))
        XCTAssertNil(TVTMDbStore.failure(status: 200, usesOwnKey: true))
        // The relay answers 503 for its own token problems, but even a stray
        // 401 or 403 must never tell someone their key is wrong.
        for status in [401, 403, 404, 429, 500, 502, 503] {
            XCTAssertEqual(TVTMDbStore.failure(status: status, usesOwnKey: false), .unavailable, "\(status)")
        }
        XCTAssertEqual(TVTMDbStore.failure(status: 401, usesOwnKey: true), .invalidKey)
        XCTAssertEqual(TVTMDbStore.failure(status: 403, usesOwnKey: true), .invalidKey)
        XCTAssertEqual(TVTMDbStore.failure(status: 429, usesOwnKey: true), .unavailable)
        XCTAssertEqual(TVTMDbStore.failure(status: 302, usesOwnKey: true), .unavailable)
    }
}
