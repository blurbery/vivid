import XCTest
@testable import Vivid

/// Clock measurements for paths that earlier optimisation work made cheap:
/// library page decoding, Home rows from the metadata snapshot and log
/// redaction. Every fixture is generated here, so no real library or server
/// data is involved. Each test asserts its result as well, because a fixture
/// that silently decodes to nothing would otherwise look fast.
final class HotPathPerformanceTests: XCTestCase {
    private static let iterations = 5

    private var options: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = Self.iterations
        return options
    }

    override func setUp() {
        super.setUp()
        DiagLog.resetSensitiveHostsForTesting()
    }

    override func tearDown() {
        DiagLog.resetSensitiveHostsForTesting()
        super.tearDown()
    }

    // MARK: - Library pages

    func testEmbyLibraryPageDecodePerformance() throws {
        let adapter = EmbyAdapter(connection: EmbyConnection(
            serverURL: "https://media.example.test", token: nil, userID: "user-1", identity: nil))
        let page = try nativePage(count: 1_000) { String(100_000 + $0) }
        try measureCatalog(page, expected: 1_000) { raw in
            try ["items": adapter.convert(raw["Items"] as? [[String: Any]] ?? []), "total": raw["TotalRecordCount"] ?? 0]
        }
    }

    func testJellyfinLibraryPageDecodePerformance() throws {
        let adapter = JellyfinAdapter(connection: JellyfinConnection(
            serverURL: "https://media.example.test/jellyfin", token: "test-token", userID: "user-1",
            identity: nil, sessionOverride: nil))
        let page = try nativePage(count: 1_000) { String(format: "%032x", $0) }
        try measureCatalog(page, expected: 1_000) { raw in
            try ["items": adapter.convert(raw["Items"] as? [[String: Any]] ?? []), "total": raw["TotalRecordCount"] ?? 0]
        }
    }

    func testSiloLibraryPageDecodePerformance() throws {
        // Snake case, as Silo sends it, so key conversion is part of the cost.
        let items: [[String: Any]] = (0..<2_000).map { index in
            [
                "content_id": "item-\(index)", "type": index % 3 == 0 ? "series" : "movie",
                "title": "Synthetic Title \(index)", "year": 1990 + index % 35,
                "genres": ["Drama", "Comedy"], "content_rating": "PG-13", "status": "available",
                "rating_imdb": 7.1, "rating_tmdb": 6.8, "rating_rt_critic": 81, "runtime": 95 + index % 40,
                "original_language": "en", "studios": ["Example Studio"],
                "overview": String(repeating: "Synthetic overview text. ", count: 6),
                "poster_url": "/api/v1/images/poster/\(index)", "poster_thumbhash": "3OcRJYB4d3h/iIeHeEh3eIhw+j2w",
                "backdrop_url": "/api/v1/images/backdrop/\(index)", "added_at": "2026-01-02T03:04:05Z",
                "release_date": "2020-05-06",
                "user_state": ["played": index % 4 == 0, "is_favorite": index % 9 == 0, "in_watchlist": false],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "total": items.count, "total_exact": true, "has_more": false, "items": items,
        ])
        var decoded: CatalogResponse?
        measure(metrics: [XCTClockMetric()], options: options) {
            decoded = try? HTTPClient.makeJSONDecoder().decode(CatalogResponse.self, from: data)
        }
        let response = try XCTUnwrap(decoded)
        XCTAssertEqual(response.items.count, 2_000)
        XCTAssertEqual(response.items[42].contentId, "item-42")
        XCTAssertEqual(response.items[42].contentRating, "PG-13")
        XCTAssertEqual(response.items[36].userState?.played, true)
    }

    // MARK: - Home rows

    @MainActor
    func testHomeRowsFromCachedMetadataPerformance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = "perf-\(UUID().uuidString)"
        try homeSnapshot(rows: 12, itemsPerRow: 20)
            .write(to: directory.appendingPathComponent(scope + ".json"), options: .atomic)

        let writer = HomeMetadataWriter()
        var sections: [ResolvedSection] = []
        let options = self.options
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            // A fresh cache each time: activate() is a no-op once loaded.
            let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { scope })
            startMeasuring()
            cache.activate()
            let rows = HomeSectionPreferences.combinedSections(
                cache.snapshot.rows.map(\.section), enabled: true, provider: .emby)
            sections = rows.filter { !$0.items.isEmpty }
            stopMeasuring()
            cache.deactivate()
            writer.sync {}
        }
        XCTAssertEqual(sections.count, 11, "Continue Watching and Next Up merge into one row")
        XCTAssertEqual(sections.first?.items.count, 40)
        XCTAssertEqual(sections.last?.items.last?.contentId, "row-11-item-19")
    }

    // MARK: - Diagnostics redaction

    func testDiagnosticsRedactionPerformance() throws {
        let messages = (0..<2_000).map { index -> String in
            switch index % 4 {
            case 0: "HTTP 200 GET https://media.example.test/api/v1/catalog?offset=\(index)&api_key=perf-key-\(index)"
            case 1: "refresh accessToken=perf.token.\(index) refreshToken: perf-refresh-\(index) done"
            case 2: "stream wss://media.example.test/api/v1/playback/sessions/\(index)/realtime closed from 192.0.2.\(index % 250)"
            default: "decoded page \(index) with \(index % 60) items in \(index % 900) ms"
            }
        }
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(URL(string: "https://media.example.test/Items/1?api_key=perf-key"))
        var lines: [String] = []
        measure(metrics: [XCTClockMetric()], options: options) {
            lines = messages.compactMap { message in
                DiagLog.renderedLine(
                    level: .info, category: .network, tag: "Perf", message: message,
                    attrs: ["path": .url(url), "status": .int(200)],
                    timestamp: timestamp, captureSessionID: "perf-run")
            }
        }
        XCTAssertEqual(lines.count, messages.count)
        XCTAssertFalse(lines.contains { $0.contains("media.example.test") })
        XCTAssertFalse(lines.contains { $0.contains("perf.token.1") })
        XCTAssertFalse(lines.contains { $0.contains("perf-key") })
    }

    // MARK: - Fixtures

    /// One Emby or Jellyfin `/Items` page with the browse fields both providers request.
    private func nativePage(count: Int, id: (Int) -> String) throws -> Data {
        let items: [[String: Any]] = (0..<count).map { index in
            [
                "Id": id(index), "Name": "Synthetic Title \(index)", "SortName": "synthetic title \(index)",
                "Type": index % 3 == 0 ? "Series" : "Movie", "ProductionYear": 1990 + index % 35,
                "Overview": String(repeating: "Synthetic overview text. ", count: 6),
                "OfficialRating": "PG-13", "CommunityRating": 6.8, "CriticRating": 81,
                "Genres": ["Drama", "Comedy"], "Studios": [["Name": "Example Studio", "Id": "1"]],
                "ProviderIds": ["Tmdb": String(index), "Imdb": "tt\(1_000_000 + index)"],
                "DateCreated": "2026-01-02T03:04:05.0000000Z", "PremiereDate": "2020-05-06T00:00:00.0000000Z",
                "RunTimeTicks": Int64(index % 40 + 90) * 600_000_000, "ChildCount": index % 3 == 0 ? 4 : 0,
                "PrimaryImageAspectRatio": 0.6667,
                "ImageTags": ["Primary": "primary-\(index)"], "BackdropImageTags": ["backdrop-\(index)"],
                "UserData": ["PlaybackPositionTicks": index % 5 == 0 ? 3_000_000_000 : 0,
                             "Played": index % 4 == 0, "IsFavorite": index % 9 == 0],
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["Items": items, "TotalRecordCount": count])
    }

    /// Server bytes to the decoded page, the same way HTTPClient routes a
    /// native provider response: parse, map, re-encode, then decode.
    private func measureCatalog(_ data: Data, expected: Int,
                                map: @escaping ([String: Any]) throws -> [String: Any]) throws {
        var decoded: CatalogResponse?
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let mapped = try JSONSerialization.data(withJSONObject: map(raw), options: [.fragmentsAllowed])
                decoded = try HTTPClient.makeJSONDecoder().decode(CatalogResponse.self, from: mapped)
            } catch {
                XCTFail("Decoding failed: \(error)")
            }
        }
        let response = try XCTUnwrap(decoded)
        XCTAssertEqual(response.items.count, expected)
        XCTAssertEqual(response.items[42].title, "Synthetic Title 42")
        XCTAssertEqual(response.items[42].runtime, 92)
        XCTAssertNotNil(response.items[42].posterUrl)
    }

    /// A snapshot in the format persist() writes. Artwork stays empty so
    /// activation does not start image prefetches.
    @MainActor
    private func homeSnapshot(rows: Int, itemsPerRow: Int) throws -> Data {
        let types = ["continue_watching", "next_up"] + Array(repeating: "latest", count: rows - 2)
        let sections = try (0..<rows).map { row in
            let json = (0..<itemsPerRow).map { item in
                #"{"contentId":"row-\#(row)-item-\#(item)","type":"movie","title":"Synthetic \#(row).\#(item)","year":2020,"genres":["Drama"],"status":"available","runtime":95,"overview":"Synthetic overview."}"#
            }
            let items = try JSONDecoder().decode([SectionItem].self, from: Data("[\(json.joined(separator: ","))]".utf8))
            return ResolvedSection(id: "row-\(row)", sectionType: types[row], title: "Row \(row)",
                                   featured: false, itemLimit: 20, totalCount: itemsPerRow,
                                   isCustom: false, customized: false, items: items)
        }
        var snapshot = TVHomeMetadataCache.Snapshot()
        let updated = Date(timeIntervalSince1970: 1_800_000_000)
        snapshot.rows = sections.map { TVHomeMetadataCache.Row(section: $0, updatedAt: updated) }
        snapshot.spotlightUpdatedAt = updated
        return try JSONEncoder().encode(snapshot)
    }
}
