import Foundation
#if os(tvOS)
import TVServices
#endif

/// The account that owns a refresh token: the server, its address and the
/// credential generation.
struct RefreshAccountIdentity: Hashable, Sendable {
    let serverId: String
    let serverURL: String
    /// Process-local epoch for the exact credential owner. It changes on
    /// sign-in, sign-out and server switches; a guarded refresh keeps it.
    let credentialGenerationID: UUID

    init(serverId: String, serverURL: String, credentialGenerationID: UUID) {
        self.serverId = serverId
        self.serverURL = serverURL
        self.credentialGenerationID = credentialGenerationID
    }
}

/// A refresh token captured with its account and owner before a refresh, so
/// the result can only replace or clear that same credential.
struct CapturedRefreshCredential: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let refreshToken: String
    let owner: CapturedHTTPRequestCredentialOwner
}

/// Every credential an ordinary request sends, read in one actor turn. The
/// profile travels with the account, so a 401 can never retry under a
/// profile chosen after the request left.
struct CapturedOrdinaryRequestAuth: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let credentialOwner: CapturedHTTPRequestCredentialOwner
    let accessToken: String?
    let profileId: String?
    let profileToken: String?
}

enum RejectedRefreshDisposition: Equatable, Sendable {
    case persistentSessionCleared
}

/// The notification payload for an expired session: which credential epoch
/// was refused, nothing secret. Receivers check it with `TokenStore` again
/// before routing.
struct SessionExpiryEvent: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let disposition: RejectedRefreshDisposition
}

/// The session's credentials.
///
/// Tokens are kept in Keychain per server (so sign-in survives a relaunch);
/// the server address and profile ID are in `SharedDefaults`, which the Top
/// Shelf extension can read too. The active server picks the Keychain slot,
/// and the slot's tokens are cached here. Each change also updates the
/// fixed-name copies notifications and diagnostics read; Top Shelf reads the
/// server's own slot.
///
/// `HTTPClient` joins concurrent 401s into one refresh. Every save and clear
/// after a refresh checks the account, owner and refresh token captured
/// before it, so a late answer can never touch a newer session.
///
/// Diagnostics lines here only ever carry a fixed phase, outcome and reason.
/// Tokens, profile IDs, server IDs (base64 of the address) and addresses are
/// never logged, not even shortened or hashed.
actor TokenStore {
    static let shared = TokenStore()

    static let accountCredentialAudience = SharedStorage.accountCredentialAudience
    static let profileCredentialAudience: KeychainAudience = .currentUser

    private let keychain: SharedKeychain
    private let defaults: SharedDefaults
    private let serverUrlDefaultsKey = SharedStorage.serverUrlKey
    private let profileIdDefaultsKey = SharedStorage.profileIdKey

    // MARK: Keychain accounts

    static func accessTokenKey(for serverId: String) -> String {
        SharedStorage.accessTokenAccount(for: serverId)
    }

    static func refreshTokenKey(for serverId: String) -> String {
        SharedStorage.refreshTokenAccount(for: serverId)
    }

    static func profileTokenKey(for serverId: String) -> String {
        SharedStorage.profileTokenAccount(for: serverId)
    }

    static func accountEpochKey(for serverId: String) -> String {
        SharedStorage.accountEpochAccount(for: serverId)
    }

    private static func nativeUserIDKey(for serverId: String) -> String {
        "vivid.nativeUserID." + serverId
    }

    // MARK: State

    /// The server whose slot is in use; empty for none, when reads return
    /// nil and saves do nothing.
    private var activeServerId = ""
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedProfileToken: String?
    /// The epoch for the active slot's credentials. A refresh keeps it; any
    /// new session or server switch replaces it.
    private var persistentCredentialGenerationID = UUID()
    /// The server the cache was read for; nil means read it again.
    private var loadedForServerId: String?
    /// Emby and Jellyfin user IDs read from Keychain, by key. Every request
    /// to those servers asks for it. Only found values are cached, and every
    /// write or delete drops the entry.
    private var nativeUserIDCache: [String: String] = [:]
    /// The values last written to the fixed-name copies, so an unchanged
    /// value (after every refresh, say) isn't written again.
    private var lastMirroredAccessToken: String?
    private var lastMirroredProfileToken: String?

    init(keychain: SharedKeychain = SharedKeychain(), defaults: SharedDefaults = .shared) {
        self.keychain = keychain
        self.defaults = defaults
    }

    private var accessTokenKey: String { Self.accessTokenKey(for: activeServerId) }
    private var refreshTokenKey: String { Self.refreshTokenKey(for: activeServerId) }
    private var profileTokenKey: String { Self.profileTokenKey(for: activeServerId) }
    private var accountEpochKey: String { Self.accountEpochKey(for: activeServerId) }
    private var accountKeychain: SharedKeychain { keychain.withAudience(Self.accountCredentialAudience) }
    private var profileKeychain: SharedKeychain { keychain.withAudience(Self.profileCredentialAudience) }

    /// A session event, kept as a breadcrumb because a refused refresh is
    /// often followed by the app being closed.
    private func recordSessionEvent(phase: String, outcome: String, reason: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Auth",
            message: "session credential event",
            attrs: [
                "phase": .string(phase),
                "outcome": .string(outcome),
                "reason": .string(reason),
            ]
        )
        #endif
    }

    // MARK: - Active server

    /// Points reads at another server's slot and loads it. Does nothing when
    /// it's already active.
    func switchActiveServer(serverId: String) {
        guard serverId != activeServerId else { return }
        retargetActiveServer(serverId: serverId)
        // A successful load updates the copies; a failed read leaves them
        // and tries again on the next access.
        ensureLoaded()
    }

    /// Points reads at another server's slot without reading Keychain, so a
    /// cold launch can choose its route before loading tokens.
    func retargetActiveServer(serverId: String) {
        guard serverId != activeServerId else { return }
        persistentCredentialGenerationID = UUID()
        activeServerId = serverId
        clearApplePushDisplayTokenIfIssued(forServerOtherThan: serverId)
        dropCachedCredentials()
        loadedForServerId = nil
    }

    /// The active server ID, or empty for none.
    func getActiveServerId() -> String { activeServerId }

    /// The account that owns refresh rotation right now. Ordinary and
    /// captured-identity requests both use it to join one refresh.
    func refreshAccountIdentity() -> RefreshAccountIdentity? {
        let serverURL = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
        guard !activeServerId.isEmpty, !serverURL.isEmpty else { return nil }
        return RefreshAccountIdentity(
            serverId: activeServerId,
            serverURL: serverURL,
            credentialGenerationID: persistentCredentialGenerationID
        )
    }

    /// The account, owner and every header value, read together. A request
    /// carries this through its 401 path, so a later switch can't redirect
    /// its refresh or mix its headers.
    func captureOrdinaryRequestAuth() -> CapturedOrdinaryRequestAuth? {
        guard let account = refreshAccountIdentity() else { return nil }
        ensureLoaded()
        return CapturedOrdinaryRequestAuth(
            account: account,
            credentialOwner: .persistentServer(serverId: account.serverId),
            accessToken: cachedAccessToken,
            profileId: defaults.string(forKey: profileIdDefaultsKey),
            profileToken: cachedProfileToken
        )
    }

    /// The refresh token and its owner, only while `expected` is still the
    /// account. The refresh answer must bring this back, so it can't affect
    /// credentials installed after a switch, sign-out or rotation.
    func captureRefreshCredential(expected: RefreshAccountIdentity) -> CapturedRefreshCredential? {
        guard refreshAccountIdentity() == expected else { return nil }
        ensureLoaded()
        guard let cachedRefreshToken, !cachedRefreshToken.isEmpty else { return nil }
        return CapturedRefreshCredential(
            account: expected,
            refreshToken: cachedRefreshToken,
            owner: .persistentServer(serverId: expected.serverId)
        )
    }

    /// The current request credentials, only while the account, owner and
    /// profile still match `expected`. The access token isn't compared, so a
    /// caller can see that a shared refresh has finished.
    func currentOrdinaryRequestAuth(matchingIdentityOf expected: CapturedOrdinaryRequestAuth) -> CapturedOrdinaryRequestAuth? {
        guard let current = captureOrdinaryRequestAuth(),
              current.account == expected.account,
              current.credentialOwner == expected.credentialOwner,
              current.profileId == expected.profileId,
              current.profileToken == expected.profileToken
        else { return nil }
        return current
    }

    /// Checks a queued request's identity against the current session and
    /// returns its credentials, for that one request only. Throws
    /// `requestIdentityChanged` when anything has moved.
    func captureRequestAuth(expected: HTTPRequestIdentity) throws -> CapturedHTTPRequestAuth {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
        guard let account = refreshAccountIdentity() else {
            // Nothing to sign with at all (no active server, or no address),
            // which is a different fault from a mismatch.
            recordSessionEvent(phase: "captureRequestAuth", outcome: "failed", reason: "noAccountIdentity")
            throw HTTPError.requestIdentityChanged
        }
        if let generation = expected.credentialGenerationID, generation != account.credentialGenerationID {
            throw HTTPError.requestIdentityChanged
        }
        let currentURL = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
        let currentProfileId = defaults.string(forKey: profileIdDefaultsKey)

        let checks = (
            hasServerId: !expected.serverId.isEmpty,
            hasServerURL: !expectedURL.isEmpty,
            hasProfileId: !expected.profileId.isEmpty,
            serverId: activeServerId == expected.serverId,
            serverURL: currentURL == expectedURL,
            accountServerId: account.serverId == expected.serverId,
            accountServerURL: account.serverURL == expectedURL,
            profile: currentProfileId == expected.profileId
        )
        guard checks.hasServerId, checks.hasServerURL, checks.hasProfileId,
              checks.serverId, checks.serverURL,
              checks.accountServerId, checks.accountServerURL,
              checks.profile
        else {
            // Which field moved is the whole value of this line: a server
            // switch and a profile switch fail the same way for the user.
            let reason = Self.requestIdentityMismatchReason(
                hasExpectedServerId: checks.hasServerId,
                hasExpectedServerURL: checks.hasServerURL,
                hasExpectedProfileId: checks.hasProfileId,
                serverIdMatches: checks.serverId,
                serverURLMatches: checks.serverURL,
                accountServerIdMatches: checks.accountServerId,
                accountServerURLMatches: checks.accountServerURL,
                profileMatches: checks.profile
            )
            recordSessionEvent(phase: "captureRequestAuth", outcome: "failed", reason: reason)
            throw HTTPError.requestIdentityChanged
        }

        ensureLoaded()
        return CapturedHTTPRequestAuth(
            account: account,
            serverURL: expectedURL,
            accessValue: cachedAccessToken,
            refreshValue: cachedRefreshToken,
            profileId: expected.profileId,
            profileValue: cachedProfileToken,
            credentialOwner: .persistentServer(serverId: expected.serverId)
        )
    }

    /// One stable reason for a `captureRequestAuth` refusal. It only takes
    /// booleans, so it can't put an identifier in a log line. Missing fields
    /// come first, since they're a caller bug rather than a mid-flight
    /// change. Tested by `TokenStoreDiagnosticsTests`; the reasons are read
    /// from field reports, so they mustn't change meaning.
    static func requestIdentityMismatchReason(
        hasExpectedServerId: Bool,
        hasExpectedServerURL: Bool,
        hasExpectedProfileId: Bool,
        serverIdMatches: Bool,
        serverURLMatches: Bool,
        accountServerIdMatches: Bool,
        accountServerURLMatches: Bool,
        profileMatches: Bool
    ) -> String {
        if !hasExpectedServerId { return "missingServerId" }
        if !hasExpectedServerURL { return "missingServerURL" }
        if !hasExpectedProfileId { return "missingProfileId" }
        if !serverIdMatches { return "serverIdChanged" }
        if !serverURLMatches { return "serverURLChanged" }
        // The registry and this store disagree: one is mid-switch or failed
        // to save.
        if !accountServerIdMatches || !accountServerURLMatches { return "accountIdentityChanged" }
        if !profileMatches { return "profileChanged" }
        return "unknown"
    }

    // MARK: - Refresh results

    /// The refresh credential a scoped request captured, rebuilt against the
    /// current generation, or nil (with the reason) when it no longer belongs
    /// to the active account.
    private func scopedRefreshCredential(
        replacing previousValue: String?,
        expected: HTTPRequestIdentity,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) -> Result<CapturedRefreshCredential, ScopedRefreshRefusal> {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
        guard credentialOwner == .persistentServer(serverId: expected.serverId),
              !expected.serverId.isEmpty,
              !expectedURL.isEmpty,
              let previousValue, !previousValue.isEmpty
        else { return .failure(.unsupportedCredentialShape) }
        guard let account = refreshAccountIdentity(),
              account.serverId == expected.serverId,
              account.serverURL == expectedURL
        else { return .failure(.accountChanged) }
        let captured = CapturedRefreshCredential(
            account: RefreshAccountIdentity(
                serverId: expected.serverId,
                serverURL: expectedURL,
                credentialGenerationID: account.credentialGenerationID
            ),
            refreshToken: previousValue,
            owner: credentialOwner
        )
        return .success(captured)
    }

    private enum ScopedRefreshRefusal: String, Error {
        case unsupportedCredentialShape
        case accountChanged
    }

    /// Saves a scoped request's refresh only while the same server account
    /// and refresh token are active. These credentials belong to the account,
    /// not a profile, so a profile switch doesn't throw away a rotation.
    func saveRefreshedTokens(
        _ accessValue: String,
        _ value: String,
        replacing previousValue: String?,
        expected: HTTPRequestIdentity,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) -> Bool {
        guard case .success(let captured) = scopedRefreshCredential(
            replacing: previousValue, expected: expected, credentialOwner: credentialOwner
        ) else { return false }
        return saveRefreshedTokens(accessValue, value, replacing: captured)
    }

    /// Saves rotated credentials only while the exact account, owner and
    /// refresh token captured before the request are still current. A
    /// discarded rotation is harmless, but shows in reports as an
    /// unexplained sign-in, so each is recorded.
    func saveRefreshedTokens(_ accessValue: String, _ value: String, replacing captured: CapturedRefreshCredential) -> Bool {
        if let refusal = refusalToReplace(captured) {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: refusal)
            return false
        }
        switch captured.owner {
        case .persistentServer(let serverId):
            cachedAccessToken = accessValue
            cachedRefreshToken = value
            recordSessionEvent(phase: "tokenRefresh", outcome: "succeeded", reason: "persistentSession")
            accountKeychain.set(accessValue, for: Self.accessTokenKey(for: serverId))
            accountKeychain.set(value, for: Self.refreshTokenKey(for: serverId))
            // Only the access token: a profile change may be part-way through.
            mirrorActiveAccessValueForExtension()
            return true
        }
    }

    /// Clears a scoped request's session after the server refused its
    /// refresh, only while the same account and refresh token are active, so
    /// a late answer never signs out a server chosen meanwhile.
    func clearTokensAfterRejectedRefresh(
        replacing previousValue: String?,
        expected: HTTPRequestIdentity,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) -> Bool {
        switch scopedRefreshCredential(replacing: previousValue, expected: expected, credentialOwner: credentialOwner) {
        case .failure(let refusal):
            recordSessionEvent(phase: "sessionInvalidation", outcome: "skipped", reason: refusal.rawValue)
            return false
        case .success(let captured):
            return invalidateRejectedRefresh(captured) == .persistentSessionCleared
        }
    }

    /// Clears exactly the session whose refresh the server refused: the one
    /// path that signs out because of the server. Every refusal to clear is
    /// recorded too, because then the app keeps credentials the server has
    /// already refused.
    func invalidateRejectedRefresh(_ captured: CapturedRefreshCredential) -> RejectedRefreshDisposition? {
        if let refusal = refusalToReplace(captured) {
            recordSessionEvent(phase: "sessionInvalidation", outcome: "skipped", reason: refusal)
            return nil
        }
        switch captured.owner {
        case .persistentServer(let serverId):
            recordSessionEvent(phase: "sessionInvalidation", outcome: "cleared", reason: "refreshRejected")
            dropCachedCredentials()
            deleteStoredCredentials(for: serverId)
            defaults.removeObject(forKey: profileIdDefaultsKey)
            clearMirroredTokensForExtension()
            requestTopShelfReload()
            return .persistentSessionCleared
        }
    }

    /// Why `captured` may no longer replace or clear the active credentials,
    /// or nil when it may. A rotated refresh token is expected when 401s
    /// join one refresh; a burst of them means the joining isn't working.
    private func refusalToReplace(_ captured: CapturedRefreshCredential) -> String? {
        guard refreshAccountIdentity() == captured.account else { return "accountChanged" }
        switch captured.owner {
        case .persistentServer(let serverId):
            guard serverId == captured.account.serverId, activeServerId == serverId else { return "credentialOwnerChanged" }
            ensureLoaded()
            guard cachedRefreshToken == captured.refreshToken else { return "refreshTokenRotated" }
            return nil
        }
    }

    /// Whether an expiry event still describes the active (cleared)
    /// credentials. Server switches cancel refreshes before installing the
    /// next session; this last check stops a late event routing that one.
    func shouldConsumeSessionExpiryEvent(_ event: SessionExpiryEvent) -> Bool {
        guard refreshAccountIdentity() == event.account else { return false }
        switch event.disposition {
        case .persistentSessionCleared:
            guard activeServerId == event.account.serverId,
                  persistentCredentialGenerationID == event.account.credentialGenerationID
            else { return false }
            ensureLoaded()
            return cachedAccessToken == nil
                && cachedRefreshToken == nil
                && cachedProfileToken == nil
                && defaults.string(forKey: profileIdDefaultsKey) == nil
        }
    }

    // MARK: - Emby and Jellyfin

    #if os(tvOS) || os(iOS)
    /// The access and refresh tokens and profile proof for a saved account,
    /// read together, while `expected` is still the account.
    func savedTVSession(expected: RefreshAccountIdentity, profile: UserProfile?) -> TVSavedAccountSession? {
        guard refreshAccountIdentity() == expected else { return nil }
        ensureLoaded()
        guard let access = cachedAccessToken,
              let refresh = cachedRefreshToken,
              profile?.id == getProfileId()
        else { return nil }
        return TVSavedAccountSession(
            accessToken: access,
            refreshToken: refresh,
            profile: profile,
            profileToken: cachedProfileToken,
            nativeUserID: nativeUserID(expected: expected)
        )
    }
    #endif

    /// Clears an Emby or Jellyfin session the server refused with a 401,
    /// while it's still exactly the captured one. These servers have no
    /// refresh token, so the empty one stands in.
    func invalidateNativeToken(_ expected: CapturedOrdinaryRequestAuth) -> SessionExpiryEvent? {
        guard MediaServerProvider.forServerID(expected.account.serverId).usesNativeUser,
              captureOrdinaryRequestAuth() == expected,
              let disposition = invalidateRejectedRefresh(CapturedRefreshCredential(
                  account: expected.account, refreshToken: "", owner: expected.credentialOwner
              ))
        else { return nil }
        return SessionExpiryEvent(account: expected.account, disposition: disposition)
    }

    /// The Emby or Jellyfin user for the active account.
    func nativeUserID(expected: RefreshAccountIdentity) -> String? {
        guard MediaServerProvider.forServerID(expected.serverId).usesNativeUser,
              refreshAccountIdentity() == expected
        else { return nil }
        return cachedNativeUserID(for: activeServerId)
    }

    private func cachedNativeUserID(for serverId: String) -> String? {
        let key = Self.nativeUserIDKey(for: serverId)
        if let cached = nativeUserIDCache[key] { return cached }
        let value = accountKeychain.get(key)
        if let value { nativeUserIDCache[key] = value }
        return value
    }

    private func storeNativeUserID(_ value: String?, for serverId: String) {
        let key = Self.nativeUserIDKey(for: serverId)
        nativeUserIDCache.removeValue(forKey: key)
        if let value {
            accountKeychain.set(value, for: key)
        } else {
            accountKeychain.delete(key)
        }
    }

    // MARK: - Tokens

    func getAccessToken() -> String? {
        ensureLoaded()
        return cachedAccessToken
    }

    func getRefreshToken() -> String? {
        ensureLoaded()
        return cachedRefreshToken
    }

    /// A launch check for a stored access token that reads only that slot;
    /// the rest loads with the first request.
    func hasAccessTokenForActiveServer(serverId: String) throws -> Bool {
        retargetActiveServer(serverId: serverId)
        if loadedForServerId == activeServerId { return cachedAccessToken != nil }
        cachedAccessToken = try accountKeychain.getChecked(Self.accessTokenKey(for: serverId))
        return cachedAccessToken != nil
    }

    /// Installs a new session for the active server, with a new epoch.
    func saveTokens(accessToken: String, refreshToken: String, nativeUserID: String? = nil) {
        guard !activeServerId.isEmpty else { return }
        ensureLoaded()
        persistentCredentialGenerationID = UUID()
        cachedAccessToken = accessToken
        cachedRefreshToken = refreshToken
        if MediaServerProvider.forServerID(activeServerId).usesNativeUser {
            storeNativeUserID(nativeUserID, for: activeServerId)
        }
        accountKeychain.set(accessToken, for: accessTokenKey)
        accountKeychain.set(refreshToken, for: refreshTokenKey)
        accountKeychain.set(UUID().uuidString, for: accountEpochKey)
        mirrorActiveTokensForExtension()
    }

    /// Signs out of the active server only, on purpose (unlike
    /// `invalidateRejectedRefresh`, which the server causes; the two record
    /// different phases). Other servers' tokens and the registry entry stay.
    func clearTokens() {
        ensureLoaded()
        persistentCredentialGenerationID = UUID()
        dropCachedCredentials()
        guard !activeServerId.isEmpty else {
            recordSessionEvent(phase: "clearTokens", outcome: "cleared", reason: "noActiveServer")
            return
        }
        recordSessionEvent(phase: "clearTokens", outcome: "cleared", reason: "persistentSession")
        deleteStoredCredentials(for: activeServerId)
        defaults.removeObject(forKey: profileIdDefaultsKey)
        clearMirroredTokensForExtension()
        requestTopShelfReload()
    }

    /// Deletes any server's stored credentials, for removing a server or
    /// signing out of one that isn't active.
    func deleteTokens(for serverId: String) {
        guard !serverId.isEmpty else { return }
        deleteStoredCredentials(for: serverId)
        guard serverId == activeServerId else { return }
        persistentCredentialGenerationID = UUID()
        dropCachedCredentials()
        loadedForServerId = nil
        clearMirroredTokensForExtension()
    }

    /// Removes a server's tokens, Emby or Jellyfin user, epoch and profile
    /// proof from Keychain.
    private func deleteStoredCredentials(for serverId: String) {
        accountKeychain.delete(Self.accessTokenKey(for: serverId))
        accountKeychain.delete(Self.refreshTokenKey(for: serverId))
        if MediaServerProvider.forServerID(serverId).usesNativeUser { storeNativeUserID(nil, for: serverId) }
        accountKeychain.delete(Self.accountEpochKey(for: serverId))
        profileKeychain.delete(Self.profileTokenKey(for: serverId))
    }

    private func dropCachedCredentials() {
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
    }

    // MARK: - Profile

    func getProfileId() -> String? {
        defaults.string(forKey: profileIdDefaultsKey)
    }

    func setProfileId(_ profileId: String?) {
        let changed = defaults.string(forKey: profileIdDefaultsKey) != profileId
        defaults.set(profileId, forKey: profileIdDefaultsKey)
        if changed { requestTopShelfReload() }
    }

    func getProfileToken() -> String? {
        ensureLoaded()
        return cachedProfileToken
    }

    @discardableResult
    func setProfileToken(_ token: String?) -> Bool {
        guard !activeServerId.isEmpty else { return false }
        ensureLoaded()
        guard storeProfileToken(token) else { return false }
        mirrorActiveTokensForExtension()
        return true
    }

    /// Saves (or deletes) the active server's profile proof, and caches it
    /// once Keychain has it.
    private func storeProfileToken(_ token: String?) -> Bool {
        let saved = if let token {
            profileKeychain.set(token, for: profileTokenKey)
        } else {
            profileKeychain.delete(profileTokenKey)
        }
        if saved { cachedProfileToken = token }
        return saved
    }

    func getOrCreateAccountEpoch() -> String? {
        getOrCreateAccountEpoch(for: activeServerId)
    }

    /// The server's account epoch, made now for a signed-in server that has
    /// none. Nil for a signed-out server.
    func getOrCreateAccountEpoch(for serverID: String) -> String? {
        guard !serverID.isEmpty else { return nil }
        let epochKey = Self.accountEpochKey(for: serverID)
        if let existing = accountKeychain.get(epochKey), !existing.isEmpty { return existing }
        guard accountKeychain.get(Self.accessTokenKey(for: serverID)) != nil else { return nil }
        let epoch = UUID().uuidString
        guard accountKeychain.set(epoch, for: epochKey) else { return nil }
        return epoch
    }

    func hasStoredProfileToken(for serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        if serverID == activeServerId {
            ensureLoaded()
            return cachedProfileToken != nil
        }
        return profileKeychain.get(Self.profileTokenKey(for: serverID)) != nil
    }

    /// Commits a profile ID and its proof together, once the caller has
    /// paused requests.
    func activateProfile(profileID: String, profileToken: String?, expectedAccount: RefreshAccountIdentity) -> Bool {
        guard refreshAccountIdentity() == expectedAccount, !profileID.isEmpty else { return false }
        ensureLoaded()
        guard storeProfileToken(profileToken) else { return false }
        // A leftover push display token belonged to the previous profile, so
        // it goes before the new profile ID is visible.
        let profileChanged = defaults.string(forKey: profileIdDefaultsKey) != profileID
        if profileChanged { clearApplePushDisplayToken() }
        defaults.set(profileID, forKey: profileIdDefaultsKey)
        mirrorActiveTokensForExtension()
        if profileChanged { requestTopShelfReload() }
        return true
    }

    /// Clears the profile and its proof together. The account session stays,
    /// so the profile picker can load the household's profiles without
    /// another sign-in.
    func deactivateProfile(expectedAccount: RefreshAccountIdentity?, expectedProfileID: String? = nil) -> Bool {
        if let expectedAccount, refreshAccountIdentity() != expectedAccount { return false }
        if let expectedProfileID, defaults.string(forKey: profileIdDefaultsKey) != expectedProfileID { return false }
        ensureLoaded()
        if !activeServerId.isEmpty, !profileKeychain.delete(profileTokenKey) { return false }
        defaults.removeObject(forKey: profileIdDefaultsKey)
        cachedProfileToken = nil
        clearApplePushDisplayToken()
        mirrorActiveTokensForExtension()
        requestTopShelfReload()
        return true
    }

    // MARK: - Server address

    func getServerUrl() -> String {
        defaults.string(forKey: serverUrlDefaultsKey) ?? ""
    }

    func setServerUrl(_ url: String) {
        defaults.set(ServerRegistry.normalize(url: url), forKey: serverUrlDefaultsKey)
    }

    // MARK: - Loading and copies

    /// Reads the active slot into the cache once. A read that fails leaves
    /// the cache unloaded, so a temporarily locked Keychain recovers.
    @discardableResult
    private func ensureLoaded() -> Bool {
        guard loadedForServerId != activeServerId else { return true }
        if activeServerId.isEmpty {
            dropCachedCredentials()
        } else {
            do {
                let access = try accountKeychain.getChecked(accessTokenKey)
                let refresh = try accountKeychain.getChecked(refreshTokenKey)
                let profile = try profileKeychain.getChecked(profileTokenKey)
                cachedAccessToken = access
                cachedRefreshToken = refresh
                cachedProfileToken = profile
            } catch {
                return false
            }
        }
        loadedForServerId = activeServerId
        mirrorActiveTokensForExtension()
        return true
    }

    /// Top Shelf shows the active profile's rows, so tvOS is asked to reload
    /// it when the profile changes or the session is cleared.
    private func requestTopShelfReload() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    /// Updates the fixed-name access and profile token copies that
    /// notifications and diagnostics read, once the cache is loaded.
    private func mirrorActiveTokensForExtension() {
        guard loadedForServerId == activeServerId else { return }
        mirrorActiveAccessValueForExtension()
        guard cachedProfileToken != lastMirroredProfileToken else { return }
        if let cachedProfileToken {
            profileKeychain.set(cachedProfileToken, for: SharedStorage.mirroredProfileTokenAccount)
        } else {
            profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
        }
        lastMirroredProfileToken = cachedProfileToken
    }

    private func mirrorActiveAccessValueForExtension() {
        guard cachedAccessToken != lastMirroredAccessToken else { return }
        if let cachedAccessToken {
            accountKeychain.set(cachedAccessToken, for: SharedStorage.mirroredAccessTokenAccount)
        } else {
            accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
        }
        lastMirroredAccessToken = cachedAccessToken
    }

    private func clearMirroredTokensForExtension() {
        accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
        profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
        clearApplePushDisplayToken()
        lastMirroredAccessToken = nil
        lastMirroredProfileToken = nil
    }

    /// Removes a push display token left by the push registration earlier
    /// builds shipped. Vivid no longer registers for push, so this only
    /// clears leftovers. The details go only once the token itself has, so a
    /// failed delete can't make it look freshly issued.
    private func clearApplePushDisplayToken() {
        guard profileKeychain.delete(SharedStorage.applePushDisplayTokenAccount) else { return }
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenServerIdKey)
    }

    /// A switch, but not a cold launch picking up the saved server, clears a
    /// leftover display token, so this compares with the server the token was
    /// issued for. A token with no server recorded is older than that key and
    /// is cleared to be safe.
    private func clearApplePushDisplayTokenIfIssued(forServerOtherThan serverId: String) {
        guard profileKeychain.get(SharedStorage.applePushDisplayTokenAccount) != nil else { return }
        let issuedFor = defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey) ?? ""
        if issuedFor.isEmpty || issuedFor != serverId {
            clearApplePushDisplayToken()
        }
    }
}
