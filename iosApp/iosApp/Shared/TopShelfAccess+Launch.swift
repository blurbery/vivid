import Foundation

/// The launch rules, and the whole decision for one viewer. Kept apart from
/// `TopShelfAccess.swift` because these need the profile-launch types.
extension TopShelfAccess {
    /// Everything shared storage says about the viewer at one moment. The
    /// extension compares two of these to notice a change during a load.
    struct Snapshot: Equatable, Sendable {
        var serverID: String?
        var activeProfileID: String?
        var activeSavedAccountID: String?
        var accountEpoch: String?
        var savedAccountsData: Data?
        var viewingProfilesData: Data?
        var launchState: ProfileLaunchState
    }

    /// Refuses unless opening Vivid now would go straight to `profileID`
    /// without asking who's watching.
    static func launchRefusal(
        state: ProfileLaunchState,
        serverID: String,
        profileID: String?,
        accountEpoch: String?,
        now: Date
    ) -> Refusal? {
        if state.behavior == .askEveryLaunch { return .launchAsks }
        if state.requiresSelectionAfterBackground(at: now) { return .awayLock }
        if state.selectionRequiredServerIDs.contains(serverID) { return .choicePending }
        guard let remembered = state.rememberedByServerID[serverID],
              let profileID, !profileID.isEmpty
        else { return .profileNotRemembered }
        if remembered.profileID != profileID { return .profileChanged }
        guard let accountEpoch, remembered.accountEpoch == accountEpoch else { return .accountChanged }
        // A stored proof lets the app reopen a PIN profile, but the shelf is
        // on show before anyone has entered anything.
        if remembered.requiredPINAtSelection { return .viewingProfileLocked }
        return nil
    }

    /// The first rule the viewer in `snapshot` fails, or nil when their rows
    /// may be shown.
    static func refusal(for snapshot: Snapshot, hasStoredPIN: (String) -> Bool, now: Date) -> Refusal? {
        guard let serverID = snapshot.serverID else { return .noActiveServer }
        if let refusal = savedProfileRefusal(
            accountsData: snapshot.savedAccountsData,
            activeAccountID: snapshot.activeSavedAccountID,
            serverID: serverID,
            hasStoredPIN: hasStoredPIN
        ) { return refusal }
        if let refusal = launchRefusal(
            state: snapshot.launchState,
            serverID: serverID,
            profileID: snapshot.activeProfileID,
            accountEpoch: snapshot.accountEpoch,
            now: now
        ) { return refusal }
        // The launch rules have already required an active profile.
        guard let profileID = snapshot.activeProfileID else { return .profileNotRemembered }
        return viewingProfileRefusal(
            recordsData: snapshot.viewingProfilesData,
            serverID: serverID,
            profileID: profileID,
            accountEpoch: snapshot.accountEpoch
        )
    }
}
