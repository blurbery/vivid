import Foundation
import Observation

/// Whether Search also looks in the other saved profiles. Kept on this
/// device only, and on until turned off.
///
/// Saved in the app's standard defaults, like the appearance theme: it
/// isn't a server or profile setting, the Top Shelf never reads it, and
/// iCloud preference sync leaves it alone. On Apple TV the standard
/// defaults belong to the native tvOS user, as the saved profiles do.
@Observable
@MainActor
final class OtherProfileSearchSettings {
    static let shared = OtherProfileSearchSettings()

    // Keep this key stable across app versions.
    static let storageKey = "vivid.search.otherProfiles.v1"

    @ObservationIgnored private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Nothing saved yet means on; `bool(forKey:)` would read that as off.
        isEnabled = defaults.object(forKey: Self.storageKey) as? Bool ?? true
    }
}
