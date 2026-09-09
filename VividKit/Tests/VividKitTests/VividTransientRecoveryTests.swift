import Foundation
import XCTest
@testable import VividKit

final class VividTransientRecoveryTests: XCTestCase {
    func testProlongedOutageExhaustsSharedBudgetWithoutLosingRetainedBytes() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedRangeProtocol.self]
        let budget = VividTransientRecoveryBudget()
        let network = try VividNetwork(VividSource(url: URL(string: "https://example.invalid/outage")!, recoveryBudget: budget), configuration: configuration)
        defer { network.cancel() }
        var byte: UInt8 = 0
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        network.observeDelivery(headroom: 20, active: true)
        InterruptedRangeProtocol.failActive()
        XCTAssertTrue(InterruptedRangeProtocol.waitForResume())
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 1)
        XCTAssertLessThan(network.read(into: &byte, count: 1), 0)
        XCTAssertEqual(network.lastFailure, .network(NSURLErrorNetworkConnectionLost))
        XCTAssertFalse(budget.beginNetworkRetry())
        XCTAssertTrue(budget.beginReload())
        XCTAssertFalse(budget.beginReload())
    }

    func testCancellationPreventsProactiveRetry() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedRangeProtocol.self]
        let budget = VividTransientRecoveryBudget()
        let network = try VividNetwork(VividSource(url: URL(string: "https://example.invalid/media")!, recoveryBudget: budget), configuration: configuration)
        var byte: UInt8 = 0
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        network.observeDelivery(headroom: 20, active: true)
        network.cancel()
        InterruptedRangeProtocol.failActive()
        network.observeDelivery(headroom: 16, active: true)
        XCTAssertLessThan(network.read(into: &byte, count: 1), 0)
        XCTAssertTrue(budget.beginNetworkRetry())
        XCTAssertTrue(budget.beginNetworkRetry())
    }

    func testRangeRecoveryRequiresStrongIdentity() {
        let url = URL(string: "https://example.invalid/media")!
        for tag in ["W/\"weak\"", "malformed", "\"bad\"tag\""] {
            XCTAssertEqual(VividRangeValidator(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
                headerFields: ["ETag": tag])!), nil)
        }
        let dated = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Date": "Wed, 09 Sep 2026 08:00:00 GMT", "Last-Modified": "Tue, 08 Sep 2026 08:00:00 GMT"])!
        XCTAssertEqual(VividRangeValidator(dated)?.field, "Last-Modified")
        let recent = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Date": "Wed, 09 Sep 2026 08:00:00 GMT", "Last-Modified": "Wed, 09 Sep 2026 08:00:00 GMT"])!
        XCTAssertEqual(VividRangeValidator(recent), nil)
    }

    func testProactiveRetryRetainsUnreadBytesAndStartsAtFirstMissingByte() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedRangeProtocol.self]
        let budget = VividTransientRecoveryBudget()
        let network = try VividNetwork(VividSource(url: URL(string: "https://example.invalid/media")!, recoveryBudget: budget), configuration: configuration)
        defer { network.cancel() }
        var byte: UInt8 = 0
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 0)
        network.observeDelivery(headroom: 20, active: true)
        InterruptedRangeProtocol.failActive()
        XCTAssertTrue(InterruptedRangeProtocol.waitForResume())
        var received: [UInt8] = [byte]
        for _ in 0..<3 {
            XCTAssertEqual(network.read(into: &byte, count: 1), 1)
            received.append(byte)
        }
        XCTAssertEqual(received, [0, 1, 2, 3])
        XCTAssertTrue(budget.beginNetworkRetry())
        XCTAssertFalse(budget.beginNetworkRetry())
    }

    func testProactiveRetryRejectsChangedContentWithoutAppendingIt() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedRangeProtocol.self]
        let network = try VividNetwork(VividSource(url: URL(string: "https://example.invalid/changed")!, recoveryBudget: VividTransientRecoveryBudget()), configuration: configuration)
        defer { network.cancel() }
        var byte: UInt8 = 0
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        network.observeDelivery(headroom: 20, active: true)
        InterruptedRangeProtocol.failActive()
        XCTAssertTrue(InterruptedRangeProtocol.waitForResume())
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 1)
        XCTAssertLessThan(network.read(into: &byte, count: 1), 0)
        XCTAssertEqual(network.lastFailure, .invalidRange)
    }

    func testOpenStallRecoversBeforeBufferEmptiesButNotDuringBackpressure() {
        var policy = VividDeliveryStall()
        XCTAssertFalse(policy.observe(headroom: 20, uptime: 10, lastDelivery: 10, eligible: true))
        XCTAssertFalse(policy.observe(headroom: 18, uptime: 12, lastDelivery: 10, eligible: true))
        XCTAssertTrue(policy.observe(headroom: 17, uptime: 13, lastDelivery: 10, eligible: true))
        for active in [false, true] {
            policy = VividDeliveryStall()
            XCTAssertFalse(policy.observe(headroom: 20, uptime: 10, lastDelivery: 10, eligible: active))
            // A full buffer or an ineligible paused/backpressured reader is not a delivery stall.
            XCTAssertFalse(policy.observe(headroom: 20, uptime: 20, lastDelivery: 10, eligible: active))
        }
        policy = VividDeliveryStall()
        XCTAssertFalse(policy.observe(headroom: 20, uptime: 10, lastDelivery: 10, eligible: true))
        XCTAssertFalse(policy.observe(headroom: 17, uptime: 13, lastDelivery: 12.9, eligible: true))
        XCTAssertFalse(policy.observe(headroom: 16, uptime: 14, lastDelivery: 12.9, eligible: false))
        XCTAssertFalse(policy.observe(headroom: 15, uptime: 20, lastDelivery: 12.9, eligible: true))
    }

    func testInterruptedReadResumesAtUnreadByteWithoutDuplicatingData() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptedRangeProtocol.self]
        let budget = VividTransientRecoveryBudget()
        let source = VividSource(url: URL(string: "https://example.invalid/media")!, recoveryBudget: budget)
        let network = try VividNetwork(source, configuration: configuration)
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 4)
        var result: [UInt8] = []
        for _ in 0..<2 {
            let count = bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 4) }
            XCTAssertEqual(count, 2)
            if count > 0 { result.append(contentsOf: bytes.prefix(Int(count))) }
            if result.count == 2 { InterruptedRangeProtocol.failActive() }
        }
        XCTAssertEqual(result, [0, 1, 2, 3])
        // One retry was spent inside the network, not a fresh budget above it.
        XCTAssertTrue(budget.beginNetworkRetry())
        XCTAssertFalse(budget.beginNetworkRetry())
        XCTAssertTrue(budget.beginReload())
        network.cancel()
        XCTAssertLessThan(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 4) }, 0)
    }

    func testBudgetSurvivesSourceReconstruction() {
        let budget = VividTransientRecoveryBudget()
        let source = VividSource(url: URL(string: "https://example.invalid/media")!, recoveryBudget: budget)
        XCTAssertTrue(source.recoveryBudget!.beginNetworkRetry())
        XCTAssertTrue(source.recoveryBudget!.beginNetworkRetry())
        XCTAssertFalse(source.recoveryBudget!.beginNetworkRetry())
        XCTAssertTrue(budget.beginReload())
        let replacement = VividSource(url: source.url, recoveryBudget: budget)
        XCTAssertFalse(replacement.recoveryBudget!.beginNetworkRetry())
        XCTAssertFalse(replacement.recoveryBudget!.beginReload())
    }

    func testReloadDoesNotReplenishUnusedNetworkBudget() {
        let budget = VividTransientRecoveryBudget()
        XCTAssertTrue(budget.beginNetworkRetry())
        XCTAssertTrue(budget.beginReload())
        XCTAssertTrue(budget.beginNetworkRetry())
        XCTAssertFalse(budget.beginNetworkRetry())
        XCTAssertFalse(budget.beginReload())
    }

    func testCancellationInvalidatesOldSourcesButNewEpisodeHasItsOwnBudget() {
        let old = VividTransientRecoveryBudget()
        old.cancel()
        XCTAssertFalse(old.beginNetworkRetry())
        XCTAssertFalse(old.beginReload())
        let next = VividTransientRecoveryBudget()
        XCTAssertTrue(next.beginNetworkRetry())
        XCTAssertTrue(next.beginReload())
        XCTAssertFalse(old.beginReload())
    }

    func testOnlyRecognisedTransientCodesAreEligible() {
        for code in [500, 502, 503, 504, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet] {
            XCTAssertTrue(VividTransientRecoveryBudget.recognises(code))
        }
        for code in [401, 403, 404, 429, 206, -1, -5, NSURLErrorCancelled,
                     NSURLErrorServerCertificateUntrusted, NSURLErrorUserAuthenticationRequired] {
            XCTAssertFalse(VividTransientRecoveryBudget.recognises(code))
        }
    }
}

private final class InterruptedRangeProtocol: URLProtocol {
    private static let lock = NSCondition()
    private static var active: InterruptedRangeProtocol?
    private static var resumed = false
    static func waitForResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !resumed { if !lock.wait(until: deadline) { return false } }
        return true
    }
    static func failActive() {
        lock.lock(); let active = active; Self.active = nil; lock.unlock()
        guard let active else { return }
        active.client?.urlProtocol(active, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resumed = request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=2-") == true
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": resumed ? "bytes 2-3/4" : "bytes 0-3/4",
                "Content-Type": "application/octet-stream", "Content-Length": resumed ? "2" : "4",
                "ETag": resumed && request.url!.lastPathComponent == "changed" ? "\"fixture-v2\"" : "\"fixture-v1\""])!
        Self.lock.lock()
        if !resumed { Self.active = self; Self.resumed = false }
        else { Self.resumed = true; Self.lock.broadcast() }
        Self.lock.unlock()
        if resumed && request.url!.lastPathComponent == "outage" {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resumed ? [2, 3] : [0, 1]))
        if resumed {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
