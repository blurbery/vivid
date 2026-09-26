import XCTest
import CryptoKit
@testable import Vivid

final class CachePerformanceTests: XCTestCase {
    @MainActor
    func testAsyncReadLeavesMainActorAvailableAndSeesEarlierSaves() async {
        let writer = HomeMetadataWriter()
        let release = block(writer)
        let events = Events()
        writer.write(scope: "account") { events.append("before") }
        // This can only run after read() suspends the main actor.
        Task { @MainActor in release.signal() }
        let observed = await writer.read {
            XCTAssertFalse(Thread.isMainThread)
            return events.values
        }
        XCTAssertEqual(observed, ["before"])
        writer.write(scope: "account") { events.append("after") }
        let final = await writer.read { events.values }
        XCTAssertEqual(final, ["before", "after"])
    }

    func testAsyncReadSeesDeletionAndLaterSaveInOrder() async {
        let writer = HomeMetadataWriter()
        let events = Events()
        writer.write(scope: "account") { events.append("old") }
        writer.async { events.append("delete") }
        let deleted = await writer.read { events.values }
        XCTAssertEqual(deleted, ["old", "delete"])
        writer.write(scope: "account") { events.append("new") }
        let restored = await writer.read { events.values }
        XCTAssertEqual(restored, ["old", "delete", "new"])
    }

    func testCacheKeysKeepExistingDiskFormat() throws {
        let identities = [
            ["server", "account", "profile"],
            ["https://server.example/path", "quotes\"and\\slashes", "café 🎬"],
            ["", "", ""],
            ["a|b", "c", "d"],
            ["a", "b|c", "d"],
        ]
        for identity in identities {
            let expected = try legacyKey(identity)
            for _ in 0..<3 {
                XCTAssertEqual(key(identity), expected)
            }
        }
    }

    func testCacheKeysTrackIdentityChangesAndReturningAccount() throws {
        let original = ["server", "account", "profile"]
        let originalKey = try legacyKey(original)
        for component in 0..<3 {
            var changed = original
            changed[component] = "replacement"
            XCTAssertEqual(key(original), originalKey)
            XCTAssertEqual(key(changed), try legacyKey(changed))
            XCTAssertNotEqual(key(changed), originalKey)
            XCTAssertEqual(key(original), originalKey)
        }
    }

    func testCacheKeysPreserveDistinctUnicodeEncodings() throws {
        // Swift String equality treats these as equal, but their existing
        // JSON bytes and therefore their on-disk namespaces are different.
        for component in 0..<3 {
            var composed = ["server", "account", "profile"]
            composed[component] = "caf\u{00E9}"
            var decomposed = composed
            decomposed[component] = "cafe\u{0301}"
            XCTAssertNotEqual(try legacyKey(composed), try legacyKey(decomposed))
            XCTAssertEqual(key(composed), try legacyKey(composed))
            XCTAssertEqual(key(decomposed), try legacyKey(decomposed))
        }
    }

    func testConcurrentCacheKeysRemainIsolated() throws {
        let identities = (0..<8).map { ["server-\($0 % 2)", "account-\($0)", "profile-\($0 % 3)"] }
        let expected = try identities.map(legacyKey)
        let failures = Events()
        DispatchQueue.concurrentPerform(iterations: 400) { iteration in
            let index = iteration % identities.count
            if key(identities[index]) != expected[index] { failures.append("wrong identity") }
        }
        XCTAssertTrue(failures.values.isEmpty)
    }

    func testQueuedSavesKeepOnlyLatestValueForEachAccount() {
        let writer = HomeMetadataWriter()
        let release = block(writer)
        let events = Events()
        for value in 1...100 {
            writer.write(scope: "first") { events.append("first:\(value)") }
            writer.write(scope: "second") { events.append("second:\(value)") }
        }
        release.signal()
        // Synchronous hydration must see the last submitted snapshot.
        XCTAssertEqual(writer.sync { events.values }, ["first:100", "second:100"])
    }

    func testRunningSaveFinishesBeforeLatestPendingSave() {
        let writer = HomeMetadataWriter()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let events = Events()
        writer.write(scope: "account") {
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            events.append("running")
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        for value in 1...100 {
            writer.write(scope: "account") { events.append("pending:\(value)") }
        }
        release.signal()
        XCTAssertEqual(writer.sync { events.values }, ["running", "pending:100"])
    }

    func testDeletionSeparatesEarlierAndLaterWrites() {
        let writer = HomeMetadataWriter()
        let release = block(writer)
        let events = Events()
        writer.write(scope: "account") { events.append("old") }
        writer.async { events.append("delete") }
        writer.write(scope: "account") { events.append("new") }
        release.signal()
        XCTAssertEqual(writer.sync { events.values }, ["old", "delete", "new"])
    }

    func testClearPersistsEmptySnapshotInsteadOfQueuedRows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let writer = HomeMetadataWriter()
        let release = block(writer)
        let events = Events()
        writer.write(scope: "account") {
            self.save(["stale row"], to: url)
            events.append("stale")
        }
        writer.write(scope: "account") {
            self.save([], to: url)
            events.append("cleared")
        }
        release.signal()
        writer.sync {}
        let rows = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(events.values, ["cleared"])
    }

    func testAccountDeletionDoesNotRecreateSnapshotFromQueuedSaves() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let writer = HomeMetadataWriter()
        let release = block(writer)
        for value in 1...10 {
            writer.write(scope: "account") { self.save(["row \(value)"], to: url) }
        }
        writer.async {
            do { try FileManager.default.removeItem(at: url) }
            catch { XCTFail("Snapshot deletion failed") }
        }
        release.signal()
        XCTAssertFalse(writer.sync { FileManager.default.fileExists(atPath: url.path) })
    }

    func testFailedSaveDoesNotPreventLaterSave() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let writer = HomeMetadataWriter()
        let events = Events()
        writer.write(scope: "account") {
            do {
                // A directory cannot be replaced by an atomic data write.
                try Data([1]).write(to: directory, options: .atomic)
                XCTFail("Expected a write failure")
            } catch { events.append("failed") }
        }
        writer.sync {}
        writer.write(scope: "account") { self.save(["latest"], to: url) }
        writer.sync {}
        XCTAssertEqual(events.values, ["failed"])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: url)), ["latest"])
    }

    private func key(_ identity: [String]) -> String {
        VividCacheScope.key(serverID: identity[0], accountID: identity[1], profileID: identity[2])
    }

    private func legacyKey(_ identity: [String]) throws -> String {
        SHA256.hash(data: try JSONEncoder().encode(identity)).map { String(format: "%02x", $0) }.joined()
    }

    private func block(_ writer: HomeMetadataWriter) -> DispatchSemaphore {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        writer.async {
            started.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        return release
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ rows: [String], to url: URL) {
        do { try JSONEncoder().encode(rows).write(to: url, options: .atomic) }
        catch { XCTFail("Snapshot write failed") }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ value: String) {
            lock.lock()
            stored.append(value)
            lock.unlock()
        }
        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
