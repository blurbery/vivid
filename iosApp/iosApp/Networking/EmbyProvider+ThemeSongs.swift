import Foundation

// Theme songs on Emby: `GET /Items/{id}/ThemeSongs` finds a title's song and
// `/Audio/{id}/stream` downloads it to a temporary file that plays. Both are
// optional: a lookup that gets no answer reports `.failed`, a song that
// can't be opened is nil, and a refusal (even a 401) never signs anyone out.
// The format rules below are shared with Jellyfin, which answers in the same
// shape.

/// How Emby and Jellyfin theme songs are read and requested. Both servers
/// return `{ Items, TotalRecordCount, OwnerId }` and serve the file from
/// `/Audio/{id}/stream`, so the rules live here once.
enum ServerThemeSongFormat {
    /// Containers `AVPlayer` plays as they are.
    static let playable: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "mov", "aac", "alac", "flac", "wav", "caf", "aif", "aiff",
    ]

    /// How to ask for the song.
    enum Request: Equatable, Sendable {
        /// The original file, named with its container when known.
        case original(extension: String?)
        /// An mp3 conversion, for a container `AVPlayer` can't play.
        case mp3
    }

    static func request(for container: String?) -> Request {
        guard let container, !container.isEmpty else { return .original(extension: nil) }
        return playable.contains(container) ? .original(extension: container) : .mp3
    }

    /// The requests to try in turn. With no container named, the original
    /// comes first and the mp3 conversion is asked for only when the
    /// original turns out not to be a format `AVPlayer` plays.
    static func attempts(for container: String?) -> [Request] {
        let first = request(for: container)
        return first == .original(extension: nil) ? [first, .mp3] : [first]
    }

    /// The format a request's reply is in, when the request names it.
    static func container(of request: Request) -> String? {
        switch request {
        case .original(let ext): ext
        case .mp3: "mp3"
        }
    }

    /// Downloads the song through the account's connection and keeps it as a
    /// temporary file, so `AVPlayer` needs no headers and knows the length.
    /// A failed, refused or oversized download is nil. The caller puts every
    /// attempt under one ``ThemeSongFiles/openSeconds`` deadline.
    static func download(
        _ attempts: [Request],
        fetch: @escaping @Sendable (Request) async -> ServerThemeSongDownload?
    ) async -> ThemeSongStream? {
        for attempt in attempts {
            guard let reply = await fetch(attempt), !Task.isCancelled else { return nil }
            // An unnamed container that isn't a playable format moves on to the conversion.
            guard let ext = container(of: attempt)
                    ?? ThemeSongFiles.fileExtension(contentType: reply.contentType, data: reply.data)
            else { continue }
            guard let url = ThemeSongFiles.store(reply.data, fileExtension: ext) else { return nil }
            return ThemeSongStream(url: url, headers: [:])
        }
        return nil
    }

    /// The container to keep: lowercased, and from a comma list such as
    /// Jellyfin's "mov,mp4,m4a" the first playable name, else the first
    /// name. Only plain letters and digits count, so the result can go into
    /// a path; nil when the server named none.
    static func container(_ raw: String?) -> String? {
        let names = (raw ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII } }
        return names.first { playable.contains($0) } ?? names.first
    }

    /// The song's container: its own `Container`, else its first media
    /// source's.
    static func container(of song: [String: Any]) -> String? {
        if let own = container(song["Container"] as? String) { return own }
        let source = (song["MediaSources"] as? [[String: Any]])?.first
        return container(source?["Container"] as? String)
    }

    /// `OwnerId` as text: Emby sends a number and Jellyfin a GUID string.
    /// A missing, zero or all-zero value (and anything else) means the
    /// title itself.
    static func ownerID(_ raw: Any?, fallback: String) -> String {
        let text: String?
        switch raw {
        case let string as String:
            text = string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            text = number.stringValue
        default:
            text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              !text.allSatisfy({ $0 == "0" || $0 == "-" })
        else { return fallback }
        return text
    }

    /// What a `ThemeSongs` reply says: its first song, `.none` when its
    /// `Items` list is empty, and `.failed` when the reply is unreadable (not
    /// a JSON object, no `Items` list, or a first song without a usable ID).
    /// `validID` returns the song's ID when it's safe to put in a path.
    static func lookup(from data: Data, item: ThemeMusicItem, validID: (String) -> String?) -> ThemeSongLookupResult {
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = reply["Items"] as? [Any]
        else { return .failed }
        guard let first = items.first else { return .none }
        guard let song = first as? [String: Any],
              let rawID = song["Id"] as? String,
              let songID = validID(rawID)
        else { return .failed }
        return .found(ThemeSongLookup(
            ownerID: ownerID(reply["OwnerId"], fallback: item.contentID),
            songID: songID,
            container: container(of: song)))
    }

    /// How long a `ThemeSongs` lookup may take.
    static let lookupSeconds: Double = 4

    /// A lookup through the connection's optional GET, which is nil for a
    /// timeout, a network error or any non-2xx answer (a 401 included, and
    /// without signing out). Those are `.failed`; only a 2xx reply can say
    /// `.none`.
    static func lookup(
        item: ThemeMusicItem,
        validID: (String) -> String?,
        fetch: @escaping @Sendable () async -> Data?
    ) async -> ThemeSongLookupResult {
        guard let data = await ThemeSongFiles.withDeadline(seconds: lookupSeconds, fetch) else { return .failed }
        return lookup(from: data, item: item, validID: validID)
    }
}

enum EmbyThemeMusic {
    static func lookup(for item: ThemeMusicItem) async -> ThemeSongLookupResult {
        guard let connection = try? await EmbyConnection.current() else { return .failed }
        return await lookup(for: item, connection: connection)
    }

    static func lookup(for item: ThemeMusicItem, connection: EmbyConnection) async -> ThemeSongLookupResult {
        guard let itemID = try? EmbyConnection.id(item.contentID), let userID = connection.userID else { return .failed }
        let query = lookupQuery(for: item, userID: userID)
        return await ServerThemeSongFormat.lookup(item: item, validID: { try? EmbyConnection.id($0) }) {
            await connection.optionalData("/Items/\(itemID)/ThemeSongs", query: query)
        }
    }

    /// Only seasons and episodes inherit: a movie or series without a theme
    /// would otherwise pick up one from the folders above it.
    static func lookupQuery(for item: ThemeMusicItem, userID: String) -> [String: String] {
        [
            "UserId": userID,
            "InheritFromParent": item.inheritsFromParent ? "true" : "false",
            "Fields": "MediaSources",
        ]
    }

    static func stream(for lookup: ThemeSongLookup) async -> ThemeSongStream? {
        guard let connection = try? await EmbyConnection.current() else { return nil }
        return await stream(for: lookup, connection: connection)
    }

    /// The song downloaded with this account's headers (the token never goes
    /// in the URL) and played from a temporary file. The original and any
    /// mp3 fallback share one ``ThemeSongFiles/openSeconds`` deadline. Like
    /// the lookup, a refusal never signs anyone out.
    static func stream(for lookup: ThemeSongLookup, connection: EmbyConnection) async -> ThemeSongStream? {
        guard let id = try? EmbyConnection.id(lookup.songID) else { return nil }
        let attempts = ServerThemeSongFormat.attempts(for: lookup.container)
        return await ThemeSongFiles.withDeadline(seconds: ThemeSongFiles.openSeconds) {
            await ServerThemeSongFormat.download(attempts) { attempt in
                let route = EmbyThemeMusic.streamRoute(songID: id, request: attempt)
                return await connection.optionalFile(route.path, query: route.query, maximumBytes: ThemeSongFiles.maximumBytes)
            }
        }
    }

    /// The original file (`Static=true`), named with its container when
    /// known, or an mp3 conversion. Not `/universal`, which answers with a
    /// redirect the connection refuses. `songID` must already be checked
    /// with `EmbyConnection.id`.
    static func streamRoute(songID: String, request: ServerThemeSongFormat.Request) -> (path: String, query: [String: String]) {
        switch request {
        case .original(let ext?): ("/Audio/\(songID)/stream.\(ext)", ["Static": "true"])
        case .original(nil): ("/Audio/\(songID)/stream", ["Static": "true"])
        case .mp3: ("/Audio/\(songID)/stream.mp3", ["AudioCodec": "mp3"])
        }
    }

    /// The first song URL tried for a container.
    static func streamURL(serverURL: String, songID: String, container: String?) throws -> URL {
        let route = streamRoute(songID: try EmbyConnection.id(songID), request: ServerThemeSongFormat.request(for: container))
        return try EmbyConnection.url(serverURL: serverURL, path: route.path, query: route.query)
    }
}
