#!/usr/bin/env python3
"""Run native-profile launch methods against isolated, instrumented stores."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
def method(path, marker):
    source = (root / path).read_text()
    start = source.index(marker)
    brace = source.index('{', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

registry = 'iosApp/iosApp/Networking/ServerRegistry.swift'
accounts = 'iosApp/iosApp/tvOS/Profiles/TVSavedAccountStore.swift'
swift = r'''
import Foundation
enum KeychainAudience: Hashable { case currentUser, userIndependent }
enum ReadError: Error { case unavailable }
@MainActor final class Storage {
    var user = "a"
    var items: [String: String] = [:]
    var unavailable = false
}
@MainActor struct Keychain {
    let storage: Storage
    var audience = KeychainAudience.currentUser
    func withAudience(_ audience: KeychainAudience) -> Self { Self(storage: storage, audience: audience) }
    func getChecked(_ key: String) throws -> String? {
        if storage.unavailable { throw ReadError.unavailable }
        return storage.items[(audience == .currentUser ? storage.user : "shared") + ":" + key]
    }
    func set(_ value: String, for key: String) { storage.items[storage.user + ":" + key] = value }
}
struct Defaults {
    var values: [String: String] = [:]
    func string(forKey key: String) -> String? { values[key] }
    func data(forKey key: String) -> Data? { values[key]?.data(using: .utf8) }
}
struct Entry: Codable { let id: String; var lastUsedAt = Date(timeIntervalSince1970: 0) }
enum SharedStorage {
    static let activeServerIdKey = "activeServerId"
    static let accountCredentialAudience = KeychainAudience.currentUser
}
enum TokenStore { static func accessTokenKey(for id: String) -> String { id + ".access" } }
@MainActor final class ServerRegistry {
    static var shared = ServerRegistry(storage: Storage())
    static let defaultsKey = "legacy"
    static let currentTVRegistryAccount = "currentRegistry"
    static let sharedTVRegistryAccount = "sharedRegistry"
    struct SharedRegistryState: Codable { let entries: [Entry] }
    struct RegistryState: Codable { let activeServerId: String?; let entries: [Entry] }
    private struct SavedAccountServerReference: Decodable { let serverID: String }
    let keychain: Keychain
    var defaults = Defaults()
    var entries: [Entry] = []
    var activeServerId: String?
    var mirrors = 0, writes = 0
    init(storage: Storage) { keychain = Keychain(storage: storage) }
    func entry(with id: String) -> Entry? { entries.first { $0.id == id } }
    func persist() {
        let data = try! JSONEncoder().encode(SharedRegistryState(entries: entries))
        keychain.set(String(decoding: data, as: UTF8.self), for: Self.currentTVRegistryAccount)
        writes += 1
    }
    func registerDiagnosticsSensitiveHosts(_ entries: [Entry]) {}
    func mirrorActiveServer() { mirrors += 1 }
''' + method(registry, 'static func ownedLegacyServerIDs') + '\n' + method(registry, 'private func loadTVRegistry') + r'''
    func load() throws { try loadTVRegistry() }
}
struct Account { let id: String; let serverID: String; let userID: String; var requiresLogin = false }
struct TVSavedAccountSession: Codable { let accessToken: String }
@MainActor final class AuthService {
    static let shared = AuthService()
    var restores = 0
    func restoreTVAccount(_ session: TVSavedAccountSession, serverID: String, accountID: String) async throws {
        restores += 1
        let registry = ServerRegistry.shared
        registry.activeServerId = serverID
        registry.keychain.set(session.accessToken, for: TokenStore.accessTokenKey(for: serverID))
    }
}
@MainActor final class Accounts {
    var activeAccount: Account?
    let keychain: Keychain
    init(storage: Storage) { keychain = Keychain(storage: storage) }
    func sessionKey(_ id: String) -> String { "session." + id }
''' + method(accounts, 'func restoreLocalSessionForLaunch') + r'''
}
@main struct Checks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1
        }
        let storage = Storage()
        storage.items["shared:sharedRegistry"] = #"{"entries":[{"id":"server-a","lastUsedAt":0},{"id":"server-b","lastUsedAt":0}]}"#
        let a = ServerRegistry(storage: storage)
        a.defaults.values["vivid.accounts.v1"] = #"[{"serverID":"server-a"}]"#
        a.defaults.values["activeServerId"] = "server-a"
        try a.load()
        check(a.entries.map(\.id) == ["server-a"], "Only this user's saved servers migrate")
        check(storage.items["shared:sharedRegistry"] != nil, "Migration retains the legacy registry")
        storage.user = "b"
        let b = ServerRegistry(storage: storage); try b.load()
        check(b.entries.isEmpty && b.activeServerId == nil, "A new native user stays in setup")
        b.defaults.values["vivid.accounts.v1"] = #"[{"serverID":"server-b"}]"#
        try b.load()
        check(b.entries.map(\.id) == ["server-b"], "Second native user migrates only their servers")
        storage.user = "a"
        let returned = ServerRegistry(storage: storage)
        returned.defaults = a.defaults
        try returned.load()
        check(returned.entries.map(\.id) == ["server-a"], "Returning to A restores A after B's registry write")
        storage.unavailable = true
        let unavailable = ServerRegistry(storage: storage)
        do { try unavailable.load(); preconditionFailure("Expected retryable read failure") }
        catch ReadError.unavailable {}
        check(unavailable.mirrors == 0 && unavailable.writes == 0, "Locked storage must not erase routing or migrate an empty registry")
        storage.unavailable = false
        let legacy = ServerRegistry(storage: Storage())
        legacy.defaults.values["legacy"] = #"{"activeServerId":"legacy-a","entries":[{"id":"legacy-a","lastUsedAt":0}]}"#
        try legacy.load()
        check(legacy.entries.map(\.id) == ["legacy-a"], "Older per-user defaults migrate locally")
        check(ServerRegistry.ownedLegacyServerIDs(savedAccounts: Data("invalid".utf8), activeServerID: nil).isEmpty, "Invalid account metadata cannot import another user's registry")

        ServerRegistry.shared = returned
        let accountStore = Accounts(storage: storage)
        accountStore.activeAccount = Account(id: "a", serverID: "server-a", userID: "user-a")
        storage.items["a:session.a"] = #"{"accessToken":"sample-a"}"#
        storage.items["shared:server-a.access"] = "other-user"
        try await accountStore.restoreLocalSessionForLaunch()
        check(storage.items["a:server-a.access"] == "sample-a", "Launch restores the current user's saved session without cloud")
        check(storage.items["shared:server-a.access"] == "other-user", "Restoration leaves shared legacy credentials untouched")
        let restored = AuthService.shared.restores
        storage.items["a:server-a.access"] = "rotated-a"
        try await accountStore.restoreLocalSessionForLaunch()
        check(AuthService.shared.restores == restored && storage.items["a:server-a.access"] == "rotated-a", "A healthy rotated session is not overwritten by an older snapshot")
        storage.user = "b"
        ServerRegistry.shared = b
        let accountB = Accounts(storage: storage)
        accountB.activeAccount = Account(id: "b", serverID: "server-b", userID: "user-b")
        storage.items["b:session.b"] = #"{"accessToken":"sample-b"}"#
        try await accountB.restoreLocalSessionForLaunch()
        check(storage.items["b:server-b.access"] == "sample-b", "B restores B's own session")
        b.entries.append(Entry(id: "server-a"))
        accountB.activeAccount = Account(id: "b", serverID: "server-a", userID: "another-user")
        try await accountB.restoreLocalSessionForLaunch()
        check(storage.items["b:server-a.access"] == "sample-b" && storage.items["a:server-a.access"] == "rotated-a", "Different native users on the same server keep independent credentials")
        storage.user = "a"; ServerRegistry.shared = returned
        try await accountStore.restoreLocalSessionForLaunch()
        check(storage.items["a:server-a.access"] == "rotated-a", "A survives a complete A to B to A switch")
        storage.items.removeValue(forKey: "a:server-a.access")
        accountStore.activeAccount?.requiresLogin = true
        let before = AuthService.shared.restores
        try await accountStore.restoreLocalSessionForLaunch()
        check(AuthService.shared.restores == before, "Explicit sign-out must not restore credentials")
        accountStore.activeAccount?.requiresLogin = false
        storage.items["a:session.a"] = "invalid"
        try await accountStore.restoreLocalSessionForLaunch()
        check(AuthService.shared.restores == before, "Invalid saved sessions are not restored")
        storage.unavailable = true
        do { try await accountStore.restoreLocalSessionForLaunch(); preconditionFailure("Expected credential read error") }
        catch ReadError.unavailable {}
        check(AuthService.shared.restores == before, "Unavailable credentials remain retryable, not signed out")
        print("\(count) native-profile restoration checks passed")
    }
}
'''
audience = next(line.strip() for line in (root/'iosApp/iosApp/Shared/SharedStorage.swift').read_text().splitlines()
                if 'static let accountCredentialAudience:' in line)
swift = swift.replace('static let accountCredentialAudience = KeychainAudience.currentUser', audience)
with tempfile.TemporaryDirectory(prefix='vivid-native-profile-', dir=root.parent) as temp:
    folder = Path(temp)
    path = folder / 'checks.swift'
    path.write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder/'cache'), str(path), '-o', str(folder/'checks')], check=True, timeout=90)
    subprocess.run([str(folder/'checks')], check=True, timeout=15)
