import Foundation

/// Server checks, sign-in, session installation, viewing profiles and
/// sign-out. Every change to the request identity holds the HTTP client's
/// identity transition for its whole length and releases it on every exit.
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()

    enum SignOutAuthorization: Equatable, Sendable {
        case allowed(account: RefreshAccountIdentity?)
        case refused
    }

    private let identityResolver: ServerIdentityResolver
    private let registry: ServerRegistry
    private let launchPreferences: ProfileLaunchPreferences

    init(
        serverIdentityResolver: ServerIdentityResolver = ServerIdentityResolver(),
        serverRegistry: ServerRegistry = .shared,
        launchPreferences: ProfileLaunchPreferences = .shared
    ) {
        self.identityResolver = serverIdentityResolver
        self.registry = serverRegistry
        self.launchPreferences = launchPreferences
    }

    // MARK: State

    var serverUrl: String { ServerRegistry.shared.activeServerUrl }

    /// Read fresh on every access, so it is safe from any thread.
    var profileId: String? { SharedDefaults.shared.string(forKey: SharedStorage.profileIdKey) }

    var hasServer: Bool { ServerRegistry.shared.hasActiveServer }

    var isLoggedIn: Bool {
        guard let serverID = ServerRegistry.shared.activeServerId, !serverID.isEmpty else { return false }
        let keychain = SharedKeychain(audience: SharedStorage.accountCredentialAudience)
        return keychain.get(TokenStore.accessTokenKey(for: serverID)) != nil
    }

    var hasProfile: Bool { profileId != nil }

    // MARK: Servers

    /// Finds the server at `address` without saving, switching or caching
    /// anything.
    func locateServer(at address: String, provider: MediaServerProvider) async throws -> ServerProbe {
        let url = ServerRegistry.normalize(url: address)
        let registryID = ServerRegistry.serverId(for: url)
        switch provider {
        case .jellyfin:
            let name = try await JellyfinConnection.probe(serverURL: url)
            try Task.checkCancellation()
            return ServerProbe(provider: .jellyfin, url: url, id: "jellyfin:" + registryID, fetchedName: name, needsSetup: false)
        case .emby:
            let name = try await EmbyConnection.probe(serverURL: url)
            try Task.checkCancellation()
            return ServerProbe(provider: .emby, url: url, id: "emby:" + registryID, fetchedName: name, needsSetup: false)
        case .silo:
            let name = await identityResolver.fetchServerName(serverURL: url)
            try Task.checkCancellation()
            let status: SetupStatus = try await HTTPClient.shared.getUnauthenticated(serverURL: url, path: "/api/v1/auth/setup")
            try Task.checkCancellation()
            return ServerProbe(provider: .silo, url: url, id: registryID, fetchedName: name, needsSetup: status.needsSetup)
        }
    }

    /// Finds the server, saves it and makes it the active one.
    func checkServer(url: String, provider: MediaServerProvider = .silo) async throws -> SetupStatus {
        let server = try await locateServer(at: url, provider: provider)
        let entry = ServerEntry(id: server.id, url: server.url, fetchedName: server.fetchedName, lastUsedAt: Date())
        guard registry.addOrUpdate(entry) != nil else { throw ServerRegistryError.persistenceFailed }
        if provider != .silo || registry.activeServerId != server.id {
            guard await registry.switchTo(serverId: server.id) else { throw ServerRegistryError.persistenceFailed }
        }
        return SetupStatus(needsSetup: server.needsSetup)
    }

    /// Renames the active Silo server, unless another server became active
    /// while the name was on its way.
    func refreshActiveServerName() async {
        guard let serverID = registry.activeServerId, let server = registry.activeServer,
              MediaServerProvider.forServerID(serverID) == .silo else { return }
        let name = await identityResolver.fetchServerName(serverURL: server.url)
        guard let name, registry.activeServerId == serverID else { return }
        registry.updateFetchedName(for: serverID, fetchedName: name)
    }

    // MARK: Sign-in

    func login(username: String, password: String, defersSiloSignInRecord: Bool = false) async throws {
        guard let account = await TokenStore.shared.refreshAccountIdentity() else { throw HTTPError.serverUrlNotConfigured }
        switch MediaServerProvider.forServerID(account.serverId) {
        case .jellyfin:
            let session = try await JellyfinConnection.login(serverURL: account.serverURL, username: username, password: password)
            try await installNativeSession(token: session.token, userID: session.userID,
                                           accountID: JellyfinAdapter.numberID(session.userID), for: account)
        case .emby:
            let session = try await EmbyConnection.login(serverURL: account.serverURL, username: username, password: password)
            try await installNativeSession(token: session.token, userID: session.userID,
                                           accountID: EmbyAdapter.numberID(session.userID), for: account)
        case .silo:
            let reply: LoginResponse = try await HTTPClient.shared.post(
                "/api/v1/auth/login", body: LoginRequest(username: username, password: password)
            )
            let userID = String(reply.user.id)
            try await installSession(accessToken: reply.accessToken, refreshToken: reply.refreshToken,
                                     for: account, nativeUserID: nil, cacheAccountID: userID)
            if !defersSiloSignInRecord { await noteSignIn(serverID: account.serverId, userID: userID) }
        }
    }

    /// Installs a Quick Connect session approved for `serverURL`, which must
    /// still be the active Jellyfin server.
    func installQuickConnectSession(_ login: JellyfinLogin, approvedAt serverURL: String) async throws {
        let account = try await accountApproving(.jellyfin, at: serverURL)
        try await installNativeSession(token: login.token, userID: login.userID,
                                       accountID: JellyfinAdapter.numberID(login.userID), for: account)
    }

    /// Installs an Emby Connect session approved for `serverURL`, which must
    /// still be the active Emby server.
    func installEmbyConnectSession(_ login: EmbyLogin, approvedAt serverURL: String) async throws {
        let account = try await accountApproving(.emby, at: serverURL)
        try await installNativeSession(token: login.token, userID: login.userID,
                                       accountID: EmbyAdapter.numberID(login.userID), for: account)
    }

    private func accountApproving(_ provider: MediaServerProvider, at serverURL: String) async throws -> RefreshAccountIdentity {
        guard let account = await TokenStore.shared.refreshAccountIdentity() else { throw HTTPError.serverUrlNotConfigured }
        guard MediaServerProvider.forServerID(account.serverId) == provider,
              account.serverURL == ServerRegistry.normalize(url: serverURL) else { throw HTTPError.requestIdentityChanged }
        return account
    }

    private func installNativeSession(token: String, userID: String, accountID: Int, for account: RefreshAccountIdentity) async throws {
        let cacheAccountID = String(accountID)
        try await installSession(accessToken: token, refreshToken: "", for: account,
                                 nativeUserID: userID, cacheAccountID: cacheAccountID)
        await noteSignIn(serverID: account.serverId, userID: cacheAccountID)
    }

    private func noteSignIn(serverID: String, userID: String) async {
        #if os(iOS) || os(tvOS)
        await VividCloudAccountSync.shared.noteExplicitAuthentication(serverID: serverID, userID: userID)
        #endif
    }

    /// Replaces the active server's tokens with a new session that has no
    /// profile yet. Refused when the account changed since `account` was read.
    private func installSession(
        accessToken: String, refreshToken: String, for account: RefreshAccountIdentity,
        nativeUserID: String?, cacheAccountID: String?
    ) async throws {
        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { throw CancellationError() }
        guard !Task.isCancelled else {
            await client.endIdentityTransition(lease)
            throw CancellationError()
        }
        await client.cancelInFlightRequests()
        guard !Task.isCancelled else {
            await client.endIdentityTransition(lease)
            throw CancellationError()
        }
        guard await TokenStore.shared.refreshAccountIdentity() == account else {
            await client.endIdentityTransition(lease)
            throw HTTPError.requestIdentityChanged
        }
        if let serverID = registry.activeServerId { launchPreferences.clearRememberedProfile(for: serverID) }
        await TokenStore.shared.clearTokens()
        await TokenStore.shared.saveTokens(accessToken: accessToken, refreshToken: refreshToken, nativeUserID: nativeUserID)
        VividCacheScope.recordAccount(cacheAccountID, serverID: account.serverId)
        await clearCachesForServerChange()
        await client.endIdentityTransition(lease)
    }

    #if os(iOS) || os(tvOS)
    /// Switches to a saved account's server and session, and to its profile
    /// when that can be entered without asking for a PIN.
    @MainActor
    func restoreTVAccount(_ session: TVSavedAccountSession, serverID: String, accountID: String) async throws {
        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { throw CancellationError() }
        await client.cancelInFlightRequests()
        clearCachesForServerChange()
        await PosterImageCache.resetForAccountSwitch()
        guard await registry.commitSwitchTo(serverId: serverID, holding: lease) else {
            await client.endIdentityTransition(lease)
            throw ServerRegistryError.persistenceFailed
        }
        let tokens = TokenStore.shared
        VividCacheScope.recordAccount(accountID, serverID: serverID)
        launchPreferences.clearRememberedProfile(for: serverID)
        await tokens.clearTokens()
        await tokens.saveTokens(accessToken: session.accessToken, refreshToken: session.refreshToken,
                                nativeUserID: session.nativeUserID)
        if let profile = session.profile, !profile.hasPin || session.profileToken != nil,
           let account = await tokens.refreshAccountIdentity(),
           let epoch = await tokens.getOrCreateAccountEpoch(),
           await tokens.activateProfile(profileID: profile.id, profileToken: session.profileToken, expectedAccount: account) {
            launchPreferences.remember(profileID: profile.id, requiresPIN: profile.hasPin, accountEpoch: epoch, for: serverID)
        }
        clearCachesForServerChange()
        await client.endIdentityTransition(lease)
    }
    #endif

    // MARK: Profiles

    func getProfiles() async throws -> [UserProfile] {
        #if os(tvOS)
        let requestIdentity = await TokenStore.shared.refreshAccountIdentity()
        let profiles = try await VividAPI.shared.listProfiles()
        await TopShelfProfileCounts.record(profiles.count, for: requestIdentity)
        return profiles
        #else
        return try await VividAPI.shared.listProfiles()
        #endif
    }

    func selectProfile(profileId: String, pin: String? = nil, requiresPIN: Bool = false, rememberSelection: Bool = true) async throws {
        let tokens = TokenStore.shared
        guard let account = await tokens.refreshAccountIdentity() else { throw ProfileTransitionError.noActiveAccount }
        let proof = try await VividAPI.shared.verifyProfileSelection(profileId: profileId, pin: pin)
        if requiresPIN, proof == nil { throw ProfileTransitionError.missingPINProof }
        guard let serverID = registry.activeServerId else { throw ProfileTransitionError.noActiveServer }
        guard let epoch = await tokens.getOrCreateAccountEpoch() else { throw ProfileTransitionError.accountEpochUnavailable }

        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { throw CancellationError() }
        await client.cancelInFlightRequests()
        var activated = false
        if !Task.isCancelled {
            activated = await tokens.activateProfile(profileID: profileId, profileToken: proof, expectedAccount: account)
        }
        guard activated else {
            await client.endIdentityTransition(lease)
            if Task.isCancelled { throw CancellationError() }
            throw ProfileTransitionError.identityChanged
        }
        if rememberSelection,
           !launchPreferences.remember(profileID: profileId, requiresPIN: requiresPIN, accountEpoch: epoch, for: serverID) {
            _ = await tokens.deactivateProfile(expectedAccount: account, expectedProfileID: profileId)
            await client.endIdentityTransition(lease)
            throw ProfileTransitionError.accountEpochUnavailable
        }
        await clearProfileCaches(keepingTrailerReturn: true)
        await client.endIdentityTransition(lease)

        Task { @MainActor in
            await AICapabilities.shared.refresh()
            await ImageSizeCapability.shared.refresh()
            await RequestsFeatureStore.shared.refresh()
            await CurrentProfileStore.shared.refresh(force: true)
        }
    }

    /// Enters the remembered profile at launch. True when a profile is now
    /// active, false when one has to be chosen.
    func resolveActiveProfileForSession() async -> Bool {
        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { return false }
        await client.cancelInFlightRequests()
        let resolved = await resolveActiveProfileForSession(holding: lease)
        await client.endIdentityTransition(lease)
        return resolved
    }

    /// The same, for a caller that already holds the identity transition.
    func resolveActiveProfileForSession(holding transitionLease: HTTPIdentityTransitionLease) async -> Bool {
        let tokens = TokenStore.shared
        guard await HTTPClient.shared.isIdentityTransitionActive(transitionLease),
              let serverID = registry.activeServerId,
              let account = await tokens.refreshAccountIdentity(),
              let epoch = await tokens.getOrCreateAccountEpoch() else { return false }

        let proof = await tokens.getProfileToken()
        let knownIDs: Set<String>? = await MainActor.run {
            ResponseCache.shared.get(CacheKey.profiles, as: [UserProfile].self).map { Set($0.map(\.id)) }
        }
        let decision = launchPreferences.resolution(
            for: serverID, accountEpoch: epoch, hasStoredProfileToken: proof != nil, knownProfileIDs: knownIDs
        )
        switch decision {
        case .needsSelection:
            if let remembered = launchPreferences.rememberedProfile(for: serverID),
               let knownIDs, !knownIDs.contains(remembered.profileID) {
                launchPreferences.clearRememberedProfile(for: serverID)
            }
            if await tokens.deactivateProfile(expectedAccount: account) {
                await clearProfileCaches(keepingTrailerReturn: true)
            }
            return false
        case .restore(let remembered):
            let activated = await tokens.activateProfile(
                profileID: remembered.profileID,
                profileToken: remembered.requiredPINAtSelection ? proof : nil,
                expectedAccount: account
            )
            guard activated else {
                _ = await tokens.deactivateProfile(expectedAccount: account)
                return false
            }
            guard launchPreferences.clearBackgroundedAt() else {
                _ = await tokens.deactivateProfile(expectedAccount: account, expectedProfileID: remembered.profileID)
                await clearProfileCaches(keepingTrailerReturn: false)
                return false
            }
            await clearProfileCaches(keepingTrailerReturn: true)
            return true
        }
    }

    /// Leaves the profile so another can be chosen, keeping the account.
    func beginExplicitProfileSelection() async -> Bool {
        await deactivateProfile(preserveRememberedProfile: true, markSelectionRequired: true)
    }

    func deactivateProfile(preserveRememberedProfile: Bool, markSelectionRequired: Bool = false, expectedProfileID: String? = nil) async -> Bool {
        if let expectedProfileID, expectedProfileID != profileId { return false }

        // The intent is saved before waiting for the transition, so it
        // survives Vivid being closed partway through.
        let serverID = registry.activeServerId
        let account = await TokenStore.shared.refreshAccountIdentity()
        let keptProfile = preserveRememberedProfile ? nil : launchPreferences.rememberedProfile(for: serverID)
        if markSelectionRequired, let serverID, !launchPreferences.markSelectionRequired(for: serverID) { return false }
        if !preserveRememberedProfile, let serverID { launchPreferences.clearRememberedProfile(for: serverID) }

        func undo() {
            if markSelectionRequired, let serverID { launchPreferences.clearSelectionRequired(for: serverID) }
            if let keptProfile, let serverID {
                launchPreferences.remember(profileID: keptProfile.profileID, requiresPIN: keptProfile.requiredPINAtSelection,
                                           accountEpoch: keptProfile.accountEpoch, for: serverID)
            }
        }

        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else {
            undo()
            return false
        }
        await client.cancelInFlightRequests()
        guard await TokenStore.shared.deactivateProfile(expectedAccount: account, expectedProfileID: expectedProfileID) else {
            undo()
            await client.endIdentityTransition(lease)
            return false
        }
        await clearProfileCaches(keepingTrailerReturn: false)
        await client.endIdentityTransition(lease)
        return true
    }

    /// Leaves the current profile when it is no longer in the account's list.
    func reconcileAvailableProfiles(_ profiles: [UserProfile]) async {
        guard let current = profileId, !profiles.contains(where: { $0.id == current }) else { return }
        await recoverFromInvalidProfile(expectedProfileID: current)
    }

    /// Leaves a profile the server no longer accepts and asks for another.
    func recoverFromInvalidProfile(expectedProfileID: String) async {
        guard profileId == expectedProfileID else { return }
        let serverID = registry.activeServerId
        let account = await TokenStore.shared.refreshAccountIdentity()
        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { return }
        await client.cancelInFlightRequests()
        let left = await TokenStore.shared.deactivateProfile(expectedAccount: account, expectedProfileID: expectedProfileID)
        if left {
            if let serverID { launchPreferences.clearRememberedProfile(for: serverID) }
            await clearProfileCaches(keepingTrailerReturn: false)
        }
        await client.endIdentityTransition(lease)
        guard left else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .vividProfileSelectionRequired, object: expectedProfileID)
        }
    }

    // MARK: Device sign-in

    /// A second Silo session for this device, approved by the active one.
    func approvedSiloSession() async throws -> (accessToken: String, refreshToken: String) {
        let client = HTTPClient.shared
        let device = AppleDeviceIdentity.current
        let start: DeviceLoginStartResponse = try await client.post(
            "/api/v1/auth/device/start",
            body: DeviceLoginStartRequest(deviceName: device.name, devicePlatform: device.platform)
        )
        try await client.postVoid("/api/v1/auth/device/approve", body: DeviceLoginDecisionRequest(code: start.userCode))
        for _ in 1...5 {
            let poll: DeviceLoginPollResponse = try await client.post(
                "/api/v1/auth/device/poll", body: DeviceLoginPollRequest(deviceCode: start.deviceCode)
            )
            switch DeviceLoginStatus(raw: poll.status) {
            case .approved:
                guard let accessToken = poll.accessToken, let refreshToken = poll.refreshToken else { throw HTTPError.invalidResponse }
                return (accessToken, refreshToken)
            case .pending:
                try await Task.sleep(for: .seconds(max(1, poll.pollAfter ?? 1)))
            default:
                throw HTTPError.invalidResponse
            }
        }
        throw HTTPError.invalidResponse
    }

    // MARK: Sign-out

    static func signOutAuthorization(activeServerId: String?, capturedAuth: CapturedOrdinaryRequestAuth?) -> SignOutAuthorization {
        guard let activeServerId, !activeServerId.isEmpty else { return .allowed(account: capturedAuth?.account) }
        guard let capturedAuth else { return .allowed(account: nil) }
        guard capturedAuth.credentialOwner == .persistentServer(serverId: activeServerId),
              capturedAuth.account.serverId == activeServerId else { return .refused }
        return .allowed(account: capturedAuth.account)
    }

    @discardableResult
    func signOut() async -> Bool {
        let shared = ServerRegistry.shared
        let serverID = shared.activeServerId
        let captured = await TokenStore.shared.captureOrdinaryRequestAuth()
        guard case .allowed(let account) = Self.signOutAuthorization(activeServerId: serverID, capturedAuth: captured) else { return false }
        if let account {
            try? await HTTPClient.shared.postVoid("/api/v1/auth/logout", expectedAccount: account)
        }

        let client = HTTPClient.shared
        guard let lease = await client.beginIdentityTransition() else { return false }
        guard !Task.isCancelled else {
            await client.endIdentityTransition(lease)
            return false
        }
        await client.cancelInFlightRequests()
        guard !Task.isCancelled, shared.activeServerId == serverID,
              await TokenStore.shared.refreshAccountIdentity() == account else {
            await client.endIdentityTransition(lease)
            return false
        }
        if let serverID {
            await shared.signOut(serverId: serverID)
        } else {
            await TokenStore.shared.clearTokens()
        }
        await clearCachesForServerChange()
        await client.endIdentityTransition(lease)
        return true
    }

    // MARK: Cache boundaries

    /// Everything cached for the previous server, account or profile.
    @MainActor
    func clearCachesForServerChange() {
        StartupContentPrefetcher.resetAllPrefetches()
        ResponseCache.shared.clearAll()
        resetPreferenceStores()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        TVTrailerReturnStore.shared.clear()
        #endif
    }

    /// Everything cached for the previous profile. The account's profile
    /// list stays.
    @MainActor
    private func clearProfileCaches(keepingTrailerReturn: Bool) {
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        for prefix in CacheKey.perProfilePrefixes {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
        resetPreferenceStores()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        if !keepingTrailerReturn { TVTrailerReturnStore.shared.clear() }
        #endif
    }

    @MainActor
    private func resetPreferenceStores() {
        OverlayPrefsStore.shared.clear()
        ProfilePrefsStore.shared.clear()
        AICapabilities.shared.reset()
        ImageSizeCapability.shared.reset()
        RequestsFeatureStore.shared.reset()
        CurrentProfileStore.shared.reset()
        RequestsEventBus.shared.reset()
    }
}
