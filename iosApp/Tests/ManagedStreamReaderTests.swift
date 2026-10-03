import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// A scripted origin. Each request is answered by `respond`, which sees the
/// request and its index and returns a status, headers and body, optionally
/// cutting the connection after `dropAfter` bytes.
private final class ScriptedOrigin: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 206
        var headers: [String: String] = [:]
        var body = Data()
        var dropAfter: Int?
        var delay: TimeInterval = 0
        var redirect: URL?
    }

    nonisolated(unsafe) static var respond: ((URLRequest, Int) -> Reply)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stopped = false

    override func startLoading() {
        Self.lock.lock()
        let index = Self.requests.count
        Self.requests.append(request)
        let reply = Self.respond?(request, index) ?? Reply(status: 500)
        Self.lock.unlock()
        let deliver = { [self] in
            if let target = reply.redirect, let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                              headerFields: ["Location": target.absoluteString]) {
                client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            guard !stopped, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                                 headerFields: reply.headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let dropAfter = reply.dropAfter {
                // Let the received bytes reach the reader before the drop, as
                // they would from a real socket.
                client?.urlProtocol(self, didLoad: reply.body.prefix(dropAfter))
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                    guard !stopped else { return }
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                }
                return
            }
            // Deliver in several chunks like a real socket.
            var offset = 0
            while offset < reply.body.count {
                let end = min(reply.body.count, offset + 64 * 1024)
                client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() { stopped = true }
}

final class ManagedStreamReaderTests: XCTestCase {
    private let url = URL(string: "https://silo.example/api/v2/stream/session")!
    private var file = Data()
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        file = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        ScriptedOrigin.requests = []
        ScriptedOrigin.respond = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedOrigin.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        ScriptedOrigin.respond = nil
        super.tearDown()
    }

    private func offset(of request: URLRequest) -> Int {
        let range = request.value(forHTTPHeaderField: "Range") ?? "bytes=0-"
        return Int(range.dropFirst(6).dropLast()) ?? 0
    }

    /// A correct 206 for whatever range was asked.
    private func ranged(_ request: URLRequest, etag: String = "\"v1\"") -> ScriptedOrigin.Reply {
        let start = offset(of: request)
        return ScriptedOrigin.Reply(
            status: 206,
            headers: ["Content-Range": "bytes \(start)-\(file.count - 1)/\(file.count)", "ETag": etag,
                      "Content-Length": "\(file.count - start)"],
            body: file.subdata(in: start..<file.count))
    }

    private func makeReader(headers: [String: String] = ["Authorization": "Bearer old"],
                            refresh: @escaping @Sendable () async -> [String: String]? = { nil },
                            highWater: Int = 16 << 20, lowWater: Int = 4 << 20,
                            retry: VividManagedStreamRetryPolicy = VividManagedStreamRetryPolicy(maxStallSeconds: 5)) -> VividManagedStreamReader {
        VividManagedStreamReader(source: VividManagedStreamSource(url: url, headers: headers, refresh: refresh),
                                 session: session, retry: retry, highWater: highWater, lowWater: lowWater,
                                 refreshTimeout: 3)
    }

    private func readAll(_ reader: VividManagedStreamReader, chunk: Int = 100_000) -> Data? {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, count: chunk) }
            if count < 0 { return nil }
            if count == 0 { return output }
            output.append(contentsOf: buffer[0..<Int(count)])
        }
    }

    func testReadsWholeFileAndReportsSize() {
        ScriptedOrigin.respond = { request, _ in self.ranged(request) }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertEqual(reader.size, Int64(file.count))
        XCTAssertEqual(readAll(reader), file)
        XCTAssertEqual(ScriptedOrigin.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer old")
    }

    func testDroppedConnectionResumesAtTheExactByte() {
        ScriptedOrigin.respond = { request, index in
            var reply = self.ranged(request)
            if index < 2 { reply.dropAfter = 700_000 }
            return reply
        }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertEqual(readAll(reader), file, "Bytes across reconnects must be identical")
        let offsets = ScriptedOrigin.requests.map(offset(of:))
        XCTAssertEqual(offsets, [0, 700_000, 1_400_000])
        XCTAssertEqual(ScriptedOrigin.requests.last?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
    }

    func testExpiredBearerIsRefreshedAndTheStreamContinues() {
        let refreshed = expectation(description: "refresh")
        ScriptedOrigin.respond = { request, index in
            switch index {
            case 0: var reply = self.ranged(request); reply.dropAfter = 1_000_000; return reply
            case 1: return ScriptedOrigin.Reply(status: 401)
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new")
                return self.ranged(request)
            }
        }
        let reader = makeReader(refresh: { refreshed.fulfill(); return ["Authorization": "Bearer new"] })
        XCTAssertTrue(reader.open())
        XCTAssertEqual(readAll(reader), file)
        wait(for: [refreshed], timeout: 1)
        XCTAssertEqual(ScriptedOrigin.requests.map(offset(of:)), [0, 1_000_000, 1_000_000])
    }

    func testProactiveHeaderUpdateIsUsedOnTheNextReconnect() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { var reply = self.ranged(request); reply.dropAfter = 500_000; return reply }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rotated")
            return self.ranged(request)
        }
        let reader = makeReader(refresh: { XCTFail("No refresh should be needed"); return nil })
        XCTAssertTrue(reader.open())
        reader.source.update(["Authorization": "Bearer rotated"])
        XCTAssertEqual(readAll(reader), file)
    }

    func testPersistentRejectionFailsInsteadOfLooping() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { var reply = self.ranged(request); reply.dropAfter = 100_000; return reply }
            return ScriptedOrigin.Reply(status: 401)
        }
        let reader = makeReader(refresh: { ["Authorization": "Bearer still-bad"] })
        XCTAssertTrue(reader.open())
        XCTAssertNil(readAll(reader))
        XCTAssertLessThanOrEqual(ScriptedOrigin.requests.count, 5)
    }

    func testSeekOutsideTheBufferRequestsTheNewRange() {
        ScriptedOrigin.respond = { request, _ in self.ranged(request) }
        let reader = makeReader(highWater: 256 * 1024, lowWater: 64 * 1024)
        XCTAssertTrue(reader.open())
        XCTAssertEqual(reader.seek(to: 2_500_000), 2_500_000)
        XCTAssertEqual(readAll(reader), file.subdata(in: 2_500_000..<file.count))
        XCTAssertEqual(Array(ScriptedOrigin.requests.map(offset(of:)).prefix(2)), [0, 2_500_000])
        XCTAssertNil(reader.seek(to: Int64(file.count + 1)))
    }

    /// The origin keeps sending as fast as it can, as URLSession did after
    /// suspend(). The reader must end the request at the high-water mark and
    /// continue with a new range, so it never holds anywhere near the whole
    /// file, and the bytes must still join up exactly. URLSession can merge
    /// deliveries, so the bound allows for one large delivery.
    func testBufferStaysBoundedAgainstAFastOrigin() {
        file = Data((0..<12_000_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
        ScriptedOrigin.respond = { request, _ in self.ranged(request) }
        let highWater = 256 * 1024
        let reader = makeReader(highWater: highWater, lowWater: 64 * 1024)
        XCTAssertTrue(reader.open())
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var peak = 0
        while true {
            // Give the origin time to overrun the buffer if nothing stops it.
            Thread.sleep(forTimeInterval: 0.002)
            peak = max(peak, reader.bufferedBytes)
            let count = buffer.withUnsafeMutableBytes { reader.read(into: $0.baseAddress!, count: 32 * 1024) }
            XCTAssertGreaterThanOrEqual(count, 0)
            if count <= 0 { break }
            output.append(contentsOf: buffer[0..<Int(count)])
        }
        XCTAssertEqual(output, file)
        XCTAssertLessThan(peak, 4_000_000, "the reader held most of the file")
        let offsets = ScriptedOrigin.requests.map(offset(of:))
        XCTAssertGreaterThan(offsets.count, 1, "the transfer continues with new ranges")
        XCTAssertEqual(offsets, offsets.sorted(), "each range continues after the last")
    }

    func testSeekToStartAfterOpenDoesNotReconnect() {
        ScriptedOrigin.respond = { request, _ in self.ranged(request) }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertEqual(reader.seek(to: 0), 0)
        XCTAssertEqual(readAll(reader), file)
        XCTAssertEqual(ScriptedOrigin.requests.count, 1)
    }

    func testCancelUnblocksAWaitingRead() {
        ScriptedOrigin.respond = { request, index in
            var reply = self.ranged(request)
            if index > 0 { reply.delay = 30 }
            return reply
        }
        let reader = makeReader(retry: VividManagedStreamRetryPolicy(maxStallSeconds: 60))
        XCTAssertTrue(reader.open())
        XCTAssertEqual(reader.seek(to: 2_500_000), 2_500_000)
        let finished = expectation(description: "read returns")
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            XCTAssertEqual(reader.read(into: &byte, count: 1), -1)
            finished.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { reader.cancel() }
        wait(for: [finished], timeout: 3)
    }

    func testDropBeforeAnyReadKeepsBufferedBytes() {
        ScriptedOrigin.respond = { request, index in
            var reply = self.ranged(request)
            if index == 0 { reply.dropAfter = 0 }
            return reply
        }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertEqual(readAll(reader), file)
    }

    func testChangedFileIsRefusedRatherThanSpliced() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { var reply = self.ranged(request); reply.dropAfter = 300_000; return reply }
            // If-Range mismatch: the origin answers with the whole new file.
            return ScriptedOrigin.Reply(status: 200, headers: ["Content-Length": "\(self.file.count)"], body: self.file)
        }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertNil(readAll(reader))
    }

    func testStallLimitEventuallyFails() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { var reply = self.ranged(request); reply.dropAfter = 100_000; return reply }
            return ScriptedOrigin.Reply(status: 503)
        }
        let reader = makeReader(retry: VividManagedStreamRetryPolicy(maxStallSeconds: 1))
        XCTAssertTrue(reader.open())
        let started = Date()
        XCTAssertNil(readAll(reader))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testStoppingThePlayerUnblocksAConnectingOpen() {
        ScriptedOrigin.respond = { request, _ in var reply = self.ranged(request); reply.delay = 30; return reply }
        let reader = makeReader()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { reader.source.cancel() }
        let started = Date()
        XCTAssertFalse(reader.open(timeout: 30))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCancelledSourceRefusesNewReaders() {
        ScriptedOrigin.respond = { request, _ in self.ranged(request) }
        let source = VividManagedStreamSource(url: url, headers: [:], refresh: { nil })
        source.cancel()
        let reader = VividManagedStreamReader(source: source, session: session)
        XCTAssertFalse(reader.open(timeout: 1))
        XCTAssertTrue(ScriptedOrigin.requests.isEmpty)
    }

    func testRejectedBearerAtOpenFailsFastWithoutRefreshing() {
        ScriptedOrigin.respond = { _, _ in ScriptedOrigin.Reply(status: 401) }
        let reader = makeReader(refresh: { XCTFail("Open must not refresh"); return nil })
        let started = Date()
        XCTAssertFalse(reader.open(timeout: 30))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRedirectsNeverCarryTheBearerElsewhere() {
        let targets = [URL(string: "https://other.example/stream")!,
                       URL(string: "http://silo.example/api/v2/stream/session")!]
        for target in targets {
            ScriptedOrigin.requests = []
            ScriptedOrigin.respond = { request, index in
                if index == 0 { return ScriptedOrigin.Reply(status: 302, redirect: target) }
                return self.ranged(request)
            }
            let started = Date()
            XCTAssertFalse(makeReader().open(timeout: 10), "\(target)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "A refused redirect fails without retrying")
            XCTAssertEqual(ScriptedOrigin.requests.count, 1)
            XCTAssertFalse(ScriptedOrigin.requests.contains { $0.url?.host != "silo.example" || $0.url?.scheme != "https" },
                           "No request may reach \(target)")
        }
    }

    func testChangedEntityTagIsRefusedEvenFromTheFirstByte() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { return self.ranged(request) }
            // A restart from byte 0 gets a 200 with the same size but a new file.
            return ScriptedOrigin.Reply(status: 200, headers: ["Content-Length": "\(self.file.count)", "ETag": "\"v2\""],
                                        body: self.file)
        }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        var byte: UInt8 = 0
        XCTAssertEqual(reader.read(into: &byte, count: 1), 1)
        XCTAssertEqual(reader.seek(to: 2_000_000), 2_000_000)
        XCTAssertEqual(reader.seek(to: 0), 0)
        XCTAssertNil(readAll(reader))
    }

    func testOriginIgnoringIfRangeCannotSpliceANewFile() {
        for changed in ["\"v2\"", "W/\"v2\""] {
            ScriptedOrigin.requests = []
            ScriptedOrigin.respond = { request, index in
                if index == 0 { var reply = self.ranged(request); reply.dropAfter = 500_000; return reply }
                return self.ranged(request, etag: changed)
            }
            let reader = makeReader()
            XCTAssertTrue(reader.open())
            XCTAssertNil(readAll(reader), "Reconnect tagged \(changed) must be refused")
        }
    }

    func testWeakFormOfTheSameTagStillContinues() {
        ScriptedOrigin.respond = { request, index in
            if index == 0 { var reply = self.ranged(request); reply.dropAfter = 500_000; return reply }
            return self.ranged(request, etag: "W/\"v1\"")
        }
        let reader = makeReader()
        XCTAssertTrue(reader.open())
        XCTAssertEqual(readAll(reader), file)
    }

    func testOpenFailsForAMissingSession() {
        ScriptedOrigin.respond = { _, _ in ScriptedOrigin.Reply(status: 404) }
        XCTAssertFalse(makeReader().open(timeout: 3))
    }

    func testResponseClassification() {
        typealias R = VividManagedStreamResponse
        XCTAssertEqual(R.classify(status: 206, requestedOffset: 10, contentRange: "bytes 10-99/100", contentLength: 90, knownTotal: nil), .bytes(total: 100))
        XCTAssertEqual(R.classify(status: 206, requestedOffset: 10, contentRange: "bytes 11-99/100", contentLength: 89, knownTotal: nil), .fatal("206 started at 11, requested 10"))
        XCTAssertEqual(R.classify(status: 206, requestedOffset: 0, contentRange: "bytes 0-9/*", contentLength: 10, knownTotal: 100), .bytes(total: 100))
        XCTAssertEqual(R.classify(status: 206, requestedOffset: 0, contentRange: "bytes 0-9/50", contentLength: 10, knownTotal: 100), .fatal("size changed from 100 to 50"))
        XCTAssertEqual(R.classify(status: 200, requestedOffset: 0, contentRange: nil, contentLength: 100, knownTotal: nil), .bytes(total: 100))
        XCTAssertEqual(R.classify(status: 200, requestedOffset: 5, contentRange: nil, contentLength: 100, knownTotal: 100), .fatal("200 for a ranged request"))
        XCTAssertEqual(R.classify(status: 416, requestedOffset: 100, contentRange: nil, contentLength: 0, knownTotal: 100), .endOfStream)
        XCTAssertEqual(R.classify(status: 401, requestedOffset: 0, contentRange: nil, contentLength: 0, knownTotal: nil), .authentication)
        XCTAssertEqual(R.classify(status: 503, requestedOffset: 0, contentRange: nil, contentLength: 0, knownTotal: nil), .transient)
        XCTAssertEqual(R.classify(status: 404, requestedOffset: 0, contentRange: nil, contentLength: 0, knownTotal: nil), .fatal("HTTP 404"))
        XCTAssertNil(R.ContentRange("bytes 9-1/100"))
        XCTAssertFalse(VividManagedStreamSource.isEligible(URL(string: "http://lan.example/stream")!))
        XCTAssertTrue(VividManagedStreamSource.isEligible(url))
    }
}
