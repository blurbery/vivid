#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit

// The saved profiles' private iCloud records and the rules for merging them.
// Older Vivid builds read the same JSON, so the property names and order are
// the stored format.

/// One saved profile in iCloud, with its session, server and PIN.
struct VividCloudAccountEnvelope: Codable {
    var account: TVSavedAccount
    var session: TVSavedAccountSession?
    var server: ServerEntry
    var pinRecord: String?
    var updatedAt: Date
    var authenticatedAt: Date? = nil
}

struct VividCloudAccountTombstone: Codable {
    var deletedAt: Date
}

/// The decoded payload of an iCloud account record.
struct VividCloudAccountVault: Codable {
    var schemaVersion = 1
    var preferences: [String: VividCloudPreference]? = nil
    var accounts: [String: VividCloudAccountEnvelope] = [:]
    var tombstones: [String: VividCloudAccountTombstone] = [:]
    var serverTombstones: [String: VividCloudAccountTombstone]? = nil

    /// Turns each deleted server into tombstones for its saved profiles, in
    /// the vault or on this device, unless the profile signed in again after
    /// the deletion. A newer tombstone already there is kept.
    mutating func applyServerDeletions(local: [String: VividCloudAccountEnvelope], authentications: [String: Date]) {
        let candidates = accounts.merging(local) { existing, _ in existing }
        for (identity, envelope) in candidates {
            guard let deletion = serverTombstones?[envelope.server.id] else { continue }
            let authenticatedAt = [envelope.authenticatedAt, authentications[identity]].compactMap { $0 }.max()
            guard VividCloudDeletionPolicy.tombstoneWins(
                deletedAt: deletion.deletedAt, explicitAuthenticationAt: authenticatedAt
            ) else { continue }
            if tombstones[identity].map({ $0.deletedAt >= deletion.deletedAt }) != true {
                tombstones[identity] = deletion
            }
        }
    }
}

/// What applying a vault did to the active saved profile and its servers.
struct VividCloudApplyResult {
    var activeAccountDeleted = false
    var activeSessionInvalidated = false
    var orphanedServerIDs: Set<String> = []
}

/// The key a saved profile is stored under in iCloud.
enum VividCloudAccountIdentity {
    /// Lowercase hex SHA-256 of the server and user IDs, plus the bound Silo
    /// profile for a household member, separated by NUL characters.
    static func key(serverID: String, userID: String, siloProfileID: String? = nil) -> String {
        var raw = "\(serverID)\u{0}\(userID)"
        if let siloProfileID { raw += "\u{0}\(siloProfileID)" }
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func key(for account: TVSavedAccount) -> String {
        key(serverID: account.serverID, userID: account.userID, siloProfileID: account.siloProfileID)
    }
}

/// Saved profiles bound to a Silo household member sync in their own iCloud
/// record. Older Vivid builds read only the original record, and they would
/// merge two saved profiles for one login into one (or duplicate them on every
/// sync), so the original record keeps exactly the profiles it always held.
enum VividCloudVaultPartition {
    /// One vault for the sync logic: the original record plus the household
    /// members' record. Tombstones, server deletions and preferences only ever
    /// live in the original record.
    static func combined(main: VividCloudAccountVault, profiles: VividCloudAccountVault) -> VividCloudAccountVault {
        var vault = main
        for (identity, envelope) in profiles.accounts
        where envelope.account.siloProfileID != nil && vault.accounts[identity] == nil {
            vault.accounts[identity] = envelope
        }
        return vault
    }

    /// Splits a combined vault back into the two records.
    static func split(_ vault: VividCloudAccountVault) -> (main: VividCloudAccountVault, profiles: VividCloudAccountVault) {
        var main = vault
        main.accounts = vault.accounts.filter { $0.value.account.siloProfileID == nil }
        var profiles = VividCloudAccountVault()
        profiles.accounts = vault.accounts.filter { $0.value.account.siloProfileID != nil }
        return (main, profiles)
    }
}

/// Saved-profile order in iCloud. `accountOrder` keeps only the profiles an
/// older build knows about, in the same form it writes, so devices on
/// different builds agree on it instead of rewriting it on every sync.
/// `accountOrder.profiles` adds household members, and exists only while one
/// is saved.
enum VividCloudAccountOrder {
    static let legacyKey = "accountOrder"
    static let fullKey = "accountOrder.profiles"

    static func values(for accounts: [TVSavedAccount]) -> (legacy: [String], full: [String]?) {
        let legacy = accounts.filter { $0.siloProfileID == nil }.map { VividCloudAccountIdentity.key(for: $0) }
        guard accounts.contains(where: { $0.siloProfileID != nil }) else { return (legacy, nil) }
        return (legacy, accounts.map { VividCloudAccountIdentity.key(for: $0) })
    }

    /// The full order positions every profile. The legacy order, which an
    /// older build may have changed since, then decides the order of the
    /// original profiles within the places they hold.
    static func resolved(identities: [String], legacyIdentities: Set<String>,
                         legacy: [String]?, full: [String]?) -> [String] {
        var result = VividCloudPreferencePolicy.ordered(identities, preferred: full ?? legacy ?? [])
        guard let legacy else { return result }
        let slots = result.indices.filter { legacyIdentities.contains(result[$0]) }
        let reordered = VividCloudPreferencePolicy.ordered(slots.map { result[$0] }, preferred: legacy)
        for (slot, identity) in zip(slots, reordered) { result[slot] = identity }
        return result
    }
}

enum VividCloudDeletionPolicy {
    /// A server is removed only once no saved profile, signed in or not, uses it.
    static func canRemoveServer(_ serverID: String, remainingAccounts: [TVSavedAccount]) -> Bool {
        !remainingAccounts.contains { $0.serverID == serverID }
    }

    /// A tombstone always wins over routine local state. It can be retired
    /// only by a credential entry that happened after the deletion.
    static func tombstoneWins(deletedAt: Date, explicitAuthenticationAt: Date?) -> Bool {
        guard let explicitAuthenticationAt else { return true }
        return explicitAuthenticationAt <= deletedAt
    }
}

enum VividCloudRestorePolicy {
    /// iCloud sync leaves the active server alone while the person is signing
    /// in to a server they chose, until a saved profile on it is active.
    /// Restoring another saved profile would switch servers under them and
    /// rebuild the sign-in screen, losing what they typed, for example after
    /// leaving Vivid to copy a password.
    static func keepsChosenServer(chosenServerID: String?, activeServerID: String?,
                                  activeAccountServerID: String?) -> Bool {
        guard let chosenServerID, chosenServerID == activeServerID else { return false }
        return activeAccountServerID != chosenServerID
    }
}
#endif
