import Foundation

/// The detail page a theme song is wanted for. Seasons and episodes carry
/// their series so a server that inherits themes can walk up to it.
struct ThemeMusicItem: Sendable, Equatable {
    /// The page's own item ID (`ItemDetail.contentId`).
    let contentID: String
    /// `ItemDetail.type`: "movie", "series", "season" or "episode".
    let type: String
    /// The series a season or episode belongs to, when known.
    let seriesID: String?

    /// Seasons and episodes use their parent's theme when they have none.
    /// The type is compared case-insensitively, so a server's "Season" or
    /// "Episode" counts too.
    var inheritsFromParent: Bool {
        let kind = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return kind == "season" || kind == "episode"
    }
}

/// What a lookup found. A failure (timeout, network error, refused request,
/// unreadable reply) is kept apart from "this title has no theme", so a
/// page whose lookup merely failed doesn't cut a song that is playing.
enum ThemeSongLookupResult: Sendable, Equatable {
    case found(ThemeSongLookup)
    /// The server answered and the title has no theme song (or the server
    /// doesn't offer theme music at all).
    case none
    /// The lookup couldn't get an answer.
    case failed
}

/// The theme song a server says belongs to a title. Looked up when a page
/// loads; turned into a playable ``ThemeSongStream`` only just before it
/// plays, because Silo's stream grants expire within minutes.
struct ThemeSongLookup: Sendable, Equatable {
    /// The server item that owns the song: the title itself, or the season
    /// or series it inherited from. Pages with the same owner and song keep
    /// the music playing instead of restarting it.
    let ownerID: String
    /// The theme song's own ID on the server.
    let songID: String
    /// The file's container ("mp3", "m4a", ...), when the server says.
    let container: String?
}

/// A theme song ready for `AVPlayer`: a URL plus any headers the request
/// needs (sent with `AVURLAssetHTTPHeaderFieldsKey`). The URL may be a local
/// file when the source had to download a converted stream first. Never log
/// or persist it: it can carry a short-lived grant.
struct ThemeSongStream: Sendable {
    let url: URL
    let headers: [String: String]
}

/// Finds and opens theme songs on the active server. Nothing here throws,
/// shows an error or signs anyone out: theme music is optional. A lookup
/// reports ``ThemeSongLookupResult/failed`` when it couldn't get an answer,
/// and a stream that can't be opened is `nil`.
enum ThemeMusicSource {
    static func lookup(for item: ThemeMusicItem) async -> ThemeSongLookupResult {
        switch MediaServerProvider.active {
        case .silo: await SiloThemeMusic.lookup(for: item)
        case .emby: await EmbyThemeMusic.lookup(for: item)
        case .jellyfin: await JellyfinThemeMusic.lookup(for: item)
        }
    }

    static func stream(for lookup: ThemeSongLookup) async -> ThemeSongStream? {
        switch MediaServerProvider.active {
        case .silo: await SiloThemeMusic.stream(for: lookup)
        case .emby: await EmbyThemeMusic.stream(for: lookup)
        case .jellyfin: await JellyfinThemeMusic.stream(for: lookup)
        }
    }
}
