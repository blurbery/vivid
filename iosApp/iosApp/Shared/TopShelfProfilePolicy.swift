import Foundation

enum TopShelfProfilePolicy {
    private struct SavedAccount: Decodable {
        let id: String
        let serverID: String
        let requiresLogin: Bool
        let pinEnabled: Bool?
    }

    static func allowsSavedAccountContent(
        accountsData: Data?, activeAccountID: String?, serverID: String?,
        hasStoredPIN: (String) -> Bool
    ) -> Bool {
        guard let accountsData,
              let accounts = try? JSONDecoder().decode([SavedAccount].self, from: accountsData),
              accounts.count == 1, let account = accounts.first,
              account.id == activeAccountID, account.serverID == serverID,
              !account.requiresLogin, account.pinEnabled != true,
              !hasStoredPIN(account.id) else { return false }
        return true
    }

    struct ViewingProfileCount: Codable, Equatable {
        let count: Int
        let accountEpoch: String
    }

    /// A Silo account with several viewing profiles has no single owner for
    /// the shelf, so only a recorded count of one, for the current account
    /// session, allows personalised rows. Emby and Jellyfin sign in as one
    /// native user, which is already the profile.
    static func allowsViewingProfileCount(
        countsData: Data?, serverID: String?, accountEpoch: String?
    ) -> Bool {
        guard let serverID else { return false }
        if serverID.hasPrefix("emby:") || serverID.hasPrefix("jellyfin:") { return true }
        guard let accountEpoch,
              let countsData,
              let counts = try? JSONDecoder().decode([String: ViewingProfileCount].self, from: countsData),
              let recorded = counts[serverID],
              recorded.accountEpoch == accountEpoch else { return false }
        return recorded.count == 1
    }


    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        serverID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        guard let serverID,
              let activeProfileID,
              let remembered = state.rememberedByServerID[serverID],
              state.behavior != .askEveryLaunch,
              !state.requiresSelectionAfterBackground(at: now),
              !state.selectionRequiredServerIDs.contains(serverID),
              remembered.profileID == activeProfileID,
              remembered.accountEpoch == accountEpoch,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return false
        }
        return true
    }
}
