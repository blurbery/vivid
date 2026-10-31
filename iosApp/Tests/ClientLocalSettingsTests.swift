import XCTest
@testable import Vivid

final class ClientLocalSettingsTests: XCTestCase {
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
