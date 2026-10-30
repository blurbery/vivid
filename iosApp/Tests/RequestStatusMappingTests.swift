import SwiftUI
import XCTest
@testable import Vivid

final class RequestStatusMappingTests: XCTestCase {
    private func state(_ status: RequestStatus?, requestable: Bool, reason: String? = nil) -> RequestState {
        RequestState(status: status, requestable: requestable, reason: reason, requestId: nil)
    }

    func testActiveRecordsFollowTheirStatus() {
        XCTAssertEqual(RequestBadge.forRecord(status: .pending, outcome: .active, reason: nil), .pending)
        for status in [RequestStatus.approved, .queued, .downloading] {
            XCTAssertEqual(RequestBadge.forRecord(status: status, outcome: .active, reason: nil), .onTheWay, "\(status)")
        }
        XCTAssertEqual(RequestBadge.forRecord(status: .completed, outcome: .active, reason: nil), .inLibrary)
    }

    func testTerminalOutcomesWinOverStatus() {
        XCTAssertEqual(
            RequestBadge.forRecord(status: .downloading, outcome: .declined, reason: "no space"),
            .needsAttention(reason: "no space")
        )
        XCTAssertEqual(
            RequestBadge.forRecord(status: .completed, outcome: .failed, reason: nil),
            .needsAttention(reason: nil)
        )
        XCTAssertEqual(
            RequestBadge.forRecord(status: .pending, outcome: .cancelled, reason: nil),
            .unavailable(reason: nil)
        )
    }

    func testFailedStatusNeedsAttentionWithItsReason() {
        XCTAssertEqual(
            RequestBadge.forRecord(status: .failed, outcome: .active, reason: "grab failed"),
            .needsAttention(reason: "grab failed")
        )
    }

    func testUnknownWireValuesStayInProgress() {
        XCTAssertEqual(RequestBadge.forRecord(status: .unknown, outcome: .active, reason: nil), .onTheWay)
        XCTAssertEqual(RequestBadge.forRecord(status: .pending, outcome: .unknown, reason: nil), .pending)
    }

    func testAvailableTitlesAreInLibraryWhateverTheRequestSays() {
        XCTAssertEqual(
            RequestBadge.forCard(availability: .available, request: state(.pending, requestable: false)),
            .inLibrary
        )
    }

    func testMissingTitlesWithARequestShowItsStatus() {
        XCTAssertEqual(
            RequestBadge.forCard(availability: .missing, request: state(.pending, requestable: false)),
            .pending
        )
        XCTAssertEqual(
            RequestBadge.forCard(availability: .missing, request: state(.downloading, requestable: false)),
            .onTheWay
        )
    }

    func testRequestableTitlesHaveNoBadge() {
        XCTAssertNil(RequestBadge.forCard(availability: .missing, request: state(nil, requestable: true)))
    }

    func testUnrequestableTitlesAreUnavailableWithTheirReason() {
        XCTAssertEqual(
            RequestBadge.forCard(
                availability: .missing,
                request: state(nil, requestable: false, reason: "quota_exceeded")
            ),
            .unavailable(reason: "quota_exceeded")
        )
    }

    func testTints() {
        XCTAssertEqual(RequestBadge.pending.tint, Color.requestAmber)
        XCTAssertEqual(RequestBadge.onTheWay.tint, Color.requestSky)
        XCTAssertEqual(RequestBadge.inLibrary.tint, Color.requestEmerald)
        XCTAssertEqual(RequestBadge.needsAttention(reason: nil).tint, Color.requestRose)
        XCTAssertEqual(RequestBadge.unavailable(reason: nil).tint, Color.vividSecondaryText)
    }
}
