import XCTest
@testable import Vivid

/// Personal and secret values must never reach a rendered diagnostics line,
/// however they are spelt or wrapped.
final class DiagnosticsPIIRedactionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagLog.resetSensitiveHostsForTesting()
    }

    override func tearDown() {
        DiagLog.resetSensitiveHostsForTesting()
        super.tearDown()
    }

    private func line(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(
            DiagLog.renderedLine(level: .info, category: .lifecycle, tag: "Test", message: message),
            file: file, line: line)
    }

    private func secretKey(_ parts: String...) -> String { parts.joined(separator: "_") }

    func testUppercaseURLSchemeAndBracketedIPv6AreRedacted() throws {
        let token = UUID().uuidString
        let first = try line("request HTTPS://Media.Example.com/path?\(secretKey("access", "token"))=\(token)")
        XCTAssertFalse(first.lowercased().contains("media.example.com"))
        XCTAssertFalse(first.contains(token))
        XCTAssertTrue(first.contains("[host:"))

        let key = UUID().uuidString
        let second = try line("request https://[2001:db8::1234]/path?\(secretKey("api", "key"))=\(key)")
        XCTAssertFalse(second.contains("2001:db8::1234"))
        XCTAssertFalse(second.contains(key))
        XCTAssertTrue(second.contains("[host:"))
    }

    func testQuotedAndEscapedJSONSecretsAreRedacted() throws {
        let access = UUID().uuidString
        let apiKey = UUID().uuidString
        let username = UUID().uuidString + "\"" + UUID().uuidString
        let quoted = try JSONSerialization.data(withJSONObject: [
            secretKey("access", "token"): access,
            secretKey("api", "key"): apiKey,
            "username": username,
        ])
        let first = try line("body=" + String(decoding: quoted, as: UTF8.self))
        for value in [access, apiKey, username] {
            XCTAssertFalse(first.contains(value))
        }

        let refresh = UUID().uuidString
        let email = UUID().uuidString + "@example.org"
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [
            secretKey("refresh", "token"): refresh,
            "email": email,
        ]), as: UTF8.self).replacingOccurrences(of: "\"", with: "\\\"")
        let second = try line("error body=" + escaped)
        XCTAssertFalse(second.contains(refresh))
        XCTAssertFalse(second.contains(email))
    }

    func testHTTPErrorDescriptionNeverContainsURLOrResponseBody() throws {
        XCTAssertEqual(String(describing: HTTPError.invalidURL("https://private.example/api")), "invalid_url")
        let token = UUID().uuidString
        let email = UUID().uuidString + "@example.org"
        let body = String(decoding: try JSONSerialization.data(withJSONObject: [
            secretKey("access", "token"): token,
            "email": email,
        ]), as: UTF8.self)
        let error = HTTPError.http(statusCode: 401, body: body)
        XCTAssertEqual(String(describing: error), "http_error(status: 401)")
        let rendered = try XCTUnwrap(DiagLog.renderedLine(
            level: .error, category: .playback, tag: "HTTP", message: "request failed",
            attrs: ["reason": .error(error)]))
        XCTAssertFalse(rendered.contains(token))
        XCTAssertFalse(rendered.contains(email))
    }
}
