import Foundation

/// The saved profile-launch choices. Stored as JSON under
/// `SharedStorage.profileLaunchStateKey` and read by the Top Shelf extension.
struct ProfileLaunchState: Codable, Equatable, Sendable {
    var behavior: ProfileLaunchBehavior = .automatic
    var rememberedByServerID: [String: RememberedProfile] = [:]
    var selectionRequiredServerIDs: Set<String> = []
    var backgroundedAt: Date? = nil

    static func load(from defaults: SharedDefaults) -> ProfileLaunchState {
        guard let data = defaults.data(forKey: SharedStorage.profileLaunchStateKey),
              let state = try? JSONDecoder().decode(ProfileLaunchState.self, from: data)
        else { return ProfileLaunchState() }
        return state
    }

    /// True once the app has been away for at least the behaviour's timeout.
    func awayIntervalHasExpired(at now: Date) -> Bool {
        guard let backgroundedAt, let timeout = behavior.awayTimeout else { return false }
        return now.timeIntervalSince(backgroundedAt) >= timeout
    }

    /// Whether a cold launch has to show the profile picker, before any
    /// per-server rule is considered.
    func requiresSelectionAtLaunch(at now: Date) -> Bool {
        behavior == .askEveryLaunch || awayIntervalHasExpired(at: now)
    }

    /// Whether returning from the background has to show the profile picker.
    /// It never does without a background marker.
    func requiresSelectionAfterBackground(at now: Date = .now) -> Bool {
        guard backgroundedAt != nil else { return false }
        return behavior == .askEveryLaunch || awayIntervalHasExpired(at: now)
    }

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        guard !requiresSelectionAtLaunch(at: now),
              !selectionRequiredServerIDs.contains(serverID),
              let remembered = rememberedByServerID[serverID],
              let accountEpoch, accountEpoch == remembered.accountEpoch,
              !remembered.profileID.isEmpty,
              knownProfileIDs?.contains(remembered.profileID) ?? true,
              !remembered.requiredPINAtSelection || hasStoredProfileToken
        else { return .needsSelection }
        return .restore(remembered)
    }
}
