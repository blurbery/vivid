#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit
import CloudKit
import OSLog
#if os(tvOS)
import TVServices
#endif

struct TVSavedAccount: Codable, Identifiable, Hashable {
    let id: String
    let serverID: String
    let userID: String
    var username: String
    var profile: UserProfile?
    var requiresLogin: Bool
    var pinEnabled: Bool? = nil
    /// The Silo viewing profile this saved profile always enters, for a
    /// household member other than the account's primary profile. Nil keeps
    /// the original behaviour (the primary, or only, profile) and the original
    /// identity, so existing saved profiles are unchanged.
    var siloProfileID: String? = nil

    /// A Silo saved profile is labelled with its viewing profile's name in
    /// Silo, the primary profile included, since that name is chosen there
    /// and isn't the sign-in username. An unbound card uses the name only
    /// when it holds the primary profile. Emby and Jellyfin, or a Silo
    /// profile not loaded yet, keep the username.
    var displayName: String { siloProfileName ?? username }

    /// The Silo viewing profile's name this saved profile shows, if any.
    var siloProfileName: String? {
        guard MediaServerProvider.forServerID(serverID) == .silo, let profile,
              siloProfileID == nil ? profile.isPrimary : profile.id == siloProfileID else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Which Silo viewing profile a saved profile binds to.
enum SiloProfileBinding {
    /// Nil for the primary profile, or the account's only profile, so those
    /// keep the original saved-profile identity. Any other household member
    /// gets its own saved profile. Emby and Jellyfin never bind.
    static func binding(for profile: UserProfile, profileCount: Int, serverID: String) -> String? {
        guard MediaServerProvider.forServerID(serverID) == .silo,
              !profile.isPrimary, profileCount > 1 else { return nil }
        return profile.id
    }

    /// Whether `profileID` is the live profile a saved profile may capture.
    /// A bound profile only ever captures its own Silo profile.
    static func accepts(_ account: TVSavedAccount, profileID: String?) -> Bool {
        guard let bound = account.siloProfileID else { return true }
        return bound == profileID
    }
}

struct TVSavedAccountSession: Codable {
    let accessToken: String
    let refreshToken: String
    let profile: UserProfile?
    let profileToken: String?
    var nativeUserID: String? = nil
}

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

struct VividCloudAccountVault: Codable {
    var schemaVersion = 1
    var preferences: [String: VividCloudPreference]? = nil
    var accounts: [String: VividCloudAccountEnvelope] = [:]
    var tombstones: [String: VividCloudAccountTombstone] = [:]
    var serverTombstones: [String: VividCloudAccountTombstone]? = nil

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

fileprivate struct VividCloudApplyResult {
    var activeAccountDeleted = false
    var activeSessionInvalidated = false
    var orphanedServerIDs: Set<String> = []
}

enum VividCloudAccountIdentity {
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

enum TVAccountRoute: Hashable {
    case editor(String?)
}

/// The Silo viewing profile login preparation should enter.
enum SiloProfileTarget: Equatable {
    /// A saved profile bound to this household member.
    case bound(String)
    /// The account's primary (or only) profile, as before.
    case primary
    /// A new saved profile: the member is chosen when there is more than one.
    case choose
}

/// A sign-in that becomes a new saved profile once its Silo viewing profile
/// is chosen. While it is pending, no saved profile owns the live session, so
/// routine capture and iCloud sync wait instead of saving or replacing it.
struct PendingSiloProfileChoice: Equatable {
    let serverID: String
    /// The viewing profile that was entered, once there is one.
    var profile: UserProfile? = nil
    /// The saved-profile binding for `profile` (see ``SiloProfileBinding``).
    var binding: String? = nil
}

@Observable
@MainActor
final class TVSavedAccountStore {
    static let shared = TVSavedAccountStore()
    private(set) var accounts: [TVSavedAccount] = []
    private(set) var activeID: String?
    var showsSelector = false
    var showsAnimation = false
    private(set) var busy = false
    private(set) var pendingProfileChoice: PendingSiloProfileChoice?
    private(set) var contentRevision = UUID()
    private var capturedUser: (identity: RefreshAccountIdentity, user: UserInfo)?
    /// Saved profiles per device, or per native Apple TV user.
    static let maximumAccounts = 8
    var canAddAccount: Bool {
        accounts.count < Self.maximumAccounts
    }
    var error: String?
    private var unlockedID: String?
    private let defaults = SharedDefaults.shared
    private let keychain = SharedKeychain(audience: .currentUser)
    private let listKey = SharedStorage.savedAccountsKey
    private let activeKey = SharedStorage.activeSavedAccountKey
    private let modificationDatesKey = "vivid.accountModificationDates.v1"
    private var modificationDates: [String: Date] = [:]

    init() {
        if let data = defaults.data(forKey: listKey), let values = try? JSONDecoder().decode([TVSavedAccount].self, from: data) {
            accounts = values
        }
        if let data = defaults.data(forKey: modificationDatesKey),
           let values = try? JSONDecoder().decode([String: Date].self, from: data) {
            modificationDates = values
        }
        activeID = defaults.string(forKey: activeKey)
        let now = Date()
        var seededDates = false
        for account in accounts where modificationDates[account.id] == nil {
            modificationDates[account.id] = now
            seededDates = true
        }
        if seededDates { persist() }
    }

    var activeAccount: TVSavedAccount? { accounts.first { $0.id == activeID } }

    private func sessionKey(_ id: String) -> String { "vivid.account.\(id).session.v1" }

    private func saveSession(_ session: TVSavedAccountSession, id: String) throws {
        let data = try JSONEncoder().encode(session)
        guard let string = String(data: data, encoding: .utf8), keychain.set(string, for: sessionKey(id)) else {
            throw ServerRegistryError.persistenceFailed
        }
    }

    private func session(_ id: String) -> TVSavedAccountSession? {
        guard let string = keychain.get(sessionKey(id)), let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TVSavedAccountSession.self, from: data)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: listKey) }
        if let data = try? JSONEncoder().encode(modificationDates) {
            defaults.set(data, forKey: modificationDatesKey)
        }
        defaults.set(activeID, forKey: activeKey)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    private func markAccountChanged(_ id: String, at date: Date = Date()) {
        modificationDates[id] = date
    }

    private struct PINRecord: Codable {
        let salt: String
        let digest: String
        var failures: Int = 0
        var blockedUntil: Date?
    }
    private func pinKey(_ id: String) -> String { "vivid.account.\(id).pin.v1" }
    func hasPIN(_ id: String) -> Bool {
        accounts.first { $0.id == id }?.pinEnabled == true || keychain.get(pinKey(id)) != nil
    }
    func needsLogin(_ account: TVSavedAccount) -> Bool { account.requiresLogin || session(account.id) == nil }
    func setPIN(_ pin: String, accountID: String) -> Bool {
        guard activeID == accountID, !showsSelector, AuthService.shared.isLoggedIn else { return false }
        guard pin.count == 4, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            error = "Enter exactly four digits."; return false
        }
        let salt = UUID().uuidString
        let digest = SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
        guard let data = try? JSONEncoder().encode(PINRecord(salt: salt, digest: digest)),
              let value = String(data: data, encoding: .utf8), keychain.set(value, for: pinKey(accountID)) else {
            error = "Couldn’t save the PIN."; return false
        }
        if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index].pinEnabled = true }
        markAccountChanged(accountID)
        persist()
        Task { await VividCloudAccountSync.shared.synchronize() }
        return true
    }
    func removePIN(_ id: String) -> Bool {
        guard activeID == id, !showsSelector, AuthService.shared.isLoggedIn else { return false }
        guard keychain.delete(pinKey(id)) else { return false }
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].pinEnabled = false }
        markAccountChanged(id)
        persist()
        Task { await VividCloudAccountSync.shared.synchronize() }
        return true
    }
    func unlock(_ id: String, pin: String) -> Bool {
        guard let raw = keychain.get(pinKey(id)), let data = raw.data(using: .utf8),
              var record = try? JSONDecoder().decode(PINRecord.self, from: data) else { return false }
        if let until = record.blockedUntil, until > Date() {
            error = "Too many attempts. Wait 30 seconds and try again."; return false
        }
        let digest = SHA256.hash(data: Data((record.salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
        let valid = pin.count == 4 && digest == record.digest
        if valid {
            record.failures = 0; record.blockedUntil = nil
        } else {
            record.failures += 1
            if record.failures >= 5 { record.blockedUntil = Date().addingTimeInterval(30); record.failures = 0 }
        }
        guard let updated = try? JSONEncoder().encode(record),
              let string = String(data: updated, encoding: .utf8), keychain.set(string, for: pinKey(id)) else { return false }
        if valid { unlockedID = id; error = nil }
        else { error = "Incorrect PIN. Try again." }
        return valid
    }
    /// Restore only this native user's explicitly selected local account.
    /// Cloud availability must not decide whether an existing user is signed in.
    func restoreLocalSessionForLaunch() async throws {
        guard let account = activeAccount, !account.requiresLogin,
              ServerRegistry.shared.entry(with: account.serverID) != nil else { return }
        let credentials = keychain.withAudience(SharedStorage.accountCredentialAudience)
        if ServerRegistry.shared.activeServerId == account.serverID,
           try credentials.getChecked(TokenStore.accessTokenKey(for: account.serverID)) != nil {
            return
        }
        guard let raw = try keychain.getChecked(sessionKey(account.id)),
              let data = raw.data(using: .utf8),
              let saved = try? JSONDecoder().decode(TVSavedAccountSession.self, from: data) else { return }
        try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID, accountID: account.userID)
    }

    func prepareColdLaunch() {
        ProfileLaunchPreferences.shared.behavior = .automatic
        unlockedID = nil
        showsAnimation = false
        defaults.removeObject(forKey: "vivid.accounts.backgroundedAt")
        showsSelector = accounts.count > 1 || accounts.first.map { $0.requiresLogin || hasPIN($0.id) } == true
    }
    func enteredBackground() {
        defaults.set(String(Date().timeIntervalSince1970), forKey: "vivid.accounts.backgroundedAt")
    }
    func enteredForeground() {
        let since = Double(defaults.string(forKey: "vivid.accounts.backgroundedAt") ?? "") ?? 0
        defaults.removeObject(forKey: "vivid.accounts.backgroundedAt")
        guard since > 0, Date().timeIntervalSince1970 - since >= 15 * 60,
              accounts.count > 1 || activeID.map({ hasPIN($0) }) == true else { return }
        unlockedID = nil
        showsSelector = true
        showsAnimation = true
    }

    func captureCurrent(refreshMetadata: Bool = true) async {
        _ = await capture(refreshMetadata: refreshMetadata, committing: nil)
    }

    /// Saves the live session into the saved profile that owns it. Routine
    /// capture never picks a saved profile by server and user alone once a
    /// Silo login can have several; committing a pending choice saves the
    /// chosen household member's own saved profile.
    private func capture(refreshMetadata: Bool, committing pending: PendingSiloProfileChoice?) async -> Bool {
        // A pending choice owns the live session until it commits. Its commit
        // runs inside the sign-in that holds `busy`.
        func blocked() -> Bool {
            pending == nil ? busy || pendingProfileChoice != nil : pendingProfileChoice != pending
        }
        guard !blocked(), AuthService.shared.isLoggedIn,
              let server = ServerRegistry.shared.activeServerId,
              let identity = await TokenStore.shared.refreshAccountIdentity() else { return false }
        // Leaving an account must not wait for its server. Reuse only user
        // metadata verified for this exact credential generation.
        let user: UserInfo?
        if refreshMetadata {
            user = try? await VividAPI.shared.currentUser()
        } else {
            user = capturedUser?.identity == identity ? capturedUser?.user : nil
        }
        guard !blocked(), identity == (await TokenStore.shared.refreshAccountIdentity()),
              server == ServerRegistry.shared.activeServerId else { return false }
        guard let user, let userID = user.id else { return false }
        let liveProfileID = AuthService.shared.profileId
        let isSilo = MediaServerProvider.forServerID(server) == .silo
        // A Silo session is saved only once its viewing profile is known, so a
        // sign-in still choosing one can't overwrite another saved profile.
        if isSilo, liveProfileID == nil { return false }
        if let pending, pending.profile?.id != liveProfileID { return false }
        VividCacheScope.recordAccount(userID, serverID: server)
        capturedUser = (identity, user)
        let sameLogin: (TVSavedAccount) -> Bool = { $0.serverID == server && $0.userID == userID }
        var profile = pending?.profile ?? CurrentProfileStore.shared.profile
        if profile == nil, refreshMetadata {
            profile = (try? await AuthService.shared.getProfiles())?.first { $0.id == liveProfileID }
        }
        if profile == nil,
           let previous = accounts.first(where: { sameLogin($0) && $0.profile?.id == liveProfileID })?.profile {
            profile = previous
        }
        guard let stored = await TokenStore.shared.savedTVSession(expected: identity, profile: profile),
              !blocked(), identity == (await TokenStore.shared.refreshAccountIdentity()),
              server == ServerRegistry.shared.activeServerId else { return false }
        guard let owner = captureOwner(sameLogin: sameLogin, isSilo: isSilo, liveProfileID: liveProfileID,
                                       profile: profile, pending: pending) else { return false }
        let index = owner.index
        guard index != nil || canAddAccount else { return false }
        let id = index.map { accounts[$0].id } ?? UUID().uuidString
        let value = TVSavedAccount(id: id, serverID: server, userID: userID,
                                   username: user.username, profile: profile, requiresLogin: false,
                                   pinEnabled: index.flatMap { accounts[$0].pinEnabled },
                                   siloProfileID: owner.binding)
        do {
            try saveSession(stored, id: id)
            if let index { accounts[index] = value } else { accounts.append(value) }
            activeID = id
            markAccountChanged(id)
            persist()
            if pending == nil { Task { await VividCloudAccountSync.shared.synchronize() } }
            return true
        } catch {
            self.error = "Couldn’t save this profile on this device."
            return false
        }
    }

    /// The saved profile a capture writes: an existing index, or nil to add
    /// one, with its Silo binding. Nil means nothing may be saved.
    private func captureOwner(sameLogin: (TVSavedAccount) -> Bool, isSilo: Bool, liveProfileID: String?,
                              profile: UserProfile?, pending: PendingSiloProfileChoice?) -> (index: Int?, binding: String?)? {
        if let pending {
            // A login's original saved profile may already hold this member.
            if let held = accounts.firstIndex(where: {
                sameLogin($0) && $0.siloProfileID == nil && $0.profile?.id == pending.profile?.id
            }) {
                return (held, nil)
            }
            let index = accounts.firstIndex { sameLogin($0) && $0.siloProfileID == pending.binding }
            return (index, pending.binding)
        }
        if let active = accounts.firstIndex(where: { $0.id == activeID && sameLogin($0) }) {
            // A bound saved profile only ever saves its own household member.
            guard SiloProfileBinding.accepts(accounts[active], profileID: liveProfileID) else { return nil }
            return (active, accounts[active].siloProfileID)
        }
        guard isSilo else {
            return (accounts.firstIndex(where: sameLogin), nil)
        }
        if let bound = accounts.firstIndex(where: { sameLogin($0) && $0.siloProfileID != nil && $0.siloProfileID == liveProfileID }) {
            return (bound, accounts[bound].siloProfileID)
        }
        if let unbound = accounts.firstIndex(where: { sameLogin($0) && $0.siloProfileID == nil && $0.profile?.id == liveProfileID }) {
            return (unbound, nil)
        }
        guard let profile else { return nil }
        // A login's first saved profile is always the original kind, as before.
        let original = accounts.firstIndex { sameLogin($0) && $0.siloProfileID == nil }
        if profile.isPrimary || original == nil {
            return (original, nil)
        }
        // Another household member without a saved profile, for example after
        // the app closed between entering the profile and saving it.
        return (nil, profile.id)
    }

    /// The viewing profile login preparation enters for the live session.
    /// Only an explicit new sign-in chooses; a saved profile bound to a
    /// household member enters that member; everything else enters the
    /// primary profile as before.
    func profileTarget(newSignIn: Bool) -> SiloProfileTarget {
        guard let server = ServerRegistry.shared.activeServerId,
              MediaServerProvider.forServerID(server) == .silo else { return .primary }
        if pendingProfileChoice != nil || newSignIn { return .choose }
        guard let account = activeAccount, account.serverID == server,
              let userID = VividCacheScope.accountID(for: server), account.userID == userID else { return .primary }
        return account.siloProfileID.map(SiloProfileTarget.bound) ?? .primary
    }

    /// Hold the live Silo session for a profile choice. No saved profile owns
    /// it meanwhile, and iCloud sync waits so it can't restore another one.
    func beginProfileChoice() {
        guard pendingProfileChoice == nil, let server = ServerRegistry.shared.activeServerId else { return }
        pendingProfileChoice = PendingSiloProfileChoice(serverID: server)
        if activeID != nil {
            activeID = nil
            persist()
        }
    }

    /// Records the viewing profile that was entered for the pending choice.
    func noteChosenProfile(_ profile: UserProfile, profileCount: Int) {
        guard var pending = pendingProfileChoice else { return }
        pending.profile = profile
        pending.binding = SiloProfileBinding.binding(for: profile, profileCount: profileCount, serverID: pending.serverID)
        pendingProfileChoice = pending
    }

    /// Saves the chosen household member as a saved profile. The choice stays
    /// pending if saving fails, so retrying saves it.
    func commitProfileChoice() async -> Bool {
        guard let pending = pendingProfileChoice else { return true }
        guard pending.profile != nil else { return false }
        // Add Profile already knows the signed-in user from its login.
        let identity = await TokenStore.shared.refreshAccountIdentity()
        let knowsUser = identity != nil && capturedUser?.identity == identity
        guard await capture(refreshMetadata: !knowsUser, committing: pending) else { return false }
        pendingProfileChoice = nil
        if let account = activeAccount { VividCloudAccountSync.shared.noteExplicitAuthentication(account) }
        Task { await VividCloudAccountSync.shared.synchronize() }
        return true
    }

    /// Whether this household member already has a saved profile for the
    /// login on this device.
    func hasSavedProfile(_ profile: UserProfile, serverID: String, userID: String, profileCount: Int) -> Bool {
        let binding = SiloProfileBinding.binding(for: profile, profileCount: profileCount, serverID: serverID)
        return accounts.contains {
            $0.serverID == serverID && $0.userID == userID
                && ($0.siloProfileID == binding || ($0.siloProfileID == nil && $0.profile?.id == profile.id))
        }
    }

    /// Saves another household member of `account`'s Silo login as its own
    /// saved profile, with the session approved for it. The live session and
    /// active saved profile are unchanged.
    func addHouseholdProfile(_ profile: UserProfile, profileCount: Int, session: TVSavedAccountSession,
                             alongside account: TVSavedAccount) -> Bool {
        guard !busy, canAddAccount,
              !hasSavedProfile(profile, serverID: account.serverID, userID: account.userID, profileCount: profileCount) else {
            return false
        }
        let added = TVSavedAccount(
            id: UUID().uuidString, serverID: account.serverID, userID: account.userID,
            username: account.username, profile: profile, requiresLogin: false,
            siloProfileID: SiloProfileBinding.binding(for: profile, profileCount: profileCount, serverID: account.serverID)
        )
        guard (try? saveSession(session, id: added.id)) != nil else { return false }
        accounts.append(added)
        markAccountChanged(added.id)
        persist()
        VividCloudAccountSync.shared.noteExplicitAuthentication(added)
        Task { await VividCloudAccountSync.shared.synchronize() }
        return true
    }

    /// The sign-in was cancelled before a profile was saved. The caller signs
    /// out of the live session, then syncs.
    @discardableResult
    func abandonProfileChoice() -> Bool {
        guard pendingProfileChoice != nil else { return false }
        pendingProfileChoice = nil
        showsSelector = !accounts.isEmpty
        return true
    }

    func select(_ account: TVSavedAccount, router: AppRouter) async {
        guard !busy, !account.requiresLogin, let saved = session(account.id) else { return }
        guard !hasPIN(account.id) || unlockedID == account.id else { return }
        unlockedID = nil
        await captureCurrent(refreshMetadata: false)
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            if activeID != account.id || ServerRegistry.shared.activeServerId != account.serverID || !AuthService.shared.isLoggedIn {
                try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID, accountID: account.userID)
            }
            activeID = account.id
            persist()
            await finishLogin(router: router)
        } catch {
            self.error = "Couldn’t switch profiles. Please try again."
            showsSelector = true
        }
    }

    func authenticate(id: String?, serverURL: String, username: String, password: String, router: AppRouter, provider requestedProvider: MediaServerProvider? = nil) async -> Bool {
        guard !busy else { return false }
        guard id != nil || canAddAccount else { error = "You can save up to eight profiles. Delete a saved profile to add another."; return false }
        await captureCurrent(refreshMetadata: false)
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            let normalized = ServerRegistry.shared.normalizedUserAddress(serverURL)
            guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                error = "Enter a valid server address."; return false
            }
            let selected = id.flatMap { selectedID in accounts.first { $0.id == selectedID } }
            let provider = requestedProvider ?? MediaServerProvider.forServerID(selected?.serverID ?? ServerRegistry.shared.activeServerId)
            let login: LoginResponse
            let nativeUserID: String?
            if provider == .jellyfin {
                let result = try await JellyfinConnection.login(serverURL: normalized, username: username, password: password)
                nativeUserID = result.userID
                login = LoginResponse(accessToken:result.token,refreshToken:"",expiresIn:0,
                    user:AuthUser(id:JellyfinAdapter.numberID(result.userID),username:username,email:"",role:"user",downloadAllowed:false,impersonation:nil))
            } else if provider == .emby {
                let result = try await EmbyConnection.login(serverURL: normalized, username: username, password: password)
                nativeUserID = result.userID
                login = LoginResponse(accessToken:result.token,refreshToken:"",expiresIn:0,
                    user:AuthUser(id:EmbyAdapter.numberID(result.userID),username:username,email:"",role:"user",downloadAllowed:false,impersonation:nil))
            } else {
                nativeUserID = nil
                login = try await HTTPClient.shared.loginSavedAccount(serverURL: normalized, username: username, password: password)
            }
            let serverID = (provider.usesNativeUser ? provider.rawValue + ":" : "") + ServerRegistry.serverId(for: normalized)
            let userID = String(login.user.id)
            let sameLogin = accounts.first { $0.serverID == serverID && $0.userID == userID }
            // Adding a Silo profile may be another household member of a login
            // that is already saved, so its saved profile is chosen once the
            // viewing profile is known.
            if id == nil, provider == .silo {
                guard sameLogin != nil || canAddAccount else { error = "You can save up to eight profiles."; return false }
                let saved = TVSavedAccountSession(accessToken: login.accessToken, refreshToken: login.refreshToken,
                                                 profile: nil, profileToken: nil, nativeUserID: nativeUserID)
                let entry = ServerEntry(id: serverID, url: normalized,
                                        fetchedName: ServerRegistry.shared.entry(with: serverID)?.fetchedName, lastUsedAt: Date())
                guard ServerRegistry.shared.addOrUpdate(entry) != nil else { throw ServerRegistryError.persistenceFailed }
                try await AuthService.shared.restoreTVAccount(saved, serverID: serverID, accountID: userID)
                if let identity = await TokenStore.shared.refreshAccountIdentity() {
                    capturedUser = (identity, UserInfo(id: userID, username: login.user.username, isAdmin: nil))
                }
                pendingProfileChoice = PendingSiloProfileChoice(serverID: serverID)
                activeID = nil
                persist()
                // The explicit sign-in is recorded when the chosen profile is
                // saved, for that saved profile's own identity.
                await finishLogin(router: router, prepareHome: true)
                return true
            }
            let existing = id.flatMap { id in accounts.first { $0.id == id } } ?? sameLogin
            if let existing, existing.userID != userID || existing.serverID != serverID {
                error = "These credentials belong to a different account. Use Add Profile instead."; return false
            }
            guard existing != nil || canAddAccount else { error = "You can save up to eight profiles."; return false }
            let accountID = existing?.id ?? UUID().uuidString
            let account = TVSavedAccount(id: accountID, serverID: serverID, userID: userID,
                                         username: login.user.username, profile: existing?.profile, requiresLogin: false,
                                         pinEnabled: existing?.pinEnabled, siloProfileID: existing?.siloProfileID)
            // Re-authentication requires a fresh PIN proof for a protected pairing.
            let pairing = existing?.profile.flatMap { $0.hasPin ? nil : $0 }
            let saved = TVSavedAccountSession(accessToken: login.accessToken, refreshToken: login.refreshToken,
                                             profile: pairing, profileToken: nil, nativeUserID: nativeUserID)
            try saveSession(saved, id: accountID)
            let entry = ServerEntry(id: serverID, url: normalized,
                                    fetchedName: ServerRegistry.shared.entry(with: serverID)?.fetchedName, lastUsedAt: Date())
            guard ServerRegistry.shared.addOrUpdate(entry) != nil else { throw ServerRegistryError.persistenceFailed }
            try await AuthService.shared.restoreTVAccount(saved, serverID: serverID, accountID: userID)
            if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index] = account }
            else { accounts.append(account) }
            activeID = accountID
            markAccountChanged(accountID)
            persist()
            VividCloudAccountSync.shared.noteExplicitAuthentication(account)
            await finishLogin(router: router, prepareHome: true)
            return true
        } catch {
            self.error = "Couldn’t sign in. Check the server address, username and password, then try again."
            return false
        }
    }

    private func finishLogin(router: AppRouter, prepareHome: Bool = false) async {
        showsSelector = false
        if !AuthService.shared.hasProfile {
            let profiles = try? await StartupContentPrefetcher.fetchProfiles()
            if let only = profiles?.first, profiles?.count == 1, !only.hasPin {
                try? await AuthService.shared.selectProfile(profileId: only.id)
            }
        }
        if AuthService.shared.hasProfile {
            #if os(iOS)
            HomeSectionPreferences.shared.refresh()
            TVHomeSpotlightPreferences.shared.refresh()
            DownloadSettings.shared.reloadForCurrentProfile()
                TVTMDbStore.shared.reloadForCurrentProfile()
            UICustomizationPreferences.shared.restoreCachedPreferences()
            await PlayerSettings.shared.reloadForCurrentProfile()
            router.dismissItemDetail()
            #endif
            // Prepare the local snapshot before rebuilding an already-visible
            // Home for a saved-account switch. Network refresh remains async.
            if !prepareHome {
                guard await StartupContentPrefetcher.prefetchAuthenticatedContent() else { return }
            }
            // Server publication precedes the token/profile commit. Rebuild
            // only after restoration so both platforms discard early loads
            // and same-server account state from the outgoing session.
            contentRevision = UUID()
            if prepareHome {
                await TVLoginPreparation.shared.begin(router: router)
            } else {
                router.resetToHome()
            }
        } else {
            router.showProfileSelection()
        }
    }

    #if DEBUG
    /// Explicit Xcode launch action for testing the complete setup journey.
    func signOutForSetup() async -> Bool {
        guard !busy else { print("VIVID_SETUP_FAILURE_BUSY"); return false }
        busy = true
        defer { busy = false }
        if let id = activeID {
            guard keychain.delete(sessionKey(id)) else { print("VIVID_SETUP_FAILURE_SAVED_SESSION"); return false }
            if let index = accounts.firstIndex(where: { $0.id == id }) {
                accounts[index].requiresLogin = true
            }
            persist()
        }
        guard await AuthService.shared.signOut() else { print("VIVID_SETUP_FAILURE_AUTH"); return false }
        activeID = nil
        persist()
        showsSelector = false
        return true
    }
    #endif

    func signOut(router: AppRouter) async {
        guard !busy, let id = activeID else { return }
        busy = true; error = nil
        defer { busy = false }
        #if os(iOS)

        showsSelector = true
        #endif
        // Delete the saved session first: a failed remote logout must never restore it later.
        guard keychain.delete(sessionKey(id)) else { error = "Couldn’t clear the saved login. Try again."; return }
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].requiresLogin = true }
        markAccountChanged(id)
        persist()
        guard await AuthService.shared.signOut() else {
            error = "Couldn’t finish signing out. Please try again."; return
        }
        activeID = nil
        contentRevision = UUID()
        persist()
        showsSelector = true
        showsAnimation = true
        router.resetToLogin()
        await VividCloudAccountSync.shared.synchronize(router: router)
    }
    /// The server behind `serverID` refused the active session, which
    /// TokenStore has already dropped. Without this the app lands on the bare
    /// sign-in form with no saved profiles until a relaunch recomputes the
    /// selector.
    ///
    /// The active account needs a fresh sign-in, so it is marked like an
    /// explicit sign-out marks it. That one flag stops every automatic
    /// restore path (launch, cloud sync, the selector's periodic sync) from
    /// reinstalling the refused session and looping back here. It is not
    /// recorded as an account change, so it isn't pushed to other devices
    /// whose sessions may be fine, though an upload already pending for this
    /// account can still carry it. A newer sign-in synced from another device
    /// still replaces it. `activeID` is kept so cloud sync does not pick and
    /// restore a different saved account on its own.
    func sessionExpired(serverID: String) {
        if let index = accounts.firstIndex(where: { $0.id == activeID && $0.serverID == serverID }),
           !accounts[index].requiresLogin {
            accounts[index].requiresLogin = true
            persist()
        }
        unlockedID = nil
        showsSelector = !accounts.isEmpty
    }

    @discardableResult
    func deleteAccount(_ id: String, router: AppRouter) async -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        return await deleteAccounts([account], removedServerID: nil, router: router)
    }

    @discardableResult
    func deleteServer(_ serverID: String, router: AppRouter) async -> Bool {
        await deleteAccounts(accounts.filter { $0.serverID == serverID }, removedServerID: serverID, router: router)
    }

    private func deleteAccounts(_ selected: [TVSavedAccount], removedServerID: String?, router: AppRouter) async -> Bool {
        guard !busy else { return false }
        busy = true
        error = nil
        defer { busy = false }
        let ids = Set(selected.map(\.id))
        for account in selected {
            guard keychain.delete(sessionKey(account.id)), keychain.delete(pinKey(account.id)) else {
                error = "Couldn’t delete the saved profile. Try again."
                return false
            }
            if let index = accounts.firstIndex(where: { $0.id == account.id }) {
                accounts[index].requiresLogin = true
                accounts[index].pinEnabled = false
                markAccountChanged(account.id)
                persist()
            }
        }
        if let activeID, ids.contains(activeID) {
            guard await AuthService.shared.signOut() else {
                error = "Couldn’t finish signing out. Try deleting again."
                return false
            }
            self.activeID = nil
            persist()
        }
        do {
            for account in selected { try await TVHomeMetadataCache.shared.deleteAccountCache(account) }
        } catch {
            self.error = "Couldn’t clear the account cache. Try deleting again."
            return false
        }
        let remainingAccounts = accounts.filter { !ids.contains($0.id) }
        var serverIDs = Set(selected.map(\.serverID))
        if let removedServerID { serverIDs.insert(removedServerID) }
        for serverID in serverIDs where VividCloudDeletionPolicy.canRemoveServer(serverID, remainingAccounts: remainingAccounts)
            && ServerRegistry.shared.entry(with: serverID) != nil {
            guard await ServerRegistry.shared.remove(serverId: serverID) else {
                error = "Couldn’t remove the saved server. Try again."
                return false
            }
        }
        accounts.removeAll { ids.contains($0.id) }
        for id in ids { modificationDates.removeValue(forKey: id) }
        if let unlockedID, ids.contains(unlockedID) { self.unlockedID = nil }
        persist()
        for account in selected { VividCloudAccountSync.shared.noteDeletion(of: account) }
        if let removedServerID { VividCloudAccountSync.shared.noteServerDeletion(removedServerID) }
        contentRevision = UUID()
        if activeID == nil {
            showsSelector = !accounts.isEmpty
            if accounts.isEmpty { router.resetToServerSetup() }
            else { router.resetToLogin() }
        }
        await VividCloudAccountSync.shared.synchronize(router: router)
        return true
    }

    @discardableResult
    func saveAccountOrder(_ ids: [String]) -> Bool {
        guard !busy else { return false }
        let current = accounts.map(\.id)
        let sorted = VividCloudPreferencePolicy.ordered(current, preferred: ids)
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let order = VividCloudAccountOrder.values(for: sorted.compactMap { byID[$0] })
        do {
            try VividCloudPreferences.shared.setAccountOrder(legacy: order.legacy, full: order.full)
            applyCloudOrder(legacy: order.legacy, full: order.full)
            Task { await VividCloudAccountSync.shared.synchronize() }
            return true
        } catch {
            self.error = "Couldn’t save the profile order. Try again."
            return false
        }
    }

    func applyCloudOrder(legacy: [String]?, full: [String]?) {
        let identities = accounts.map { VividCloudAccountIdentity.key(for: $0) }
        let legacyIdentities = Set(accounts.filter { $0.siloProfileID == nil }.map { VividCloudAccountIdentity.key(for: $0) })
        let sorted = VividCloudAccountOrder.resolved(identities: identities, legacyIdentities: legacyIdentities,
                                                     legacy: legacy, full: full)
        let positions = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
        accounts.sort { positions[VividCloudAccountIdentity.key(for: $0), default: 0] < positions[VividCloudAccountIdentity.key(for: $1), default: 0] }
        if identities != sorted { persist() }
    }

    fileprivate func cloudSnapshot() -> [String: VividCloudAccountEnvelope] {
        var snapshot: [String: VividCloudAccountEnvelope] = [:]
        for account in accounts {
            guard let server = ServerRegistry.shared.entry(with: account.serverID) else { continue }
            let envelope = VividCloudAccountEnvelope(
                account: account,
                session: session(account.id),
                server: server,
                pinRecord: keychain.get(pinKey(account.id)),
                updatedAt: modificationDates[account.id] ?? .distantPast
            )
            let identity = VividCloudAccountIdentity.key(for: account)
            if let existing = snapshot[identity], existing.updatedAt >= envelope.updatedAt { continue }
            snapshot[identity] = envelope
        }
        return snapshot
    }

    fileprivate func applyCloudVault(_ vault: VividCloudAccountVault) async -> VividCloudApplyResult {
        let previousActiveID = activeID
        var result = VividCloudApplyResult()

        for identity in vault.tombstones.keys {
            if VividCloudAccountSync.shared.signedInAfterDeletion(identity, in: vault) { continue }
            let matching = accounts.filter { VividCloudAccountIdentity.key(for: $0) == identity }
            var cacheCleanupFailed = false
            for account in matching {
                do { try await TVHomeMetadataCache.shared.deleteAccountCache(account) }
                catch { cacheCleanupFailed = true; self.error = "Couldn’t clear a deleted account’s cache. Vivid will retry on the next sync." }
            }
            for account in matching {
                _ = keychain.delete(sessionKey(account.id))
                _ = keychain.delete(pinKey(account.id))
                modificationDates.removeValue(forKey: account.id)
                if account.id == previousActiveID { result.activeAccountDeleted = true }
                result.orphanedServerIDs.insert(account.serverID)
            }
            if cacheCleanupFailed {
                for index in accounts.indices where VividCloudAccountIdentity.key(for: accounts[index]) == identity {
                    accounts[index].requiresLogin = true
                    accounts[index].pinEnabled = false
                }
                continue
            }
            accounts.removeAll { VividCloudAccountIdentity.key(for: $0) == identity }
        }

        for identity in vault.accounts.keys.sorted() where vault.tombstones[identity] == nil {
            guard let envelope = vault.accounts[identity] else { continue }
            // A household member's saved profile only applies under its own identity.
            if envelope.account.siloProfileID != nil,
               VividCloudAccountIdentity.key(for: envelope.account) != identity { continue }
            let existingIndex = accounts.firstIndex {
                VividCloudAccountIdentity.key(for: $0) == identity
            }
            guard existingIndex != nil || canAddAccount else { continue }
            let localID = existingIndex.map { accounts[$0].id } ?? envelope.account.id
            let localDate = modificationDates[localID] ?? .distantPast
            guard envelope.updatedAt > localDate || existingIndex == nil else { continue }

            var imported = envelope.account
            imported = TVSavedAccount(
                id: localID,
                serverID: imported.serverID,
                userID: imported.userID,
                username: imported.username,
                profile: imported.profile,
                requiresLogin: imported.requiresLogin,
                pinEnabled: imported.pinEnabled,
                siloProfileID: imported.siloProfileID
            )
            if let saved = envelope.session {
                guard (try? saveSession(saved, id: localID)) != nil else { continue }
            } else {
                _ = keychain.delete(sessionKey(localID))
            }
            if let pin = envelope.pinRecord {
                guard keychain.set(pin, for: pinKey(localID)) else { continue }
            } else {
                _ = keychain.delete(pinKey(localID))
            }
            guard ServerRegistry.shared.addOrUpdate(envelope.server) != nil else { continue }
            if let existingIndex { accounts[existingIndex] = imported }
            else { accounts.append(imported) }
            modificationDates[localID] = envelope.updatedAt
            if localID == previousActiveID,
               imported.requiresLogin || envelope.session == nil {
                result.activeSessionInvalidated = true
            }
        }

        if let activeID, !accounts.contains(where: { $0.id == activeID }) {
            self.activeID = nil
        }
        if activeID == nil, pendingProfileChoice == nil {
            activeID = accounts
                .filter { !$0.requiresLogin && session($0.id) != nil }
                .max { (modificationDates[$0.id] ?? .distantPast) < (modificationDates[$1.id] ?? .distantPast) }?
                .id
        }
        persist()
        // iOS keys its entire routed screen tree by this revision. Importing
        // saved-account metadata must not discard an open Settings page or
        // playback session. Only a changed active account or invalidated
        // authority requires rebuilding that tree.
        if activeID != previousActiveID || result.activeAccountDeleted || result.activeSessionInvalidated {
            contentRevision = UUID()
        }

        if result.activeAccountDeleted || result.activeSessionInvalidated {
            _ = await AuthService.shared.signOut()
        }
        for serverID in result.orphanedServerIDs
        where VividCloudDeletionPolicy.canRemoveServer(serverID, remainingAccounts: accounts) {
            _ = await ServerRegistry.shared.remove(serverId: serverID)
        }
        return result
    }

    fileprivate func restoreActiveCloudSessionIfNeeded() async -> Bool {
        guard let account = activeAccount, !account.requiresLogin,
              let saved = session(account.id),
              ServerRegistry.shared.entry(with: account.serverID) != nil else { return false }
        if AuthService.shared.isLoggedIn,
           ServerRegistry.shared.activeServerId == account.serverID {
            return true
        }
        do {
            try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID, accountID: account.userID)
            return true
        } catch {
            return false
        }
    }

}

@Observable
@MainActor
final class VividCloudAccountSync {
    static let shared = VividCloudAccountSync()

    private static let containerIdentifier = "iCloud.com.blurbery.vivid"
    private static let recordType = "VividAccountVault"
    private static let payloadKey = "payload"
    private static let recordID = CKRecord.ID(recordName: "account-vault-v1")
    /// Saved profiles bound to a Silo household member (see ``VividCloudVaultPartition``).
    private static let profileRecordID = CKRecord.ID(recordName: "account-vault-profiles-v1")
    private static let tombstoneDefaultsKey = "vivid.cloudAccountTombstones.v1"
    private static let serverTombstoneDefaultsKey = "vivid.cloudServerTombstones.v1"
    private static let resurrectionDefaultsKey = "vivid.cloudAccountResurrections.v1"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "CloudAccountSync"
    )

    private let container = CKContainer(identifier: containerIdentifier)
    private let defaults = UserDefaults.standard
    private(set) var bootstrapFailed = false
    private var isSynchronizing = false
    private var needsAnotherSynchronization = false
    private var pendingRouter: AppRouter?

    private init() {}

    func noteDeletion(of account: TVSavedAccount) {
        try? VividCloudPreferences.shared.removeAccountPreferences(account)
        let identity = VividCloudAccountIdentity.key(for: account)
        var tombstones = loadTombstones()
        tombstones[identity] = VividCloudAccountTombstone(deletedAt: Date())
        save(tombstones, key: Self.tombstoneDefaultsKey)

        var resurrections = loadResurrections()
        resurrections.removeValue(forKey: identity)
        save(resurrections, key: Self.resurrectionDefaultsKey)
    }

    func noteServerDeletion(_ serverID: String) {
        var deletions: [String: VividCloudAccountTombstone] = load([String: VividCloudAccountTombstone].self, key: Self.serverTombstoneDefaultsKey) ?? [:]
        deletions[serverID] = VividCloudAccountTombstone(deletedAt: Date())
        save(deletions, key: Self.serverTombstoneDefaultsKey)
    }

    /// Only an explicit credential entry may revive an account identity that
    /// was previously deleted. Routine capture and stale-device uploads never
    /// create this marker.
    /// A sync reads deletions before it applies them. If this device signed in
    /// to the account after the deletion, even while the sync was running,
    /// the account is kept; the next sync retires the deletion.
    fileprivate func signedInAfterDeletion(_ identity: String, in vault: VividCloudAccountVault) -> Bool {
        guard let deletedAt = vault.tombstones[identity]?.deletedAt,
              let signedInAt = loadResurrections()[identity] else { return false }
        return !VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: signedInAt)
    }

    /// Sign-ins still to upload after a sync: anything recorded or updated
    /// while it ran. Unchanged entries were carried by the uploaded vault.
    static func resurrections(_ current: [String: Date], afterUploading synced: [String: Date]) -> [String: Date] {
        current.filter { identity, date in synced[identity] != date }
    }

    func noteExplicitAuthentication(_ account: TVSavedAccount) {
        noteExplicitAuthentication(serverID: account.serverID, userID: account.userID, siloProfileID: account.siloProfileID)
    }

    func noteExplicitAuthentication(serverID: String, userID: String, siloProfileID: String? = nil) {
        var resurrections = loadResurrections()
        resurrections[VividCloudAccountIdentity.key(serverID: serverID, userID: userID, siloProfileID: siloProfileID)] = Date()
        save(resurrections, key: Self.resurrectionDefaultsKey)
    }

    func synchronize(router: AppRouter? = nil) async {
        if let router {
            pendingRouter = router
        }
        guard !isSynchronizing else {
            needsAnotherSynchronization = true
            while isSynchronizing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return
        }

        isSynchronizing = true
        var routingContext = router
        repeat {
            needsAnotherSynchronization = false
            if let pendingRouter {
                routingContext = pendingRouter
                self.pendingRouter = nil
            }
            await synchronizeOnce(router: routingContext)
        } while needsAnotherSynchronization
        isSynchronizing = false
    }

    private func synchronizeOnce(router: AppRouter?) async {
        // A Silo profile choice owns the live session; the commit syncs after it.
        guard TVSavedAccountStore.shared.pendingProfileChoice == nil else { return }
        do {
            bootstrapFailed = false
            let status = try await container.accountStatus()
            guard status == .available else {
                bootstrapFailed = status != .noAccount
                return
            }
            _ = try VividCloudPreferences.shared.capture(accounts: TVSavedAccountStore.shared.accounts)
            // A media server outage must not block account restoration.
            try? await VividCloudPreferences.shared.captureSharedSettings()
            var activeWasDeleted = false
            var activeSessionWasInvalidated = false
            // Sign-ins recorded before this sync started. Any recorded while it
            // runs stay local for the next sync.
            let syncedResurrections = loadResurrections()
            var savedSuccessfully = false

            for _ in 0..<3 {
                let (record, existingPayload) = try await fetchRecord()
                // Without a readable household record, sync carries on but never
                // writes that record, so other devices' saved profiles survive.
                let profileState = await fetchProfileRecord()
                var vault = VividCloudVaultPartition.combined(
                    main: try decodeVault(existingPayload),
                    profiles: profileState?.vault ?? VividCloudAccountVault()
                )
                _ = try VividCloudPreferences.shared.capture(accounts: TVSavedAccountStore.shared.accounts)
                let localTombstones = loadTombstones()
                let resurrections = vault.accounts.compactMapValues(\.authenticatedAt)
                    .merging(loadResurrections(), uniquingKeysWith: max)

                let serverDeletions: [String: VividCloudAccountTombstone] = load([String: VividCloudAccountTombstone].self, key: Self.serverTombstoneDefaultsKey) ?? [:]
                for (serverID, deletion) in serverDeletions {
                    if vault.serverTombstones?[serverID].map({ $0.deletedAt >= deletion.deletedAt }) == true { continue }
                    if vault.serverTombstones == nil { vault.serverTombstones = [:] }
                    vault.serverTombstones?[serverID] = deletion
                }
                vault.applyServerDeletions(local: TVSavedAccountStore.shared.cloudSnapshot(), authentications: resurrections)

                for (identity, resurrectionDate) in resurrections {
                    if let tombstone = vault.tombstones[identity],
                       !VividCloudDeletionPolicy.tombstoneWins(
                           deletedAt: tombstone.deletedAt,
                           explicitAuthenticationAt: resurrectionDate
                       ) {
                        vault.tombstones.removeValue(forKey: identity)
                    }
                }
                for (identity, tombstone) in localTombstones {
                    if !VividCloudDeletionPolicy.tombstoneWins(
                        deletedAt: tombstone.deletedAt,
                        explicitAuthenticationAt: resurrections[identity]
                    ) {
                        continue
                    }
                    if let existing = vault.tombstones[identity], existing.deletedAt >= tombstone.deletedAt {
                        continue
                    }
                    vault.tombstones[identity] = tombstone
                }
                for identity in vault.tombstones.keys {
                    vault.accounts.removeValue(forKey: identity)
                }

                for account in TVSavedAccountStore.shared.accounts
                where vault.tombstones[VividCloudAccountIdentity.key(for: account)] != nil
                    && !signedInAfterDeletion(VividCloudAccountIdentity.key(for: account), in: vault) {
                    try VividCloudPreferences.shared.removeAccountPreferences(account)
                }
                guard TVSavedAccountStore.shared.pendingProfileChoice == nil else { return }
                let applyResult = await TVSavedAccountStore.shared.applyCloudVault(vault)
                activeWasDeleted = activeWasDeleted || applyResult.activeAccountDeleted
                activeSessionWasInvalidated = activeSessionWasInvalidated || applyResult.activeSessionInvalidated

                for (identity, var envelope) in TVSavedAccountStore.shared.cloudSnapshot()
                where vault.tombstones[identity] == nil {
                    let existing = vault.accounts[identity]
                    envelope.authenticatedAt = [existing?.authenticatedAt, resurrections[identity]].compactMap { $0 }.max()
                    if let existing, existing.updatedAt >= envelope.updatedAt,
                       existing.authenticatedAt == envelope.authenticatedAt { continue }
                    vault.accounts[identity] = envelope
                }

                vault.preferences = try VividCloudPreferences.shared.reconcile(vault.preferences ?? [:], accounts: TVSavedAccountStore.shared.accounts)
                let legacyOrder = vault.preferences?[VividCloudAccountOrder.legacyKey]?.value
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                let fullOrder = vault.preferences?[VividCloudAccountOrder.fullKey]?.value
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                if legacyOrder != nil || fullOrder != nil {
                    TVSavedAccountStore.shared.applyCloudOrder(legacy: legacyOrder, full: fullOrder)
                }
                let parts = VividCloudVaultPartition.split(vault)
                let payload = try Self.encoder.encode(parts.main)
                let profilePayload = try Self.encoder.encode(parts.profiles)
                let savesMain = payload != existingPayload
                // The household record is created only once a member is saved.
                let savesProfiles = profileState.map {
                    profilePayload != $0.payload && ($0.payload != nil || !parts.profiles.accounts.isEmpty)
                } ?? false
                if !savesMain && !savesProfiles {
                    savedSuccessfully = true
                    break
                }
                do {
                    if savesMain {
                        record.encryptedValues[Self.payloadKey] = payload as NSData
                        _ = try await container.privateCloudDatabase.save(record)
                    }
                    if savesProfiles, let profileRecord = profileState?.record {
                        profileRecord.encryptedValues[Self.payloadKey] = profilePayload as NSData
                        _ = try await container.privateCloudDatabase.save(profileRecord)
                    }
                    savedSuccessfully = true
                    break
                } catch let error as CKError where error.code == .serverRecordChanged {
                    continue
                }
            }

            guard savedSuccessfully else { bootstrapFailed = true; return }
            VividCloudPreferences.shared.startObserving()
            var retainedTombstones = loadTombstones()
            for identity in loadResurrections().keys {
                retainedTombstones.removeValue(forKey: identity)
            }
            save(retainedTombstones, key: Self.tombstoneDefaultsKey)
            let pendingResurrections = Self.resurrections(loadResurrections(), afterUploading: syncedResurrections)
            if pendingResurrections.isEmpty {
                defaults.removeObject(forKey: Self.resurrectionDefaultsKey)
            } else {
                save(pendingResurrections, key: Self.resurrectionDefaultsKey)
            }
            // A profile choice that began during this sync keeps the live session.
            guard TVSavedAccountStore.shared.pendingProfileChoice == nil else { return }
            let restored = await TVSavedAccountStore.shared.restoreActiveCloudSessionIfNeeded()
            if restored { try? await VividCloudPreferences.shared.applySharedSettings() }

            if activeWasDeleted || activeSessionWasInvalidated {
                if restored {
                    if AuthService.shared.hasProfile { router?.resetToHome() }
                    else { router?.showProfileSelection() }
                } else if TVSavedAccountStore.shared.accounts.isEmpty {
                    router?.resetToServerSetup()
                } else {
                    TVSavedAccountStore.shared.showsSelector = true
                    router?.resetToLogin()
                }
            } else if restored,
                      let router,
                      router.authState == .needsLogin || router.authState == .needsServerSetup {
                if AuthService.shared.hasProfile { router.resetToHome() }
                else { router.showProfileSelection() }
            }
        } catch {
            bootstrapFailed = true
            Self.logger.notice("Private iCloud account sync is temporarily unavailable.")
        }
    }

    private func fetchRecord() async throws -> (CKRecord, Data?) {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.recordID)
            guard let payload = Self.payloadData(from: record) else { throw ServerRegistryError.persistenceFailed }
            return (record, payload)
        } catch let error as CKError where error.code == .unknownItem {
            return (CKRecord(recordType: Self.recordType, recordID: Self.recordID), nil)
        }
    }

    /// The household record, or nil when it can't be read or decoded. A
    /// record that doesn't exist yet reads as empty.
    private func fetchProfileRecord() async -> (record: CKRecord, payload: Data?, vault: VividCloudAccountVault)? {
        do {
            let record = try await container.privateCloudDatabase.record(for: Self.profileRecordID)
            guard let payload = Self.payloadData(from: record),
                  let vault = try? decodeVault(payload) else { return nil }
            return (record, payload, vault)
        } catch let error as CKError where error.code == .unknownItem {
            return (CKRecord(recordType: Self.recordType, recordID: Self.profileRecordID), nil, VividCloudAccountVault())
        } catch {
            return nil
        }
    }

    private func decodeVault(_ data: Data?) throws -> VividCloudAccountVault {
        guard let data else { return VividCloudAccountVault() }
        let vault = try Self.decoder.decode(VividCloudAccountVault.self, from: data)
        guard vault.schemaVersion == 1 else { throw ServerRegistryError.persistenceFailed }
        return vault
    }

    private static func payloadData(from record: CKRecord) -> Data? {
        if let data = record.encryptedValues[payloadKey] as? Data { return data }
        if let data = record.encryptedValues[payloadKey] as? NSData { return data as Data }
        return nil
    }

    private func loadTombstones() -> [String: VividCloudAccountTombstone] {
        load([String: VividCloudAccountTombstone].self, key: Self.tombstoneDefaultsKey) ?? [:]
    }

    private func loadResurrections() -> [String: Date] {
        load([String: Date].self, key: Self.resurrectionDefaultsKey) ?? [:]
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
#endif
