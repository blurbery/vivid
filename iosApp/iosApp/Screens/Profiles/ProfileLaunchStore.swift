import Foundation
import Observation
import os
#if os(tvOS)
import TVServices
#endif

/// When Vivid asks which profile is watching, and which profile it last
/// used on each server. Every change is written straight back to shared
/// defaults; a change that can't be saved is undone, except clearing a
/// server's selection-required mark, which stays cleared in memory either way.
@Observable
final class ProfileLaunchPreferences {
    static let shared = ProfileLaunchPreferences()

    private(set) var state: ProfileLaunchState

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let persistenceOverride: ((ProfileLaunchState) -> Bool)?

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "ProfileLaunchPreferences"
    )

    init(defaults: SharedDefaults = .shared, persistenceOverride: ((ProfileLaunchState) -> Bool)? = nil) {
        self.defaults = defaults
        self.persistenceOverride = persistenceOverride
        state = ProfileLaunchState.load(from: defaults)
        save()
    }

    var behavior: ProfileLaunchBehavior {
        get { state.behavior }
        set {
            guard newValue != state.behavior else { return }
            let previous = state
            state.behavior = newValue
            if newValue == .automatic { state.backgroundedAt = nil }
            if !save() {
                state = previous
                save()
            }
        }
    }

    func rememberedProfile(for serverID: String?) -> RememberedProfile? {
        guard let serverID else { return nil }
        return state.rememberedByServerID[serverID]
    }

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        state.resolution(
            for: serverID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            now: now
        )
    }

    func requiresSelectionAfterBackground(at now: Date = .now) -> Bool {
        state.requiresSelectionAfterBackground(at: now)
    }

    @discardableResult
    func remember(profileID: String, requiresPIN: Bool, accountEpoch: String, for serverID: String) -> Bool {
        let previous = state
        state.rememberedByServerID[serverID] = RememberedProfile(
            profileID: profileID,
            requiredPINAtSelection: requiresPIN,
            accountEpoch: accountEpoch
        )
        state.selectionRequiredServerIDs.remove(serverID)
        state.backgroundedAt = nil
        return commit(undoingTo: previous)
    }

    @discardableResult
    func markBackgrounded(at date: Date = .now) -> Bool {
        guard state.behavior != .automatic else { return clearBackgroundedAt() }
        let previous = state
        state.backgroundedAt = date
        return commit(undoingTo: previous)
    }

    @discardableResult
    func clearBackgroundedAt() -> Bool {
        guard state.backgroundedAt != nil else { return true }
        let previous = state
        state.backgroundedAt = nil
        return commit(undoingTo: previous)
    }

    @discardableResult
    func markSelectionRequired(for serverID: String) -> Bool {
        guard !state.selectionRequiredServerIDs.contains(serverID) else { return true }
        let previous = state
        state.selectionRequiredServerIDs.insert(serverID)
        return commit(undoingTo: previous)
    }

    func clearSelectionRequired(for serverID: String) {
        guard state.selectionRequiredServerIDs.remove(serverID) != nil else { return }
        save()
    }

    @discardableResult
    func clearRememberedProfile(for serverID: String) -> Bool {
        let previous = state
        let hadProfile = state.rememberedByServerID.removeValue(forKey: serverID) != nil
        let hadMark = state.selectionRequiredServerIDs.remove(serverID) != nil
        guard hadProfile || hadMark else { return true }
        return commit(undoingTo: previous)
    }

    /// Carries a profile remembered by an older registry entry into the
    /// launch state. True when the server ends up remembering that profile.
    @discardableResult
    func migrateLegacyProfile(profileID: String?, requiresPIN: Bool, accountEpoch: String?, for serverID: String) -> Bool {
        if let existing = state.rememberedByServerID[serverID] {
            return existing.profileID == profileID && existing.accountEpoch == accountEpoch
        }
        guard let profileID, !profileID.isEmpty, let accountEpoch, !accountEpoch.isEmpty else { return false }
        return remember(profileID: profileID, requiresPIN: requiresPIN, accountEpoch: accountEpoch, for: serverID)
    }

    // MARK: Saving

    private func commit(undoingTo previous: ProfileLaunchState) -> Bool {
        guard save() else {
            state = previous
            return false
        }
        return true
    }

    /// Writes the state and reads it back. False when nothing was written
    /// or the stored bytes don't match.
    @discardableResult
    private func save() -> Bool {
        if let persistenceOverride, !persistenceOverride(state) { return false }
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            Self.logger.error("Profile launch state encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let key = SharedStorage.profileLaunchStateKey
        #if os(tvOS)
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ProfileLaunchState.self, from: $0) }
        #endif
        defaults.set(data, forKey: key)
        let saved = defaults.data(forKey: key) == data
        #if os(tvOS)
        if saved, stored != state {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
        #endif
        return saved
    }
}
