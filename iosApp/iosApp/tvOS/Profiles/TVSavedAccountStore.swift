#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit
#if os(tvOS)
import TVServices
#endif

/// The saved profiles on this device (or this native Apple TV user): their
/// list, the active one, their sessions and PINs in the Keychain, signing in,
/// switching, signing out and deleting, and the hooks iCloud sync uses.
@Observable
@MainActor
final class TVSavedAccountStore {
    static let shared = TVSavedAccountStore()

    private(set) var accounts: [TVSavedAccount] = []
    private(set) var activeID: String? {
        didSet {
            // A saved profile on the chosen server is in use, so the note has
            // done its job. Later sign-outs and deletions sync as before.
            if let chosenServerID, activeAccount?.serverID == chosenServerID { self.chosenServerID = nil }
        }
    }
    var showsSelector = false
    var showsAnimation = false
    private(set) var busy = false
    private(set) var pendingProfileChoice: PendingSiloProfileChoice?
    /// The server the person last chose from server setup or the server list
    /// (see ``VividCloudRestorePolicy``), until a saved profile on it is
    /// active. Never saved, so a relaunch restores the active saved profile as
    /// before.
    private var chosenServerID: String?
    /// Set when a new install's first launch stopped waiting for iCloud and
    /// showed setup (see ``VividCloudAccountSync/synchronizeForFirstLaunch(router:limit:)``).
    /// Until the person signs in, sync still imports saved profiles but
    /// neither chooses one nor restores its session: either would rebuild
    /// the setup screen under them and lose what they typed. Never saved, so
    /// the next launch restores as before. Only iCloud sync and
    /// ``resumeCloudRestore()`` change it.
    var holdsCloudRestore = false
    /// A sync is restoring the active saved profile's session.
    private(set) var isRestoringCloudSession = false
    private(set) var contentRevision = UUID()
    /// The user last read for a credential generation, so leaving a profile
    /// can save it without waiting for its server.
    private var capturedUser: (identity: RefreshAccountIdentity, user: UserInfo)?
    /// Saved profiles per device, or per native Apple TV user.
    static let maximumAccounts = 8
    var canAddAccount: Bool {
        accounts.count < Self.maximumAccounts
    }
    var error: String?
    /// The saved profile whose PIN was just entered, until it is selected.
    private var unlockedID: String?
    private let defaults = SharedDefaults.shared
    private let keychain = SharedKeychain(audience: .currentUser)
    private let listKey = SharedStorage.savedAccountsKey
    private let activeKey = SharedStorage.activeSavedAccountKey
    private let modificationDatesKey = "vivid.accountModificationDates.v1"
    private let backgroundedAtKey = "vivid.accounts.backgroundedAt"
    /// When each saved profile last changed on this device, which decides
    /// whether an iCloud copy is newer.
    private var modificationDates: [String: Date] = [:]

    init() {
        if let data = defaults.data(forKey: listKey),
           let values = try? JSONDecoder().decode([TVSavedAccount].self, from: data) {
            accounts = values
        }
        if let data = defaults.data(forKey: modificationDatesKey),
           let values = try? JSONDecoder().decode([String: Date].self, from: data) {
            modificationDates = values
        }
        activeID = defaults.string(forKey: activeKey)
        // Profiles saved before change dates were kept count as changed now.
        let undated = accounts.filter { modificationDates[$0.id] == nil }
        guard !undated.isEmpty else { return }
        let now = Date()
        for account in undated { modificationDates[account.id] = now }
        persist()
    }

    var activeAccount: TVSavedAccount? { accounts.first { $0.id == activeID } }

    private func accountIndex(_ id: String) -> Int? { accounts.firstIndex { $0.id == id } }

    // MARK: Chosen server and first-launch hold

    /// The person chose the registry's active server, to sign in to or to use.
    func noteChosenServer() {
        let server = ServerRegistry.shared.activeServerId
        // The active saved profile is already on it, so there's nothing for
        // sync to keep, and a note left set would outlive a later sign-out.
        chosenServerID = activeAccount?.serverID == server ? nil : server
    }

    /// A saved profile is signed in, so sync may choose and restore saved
    /// profiles again.
    func resumeCloudRestore() {
        holdsCloudRestore = false
    }

    private var keepsChosenServer: Bool {
        VividCloudRestorePolicy.keepsChosenServer(chosenServerID: chosenServerID,
                                                  activeServerID: ServerRegistry.shared.activeServerId,
                                                  activeAccountServerID: activeAccount?.serverID)
    }

    // MARK: Storage

    private func sessionKey(_ id: String) -> String { "vivid.account.\(id).session.v1" }
    private func pinKey(_ id: String) -> String { "vivid.account.\(id).pin.v1" }

    private func saveSession(_ session: TVSavedAccountSession, id: String) throws {
        guard writeJSON(session, to: sessionKey(id)) else { throw ServerRegistryError.persistenceFailed }
    }

    private func session(_ id: String) -> TVSavedAccountSession? {
        readJSON(TVSavedAccountSession.self, from: sessionKey(id))
    }

    /// Keychain items hold their JSON as a UTF-8 string.
    private func readJSON<Value: Decodable>(_ type: Value.Type, from key: String) -> Value? {
        guard let string = keychain.get(key), let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else { return false }
        return keychain.set(string, for: key)
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

    /// Saves a local change to one profile and shares it through iCloud.
    private func commitChange(to id: String) {
        markAccountChanged(id)
        persist()
        Task { await VividCloudAccountSync.shared.synchronize() }
    }

    // MARK: PIN

    private struct PINRecord: Codable {
        let salt: String
        let digest: String
        var failures: Int = 0
        var blockedUntil: Date?
    }

    private static let pinAttemptsBeforeBlock = 5
    private static let pinBlockDuration: TimeInterval = 30

    private static func pinDigest(salt: String, pin: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func hasPIN(_ id: String) -> Bool {
        accounts.first { $0.id == id }?.pinEnabled == true || keychain.get(pinKey(id)) != nil
    }

    func needsLogin(_ account: TVSavedAccount) -> Bool { account.requiresLogin || session(account.id) == nil }

    /// Only the signed-in active profile can change its own PIN.
    private func canChangePIN(of id: String) -> Bool {
        activeID == id && !showsSelector && AuthService.shared.isLoggedIn
    }

    func setPIN(_ pin: String, accountID: String) -> Bool {
        guard canChangePIN(of: accountID) else { return false }
        guard pin.count == 4, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            error = String(localized: "Enter exactly four digits."); return false
        }
        let salt = UUID().uuidString
        let record = PINRecord(salt: salt, digest: Self.pinDigest(salt: salt, pin: pin))
        guard writeJSON(record, to: pinKey(accountID)) else {
            error = String(localized: "Couldn’t save the PIN."); return false
        }
        if let index = accountIndex(accountID) { accounts[index].pinEnabled = true }
        commitChange(to: accountID)
        return true
    }

    func removePIN(_ id: String) -> Bool {
        guard canChangePIN(of: id), keychain.delete(pinKey(id)) else { return false }
        if let index = accountIndex(id) { accounts[index].pinEnabled = false }
        commitChange(to: id)
        return true
    }

    /// Checks a PIN. Five wrong tries in a row block the profile for 30
    /// seconds, and the count starts again after the block.
    func unlock(_ id: String, pin: String) -> Bool {
        guard var record = readJSON(PINRecord.self, from: pinKey(id)) else { return false }
        if let until = record.blockedUntil, until > Date() {
            error = String(localized: "Too many attempts. Wait 30 seconds and try again."); return false
        }
        let valid = pin.count == 4 && Self.pinDigest(salt: record.salt, pin: pin) == record.digest
        if valid {
            record.failures = 0
            record.blockedUntil = nil
        } else {
            record.failures += 1
            if record.failures >= Self.pinAttemptsBeforeBlock {
                record.blockedUntil = Date().addingTimeInterval(Self.pinBlockDuration)
                record.failures = 0
            }
        }
        guard writeJSON(record, to: pinKey(id)) else { return false }
        if valid {
            unlockedID = id
            error = nil
        } else {
            error = String(localized: "Incorrect PIN. Try again.")
        }
        return valid
    }

    // MARK: Launch and background

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
        defaults.removeObject(forKey: backgroundedAtKey)
        showsSelector = accounts.count > 1 || accounts.first.map { $0.requiresLogin || hasPIN($0.id) } == true
    }

    func enteredBackground() {
        defaults.set(String(Date().timeIntervalSince1970), forKey: backgroundedAtKey)
    }

    /// After 15 minutes away, a device with several profiles, or a PIN on the
    /// active one, asks who's watching again.
    func enteredForeground() {
        let since = Double(defaults.string(forKey: backgroundedAtKey) ?? "") ?? 0
        defaults.removeObject(forKey: backgroundedAtKey)
        guard since > 0, Date().timeIntervalSince1970 - since >= 15 * 60,
              accounts.count > 1 || activeID.map({ hasPIN($0) }) == true else { return }
        unlockedID = nil
        showsSelector = true
        showsAnimation = true
    }

    // MARK: Capturing the live session

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
        // The session and server must still be the ones this capture started on.
        func stillCurrent() async -> Bool {
            guard !blocked() else { return false }
            return identity == (await TokenStore.shared.refreshAccountIdentity())
                && server == ServerRegistry.shared.activeServerId
        }
        // Leaving an account must not wait for its server. Reuse only user
        // metadata verified for this exact credential generation.
        let user: UserInfo?
        if refreshMetadata {
            user = try? await VividAPI.shared.currentUser()
        } else {
            user = capturedUser?.identity == identity ? capturedUser?.user : nil
        }
        guard await stillCurrent(), let user, let userID = user.id else { return false }
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
        if profile == nil {
            profile = accounts.first { sameLogin($0) && $0.profile?.id == liveProfileID }?.profile
        }
        guard let stored = await TokenStore.shared.savedTVSession(expected: identity, profile: profile),
              await stillCurrent() else { return false }
        guard let owner = captureOwner(sameLogin: sameLogin, isSilo: isSilo, liveProfileID: liveProfileID,
                                       profile: profile, pending: pending) else { return false }
        let existing = owner.index.map { accounts[$0] }
        guard existing != nil || canAddAccount else { return false }
        let id = existing?.id ?? UUID().uuidString
        let value = TVSavedAccount(id: id, serverID: server, userID: userID,
                                   username: user.username, profile: profile, requiresLogin: false,
                                   pinEnabled: existing?.pinEnabled,
                                   siloProfileID: owner.binding,
                                   serverName: existing?.serverName)
        do {
            try saveSession(stored, id: id)
        } catch {
            self.error = String(localized: "Couldn’t save this profile on this device.")
            return false
        }
        if let index = owner.index { accounts[index] = value } else { accounts.append(value) }
        activeID = id
        markAccountChanged(id)
        persist()
        if pending == nil { Task { await VividCloudAccountSync.shared.synchronize() } }
        return true
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
            return (accounts.firstIndex { sameLogin($0) && $0.siloProfileID == pending.binding }, pending.binding)
        }
        if let active = accounts.firstIndex(where: { $0.id == activeID && sameLogin($0) }) {
            // A bound saved profile only ever saves its own household member.
            guard SiloProfileBinding.accepts(accounts[active], profileID: liveProfileID) else { return nil }
            return (active, accounts[active].siloProfileID)
        }
        guard isSilo else { return (accounts.firstIndex(where: sameLogin), nil) }
        if let bound = accounts.firstIndex(where: {
            sameLogin($0) && $0.siloProfileID != nil && $0.siloProfileID == liveProfileID
        }) {
            return (bound, accounts[bound].siloProfileID)
        }
        if let unbound = accounts.firstIndex(where: {
            sameLogin($0) && $0.siloProfileID == nil && $0.profile?.id == liveProfileID
        }) {
            return (unbound, nil)
        }
        guard let profile else { return nil }
        // A login's first saved profile is always the original kind, as before.
        let original = accounts.firstIndex { sameLogin($0) && $0.siloProfileID == nil }
        if profile.isPrimary || original == nil { return (original, nil) }
        // Another household member without a saved profile, for example after
        // the app closed between entering the profile and saving it.
        return (nil, profile.id)
    }

    // MARK: Silo household members

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

    // MARK: Switching and signing in

    func select(_ account: TVSavedAccount, router: AppRouter) async {
        guard !busy, !account.requiresLogin, let saved = session(account.id) else { return }
        guard !hasPIN(account.id) || unlockedID == account.id else { return }
        unlockedID = nil
        await captureCurrent(refreshMetadata: false)
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            if activeID != account.id || ServerRegistry.shared.activeServerId != account.serverID
                || !AuthService.shared.isLoggedIn {
                try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID, accountID: account.userID)
            }
            activeID = account.id
            persist()
            await finishLogin(router: router)
        } catch {
            self.error = String(localized: "Couldn’t switch profiles. Please try again.")
            showsSelector = true
        }
    }

    /// - Parameters:
    ///   - quickConnect: a Jellyfin session already approved through Quick
    ///     Connect for `serverURL`, used instead of the username and password.
    ///   - embyConnect: an Emby session for `serverURL` reached through Emby
    ///     Connect, used the same way.
    func authenticate(id: String?, serverURL: String, username: String, password: String, router: AppRouter,
                      provider requestedProvider: MediaServerProvider? = nil, quickConnect: JellyfinLogin? = nil,
                      embyConnect: EmbyLogin? = nil, verified: VerifiedServerLogin? = nil,
                      serverName: String? = nil) async -> Bool {
        guard !busy else { return false }
        guard id != nil || canAddAccount else {
            error = String(localized: "You can save up to eight profiles. Delete a saved profile to add another.")
            return false
        }
        await captureCurrent(refreshMetadata: false)
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            let normalized = ServerRegistry.shared.normalizedUserAddress(serverURL)
            guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else {
                error = String(localized: "Enter a valid server address."); return false
            }
            let selected = id.flatMap { accountIndex($0) }.map { accounts[$0] }
            let provider = requestedProvider
                ?? MediaServerProvider.forServerID(selected?.serverID ?? ServerRegistry.shared.activeServerId)
            let checked: VerifiedServerLogin
            if let verified {
                checked = verified
            } else if provider == .jellyfin, let quickConnect {
                checked = .jellyfin(quickConnect)
            } else if provider == .emby, let embyConnect {
                checked = .emby(embyConnect)
            } else {
                checked = try await .signIn(serverURL: normalized, provider: provider, username: username, password: password)
            }
            let (login, nativeUserID) = checked.response
            let serverID = (provider.usesNativeUser ? provider.rawValue + ":" : "") + ServerRegistry.serverId(for: normalized)
            let userID = String(login.user.id)
            let sameLogin = accounts.first { $0.serverID == serverID && $0.userID == userID }
            func saveServer() throws {
                let entry = ServerEntry(id: serverID, url: normalized,
                                        fetchedName: fetchedName(serverName, serverID: serverID), lastUsedAt: Date())
                guard ServerRegistry.shared.addOrUpdate(entry) != nil else { throw ServerRegistryError.persistenceFailed }
            }
            // Adding a Silo profile may be another household member of a login
            // that is already saved, so its saved profile is chosen once the
            // viewing profile is known.
            if id == nil, provider == .silo {
                guard sameLogin != nil || canAddAccount else {
                    error = String(localized: "You can save up to eight profiles."); return false
                }
                let saved = TVSavedAccountSession(accessToken: login.accessToken, refreshToken: login.refreshToken,
                                                  profile: nil, profileToken: nil, nativeUserID: nativeUserID)
                try saveServer()
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
            // Read again after signing in: iCloud sync may have changed it meanwhile.
            let existing = id.flatMap { accountIndex($0) }.map { accounts[$0] } ?? sameLogin
            if let existing, existing.userID != userID || existing.serverID != serverID {
                error = String(localized: "These credentials belong to a different account. Use Add Profile instead.")
                return false
            }
            guard existing != nil || canAddAccount else {
                error = String(localized: "You can save up to eight profiles."); return false
            }
            let accountID = existing?.id ?? UUID().uuidString
            let account = TVSavedAccount(id: accountID, serverID: serverID, userID: userID,
                                         username: login.user.username, profile: existing?.profile, requiresLogin: false,
                                         pinEnabled: existing?.pinEnabled, siloProfileID: existing?.siloProfileID,
                                         serverName: existing?.serverName)
            // Re-authentication requires a fresh PIN proof for a protected pairing.
            let pairing = existing?.profile.flatMap { $0.hasPin ? nil : $0 }
            let saved = TVSavedAccountSession(accessToken: login.accessToken, refreshToken: login.refreshToken,
                                              profile: pairing, profileToken: nil, nativeUserID: nativeUserID)
            try saveSession(saved, id: accountID)
            try saveServer()
            try await AuthService.shared.restoreTVAccount(saved, serverID: serverID, accountID: userID)
            if let index = accountIndex(accountID) { accounts[index] = account } else { accounts.append(account) }
            activeID = accountID
            markAccountChanged(accountID)
            persist()
            VividCloudAccountSync.shared.noteExplicitAuthentication(account)
            await finishLogin(router: router, prepareHome: true)
            return true
        } catch {
            if quickConnect != nil {
                self.error = String(localized: "Couldn’t finish signing in with Quick Connect. Please try again.")
            } else if embyConnect != nil {
                self.error = String(localized: "Couldn’t finish signing in with Emby Connect. Please try again.")
            } else {
                self.error = String(localized: "Couldn’t sign in. Check the server address, username and password, then try again.")
            }
            return false
        }
    }

    /// The name the server just gave wins over a saved one, so a renamed
    /// server shows its new name. Without one, the saved name stays.
    private func fetchedName(_ serverName: String?, serverID: String) -> String? {
        if let serverName, !serverName.isEmpty { return serverName }
        return ServerRegistry.shared.entry(with: serverID)?.fetchedName
    }

    private func finishLogin(router: AppRouter, prepareHome: Bool = false) async {
        showsSelector = false
        if !AuthService.shared.hasProfile {
            let profiles = try? await StartupContentPrefetcher.fetchProfiles()
            // A household member's saved profile never enters another
            // profile, even the only one left. With no profile, profile
            // selection below starts login preparation, which reports the
            // bound profile as unavailable.
            if let only = profiles?.first, profiles?.count == 1, !only.hasPin,
               activeAccount.map({ SiloProfileBinding.accepts($0, profileID: only.id) }) ?? true {
                try? await AuthService.shared.selectProfile(profileId: only.id)
            }
        }
        guard AuthService.shared.hasProfile else {
            router.showProfileSelection()
            return
        }
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
    }

    // MARK: Signing out and expiry

    func signOut(router: AppRouter) async {
        guard !busy, let id = activeID else { return }
        busy = true; error = nil
        defer { busy = false }
        #if os(iOS)
        showsSelector = true
        #endif
        // Delete the saved session first: a failed remote logout must never restore it later.
        guard keychain.delete(sessionKey(id)) else { error = String(localized: "Couldn’t clear the saved login. Try again."); return }
        if let index = accountIndex(id) { accounts[index].requiresLogin = true }
        markAccountChanged(id)
        persist()
        guard await AuthService.shared.signOut() else {
            error = String(localized: "Couldn’t finish signing out. Please try again."); return
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

    // MARK: Deleting

    @discardableResult
    func deleteAccount(_ id: String, router: AppRouter) async -> Bool {
        guard let account = accounts.first(where: { $0.id == id }) else { return false }
        return await deleteAccounts([account], removedServerID: nil, router: router)
    }

    @discardableResult
    func deleteServer(_ serverID: String, router: AppRouter) async -> Bool {
        await deleteAccounts(accounts.filter { $0.serverID == serverID }, removedServerID: serverID, router: router)
    }

    /// Deletes saved profiles in an order that can be retried at any step:
    /// credentials first, then the live session, local caches, unused
    /// servers, and finally the profiles themselves and their iCloud records.
    private func deleteAccounts(_ selected: [TVSavedAccount], removedServerID: String?, router: AppRouter) async -> Bool {
        guard !busy else { return false }
        busy = true
        error = nil
        defer { busy = false }
        let ids = Set(selected.map(\.id))
        for account in selected {
            guard keychain.delete(sessionKey(account.id)), keychain.delete(pinKey(account.id)) else {
                error = String(localized: "Couldn’t delete the saved profile. Try again.")
                return false
            }
            if let index = accountIndex(account.id) {
                accounts[index].requiresLogin = true
                accounts[index].pinEnabled = false
                markAccountChanged(account.id)
                persist()
            }
        }
        if let activeID, ids.contains(activeID) {
            guard await AuthService.shared.signOut() else {
                error = String(localized: "Couldn’t finish signing out. Try deleting again.")
                return false
            }
            self.activeID = nil
            persist()
        }
        for account in selected { CalendarStore.deleteSavedData(serverID: account.serverID, accountID: account.userID) }
        do {
            for account in selected { try await TVHomeMetadataCache.shared.deleteAccountCache(account) }
        } catch {
            self.error = String(localized: "Couldn’t clear the account cache. Try deleting again.")
            return false
        }
        let remainingAccounts = accounts.filter { !ids.contains($0.id) }
        var serverIDs = Set(selected.map(\.serverID))
        if let removedServerID { serverIDs.insert(removedServerID) }
        for serverID in serverIDs where VividCloudDeletionPolicy.canRemoveServer(serverID, remainingAccounts: remainingAccounts)
            && ServerRegistry.shared.entry(with: serverID) != nil {
            guard await ServerRegistry.shared.remove(serverId: serverID) else {
                error = String(localized: "Couldn’t remove the saved server. Try again.")
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
            if accounts.isEmpty { router.resetToServerSetup() } else { router.resetToLogin() }
        }
        await VividCloudAccountSync.shared.synchronize(router: router)
        return true
    }

    // MARK: Server names and order

    /// Names the server for one saved profile, here and, through iCloud, on
    /// the person's other devices. A nil or blank name shows the server's own
    /// label again. Other profiles on the same server keep their own.
    @discardableResult
    func renameServer(for accountID: String, to name: String?) -> Bool {
        guard !busy, let index = accountIndex(accountID) else { return false }
        let name = TVSavedAccount.serverName(from: name)
        guard accounts[index].serverName != name else { return true }
        accounts[index].serverName = name
        commitChange(to: accountID)
        return true
    }

    @discardableResult
    func saveAccountOrder(_ ids: [String]) -> Bool {
        guard !busy else { return false }
        let sorted = VividCloudPreferencePolicy.ordered(accounts.map(\.id), preferred: ids)
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let order = VividCloudAccountOrder.values(for: sorted.compactMap { byID[$0] })
        do {
            try VividCloudPreferences.shared.setAccountOrder(legacy: order.legacy, full: order.full)
        } catch {
            self.error = String(localized: "Couldn’t save the profile order. Try again.")
            return false
        }
        applyCloudOrder(legacy: order.legacy, full: order.full)
        Task { await VividCloudAccountSync.shared.synchronize() }
        return true
    }

    func applyCloudOrder(legacy: [String]?, full: [String]?) {
        let identities = accounts.map { VividCloudAccountIdentity.key(for: $0) }
        let legacyIdentities = Set(accounts.filter { $0.siloProfileID == nil }.map { VividCloudAccountIdentity.key(for: $0) })
        let sorted = VividCloudAccountOrder.resolved(identities: identities, legacyIdentities: legacyIdentities,
                                                     legacy: legacy, full: full)
        let positions = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0) })
        func position(_ account: TVSavedAccount) -> Int { positions[VividCloudAccountIdentity.key(for: account), default: 0] }
        accounts.sort { position($0) < position($1) }
        if identities != sorted { persist() }
    }

    // MARK: iCloud sync hooks (used by VividCloudAccountSync)

    /// Every saved profile whose server is still saved, keyed by identity.
    /// When two share an identity, the newer change wins.
    func cloudSnapshot() -> [String: VividCloudAccountEnvelope] {
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

    /// Applies a merged vault: deletions first, then newer or new profiles,
    /// then picks an active profile if none is, and signs out of a deleted
    /// or invalidated active session.
    func applyCloudVault(_ vault: VividCloudAccountVault) async -> VividCloudApplyResult {
        let previousActiveID = activeID
        var result = VividCloudApplyResult()
        for identity in vault.tombstones.keys {
            await applyTombstone(identity, in: vault, previousActiveID: previousActiveID, result: &result)
        }
        for identity in vault.accounts.keys.sorted() where vault.tombstones[identity] == nil {
            guard let envelope = vault.accounts[identity] else { continue }
            importEnvelope(envelope, identity: identity, previousActiveID: previousActiveID, result: &result)
        }

        if let activeID, !accounts.contains(where: { $0.id == activeID }) {
            self.activeID = nil
        }
        if activeID == nil, pendingProfileChoice == nil, !keepsChosenServer, !holdsCloudRestore {
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
        let losesActiveSession = result.activeAccountDeleted || result.activeSessionInvalidated
        if activeID != previousActiveID || losesActiveSession {
            contentRevision = UUID()
        }
        if losesActiveSession {
            _ = await AuthService.shared.signOut()
        }
        for serverID in result.orphanedServerIDs
        where VividCloudDeletionPolicy.canRemoveServer(serverID, remainingAccounts: accounts) {
            _ = await ServerRegistry.shared.remove(serverId: serverID)
        }
        return result
    }

    /// Removes the saved profiles a tombstone deletes, unless this device
    /// signed in to them after the deletion. If a cache can't be cleared, the
    /// profiles stay as signed out so the next sync retries.
    private func applyTombstone(_ identity: String, in vault: VividCloudAccountVault, previousActiveID: String?,
                                result: inout VividCloudApplyResult) async {
        if VividCloudAccountSync.shared.signedInAfterDeletion(identity, in: vault) { return }
        let matches: (TVSavedAccount) -> Bool = { VividCloudAccountIdentity.key(for: $0) == identity }
        let matching = accounts.filter(matches)
        var cacheCleanupFailed = false
        for account in matching {
            CalendarStore.deleteSavedData(serverID: account.serverID, accountID: account.userID)
            do {
                try await TVHomeMetadataCache.shared.deleteAccountCache(account)
            } catch {
                cacheCleanupFailed = true
                self.error = String(localized: "Couldn’t clear a deleted account’s cache. Vivid will retry on the next sync.")
            }
        }
        for account in matching {
            _ = keychain.delete(sessionKey(account.id))
            _ = keychain.delete(pinKey(account.id))
            modificationDates.removeValue(forKey: account.id)
            if account.id == previousActiveID { result.activeAccountDeleted = true }
            result.orphanedServerIDs.insert(account.serverID)
        }
        guard !cacheCleanupFailed else {
            for index in accounts.indices where matches(accounts[index]) {
                accounts[index].requiresLogin = true
                accounts[index].pinEnabled = false
            }
            return
        }
        accounts.removeAll(where: matches)
    }

    /// Adds a profile from iCloud, or replaces the local copy when iCloud's
    /// is newer, keeping the local ID. A profile whose credentials or server
    /// can't be saved here is skipped.
    private func importEnvelope(_ envelope: VividCloudAccountEnvelope, identity: String, previousActiveID: String?,
                                result: inout VividCloudApplyResult) {
        // A household member's saved profile only applies under its own identity.
        if envelope.account.siloProfileID != nil,
           VividCloudAccountIdentity.key(for: envelope.account) != identity { return }
        let existingIndex = accounts.firstIndex { VividCloudAccountIdentity.key(for: $0) == identity }
        guard existingIndex != nil || canAddAccount else { return }
        let localID = existingIndex.map { accounts[$0].id } ?? envelope.account.id
        let localDate = modificationDates[localID] ?? .distantPast
        guard envelope.updatedAt > localDate || existingIndex == nil else { return }

        let remote = envelope.account
        let imported = TVSavedAccount(
            id: localID, serverID: remote.serverID, userID: remote.userID, username: remote.username,
            profile: remote.profile, requiresLogin: remote.requiresLogin, pinEnabled: remote.pinEnabled,
            siloProfileID: remote.siloProfileID, serverName: remote.serverName
        )
        if let saved = envelope.session {
            guard (try? saveSession(saved, id: localID)) != nil else { return }
        } else {
            _ = keychain.delete(sessionKey(localID))
        }
        if let pin = envelope.pinRecord {
            guard keychain.set(pin, for: pinKey(localID)) else { return }
        } else {
            _ = keychain.delete(pinKey(localID))
        }
        guard ServerRegistry.shared.addOrUpdate(envelope.server) != nil else { return }
        if let existingIndex { accounts[existingIndex] = imported } else { accounts.append(imported) }
        modificationDates[localID] = envelope.updatedAt
        if localID == previousActiveID, imported.requiresLogin || envelope.session == nil {
            result.activeSessionInvalidated = true
        }
    }

    /// Restores the active saved profile's session after a sync, unless it's
    /// already live or the person is setting up or signing in elsewhere.
    func restoreActiveCloudSessionIfNeeded() async -> Bool {
        guard let account = activeAccount, !account.requiresLogin,
              let saved = session(account.id),
              ServerRegistry.shared.entry(with: account.serverID) != nil else { return false }
        if AuthService.shared.isLoggedIn, ServerRegistry.shared.activeServerId == account.serverID {
            return true
        }
        guard !keepsChosenServer, !holdsCloudRestore else { return false }
        isRestoringCloudSession = true
        defer { isRestoringCloudSession = false }
        do {
            try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID, accountID: account.userID)
            return true
        } catch {
            return false
        }
    }
}
#endif
