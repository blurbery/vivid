import XCTest
@testable import Vivid

final class RequestReasonTextTests: XCTestCase {
    func testKnownTokensUseTheirCopy() {
        XCTAssertEqual(RequestReasonText.text(for: "already_requested"), "Already requested")
        XCTAssertEqual(RequestReasonText.text(for: "already_available"), "Already in your library")
        XCTAssertEqual(RequestReasonText.text(for: "quota_exceeded"), "Request limit reached")
        XCTAssertEqual(RequestReasonText.text(for: "requests_disabled"), "Requests are turned off")
        XCTAssertEqual(RequestReasonText.text(for: "requesting_blocked"), "You can't request media right now")
        XCTAssertEqual(RequestReasonText.text(for: "validation_failed"), "That request couldn't be submitted")
    }

    func testUnknownTokensAreHumanised() {
        XCTAssertEqual(RequestReasonText.text(for: "waiting_for_release"), "Waiting For Release")
        XCTAssertEqual(RequestReasonText.text(for: "some-dash-reason"), "Some Dash Reason")
    }

    func testMissingTokensGiveNoCopy() {
        XCTAssertNil(RequestReasonText.text(for: nil))
        XCTAssertNil(RequestReasonText.text(for: ""))
    }
}
