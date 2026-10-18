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
}
