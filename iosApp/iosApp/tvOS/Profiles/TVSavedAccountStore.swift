#if os(tvOS) || os(iOS)
import Foundation
import CryptoKit

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

    init() {
        if let data = defaults.data(forKey: listKey), let values = try? JSONDecoder().decode([TVSavedAccount].self, from: data) {
            accounts = values
        }
        activeID = defaults.string(forKey: activeKey)
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
        defaults.set(activeID, forKey: activeKey)
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
        persist()
        return true
    }
    func removePIN(_ id: String) -> Bool {
        guard activeID == id, !showsSelector, AuthService.shared.isLoggedIn else { return false }
        guard keychain.delete(pinKey(id)) else { return false }
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].pinEnabled = false }
        persist()
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
            persist()
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
        guard id != nil || canAddAccount else { error = "You can save up to three profiles. Delete a signed-out profile to add another."; return false }
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
            persist()
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
    }
    #if os(iOS)
    func deleteSignedOutAccount(_ id: String, router: AppRouter) async {
        guard !busy, let account = accounts.first(where: { $0.id == id }),
              account.requiresLogin, activeID != id else { return }
        busy = true
        error = nil
        defer { busy = false }
        guard keychain.delete(sessionKey(id)), keychain.delete(pinKey(id)) else {
            error = "Couldn’t delete the saved profile. Try again."
            return
        }
        let serverIsShared = accounts.contains { $0.id != id && $0.serverID == account.serverID }
        if !serverIsShared, ServerRegistry.shared.entry(with: account.serverID) != nil {
            guard await ServerRegistry.shared.remove(serverId: account.serverID) else {
                error = "Couldn’t remove the saved server. Try again."
                return
            }
        }
        accounts.removeAll { $0.id == id }
        if unlockedID == id { unlockedID = nil }
        persist()
        contentRevision = UUID()
        if activeID == nil {
            showsSelector = !accounts.isEmpty
            if accounts.isEmpty { router.resetToServerSetup() }
            else { router.resetToLogin() }
        }
    }
    #endif

}
#endif
