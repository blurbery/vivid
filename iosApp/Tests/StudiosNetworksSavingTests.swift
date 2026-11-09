import XCTest
@testable import Vivid

/// Saving Studios & Networks results a piece at a time, and the guard that
/// stops a load the app keeps closing during.
final class StudiosNetworksSavingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func item(_ id: String) throws -> BrowseItem {
        let json = #"{"contentId":"\#(id)","type":"movie","title":"Film \"\#(id)\" / ä","year":2020,"overview":"Line\nbreak"}"#
        return try JSONDecoder().decode(BrowseItem.self, from: Data(json.utf8))
    }

    // MARK: Piecewise writing

    func testResultsWrittenInPiecesReadBackAsTheyWere() throws {
        var results: [String: StudioNetworkResult] = [:]
        for brand in ["netflix", "hbo", "pixar"] {
            var result = StudioNetworkResult()
            result.movies = try (0..<450).map { try item("\(brand)\($0)") }
            result.leftOutOfRows = ["\(brand)1"]
            result.matchCount = 450
            results[brand] = result
        }
        results["empty"] = StudioNetworkResult()
        let file = StudioNetworkResultsFile(savedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.25),
                                            results: results, revision: 6, missesTrending: nil)
        let url = folder.appendingPathComponent("results.json")
        try JSONPieceWriter.write(to: url) { try file.writeFields(to: &$0) }

        let read = try JSONDecoder().decode(StudioNetworkResultsFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(read.savedAt, file.savedAt)
        XCTAssertEqual(read.results, file.results)
        XCTAssertEqual(read.revision, 6)
        XCTAssertNil(read.missesTrending, "A nil field is left out, as synthesised Codable does")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["results.json"],
                       "Nothing is left beside it")
    }

    func testAFailedWriteKeepsTheOldFile() throws {
        struct Broken: Error {}
        let url = folder.appendingPathComponent("results.json")
        try Data("old".utf8).write(to: url)
        XCTAssertThrowsError(try JSONPieceWriter.write(to: url) { _ in throw Broken() })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["results.json"])
    }

    func testOnlyAbandonedPartialFilesAreRemoved() throws {
        let old = folder.appendingPathComponent(".results.json.A.partial")
        let recent = folder.appendingPathComponent(".results.json.B.partial")
        let saved = folder.appendingPathComponent("results.json")
        for url in [old, recent, saved] { try Data().write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        StudiosNetworksStore.removeAbandonedPartials(in: folder)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
                       [".results.json.B.partial", "results.json"])
    }

    // MARK: Interrupted loads

    private typealias Record = StudiosNetworksStore.LoadRecord
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func start(_ saved: Record?, exitPID: Int32? = nil, retrying: Bool = false, app: String = "1.1 (2)",
                       at time: Date? = nil) -> (starts: Bool, record: Record) {
        StudiosNetworksStore.guardedStart(
            saved, app: app, process: "300",
            previousExit: exitPID.map { AppHealthMonitor.PreviousExit(pid: $0, playerOpen: false) },
            retrying: retrying, now: time ?? now
        )
    }

    func testALoadCutShortByTheAppClosingCountsOnlyForThatProcess() {
        let running = Record(app: "1.1 (2)", running: "200")
        let killed = start(running, exitPID: 200)
        XCTAssertTrue(killed.starts)
        XCTAssertEqual(killed.record.interrupted, 1)
        XCTAssertEqual(killed.record.running, "300")

        let otherProcess = start(running, exitPID: 250)
        XCTAssertEqual(otherProcess.record.interrupted, 0, "Another process's crash isn't this load's")
        let background = start(running)
        XCTAssertEqual(background.record.interrupted, 0, "A close in the background is routine")
    }

    func testTwoInARowStopLoadsUntilTryAgainAnUpdateOrADayLater() {
        let first = start(Record(app: "1.1 (2)", running: "100"), exitPID: 100)
        var second = first.record
        second.running = "200"
        let halted = start(second, exitPID: 200)
        XCTAssertFalse(halted.starts)
        XCTAssertEqual(halted.record.interrupted, 2)
        XCTAssertNil(halted.record.running)

        XCTAssertFalse(start(halted.record, at: now.addingTimeInterval(3_600)).starts, "Still stopped an hour on")
        XCTAssertTrue(start(halted.record, retrying: true).starts, "Try Again")
        XCTAssertTrue(start(halted.record, app: "1.1 (3)").starts, "A new app version")

        let dayLater = start(halted.record, at: now.addingTimeInterval(25 * 3_600))
        XCTAssertTrue(dayLater.starts, "A day on, it tries once more")
        var cutAgain = dayLater.record
        cutAgain.running = "400"
        XCTAssertFalse(start(cutAgain, exitPID: 400, at: now.addingTimeInterval(26 * 3_600)).starts,
                       "and stops again if that one is cut short too")
    }
}
