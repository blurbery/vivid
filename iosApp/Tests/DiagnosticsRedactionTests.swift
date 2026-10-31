import XCTest
@testable import Vivid

/// Hosts, credentials, paths and media names are replaced in rendered lines,
/// while the route and ordinary words stay readable.
final class DiagnosticsRedactionTests: XCTestCase {
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

    func testHTTPSURLHostIsHashedAndQueryDropped() throws {
        let rendered = try line("HTTP 404 GET https://media.example.com/api/v1/settings/card_overlays?probe=1")
        XCTAssertFalse(rendered.contains("media.example.com"))
        XCTAssertFalse(rendered.contains("probe=1"))
        XCTAssertTrue(rendered.contains("[host:"))
        XCTAssertTrue(rendered.contains("/api/v1/settings/card_overlays"))
    }

    func testWebSocketURLHostIsHashed() throws {
        let rendered = try line(
            "loop failed UserInfo={NSErrorFailingURLStringKey=wss://media.example.com/api/v1/playback/sessions/abc/realtime}")
        XCTAssertFalse(rendered.contains("media.example.com"))
        XCTAssertTrue(rendered.contains("wss://[host:"))
    }

    func testLoopbackURLStaysLiteral() throws {
        XCTAssertTrue(try line("local playlist ready http://127.0.0.1/master.m3u8").contains("http://127.0.0.1/master.m3u8"))
    }

    func testEmailIsRedacted() throws {
        let rendered = try line("signup failed for person@example.org retrying")
        XCTAssertFalse(rendered.contains("person@example.org"))
        XCTAssertTrue(rendered.contains("[redacted_email]"))
    }

    func testUsernameKeyValueIsRedacted() throws {
        let rejected = try line("login rejected username=admin2 attempts=3")
        XCTAssertFalse(rejected.contains("admin2"))
        XCTAssertTrue(rejected.contains("username=[redacted]"))
        XCTAssertFalse(try line("login: someperson failed").contains("someperson"))
    }

    func testRegisteredBareHostnameIsHashed() throws {
        DiagLog.registerSensitiveHost("bare-host.example.net")
        let rendered = try line("reachability probe for bare-host.example.net timed out")
        XCTAssertFalse(rendered.contains("bare-host.example.net"))
        XCTAssertTrue(rendered.contains("[host:"))
    }

    func testRegisteredHostThatIsSubstringOfItsTokenTerminates() throws {
        DiagLog.registerSensitiveHost("host")
        let rendered = try line("connect to host failed")
        XCTAssertTrue(rendered.contains("[host:"))
        XCTAssertFalse(rendered.contains("to host failed"))
    }

    func testBearerTokenStaysRedacted() throws {
        XCTAssertFalse(try line("request sent Authorization: Bearer abcdefghijklmnop").contains("abcdefghijklmnop"))
    }

    func testHTTPClientDebugHeaderProfileAndTokensAreRedacted() throws {
        let rendered = try line(
            "\u{2192} GET /api/v1/library headers=[auth(\u{2026}9f8e7d), profileId=prof-abc-123, profileToken(\u{2026}a1b2c3), device=tvos]")
        for secret in ["9f8e7d", "a1b2c3", "prof-abc-123"] {
            XCTAssertFalse(rendered.contains(secret), secret)
        }
        XCTAssertTrue(rendered.contains("auth(\u{2026}[redacted])"))
        XCTAssertTrue(rendered.contains("profileToken(\u{2026}[redacted])"))
        XCTAssertTrue(rendered.contains("profileId=[redacted]"))
        XCTAssertTrue(rendered.contains("device=tvos"))
    }

    func testURLPathMediaNameAndItemIdentifierAreRedacted() throws {
        let rendered = try line(
            "stream open https://media.example.com/Videos/9f83ba21c0de44aa77b1c0de44aa77b1/Movie.Name.2019.mkv?k=1")
        for leak in ["media.example.com", "Movie.Name.2019", ".mkv", "9f83ba21c0de44aa77b1c0de44aa77b1"] {
            XCTAssertFalse(rendered.contains(leak), leak)
        }
        for kept in ["/Videos/", "[redacted_media_name]", "[redacted_id]"] {
            XCTAssertTrue(rendered.contains(kept), kept)
        }
    }

    func testURLPathAPIVocabularyIsNotMistakenForAnIdentifier() throws {
        XCTAssertTrue(try line("HTTP 200 GET https://media.example.com/api/v1/settings/card_overlays")
            .contains("/api/v1/settings/card_overlays"))
    }

    func testFilesystemPathsAndBareMediaNamesAreRedacted() throws {
        let download = try line("download finished /Users/person/Movies/Show Name S01E01.mkv ok")
        XCTAssertFalse(download.contains("person"))
        XCTAssertFalse(download.contains("Show Name"))
        XCTAssertTrue(download.contains("ok"))

        let sidecar = try line("sidecar attached Movie Title (2024).en.srt count=2")
        XCTAssertFalse(sidecar.contains("Movie Title"))
        XCTAssertFalse(sidecar.contains("2024"))
        XCTAssertTrue(sidecar.contains("count=2"))
    }

    func testEmptyURLHostStaysEmpty() throws {
        let rendered = try line("upgrade failed for https:///x")
        XCTAssertTrue(rendered.contains("https:///x"))
        XCTAssertFalse(rendered.contains("[host:"))
    }

    func testEscapedTokenValueRunsPastUnicodeLineSeparators() throws {
        let secret = UUID().uuidString
        let rendered = try line("body=\\\"token\\\":\\\"part\u{2028}\(secret)\\\"} end")
        XCTAssertFalse(rendered.contains(secret))
        XCTAssertTrue(rendered.contains("token=[redacted]"))
    }

    func testCamelCaseTokenKeyValuesAreRedacted() throws {
        let rendered = try line("refresh accessToken=aaa.bbb.ccc refreshToken: ddd-eee-fff done")
        XCTAssertFalse(rendered.contains("aaa.bbb.ccc"))
        XCTAssertFalse(rendered.contains("ddd-eee-fff"))
        XCTAssertTrue(rendered.contains("accessToken=[redacted]"))
        XCTAssertTrue(rendered.contains("refreshToken=[redacted]"))
    }
}
