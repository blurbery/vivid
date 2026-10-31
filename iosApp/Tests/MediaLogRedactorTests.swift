import XCTest
@testable import Vivid

/// Playback text written to the unified log keeps its metrics but loses
/// credentials, origins, paths and media titles.
final class MediaLogRedactorTests: XCTestCase {
    private static let auditedSamples = [
        "load url=https://media.example/stream?id=4&st=secret-token fallback=file:///private/var/mobile/movie.mkv rate=1.000 frames=42",
        "Authorization: Bearer header-secret, Cookie=session=cookie-secret token=plain-secret path=/Users/person/Movies/title.mkv",
        "headers=[\"X-Profile-Token\": \"profile-secret\", \"X-Silo-Auth\": \"auth-secret\"] frames=42",
        "cache=\"/var/mobile/Containers/Data/Downloads/Show Name S01E01.mkv\" sidecar=Movie Title (2024).en.srt retries=3",
        "Authorization: Bearer abc",
        "token=short",
        "headers X-Emby-Token 9f83ba21c0de44aa77b1 device=tvos",
        "origin silo.example.com:8096/Videos/abc/Movie.Name.2019.mkv?k=1",
        "origin 192.168.1.42:8096/Videos/abc/Movie.mkv",
        "origin [2001:db8::1]:8096/Videos/abc/Movie.mkv",
        "path=\\\\media-nas\\Movies\\Show Name S01E01.mkv",
        "cache ~/Documents/Silo/Show Name S02E03.mkv loaded",
        "cache /Library/Caches/com.silo/Downloads/title.mkv loaded",
        "playing [redacted-url] Movie.mkv",
        "hls ready url=master.m3u8 seq=4",
        "session started successfully after 3 retries",
        "refresh accessToken=aaa.bbb.ccc done",
    ]

    private func sample(_ number: Int) -> String { Self.auditedSamples[number - 1] }

    private func expect(
        _ input: String, absent: [String] = [], present: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let output = MediaLogRedactor.sanitize(input)
        for text in absent {
            XCTAssertFalse(output.contains(text), "\(text) leaked in \(output)", file: file, line: line)
        }
        for text in present {
            XCTAssertTrue(output.contains(text), "\(text) missing from \(output)", file: file, line: line)
        }
    }

    func testRedactsRemoteAndLocalMediaIdentityWithoutDroppingMetrics() {
        expect(sample(1), absent: ["media.example", "secret-token", "movie.mkv"], present: ["rate=1.000", "frames=42"])
    }

    func testRedactsHeadersBareTokensAndFilesystemPaths() {
        expect(sample(2), absent: ["header-secret", "cookie-secret", "plain-secret", "person", "title.mkv"])
    }

    func testRedactsCustomCredentialHeadersWithoutDroppingLaterTelemetry() {
        expect(
            "headers=[\"X-Profile-Token\": \"profile-secret\", \"X-Silo-Auth\": \"auth-secret\", "
                + "\"X_Profile_Token\": \"underscore-secret\"] frames=42 rate=1.000",
            absent: ["profile-secret", "auth-secret", "underscore-secret"],
            present: ["frames=42", "rate=1.000"])
    }

    func testRedactsSpacedPathsAndBareMediaNamesWithoutDroppingTelemetry() {
        expect(sample(4), absent: ["Show Name", "S01E01", "Movie Title", "2024", ".mkv", ".srt"], present: ["retries=3"])
    }

    func testRedactsSpaceDelimitedCredentialHeaders() {
        expect(sample(7), absent: ["9f83ba21c0de44aa77b1"], present: ["[redacted]", "device=tvos"])
    }

    func testSpaceDelimitedRuleLeavesOrdinaryProseIntact() {
        XCTAssertEqual(MediaLogRedactor.sanitize(sample(16)), sample(16))
    }

    func testRedactsSchemeLessOriginsWithPaths() {
        expect(sample(8), absent: ["silo.example.com", "Movie.Name.2019"])
        expect(sample(9), absent: ["192.168.1.42", "Movie.mkv"])
        expect(sample(10), absent: ["2001:db8", "Movie.mkv"])
    }

    func testSchemeLessOriginRuleLeavesSourceReferencesIntact() {
        let reference = "DiagLog.swift:42 assertion rate=1.000"
        XCTAssertEqual(MediaLogRedactor.sanitize(reference), reference)
    }

    func testRedactsCachesAndTildeHomePaths() {
        expect(sample(13), absent: ["title.mkv", "/Library/Caches"], present: ["loaded"])
        expect(sample(12), absent: ["Show Name", "S02E03", "~/Documents"], present: ["loaded"])
    }

    func testRedactsUNCSharesIncludingServerAndShareName() {
        expect(sample(11), absent: ["media-nas", "Movies", "Show Name", "S01E01"], present: ["[redacted-path]"])
    }

    func testMediaNameRuleReplacesOnlyTheFilenameToken() {
        XCTAssertEqual(MediaLogRedactor.sanitize(sample(14)), "playing [redacted-url] [redacted-media-name]")
    }

    func testGenericManifestNamesSurviveButUserTitlesDoNot() {
        expect(sample(15), present: ["master.m3u8", "seq=4"])
        expect("master copy of movie.mkv", absent: ["movie.mkv"])
    }

    func testSanitizeIsIdempotent() {
        for (index, input) in Self.auditedSamples.enumerated() {
            let once = MediaLogRedactor.sanitize(input)
            XCTAssertEqual(MediaLogRedactor.sanitize(once), once, "sample \(index + 1): \(input)")
        }
    }

    func testRedactionMarkerDoesNotAccreteBrackets() {
        XCTAssertEqual(MediaLogRedactor.sanitize(sample(5)), "Authorization: [redacted]")
        XCTAssertEqual(MediaLogRedactor.sanitize("open url?token=abc123, retries=1"), "open url?token=[redacted], retries=1")
    }

    func testBoundsUntrustedErrorText() {
        XCTAssertLessThanOrEqual(MediaLogRedactor.sanitize(String(repeating: "x", count: 10_000), maxLength: 128).count, 128)
        XCTAssertEqual(MediaLogRedactor.sanitize("secret", maxLength: 2).count, 2)
    }

    func testPreboundsPathologicalInputBeforeRegexRedaction() {
        let input = String(repeating: "a", count: 100_000) + " token=secret-that-must-not-reach-output"
        XCTAssertLessThanOrEqual(MediaLogRedactor.sanitize(input).count, 1_024)
    }
}
