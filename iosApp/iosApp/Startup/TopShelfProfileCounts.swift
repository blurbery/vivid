import Foundation
#if os(tvOS)
import TVServices
#endif

/// Records how many Silo viewing profiles the active account has, for the
/// Top Shelf rule in `TopShelfProfilePolicy`. Every profile list the app
/// reads goes through `AuthService.getProfiles`, which records it here, so
/// a server switch or a Settings read keeps the count current too.
enum TopShelfProfileCounts {
    /// Records the latest count and reports whether the stored value changed,
    /// so the caller can ask tvOS to reload the shelf.
    @discardableResult
    static func record(
        _ count: Int, serverID: String, accountEpoch: String, defaults: SharedDefaults
    ) -> Bool {
        var counts = defaults.data(forKey: SharedStorage.viewingProfileCountsKey)
            .flatMap { try? JSONDecoder().decode([String: TopShelfProfilePolicy.ViewingProfileCount].self, from: $0) } ?? [:]
        let entry = TopShelfProfilePolicy.ViewingProfileCount(count: count, accountEpoch: accountEpoch)
        guard counts[serverID] != entry else { return false }
        counts[serverID] = entry
        guard let data = try? JSONEncoder().encode(counts) else { return false }
        defaults.set(data, forKey: SharedStorage.viewingProfileCountsKey)
        return true
    }

    #if os(tvOS)
    /// The list belongs to the session that requested it: a sign-in that
    /// replaced the session while the request was in flight changes the
    /// credential generation, and that response is dropped rather than
    /// recorded against the new session. Emby and Jellyfin need no count.
    static func record(_ count: Int, for requestIdentity: RefreshAccountIdentity?) async {
        guard let requestIdentity,
              await TokenStore.shared.refreshAccountIdentity() == requestIdentity else { return }
        let serverID = requestIdentity.serverId
        guard !serverID.hasPrefix("emby:"), !serverID.hasPrefix("jellyfin:"),
              let accountEpoch = await TokenStore.shared.getOrCreateAccountEpoch(for: serverID) else { return }
        if record(count, serverID: serverID, accountEpoch: accountEpoch, defaults: .shared) {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
    }
    #endif
}
