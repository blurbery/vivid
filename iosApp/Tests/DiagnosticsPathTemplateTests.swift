import XCTest
@testable import Vivid

/// Templated paths keep the route and lose every identifying segment. The
/// oracle below is written independently of the code under test.
final class DiagnosticsPathTemplateTests: XCTestCase {
    private func assertTemplated(_ input: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let output = DiagnosticsPathTemplate.templatedPath(forRawPath: input)
        XCTAssertEqual(output, expected, input, file: file, line: line)
        assertNoPrivateSegments(output, file: file, line: line)
    }

    // MARK: - Oracle

    private static let idPrefixes = [
        "account", "attempt", "content", "correlation", "device", "file", "item", "library", "media",
        "playback", "plan", "profile", "ps", "req", "request", "run", "server", "session", "subtitle",
        "track", "user",
    ]

    private func matches(_ pattern: String, _ text: String, caseInsensitive: Bool = false) -> Bool {
        text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
    }

    private func assertNoPrivateSegments(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(path.contains("?") || path.contains("#"), "query or fragment in \(path)", file: file, line: line)
        let lowered = path.lowercased()
        for prefix in ["/users/", "/private/", "/var/mobile/", "/data/user/"] {
            XCTAssertFalse(lowered.hasPrefix(prefix), "file-system prefix in \(path)", file: file, line: line)
        }
        for segment in path.split(separator: "/") {
            var decoded = String(segment)
            var stable = false
            for _ in 0..<4 {
                guard let next = decoded.removingPercentEncoding else { break }
                if next == decoded {
                    stable = true
                    break
                }
                decoded = next
            }
            guard stable else {
                XCTFail("undecodable segment \(segment) in \(path)", file: file, line: line)
                continue
            }
            XCTAssertFalse(decoded.contains("/") || decoded == "." || decoded == "..",
                           "relative or nested segment \(segment) in \(path)", file: file, line: line)
            let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "!\"'(),.:;[]"))
            if trimmed.isEmpty || matches("^\\{[a-z][a-z0-9_]*\\}$", trimmed) || matches("^[vV][0-9]+$", trimmed) { continue }
            let pieces = [trimmed] + trimmed.components(separatedBy: CharacterSet(charactersIn: "(),.:;[]")).filter { !$0.isEmpty }
            for piece in pieces {
                let identifying =
                    matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", piece, caseInsensitive: true)
                    || matches("^[0-9]+$", piece)
                    || matches("^(" + Self.idPrefixes.joined(separator: "|") + ")[_-][A-Za-z0-9_-]{4,}$", piece, caseInsensitive: true)
                    || matches("^[0-9a-fA-F]{16,}$", piece)
                    || matches("^[A-Za-z0-9_-]{20,}$", piece)
                XCTAssertFalse(identifying, "identifying piece \(piece) in \(path)", file: file, line: line)
            }
        }
    }

    // MARK: - Tests

    func testStaticRoutesArePreserved() {
        for path in ["/api/v1/health", "/api/v1/settings/values/effective", "/api/v1/playback/start",
                     "/api/v1/catalog/filters", "/api/v1/collections/groups/order"] {
            assertTemplated(path, path)
        }
    }

    func testSettingsKeySegmentSurvivesWhenTheCollectorAllowsIt() {
        assertTemplated("/api/v1/settings/values/nav_shortcuts", "/api/v1/settings/values/nav_shortcuts")
    }

    func testIdentifierSegmentsAreTemplated() {
        assertTemplated("/v1/reports/01H8XK3P2Q", "/v1/reports/{id}")
        assertTemplated("/api/v1/items/12345", "/api/v1/items/{id}")
        assertTemplated("/api/v1/catalog/items/550e8400-e29b-41d4-a716-446655440000", "/api/v1/catalog/items/{id}")
        assertTemplated("/api/v1/home/dismissals/continue_watching/9", "/api/v1/home/dismissals/continue_watching/{id}")
    }

    func testStaticRoutesTheCollectorWouldRejectAreTemplated() {
        assertTemplated("/api/v1/library-playback-prefs", "/api/v1/{id}")
        assertTemplated("/api/v1/subtitle-prefs", "/api/v1/{id}")
        assertTemplated("/api/v1/settings/subtitle_appearance/effective", "/api/v1/settings/{id}/effective")
    }

    func testUUIDSegmentsOfAnyVersionAreTemplated() {
        for path in ["/x/550e8400-e29b-41d4-a716-446655440000", "/x/00000000-0000-0000-0000-000000000000",
                     "/x/pre-550e8400-e29b-91d4-c716-446655440000"] {
            assertTemplated(path, "/x/{id}")
        }
    }

    func testNumericHexAndOpaqueSegmentsAreTemplated() {
        for path in ["/x/12345", "/x/0", "/x/abcdef0123456789", "/x/abcdefghijklmnopqrst"] {
            assertTemplated(path, "/x/{id}")
        }
    }

    func testPrivateIDPrefixSegmentsAreTemplated() {
        for path in ["/x/session_abcd", "/x/item-90210", "/x/ps_12ab34cd"] {
            assertTemplated(path, "/x/{id}")
        }
    }

    func testDottedSubPartsAreTemplated() {
        assertTemplated("/x/12345.json", "/x/{id}")
        assertTemplated("/x/(4242)", "/x/{id}")
    }

    func testVersionAndAlreadyTemplatedSegmentsAreLeftAlone() {
        assertTemplated("/v1/v2/v10/health", "/v1/v2/v10/health")
        assertTemplated("/api/v1/items/{id}", "/api/v1/items/{id}")
    }

    func testPercentEncodedAndRelativeSegmentsAreTemplated() {
        assertTemplated("/api/v1/library/tv%20shows", "/api/v1/library/{id}")
        assertTemplated("/api/v1/library/a%2Fb", "/api/v1/library/{id}")
        assertTemplated("/api/v1/./items", "/api/v1/{id}/items")
        assertTemplated("/api/v1/../items", "/api/v1/{id}/items")
    }

    func testFilesystemPrefixesAreFullyTemplated() {
        assertTemplated("/users/bob/library", "/{id}/{id}/{id}")
        assertTemplated("/var/mobile/Containers/Data", "/{id}/{id}/{id}/{id}")
        assertTemplated("/private/var/tmp", "/{id}/{id}/{id}")
        assertTemplated("/data/user/0/pkg", "/{id}/{id}/{id}/{id}")
    }

    func testQueryStringsAndFragmentsAreStripped() {
        assertTemplated("/api/v1/items/12345?api_key=secret", "/api/v1/items/{id}")
        assertTemplated("/api/v1/catalog?q=bourne&page=2", "/api/v1/catalog")
        assertTemplated("/api/v1/items/12345#frag", "/api/v1/items/{id}")
        assertTemplated("/api/v1/health?", "/api/v1/health")
    }

    func testURLEntryPointDropsHostQueryAndFragment() throws {
        let url = try XCTUnwrap(URL(string: "https://media.example.com:8096/api/v1/items/12345?token=abc#top"))
        let output = DiagnosticsPathTemplate.templatedPath(for: url)
        XCTAssertEqual(output, "/api/v1/items/{id}")
        XCTAssertFalse(output.contains("example.com"))
        assertNoPrivateSegments(output)
    }

    func testTemplatingIsIdempotent() {
        for path in ["/api/v1/items/12345", "/v1/reports/01H8XK3P2Q", "/users/bob/library", "/api/v1/health"] {
            let once = DiagnosticsPathTemplate.templatedPath(forRawPath: path)
            XCTAssertEqual(DiagnosticsPathTemplate.templatedPath(forRawPath: once), once, path)
        }
    }
}
