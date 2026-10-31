import Security
import XCTest
@testable import Vivid

/// A throwaway App Group suite wrapped the way the stores use it.
private struct ThrowawaySuite {
    let name: String
    let suite: UserDefaults
    let defaults: SharedDefaults

    init(prefix: String) throws {
        name = prefix + "." + UUID().uuidString
        suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults = SharedDefaults(suite: suite, standard: suite)
    }

    func remove() {
        suite.removePersistentDomain(forName: name)
    }
}

/// When launch restores the remembered profile and when it asks who's
/// watching, and when the Top Shelf may show one viewer's rows.
final class ProfileLaunchPolicyTests: XCTestCase {
    private let serverID = "server-a"
    private let accountEpoch = "account-a"
    private let pinFreeProfile = RememberedProfile(profileID: "profile-a", requiredPINAtSelection: false, accountEpoch: "account-a")
    private let pinProtectedProfile = RememberedProfile(profileID: "profile-a", requiredPINAtSelection: true, accountEpoch: "account-a")

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    func testCloudAccountIdentityIsStableAcrossDeviceLocalAccountIDs() {
        let key = VividCloudAccountIdentity.key(serverID: "server-a", userID: "user-a")
        XCTAssertEqual(key, VividCloudAccountIdentity.key(serverID: "server-a", userID: "user-a"))
        XCTAssertNotEqual(key, VividCloudAccountIdentity.key(serverID: "server-b", userID: "user-a"))
        XCTAssertNotEqual(key, VividCloudAccountIdentity.key(serverID: "server-a", userID: "user-b"))
    }

    func testCloudDeletionTombstoneCannotBeOverriddenByStaleDeviceState() {
        let deletedAt = date(2_000)
        XCTAssertTrue(VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: nil))
        XCTAssertTrue(VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: date(1_999)))
        XCTAssertFalse(VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: date(2_001)))
    }

    @MainActor
    func testSignInRecordedDuringSyncSurvivesForTheNextSync() {
        let deletedAt = date(2_000)
        let uploaded = deletedAt.addingTimeInterval(-60)
        let readded = deletedAt.addingTimeInterval(60)
        let synced = ["kept": uploaded, "updated": uploaded]
        let current = ["kept": uploaded, "updated": readded, "new": readded]
        XCTAssertEqual(VividCloudAccountSync.resurrections(current, afterUploading: synced), ["updated": readded, "new": readded])
        XCTAssertTrue(VividCloudAccountSync.resurrections(synced, afterUploading: synced).isEmpty)
        XCTAssertFalse(VividCloudDeletionPolicy.tombstoneWins(deletedAt: deletedAt, explicitAuthenticationAt: readded))
    }

    func testProfileDeletionPreservesServersUsedByOtherSavedAccounts() {
        let account = TVSavedAccount(
            id: "other", serverID: "shared-server", userID: "other-user", username: "Other", profile: nil, requiresLogin: false)
        XCTAssertFalse(VividCloudDeletionPolicy.canRemoveServer("shared-server", remainingAccounts: [account]))
        var signedOut = account
        signedOut.requiresLogin = true
        XCTAssertFalse(VividCloudDeletionPolicy.canRemoveServer("shared-server", remainingAccounts: [signedOut]))
        XCTAssertTrue(VividCloudDeletionPolicy.canRemoveServer("deleted-server", remainingAccounts: [account]))
        XCTAssertTrue(VividCloudDeletionPolicy.canRemoveServer("shared-server", remainingAccounts: []))
    }

    func testProfileSelectionPoliciesKeepStableOrderAndLegacyEveryTimeRawValue() {
        XCTAssertEqual(ProfileLaunchBehavior.askEveryLaunch.rawValue, "askEveryLaunch")
        XCTAssertNil(ProfileLaunchBehavior.automatic.awayTimeout)
        XCTAssertNil(ProfileLaunchBehavior.askEveryLaunch.awayTimeout)
        XCTAssertEqual(ProfileLaunchBehavior.afterOneHour.awayTimeout, 3_600)
        XCTAssertEqual(ProfileLaunchBehavior.afterTwelveHours.awayTimeout, 43_200)
    }

    func testDefaultStateUsesAutomaticAndRequiresAProfile() {
        let state = ProfileLaunchState()
        XCTAssertEqual(state.behavior, .automatic)
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false), .needsSelection)
    }

    func testAskEveryLaunchNeverRestoresRememberedProfile() {
        let state = ProfileLaunchState(behavior: .askEveryLaunch, rememberedByServerID: [serverID: pinFreeProfile])
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: true), .needsSelection)
        XCTAssertEqual(state.rememberedByServerID[serverID], pinFreeProfile)
    }

    func testEveryTimeRequiresARealBackgroundIntervalOnWarmReturn() {
        var state = ProfileLaunchState(behavior: .askEveryLaunch)
        XCTAssertFalse(state.requiresSelectionAfterBackground(at: date(1_000)))
        state.backgroundedAt = date(1_000)
        XCTAssertTrue(state.requiresSelectionAfterBackground(at: date(1_000)))
    }

    func testTimedPoliciesRestoreBeforeAndRequireAtTimeout() {
        var state = ProfileLaunchState(
            behavior: .afterOneHour, rememberedByServerID: [serverID: pinFreeProfile], backgroundedAt: date(1_000))
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false,
                                        now: date(1_000 + 3_599)), .restore(pinFreeProfile))
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false,
                                        now: date(1_000 + 3_600)), .needsSelection)
        state.behavior = .afterTwelveHours
        XCTAssertFalse(state.requiresSelectionAtLaunch(at: date(1_000 + 43_199)))
        XCTAssertTrue(state.requiresSelectionAtLaunch(at: date(1_000 + 43_200)))
    }

    func testAutomaticIgnoresAStaleBackgroundMarker() {
        let state = ProfileLaunchState(behavior: .automatic, backgroundedAt: date(1_000))
        XCTAssertFalse(state.requiresSelectionAtLaunch(at: date(1_000 + 86_400)))
        XCTAssertFalse(state.requiresSelectionAfterBackground(at: date(1_000 + 86_400)))
    }

    func testLegacyLaunchStateWithoutBackgroundMarkerStillDecodes() throws {
        let json = #"{"behavior":"automatic","rememberedByServerID":{},"selectionRequiredServerIDs":[]}"#
        let state = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(json.utf8))
        XCTAssertEqual(state.behavior, .automatic)
        XCTAssertNil(state.backgroundedAt)
    }

    func testAutomaticRestoresPINlessProfileOffline() {
        let state = ProfileLaunchState(rememberedByServerID: [serverID: pinFreeProfile])
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false),
                       .restore(pinFreeProfile))
    }

    func testAutomaticRequiresProtectedProfileProofAndMatchingAccount() {
        let state = ProfileLaunchState(rememberedByServerID: [serverID: pinProtectedProfile])
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false), .needsSelection)
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: "replacement-account", hasStoredProfileToken: true), .needsSelection)
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: true),
                       .restore(pinProtectedProfile))
    }

    func testPendingSwitchAndKnownDeletedProfileRequireSelection() {
        let pending = ProfileLaunchState(rememberedByServerID: [serverID: pinFreeProfile], selectionRequiredServerIDs: [serverID])
        XCTAssertEqual(pending.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false), .needsSelection)
        let state = ProfileLaunchState(rememberedByServerID: [serverID: pinFreeProfile])
        XCTAssertEqual(state.resolution(for: serverID, accountEpoch: accountEpoch, hasStoredProfileToken: false,
                                        knownProfileIDs: ["profile-b"]), .needsSelection)
    }

    func testRememberPersistsAndClearsPendingSwitch() throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchPolicyTests")
        defer { suite.remove() }
        let preferences = ProfileLaunchPreferences(defaults: suite.defaults)
        preferences.behavior = .askEveryLaunch
        XCTAssertTrue(preferences.markBackgrounded(at: date(1_000)))
        XCTAssertTrue(preferences.markSelectionRequired(for: serverID))
        preferences.remember(profileID: "profile-a", requiresPIN: true, accountEpoch: accountEpoch, for: serverID)
        let restored = ProfileLaunchPreferences(defaults: suite.defaults)
        XCTAssertEqual(restored.behavior, .askEveryLaunch)
        XCTAssertEqual(restored.rememberedProfile(for: serverID),
                       RememberedProfile(profileID: "profile-a", requiredPINAtSelection: true, accountEpoch: accountEpoch))
        XCTAssertFalse(restored.state.selectionRequiredServerIDs.contains(serverID))
        XCTAssertNil(restored.state.backgroundedAt)
    }

    func testBackgroundMarkerPersistsAndClearsAcrossProcessRestores() throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchPolicyTests")
        defer { suite.remove() }
        let preferences = ProfileLaunchPreferences(defaults: suite.defaults)
        preferences.behavior = .afterOneHour
        XCTAssertTrue(preferences.markBackgrounded(at: date(2_000)))
        XCTAssertEqual(ProfileLaunchPreferences(defaults: suite.defaults).state.backgroundedAt, date(2_000))
        XCTAssertTrue(preferences.clearBackgroundedAt())
        XCTAssertNil(ProfileLaunchPreferences(defaults: suite.defaults).state.backgroundedAt)
    }

    func testBehaviorRollsBackWhenPersistenceFails() throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchPolicyTests")
        defer { suite.remove() }
        var persistenceWorks = true
        let preferences = ProfileLaunchPreferences(defaults: suite.defaults, persistenceOverride: { _ in persistenceWorks })
        persistenceWorks = false
        preferences.behavior = .askEveryLaunch
        XCTAssertEqual(preferences.behavior, .automatic)
    }

    func testInvalidProfileNotificationCannotReplaceAnActiveProfile() {
        XCTAssertTrue(shouldPresentProfileSelectionAfterRecovery(isLoggedIn: true, activeProfileID: nil))
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(isLoggedIn: true, activeProfileID: "replacement-profile"))
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(isLoggedIn: false, activeProfileID: nil))
    }

    func testTopShelfRespectsProfileSelectionPolicyAndMatchingCurrentUserIdentity() {
        var state = ProfileLaunchState(rememberedByServerID: [serverID: pinFreeProfile])
        func allowed(storedToken: Bool, now: Date = .now) -> Bool {
            TopShelfProfilePolicy.allowsPersonalizedContent(
                state: state, serverID: serverID, activeProfileID: "profile-a", accountEpoch: accountEpoch,
                hasStoredProfileToken: storedToken, now: now)
        }
        state.behavior = .automatic
        XCTAssertTrue(allowed(storedToken: false))
        state.behavior = .askEveryLaunch
        XCTAssertFalse(allowed(storedToken: true))
        state.behavior = .automatic
        state.selectionRequiredServerIDs.insert(serverID)
        XCTAssertFalse(allowed(storedToken: true))
        state.behavior = .afterOneHour
        state.selectionRequiredServerIDs.remove(serverID)
        state.backgroundedAt = date(3_000)
        XCTAssertTrue(allowed(storedToken: false, now: date(3_000 + 3_599)))
        XCTAssertFalse(allowed(storedToken: false, now: date(3_000 + 3_600)))
    }

    func testTopShelfOnlyShowsTheSoleUnlockedSavedAccount() throws {
        let row: [String: Any] = ["id": "saved", "serverID": "server", "requiresLogin": false]
        func allowed(_ rows: [[String: Any]], active: String = "saved", server: String = "server", hasPIN: Bool = false) throws -> Bool {
            TopShelfProfilePolicy.allowsSavedAccountContent(
                accountsData: try JSONSerialization.data(withJSONObject: rows),
                activeAccountID: active, serverID: server, hasStoredPIN: { _ in hasPIN })
        }
        var second = row
        second["id"] = "second"
        var pinned = row
        pinned["pinEnabled"] = true
        var signedOut = row
        signedOut["requiresLogin"] = true
        XCTAssertTrue(try allowed([row]))
        XCTAssertFalse(try allowed([]))
        XCTAssertFalse(try allowed([row, second]))
        XCTAssertFalse(try allowed([row], active: "other"))
        XCTAssertFalse(try allowed([row], server: "other"))
        XCTAssertFalse(try allowed([row], hasPIN: true))
        XCTAssertFalse(try allowed([pinned]))
        XCTAssertFalse(try allowed([signedOut]))
        for data in [nil, Data("invalid".utf8)] as [Data?] {
            XCTAssertFalse(TopShelfProfilePolicy.allowsSavedAccountContent(
                accountsData: data, activeAccountID: "saved", serverID: "server", hasStoredPIN: { _ in false }))
        }
    }

    func testTopShelfOnlyPersonalisesASiloAccountWithOneViewingProfile() throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchPolicyTests.viewingProfiles")
        defer { suite.remove() }
        func allowed(_ server: String = "server-a", epoch: String? = "account-a") -> Bool {
            TopShelfProfilePolicy.allowsViewingProfileCount(
                countsData: suite.defaults.data(forKey: SharedStorage.viewingProfileCountsKey), serverID: server, accountEpoch: epoch)
        }
        XCTAssertFalse(allowed())
        XCTAssertTrue(allowed("emby:server"))
        XCTAssertTrue(allowed("jellyfin:server", epoch: nil))
        XCTAssertTrue(TopShelfProfileCounts.record(1, serverID: "server-a", accountEpoch: "account-a", defaults: suite.defaults))
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(epoch: "account-b"))
        XCTAssertFalse(allowed(epoch: nil))
        XCTAssertFalse(allowed("server-b"))
        XCTAssertFalse(TopShelfProfileCounts.record(1, serverID: "server-a", accountEpoch: "account-a", defaults: suite.defaults))
        XCTAssertTrue(TopShelfProfileCounts.record(2, serverID: "server-a", accountEpoch: "account-a", defaults: suite.defaults))
        XCTAssertFalse(allowed())
        suite.suite.set(Data("invalid".utf8), forKey: SharedStorage.viewingProfileCountsKey)
        XCTAssertFalse(allowed())
    }

    func testTopShelfRequiresCurrentUserProofForProtectedProfile() {
        let state = ProfileLaunchState(behavior: .automatic, rememberedByServerID: [serverID: pinProtectedProfile])
        func allowed(storedToken: Bool) -> Bool {
            TopShelfProfilePolicy.allowsPersonalizedContent(
                state: state, serverID: serverID, activeProfileID: "profile-a", accountEpoch: accountEpoch,
                hasStoredProfileToken: storedToken)
        }
        XCTAssertFalse(allowed(storedToken: false))
        XCTAssertTrue(allowed(storedToken: true))
    }

    func testCredentialAudienceClassification() {
        XCTAssertEqual(TokenStore.accountCredentialAudience, .currentUser)
        XCTAssertEqual(TokenStore.profileCredentialAudience, .currentUser)
    }
}

/// The account epoch, profile activation and the Keychain rules they rely on.
final class ProfileLaunchIdentityTests: XCTestCase {
    private struct Harness {
        let suite: ThrowawaySuite
        let keychain: SharedKeychain
        let store: TokenStore
        let serverID = "server-a"

        init() throws {
            suite = try ThrowawaySuite(prefix: "ProfileLaunchIdentityTests")
            keychain = SharedKeychain(service: "ProfileLaunchIdentityTests." + UUID().uuidString, accessGroup: nil)
            store = TokenStore(keychain: keychain, defaults: suite.defaults)
        }

        func signIn(accessToken: String, refreshToken: String) async {
            await store.switchActiveServer(serverId: serverID)
            await store.setServerUrl("https://silo.example")
            await store.saveTokens(accessToken: accessToken, refreshToken: refreshToken)
        }

        func cleanUp() {
            let accounts = [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
            ]
            for account in accounts { keychain.delete(account) }
            suite.remove()
        }
    }

    func testAccountEpochRotatesAndRejectsStaleActivation() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let store = harness.store
        await harness.signIn(accessToken: "access-a", refreshToken: "refresh-a")
        let firstRead = await store.getOrCreateAccountEpoch()
        let firstEpoch = try XCTUnwrap(firstRead)
        let identityRead = await store.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityRead)
        await store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
        let secondRead = await store.getOrCreateAccountEpoch()
        let secondEpoch = try XCTUnwrap(secondRead)
        let activated = await store.activateProfile(profileID: "profile-a", profileToken: nil, expectedAccount: identity)
        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertFalse(activated)
    }

    func testProfileCommitIsAtomicAndLateDeactivationCannotClearReplacement() async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        let store = harness.store
        await harness.signIn(accessToken: "access", refreshToken: "refresh")
        let identityRead = await store.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityRead)

        let activatedFirst = await store.activateProfile(profileID: "profile-a", profileToken: "proof-a", expectedAccount: identity)
        XCTAssertTrue(activatedFirst)
        let firstID = await store.getProfileId()
        XCTAssertEqual(firstID, "profile-a")
        let firstToken = await store.getProfileToken()
        XCTAssertEqual(firstToken, "proof-a")

        let activatedSecond = await store.activateProfile(profileID: "profile-b", profileToken: nil, expectedAccount: identity)
        XCTAssertTrue(activatedSecond)
        let lateDeactivation = await store.deactivateProfile(expectedAccount: identity, expectedProfileID: "profile-a")
        XCTAssertFalse(lateDeactivation)
        let currentID = await store.getProfileId()
        XCTAssertEqual(currentID, "profile-b")
        let currentToken = await store.getProfileToken()
        XCTAssertNil(currentToken)
    }

    func testFailedKeychainWriteDoesNotPublishProfileProof() async throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchIdentityTests")
        defer { suite.remove() }
        let keychain = SharedKeychain(
            service: "ProfileLaunchIdentityTests." + UUID().uuidString,
            accessGroup: "invalid.access.group",
            allowsAppLocalFallback: false)
        let store = TokenStore(keychain: keychain, defaults: suite.defaults)
        await store.switchActiveServer(serverId: "server-a")
        let saved = await store.setProfileToken("proof")
        XCTAssertFalse(saved)
        let token = await store.getProfileToken()
        XCTAssertNil(token)
    }

    func testUnavailableConfiguredAccessGroupUsesAppLocalKeychainWhenEnabled() {
        let service = "ProfileLaunchIdentityTests." + UUID().uuidString
        let account = "profile-proof"
        let sharedGroup = SharedKeychain(service: service, accessGroup: "invalid.access.group", allowsAppLocalFallback: true)
        let appLocal = SharedKeychain(service: service, accessGroup: nil)
        defer { appLocal.delete(account) }
        XCTAssertTrue(sharedGroup.set("proof", for: account))
        XCTAssertEqual(appLocal.get(account), "proof")
        XCTAssertEqual(sharedGroup.get(account), "proof")
        XCTAssertEqual(appLocal.get(account), "proof", "Reading through the fallback must not move or delete the item")
        XCTAssertTrue(sharedGroup.delete(account))
        XCTAssertNil(sharedGroup.get(account))
        XCTAssertNil(appLocal.get(account))
    }

    func testAppLocalKeychainFallbackPolicyIsLimitedToLegacyIOSSideloads() {
        XCTAssertTrue(SharedKeychainPolicy.allowsAppLocalFallback(buildChannel: "sideload", isOlderThanIOS26: true))
        XCTAssertFalse(SharedKeychainPolicy.allowsAppLocalFallback(buildChannel: "sideload", isOlderThanIOS26: false))
        XCTAssertFalse(SharedKeychainPolicy.allowsAppLocalFallback(buildChannel: "release", isOlderThanIOS26: true))
        XCTAssertFalse(SharedKeychainPolicy.allowsAppLocalFallback(buildChannel: "dev", isOlderThanIOS26: true))
    }

    func testAppLocalKeychainFallbackPolicyRecognizesUnsignedArchiveGroup() {
        XCTAssertEqual(SharedKeychainPolicy.acceptedAccessGroup("com.blurbery.vivid.shared", allowsBareGroup: true),
                       "com.blurbery.vivid.shared")
        XCTAssertNil(SharedKeychainPolicy.acceptedAccessGroup("com.blurbery.vivid.shared", allowsBareGroup: false))
        XCTAssertEqual(SharedKeychainPolicy.acceptedAccessGroup("TEAMID.com.blurbery.vivid.shared", allowsBareGroup: false),
                       "TEAMID.com.blurbery.vivid.shared")
        XCTAssertEqual(SharedKeychainPolicy.legacyTeamPrefix(forAccessGroup: "TEAMID.com.blurbery.vivid.shared"), "TEAMID.")
        XCTAssertNil(SharedKeychainPolicy.legacyTeamPrefix(forAccessGroup: "com.blurbery.vivid.shared"))
    }

    func testSharedKeychainPolicyRejectsUnrelatedGroups() {
        for group in ["TEAMID.com.example.other.shared", "com.blurbery.vivid.shared.extra"] {
            XCTAssertNil(SharedKeychainPolicy.acceptedAccessGroup(group, allowsBareGroup: false), group)
            XCTAssertNil(SharedKeychainPolicy.legacyTeamPrefix(forAccessGroup: group), group)
        }
    }

    /// A Keychain that is only briefly unavailable at launch must not cost the
    /// device its identifier: the new one is used for this launch but not saved.
    func testTemporaryKeychainFailureKeepsTheStoredDeviceIdentifier() {
        func decision(_ stored: Result<String?, Error>) -> (identifier: String, save: Bool) {
            AppleDeviceIdentity.deviceIdentifier(from: stored) { "generated" }
        }
        let kept = decision(.success("stored"))
        XCTAssertEqual(kept.identifier, "stored")
        XCTAssertFalse(kept.save)
        for missing in [nil, ""] as [String?] {
            let made = decision(.success(missing))
            XCTAssertEqual(made.identifier, "generated")
            XCTAssertTrue(made.save)
        }
        for status in [errSecInteractionNotAllowed, errSecNotAvailable] {
            let temporary = decision(.failure(KeychainReadFailure(status: status)))
            XCTAssertEqual(temporary.identifier, "generated", "\(status)")
            XCTAssertFalse(temporary.save, "\(status)")
        }
        for status in [errSecDecode, errSecMissingEntitlement] {
            let lasting = decision(.failure(KeychainReadFailure(status: status)))
            XCTAssertEqual(lasting.identifier, "generated", "\(status)")
            XCTAssertTrue(lasting.save, "\(status)")
        }
    }
}

/// Only an explicit profile error starts profile recovery.
@MainActor
final class InvalidProfileRecoveryTests: XCTestCase {
    private func error(_ status: Int, _ body: String?) -> HTTPError {
        .http(statusCode: status, body: body)
    }

    func testOnlyExplicitProfileErrorsTriggerRecovery() {
        XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error(403, #"{"error":"profile_unverified"}"#)))
        XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(error(404, #"{"error":"profile_not_found"}"#)))
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(error(404, #"{"error":"content_not_found"}"#)))
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(error(404, nil)))
    }

    func testRemovedProfileAnswerOnlyPromptsAProfileListCheck() {
        let removedProfileBodies = [
            #"{"error":"not_found","message":"Profile not found"}"#,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"#
                + #""detail":"Profile not found","instance":"urn:silo:request:000000000000000000000001"}"#,
        ]
        for body in removedProfileBodies {
            XCTAssertTrue(StartupContentPrefetcher.mayIndicateRemovedProfile(error(404, body)), body)
            XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(error(404, body)), body)
        }
        XCTAssertFalse(StartupContentPrefetcher.mayIndicateRemovedProfile(error(404, nil)))
        XCTAssertFalse(StartupContentPrefetcher.mayIndicateRemovedProfile(error(404, #"{"error":"unknown_setting"}"#)))
        XCTAssertFalse(StartupContentPrefetcher.mayIndicateRemovedProfile(error(403, #"{"error":"not_found"}"#)))
    }
}

/// The legacy registry's profile moves into the launch preferences before the
/// field is dropped from the registry.
@MainActor
final class ProfileLaunchMigrationTests: XCTestCase {
    private struct LegacyRegistry: Codable {
        let activeServerId: String?
        let entries: [ServerEntry]
    }

    func testLegacyRegistryProfileMigratesBeforeProfileFieldIsRemoved() throws {
        let suite = try ThrowawaySuite(prefix: "ProfileLaunchMigrationTests")
        let keychain = SharedKeychain(service: "ProfileLaunchMigrationTests." + UUID().uuidString, accessGroup: nil)
        let serverID = "server-a"
        defer {
            for account in [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
            ] {
                keychain.delete(account)
            }
            suite.remove()
        }
        let legacy = LegacyRegistry(activeServerId: serverID, entries: [
            ServerEntry(id: serverID, url: "https://silo.example", fetchedName: "Silo", profileId: "profile-a",
                        lastUsedAt: Date(timeIntervalSinceReferenceDate: 1)),
        ])
        suite.defaults.set(try JSONEncoder().encode(legacy), forKey: "vividServerRegistry.v1")
        XCTAssertTrue(keychain.set("access", for: TokenStore.accessTokenKey(for: serverID)))
        XCTAssertTrue(keychain.set("proof", for: TokenStore.profileTokenKey(for: serverID)))

        let preferences = ProfileLaunchPreferences(defaults: suite.defaults)
        let registry = ServerRegistry(defaults: suite.defaults, keychain: keychain, launchPreferences: preferences)

        let remembered = try XCTUnwrap(preferences.rememberedProfile(for: serverID))
        XCTAssertEqual(remembered.profileID, "profile-a")
        XCTAssertTrue(remembered.requiredPINAtSelection)
        XCTAssertNil(registry.entry(with: serverID)?.legacyProfileId)
        let stored = try XCTUnwrap(suite.defaults.data(forKey: "vividServerRegistry.v1"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("profileId"))
    }
}
