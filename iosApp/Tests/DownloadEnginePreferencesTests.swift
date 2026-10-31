import XCTest
@testable import Vivid

final class DownloadEnginePreferencesTests: XCTestCase {
    /// With no profile loaded the preferences live under the plain keys and
    /// survive a new settings object.
    func testDownloadPreferencesPersist() throws {
        let suiteName = "vivid.tests.download-preferences.plain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = DownloadSettings(defaults: defaults)
        XCTAssertTrue(settings.wifiOnlyTransfers)
        XCTAssertFalse(settings.keepsWatchedDownloads)
        settings.wifiOnlyTransfers = false
        settings.keepsWatchedDownloads = true

        let reloaded = DownloadSettings(defaults: defaults)
        XCTAssertFalse(reloaded.wifiOnlyTransfers)
        XCTAssertTrue(reloaded.keepsWatchedDownloads)
    }
}
