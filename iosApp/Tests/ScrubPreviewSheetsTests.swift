import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

@MainActor
final class ScrubPreviewSheetsTests: XCTestCase {
    // MARK: - Tile maths

    func testATimeMapsToItsSheetAndCell() throws {
        let sheets = try XCTUnwrap(Self.sheets(count: 205, columns: 10, rows: 8))
        XCTAssertEqual(sheets.sheetURLs.count, 3)
        XCTAssertEqual(sheets.tile(atSourceTime: 0), .init(index: 0, sheet: 0, column: 0, row: 0))
        XCTAssertEqual(sheets.tile(atSourceTime: 9.999), .init(index: 0, sheet: 0, column: 0, row: 0))
        XCTAssertEqual(sheets.tile(atSourceTime: 10), .init(index: 1, sheet: 0, column: 1, row: 0))
        XCTAssertEqual(sheets.tile(atSourceTime: 125), .init(index: 12, sheet: 0, column: 2, row: 1))
        XCTAssertEqual(sheets.tile(atSourceTime: 799.9), .init(index: 79, sheet: 0, column: 9, row: 7))
        XCTAssertEqual(sheets.tile(atSourceTime: 800), .init(index: 80, sheet: 1, column: 0, row: 0))
        XCTAssertEqual(sheets.tile(atSourceTime: 2049), .init(index: 204, sheet: 2, column: 4, row: 4))
    }

    func testTheLastStillCoversTheTailButNotALongerFile() throws {
        let sheets = try XCTUnwrap(Self.sheets(count: 205, columns: 10, rows: 8))
        XCTAssertEqual(sheets.tile(atSourceTime: 2055)?.index, 204)
        XCTAssertNil(sheets.tile(atSourceTime: 2060))
        XCTAssertNil(sheets.tile(atSourceTime: -1))
        XCTAssertNil(sheets.tile(atSourceTime: .nan))
        XCTAssertNil(sheets.tile(atSourceTime: .infinity))
    }

    func testADescriptionThatCannotAddressItsStillsIsRefused() {
        XCTAssertNil(Self.sheets(count: 205, columns: 10, rows: 8, sheetCount: 2), "too few sheets")
        XCTAssertNil(Self.sheets(count: 0, columns: 10, rows: 8))
        XCTAssertNil(Self.sheets(count: 10, columns: 0, rows: 8))
        XCTAssertNil(Self.sheets(count: 10, columns: 10, rows: 400))
        XCTAssertNil(Self.sheets(count: 10, columns: 10, rows: 8, interval: 0))
        XCTAssertEqual(Self.sheets(count: 10, columns: 10, rows: 8, sheetCount: 4)?.sheetURLs.count, 1, "spare sheets are dropped")
    }

    func testExpiryLeavesAMinuteInHand() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func sheets(expiring seconds: TimeInterval?) -> ScrubPreviewSheets? {
            ScrubPreviewSheets(key: "k", intervalMilliseconds: 10_000, columns: 2, rows: 2, thumbnailCount: 4,
                               sheetURLs: [URL(string: "https://media.example.invalid/0.jpg")!], headers: [:],
                               expiresAt: seconds.map { now.addingTimeInterval($0) })
        }
        XCTAssertFalse(try XCTUnwrap(sheets(expiring: nil)).isExpiring(at: now))
        XCTAssertFalse(try XCTUnwrap(sheets(expiring: 3600)).isExpiring(at: now))
        XCTAssertTrue(try XCTUnwrap(sheets(expiring: 30)).isExpiring(at: now))
        XCTAssertTrue(try XCTUnwrap(sheets(expiring: -5)).isExpiring(at: now))
    }

    func testCroppingUsesTheImagesOwnGrid() throws {
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let image = try XCTUnwrap(Self.sheetImage(columns: 4, rows: 2, cell: 20))
        let tile = try XCTUnwrap(sheets.tile(atSourceTime: 65))
        XCTAssertEqual(tile, .init(index: 6, sheet: 0, column: 2, row: 1))
        let still = try XCTUnwrap(sheets.crop(tile, from: image))
        XCTAssertEqual(still.width, 20)
        XCTAssertEqual(still.height, 20)
        XCTAssertEqual(Self.level(of: still), Self.level(forCell: 6), accuracy: 12)
        let tiny = try XCTUnwrap(Self.sheetImage(columns: 4, rows: 2, cell: 4))
        XCTAssertNil(sheets.crop(tile, from: tiny))
    }

    // MARK: - Silo

    func testSiloManifestResolvesRelativeAndAbsoluteSheets() throws {
        let body = #"{"file_id":"42","interval_ms":10000,"thumbnail_width":300,"thumbnail_height":126,"tile_columns":10,"tile_rows":8,"thumbnail_count":90,"sheets":[{"index":1,"url":"https://cdn.example.com/trickplay/42/r/1.jpg?X-Amz-Signature=abc"},{"index":0,"url":"/api/v2/artwork/trickplay/42/r/0.r.jpg?exp=1&sig=a%2Fb"}],"expires_at":"2026-01-02T03:04:05.000Z"}"#
        let sheets = try XCTUnwrap(SiloScrubPreviews.decode(Data(body.utf8), serverURL: "https://silo.example.com:8443", key: "silo|movie:1|42"))
        XCTAssertEqual(sheets.sheetURLs.map(\.absoluteString), [
            "https://silo.example.com:8443/api/v2/artwork/trickplay/42/r/0.r.jpg?exp=1&sig=a%2Fb",
            "https://cdn.example.com/trickplay/42/r/1.jpg?X-Amz-Signature=abc",
        ])
        XCTAssertEqual(sheets.headers, [:], "signed URLs take no account header")
        XCTAssertEqual(sheets.columns, 10)
        XCTAssertEqual(sheets.rows, 8)
        XCTAssertEqual(sheets.intervalMilliseconds, 10_000)
        XCTAssertEqual(sheets.expiresAt, ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        XCTAssertEqual(sheets.key, "silo|movie:1|42")
    }

    func testSiloManifestWithAnUnusableSheetIsDropped() {
        let server = "https://silo.example.com"
        for body in [
            #"{"interval_ms":10000,"tile_columns":10,"tile_rows":8,"thumbnail_count":9,"sheets":[{"index":0,"url":"ftp://x.example.com/0.jpg"}]}"#,
            #"{"interval_ms":10000,"tile_columns":10,"tile_rows":8,"thumbnail_count":9,"sheets":[{"index":0,"url":"//x.example.com/0.jpg"}]}"#,
            #"{"interval_ms":10000,"tile_columns":10,"tile_rows":8,"thumbnail_count":90,"sheets":[{"index":0,"url":"/a.jpg"},{"index":2,"url":"/c.jpg"}]}"#,
            #"{"interval_ms":10000,"tile_columns":10,"tile_rows":8,"thumbnail_count":90,"sheets":[{"index":0,"url":"/a.jpg"}]}"#,
            #"{"interval_ms":0,"tile_columns":10,"tile_rows":8,"thumbnail_count":9,"sheets":[{"index":0,"url":"/a.jpg"}]}"#,
            "not json",
        ] {
            XCTAssertNil(SiloScrubPreviews.decode(Data(body.utf8), serverURL: server, key: "k"), body)
        }
    }

    func testFileVersionReadsWhetherSiloHasPreviews() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        func version(_ extra: String) throws -> FileVersion {
            try decoder.decode(FileVersion.self, from: Data(#"{"file_id":42\#(extra)}"#.utf8))
        }
        XCTAssertEqual(try version(#","trickplay_available":true"#).trickplayAvailable, true)
        XCTAssertEqual(try version(#","trickplay_available":false"#).trickplayAvailable, false)
        XCTAssertNil(try version("").trickplayAvailable)
        XCTAssertNil(try version(#","trickplay_available":"yes""#).trickplayAvailable, "an odd value doesn't fail the item")
    }

    // MARK: - Jellyfin

    func testJellyfinSheetsComeFromThePlayingSource() throws {
        let item: [String: Any] = ["Trickplay": [
            "0f8fad5b-d9cb-469f-a165-70867728950e": [
                "320": ["Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 250, "Interval": 10_000, "Bandwidth": 1],
                "640": ["Width": 640, "Height": 360, "TileWidth": 5, "TileHeight": 5, "ThumbnailCount": 250, "Interval": 10_000, "Bandwidth": 1],
            ],
            "other": ["320": ["TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 5, "Interval": 10_000]],
        ]]
        let sheets = try XCTUnwrap(JellyfinScrubPreviews.sheets(
            item: item, itemID: "abc123", sourceID: "0F8FAD5BD9CB469FA16570867728950E",
            serverURL: "https://jelly.example.com/base", headers: ["Authorization": "MediaBrowser Token=\"t\""]))
        XCTAssertEqual(sheets.columns, 5, "the narrowest set that's wide enough")
        XCTAssertEqual(sheets.rows, 5)
        XCTAssertEqual(sheets.sheetURLs.count, 10)
        XCTAssertEqual(sheets.sheetURLs[3].absoluteString,
                       "https://jelly.example.com/base/Videos/0F8FAD5BD9CB469FA16570867728950E/Trickplay/640/3.jpg?mediaSourceId=0F8FAD5BD9CB469FA16570867728950E",
                       "the sheets belong to the playing version's own item")
        XCTAssertEqual(sheets.headers["Authorization"], "MediaBrowser Token=\"t\"")
        XCTAssertNil(sheets.expiresAt)
    }

    func testJellyfinFallsBackToTheWidestSetAndRefusesBadOnes() throws {
        let only320: [String: Any] = ["Trickplay": ["src": ["320": ["TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 101, "Interval": 10_000]]]]
        let sheets = try XCTUnwrap(JellyfinScrubPreviews.sheets(
            item: only320, itemID: "abc", sourceID: "src", serverURL: "https://jelly.example.com", headers: [:]))
        XCTAssertEqual(sheets.sheetURLs.count, 2)
        XCTAssertTrue(sheets.sheetURLs[0].absoluteString.contains("/Trickplay/320/0.jpg"))

        func none(_ item: [String: Any], itemID: String = "abc", sourceID: String = "src") {
            XCTAssertNil(JellyfinScrubPreviews.sheets(item: item, itemID: itemID, sourceID: sourceID,
                                                      serverURL: "https://jelly.example.com", headers: [:]))
        }
        none([:])
        none(only320, sourceID: "another")
        // Neither the source's ID nor the item's can go in a path.
        none(["Trickplay": ["s/c": ["320": ["TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 101, "Interval": 10_000]]]],
             itemID: "a/b", sourceID: "s/c")
        none(["Trickplay": ["src": ["320": ["TileWidth": 0, "TileHeight": 10, "ThumbnailCount": 5, "Interval": 10_000]]]])
        none(["Trickplay": ["src": ["wide": ["TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 5, "Interval": 10_000]]]])
        none(["Trickplay": ["src": [:] as [String: Any]]])
        // Huge counts are refused before they're multiplied.
        none(["Trickplay": ["src": ["320": ["TileWidth": Int.max, "TileHeight": Int.max, "ThumbnailCount": 5, "Interval": 10_000]]]])
        none(["Trickplay": ["src": ["320": ["TileWidth": 10, "TileHeight": 10, "ThumbnailCount": Int.max, "Interval": 10_000]]]])
    }

    // MARK: - Store

    func testTheStoreSharesOneDownloadAndSendsTheSheetsHeaders() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2, headers: ["Authorization": "MediaBrowser Token=\"t\""]))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        XCTAssertNil(store.cached(0))
        async let first = store.image(0)
        async let second = store.image(0)
        let images = await [first, second]
        XCTAssertEqual(images.compactMap { $0 }.count, 2)
        XCTAssertNotNil(store.cached(0))
        let requests = SheetStub.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "MediaBrowser Token=\"t\"")
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://media.example.invalid/sheets/0.jpg")
        _ = await store.image(0)
        XCTAssertEqual(SheetStub.requests().count, 1, "a decoded sheet needs no request")
    }

    func testAFailedSheetWaitsBeforeItsRetriedAndOnlyTwoStayDecoded() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        var clock = Date(timeIntervalSince1970: 1_000_000)
        SheetStub.configure { request in
            request.url?.lastPathComponent == "1.jpg" ? (404, Data()) : (200, jpeg)
        }
        let sheets = try XCTUnwrap(Self.sheets(count: 32, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession(), now: { clock })
        let missing = await store.image(1)
        XCTAssertNil(missing)
        XCTAssertTrue(store.hasFailed(1))
        _ = await store.image(1)
        XCTAssertEqual(SheetStub.requests().count, 1, "no second request inside the retry delay")
        clock = clock.addingTimeInterval(31)
        XCTAssertFalse(store.hasFailed(1))

        for sheet in [0, 2, 3] {
            let image = await store.image(sheet)
            XCTAssertNotNil(image)
        }
        store.setScrubbing(true)
        XCTAssertNil(store.cached(0), "the oldest decoded sheet is dropped")
        XCTAssertNotNil(store.cached(2))
        XCTAssertNotNil(store.cached(3))
        let before = SheetStub.requests().count
        let again = await store.image(0)
        XCTAssertNotNil(again)
        XCTAssertEqual(SheetStub.requests().count, before, "its JPEG was kept, so it only decodes again")

        let outOfRange = await store.image(9)
        XCTAssertNil(outOfRange)
        store.shutdown()
        let afterShutdown = await store.image(2)
        XCTAssertNil(afterShutdown)
    }

    func testSomethingThatIsNotAnImageFailsTheSheet() async throws {
        SheetStub.configure { _ in (200, Data("<html>sign in</html>".utf8)) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        let image = await store.image(0)
        XCTAssertNil(image)
        XCTAssertTrue(store.hasFailed(0))
    }

    func testBetweenScrubsOneSheetStaysDecodedEvenIfAnotherLandsLate() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 32, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        store.setScrubbing(true)
        _ = await store.image(0)
        async let late = store.image(1)
        store.setScrubbing(false)
        _ = await late
        XCTAssertNil(store.cached(0))
        XCTAssertNotNil(store.cached(1))
    }

    func testMemoryGivenBackStaysGivenBackWhenWorkLandsLate() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return (200, jpeg)
        }
        let sheets = try XCTUnwrap(Self.sheets(count: 32, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        async let running = store.image(0)
        try await Task.sleep(for: .milliseconds(40))
        store.releaseMemory()
        let image = await running
        XCTAssertNotNil(image, "the caller still gets its sheet")
        XCTAssertNil(store.cached(0))
        _ = await store.image(0)
        XCTAssertEqual(SheetStub.requests().count, 2, "and its JPEG wasn't kept either")
    }

    func testADownloadWithNoLengthStopsOnceItPassesTheLimit() async throws {
        // 40 MB in 4 MB chunks with no Content-Length: the request has to be
        // cancelled part-way, not rejected after the whole body arrived.
        SheetStub.configure(chunks: 10, chunkSize: 4 * 1024 * 1024) { _ in (200, Data()) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        let image = await store.image(0)
        XCTAssertNil(image)
        XCTAssertTrue(store.hasFailed(0))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(SheetStub.wasStopped())
        XCTAssertLessThan(SheetStub.chunksSent(), 10)
    }

    func testADeclaredLengthOverTheLimitIsRefusedBeforeAnyBody() async throws {
        SheetStub.configure(chunks: 4, chunkSize: 1024, declaredLength: 20 * 1024 * 1024) { _ in (200, Data()) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        let image = await store.image(0)
        XCTAssertNil(image)
        XCTAssertTrue(store.hasFailed(0))
        XCTAssertTrue(SheetStub.wasStopped())
        XCTAssertLessThan(SheetStub.chunksSent(), 4)
    }

    func testAFailedSheetDoesNotLetTheNextDecodeOvertakeARunningOne() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        // Sheet 0 is held at the server until sheet 2 has been asked for,
        // and then takes a little longer, so the order doesn't depend on
        // how fast anything runs: without the chain, sheet 2 always decodes
        // while sheet 0 is still on its way.
        let sheetTwoRequested = DispatchSemaphore(value: 0)
        SheetStub.configure { request in
            switch request.url?.lastPathComponent {
            case "0.jpg":
                sheetTwoRequested.wait()
                Thread.sleep(forTimeInterval: 0.15)
                return (200, jpeg)
            case "1.jpg":
                return (500, Data())
            default:
                sheetTwoRequested.signal()
                return (200, jpeg)
            }
        }
        let sheets = try XCTUnwrap(Self.sheets(count: 32, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        store.setScrubbing(true)
        var order: [Int] = []
        async let slow: Void = { _ = await store.image(0); order.append(0) }()
        try await waitUntil { SheetStub.requests().contains { $0.url?.lastPathComponent == "0.jpg" } }
        async let failed: Void = { _ = await store.image(1); order.append(1) }()
        // Sheet 1 has failed before sheet 2 is even asked for.
        try await waitUntil { store.hasFailed(1) }
        async let next: Void = { _ = await store.image(2); order.append(2) }()
        _ = await (slow, failed, next)
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: 0)), try XCTUnwrap(order.firstIndex(of: 2)),
                          "sheet 2 waits for sheet 0 although sheet 1 failed in between")
    }

    func testAnOversizedSheetIsRefused() async throws {
        SheetStub.configure { _ in (200, Data(count: 17 * 1024 * 1024)) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let store = ScrubPreviewSheetStore(sheets: sheets, session: Self.stubSession())
        let image = await store.image(0)
        XCTAssertNil(image)
        XCTAssertTrue(store.hasFailed(0))
    }

    // MARK: - Provider

    func testAScrubGetsItsStillFromTheSheetAndFollowsTheTarget() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var previews: [VividScrubPreviewProvider.Preview?] = []
        provider.onPreview = { previews.append($0) }

        provider.activate(try Self.spec(), sheets: .init(key: sheets.key) { sheets }, startSourceTime: 0)
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        try await waitUntil { previews.contains { $0 != nil } }
        let first = try XCTUnwrap(previews.last ?? nil)
        XCTAssertEqual(first.sourceTime, 15)
        XCTAssertEqual(Self.level(of: first.image), Self.level(forCell: 1), accuracy: 12)

        // The sheet is decoded now, so the next target answers before
        // `request` returns.
        provider.request(atSourceTime: 72)
        let second = try XCTUnwrap(previews.last ?? nil)
        XCTAssertEqual(second.sourceTime, 72)
        XCTAssertEqual(Self.level(of: second.image), Self.level(forCell: 7), accuracy: 12)
        XCTAssertEqual(SheetStub.requests().count, 1)

        // Moving inside the same still publishes nothing new.
        let published = previews.count
        provider.request(atSourceTime: 74)
        provider.request(atSourceTime: 79.5)
        XCTAssertEqual(previews.count, published)

        provider.endInteraction()
        XCTAssertNil(try XCTUnwrap(previews.last), "ending the scrub clears the still")

        // The next scrub shows the same still again from the decoded sheet.
        provider.begin(atSourceTime: 74)
        XCTAssertEqual((previews.last ?? nil)?.sourceTime, 74)
        XCTAssertEqual(SheetStub.requests().count, 1)
        await provider.endSession()?.value
    }

    func testAStillForAnEndedLoadNeverLands() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var stills = 0
        provider.onPreview = { if $0 != nil { stills += 1 } }
        provider.activate(try Self.spec(), sheets: .init(key: sheets.key) { sheets })
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        await provider.endSession()?.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(stills, 0)
        provider.request(atSourceTime: 20)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stills, 0, "nothing is asked for without a load")
    }

    func testSheetsThatArriveMidScrubAnswerTheCurrentTarget() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        var release: CheckedContinuation<Void, Never>?
        provider.activate(try Self.spec(), sheets: .init(key: sheets.key) {
            await withCheckedContinuation { release = $0 }
            return sheets
        })
        provider.playbackStarted()
        try await waitUntil { release != nil }
        provider.begin(atSourceTime: 5)
        provider.request(atSourceTime: 45)
        release?.resume()
        try await waitUntil { latest?.sourceTime == 45 }
        XCTAssertEqual(Self.level(of: try XCTUnwrap(latest).image), Self.level(forCell: 4), accuracy: 12)
        await provider.endSession()?.value
    }

    func testAReloadOfTheSameFileKeepsItsSheets() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        var loads = 0
        let source = VividScrubPreviewProvider.SheetSource(key: sheets.key) {
            loads += 1
            return sheets
        }
        provider.activate(try Self.spec(), sheets: source)
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        try await waitUntil { latest != nil }

        provider.endSession(keepingSheets: true)
        provider.activate(try Self.spec(), sheets: source)
        provider.playbackStarted()
        provider.begin(atSourceTime: 25)
        XCTAssertEqual(latest?.sourceTime, 25, "the kept sheet answers at once")
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(SheetStub.requests().count, 1)

        // A different file starts again.
        let other = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2, key: "other"))
        provider.activate(try Self.spec(), sheets: .init(key: other.key) { other })
        provider.playbackStarted()
        provider.begin(atSourceTime: 25)
        try await waitUntil { latest?.sourceTime == 25 && SheetStub.requests().count == 2 }
        await provider.endSession()?.value
    }

    func testNothingIsAskedForUntilPlaybackHasStarted() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var loads = 0
        let source = VividScrubPreviewProvider.SheetSource(key: sheets.key) {
            loads += 1
            return sheets
        }
        provider.activate(try Self.spec(), sheets: source, startSourceTime: 15)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(loads, 0, "the sheet list waits for the first frame")
        XCTAssertEqual(SheetStub.requests().count, 0)

        provider.playbackStarted()
        try await waitUntil { SheetStub.requests().count == 1 }
        XCTAssertEqual(loads, 1)

        // A reload of the same file keeps its sheets but still waits for
        // its own first frame before touching the network again.
        provider.endSession(keepingSheets: true)
        SheetStub.configure { _ in (200, jpeg) }
        provider.activate(try Self.spec(), sheets: source, startSourceTime: 75)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(SheetStub.requests().count, 0)
        await provider.endSession()?.value
    }

    func testAFastDragFetchesOneSheetAtATimeAndEndsOnTheNewestTarget() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in (200, jpeg) }
        let sheets = try XCTUnwrap(Self.sheets(count: 64, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        provider.activate(try Self.spec(), sheets: .init(key: sheets.key) { sheets })
        provider.playbackStarted()
        provider.begin(atSourceTime: 5)
        for target in stride(from: 85.0, through: 565, by: 80) {
            provider.request(atSourceTime: target)
        }
        try await waitUntil { latest?.sourceTime == 565 }
        XCTAssertEqual(Self.level(of: try XCTUnwrap(latest).image), Self.level(forCell: 0), accuracy: 12)
        await provider.endSession()?.value
    }

    func testAFailedSheetGivesNoStillAndDoesNotStopTheNextOne() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { request in
            request.url?.lastPathComponent == "0.jpg" ? (500, Data()) : (200, jpeg)
        }
        let sheets = try XCTUnwrap(Self.sheets(count: 16, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        provider.activate(try Self.spec(), sheets: .init(key: sheets.key) { sheets })
        provider.playbackStarted()
        provider.begin(atSourceTime: 5)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(latest?.sourceTime == 5 ? latest : nil, "no sheet still for the failed sheet")
        provider.request(atSourceTime: 95)
        try await waitUntil { latest?.sourceTime == 95 }
        await provider.endSession()?.value
    }

    func testAScrubRightAfterAReloadIsAnsweredWhileTheOldFetchIsStillRunning() async throws {
        let jpeg = try XCTUnwrap(Self.sheetJPEG(columns: 4, rows: 2, cell: 20))
        SheetStub.configure { _ in
            Thread.sleep(forTimeInterval: 0.25)
            return (200, jpeg)
        }
        let sheets = try XCTUnwrap(Self.sheets(count: 8, columns: 4, rows: 2))
        let (provider, _) = try makeProvider()
        var latest: VividScrubPreviewProvider.Preview?
        provider.onPreview = { latest = $0 }
        let source = VividScrubPreviewProvider.SheetSource(key: sheets.key) { sheets }
        provider.activate(try Self.spec(), sheets: source)
        provider.playbackStarted()
        provider.begin(atSourceTime: 15)
        try await Task.sleep(for: .milliseconds(50))

        // The same file loads again with the sheet still downloading, and
        // a scrub starts and holds on one target.
        provider.endSession(keepingSheets: true)
        provider.activate(try Self.spec(), sheets: source)
        provider.playbackStarted()
        provider.begin(atSourceTime: 35)
        try await waitUntil { latest?.sourceTime == 35 }
        XCTAssertEqual(SheetStub.requests().count, 1, "the running download is shared")
        await provider.endSession()?.value
    }

    // MARK: - Helpers

    private func makeProvider() throws -> (VividScrubPreviewProvider, VividPlaybackController) {
        let controller = try VividPlaybackController()
        // No frame reader, so nothing here opens the stream.
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeStore: { ScrubPreviewSheetStore(sheets: $0, session: Self.stubSession()) },
            makeReader: { _ in nil }
        )
        return (provider, controller)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    private static func spec() throws -> VividLoadSpec {
        try VividLoadSpec(directURL: URL(string: "https://media.example.invalid/video.mkv")!, headers: [:],
                          startPosition: 0, audioOnly: false)
    }

    private static func sheets(
        count: Int, columns: Int, rows: Int, sheetCount: Int? = nil, interval: Int = 10_000,
        headers: [String: String] = [:], key: String = "test"
    ) -> ScrubPreviewSheets? {
        let needed = columns > 0 && rows > 0 ? (max(count, 1) + columns * rows - 1) / (columns * rows) : 1
        let urls = (0..<(sheetCount ?? needed)).map { URL(string: "https://media.example.invalid/sheets/\($0).jpg")! }
        return ScrubPreviewSheets(key: key, intervalMilliseconds: interval, columns: columns, rows: rows,
                                  thumbnailCount: count, sheetURLs: urls, headers: headers, expiresAt: nil)
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SheetStub.self]
        return URLSession(configuration: configuration)
    }

    /// Each cell is a flat grey of its own, so a crop can be told apart.
    private static func level(forCell cell: Int) -> Double {
        Double(20 + cell * 28)
    }

    private static func sheetImage(columns: Int, rows: Int, cell: Int) -> CGImage? {
        sheetJPEG(columns: columns, rows: rows, cell: cell).flatMap { UIImage(data: $0)?.cgImage }
    }

    private static func sheetJPEG(columns: Int, rows: Int, cell: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: columns * cell, height: rows * cell)
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) { context in
            for index in 0..<(columns * rows) {
                UIColor(white: level(forCell: index) / 255, alpha: 1).setFill()
                context.fill(CGRect(x: (index % columns) * cell, y: (index / columns) * cell, width: cell, height: cell))
            }
        }
    }

    /// The grey level at the middle of an image, 0 to 255.
    private static func level(of image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        context.interpolationQuality = .none
        let width = CGFloat(image.width), height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return Double(pixel[0])
    }
}

private final class SheetStub: URLProtocol {
    typealias Reply = (Int, Data)
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recorded: [URLRequest] = []
    /// When set, the body is this many chunks of zeros, a few milliseconds
    /// apart, instead of the handler's data.
    private static var chunkPlan: (count: Int, size: Int)?
    private static var declaredLength: Int?
    private static var sent = 0
    private static var stopped = false
    private let stopLock = NSLock()
    private var isStopped = false

    static func configure(chunks: Int? = nil, chunkSize: Int = 0, declaredLength: Int? = nil,
                          _ body: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        handler = body
        recorded = []
        chunkPlan = chunks.map { ($0, chunkSize) }
        Self.declaredLength = declaredLength
        sent = 0
        stopped = false
    }

    static func chunksSent() -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    static func wasStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let body = Self.handler
        let plan = Self.chunkPlan
        let declared = Self.declaredLength
        Self.lock.unlock()
        guard let body, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // Each request is answered on its own thread, so a reply a test
        // holds back can't hold up the others.
        Thread.detachNewThread { [self] in
            respond(body(request), url: url, plan: plan, declared: declared)
        }
    }

    private func respond(_ reply: Reply, url: URL, plan: (count: Int, size: Int)?, declared: Int?) {
        let (status, data) = reply
        var headers = ["Content-Type": "image/jpeg"]
        if let declared { headers["Content-Length"] = String(declared) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard let plan else {
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().async { [self] in
            for _ in 0..<plan.count {
                Thread.sleep(forTimeInterval: 0.02)
                stopLock.lock()
                let halted = isStopped
                stopLock.unlock()
                if halted { return }
                client?.urlProtocol(self, didLoad: Data(count: plan.size))
                Self.lock.lock()
                Self.sent += 1
                Self.lock.unlock()
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopLock.lock()
        isStopped = true
        stopLock.unlock()
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
    }
}
