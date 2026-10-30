import XCTest
@testable import Vivid

@MainActor
final class RequestDetailFailureTests: XCTestCase {
    private let connectionChanged = "This account's connection changed. Open the title again from Search."

    func testCancelledLoadsReadAsAConnectionChange() {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let state = RequestDetailModel.loadFailureState(for: error)
            XCTAssertNil(state.statusCode)
            XCTAssertEqual(state.message, connectionChanged)
        }
    }

    func testOtherLoadFailuresKeepTheirMessage() {
        let state = RequestDetailModel.loadFailureState(for: TVSeerrError(message: "Seerr returned an invalid response."))
        XCTAssertNil(state.statusCode)
        XCTAssertEqual(state.message, "Seerr returned an invalid response.")
    }

    func testCancelledSubmitsReadAsAConnectionChange() {
        XCTAssertEqual(RequestDetailModel.submitFailureMessage(for: CancellationError()), connectionChanged)
        XCTAssertEqual(RequestDetailModel.submitFailureMessage(for: URLError(.cancelled)), connectionChanged)
        XCTAssertEqual(
            RequestDetailModel.submitFailureMessage(for: TVSeerrError(message: "This title has already been requested.")),
            "This title has already been requested."
        )
    }
}
