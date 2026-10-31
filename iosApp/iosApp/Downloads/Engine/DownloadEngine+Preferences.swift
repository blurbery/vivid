import Foundation
import Observation

/// The device's download preferences, kept per profile once a profile is
/// loaded. None of them is sent to a server.
@Observable
final class DownloadSettings {
    static let shared = DownloadSettings()

    private enum Key {
        static let wifiOnly = "downloads.wifiOnly"
        static let deleteWatched = "downloads.defaultDeleteWatched"
        static let limitGB = "downloads.defaultMaxStorageGB"
        static let order = "downloads.sortOption"
        static let keepWatched = "downloads.keepWatchedDownloads"
    }

    var wifiOnlyTransfers: Bool { didSet { store(wifiOnlyTransfers, Key.wifiOnly) } }
    var monitoringDeletesWatchedByDefault: Bool { didSet { store(monitoringDeletesWatchedByDefault, Key.deleteWatched) } }
    /// Gigabytes of 1,073,741,824 bytes; 0 means unlimited.
    var monitoringLimitGBByDefault: Int { didSet { store(monitoringLimitGBByDefault, Key.limitGB) } }
    var listOrder: DownloadListOrder { didSet { store(listOrder.rawValue, Key.order) } }
    var keepsWatchedDownloads: Bool { didSet { store(keepsWatchedDownloads, Key.keepWatched) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scope: String?

    /// Registers the defaults under the plain keys and reads them. Nothing is
    /// written back.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.wifiOnly: true,
            Key.deleteWatched: false,
            Key.limitGB: 0,
            Key.order: DownloadListOrder.biggestFirst.rawValue,
            Key.keepWatched: false,
        ])
        wifiOnlyTransfers = defaults.bool(forKey: Key.wifiOnly)
        monitoringDeletesWatchedByDefault = defaults.bool(forKey: Key.deleteWatched)
        monitoringLimitGBByDefault = defaults.integer(forKey: Key.limitGB)
        listOrder = DownloadListOrder(rawValue: defaults.string(forKey: Key.order) ?? "") ?? .biggestFirst
        keepsWatchedDownloads = defaults.bool(forKey: Key.keepWatched)
    }

    /// Loads the preferences of the player settings' current profile scope.
    func reloadForCurrentProfile() {
        #if os(iOS)
        // Every caller is on the main actor; the scope comes from player settings.
        let scope = MainActor.assumeIsolated { PlayerSettings.currentScopeIdentifier }
        load(scope: scope)
        #endif
    }

    /// Switches to another profile's preferences (nil for the plain keys) and
    /// writes each value read straight back under that scope's keys.
    func load(scope newScope: String?) {
        guard newScope != scope else { return }
        scope = newScope
        // Registered defaults only cover the plain keys.
        wifiOnlyTransfers = defaults.object(forKey: key(Key.wifiOnly)) as? Bool ?? true
        monitoringDeletesWatchedByDefault = defaults.bool(forKey: key(Key.deleteWatched))
        monitoringLimitGBByDefault = defaults.integer(forKey: key(Key.limitGB))
        listOrder = DownloadListOrder(rawValue: defaults.string(forKey: key(Key.order)) ?? "") ?? .biggestFirst
        keepsWatchedDownloads = defaults.bool(forKey: key(Key.keepWatched))
    }

    private func key(_ bare: String) -> String {
        guard let scope else { return bare }
        return "downloads.profile.\(scope).\(bare)"
    }

    private func store(_ value: Any, _ bare: String) {
        defaults.set(value, forKey: key(bare))
    }
}
