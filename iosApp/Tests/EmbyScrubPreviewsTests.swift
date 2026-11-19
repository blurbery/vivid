import UIKit
import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Emby's seek preview stills: the BIF index, reading it and its stills by
/// byte range, and the scrub provider end to end. Every file here is made in
/// the test.
@MainActor
final class EmbyScrubPreviewsTests: XCTestCase {
    nonisolated private static let headers = ["X-Emby-Authorization": "Emby Client=\"Vivid\"", "X-Emby-Token": "token"]
    /// Uneven on purpose: nothing may assume a fixed interval.
    nonisolated private static let seconds: [UInt32] = [5, 10, 20, 35, 50, 60, 70, 80, 90, 100, 110, 120]

    // MARK: - Index

    func testAnIndexGivesEachStillItsStartAndByteRange() throws {
        let stills = [Data([1, 2, 3]), Data([4, 5]), Data([6, 7, 8, 9])]
        let file = Self.bif(stills: stills, timestamps: [0, 4, 9], unit: 500)
        guard case let .index(index) = BIFIndex.parse(file, totalLength: nil, isWholeFile: true) else {
            return XCTFail("a sound file has an index")
        }
        XCTAssertEqual(index.startsMilliseconds, [0, 2000, 4500])
        XCTAssertEqual(index.offsets, [96, 99, 101, 105])
        XCTAssertEqual(file.count, 105)
        // The start of the file is enough when it holds the whole index.
        XCTAssertEqual(BIFIndex.parse(file.prefix(96), totalLength: 105, isWholeFile: false), .index(index))
        // A slice that doesn't start at index zero reads the same.
        let padded = Data([0, 0, 0]) + file
        XCTAssertEqual(BIFIndex.parse(padded.dropFirst(3), totalLength: nil, isWholeFile: true), .index(index))
    }

    func testAUnitOfZeroMeansSeconds() {
        let file = Self.bif(stills: [Data([1]), Data([2])], timestamps: [0, 10], unit: 0)
        guard case let .index(index) = BIFIndex.parse(file, totalLength: nil, isWholeFile: true) else {
            return XCTFail("a unit of zero is allowed")
        }
        XCTAssertEqual(index.startsMilliseconds, [0, 10_000])
    }

    func testAnIndexCutShortAsksForTheRestOrIsRefused() {
        let file = Self.bif(stills: [Data([1]), Data([2]), Data([3])], timestamps: [0, 1, 2])
        // 64 bytes of header, then four entries of eight bytes.
        XCTAssertEqual(BIFIndex.parse(file.prefix(80), totalLength: nil, isWholeFile: false), .needs(96))
        XCTAssertEqual(BIFIndex.parse(file.prefix(80), totalLength: nil, isWholeFile: true), .invalid)
        XCTAssertEqual(BIFIndex.parse(file.prefix(40), totalLength: nil, isWholeFile: false), .invalid)
        XCTAssertEqual(BIFIndex.parse(Data(), totalLength: nil, isWholeFile: true), .invalid)
        // The file is known to end before its own index does.
        XCTAssertEqual(BIFIndex.parse(file.prefix(80), totalLength: 90, isWholeFile: false), .invalid)
    }

    func testABrokenFileIsRefused() {
        let stills = [Data([1, 1]), Data([2, 2]), Data([3, 3])]
        let good = Self.bif(stills: stills, timestamps: [0, 1, 2])
        func parsed(_ change: (inout Data) -> Void) -> BIFIndex.Outcome {
            var file = good
            change(&file)
            return BIFIndex.parse(file, totalLength: nil, isWholeFile: true)
        }
        XCTAssertNotEqual(parsed { _ in }, .invalid)
        XCTAssertEqual(parsed { $0[1] = 0x4A }, .invalid, "wrong identifying bytes")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 12, to: 0) }, .invalid, "no stills")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 12, to: 0xFFFF_FFFF) }, .invalid, "an absurd count")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 12, to: 100_001) }, .invalid, "more stills than allowed")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 16, to: 3_600_000) }, .invalid, "an absurd unit")
        // Entry 1's offset, at 64 + 8 + 4.
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 76, to: 96) }, .invalid, "an empty still")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 76, to: 90) }, .invalid, "offsets going backwards")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 68, to: 70) }, .invalid, "a still inside the index")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 92, to: 5000) }, .invalid, "an end past the file")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 72, to: 0) }, .invalid, "a timestamp that doesn't move on")
        XCTAssertEqual(parsed { Self.setWord(&$0, at: 80, to: 0xFFFF_FFFF) }, .invalid, "the end marker too early")
        XCTAssertEqual(
            parsed { Self.setWord(&$0, at: 92, to: UInt32(ScrubPreviewSheets.Container.maximumStillBytes) + 200) },
            .invalid, "a still too big to be a preview")
        // With the length known from the server, an end past it is refused
        // before any still is asked for.
        XCTAssertEqual(BIFIndex.parse(good.prefix(96), totalLength: 100, isWholeFile: false), .invalid)
    }

    // MARK: - Time mapping

    func testATimeMapsToTheLastStillAtOrBeforeIt() throws {
        let sheets = try XCTUnwrap(Self.sheets(startsSeconds: [5, 10, 20, 35, 50]))
        XCTAssertEqual(sheets.sheetCount, 5)
        func still(_ time: Double) -> Int? { sheets.tile(atSourceTime: time)?.sheet }
        XCTAssertEqual(still(0), 0, "before the first still, the first one")
        XCTAssertEqual(still(4.9), 0)
        XCTAssertEqual(still(5), 0)
        XCTAssertEqual(still(9.999), 0)
        XCTAssertEqual(still(10), 1)
        XCTAssertEqual(still(19.9), 1)
        XCTAssertEqual(still(34.9), 2)
        XCTAssertEqual(still(35), 3)
        XCTAssertEqual(still(50), 4)
        XCTAssertEqual(still(70), 4, "the last still covers the tail")
        // The typical gap is 11.25 s; two of them past the last start is a
        // different, longer file.
        XCTAssertNil(still(72.5))
        XCTAssertNil(still(-1))
        XCTAssertNil(still(.nan))
        XCTAssertEqual(sheets.tile(atSourceTime: 36), .init(index: 3, sheet: 3, column: 0, row: 0))

        let single = try XCTUnwrap(Self.sheets(startsSeconds: [0]))
        XCTAssertEqual(single.tile(atSourceTime: 900)?.sheet, 0)
    }

    func testAContainerThatCannotAddressItsStillsIsRefused() {
        let url = URL(string: "https://media.example.invalid/emby/Videos/1/index.bif")!
        func sheets(starts: [Int], offsets: [Int]) -> ScrubPreviewSheets? {
            ScrubPreviewSheets(
                key: "k", container: .init(url: url, startsMilliseconds: starts, offsets: offsets, whole: nil), headers: [:])
        }
        XCTAssertNotNil(sheets(starts: [0, 10], offsets: [80, 90, 100]))
        XCTAssertNil(sheets(starts: [], offsets: [80]))
        XCTAssertNil(sheets(starts: [0, 10], offsets: [80, 90]))
        XCTAssertNil(sheets(starts: [10, 10], offsets: [80, 90, 100]))
        XCTAssertNil(sheets(starts: [0, 10], offsets: [80, 80, 100]))
        XCTAssertNil(sheets(starts: [-1, 10], offsets: [80, 90, 100]))
    }

    // MARK: - Description

    func testTheDescriptionNamesTheItemsOwnFileAndAsksNothing() throws {
        RangeStub.serve(Data())
        let item: [String: Any] = ["Id": "123", "MediaSources": [["Id": "mediasource_123"]]]
        let source = try XCTUnwrap(EmbyScrubPreviews.source(
            item: item, itemID: "123", sourceID: "mediasource_123",
            serverURL: "https://media.example.invalid", headers: Self.headers))
        XCTAssertEqual(source.url.absoluteString, "https://media.example.invalid/emby/Videos/123/index.bif?Width=320")
        XCTAssertEqual(source.key, "emby|https://media.example.invalid|123|mediasource_123|320")
        XCTAssertEqual(source.headers, Self.headers)

        // The route can't name an alternate version, so one gets no stills
        // rather than another file's.
        let versions: [String: Any] = ["Id": "123", "MediaSources": [["Id": "mediasource_123"], ["Id": "mediasource_456"]]]
        XCTAssertNotNil(EmbyScrubPreviews.source(
            item: versions, itemID: "123", sourceID: "mediasource_123",
            serverURL: "https://media.example.invalid", headers: Self.headers))
        XCTAssertNil(EmbyScrubPreviews.source(
            item: versions, itemID: "123", sourceID: "mediasource_456",
            serverURL: "https://media.example.invalid", headers: Self.headers))
        XCTAssertNil(EmbyScrubPreviews.source(
            item: item, itemID: "../123", sourceID: "mediasource_123",
            serverURL: "https://media.example.invalid", headers: Self.headers))
        XCTAssertTrue(RangeStub.requests().isEmpty)
    }

    // MARK: - Reading the index

    func testTheIndexIsReadWithOneSmallRangeRequest() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file)
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        XCTAssertTrue(RangeStub.requests().isEmpty, "making the loader asks for nothing")

        let sheets = try await loaded(loader)
        let requests = RangeStub.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Range"), "bytes=0-65535")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Emby-Token"), "token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Emby-Authorization"), "Emby Client=\"Vivid\"")
        XCTAssertEqual(requests[0].url, Self.source().url)
        XCTAssertEqual(sheets.key, Self.source().key)
        XCTAssertEqual(sheets.headers, Self.headers)
        XCTAssertEqual(sheets.sheetCount, Self.seconds.count)
        XCTAssertEqual(sheets.container?.startsMilliseconds, Self.seconds.map { Int($0) * 1000 })
        XCTAssertEqual(sheets.container?.offsets.last, file.count)
        XCTAssertNil(sheets.container?.whole, "a ranged reply keeps no file")
    }

    func testAnIndexLongerThanTheFirstRangeTakesOneMoreRequest() async throws {
        // 9,000 one-byte stills: the index alone is past 64 KiB.
        let count = 9000
        let file = Self.bif(stills: Array(repeating: Data([7]), count: count), timestamps: (0..<count).map(UInt32.init))
        RangeStub.serve(file)
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        let sheets = try await loaded(loader)
        XCTAssertEqual(sheets.sheetCount, count)
        XCTAssertEqual(RangeStub.requests().map { $0.value(forHTTPHeaderField: "Range") },
                       ["bytes=0-65535", "bytes=0-\(64 + 8 * (count + 1) - 1)"])
    }

    func testAFileWithNoPreviewsIsAskedForOnce() async throws {
        RangeStub.configure { _ in .init(status: 404) }
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        let first = await loader.load()
        XCTAssertNil(first)
        let second = await loader.load()
        XCTAssertNil(second)
        XCTAssertEqual(RangeStub.requests().count, 1, "a 404 is the answer, not a failure to retry")
    }

    func testAPassingFailureMayBeAskedAgainAndARedirectIsNotFollowed() async throws {
        let file = try Self.previewFile()
        var answers: [RangeStub.Reply] = [
            .init(status: 500),
            .init(status: 302, headers: ["Location": "https://elsewhere.example.invalid/index.bif"]),
        ]
        let lock = NSLock()
        RangeStub.configure { request in
            lock.lock(); defer { lock.unlock() }
            return answers.isEmpty ? RangeStub.ranged(file, request) : answers.removeFirst()
        }
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        let failed = await loader.load()
        XCTAssertNil(failed)
        let redirected = await loader.load()
        XCTAssertNil(redirected)
        XCTAssertEqual(RangeStub.requests().count, 2)
        XCTAssertFalse(RangeStub.requests().contains { $0.url?.host == "elsewhere.example.invalid" })
        let third = await loader.load()
        XCTAssertNotNil(third)
    }

    func testAnythingThatIsNotAPreviewFileGivesNoStills() async throws {
        RangeStub.serve(Data(repeating: 0x20, count: 4000))
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        let sheets = await loader.load()
        XCTAssertNil(sheets)
    }

    // MARK: - Reading stills

    func testAStillComesWithItsNeighboursInOneRangeRequest() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file)
        let sheets = try XCTUnwrap(Self.sheets(of: file))
        let offsets = try XCTUnwrap(sheets.container?.offsets)
        let store = ScrubPreviewSheetStore(sheets: sheets, session: RangeStub.session())
        defer { store.shutdown() }

        let image = try await still(4, from: store)
        XCTAssertEqual(Self.level(of: image), Self.level(forStill: 4), accuracy: 6)
        // Two before, five after.
        var requests = RangeStub.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Range"), "bytes=\(offsets[2])-\(offsets[10] - 1)")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Emby-Token"), "token")

        // A neighbour is already here.
        let neighbour = try await still(7, from: store)
        XCTAssertEqual(Self.level(of: neighbour), Self.level(forStill: 7), accuracy: 6)
        XCTAssertNotNil(store.cached(4), "stills are small, so more than two stay decoded")
        XCTAssertEqual(RangeStub.requests().count, 1)

        // A still outside the run asks only for what isn't held.
        let further = try await still(10, from: store)
        XCTAssertEqual(Self.level(of: further), Self.level(forStill: 10), accuracy: 6)
        requests = RangeStub.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Range"), "bytes=\(offsets[10])-\(offsets[12] - 1)")
        let outside = await store.image(12)
        XCTAssertNil(outside, "there is no still 12")
    }

    func testAServerThatIgnoresTheRangeSendsTheFileOnce() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file, honoursRange: false)
        // The index request already brought the whole file.
        let loader = EmbyScrubPreviews.Loader(Self.source(), session: RangeStub.session())
        let sheets = try await loaded(loader)
        XCTAssertEqual(sheets.container?.whole, file)
        XCTAssertEqual(RangeStub.requests().count, 1)

        let store = ScrubPreviewSheetStore(sheets: sheets, session: RangeStub.session())
        defer { store.shutdown() }
        XCTAssertNil(store.sheets.container?.whole, "the store holds the file, where it can be given back")
        for number in [0, 6, 11] {
            let image = try await still(number, from: store)
            XCTAssertEqual(Self.level(of: image), Self.level(forStill: number), accuracy: 6)
        }
        XCTAssertEqual(RangeStub.requests().count, 1, "every still is a slice of the file already held")

        // Memory given back means one more download of the file, not one
        // per still.
        store.releaseMemory()
        for number in [3, 9] {
            let image = try await still(number, from: store)
            XCTAssertEqual(Self.level(of: image), Self.level(forStill: number), accuracy: 6)
        }
        XCTAssertEqual(RangeStub.requests().count, 2)
    }

    func testARangeIgnoredForAStillFallsBackToTheWholeFile() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file, honoursRange: false)
        let store = ScrubPreviewSheetStore(sheets: try XCTUnwrap(Self.sheets(of: file)), session: RangeStub.session())
        defer { store.shutdown() }
        for number in [1, 11, 5] {
            let image = try await still(number, from: store)
            XCTAssertEqual(Self.level(of: image), Self.level(forStill: number), accuracy: 6)
        }
        XCTAssertEqual(RangeStub.requests().count, 1)
    }

    func testAWrongRangeFailsTheRunAndWaitsBeforeARetry() async throws {
        let file = try Self.previewFile()
        var isBroken = true
        let lock = NSLock()
        RangeStub.configure { request in
            lock.lock(); defer { lock.unlock() }
            guard isBroken else { return RangeStub.ranged(file, request) }
            // Says it's a part, but isn't the part asked for.
            return .init(status: 206, headers: ["Content-Range": "bytes 0-9/\(file.count)"], body: file.prefix(10))
        }
        var clock = Date(timeIntervalSince1970: 1000)
        let store = ScrubPreviewSheetStore(
            sheets: try XCTUnwrap(Self.sheets(of: file)), session: RangeStub.session(), now: { clock })
        defer { store.shutdown() }
        let failed = await store.image(4)
        XCTAssertNil(failed)
        XCTAssertTrue(store.hasFailed(4))
        let mend = {
            lock.lock()
            isBroken = false
            lock.unlock()
        }
        mend()
        let early = await store.image(4)
        XCTAssertNil(early)
        XCTAssertEqual(RangeStub.requests().count, 1, "nothing is asked again inside the retry delay")
        clock += 31
        let later = await store.image(4)
        XCTAssertNotNil(later)
    }

    func testOneRangeRequestRunsAtATimeNewestNext() async throws {
        // Twenty-four stills, so four runs don't overlap.
        let file = try Self.previewFile(seconds: (0..<24).map { UInt32($0 * 10) })
        let gate = DispatchSemaphore(value: 0)
        RangeStub.configure { request in
            gate.wait()
            return RangeStub.ranged(file, request)
        }
        let sheets = try XCTUnwrap(Self.sheets(of: file))
        let offsets = try XCTUnwrap(sheets.container?.offsets)
        let store = ScrubPreviewSheetStore(sheets: sheets, session: RangeStub.session())
        defer { store.shutdown() }

        async let first = store.image(0)
        try await waitUntil { RangeStub.requests().count == 1 }
        store.prefetch(8)
        store.prefetch(16)
        // Let the two waiting requests join the line.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(RangeStub.requests().count, 1, "the others wait for the one running")

        gate.signal()
        let image = await first
        XCTAssertNotNil(image)
        try await waitUntil { RangeStub.requests().count == 2 }
        XCTAssertEqual(RangeStub.requests()[1].value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=\(offsets[14])-"), true,
                       "the newest goes next")
        gate.signal()
        try await waitUntil { RangeStub.requests().count == 3 }
        XCTAssertEqual(RangeStub.requests()[2].value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=\(offsets[6])-"), true)
        gate.signal()
        let last = await store.image(8)
        XCTAssertNotNil(last)
        XCTAssertEqual(RangeStub.requests().count, 3)
    }

    // MARK: - Provider

    func testNothingIsAskedOfEmbyUntilPlaybackHasStarted() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file)
        let (provider, _) = try makeProvider()
        var previews: [VividScrubPreviewProvider.Preview?] = []
        provider.onPreview = { previews.append($0) }

        provider.activate(try Self.spec(), sheets: Self.sheetSource(), startSourceTime: 36)
        provider.begin(atSourceTime: 36)
        provider.request(atSourceTime: 52)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(RangeStub.requests().isEmpty, "the load hasn't shown a frame yet")
        XCTAssertFalse(previews.contains { $0 != nil })

        provider.playbackStarted()
        // The index first, then the stills around the scrub's target.
        try await waitUntil { previews.contains { $0 != nil } }
        let requests = RangeStub.requests()
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-65535")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Emby-Token") == "token" })
        let still = try XCTUnwrap(previews.last ?? nil)
        XCTAssertEqual(still.sourceTime, 52)
        XCTAssertEqual(Self.level(of: still.image), Self.level(forStill: 4), accuracy: 6)
        await provider.endSession()?.value
    }

    func testAScrubGetsTheRightStillAndAHeldOneAnswersAtOnce() async throws {
        let file = try Self.previewFile()
        RangeStub.serve(file)
        let (provider, _) = try makeProvider()
        var previews: [VividScrubPreviewProvider.Preview?] = []
        provider.onPreview = { previews.append($0) }

        provider.activate(try Self.spec(), sheets: Self.sheetSource(), startSourceTime: 0)
        provider.playbackStarted()
        provider.begin(atSourceTime: 36)
        try await waitUntil { previews.contains { $0 != nil } }
        let first = try XCTUnwrap(previews.last ?? nil)
        XCTAssertEqual(first.sourceTime, 36)
        XCTAssertEqual(Self.level(of: first.image), Self.level(forStill: 3), accuracy: 6)

        // Inside the same still nothing new is published.
        var published = previews.count
        provider.request(atSourceTime: 41)
        XCTAssertEqual(previews.count, published)

        // The next still came in the same range request; it only decodes.
        let asked = RangeStub.requests().count
        provider.request(atSourceTime: 55)
        try await waitUntil { (previews.last ?? nil)?.sourceTime == 55 }
        XCTAssertEqual(Self.level(of: try XCTUnwrap(previews.last ?? nil).image), Self.level(forStill: 4), accuracy: 6)
        XCTAssertEqual(RangeStub.requests().count, asked)

        // Back to a still already decoded: answered before `request` returns.
        published = previews.count
        provider.request(atSourceTime: 37)
        XCTAssertEqual(previews.count, published + 1)
        let back = try XCTUnwrap(previews.last ?? nil)
        XCTAssertEqual(back.sourceTime, 37)
        XCTAssertEqual(Self.level(of: back.image), Self.level(forStill: 3), accuracy: 6)
        XCTAssertEqual(RangeStub.requests().count, asked)

        // Before the first still's own start, the first still.
        provider.request(atSourceTime: 1)
        try await waitUntil { (previews.last ?? nil)?.sourceTime == 1 }
        XCTAssertEqual(Self.level(of: try XCTUnwrap(previews.last ?? nil).image), Self.level(forStill: 0), accuracy: 6)

        provider.endInteraction()
        XCTAssertNil(try XCTUnwrap(previews.last), "ending the scrub clears the still")
        await provider.endSession()?.value
    }

    func testAStillForAnEndedEmbyLoadNeverLands() async throws {
        let file = try Self.previewFile()
        let gate = DispatchSemaphore(value: 0)
        RangeStub.configure { request in
            // The index goes straight out; stills wait for the test.
            if request.value(forHTTPHeaderField: "Range") != "bytes=0-65535" { gate.wait() }
            return RangeStub.ranged(file, request)
        }
        let (provider, _) = try makeProvider()
        var stills = 0
        provider.onPreview = { if $0 != nil { stills += 1 } }
        provider.activate(try Self.spec(), sheets: Self.sheetSource())
        provider.playbackStarted()
        provider.begin(atSourceTime: 36)
        try await waitUntil { RangeStub.requests().count == 2 }

        // The load ends, and another file's begins, while the still is on
        // its way.
        await provider.endSession()?.value
        provider.activate(try Self.spec(), sheets: nil)
        provider.playbackStarted()
        provider.begin(atSourceTime: 36)
        gate.signal()
        try await waitUntil { RangeStub.answered() == 2 }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(stills, 0)
        XCTAssertEqual(RangeStub.requests().count, 2)
        await provider.endSession()?.value
    }

    func testAnEmbyFileWithNoPreviewsIsQuiet() async throws {
        RangeStub.configure { _ in .init(status: 404) }
        let (provider, _) = try makeProvider()
        var stills = 0
        provider.onPreview = { if $0 != nil { stills += 1 } }
        provider.activate(try Self.spec(), sheets: Self.sheetSource())
        provider.playbackStarted()
        try await waitUntil { RangeStub.requests().count == 1 }
        for _ in 0..<4 {
            provider.begin(atSourceTime: 36)
            provider.request(atSourceTime: 50)
            provider.endInteraction()
            for _ in 0..<20 { await Task.yield() }
        }
        XCTAssertEqual(RangeStub.requests().count, 1)
        XCTAssertEqual(stills, 0)
        await provider.endSession()?.value
    }

    // MARK: - Helpers

    private func makeProvider() throws -> (VividScrubPreviewProvider, VividPlaybackController) {
        let controller = try VividPlaybackController()
        // No frame reader, so nothing here opens the stream.
        let provider = VividScrubPreviewProvider(
            engine: controller.engine,
            makeStore: { ScrubPreviewSheetStore(sheets: $0, session: RangeStub.session()) },
            makeReader: { _ in nil }
        )
        return (provider, controller)
    }

    private func loaded(_ loader: EmbyScrubPreviews.Loader, file: StaticString = #filePath,
                        line: UInt = #line) async throws -> ScrubPreviewSheets {
        let sheets = await loader.load()
        return try XCTUnwrap(sheets, file: file, line: line)
    }

    private func still(_ still: Int, from store: ScrubPreviewSheetStore, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> CGImage {
        let image = await store.image(still)
        return try XCTUnwrap(image, file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    private static func spec() throws -> VividLoadSpec {
        try VividLoadSpec(directURL: URL(string: "https://media.example.invalid/video.mkv")!, headers: [:],
                          startPosition: 0, audioOnly: false)
    }

    private static func source() -> ScrubPreviewContainerSource {
        ScrubPreviewContainerSource(
            key: "emby|test|1|mediasource_1|320",
            url: URL(string: "https://media.example.invalid/emby/Videos/1/index.bif?Width=320")!,
            headers: headers)
    }

    /// As the player builds it: a loader that reads the index when asked.
    private static func sheetSource() -> VividScrubPreviewProvider.SheetSource {
        let loader = EmbyScrubPreviews.Loader(source(), session: RangeStub.session())
        return .init(key: source().key) { await loader.load() }
    }

    /// The description a loader would make of `file`, without the requests.
    private static func sheets(of file: Data) -> ScrubPreviewSheets? {
        guard case let .index(index) = BIFIndex.parse(file, totalLength: nil, isWholeFile: true) else { return nil }
        return ScrubPreviewSheets(
            key: source().key,
            container: .init(url: source().url, startsMilliseconds: index.startsMilliseconds,
                             offsets: index.offsets, whole: nil),
            headers: headers)
    }

    private static func sheets(startsSeconds: [Int]) -> ScrubPreviewSheets? {
        ScrubPreviewSheets(
            key: "k",
            container: .init(url: source().url, startsMilliseconds: startsSeconds.map { $0 * 1000 },
                             offsets: Array(stride(from: 100, through: 100 + startsSeconds.count * 10, by: 10)),
                             whole: nil),
            headers: [:])
    }

    /// A preview file with one flat grey JPEG per still.
    private static func previewFile(seconds: [UInt32] = EmbyScrubPreviewsTests.seconds) throws -> Data {
        let stills = try seconds.indices.map { try XCTUnwrap(stillJPEG($0)) }
        return bif(stills: stills, timestamps: seconds)
    }

    /// A BIF file written out from its description.
    private static func bif(stills: [Data], timestamps: [UInt32], unit: UInt32 = 1000) -> Data {
        var file = Data([0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A])
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        append(0)
        append(UInt32(stills.count))
        append(unit)
        file.append(Data(count: 64 - file.count))
        var offset = UInt32(64 + 8 * (stills.count + 1))
        for (still, timestamp) in zip(stills, timestamps) {
            append(timestamp)
            append(offset)
            offset += UInt32(still.count)
        }
        append(0xFFFF_FFFF)
        append(offset)
        stills.forEach { file.append($0) }
        return file
    }

    private static func setWord(_ data: inout Data, at offset: Int, to value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    /// Each still is a flat grey of its own, so one can be told from the next.
    private static func level(forStill still: Int) -> Double {
        Double(16 + still * 10)
    }

    private static func stillJPEG(_ still: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36), format: format)
            .jpegData(withCompressionQuality: 0.95) { context in
                UIColor(white: level(forStill: still) / 255, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
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

/// Answers each request from a handler, on its own thread, and keeps the
/// requests it was sent.
private final class RangeStub: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var recorded: [URLRequest] = []
    private static var finished = 0

    static func configure(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        Self.handler = handler
        recorded = []
        finished = 0
    }

    /// Serves `file` as a server would: the part asked for, or all of it
    /// when ranges aren't honoured.
    static func serve(_ file: Data, honoursRange: Bool = true) {
        configure { honoursRange ? ranged(file, $0) : Reply(status: 200, body: file) }
    }

    static func ranged(_ file: Data, _ request: URLRequest) -> Reply {
        guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes="),
              case let bounds = header.dropFirst(6).split(separator: "-"), bounds.count == 2,
              let lower = Int(bounds[0]), let asked = Int(bounds[1]), lower < file.count, lower <= asked
        else { return Reply(status: 416) }
        let upper = min(asked, file.count - 1)
        return Reply(
            status: 206,
            headers: ["Content-Range": "bytes \(lower)-\(upper)/\(file.count)"],
            body: file.subdata(in: (file.startIndex + lower)..<(file.startIndex + upper + 1)))
    }

    /// How many replies have been handed over in full.
    static func answered() -> Int {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Thread.detachNewThread { [self] in
            let reply = handler(request)
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"].flatMap(URL.init(string:)) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
            Self.lock.lock()
            Self.finished += 1
            Self.lock.unlock()
        }
    }

    override func stopLoading() {}
}
