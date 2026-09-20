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
