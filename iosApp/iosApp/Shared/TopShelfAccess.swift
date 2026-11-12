import Foundation

/// Who the Apple TV Top Shelf may show rows for. The shelf sits on the Home
/// Screen where anyone can see it, so it only shows the viewer Vivid would
/// open as right now, and never one who is behind a PIN. The app and the
/// extension both compile this file, which keeps to Foundation so the rules
/// can be checked on their own.
enum TopShelfAccess {
    /// Why the shelf stays on its static artwork. The raw values go into the
    /// diagnostics status, so they hold nothing about the viewer.
    enum Refusal: String, Error, Equatable, Sendable {
        case noActiveServer = "no-server"
        case savedProfileMissing = "saved-profile-missing"
        case savedProfileSignedOut = "saved-profile-signed-out"
        case savedProfileLocked = "saved-profile-locked"
        case launchAsks = "launch-asks"
        case awayLock = "away-lock"
        case choicePending = "choice-pending"
        case profileNotRemembered = "profile-not-remembered"
        case profileChanged = "profile-changed"
        case accountChanged = "account-changed"
        case viewingProfileLocked = "viewing-profile-locked"
        case viewingProfilesUnknown = "viewing-profiles-unknown"
    }

    /// One Silo account's viewing profiles, as last read by the app.
    struct ViewingProfiles: Codable, Equatable, Sendable {
        let accountEpoch: String
        let profileIDs: [String]
        let lockedProfileIDs: [String]
    }

    /// Emby and Jellyfin servers carry their provider in the server ID. They
    /// have no Silo viewing profiles.
    static func isNativeServer(_ serverID: String) -> Bool {
        serverID.hasPrefix("emby:") || serverID.hasPrefix("jellyfin:")
    }

    /// Checks the saved profile that is active on this Apple TV. How many
    /// other saved profiles exist doesn't matter: only the active one is
    /// ever shown.
    ///
    /// `accountsData` is the JSON array stored under
    /// `SharedStorage.savedAccountsKey`. `hasStoredPIN` answers whether a
    /// saved profile has a PIN in the Keychain.
    static func savedProfileRefusal(
        accountsData: Data?,
        activeAccountID: String?,
        serverID: String,
        hasStoredPIN: (String) -> Bool
    ) -> Refusal? {
        guard let accountsData, let activeAccountID,
              let rows = try? JSONDecoder().decode([SavedProfileRow].self, from: accountsData),
              let active = rows.first(where: { $0.id == activeAccountID }),
              active.serverID == serverID
        else { return .savedProfileMissing }
        if active.requiresLogin { return .savedProfileSignedOut }
        // Older rows carry no flag, so the Keychain is asked as well.
        if active.pinEnabled == true || hasStoredPIN(active.id) { return .savedProfileLocked }
        return nil
    }

    /// Checks the Silo viewing profile against the list the app last read
    /// for this account. A list that is missing, or that belongs to another
    /// sign-in, can't show the profile is free of a PIN, so it refuses.
    ///
    /// `recordsData` is the JSON object stored under
    /// `SharedStorage.topShelfViewingProfilesKey`, keyed by server ID.
    static func viewingProfileRefusal(
        recordsData: Data?,
        serverID: String,
        profileID: String,
        accountEpoch: String?
    ) -> Refusal? {
        if isNativeServer(serverID) { return nil }
        guard let recordsData, let accountEpoch,
              let records = try? JSONDecoder().decode([String: ViewingProfiles].self, from: recordsData),
              let record = records[serverID],
              record.accountEpoch == accountEpoch,
              record.profileIDs.contains(profileID)
        else { return .viewingProfilesUnknown }
        if record.lockedProfileIDs.contains(profileID) { return .viewingProfileLocked }
        return nil
    }

    /// The parts of a saved profile the rules read. The app stores more keys
    /// in each row, and the decoder skips them.
    private struct SavedProfileRow: Decodable {
        let id: String
        let serverID: String
        let requiresLogin: Bool
        let pinEnabled: Bool?
    }
}
