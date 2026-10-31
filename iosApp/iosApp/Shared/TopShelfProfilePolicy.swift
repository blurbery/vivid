import Foundation

/// Decides whether the Top Shelf may show one viewer's own rows. It shows them
/// only when there's no doubt about who is watching.
enum TopShelfProfilePolicy {
    /// The parts of a saved account row this policy reads. Other keys the
    /// account store writes are ignored.
    private struct SavedAccountRow: Decodable {
        let id: String
        let serverID: String
        let requiresLogin: Bool
        let pinEnabled: Bool?
    }

    /// True only for a single saved account that is the active one, is signed
    /// in and has no PIN of any kind.
    static func allowsSavedAccountContent(
        accountsData: Data?,
        activeAccountID: String?,
        serverID: String?,
        hasStoredPIN: (String) -> Bool
    ) -> Bool {
        guard let accountsData,
              let rows = try? JSONDecoder().decode([SavedAccountRow].self, from: accountsData),
              rows.count == 1, let row = rows.first,
              row.id == activeAccountID, row.serverID == serverID,
              !row.requiresLogin, row.pinEnabled != true
        else { return false }
        return !hasStoredPIN(row.id)
    }

    /// How many viewing profiles a Silo account had when it was last checked.
    struct ViewingProfileCount: Codable, Equatable {
        let count: Int
        let accountEpoch: String
    }

    /// Emby and Jellyfin accounts have no viewing profiles to choose between.
    /// A Silo account must be known to have exactly one, under this account.
    static func allowsViewingProfileCount(countsData: Data?, serverID: String?, accountEpoch: String?) -> Bool {
        guard let serverID else { return false }
        if serverID.hasPrefix("emby:") || serverID.hasPrefix("jellyfin:") { return true }
        guard let accountEpoch, let countsData,
              let counts = try? JSONDecoder().decode([String: ViewingProfileCount].self, from: countsData),
              let entry = counts[serverID]
        else { return false }
        return entry.accountEpoch == accountEpoch && entry.count == 1
    }

    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        serverID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        guard let serverID, let activeProfileID,
              let remembered = state.rememberedByServerID[serverID],
              state.behavior != .askEveryLaunch,
              !state.requiresSelectionAfterBackground(at: now),
              !state.selectionRequiredServerIDs.contains(serverID),
              remembered.profileID == activeProfileID,
              let accountEpoch, remembered.accountEpoch == accountEpoch
        else { return false }
        return !remembered.requiredPINAtSelection || hasStoredProfileToken
    }
}
