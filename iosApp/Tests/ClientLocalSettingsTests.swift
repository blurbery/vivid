import XCTest
@testable import Vivid

final class ClientLocalSettingsTests: XCTestCase {
    func testDownloadContractPreferencesPersistAndDriveTheirPolicies() throws {
        let suiteName = "client-local-download-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = DownloadSettings(defaults: defaults)
        XCTAssertEqual(settings.preferredFormat, DownloadFormat.original.rawValue)
        XCTAssertTrue(settings.wifiOnly)
        XCTAssertFalse(settings.keepWatchedDownloads)

        settings.preferredFormat = DownloadFormat.fiveMbps.rawValue
        settings.wifiOnly = false
        settings.keepWatchedDownloads = true

        let restored = DownloadSettings(defaults: defaults)
        XCTAssertEqual(restored.preferredFormat, DownloadFormat.fiveMbps.rawValue)
        XCTAssertFalse(restored.wifiOnly)
        XCTAssertTrue(restored.keepWatchedDownloads)
        XCTAssertEqual(
            restored.resolvedFormat(allowedFormats: [DownloadFormat.fiveMbps.rawValue]),
            DownloadFormat.fiveMbps.rawValue
        )
        XCTAssertEqual(
            restored.resolvedFormat(allowedFormats: [DownloadFormat.original.rawValue]),
            DownloadFormat.original.rawValue,
            "an unavailable saved quality must fall back to a request the server offers"
        )
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
