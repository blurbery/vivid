import Foundation
import XCTest
@testable import VividKit

final class VividTransientRecoveryTests: XCTestCase {
    private func credentialNetwork(_ mode: CredentialRangeProtocol.Mode = .normal,
        timeout: TimeInterval = 6, refresh: (@Sendable () async -> [String: String]?)? = nil) throws -> VividNetwork {
        CredentialRangeProtocol.reset(mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialRangeProtocol.self]
        return try VividNetwork(VividSource(url: URL(string: "https://example.invalid/credentials")!,
            headers: ["Authorization": "Bearer old"], recoveryBudget: VividTransientRecoveryBudget(),
            refreshHeaders: refresh), configuration: configuration, authenticationTimeout: timeout)
    }

    func testCredentialRotationKeepsUnreadBytesAndAppliesToNextRequest() throws {
        let network = try credentialNetwork()
        defer { network.cancel() }
        var byte: UInt8 = 0
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertTrue(network.updateHeaders(["Authorization": "Bearer new"]))
        XCTAssertEqual(CredentialRangeProtocol.requests.count, 1)
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 1)
        XCTAssertEqual(network.read(into: &byte, count: 1), 1)
        XCTAssertEqual(byte, 2)
        XCTAssertEqual(CredentialRangeProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer old", "Bearer new"])
    }

    func testHTTP401RefreshResumesValidatedRangeWithoutReconstructingReader() throws {
        let network = try credentialNetwork(refresh: { ["Authorization": "Bearer new"] })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertEqual(bytes, [0, 1])
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertEqual(bytes, [2, 3])
        let requests = CredentialRangeProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=2-3")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Range"), "\"fixture-v1\"")
        XCTAssertNil(network.lastFailure)
    }

    func testLate401UsesAlreadyRotatedCredentialWithoutRefreshingAgain() throws {
        let network = try credentialNetwork(.hold401, refresh: {
            XCTFail("An already rotated credential must be tried before another refresh")
            return nil
        })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        let done = expectation(description: "Read resumes")
        DispatchQueue.global().async {
            var bytes = [UInt8](repeating: 0, count: 2)
            XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
            XCTAssertEqual(bytes, [2, 3])
            done.fulfill()
        }
        XCTAssertTrue(CredentialRangeProtocol.waitForRequests(2))
        XCTAssertTrue(network.updateHeaders(["Authorization": "Bearer new"]))
        CredentialRangeProtocol.release401()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(CredentialRangeProtocol.requests.count, 3)
    }

    func testRejectedReplacementCredentialDoesNotLoop() throws {
        let network = try credentialNetwork(.reject, refresh: { ["Authorization": "Bearer new"] })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertLessThan(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 0)
        XCTAssertEqual(network.lastFailure, .network(401))
        XCTAssertEqual(CredentialRangeProtocol.requests.count, 3)
    }

    func testAuthenticationRefreshTimeoutIgnoresLateCompletion() throws {
        let network = try credentialNetwork(timeout: 0.05, refresh: {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return ["Authorization": "Bearer new"]
        })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertLessThan(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(network.lastFailure, .network(401))
        XCTAssertEqual(CredentialRangeProtocol.requests.count, 2)
    }

    func testCancellingAuthenticationRefreshRejectsItsCompletion() throws {
        let refreshStarted = expectation(description: "Refresh starts")
        let network = try credentialNetwork(refresh: {
            refreshStarted.fulfill()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return ["Authorization": "Bearer new"]
        })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        let done = expectation(description: "Cancelled read exits")
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            XCTAssertLessThan(network.read(into: &byte, count: 1), 0)
            done.fulfill()
        }
        wait(for: [refreshStarted], timeout: 3)
        network.cancel()
        wait(for: [done], timeout: 3)
        XCTAssertFalse(network.updateHeaders(["Authorization": "Bearer late"]))
        XCTAssertEqual(CredentialRangeProtocol.requests.count, 2)
    }

    func testAuthenticatedResumeRejectsChangedContent() throws {
        let network = try credentialNetwork(.changed, refresh: { ["Authorization": "Bearer new"] })
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertLessThan(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 0)
        XCTAssertEqual(network.lastFailure, .invalidRange)
    }

    func testCompletedRangeWithLateErrorAdvancesToNextValidRange() throws {
        let network = try credentialNetwork(.lateError)
        defer { network.cancel() }
        var bytes = [UInt8](repeating: 0, count: 2)
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        CredentialRangeProtocol.failCompletedRange()
        XCTAssertEqual(bytes.withUnsafeMutableBufferPointer { network.read(into: $0.baseAddress!, count: 2) }, 2)
        XCTAssertEqual(bytes, [2, 3])
        XCTAssertEqual(CredentialRangeProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=2-3")
        XCTAssertNil(network.lastFailure)
    }

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

private final class CredentialRangeProtocol: URLProtocol {
    enum Mode { case normal, hold401, reject, changed, lateError }
    private static let lock = NSCondition()
    private static var mode = Mode.normal
    private static var recorded: [URLRequest] = []
    private static var held: CredentialRangeProtocol?
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
    static func reset(_ mode: Mode) {
        lock.lock(); defer { lock.unlock() }
        Self.mode = mode; recorded = []; held = nil
    }
    static func waitForRequests(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while recorded.count < count { if !lock.wait(until: deadline) { return false } }
        return true
    }
    static func release401() {
        lock.lock(); let pending = held; held = nil; lock.unlock()
        pending?.refuse()
    }
    static func failCompletedRange() {
        lock.lock(); let pending = held; held = nil; lock.unlock()
        guard let pending else { return }
        pending.client?.urlProtocol(pending, didFailWithError: NSError(domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private func refuse() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func startLoading() {
        let first = request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=0-") == true
        Self.lock.lock()
        let mode = Self.mode
        let hold = mode == .hold401 && !first && Self.recorded.count == 1
        if hold || (first && mode == .lateError) { Self.held = self }
        Self.recorded.append(request); Self.lock.broadcast(); Self.lock.unlock()
        if hold { return }
        if !first && mode != .lateError &&
            (mode == .reject || request.value(forHTTPHeaderField: "Authorization") != "Bearer new") {
            refuse(); return
        }
        let valid = first || request.value(forHTTPHeaderField: "Range") == "bytes=2-3"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 206 : 416, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": first ? "bytes 0-1/4" : "bytes 2-3/4",
                "Content-Type": "application/octet-stream", "Content-Length": "2",
                "ETag": !first && mode == .changed ? "\"fixture-v2\"" : "\"fixture-v1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if valid { client?.urlProtocol(self, didLoad: Data(first ? [0, 1] : [2, 3])) }
        if !(first && mode == .lateError) { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
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
