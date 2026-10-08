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

    func testNoteIsSentAsWrittenWithinTheRelaysRules() {
        XCTAssertNil(DiagnosticsNote.cleaned(""))
        XCTAssertNil(DiagnosticsNote.cleaned("  \n\t "), "Blank is the same as no note")
        XCTAssertEqual(DiagnosticsNote.cleaned("  It froze after a seek.\r\nTwice.  "), "It froze after a seek.\nTwice.")
        XCTAssertEqual(DiagnosticsNote.cleaned("bell\u{07} flip\u{202E}ped"), "bell flipped")
        let long = String(repeating: "😀", count: DiagnosticsNote.maxCharacters + 20)
        XCTAssertEqual(DiagnosticsNote.cleaned(long)?.unicodeScalars.count, DiagnosticsNote.maxCharacters)
        XCTAssertEqual(DiagnosticsNote.limited(long).unicodeScalars.count, DiagnosticsNote.maxCharacters)
        XCTAssertEqual(DiagnosticsNote.limited("short"), "short")
    }

    func testANoteIsOnlyAddedWhenWritten() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let encoder = JSONEncoder()
        let plain = String(decoding: try encoder.encode(AppHealthExport(format: 1, exportedAt: date, reports: [])), as: UTF8.self)
        XCTAssertFalse(plain.contains("note"), "Without a note the file is unchanged")
        let noted = String(decoding: try encoder.encode(AppHealthExport(format: 1, exportedAt: date, reports: [], note: "Stuck after a seek")),
                           as: UTF8.self)
        XCTAssertTrue(noted.contains(#""note":"Stuck after a seek""#))
    }

    @MainActor
    func testThePlaybackRecordIsSavedWithoutTheNote() throws {
        var report = PlaybackSessionReport(
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            app: AppHealthAppInfo(version: "0.14.3", build: "65", os: "iOS 27.0", device: "iPhone18,2"),
            setup: .init(), media: .init(), totals: .init(), timeline: [], notMeasured: [])
        let saved = String(decoding: try XCTUnwrap(PlaybackSessionRecorder.encode(report)), as: UTF8.self)
        XCTAssertFalse(saved.contains("note"))
        report.note = DiagnosticsNote.cleaned("Video froze")
        let sent = String(decoding: try XCTUnwrap(PlaybackSessionRecorder.encode(report)), as: UTF8.self)
        XCTAssertTrue(sent.contains(#""note" : "Video froze""#))
    }
}
