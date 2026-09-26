import XCTest
import ImageIO
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

final class ImageDataCoalescingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ArtworkProtocol.reset()
    }

    private func makePipeline() -> VividImagePipeline {
        VividImagePipeline(diskCapacity: 0) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ArtworkProtocol.self]
            return configuration
        }
    }

    func testDifferentDecodesAndDiskWarmingShareOneDownloadForEveryProvider() async throws {
        for path in ["/silo/poster?signature=one", "/emby/Items/1/Images/Primary", "/Items/1/Images/Primary"] {
            ArtworkProtocol.holdResponses()
            let pipeline = makePipeline()
            let url = URL(string: "https://artwork.invalid" + path)!
            var small = VividImageRequest(url: url, cacheScope: "test")
            small.thumbnail = .init(maxPixelSize: 3)
            var large = small
            large.thumbnail = .init(maxPixelSize: 6)
            let before = ArtworkProtocol.count
            let first = Task { try await pipeline.image(for: small) }
            let second = Task { try await pipeline.image(for: large) }
            let bytes = Task { try await pipeline.data(for: VividImageRequest(url: url, cacheScope: "test")) }
            defer {
                first.cancel()
                second.cancel()
                bytes.cancel()
                ArtworkProtocol.releaseResponses()
            }
            try await waitForWaiters(3, in: pipeline, request: small)
            ArtworkProtocol.releaseResponses()
            let (smallImage, largeImage, data) = try await (first.value, second.value, bytes.value)
            XCTAssertEqual(ArtworkProtocol.count - before, 1)
            XCTAssertEqual(smallImage.cgImage?.height, 3)
            XCTAssertEqual(largeImage.cgImage?.height, 6)
            XCTAssertFalse(data.isEmpty)
        }
    }

    func testAccountScopesAndSignedURLQueriesStaySeparate() async throws {
        let pipeline = makePipeline()
        let url = URL(string: "https://artwork.invalid/poster?signature=first")!
        async let first = pipeline.data(for: VividImageRequest(url: url, cacheScope: "first"))
        async let account = pipeline.data(for: VividImageRequest(url: url, cacheScope: "second"))
        async let signature = pipeline.data(for: VividImageRequest(
            url: URL(string: "https://artwork.invalid/poster?signature=second")!, cacheScope: "first"))
        _ = try await (first, account, signature)
        XCTAssertEqual(ArtworkProtocol.count, 3)
    }

    func testCancellingOneWaiterDoesNotCancelAnotherSize() async throws {
        ArtworkProtocol.holdResponses()
        let pipeline = makePipeline()
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/poster")!, cacheScope: "test")
        let warming = Task { try await pipeline.data(for: request) }
        let display = Task { try await pipeline.image(for: request) }
        defer {
            warming.cancel()
            display.cancel()
            ArtworkProtocol.releaseResponses()
        }
        try await waitForWaiters(2, in: pipeline, request: request)
        warming.cancel()
        // Confirm cancellation was processed while the response is still held.
        try await waitForWaiters(1, in: pipeline, request: request)
        ArtworkProtocol.releaseResponses()
        let image = try await display.value
        XCTAssertNotNil(image.cgImage)
        do {
            _ = try await warming.value
            XCTFail("The cancelled waiter must not receive data")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ArtworkProtocol.count, 1)
    }

    func testCancellingLastImageWaiterStopsItsDownload() async throws {
        ArtworkProtocol.holdResponses()
        let pipeline = makePipeline()
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/abandoned")!, cacheScope: "test")
        let image = Task { try await pipeline.image(for: request) }
        defer { image.cancel(); ArtworkProtocol.releaseResponses() }
        try await waitForWaiters(1, in: pipeline, request: request)
        try await waitUntil("HTTP request started") { ArtworkProtocol.count == 1 }
        image.cancel()
        try await waitUntil("Abandoned image cancelled its HTTP request") { ArtworkProtocol.stops == 1 }
        try await waitForWaiters(0, in: pipeline, request: request)
        do { _ = try await image.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(pipeline.cache[request])
    }

    func testCancellingOneSameSizeConsumerPreservesVisibleImage() async throws {
        ArtworkProtocol.holdResponses()
        let pipeline = makePipeline()
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/shared")!, cacheScope: "test")
        let warmer = Task { try await pipeline.image(for: request) }
        let visible = Task { try await pipeline.image(for: request) }
        defer { warmer.cancel(); visible.cancel(); ArtworkProtocol.releaseResponses() }
        try await waitUntil("Both image consumers joined") {
            await pipeline.debugImageFlightWaiterCount(for: request) == 2
        }
        try await waitForWaiters(1, in: pipeline, request: request)
        warmer.cancel()
        try await waitUntil("Only visible consumer remains") {
            await pipeline.debugImageFlightWaiterCount(for: request) == 1
        }
        XCTAssertEqual(ArtworkProtocol.stops, 0)
        ArtworkProtocol.releaseResponses()
        let image = try await visible.value
        XCTAssertNotNil(image.cgImage)
        do { _ = try await warmer.value; XCTFail("Cancelled consumer received an image") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ArtworkProtocol.count, 1)
    }

    func testCancellingImageSizePreservesAnotherSizeSharingTheDownload() async throws {
        ArtworkProtocol.holdResponses()
        let pipeline = makePipeline()
        var small = VividImageRequest(url: URL(string: "https://artwork.invalid/sizes")!, cacheScope: "test")
        small.thumbnail = .init(maxPixelSize: 3)
        var large = small
        large.thumbnail = .init(maxPixelSize: 6)
        let first = Task { try await pipeline.image(for: small) }
        let second = Task { try await pipeline.image(for: large) }
        defer { first.cancel(); second.cancel(); ArtworkProtocol.releaseResponses() }
        try await waitForWaiters(2, in: pipeline, request: small)
        first.cancel()
        try await waitForWaiters(1, in: pipeline, request: small)
        XCTAssertEqual(ArtworkProtocol.stops, 0)
        ArtworkProtocol.releaseResponses()
        let image = try await second.value
        XCTAssertEqual(image.cgImage?.height, 6)
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ArtworkProtocol.count, 1)
    }

    func testMemoryPrefetchCancellationAllowsVisibleRetry() async throws {
        ArtworkProtocol.holdResponses()
        let pipeline = makePipeline()
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/prefetch")!, cacheScope: "test")
        let prefetcher = VividImagePrefetcher(pipeline: pipeline, destination: .memoryCache)
        defer { prefetcher.stopPrefetching(); ArtworkProtocol.releaseResponses() }
        prefetcher.startPrefetching(with: [request])
        try await waitForWaiters(1, in: pipeline, request: request)
        try await waitUntil("Prefetch request started") { ArtworkProtocol.count == 1 }
        prefetcher.stopPrefetching(with: [request])
        try await waitUntil("Memory prefetch stopped its transfer") { ArtworkProtocol.stops == 1 }
        try await waitForWaiters(0, in: pipeline, request: request)
        ArtworkProtocol.releaseResponses()
        let image = try await pipeline.image(for: request)
        XCTAssertNotNil(image.cgImage)
        XCTAssertEqual(ArtworkProtocol.count, 2)
    }

    func testCancelledQueuedDecodeCannotFillCacheOrRemoveReplacement() async throws {
        let pipeline = makePipeline()
        pipeline.debugSuspendDecoding(true)
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/queued")!, cacheScope: "test")
        let abandoned = Task { try await pipeline.image(for: request) }
        defer { abandoned.cancel(); pipeline.debugSuspendDecoding(false) }
        try await waitUntil("First decode queued") { pipeline.debugPendingDecodeCount == 1 }
        abandoned.cancel()
        try await waitUntil("Abandoned image flight released") {
            await pipeline.debugImageFlightWaiterCount(for: request) == 0
        }
        // A new request for the same image must survive the retired flight's
        // eventual completion, including its deferred consumer cleanup.
        let replacement = Task { try await pipeline.image(for: request) }
        defer { replacement.cancel() }
        try await waitUntil("Replacement decode queued") { pipeline.debugPendingDecodeCount == 2 }
        XCTAssertNil(pipeline.cache[request])
        pipeline.debugSuspendDecoding(false)
        do { _ = try await abandoned.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let image = try await replacement.value
        XCTAssertNotNil(image.cgImage)
        XCTAssertNotNil(pipeline.cache[request])
        XCTAssertEqual(ArtworkProtocol.count, 2)
    }

    func testAccountSwitchPreventsQueuedImageFromRefillingMemory() async throws {
        let pipeline = makePipeline()
        pipeline.debugSuspendDecoding(true)
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/account")!, cacheScope: "old")
        let old = Task { try await pipeline.image(for: request) }
        defer { old.cancel(); pipeline.debugSuspendDecoding(false) }
        try await waitUntil("Outgoing account decode queued") { pipeline.debugPendingDecodeCount == 1 }
        await pipeline.cancelForAccountSwitch()
        pipeline.debugSuspendDecoding(false)
        do { _ = try await old.value; XCTFail("Outgoing account image survived cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(pipeline.cache[request])
        let incoming = VividImageRequest(url: request.url, cacheScope: "new")
        let image = try await pipeline.image(for: incoming)
        XCTAssertNotNil(image.cgImage)
        XCTAssertNil(pipeline.cache[request])
        XCTAssertNotNil(pipeline.cache[incoming])
    }

    private func waitUntil(_ message: String, condition: () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitForWaiters(_ count: Int, in pipeline: VividImagePipeline,
                                request: VividImageRequest, file: StaticString = #filePath,
                                line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await pipeline.debugDataFlightWaiterCount(for: request) != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Shared transfer did not reach \(count) waiters", file: file, line: line)
                throw URLError(.timedOut)
            }
            // Poll only to observe registration; elapsed time never signals readiness.
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testCancellingLastWaiterStopsTheTransfer() async throws {
        let flights = VividImageDataFlights()
        let started = expectation(description: "Transfer started")
        let stopped = expectation(description: "Transfer cancelled")
        let waiter = Task {
            try await flights.load(URL(string: "https://artwork.invalid/poster")!) {
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return Data([1])
                } catch {
                    stopped.fulfill()
                    throw error
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        waiter.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFailureIsNotRetainedAsAnInFlightResult() async throws {
        let flights = VividImageDataFlights()
        let url = URL(string: "https://artwork.invalid/poster")!
        do {
            _ = try await flights.load(url) { throw URLError(.badServerResponse) }
            XCTFail("Expected the shared operation to fail")
        } catch {}
        let recovered = try await flights.load(url) { Data([2]) }
        XCTAssertEqual(recovered, Data([2]))
    }

    func testCancellingOneURLLeavesOtherArtworkRunning() async throws {
        let flights = VividImageDataFlights()
        let firstURL = URL(string: "https://artwork.invalid/first")!
        let secondURL = URL(string: "https://artwork.invalid/second")!
        let started = expectation(description: "First artwork started")
        let first = Task {
            try await flights.load(firstURL, scope: "test") {
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
                return Data([1])
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let second = Task {
            try await flights.load(secondURL, scope: "test") {
                try await Task.sleep(for: .milliseconds(50))
                return Data([2])
            }
        }
        await flights.cancel(urls: [firstURL], scope: "test")
        let retained = try await second.value
        XCTAssertEqual(retained, Data([2]))
        do {
            _ = try await first.value
            XCTFail("Expected targeted cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

/// Synthetic HTTP responses only. No server credentials or real network I/O.
private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    private static var stoppedRequests = 0
    private static var holdingResponses = false
    private static var pending: [DispatchWorkItem] = []
    private var response: DispatchWorkItem?
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static var stops: Int { lock.lock(); defer { lock.unlock() }; return stoppedRequests }
    static func holdResponses() {
        lock.lock(); defer { lock.unlock() }
        holdingResponses = true
    }
    static func releaseResponses() {
        lock.lock()
        holdingResponses = false
        let responses = pending
        pending.removeAll()
        lock.unlock()
        responses.forEach { DispatchQueue.global().async(execute: $0) }
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = 0
        stoppedRequests = 0
        holdingResponses = false
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        Self.lock.unlock()
        let response = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let context = CGContext(data: nil, width: 8, height: 12, bitsPerComponent: 8,
                                    bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
            let http = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Cache-Control": "no-store", "Content-Type": "image/png"])!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data as Data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.response = response
        Self.lock.lock()
        let held = Self.holdingResponses
        if held { Self.pending.append(response) }
        Self.lock.unlock()
        if !held { DispatchQueue.global().async(execute: response) }
    }
    override func stopLoading() {
        response?.cancel()
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.stoppedRequests += 1
    }
}
