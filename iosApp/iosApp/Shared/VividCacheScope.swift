import Foundation
import CryptoKit

/// Stable ownership for disposable media caches, never a credential.
enum VividCacheScope {
    private static let unownedSession = UUID().uuidString

    static func key(serverID: String, accountID: String, profileID: String) -> String {
        let data = (try? JSONEncoder().encode([serverID, accountID, profileID])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
}
