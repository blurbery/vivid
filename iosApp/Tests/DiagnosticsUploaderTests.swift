import XCTest
@testable import Vivid

/// A report only counts as sent when the diagnostics service confirms it
/// with a reference, so these decide what is marked sent.
final class DiagnosticsUploaderTests: XCTestCase {
    private func outcome(_ status: Int, _ body: String = "", retryAfter: String? = nil) -> Result<String, DiagnosticsUploader.Failure> {
        DiagnosticsUploader.outcome(status: status, body: Data(body.utf8), retryAfter: retryAfter)
    }

    func testOnlyAConfirmedReferenceCountsAsSent() {
        XCTAssertEqual(outcome(200, #"{"reference":"VR-7K2M9Q"}"#), .success("VR-7K2M9Q"))
        XCTAssertEqual(outcome(200, ""), .failure(.unavailable))
        XCTAssertEqual(outcome(200, #"{"reference":"anything"}"#), .failure(.unavailable))
        XCTAssertEqual(outcome(202, #"{"reference":"VR-7K2M9Q"}"#), .failure(.unavailable))
    }

    func testRateLimitUsesRetryAfter() {
        XCTAssertEqual(outcome(429, retryAfter: "120"), .failure(.rateLimited(retryAfter: 120)))
        XCTAssertEqual(outcome(429), .failure(.rateLimited(retryAfter: 60)))
        XCTAssertEqual(DiagnosticsUploader.Failure.rateLimited(retryAfter: 61).message,
                       "Too many reports were sent just now. Try again in 2 min.")
    }

    func testRejectedReportsCanNotBeRetriedButOutagesCan() {
        for status in [400, 404, 405, 413, 415] {
            XCTAssertEqual(outcome(status), .failure(.rejected))
        }
        XCTAssertFalse(DiagnosticsUploader.Failure.rejected.canRetry)
        for status in [500, 502, 503] {
            XCTAssertEqual(outcome(status), .failure(.unavailable))
        }
        XCTAssertTrue(DiagnosticsUploader.Failure.unavailable.canRetry)
        XCTAssertTrue(DiagnosticsUploader.Failure.offline.canRetry)
    }

    func testSendsToTheDiagnosticsService() {
        XCTAssertEqual(DiagnosticsUploader.baseURL.appendingPathComponent("playback").absoluteString,
                       "https://diagnostics.vividapp.co/v1/reports/playback")
    }
}
