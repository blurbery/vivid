import XCTest
@testable import Vivid

final class VividCloudPreferenceTests: XCTestCase {
    /// TMDb keys are retired: the vault deletes them and never restores one.
    /// No other plugin's key may be caught by that.
    @MainActor
    func testOnlyTMDbKeysAreRetired() {
        XCTAssertTrue(VividCloudPreferences.isRetiredCredential(VividCloudPreferences.credentialKey("tmdb", server: "s", profile: "p")))
        XCTAssertFalse(VividCloudPreferences.isRetiredCredential(VividCloudPreferences.credentialKey("seerr", server: "s", profile: "p")))
        XCTAssertFalse(VividCloudPreferences.isRetiredCredential("vivid.mdblist.key.v1.scope"))
        XCTAssertFalse(VividCloudPreferences.isRetiredCredential("vivid.opensubtitles.key.v1.scope"))
    }

    /// Older Vivid builds write every `setting|` entry back to Silo's shared
    /// rows, so Vivid's own Silo interface settings must never use that name.
    @MainActor
    func testSiloInterfaceSettingsUseTheirOwnVaultName() {
        let siloMenu = VividCloudPreferences.settingName(serverId: "silo", profileId: "p", key: "nav.primary_menu")
        let siloCards = VividCloudPreferences.settingName(serverId: "silo", profileId: "p", key: "ui.card_presentation")
        let siloMetadata = VividCloudPreferences.settingName(serverId: "silo", profileId: "p", key: "catalog.metadata_language")
        let embyMenu = VividCloudPreferences.settingName(serverId: "emby:server", profileId: "p", key: "nav.primary_menu")

        XCTAssertTrue(siloMenu.hasPrefix("vivid-setting|"))
        XCTAssertTrue(siloCards.hasPrefix("vivid-setting|"))
        XCTAssertTrue(siloMetadata.hasPrefix("setting|"))
        XCTAssertTrue(embyMenu.hasPrefix("setting|"))
        XCTAssertNotEqual(
            siloMenu,
            VividCloudPreferences.settingName(serverId: "silo", profileId: "other", key: "nav.primary_menu")
        )
    }

    func testPluginCredentialScopePreservesAccountAndProfileIsolation() {
        let scope = VividCloudPreferences.pluginScope(server: "server", user: "user", profile: "profile")
        XCTAssertEqual(scope, "535ebf95cd5b844ea8e78b0b4ca88838b3b430f6cd2995f37a08f0a083896547")
        for args in [("other", "user", "profile"), ("server", "other", "profile"), ("server", "user", "other")] {
            XCTAssertNotEqual(scope, VividCloudPreferences.pluginScope(server: args.0, user: args.1, profile: args.2))
        }
    }

    func testAccountSwitchDoesNotUseAnotherServerOrProfilesCredentials() {
        XCTAssertTrue(VividCloudPreferencePolicy.matchesAccountContext(server: "silo", profile: "a",
            accountServer: "silo", accountProfile: "a", requiresLogin: false))
        for (server, profile, login) in [("silo", "b", false), ("emby", "a", false), ("silo", "a", true), ("silo", "", false)] {
            XCTAssertFalse(VividCloudPreferencePolicy.matchesAccountContext(server: server, profile: profile,
                accountServer: "silo", accountProfile: "a", requiresLogin: login))
        }
        XCTAssertFalse(VividCloudPreferencePolicy.matchesAccountContext(server: "silo", profile: "a",
            accountServer: "silo", accountProfile: nil, requiresLogin: false))
    }

    /// Adding a server, then leaving Vivid to copy its password, must not
    /// switch back to the saved profile that was active before.
    func testSyncKeepsAChosenServerUntilItsProfileIsActive() {
        XCTAssertTrue(VividCloudRestorePolicy.keepsChosenServer(chosenServerID: "new", activeServerID: "new",
                                                                activeAccountServerID: "old"))
        XCTAssertTrue(VividCloudRestorePolicy.keepsChosenServer(chosenServerID: "new", activeServerID: "new",
                                                                activeAccountServerID: nil))
        // A saved profile on the chosen server, a later switch elsewhere and a
        // relaunch (nothing chosen yet) all restore as before.
        XCTAssertFalse(VividCloudRestorePolicy.keepsChosenServer(chosenServerID: "new", activeServerID: "new",
                                                                 activeAccountServerID: "new"))
        XCTAssertFalse(VividCloudRestorePolicy.keepsChosenServer(chosenServerID: "new", activeServerID: "old",
                                                                 activeAccountServerID: "old"))
        XCTAssertFalse(VividCloudRestorePolicy.keepsChosenServer(chosenServerID: nil, activeServerID: "new",
                                                                 activeAccountServerID: "old"))
    }

    func testMissingPluginKeyPreservesSavedCredentialAndRemoteValue() {
        let saved = VividCloudPreference(value: Data("test-key".utf8), modifiedAt: Date(timeIntervalSince1970: 10), writer: "phone")
        let captured = VividCloudPreferencePolicy.capturedPluginCredential(nil, previous: saved,
            modifiedAt: Date(timeIntervalSince1970: 20), writer: "tv")
        XCTAssertEqual(captured, saved)
        XCTAssertEqual(VividCloudPreferencePolicy.merge(["key": captured!], ["key": saved])["key"], saved)
        XCTAssertTrue(VividCloudPreferencePolicy.needsCredentialRestore(saved, stored: nil))
        XCTAssertFalse(VividCloudPreferencePolicy.needsCredentialRestore(saved, stored: saved.value))
    }

    func testMissingUnconfiguredPluginDoesNotCreateDeletion() {
        XCTAssertNil(VividCloudPreferencePolicy.capturedPluginCredential(nil, previous: nil,
            modifiedAt: Date(), writer: "tv"))
    }

    func testExplicitPluginDisconnectStillWinsAndCanBeReconnected() {
        let saved = VividCloudPreference(value: Data("old-key".utf8), modifiedAt: Date(timeIntervalSince1970: 10), writer: "phone")
        let disconnected = VividCloudPreference(value: nil, modifiedAt: Date(timeIntervalSince1970: 20), writer: "phone")
        XCTAssertEqual(VividCloudPreferencePolicy.merge(["key": saved], ["key": disconnected])["key"], disconnected)
        XCTAssertEqual(VividCloudPreferencePolicy.capturedPluginCredential(nil, previous: disconnected,
            modifiedAt: Date(timeIntervalSince1970: 30), writer: "tv"), disconnected)
        XCTAssertTrue(VividCloudPreferencePolicy.needsCredentialRestore(disconnected, stored: saved.value))
        let reconnected = VividCloudPreferencePolicy.capturedPluginCredential(Data("new-key".utf8), previous: disconnected,
            modifiedAt: Date(timeIntervalSince1970: 30), writer: "tv")!
        XCTAssertEqual(VividCloudPreferencePolicy.merge(["key": reconnected], ["key": disconnected])["key"], reconnected)
    }

    func testIndependentEditsAndCredentialDeletionSurviveMerge() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let local = ["home": VividCloudPreference(value: Data([1]), modifiedAt: new, writer: "phone"),
                     "credential": VividCloudPreference(value: Data([2]), modifiedAt: old, writer: "phone")]
        let remote = ["spotlight": VividCloudPreference(value: Data([3]), modifiedAt: new, writer: "tv"),
                      "credential": VividCloudPreference(value: nil, modifiedAt: new, writer: "tv")]
        let merged = VividCloudPreferencePolicy.merge(local, remote)
        XCTAssertEqual(merged["home"], local["home"])
        XCTAssertEqual(merged["spotlight"], remote["spotlight"])
        XCTAssertNotNil(merged["credential"])
        XCTAssertNil(merged["credential"]?.value)
        XCTAssertEqual(merged, VividCloudPreferencePolicy.merge(remote, local))
    }

    func testEqualTimestampsConvergeRegardlessOfMergeDirection() {
        let a = ["home": VividCloudPreference(value: Data([1]), modifiedAt: .distantPast, writer: "a")]
        let b = ["home": VividCloudPreference(value: Data([2]), modifiedAt: .distantPast, writer: "b")]
        XCTAssertEqual(VividCloudPreferencePolicy.merge(a, b), VividCloudPreferencePolicy.merge(b, a))
    }

    func testProfileOrderPreservesRemoteOrderAndAppendsNewProfilesOnce() {
        XCTAssertEqual(VividCloudPreferencePolicy.ordered(["c", "a", "b", "d"], preferred: ["b", "a", "deleted", "b", "c"]), ["b", "a", "c", "d"])
    }

    func testExplicitProfileMovesPreserveAllIdentities() {
        XCTAssertEqual(VividCloudPreferencePolicy.moving(["a", "b", "c"], id: "b", by: -1), ["b", "a", "c"])
        XCTAssertEqual(VividCloudPreferencePolicy.moving(["a", "b", "c"], id: "b", by: 1), ["a", "c", "b"])
        for (id, offset) in [("a", -1), ("c", 1), ("deleted", 1), ("b", 99)] {
            XCTAssertEqual(VividCloudPreferencePolicy.moving(["a", "b", "c"], id: id, by: offset), ["a", "b", "c"])
        }
        XCTAssertEqual(VividCloudPreferencePolicy.ordered(["c", "a", "new"], preferred: ["b", "a", "c"]), ["a", "c", "new"])
    }

    func testPlaybackAndSubtitleSettingsAreExcluded() {
        for key in ["playback.audio_language", "playback.subtitle_appearance", "player.buffer_ahead", "subtitle.matches_device"] {
            XCTAssertFalse(VividCloudPreferencePolicy.isSharedSetting(key))
        }
        for key in ["nav.primary_menu", "catalog.metadata_language", "ui.card_presentation", "downloads.wifi_only"] {
            XCTAssertTrue(VividCloudPreferencePolicy.isSharedSetting(key))
        }
    }

    /// The health monitor rewrites its exit marker every 30 seconds and after
    /// every hang. Those writes must not wake the capture, but every store a
    /// synced preference lives in still must.
    func testHealthMonitorWritesDoNotWakeCapture() throws {
        let health = try XCTUnwrap(AppHealthMonitor.store)
        XCTAssertFalse(health === UserDefaults.standard)
        let key = "vivid.tests.healthStoreChange"
        defer { health.removeObject(forKey: key) }
        let posted = expectation(forNotification: UserDefaults.didChangeNotification, object: health)
        health.set(UUID().uuidString, forKey: key)
        wait(for: [posted], timeout: 2)

        XCTAssertFalse(VividCloudPreferences.capturesChange(from: health))
        XCTAssertTrue(VividCloudPreferences.capturesChange(from: UserDefaults.standard))
        XCTAssertTrue(VividCloudPreferences.capturesChange(from: SharedStorage.suite))
        XCTAssertTrue(VividCloudPreferences.capturesChange(from: nil))
    }
}
