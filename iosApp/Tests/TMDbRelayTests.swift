import XCTest
@testable import Vivid

final class TMDbRelayTests: XCTestCase {
    func testRequestsGoToTheRelayWithNoCredential() throws {
        let request = TVTMDbStore.urlRequest("discover/tv", query: ["page": "1", "with_networks": "213"])
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "tmdb.vividapp.co")
        XCTAssertEqual(url.path, "/3/discover/tv")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        XCTAssertEqual(Set(names), ["page", "with_networks"])
    }

    func testARequestWithoutAQueryHasNone() throws {
        let url = try XCTUnwrap(TVTMDbStore.urlRequest("movie/7").url)
        XCTAssertEqual(url.absoluteString, "https://tmdb.vividapp.co/3/movie/7")
    }

    func testEveryFailureIsTemporary() {
        XCTAssertNil(TVTMDbStore.failure(status: 200))
        // The relay answers 503 for its own token problems. Nothing may ever
        // tell someone a key is wrong, because they don't have one.
        for status in [301, 400, 401, 403, 404, 429, 500, 502, 503] {
            XCTAssertEqual(TVTMDbStore.failure(status: status), .unavailable, "\(status)")
        }
    }
}
