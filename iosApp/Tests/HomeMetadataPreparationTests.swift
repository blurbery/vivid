import XCTest
@testable import Vivid

@MainActor
final class HomeMetadataPreparationTests: XCTestCase {
    func testPreparedSnapshotIsAvailableBeforeSynchronousHydration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        let date = Date(timeIntervalSince1970: 123)
        try saveSnapshot(date, scope: "test", in: directory)
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { "test" })
        await cache.prepare()
        XCTAssertEqual(cache.snapshot.spotlightUpdatedAt, date)
        // Once prepared, activation has no dependency on the snapshot file.
        _ = await writer.read { try? FileManager.default.removeItem(at: directory.appendingPathComponent("test.json")) }
        cache.activate()
        XCTAssertEqual(cache.snapshot.spotlightUpdatedAt, date)
        cache.deactivate()
    }

    func testDepartedProfileCannotApplyItsPendingSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        try saveSnapshot(Date(timeIntervalSince1970: 1), scope: "first", in: directory)
        let expected = Date(timeIntervalSince1970: 2)
        try saveSnapshot(expected, scope: "second", in: directory)
        var scope = "first"
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { scope })
        let release = block(writer)
        let switchProfile = Task { @MainActor in
            scope = "second"
            cache.deactivate()
            release.signal()
        }
        // This actor cannot run switchProfile until prepare suspends.
        await cache.prepare()
        await switchProfile.value
        await cache.prepare()
        XCTAssertEqual(cache.snapshot.spotlightUpdatedAt, expected)
        cache.deactivate()
        _ = await writer.read { true }
    }

    func testClearCannotBeUndoneByAnEarlierPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        try saveSnapshot(Date(timeIntervalSince1970: 1), scope: "test", in: directory)
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { "test" })
        let release = block(writer)
        let clear = Task { @MainActor in
            release.signal()
            cache.clear(TVHomeMetadataCache.spotlightID)
        }
        await cache.prepare()
        await clear.value
        XCTAssertNil(cache.snapshot.spotlightUpdatedAt)
        let persisted = await writer.read {
            try? JSONDecoder().decode(TVHomeMetadataCache.Snapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent("test.json")))
        }
        XCTAssertNotNil(persisted)
        XCTAssertNil(persisted?.spotlightUpdatedAt)
        cache.deactivate()
    }

    func testFreshLibrariesCannotBeReplacedByAnEarlierPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        try saveSnapshot(Date(timeIntervalSince1970: 1), scope: "test", in: directory)
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { "test" })
        let release = block(writer)
        let refresh = Task { @MainActor in
            release.signal()
            cache.storeLibraries(LibrariesResponse(libraries: []))
        }
        await cache.prepare()
        await refresh.value
        XCTAssertNotNil(cache.snapshot.libraries)
        cache.deactivate()
        _ = await writer.read { true }
    }

    func testMissingAndCorruptSnapshotsAllowActivation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { "test" })
        await cache.prepare()
        XCTAssertTrue(cache.snapshot.rows.isEmpty)
        cache.deactivate()
        try Data("invalid snapshot".utf8).write(to: directory.appendingPathComponent("test.json"))
        await cache.prepare()
        XCTAssertTrue(cache.snapshot.rows.isEmpty)
        XCTAssertNil(cache.storageError)
        cache.deactivate()
    }

    func testDeletingAccountInvalidatesPendingPreparation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = HomeMetadataWriter()
        let scope = VividCacheScope.key(serverID: "test-server", accountID: "test-account", profileID: "test-profile")
        try saveSnapshot(Date(timeIntervalSince1970: 1), scope: scope, in: directory)
        let cache = TVHomeMetadataCache(writer: writer, snapshotDirectory: directory, currentScope: { scope })
        let profile = UserProfile(id: "test-profile", name: "Test", avatarEmoji: nil, hasPin: false, isChild: false)
        let account = TVSavedAccount(id: "test", serverID: "test-server", userID: "test-account",
                                     username: "test", profile: profile, requiresLogin: false)
        let release = block(writer)
        let deletion = Task { @MainActor in
            release.signal()
            try await cache.deleteAccountCache(account)
        }
        await cache.prepare()
        try await deletion.value
        _ = await writer.read { true }
        XCTAssertNil(cache.snapshot.spotlightUpdatedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(scope + ".json").path))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func saveSnapshot(_ date: Date, scope: String, in directory: URL) throws {
        var snapshot = TVHomeMetadataCache.Snapshot()
        snapshot.spotlightUpdatedAt = date
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(scope + ".json"))
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
}
