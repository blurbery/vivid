import XCTest
@testable import Vivid

/// Apple TV reopens a title after a YouTube trailer only for the same server
/// and profile, and only within half an hour.
final class TrailerReturnRuleTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let ageLimit: TimeInterval = 1_800

    private func record(savedAt: Date) -> TrailerReturnRecord {
        TrailerReturnRecord(contentId: "movie-42", serverId: "server-1", profileId: "profile-1", savedAt: savedAt)
    }

    private func restores(_ record: TrailerReturnRecord, server: String? = "server-1", profile: String? = "profile-1") -> Bool {
        TrailerReturnPolicy.shouldRestore(record: record, now: now, activeServerId: server, activeProfileId: profile)
    }

    func testRecentRecordForTheSameIdentityRestores() {
        XCTAssertTrue(restores(record(savedAt: now.addingTimeInterval(-120))))
    }

    func testRecordExactlyAtTheAgeLimitRestores() {
        XCTAssertTrue(restores(record(savedAt: now.addingTimeInterval(-ageLimit))))
    }

    func testRecordOneSecondPastTheAgeLimitDoesNotRestore() {
        XCTAssertFalse(restores(record(savedAt: now.addingTimeInterval(-ageLimit - 1))))
    }

    func testRecordSavedInTheFutureDoesNotRestore() {
        XCTAssertFalse(restores(record(savedAt: now.addingTimeInterval(60))))
    }

    func testAnotherServerDoesNotRestore() {
        XCTAssertFalse(restores(record(savedAt: now), server: "server-2"))
    }

    func testAnotherProfileDoesNotRestore() {
        XCTAssertFalse(restores(record(savedAt: now), profile: "profile-2"))
    }

    func testNoActiveIdentityDoesNotRestore() {
        XCTAssertFalse(restores(record(savedAt: now), server: nil, profile: nil))
    }
}
