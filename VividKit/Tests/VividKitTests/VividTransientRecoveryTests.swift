import Foundation
import XCTest
@testable import VividKit

final class VividTransientRecoveryTests: XCTestCase {
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resumed = request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=2-") == true
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": resumed ? "bytes 2-3/4" : "bytes 0-3/4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(resumed ? [2, 3] : [0, 1]))
        if resumed {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        }
    }
    override func stopLoading() {}
}
