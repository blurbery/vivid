import CryptoKit
import Foundation

/// Names who owns a disposable media cache: a server, its server user and a
/// profile. A scope is a hash, never a credential.
enum VividCacheScope {
    /// Artwork fetched before anyone signs in gets this process's own scope,
    /// so it never reuses an earlier account's disk cache. The image cache
    /// gives `unowned-` scopes no disk storage.
    private static let unownedSession = UUID().uuidString
    private static let lastKey = LastKey()

    /// The lowercase hex SHA-256 of the JSON array `[server, account,
    /// profile]`. Cache folders on disk are named with it, so the format
    /// can't change.
    static func key(serverID: String, accountID: String, profileID: String) -> String {
        lastKey.key(for: Identity(serverID: serverID, accountID: accountID, profileID: profileID))
    }

    static func recordAccount(_ accountID: String?, serverID: String) {
        let key = accountKey(serverID: serverID)
        if let accountID {
            SharedDefaults.shared.set(accountID, forKey: key)
        } else {
            SharedDefaults.shared.removeObject(forKey: key)
        }
    }

    /// The server user the live session on `serverID` belongs to.
    static func accountID(for serverID: String) -> String? {
        SharedDefaults.shared.string(forKey: accountKey(serverID: serverID))
    }

    /// The server, server user and profile the live session belongs to.
    static var currentIdentity: (serverID: String, accountID: String, profileID: String)? {
        let defaults = SharedDefaults.shared
        guard let server = defaults.string(forKey: SharedStorage.activeServerIdKey),
              let account = defaults.string(forKey: accountKey(serverID: server)),
              let profile = defaults.string(forKey: SharedStorage.profileIdKey),
              !server.isEmpty, !account.isEmpty, !profile.isEmpty
        else { return nil }
        return (server, account, profile)
    }

    static var current: String? {
        currentIdentity.map { key(serverID: $0.serverID, accountID: $0.accountID, profileID: $0.profileID) }
    }

    static var artwork: String { current ?? "unowned-" + unownedSession }

    private static func accountKey(serverID: String) -> String {
        "vivid.cache.account." + serverID
    }

    private struct Identity {
        let serverID: String
        let accountID: String
        let profileID: String

        /// Compares the UTF-8 bytes, not Swift's canonical equivalence: an
        /// é written as one or two scalars encodes, and so hashes, differently.
        func matches(_ other: Identity) -> Bool {
            serverID.utf8.elementsEqual(other.serverID.utf8)
                && accountID.utf8.elementsEqual(other.accountID.utf8)
                && profileID.utf8.elementsEqual(other.profileID.utf8)
        }

        var hashedKey: String {
            let json = (try? JSONEncoder().encode([serverID, accountID, profileID])) ?? Data()
            return SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Artwork asks for the same scope over and over, so the last one is kept.
    /// The defaults are still read on every lookup, so an account change never
    /// needs this cleared.
    private final class LastKey: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (identity: Identity, key: String)?

        func key(for identity: Identity) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let last, last.identity.matches(identity) { return last.key }
            let key = identity.hashedKey
            last = (identity, key)
            return key
        }
    }
}
