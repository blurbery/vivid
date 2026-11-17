import XCTest
@testable import Vivid

/// Plain HTTP servers work anywhere, but a request that started on HTTPS is
/// never redirected down to plain HTTP.
final class PlainHTTPRedirectGuardTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testRefusesHTTPSToPlainHTTP() {
        XCTAssertFalse(PlainHTTPRedirectGuard.allows(from: url("https://media.example.test/api"), to: url("http://media.example.test/api")))
        XCTAssertFalse(PlainHTTPRedirectGuard.allows(from: url("HTTPS://media.example.test/api"), to: url("HTTP://other.example.test/api")))
    }

    func testAllowsEverythingElse() {
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("http://media.example.test:8096/a"), to: url("http://media.example.test:8096/b")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("http://media.example.test/a"), to: url("https://media.example.test/a")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("https://media.example.test/a"), to: url("https://cdn.example.test/a")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("http://192.168.1.20:8096/a"), to: url("http://192.168.1.20:8096/b")))
    }

    /// ATS always let a redirect down to plain HTTP on a local address
    /// through, so that still works.
    func testAllowsHTTPSToPlainHTTPOnALocalAddress() {
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("https://192.168.1.20/a"), to: url("http://192.168.1.20/a")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("https://media.example.test/a"), to: url("http://nas:8096/a")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("https://nas.local/a"), to: url("http://nas.local/a")))
        XCTAssertTrue(PlainHTTPRedirectGuard.allows(from: url("https://[::1]/a"), to: url("http://[::1]/a")))
    }

    func testSessionDelegateFollowsOrEndsTheRedirect() throws {
        let task = URLSession.shared.dataTask(with: url("https://media.example.test/api"))
        defer { task.cancel() }
        let redirect = try XCTUnwrap(HTTPURLResponse(url: url("https://media.example.test/api"), statusCode: 302, httpVersion: nil, headerFields: nil))

        var followed: URLRequest?? = .none
        PlainHTTPRedirectGuard.SessionDelegate.shared.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: url("http://media.example.test/api"))
        ) { followed = .some($0) }
        XCTAssertEqual(followed, .some(nil))

        PlainHTTPRedirectGuard.SessionDelegate.shared.urlSession(
            URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: url("https://media.example.test/v2/api"))
        ) { followed = .some($0) }
        XCTAssertEqual(followed??.url, url("https://media.example.test/v2/api"))
    }
}
