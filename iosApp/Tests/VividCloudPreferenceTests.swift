import XCTest
@testable import Vivid

final class VividCloudPreferenceTests: XCTestCase {
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

    func testPlaybackAndSubtitleSettingsAreExcluded() {
        for key in ["playback.audio_language", "playback.subtitle_appearance", "player.buffer_ahead", "subtitle.matches_device"] {
            XCTAssertFalse(VividCloudPreferencePolicy.isSharedSetting(key))
        }
        for key in ["nav.primary_menu", "catalog.metadata_language", "ui.card_presentation", "downloads.wifi_only"] {
            XCTAssertTrue(VividCloudPreferencePolicy.isSharedSetting(key))
        }
    }
}
