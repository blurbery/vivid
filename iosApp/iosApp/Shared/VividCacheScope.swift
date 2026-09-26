import Foundation
import CryptoKit

/// Stable ownership for disposable media caches, never a credential.
enum VividCacheScope {
    private static let unownedSession = UUID().uuidString
    private static let keyCache = ScopeKeyCache()

    static func key(serverID: String, accountID: String, profileID: String) -> String {
        keyCache.key(serverID: serverID, accountID: accountID, profileID: profileID)
    }

    static func recordAccount(_ accountID: String?, serverID: String) {
        let key = "vivid.cache.account." + serverID
        if let accountID { SharedDefaults.shared.set(accountID, forKey: key) }
        else { SharedDefaults.shared.removeObject(forKey: key) }
    }

    static var current: String? {
        let defaults = SharedDefaults.shared
        guard let server = defaults.string(forKey: SharedStorage.activeServerIdKey),
              let account = defaults.string(forKey: "vivid.cache.account." + server),
              let profile = defaults.string(forKey: SharedStorage.profileIdKey),
              !server.isEmpty, !account.isEmpty, !profile.isEmpty else { return nil }
        return key(serverID: server, accountID: account, profileID: profile)
    }

    // Pre-login artwork has no persistent owner and must not reuse an old
    // account's disk cache. The transport gives this namespace no disk cache.
    static var artwork: String { current ?? "unowned-" + unownedSession }

    /// Keep only the most recently used identity. Read the current defaults on
    /// every lookup so account changes never depend on a cache invalidation hook.
    private final class ScopeKeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (serverID: String, accountID: String, profileID: String, key: String)?

        func key(serverID: String, accountID: String, profileID: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            // Compare UTF-8 rather than canonically equivalent Strings: the
            // existing JSON/hash format distinguishes Unicode encodings.
            if let cached, cached.serverID.utf8.elementsEqual(serverID.utf8),
               cached.accountID.utf8.elementsEqual(accountID.utf8),
               cached.profileID.utf8.elementsEqual(profileID.utf8) {
                return cached.key
            }
            // Preserve the existing on-disk namespace, including JSON escaping.
            let data = (try? JSONEncoder().encode([serverID, accountID, profileID])) ?? Data()
            let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            cached = (serverID, accountID, profileID, key)
            return key
        }
    }
}
