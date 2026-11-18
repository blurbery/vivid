import Security
import XCTest
@testable import Vivid

@MainActor
final class ServerRegistrySaveTests: XCTestCase {
    func testRegistryChangesRollBackWhenSavingFails() async throws {
        var allowsSaves = true
        let (registry, _) = makeRegistry(persistenceOverride: { _, _ in allowsSaves })

        let first = ServerEntry(id: "server-a", url: "https://a.example.com", fetchedName: "Server A", lastUsedAt: Date())
        let added = try XCTUnwrap(registry.addOrUpdate(first))

        allowsSaves = false
        let second = ServerEntry(id: "server-b", url: "https://b.example.com", fetchedName: "Server B", lastUsedAt: Date())
        XCTAssertNil(registry.addOrUpdate(second))
        XCTAssertNil(registry.entry(with: "server-b"))

        let switched = await registry.switchTo(serverId: "server-a")
        XCTAssertFalse(switched)
        XCTAssertNil(registry.activeServerId)

        let removed = await registry.remove(serverId: "server-a")
        XCTAssertFalse(removed)
        XCTAssertEqual(registry.entry(with: "server-a"), added)
    }

    func testServerIDsGiveBackTheAddressTheyWereMadeFrom() {
        let address = "https://media.example.com:8920/emby"
        let id = ServerRegistry.serverId(for: address)
        XCTAssertEqual(ServerRegistry.address(forServerID: id), address)
        XCTAssertEqual(ServerRegistry.address(forServerID: "emby:" + id), address)
        XCTAssertEqual(ServerRegistry.address(forServerID: "jellyfin:" + id), address)
        XCTAssertNil(ServerRegistry.address(forServerID: "server-a"))
        XCTAssertNil(ServerRegistry.address(forServerID: "emby:"))
        XCTAssertNil(ServerRegistry.address(forServerID: ""))
        XCTAssertNil(ServerRegistry.address(forServerID: "emby:" + ServerRegistry.serverId(for: "not an address")))
    }

    func testMissingProfileServerIsPutBackFromItsIDOnly() throws {
        let (registry, _) = makeRegistry()
        let other = ServerEntry(id: "jellyfin:" + ServerRegistry.serverId(for: "https://other.example.com"),
                                url: "https://other.example.com", fetchedName: "Other", lastUsedAt: Date())
        XCTAssertNotNil(registry.addOrUpdate(other))
        let embyID = "emby:" + ServerRegistry.serverId(for: "https://emby.example.com")

        let restored = try XCTUnwrap(registry.restoreEntry(forServerID: embyID))
        XCTAssertEqual(restored.url, "https://emby.example.com")
        XCTAssertEqual(registry.entry(with: embyID), restored)
        // An entry that's already there is left as it is.
        XCTAssertEqual(registry.restoreEntry(forServerID: other.id), other)
        XCTAssertNil(registry.restoreEntry(forServerID: "server-a"))
    }

    func testNewSessionUpsertForgetsTheProfileAndTakesTheNewName() throws {
        let (registry, launchPreferences) = makeRegistry()
        let address = "https://media.example.com"
        let serverId = ServerRegistry.serverId(for: address)

        registry.addOrUpdate(ServerEntry(id: serverId, url: address, fetchedName: "Old Name", lastUsedAt: Date()))
        launchPreferences.remember(profileID: "profile-a", requiresPIN: false, accountEpoch: "epoch-a", for: serverId)

        registry.addOrUpdate(
            ServerEntry(id: serverId, url: address, fetchedName: "New Name", profileId: nil, lastUsedAt: Date()),
            preservingProfile: false
        )

        XCTAssertNil(launchPreferences.rememberedProfile(for: serverId))
        let stored = try XCTUnwrap(registry.entry(with: serverId))
        XCTAssertEqual(stored.fetchedName, "New Name")
        XCTAssertEqual(stored.displayName, "New Name")
    }

    // MARK: Helpers

    /// A registry over its own defaults suites and Keychain service, removed
    /// again when the test ends.
    private func makeRegistry(
        persistenceOverride: (([ServerEntry], String?) -> Bool)? = nil
    ) -> (ServerRegistry, ProfileLaunchPreferences) {
        let suiteName = "registry-tests.shared.\(UUID().uuidString)"
        let standardName = "registry-tests.standard.\(UUID().uuidString)"
        let service = "registry-tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let standard = UserDefaults(suiteName: standardName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
            Self.deleteKeychainItems(service: service)
        }
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let keychain = SharedKeychain(service: service, accessGroup: nil)
        let launchPreferences = ProfileLaunchPreferences(defaults: defaults)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: keychain,
            launchPreferences: launchPreferences,
            persistenceOverride: persistenceOverride
        )
        return (registry, launchPreferences)
    }

    /// Removes every item the test stored under its own service name.
    private nonisolated static func deleteKeychainItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
