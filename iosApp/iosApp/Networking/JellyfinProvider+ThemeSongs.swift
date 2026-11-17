import Foundation

// Theme songs on Jellyfin: `GET /Items/{id}/ThemeSongs` finds a title's song
// and `/Audio/{id}/stream` downloads it to a temporary file that plays. Both
// are optional, so any failure is nil and a refusal (even a 401) never signs
// anyone out. The reply and
// container rules are shared with Emby (`ServerThemeSongFormat` in
// `EmbyProvider+ThemeSongs.swift`).

enum JellyfinThemeMusic {
    static func lookup(for item: ThemeMusicItem) async -> ThemeSongLookup? {
        guard let connection = try? await JellyfinConnection.current() else { return nil }
        return await lookup(for: item, connection: connection)
    }

    /// The connection adds the account's own `UserId` to the query.
    static func lookup(for item: ThemeMusicItem, connection: JellyfinConnection) async -> ThemeSongLookup? {
        guard let itemID = try? JellyfinConnection.id(item.contentID) else { return nil }
        let query = lookupQuery(for: item)
        let data = await ServerThemeSongFormat.withDeadline {
            await connection.optionalData("/Items/\(itemID)/ThemeSongs", query: query)
        }
        guard let data, let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ServerThemeSongFormat.lookup(from: reply, item: item) { try? JellyfinConnection.id($0) }
    }

    /// Only seasons and episodes inherit: a movie or series without a theme
    /// would otherwise pick up one from the folders above it.
    static func lookupQuery(for item: ThemeMusicItem) -> [String: String] {
        ["inheritFromParent": item.inheritsFromParent ? "true" : "false"]
    }

    static func stream(for lookup: ThemeSongLookup) async -> ThemeSongStream? {
        guard let connection = try? await JellyfinConnection.current() else { return nil }
        return await stream(for: lookup, connection: connection)
    }

    /// The song downloaded with this account's authorisation header (the
    /// token never goes in the URL) and played from a temporary file. Like
    /// the lookup, a refusal never signs anyone out.
    static func stream(for lookup: ThemeSongLookup, connection: JellyfinConnection) async -> ThemeSongStream? {
        guard let id = try? JellyfinConnection.id(lookup.songID) else { return nil }
        return await ServerThemeSongFormat.download(ServerThemeSongFormat.attempts(for: lookup.container)) { attempt in
            let route = JellyfinThemeMusic.streamRoute(songID: id, request: attempt)
            guard let reply = await connection.optionalFile(
                route.path, query: route.query, maximumBytes: ThemeSongFiles.maximumBytes) else { return nil }
            return ServerThemeSongDownload(data: reply.data, contentType: reply.contentType)
        }
    }

    /// The original file (`static=true`), named with its container when
    /// known, or an mp3 conversion. Not `/universal`, which answers with a
    /// redirect the connection refuses. `songID` must already be checked
    /// with `JellyfinConnection.id`.
    static func streamRoute(songID: String, request: ServerThemeSongFormat.Request) -> (path: String, query: [String: String]) {
        switch request {
        case .original(let ext?): ("/Audio/\(songID)/stream.\(ext)", ["static": "true"])
        case .original(nil): ("/Audio/\(songID)/stream", ["static": "true"])
        case .mp3: ("/Audio/\(songID)/stream.mp3", ["audioCodec": "mp3"])
        }
    }

    /// The first song URL tried for a container. The connection also adds
    /// the account's `UserId` when it sends it.
    static func streamURL(serverURL: String, songID: String, container: String?) throws -> URL {
        let route = streamRoute(songID: try JellyfinConnection.id(songID), request: ServerThemeSongFormat.request(for: container))
        return try JellyfinConnection.url(serverURL: serverURL, path: route.path, query: route.query)
    }
}
