import XCTest
@testable import Vivid

final class ClientLocalSettingsTests: XCTestCase {
    func testDownloadContractPreferencesPersistAndDriveTheirPolicies() throws {
        let suiteName = "client-local-download-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = DownloadSettings(defaults: defaults)
        XCTAssertTrue(settings.wifiOnly)
        XCTAssertFalse(settings.keepWatchedDownloads)

        settings.wifiOnly = false
        settings.keepWatchedDownloads = true

        let restored = DownloadSettings(defaults: defaults)
        XCTAssertFalse(restored.wifiOnly)
        XCTAssertTrue(restored.keepWatchedDownloads)
    }

    @MainActor
    func testMatchDeviceCaptionsOverridesServerAppearanceAndManualEditingTakesBackControl() async throws {
        let harness = try PlayerSettingsHarness()
        var systemAppearance = SubtitleAppearance.default
        systemAppearance.fontSize = .xxlarge
        systemAppearance.fontColor = "#facc15"
        systemAppearance.position = .top
        harness.settings.setSubtitleMatchesSystemAppearance(true)
        harness.settings.subtitleSystemAppearance = systemAppearance
        XCTAssertTrue(harness.settings.subtitleMatchesSystemAppearance)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance, systemAppearance)

        var customAppearance = SubtitleAppearance.default
        customAppearance.fontSize = .small
        await harness.settings.setSubtitleAppearance(customAppearance)

        XCTAssertFalse(harness.settings.subtitleMatchesSystemAppearance)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance, customAppearance)
    }
}
