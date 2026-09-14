import XCTest
@testable import Vivid

@MainActor
final class ServerSessionPersistenceTests: XCTestCase {
    func testRegistryMutationsRollBackWhenPersistenceFails() async throws {
        let suiteName = "ServerSessionPersistenceTests.suite.\(UUID().uuidString)"
        let standardName = "ServerSessionPersistenceTests.standard.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            suite.removePersistentDomain(forName: suiteName)
            standard.removePersistentDomain(forName: standardName)
        }
        var allowsPersistence = true
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(
                service: "ServerSessionPersistenceTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in allowsPersistence }
        )
        let first = ServerEntry(
            id: "first",
            url: "https://first.example",
            fetchedName: "First",
            lastUsedAt: Date()
        )
        let second = ServerEntry(
            id: "second",
            url: "https://second.example",
            fetchedName: "Second",
            lastUsedAt: Date()
        )
        XCTAssertNotNil(registry.addOrUpdate(first))

        allowsPersistence = false
        XCTAssertNil(registry.addOrUpdate(second))
        XCTAssertNil(registry.entry(with: second.id))
        let switched = await registry.switchTo(serverId: first.id)
        XCTAssertFalse(switched)
        XCTAssertNil(registry.activeServerId)
        let removed = await registry.remove(serverId: first.id)
        XCTAssertFalse(removed)
        XCTAssertEqual(registry.entry(with: first.id), first)
    }

    func testNewSessionUpsertClearsExistingProfileAndRefreshesServerName() {
        let suiteName = "ServerSessionPersistenceTests.suite.\(UUID().uuidString)"
        let standardName = "ServerSessionPersistenceTests.standard.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let standard = UserDefaults(suiteName: standardName)!
        defer {
            suite.removePersistentDomain(forName: suiteName)
            standard.removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let launchPreferences = ProfileLaunchPreferences(defaults: defaults)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: "ServerSessionPersistenceTests.\(UUID().uuidString)", accessGroup: nil),
            launchPreferences: launchPreferences
        )
        let serverID = ServerRegistry.serverId(for: "https://home.example")
        registry.addOrUpdate(ServerEntry(
            id: serverID,
            url: "https://home.example",
            fetchedName: "Home",
            lastUsedAt: Date()
        ))
        launchPreferences.remember(
            profileID: "OLD-PROFILE",
            requiresPIN: false,
            accountEpoch: "old-account",
            for: serverID
        )

        registry.addOrUpdate(ServerEntry(
            id: serverID,
            url: "https://home.example",
            fetchedName: "Home Renamed",
            profileId: nil,
            lastUsedAt: Date()
        ), preservingProfile: false)

        XCTAssertNil(launchPreferences.rememberedProfile(for: serverID))
        XCTAssertEqual(registry.entry(with: serverID)?.fetchedName, "Home Renamed")
        XCTAssertEqual(registry.entry(with: serverID)?.displayName, "Home Renamed")
    }
}

final class CloudServerDeletionTests: XCTestCase {
    private func envelope(server: String, user: String, authenticatedAt: Date? = nil) -> VividCloudAccountEnvelope {
        VividCloudAccountEnvelope(
            account: TVSavedAccount(id: user, serverID: server, userID: user, username: "Test", profile: nil, requiresLogin: false),
            session: nil,
            server: ServerEntry(id: server, url: "https://example.invalid", fetchedName: "Test", lastUsedAt: .distantPast),
            pinRecord: nil, updatedAt: Date(timeIntervalSince1970: 999), authenticatedAt: authenticatedAt
        )
    }

    func testServerDeletionCoversCloudAndOfflineProfilesWithoutAffectingOtherServers() {
        var vault = VividCloudAccountVault()
        vault.accounts = ["cloud": envelope(server: "emby", user: "cloud"), "other": envelope(server: "silo", user: "other")]
        vault.serverTombstones = ["emby": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 20))]
        vault.applyServerDeletions(local: ["offline": envelope(server: "emby", user: "offline")], authentications: [:])
        XCTAssertEqual(Set(vault.tombstones.keys), ["cloud", "offline"])
    }

    func testExplicitReauthenticationSurvivesPersistedServerDeletion() throws {
        var vault = VividCloudAccountVault()
        vault.accounts = ["new": envelope(server: "emby", user: "new", authenticatedAt: Date(timeIntervalSince1970: 30))]
        vault.serverTombstones = ["emby": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 20))]
        vault = try JSONDecoder().decode(VividCloudAccountVault.self, from: JSONEncoder().encode(vault))
        vault.applyServerDeletions(local: [:], authentications: [:])
        XCTAssertTrue(vault.tombstones.isEmpty)
        vault.serverTombstones?["emby"] = VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 40))
        vault.applyServerDeletions(local: [:], authentications: [:])
        XCTAssertEqual(vault.tombstones["new"]?.deletedAt, Date(timeIntervalSince1970: 40))
    }

    func testOnlyAuthenticationAfterDeletionAllowsAnOfflineAccountBack() {
        for offset in [19.0, 20.0, 21.0] {
            var vault = VividCloudAccountVault()
            vault.serverTombstones = ["emby": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 20))]
            vault.applyServerDeletions(local: ["offline": envelope(server: "emby", user: "offline")],
                authentications: ["offline": Date(timeIntervalSince1970: offset)])
            XCTAssertEqual(vault.tombstones.isEmpty, offset > 20)
        }
    }

    func testServerDeletionDoesNotReplaceANewerAccountDeletion() {
        var vault = VividCloudAccountVault()
        vault.accounts = ["user": envelope(server: "emby", user: "user")]
        vault.tombstones = ["user": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 40))]
        vault.serverTombstones = ["emby": VividCloudAccountTombstone(deletedAt: Date(timeIntervalSince1970: 20))]
        vault.applyServerDeletions(local: [:], authentications: [:])
        XCTAssertEqual(vault.tombstones["user"]?.deletedAt, Date(timeIntervalSince1970: 40))
    }

    func testExistingVaultWithoutServerDeletionsStillDecodes() throws {
        let data = Data(#"{"schemaVersion":1,"accounts":{},"tombstones":{}}"#.utf8)
        let vault = try JSONDecoder().decode(VividCloudAccountVault.self, from: data)
        XCTAssertNil(vault.serverTombstones)
    }
}

final class AccountMetadataDeletionTests: XCTestCase {
    func testDeletesSelectedSnapshotAndReturnsNestedArtworkOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.json")
        let other = root.appendingPathComponent("other.json")
        let data = Data(#"{"rows":[{"posterUrl":"https://example.invalid/poster"}],"details":{"backdrop":"https://example.invalid/backdrop"},"name":"Title"}"#.utf8)
        try data.write(to: selected)
        try data.write(to: other)
        let urls = try TVHomeMetadataCache.deleteSnapshot(at: selected)
        XCTAssertEqual(urls.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try Data(contentsOf: other), data)
        XCTAssertTrue(try TVHomeMetadataCache.deleteSnapshot(at: selected).isEmpty)
    }

    func testCorruptSnapshotCanStillBeDeleted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xff]).write(to: url)
        XCTAssertTrue(try TVHomeMetadataCache.deleteSnapshot(at: url).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
