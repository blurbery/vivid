import XCTest
@testable import Vivid

final class VividCloudPreferenceTests: XCTestCase {
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
}
