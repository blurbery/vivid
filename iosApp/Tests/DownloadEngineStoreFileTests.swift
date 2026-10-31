import XCTest
@testable import Vivid

/// One unreadable record in `store.json` no longer empties the scope.
final class DownloadEngineStoreFileTests: XCTestCase {
    private func record(_ id: String) -> DownloadRecord {
        DownloadRecord(
            id: id, contentId: "movie-\(id)", episodeId: nil, mediaFileId: 1, format: "original", serverStatus: "ready",
            localStatus: .completed, fileSize: 10, bytesDownloaded: 10, mediaFilename: "media.mp4",
            registeredAt: Date(timeIntervalSinceReferenceDate: 1_000)
        )
    }

    /// The scope file as a JSON object, ready to be damaged.
    private func storeObject() throws -> [String: Any] {
        var state = DownloadStoreFile.empty
        state.records = ["good": record("good"), "bad": record("bad")]
        let data = try JSONEncoder().encode(state)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnUnreadableRecordIsSkippedAndTheRestKept() throws {
        var object = try storeObject()
        var records = try XCTUnwrap(object["records"] as? [String: Any])
        var bad = try XCTUnwrap(records["bad"] as? [String: Any])
        bad["format"] = nil
        records["bad"] = bad
        object["records"] = records

        let loaded = try JSONDecoder().decode(DownloadStoreFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(Array(loaded.records.keys), ["good"])
        XCTAssertEqual(loaded.records["good"], record("good"))
    }

    func testOtherDamageStillFailsTheWholeFile() throws {
        var object = try storeObject()
        object["subscriptions"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadStoreFile.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
