import Foundation

/// One Top Shelf run: decide whether the current viewer may be shown, fetch
/// their rows, and make sure they're still the viewer before handing the rows
/// back. Every run leaves a status behind for diagnostics.
struct ShelfLoad {
    var storage = ShelfStorage()
    var now: @Sendable () -> Date = { Date() }

    /// The rows to show, or nil when the shelf should keep its static artwork.
    func run() async -> ShelfFeed? {
        storage.noteRun(at: now())
        let outcome = await outcome()
        storage.note(outcome)
        guard case .loaded(let feed) = outcome, !feed.isEmpty else { return nil }
        return feed
    }

    private func outcome() async -> ShelfOutcome {
        let viewer = storage.viewer()
        if let refusal = storage.refusal(for: viewer, now: now()) { return .refused(refusal) }
        // The access rules have already required both of these.
        guard let serverID = viewer.access.serverID, let profileID = viewer.access.activeProfileID else {
            return .refused(.noActiveServer)
        }
        do {
            let feed: ShelfFeed
            if TopShelfAccess.isNativeServer(serverID) {
                feed = try await nativeFeed(serverID: serverID, profileID: profileID, serverURL: viewer.serverURL)
            } else {
                feed = try await siloFeed(serverID: serverID, profileID: profileID, serverURL: viewer.serverURL)
            }
            // Fetching takes seconds. If anyone switched profile, signed out
            // or locked up in that time, these rows belong to someone else.
            let latest = storage.viewer()
            guard latest.isSameViewer(as: viewer), storage.refusal(for: latest, now: now()) == nil else {
                return .changedDuringLoad
            }
            return .loaded(feed)
        } catch {
            return ShelfOutcome(error: error)
        }
    }

    private func nativeFeed(serverID: String, profileID: String, serverURL: String?) async throws -> ShelfFeed {
        // On Emby and Jellyfin the active profile is the server user, so the
        // stored sign-in has to be that same user's.
        guard storage.nativeUserID(for: serverID) == profileID,
              let token = storage.accessToken(for: serverID),
              let serverURL
        else { throw ShelfFailure.nativeIdentity }
        let client = TopShelfNativeClient(
            provider: serverID.hasPrefix("emby:") ? .emby : .jellyfin,
            serverURL: serverURL,
            userID: profileID,
            token: token
        )
        return try await client.fetchHomeSections()
    }

    private func siloFeed(serverID: String, profileID: String, serverURL: String?) async throws -> ShelfFeed {
        guard let token = storage.accessToken(for: serverID), let serverURL else {
            throw ShelfFailure.signedOut
        }
        let source = SiloShelfSource(
            server: serverURL,
            accessToken: token,
            profileID: profileID,
            profileToken: storage.profileToken(for: serverID),
            // Only read if the server turns the access token down.
            refreshToken: { [storage] in storage.refreshToken(for: serverID) },
            stillAllowed: { [storage, now] in storage.refusal(for: storage.viewer(), now: now()) == nil }
        )
        return try await source.fetchFeed()
    }
}
