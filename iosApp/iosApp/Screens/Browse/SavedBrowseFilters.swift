import Foundation

/// Each library's remembered sort and filters, per server and profile.
/// The keys sync through iCloud, so their format must stay as it is.
struct BrowsePrefsStore {
    static let shared = BrowsePrefsStore()

    private let defaults: SharedDefaults

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    func preserveEnabled(libraryId: Int?, mediaScope: String? = nil) -> Bool {
        guard let stem = keyStem(libraryId: libraryId, mediaScope: mediaScope) else { return true }
        if mediaScope != nil {
            adoptUnscopedSettings(into: stem, libraryId: libraryId)
        }
        let key = stem + ".preserve"
        return defaults.containsObject(forKey: key) ? defaults.bool(forKey: key) : true
    }

    func setPreserveEnabled(_ enabled: Bool, libraryId: Int?, mediaScope: String? = nil) {
        guard let stem = keyStem(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.set(enabled, forKey: stem + ".preserve")
        if !enabled {
            clearState(libraryId: libraryId, mediaScope: mediaScope)
        }
    }

    func savedState(libraryId: Int?, mediaScope: String? = nil) -> CatalogFilterState? {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let stem = keyStem(libraryId: libraryId, mediaScope: mediaScope),
              let data = defaults.data(forKey: stem + ".state"),
              let stored = try? JSONDecoder().decode(CatalogFilterState.self, from: data) else { return nil }
        let state = stored.normalized(for: .active)
        if state != stored {
            saveState(state, libraryId: libraryId, mediaScope: mediaScope)
        }
        return state
    }

    func saveState(_ state: CatalogFilterState, libraryId: Int?, mediaScope: String? = nil) {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let stem = keyStem(libraryId: libraryId, mediaScope: mediaScope) else { return }
        // The letter jump is for this visit only.
        var stored = state
        stored.namePrefix = nil
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: stem + ".state")
    }

    func clearState(libraryId: Int?, mediaScope: String? = nil) {
        guard let stem = keyStem(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.removeObject(forKey: stem + ".state")
    }

    // MARK: Keys

    private static let prefix = "vivid.browsePrefs"

    #if os(tvOS)
    private static let legacyPrefix = "tv.browsePrefs"
    #else
    private static let legacyPrefix = "ios.browsePrefs"
    #endif

    /// Nil while no profile is chosen, so nothing is read or written.
    private func keyStem(libraryId: Int?, mediaScope: String?) -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        let server = ServerRegistry.shared.activeServerId ?? "default"
        var scope = "\(server).\(profileId).\(libraryId.map(String.init) ?? "all")"
        if let mediaScope { scope += ".\(mediaScope)" }
        let stem = "\(Self.prefix).\(scope)"
        moveLegacyKeys(to: stem, from: "\(Self.legacyPrefix).\(scope)")
        return stem
    }

    /// Moves settings saved under the old per-platform prefix, once.
    private func moveLegacyKeys(to stem: String, from legacy: String) {
        let marker = stem + ".migrated"
        guard !defaults.bool(forKey: marker) else { return }
        let preserveKey = stem + ".preserve"
        let legacyPreserveKey = legacy + ".preserve"
        if !defaults.containsObject(forKey: preserveKey), defaults.containsObject(forKey: legacyPreserveKey) {
            defaults.set(defaults.bool(forKey: legacyPreserveKey), forKey: preserveKey)
        }
        let stateKey = stem + ".state"
        if !defaults.containsObject(forKey: stateKey), let data = defaults.data(forKey: legacy + ".state") {
            defaults.set(data, forKey: stateKey)
        }
        defaults.removeObject(forKey: legacyPreserveKey)
        defaults.removeObject(forKey: legacy + ".state")
        defaults.set(true, forKey: marker)
    }

    /// A library first opened with a media scope starts from what was saved
    /// for the library as a whole.
    private func adoptUnscopedSettings(into stem: String, libraryId: Int?) {
        let preserveKey = stem + ".preserve"
        guard !defaults.containsObject(forKey: preserveKey) else { return }
        let preserve = preserveEnabled(libraryId: libraryId)
        defaults.set(preserve, forKey: preserveKey)
        guard preserve, var state = savedState(libraryId: libraryId) else { return }
        state.mediaScope = nil
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stem + ".state")
    }
}
