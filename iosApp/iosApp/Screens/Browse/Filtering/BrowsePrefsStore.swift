import Foundation

/// Per-library, per-profile persistence of browse sort + filters, gated by a
/// user-facing "Preserve sort & filters" toggle (default on). Mirrors the
/// `TVLibraryScopeStore` pattern: `SharedDefaults`
/// keyed by server + profile + library on iOS and tvOS for iCloud sync.
/// Other profiles and anonymous sessions remain isolated.
struct BrowsePrefsStore {
    static let shared = BrowsePrefsStore()

    private let defaults: SharedDefaults

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    /// Whether sort + filters are remembered for this library. Default true.
    func preserveEnabled(libraryId: Int?, mediaScope: String? = nil) -> Bool {
        migrateScopeIfNeeded(libraryId: libraryId, mediaScope: mediaScope)
        guard let key = preserveKey(libraryId: libraryId, mediaScope: mediaScope) else { return true }
        guard defaults.containsObject(forKey: key) else { return true }
        return defaults.bool(forKey: key)
    }

    /// Set the preserve preference. Turning it off also drops any saved state.
    func setPreserveEnabled(_ enabled: Bool, libraryId: Int?, mediaScope: String? = nil) {
        guard let key = preserveKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.set(enabled, forKey: key)
        if !enabled { clearState(libraryId: libraryId, mediaScope: mediaScope) }
    }

    /// The saved state for a library, or `nil` when preserve is off or
    /// nothing is stored.
    func savedState(libraryId: Int?, mediaScope: String? = nil) -> CatalogFilterState? {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let key = stateKey(libraryId: libraryId, mediaScope: mediaScope),
              let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(CatalogFilterState.self, from: data)
        else { return nil }
        let normalised = state.normalised(for: MediaServerProvider.active)
        if normalised != state {
            saveState(normalised, libraryId: libraryId, mediaScope: mediaScope)
        }
        return normalised
    }

    /// Persist the committed state (minus the transient A–Z `namePrefix`).
    /// No-op when preserve is off.
    func saveState(_ state: CatalogFilterState, libraryId: Int?, mediaScope: String? = nil) {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let key = stateKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        var toSave = state
        toSave.namePrefix = nil
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        defaults.set(data, forKey: key)
    }

    func clearState(libraryId: Int?, mediaScope: String? = nil) {
        guard let key = stateKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.removeObject(forKey: key)
    }

    private func migrateScopeIfNeeded(libraryId: Int?, mediaScope: String?) {
        guard let mediaScope,
              let targetPreserve = preserveKey(libraryId: libraryId, mediaScope: mediaScope),
              !defaults.containsObject(forKey: targetPreserve),
              let targetState = stateKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        let enabled = preserveEnabled(libraryId: libraryId)
        defaults.set(enabled, forKey: targetPreserve)
        if enabled, var legacy = savedState(libraryId: libraryId) {
            legacy.mediaScope = nil
            if let data = try? JSONEncoder().encode(legacy) {
                defaults.set(data, forKey: targetState)
            }
        }
    }

    // MARK: - Keys

    private func base(libraryId: Int?, mediaScope: String? = nil) -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        let lib = libraryId.map(String.init) ?? "all"
        let scope = mediaScope.map { ".\($0)" } ?? ""
        let key = "\(Self.platformPrefix).\(serverId).\(profileId).\(lib)\(scope)"
        #if os(iOS) || os(tvOS)
        #if os(tvOS)
        let legacyPrefix = "tv.browsePrefs"
        #else
        let legacyPrefix = "ios.browsePrefs"
        #endif
        let legacy = "\(legacyPrefix).\(serverId).\(profileId).\(lib)\(scope)"
        let marker = key + ".migrated"
        if !defaults.bool(forKey: marker) {
            if !defaults.containsObject(forKey: key + ".preserve"), defaults.containsObject(forKey: legacy + ".preserve") {
                defaults.set(defaults.bool(forKey: legacy + ".preserve"), forKey: key + ".preserve")
            }
            if !defaults.containsObject(forKey: key + ".state"), let data = defaults.data(forKey: legacy + ".state") {
                defaults.set(data, forKey: key + ".state")
            }
            defaults.removeObject(forKey: legacy + ".state")
            defaults.removeObject(forKey: legacy + ".preserve")
            defaults.set(true, forKey: marker)
        }
        #endif
        return key
    }

    private func stateKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        base(libraryId: libraryId, mediaScope: mediaScope).map { "\($0).state" }
    }

    private func preserveKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        base(libraryId: libraryId, mediaScope: mediaScope).map { "\($0).preserve" }
    }

    private static var platformPrefix: String {
        #if os(tvOS) || os(iOS)
        "vivid.browsePrefs"
        #elseif os(macOS)
        "mac.browsePrefs"
        #else
        "apple.browsePrefs"
        #endif
    }
}
