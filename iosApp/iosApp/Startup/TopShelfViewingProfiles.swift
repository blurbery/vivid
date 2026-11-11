import Foundation
#if os(tvOS)
import TVServices
#endif

/// Keeps the Top Shelf's copy of each Silo account's viewing profiles. The
/// extension can't ask the server who has a PIN before it decides whether to
/// show anything, so the app saves the answer whenever it loads the list.
enum TopShelfViewingProfiles {
    /// Saves the record for `serverID`, removes the legacy count, and reports whether the stored value changed.
    @discardableResult
    static func record(_ record: TopShelfAccess.ViewingProfiles, serverID: String, defaults: SharedDefaults) -> Bool {
        // Earlier builds stored only how many profiles there were.
        defaults.removeObject(forKey: SharedStorage.legacyViewingProfileCountsKey)

        let key = SharedStorage.topShelfViewingProfilesKey
        var records = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: TopShelfAccess.ViewingProfiles].self, from: $0) } ?? [:]
        guard records[serverID] != record else { return false }
        records[serverID] = record
        guard let data = try? JSONEncoder().encode(records) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    #if os(tvOS)
    /// Saves the list a profile request returned. `requestIdentity` is the
    /// account that was signed in when the request started.
    static func record(_ profiles: [UserProfile], for requestIdentity: RefreshAccountIdentity?) async {
        let tokens = TokenStore.shared
        // A list that arrives after a sign-out or server switch belongs to
        // someone else, and must not be saved against the current account.
        guard let requestIdentity, await tokens.refreshAccountIdentity() == requestIdentity else { return }
        let serverID = requestIdentity.serverId
        guard !TopShelfAccess.isNativeServer(serverID),
              let epoch = await tokens.getOrCreateAccountEpoch(for: serverID)
        else { return }
        let viewingProfiles = TopShelfAccess.ViewingProfiles(
            accountEpoch: epoch,
            profileIDs: profiles.map(\.id),
            lockedProfileIDs: profiles.filter(\.hasPin).map(\.id)
        )
        if record(viewingProfiles, serverID: serverID, defaults: .shared) {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }
    #endif
}
