#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit
import CloudKit
import OSLog

struct TVSavedAccount: Codable, Identifiable, Hashable {
    let id: String
    let serverID: String
    let userID: String
    var username: String
    var profile: UserProfile?
    var requiresLogin: Bool
    var pinEnabled: Bool? = nil
}

struct TVSavedAccountSession: Codable {
    let accessToken: String
    let refreshToken: String
    let profile: UserProfile?
    let profileToken: String?
    var nativeUserID: String? = nil
}

fileprivate struct VividCloudAccountEnvelope: Codable {
    var account: TVSavedAccount
    var session: TVSavedAccountSession?
    var server: ServerEntry
    var pinRecord: String?
    var updatedAt: Date
}

fileprivate struct VividCloudAccountTombstone: Codable {
    var deletedAt: Date
}

fileprivate struct VividCloudAccountVault: Codable {
    var schemaVersion = 1
    var preferences: [String: VividCloudPreference]? = nil
    var accounts: [String: VividCloudAccountEnvelope] = [:]
    var tombstones: [String: VividCloudAccountTombstone] = [:]
}

fileprivate struct VividCloudApplyResult {
    var activeAccountDeleted = false
    var activeSessionInvalidated = false
    var orphanedServerIDs: Set<String> = []
}

enum VividCloudAccountIdentity {
    static func key(serverID: String, userID: String) -> String {
        SHA256.hash(data: Data("\(serverID)\u{0}\(userID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func key(for account: TVSavedAccount) -> String {
        key(serverID: account.serverID, userID: account.userID)
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

@Observable
@MainActor
final class TVSavedAccountStore {
    static let shared = TVSavedAccountStore()
    private(set) var accounts: [TVSavedAccount] = []
    private(set) var activeID: String?
    var showsSelector = false
    var showsAnimation = false
    private(set) var busy = false
    private(set) var contentRevision = UUID()
    var canAddAccount: Bool {
        #if os(iOS)
        accounts.count < 3
        #else
        true
        #endif
    }
    var error: String?
    private var unlockedID: String?
    private let defaults = SharedDefaults.shared
    private let keychain = SharedKeychain(audience: .currentUser)
    private let listKey = "vivid.accounts.v1"
    private let activeKey = "vivid.activeAccount.v1"
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

    func captureCurrent() async {
        guard !busy, AuthService.shared.isLoggedIn,
              let server = ServerRegistry.shared.activeServerId,
              let identity = await TokenStore.shared.refreshAccountIdentity() else { return }
        let user = try? await VividAPI.shared.currentUser()
        guard !busy, identity == (await TokenStore.shared.refreshAccountIdentity()),
              server == ServerRegistry.shared.activeServerId else { return }
        guard let user, let userID = user.id else { return }
        var profile = CurrentProfileStore.shared.profile
        if profile == nil {
            profile = (try? await AuthService.shared.getProfiles())?.first { $0.id == AuthService.shared.profileId }
        }
        #if os(tvOS)
        if profile == nil,
           let previous = accounts.first(where: { $0.serverID == server && $0.userID == userID })?.profile,
           previous.id == AuthService.shared.profileId {
            profile = previous
        }
        #endif
        guard let stored = await TokenStore.shared.savedTVSession(expected: identity, profile: profile),
              !busy, identity == (await TokenStore.shared.refreshAccountIdentity()),
              server == ServerRegistry.shared.activeServerId else { return }
        let index = accounts.firstIndex { $0.serverID == server && $0.userID == userID }
        guard index != nil || canAddAccount else { return }
        let id = index.map { accounts[$0].id } ?? UUID().uuidString
        let value = TVSavedAccount(id: id, serverID: server, userID: userID,
                                   username: user.username, profile: profile, requiresLogin: false,
                                   pinEnabled: index.flatMap { accounts[$0].pinEnabled })
        do {
            try saveSession(stored, id: id)
            if let index { accounts[index] = value } else { accounts.append(value) }
            activeID = id
            markAccountChanged(id)
            persist()
            Task { await VividCloudAccountSync.shared.synchronize() }
        } catch { self.error = "Couldn’t save this profile on this device." }
    }

    func select(_ account: TVSavedAccount, router: AppRouter) async {
        guard !busy, !account.requiresLogin, let saved = session(account.id) else { return }
        guard !hasPIN(account.id) || unlockedID == account.id else { return }
        unlockedID = nil
        await captureCurrent()
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            if activeID != account.id || ServerRegistry.shared.activeServerId != account.serverID || !AuthService.shared.isLoggedIn {
                try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID)
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
        guard id != nil || canAddAccount else { error = "You can save up to three profiles. Delete a saved profile to add another."; return false }
        await captureCurrent()
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false; Task { await captureCurrent() } }
        do {
            let normalized = ServerRegistry.normalize(url: serverURL)
            guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                error = "Enter a valid server address."; return false
            }
            let selected = id.flatMap { selectedID in accounts.first { $0.id == selectedID } }
            let provider = requestedProvider ?? MediaServerProvider.forServerID(selected?.serverID ?? ServerRegistry.shared.activeServerId)
            let login: LoginResponse
            let nativeUserID: String?
            if provider == .emby {
                let result = try await EmbyConnection.login(serverURL: normalized, username: username, password: password)
                nativeUserID = result.userID
                login = LoginResponse(accessToken:result.token,refreshToken:"",expiresIn:0,
                    user:AuthUser(id:EmbyAdapter.numberID(result.userID),username:username,email:"",role:"user",downloadAllowed:false,impersonation:nil))
            } else {
                nativeUserID = nil
                login = try await HTTPClient.shared.loginSavedAccount(serverURL: normalized, username: username, password: password)
            }
            let serverID = (provider == .emby ? "emby:" : "") + ServerRegistry.serverId(for: normalized)
            let userID = String(login.user.id)
            let existing = id.flatMap { id in accounts.first { $0.id == id } }
                ?? accounts.first { $0.serverID == serverID && $0.userID == userID }
            if let existing, existing.userID != userID || existing.serverID != serverID {
                error = "These credentials belong to a different account. Use Add Profile instead."; return false
            }
            guard existing != nil || canAddAccount else { error = "You can save up to three profiles."; return false }
            let accountID = existing?.id ?? UUID().uuidString
            let account = TVSavedAccount(id: accountID, serverID: serverID, userID: userID,
                                         username: login.user.username, profile: existing?.profile, requiresLogin: false,
                                         pinEnabled: existing?.pinEnabled)
            // Re-authentication requires a fresh PIN proof for a protected pairing.
            let pairing = existing?.profile.flatMap { $0.hasPin ? nil : $0 }
            let saved = TVSavedAccountSession(accessToken: login.accessToken, refreshToken: login.refreshToken,
                                             profile: pairing, profileToken: nil, nativeUserID: nativeUserID)
            try saveSession(saved, id: accountID)
            let entry = ServerEntry(id: serverID, url: normalized,
                                    fetchedName: ServerRegistry.shared.entry(with: serverID)?.fetchedName, lastUsedAt: Date())
            guard ServerRegistry.shared.addOrUpdate(entry) != nil else { throw ServerRegistryError.persistenceFailed }
            try await AuthService.shared.restoreTVAccount(saved, serverID: serverID)
            if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index] = account }
            else { accounts.append(account) }
            activeID = accountID
            markAccountChanged(accountID)
            persist()
            VividCloudAccountSync.shared.noteExplicitAuthentication(account)
            await finishLogin(router: router)
            return true
        } catch {
            self.error = "Couldn’t sign in. Check the server address, username and password, then try again."
            return false
        }
    }

    private func finishLogin(router: AppRouter) async {
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
            await CurrentProfileStore.shared.refresh(force: true)
            _ = await OverlayPrefsStore.shared.hydrateIfNeeded()
            await UICustomizationPreferences.shared.refresh()
            await PlayerSettings.shared.reloadForCurrentProfile()
            router.dismissItemDetail()
            contentRevision = UUID()
            #endif
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            router.resetToHome()
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
    func deleteAccount(_ id: String, router: AppRouter) async {
        guard !busy, let account = accounts.first(where: { $0.id == id }) else { return }
        busy = true
        error = nil
        defer { busy = false }
        guard keychain.delete(sessionKey(id)), keychain.delete(pinKey(id)) else {
            error = "Couldn’t delete the saved profile. Try again."
            return
        }
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].requiresLogin = true
            accounts[index].pinEnabled = false
            markAccountChanged(id)
            persist()
        }
        if activeID == id {
            guard await AuthService.shared.signOut() else {
                error = "Couldn’t finish signing out. Try deleting the profile again."
                return
            }
            activeID = nil
            persist()
        }
        let remainingAccounts = accounts.filter { $0.id != id }
        if VividCloudDeletionPolicy.canRemoveServer(account.serverID, remainingAccounts: remainingAccounts),
           ServerRegistry.shared.entry(with: account.serverID) != nil {
            guard await ServerRegistry.shared.remove(serverId: account.serverID) else {
                error = "Couldn’t remove the saved server. Try again."
                return
            }
        }
        accounts.removeAll { $0.id == id }
        modificationDates.removeValue(forKey: id)
        if unlockedID == id { unlockedID = nil }
        persist()
        VividCloudAccountSync.shared.noteDeletion(of: account)
        contentRevision = UUID()
        if activeID == nil {
            showsSelector = !accounts.isEmpty
            if accounts.isEmpty { router.resetToServerSetup() }
            else { router.resetToLogin() }
        }
        await VividCloudAccountSync.shared.synchronize(router: router)
    }

    @discardableResult
    func saveAccountOrder(_ ids: [String]) -> Bool {
        guard !busy else { return false }
        let current = accounts.map(\.id)
        let sorted = VividCloudPreferencePolicy.ordered(current, preferred: ids)
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let order = sorted.compactMap { byID[$0].map { VividCloudAccountIdentity.key(for: $0) } }
        do {
            try VividCloudPreferences.shared.setAccountOrder(order)
            applyCloudOrder(order)
            Task { await VividCloudAccountSync.shared.synchronize() }
            return true
        } catch {
            self.error = "Couldn’t save the profile order. Try again."
            return false
        }
    }

    func applyCloudOrder(_ order: [String]) {
        let identities = accounts.map { VividCloudAccountIdentity.key(for: $0) }
        let sorted = VividCloudPreferencePolicy.ordered(identities, preferred: order)
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
        var didChange = false

        for identity in vault.tombstones.keys {
            let matching = accounts.filter { VividCloudAccountIdentity.key(for: $0) == identity }
            if !matching.isEmpty { didChange = true }
            for account in matching {
                _ = keychain.delete(sessionKey(account.id))
                _ = keychain.delete(pinKey(account.id))
                modificationDates.removeValue(forKey: account.id)
                if account.id == previousActiveID { result.activeAccountDeleted = true }
                result.orphanedServerIDs.insert(account.serverID)
            }
            accounts.removeAll { VividCloudAccountIdentity.key(for: $0) == identity }
        }

        for identity in vault.accounts.keys.sorted() where vault.tombstones[identity] == nil {
            guard let envelope = vault.accounts[identity] else { continue }
            let existingIndex = accounts.firstIndex {
                VividCloudAccountIdentity.key(for: $0) == identity
            }
            let localID = existingIndex.map { accounts[$0].id } ?? envelope.account.id
            let localDate = modificationDates[localID] ?? .distantPast
            guard envelope.updatedAt > localDate || existingIndex == nil else { continue }
            didChange = true

            var imported = envelope.account
            imported = TVSavedAccount(
                id: localID,
                serverID: imported.serverID,
                userID: imported.userID,
                username: imported.username,
                profile: imported.profile,
                requiresLogin: imported.requiresLogin,
                pinEnabled: imported.pinEnabled
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
        if activeID == nil {
            activeID = accounts
                .filter { !$0.requiresLogin && session($0.id) != nil }
                .max { (modificationDates[$0.id] ?? .distantPast) < (modificationDates[$1.id] ?? .distantPast) }?
                .id
        }
        persist()
        if didChange { contentRevision = UUID() }

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
            try await AuthService.shared.restoreTVAccount(saved, serverID: account.serverID)
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
    private static let tombstoneDefaultsKey = "vivid.cloudAccountTombstones.v1"
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

    /// Only an explicit credential entry may revive an account identity that
    /// was previously deleted. Routine capture and stale-device uploads never
    /// create this marker.
    func noteExplicitAuthentication(_ account: TVSavedAccount) {
        var resurrections = loadResurrections()
        resurrections[VividCloudAccountIdentity.key(for: account)] = Date()
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
            var savedSuccessfully = false

            for _ in 0..<3 {
                let (record, existingPayload) = try await fetchRecord()
                var vault = try decodeVault(existingPayload)
                _ = try VividCloudPreferences.shared.capture(accounts: TVSavedAccountStore.shared.accounts)
                let localTombstones = loadTombstones()
                let resurrections = loadResurrections()

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
                where vault.tombstones[VividCloudAccountIdentity.key(for: account)] != nil {
                    try VividCloudPreferences.shared.removeAccountPreferences(account)
                }
                let applyResult = await TVSavedAccountStore.shared.applyCloudVault(vault)
                activeWasDeleted = activeWasDeleted || applyResult.activeAccountDeleted
                activeSessionWasInvalidated = activeSessionWasInvalidated || applyResult.activeSessionInvalidated

                for (identity, envelope) in TVSavedAccountStore.shared.cloudSnapshot()
                where vault.tombstones[identity] == nil {
                    if let existing = vault.accounts[identity], existing.updatedAt >= envelope.updatedAt {
                        continue
                    }
                    vault.accounts[identity] = envelope
                }

                vault.preferences = try VividCloudPreferences.shared.reconcile(vault.preferences ?? [:], accounts: TVSavedAccountStore.shared.accounts)
                if let data = vault.preferences?["accountOrder"]?.value,
                   let order = try? JSONDecoder().decode([String].self, from: data) {
                    TVSavedAccountStore.shared.applyCloudOrder(order)
                }
                let payload = try Self.encoder.encode(vault)
                if payload == existingPayload {
                    savedSuccessfully = true
                    break
                }
                record.encryptedValues[Self.payloadKey] = payload as NSData
                do {
                    _ = try await container.privateCloudDatabase.save(record)
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
            defaults.removeObject(forKey: Self.resurrectionDefaultsKey)
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
