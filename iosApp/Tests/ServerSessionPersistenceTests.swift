import XCTest
@testable import Vivid

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

final class ProfileServerNameTests: XCTestCase {
    func testSavedProfileFromBeforeServerNamesDecodesWithoutOne() throws {
        let data = Data(#"{"id":"a","serverID":"s","userID":"1","username":"Test","requiresLogin":false}"#.utf8)
        let account = try JSONDecoder().decode(TVSavedAccount.self, from: data)
        XCTAssertNil(account.serverName)
    }

    func testServerNameTravelsWithItsProfileThroughTheVault() throws {
        var account = TVSavedAccount(id: "a", serverID: "s", userID: "1", username: "Test", profile: nil, requiresLogin: false)
        account.serverName = "Lounge"
        let envelope = VividCloudAccountEnvelope(
            account: account,
            session: nil,
            server: ServerEntry(id: "s", url: "https://example.invalid", fetchedName: "Test", lastUsedAt: .distantPast),
            pinRecord: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let decoded = try JSONDecoder().decode(VividCloudAccountEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.account.serverName, "Lounge")
    }

    func testTypedServerNameIsTrimmedAndBlankClearsIt() {
        XCTAssertEqual(TVSavedAccount.serverName(from: "  Lounge  "), "Lounge")
        XCTAssertNil(TVSavedAccount.serverName(from: "   "))
        XCTAssertNil(TVSavedAccount.serverName(from: nil))
    }
}
