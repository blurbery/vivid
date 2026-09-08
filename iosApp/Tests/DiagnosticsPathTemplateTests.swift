import XCTest
@testable import Vivid







final class DiagnosticsPathTemplateTests: XCTestCase {


    func testStaticRoutesArePreserved() {


        assertTemplated("/api/v1/health", equals: "/api/v1/health")
        assertTemplated("/api/v1/settings/values/effective", equals: "/api/v1/settings/values/effective")
        assertTemplated("/api/v1/playback/start", equals: "/api/v1/playback/start")
        assertTemplated("/api/v1/catalog/filters", equals: "/api/v1/catalog/filters")
        assertTemplated("/api/v1/collections/groups/order", equals: "/api/v1/collections/groups/order")
    }

    func testSettingsKeySegmentSurvivesWhenTheCollectorAllowsIt() {



        assertTemplated(
            "/api/v1/settings/values/nav_shortcuts",
            equals: "/api/v1/settings/values/nav_shortcuts"
        )
    }

    func testIdentifierSegmentsAreTemplated() {
        assertTemplated("/v1/reports/01H8XK3P2Q", equals: "/v1/reports/{id}")
        assertTemplated("/api/v1/items/12345", equals: "/api/v1/items/{id}")
        assertTemplated(
            "/api/v1/catalog/items/550e8400-e29b-41d4-a716-446655440000",
            equals: "/api/v1/catalog/items/{id}"
        )
        assertTemplated("/api/v1/home/dismissals/continue_watching/9", equals: "/api/v1/home/dismissals/continue_watching/{id}")
    }

    func testStaticRoutesTheCollectorWouldRejectAreTemplated() {




        assertTemplated("/api/v1/library-playback-prefs", equals: "/api/v1/{id}")
        assertTemplated("/api/v1/subtitle-prefs", equals: "/api/v1/{id}")
        assertTemplated(
            "/api/v1/settings/subtitle_appearance/effective",
            equals: "/api/v1/settings/{id}/effective"
        )
    }


    func testUUIDSegmentsOfAnyVersionAreTemplated() {


        assertTemplated("/x/550e8400-e29b-41d4-a716-446655440000", equals: "/x/{id}")
        assertTemplated("/x/00000000-0000-0000-0000-000000000000", equals: "/x/{id}")
        assertTemplated("/x/pre-550e8400-e29b-91d4-c716-446655440000", equals: "/x/{id}")
    }

    func testNumericHexAndOpaqueSegmentsAreTemplated() {
        assertTemplated("/x/12345", equals: "/x/{id}")
        assertTemplated("/x/0", equals: "/x/{id}")
        assertTemplated("/x/abcdef0123456789", equals: "/x/{id}")        // HEX_ID_SEGMENT, 16+
        assertTemplated("/x/abcdefghijklmnopqrst", equals: "/x/{id}")    // OPAQUE_ID_SEGMENT, 20+
    }

    func testPrivateIDPrefixSegmentsAreTemplated() {

        assertTemplated("/x/session_abcd", equals: "/x/{id}")
        assertTemplated("/x/item-90210", equals: "/x/{id}")
        assertTemplated("/x/ps_12ab34cd", equals: "/x/{id}")
    }

    func testDottedSubPartsAreTemplated() {


        assertTemplated("/x/12345.json", equals: "/x/{id}")
        assertTemplated("/x/(4242)", equals: "/x/{id}")
    }

    func testVersionAndAlreadyTemplatedSegmentsAreLeftAlone() {


        assertTemplated("/v1/v2/v10/health", equals: "/v1/v2/v10/health")
        assertTemplated("/api/v1/items/{id}", equals: "/api/v1/items/{id}")
    }

    func testPercentEncodedAndRelativeSegmentsAreTemplated() {


        assertTemplated("/api/v1/library/tv%20shows", equals: "/api/v1/library/{id}")
        assertTemplated("/api/v1/library/a%2Fb", equals: "/api/v1/library/{id}")
        assertTemplated("/api/v1/./items", equals: "/api/v1/{id}/items")
        assertTemplated("/api/v1/../items", equals: "/api/v1/{id}/items")
    }

    func testFilesystemPrefixesAreFullyTemplated() {




        assertTemplated("/users/bob/library", equals: "/{id}/{id}/{id}")
        assertTemplated("/var/mobile/Containers/Data", equals: "/{id}/{id}/{id}/{id}")
        assertTemplated("/private/var/tmp", equals: "/{id}/{id}/{id}")
        assertTemplated("/data/user/0/pkg", equals: "/{id}/{id}/{id}/{id}")
    }


    func testQueryStringsAndFragmentsAreStripped() {


        assertTemplated("/api/v1/items/12345?api_key=secret", equals: "/api/v1/items/{id}")
        assertTemplated("/api/v1/catalog?q=bourne&page=2", equals: "/api/v1/catalog")
        assertTemplated("/api/v1/items/12345#frag", equals: "/api/v1/items/{id}")
        assertTemplated("/api/v1/health?", equals: "/api/v1/health")
    }

    func testURLEntryPointDropsHostQueryAndFragment() {
        let url = URL(string: "https://media.example.com:8096/api/v1/items/12345?token=abc#top")!
        let templated = DiagnosticsPathTemplate.templatedPath(for: url)

        XCTAssertEqual(templated, "/api/v1/items/{id}")

        XCTAssertFalse(templated.contains("example.com"))
        assertNoPrivateSegments(templated)
    }




    func testTemplatingIsIdempotent() {


        for path in [
            "/api/v1/items/12345",
            "/v1/reports/01H8XK3P2Q",
            "/users/bob/library",
            "/api/v1/health",
        ] {
            let once = DiagnosticsPathTemplate.templatedPath(forRawPath: path)
            XCTAssertEqual(
                DiagnosticsPathTemplate.templatedPath(forRawPath: once),
                once,
                "templating \(path) is not idempotent"
            )
        }
    }


    private func assertTemplated(
        _ input: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = DiagnosticsPathTemplate.templatedPath(forRawPath: input)
        XCTAssertEqual(actual, expected, "templating \(input)", file: file, line: line)
        assertNoPrivateSegments(actual, file: file, line: line)
    }




    private func assertNoPrivateSegments(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(path.contains("?"), "path contains a query marker: \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("#"), "path contains a fragment marker: \(path)", file: file, line: line)

        let lowercased = path.lowercased()
        for prefix in ["/users/", "/private/", "/var/mobile/", "/data/user/"] {
            XCTAssertFalse(
                lowercased.hasPrefix(prefix),
                "path keeps private prefix \(prefix): \(path)",
                file: file,
                line: line
            )
        }

        for rawPart in path.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(rawPart)
            guard let decoded = Self.fullyPercentDecoded(segment) else {
                XCTFail("segment \(segment) is undecodable in \(path)", file: file, line: line)
                continue
            }
            XCTAssertFalse(decoded.contains("/"), "segment decodes to a separator: \(path)", file: file, line: line)




            XCTAssertNotEqual(decoded, ".", "relative segment survived: \(path)", file: file, line: line)
            XCTAssertNotEqual(decoded, "..", "relative segment survived: \(path)", file: file, line: line)


            let normalized = Self.trimmingPunctuation(decoded)
            if normalized.isEmpty
                || Self.matches(Self.templateSegment, normalized)
                || Self.matches(Self.safeVersionSegment, normalized) {
                continue
            }
            let candidates = [normalized] + normalized.components(
                separatedBy: CharacterSet(charactersIn: ".,;:()[]")
            )
            for candidate in candidates where !candidate.isEmpty {
                for (name, regex) in Self.privateSegmentRules {
                    XCTAssertFalse(
                        Self.matches(regex, candidate),
                        "segment \(candidate) matches privacy rule \(name) in \(path)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }



    private static func fullyPercentDecoded(_ raw: String) -> String? {
        var segment = raw
        for _ in 0..<3 {
            guard let decoded = segment.removingPercentEncoding else { return nil }
            if decoded == segment { return segment }
            segment = decoded
        }
        guard let decoded = segment.removingPercentEncoding, decoded == segment else { return nil }
        return segment
    }

    private static func trimmingPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: #"([]"'.,;!:)"#))
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {

        try! NSRegularExpression(pattern: pattern)
    }

    private static let templateSegment = regex(#"^\{[a-z][a-z0-9_]*\}$"#)
    private static let safeVersionSegment = regex(#"(?i)^v[0-9]+$"#)
    private static let privateSegmentRules: [(String, NSRegularExpression)] = [
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("NUMERIC", regex(#"^[0-9]+$"#)),
        (
            "PRIVATE_ID_SEGMENT",
            regex(#"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#)
        ),
        ("HEX_ID_SEGMENT", regex(#"(?i)^[a-f0-9]{16,}$"#)),
        ("OPAQUE_ID_SEGMENT", regex(#"(?i)^[a-z0-9_-]{20,}$"#)),
    ]
}
