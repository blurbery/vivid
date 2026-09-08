import Foundation

/// Device-level download preferences. Persisted to `UserDefaults` in each
/// property's `didSet`, mirroring the `PlayerSettings` convention. These
/// are local decisions (not server-synced): the download quality to
/// request, whether to restrict to Wi-Fi, and the defaults used when
/// creating a new series-monitoring subscription.
@Observable
final class DownloadSettings {
    static let shared = DownloadSettings()

    /// Requested download quality. Coerced to `original` if the active
    /// server doesn't currently offer the stored choice.
    var preferredFormat: String {
        didSet { defaults.set(preferredFormat, forKey: storageKey(Keys.preferredFormat)) }
    }

    /// When true, downloads only transfer over Wi-Fi.
    var wifiOnly: Bool {
        didSet { defaults.set(wifiOnly, forKey: storageKey(Keys.wifiOnly)) }
    }

    /// Default `delete_watched` for new subscriptions.
    var defaultDeleteWatched: Bool {
        didSet { defaults.set(defaultDeleteWatched, forKey: storageKey(Keys.defaultDeleteWatched)) }
    }

    /// Default per-subscription storage cap in GB. `0` = unlimited.
    var defaultMaxStorageGB: Int {
        didSet { defaults.set(defaultMaxStorageGB, forKey: storageKey(Keys.defaultMaxStorageGB)) }
    }

    /// Last-chosen ordering for the Downloads Manager list.
    var sortOption: DownloadSortOption {
        didSet { defaults.set(sortOption.rawValue, forKey: storageKey(Keys.sortOption)) }
    }

    /// When true, suppress the "Free up space" reclaim suggestion (the user
    /// prefers to keep watched downloads around).
    var keepWatchedDownloads: Bool {
        didSet { defaults.set(keepWatchedDownloads, forKey: storageKey(Keys.keepWatchedDownloads)) }
    }

    private var loadedScope: String?
    private func storageKey(_ key: String) -> String {
        guard let loadedScope else { return key }
        return "downloads.profile.\(loadedScope).\(key)"
    }

    func reloadForCurrentProfile() {
        #if os(iOS)
        reload(for: PlayerSettings.currentScopeIdentifier)
        #endif
    }

    func reload(for scope: String?) {
        guard loadedScope != scope else { return }
        loadedScope = scope
        preferredFormat = defaults.string(forKey: storageKey(Keys.preferredFormat)) ?? DownloadFormat.original.rawValue
        wifiOnly = (defaults.object(forKey: storageKey(Keys.wifiOnly)) as? Bool) ?? true
        defaultDeleteWatched = defaults.bool(forKey: storageKey(Keys.defaultDeleteWatched))
        defaultMaxStorageGB = defaults.integer(forKey: storageKey(Keys.defaultMaxStorageGB))
        sortOption = defaults.string(forKey: storageKey(Keys.sortOption)).flatMap(DownloadSortOption.init(rawValue:)) ?? .largestFirst
        keepWatchedDownloads = defaults.bool(forKey: storageKey(Keys.keepWatchedDownloads))
    }

    private let defaults: UserDefaults

    /// Internal so tests can verify the contract-known local preferences in an
    /// isolated defaults domain instead of mutating the app-wide singleton.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.preferredFormat: DownloadFormat.original.rawValue,
            Keys.wifiOnly: true,
            Keys.defaultDeleteWatched: false,
            Keys.defaultMaxStorageGB: 0,
            Keys.sortOption: DownloadSortOption.largestFirst.rawValue,
            Keys.keepWatchedDownloads: false,
        ])
        preferredFormat = defaults.string(forKey: Keys.preferredFormat) ?? DownloadFormat.original.rawValue
        wifiOnly = defaults.bool(forKey: Keys.wifiOnly)
        defaultDeleteWatched = defaults.bool(forKey: Keys.defaultDeleteWatched)
        defaultMaxStorageGB = defaults.integer(forKey: Keys.defaultMaxStorageGB)
        sortOption = defaults.string(forKey: Keys.sortOption)
            .flatMap(DownloadSortOption.init(rawValue:)) ?? .largestFirst
        keepWatchedDownloads = defaults.bool(forKey: Keys.keepWatchedDownloads)
    }

    /// The quality to actually request, given what the server offers right
    /// now. Falls back to `original`, which should always be available.
    func resolvedFormat(allowedFormats: [String]) -> String {
        if allowedFormats.contains(preferredFormat) {
            return preferredFormat
        }
        return DownloadFormat.original.rawValue
    }

    /// Bytes per gigabyte (GiB), shared by the storage-cap conversions.
    static let bytesPerGB: Int64 = 1_073_741_824

    var defaultMaxStorageBytes: Int64 {
        guard defaultMaxStorageGB > 0 else { return 0 }
        return Int64(defaultMaxStorageGB) * Self.bytesPerGB
    }

    private enum Keys {
        static let preferredFormat = "downloads.preferredFormat"
        static let wifiOnly = "downloads.wifiOnly"
        static let defaultDeleteWatched = "downloads.defaultDeleteWatched"
        static let defaultMaxStorageGB = "downloads.defaultMaxStorageGB"
        static let sortOption = "downloads.sortOption"
        static let keepWatchedDownloads = "downloads.keepWatchedDownloads"
    }
}
