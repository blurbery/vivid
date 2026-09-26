import XCTest
import ImageIO
@testable import Vivid

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
            let pipeline = makePipeline()
            let url = URL(string: "https://artwork.invalid" + path)!
            var small = VividImageRequest(url: url, cacheScope: "test")
            small.thumbnail = .init(maxPixelSize: 3)
            var large = small
            large.thumbnail = .init(maxPixelSize: 6)
            let before = ArtworkProtocol.count
            async let first = pipeline.image(for: small)
            async let second = pipeline.image(for: large)
            async let bytes = pipeline.data(for: VividImageRequest(url: url, cacheScope: "test"))
            let (smallImage, largeImage, data) = try await (first, second, bytes)
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
        let pipeline = makePipeline()
        let request = VividImageRequest(url: URL(string: "https://artwork.invalid/poster")!, cacheScope: "test")
        let started = expectation(description: "Shared transfer started")
        ArtworkProtocol.onStart = { started.fulfill() }
        let warming = Task { try await pipeline.data(for: request) }
        await fulfillment(of: [started], timeout: 2)
        let display = Task { try await pipeline.image(for: request) }
        // The synthetic transfer stays open for 150 ms while display joins it.
        try await Task.sleep(for: .milliseconds(30))
        warming.cancel()
        let image = try await display.value
        XCTAssertNotNil(image.cgImage)
        do {
            _ = try await warming.value
            XCTFail("The cancelled waiter must not receive data")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ArtworkProtocol.count, 1)
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
    private static var started: (() -> Void)?
    private var response: DispatchWorkItem?
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static var onStart: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return started }
        set { lock.lock(); defer { lock.unlock() }; started = newValue }
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; requests = 0; started = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "artwork.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let onStart = Self.started
        Self.started = nil
        Self.lock.unlock()
        onStart?()
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15, execute: response)
    }
    override func stopLoading() { response?.cancel() }
}
