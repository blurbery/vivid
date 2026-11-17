import Foundation

/// Silo's local theme songs ("Local theme songs, V2" in Silo's catalogue API
/// docs). Only v2 servers have them:
///
/// - `GET /api/v2/catalog/themes/capabilities` says whether this profile may
///   play them. It's cached per account and profile for a few minutes.
/// - `GET /api/v2/catalog/items/{id}` carries `themes` with the owner (the
///   title, or the season or series it inherits from) and the songs in file
///   order. Vivid plays the first.
/// - `POST /api/v2/catalog/items/{owner}/themes/{theme}/playback` grants a
///   short-lived audio URL, asked for only just before it plays. A
///   `converted` stream has no length or byte ranges, which `AVPlayer`
///   refuses over HTTP, so it's downloaded (up to 32 MB) into the shared
///   temporary theme folder first.
///
/// Every request goes through `HTTPClient.optionalSiloV2Request`, which never
/// starts a token refresh, so a refusal (even a 401) can't sign anyone out.
/// Every failure is nil. The grant URL carries a credential: it's never
/// logged or stored beyond the temporary audio file it fetches.
enum SiloThemeMusic {
    static func lookup(for item: ThemeMusicItem) async -> ThemeSongLookup? {
        await lookup(for: item, http: .shared, tokenStore: .shared, capabilities: .shared)
    }

    static func stream(for lookup: ThemeSongLookup) async -> ThemeSongStream? {
        await stream(for: lookup, http: .shared)
    }

    // MARK: - Requests

    static func lookup(
        for item: ThemeMusicItem,
        http: HTTPClient,
        tokenStore: TokenStore,
        capabilities: SiloThemeCapabilityCache
    ) async -> ThemeSongLookup? {
        guard let id = pathSegment(item.contentID),
              await capabilities.isPlayable(http: http, tokenStore: tokenStore),
              let response = try? await http.optionalSiloV2Request(
                  method: "GET", path: "/api/v2/catalog/items/\(id)", quietStatuses: quietStatuses
              )
        else { return nil }
        return firstTheme(inDetail: response.data)
    }

    static func stream(for lookup: ThemeSongLookup, http: HTTPClient) async -> ThemeSongStream? {
        guard let owner = pathSegment(lookup.ownerID), let song = pathSegment(lookup.songID),
              let response = try? await http.optionalSiloV2Request(
                  method: "POST", path: "/api/v2/catalog/items/\(owner)/themes/\(song)/playback",
                  body: grantRequestBody, quietStatuses: quietStatuses
              ),
              let grant = decodeGrant(response.data),
              let url = resolveGrantURL(grant.url, serverURL: response.serverURL)
        else { return nil }
        guard grant.delivery == "converted" else { return ThemeSongStream(url: url, headers: [:]) }
        guard let file = await SiloThemeDownload.converted(url) else { return nil }
        return ThemeSongStream(url: file, headers: [:])
    }

    /// Refusals an optional theme request expects: signed out or not a login
    /// session, not allowed, no such theme, a format the device can't play,
    /// or no route to the audio. They're logged at debug level, not as errors.
    static let quietStatuses: Set<Int> = [401, 403, 404, 406, 503]

    // MARK: - Pure helpers

    /// The theme part of a v2 item detail. Missing or empty means none.
    struct ThemeSet: Decodable, Equatable {
        let ownerId: String
        let items: [Song]

        struct Song: Decodable, Equatable {
            let id: String
            let title: String?
            let durationSeconds: Int?
            let container: String?
        }
    }

    private struct Detail: Decodable {
        let themes: ThemeSet?
    }

    /// The first theme song in an item detail document. Silo already applies
    /// inheritance and sorts the songs by file path.
    static func firstTheme(inDetail data: Data) -> ThemeSongLookup? {
        guard let themes = (try? HTTPClient.makeJSONDecoder().decode(Detail.self, from: data))?.themes,
              !themes.ownerId.isEmpty,
              let song = themes.items.first, !song.id.isEmpty
        else { return nil }
        let container = song.container.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return ThemeSongLookup(ownerID: themes.ownerId, songID: song.id, container: container)
    }

    private struct Capability: Decodable {
        let state: String
        let allowed: Bool?
    }

    /// Whether a capabilities document lets this profile play themes:
    /// `state` is `available` and `allowed` isn't false.
    static func capabilityAllowsPlayback(_ data: Data) -> Bool {
        guard let capability = try? HTTPClient.makeJSONDecoder().decode(Capability.self, from: data) else { return false }
        return capability.state == "available" && capability.allowed != false
    }

    /// What `AVPlayer` opens over HTTP, as container and codec pairs. Silo
    /// sends the original when it matches, and otherwise converts to AAC in
    /// MP4 (allowed by the `mp4`/`aac` pair). Ogg (Vorbis and Opus) is left
    /// out because AVFoundation can't demux it. Mirrors Silo's own Apple app.
    static let acceptedFormats: [(container: String, codec: String)] = [
        ("mp3", "mp3"),
        ("mp4", "aac"), ("mp4", "alac"),
        ("m4a", "aac"), ("m4a", "alac"),
        ("aac", "aac"),
        ("flac", "flac"),
        ("wav", "pcm"),
    ]

    /// `{"accepted_formats":[{"audio_codec":…,"container":…}, …]}`.
    static let grantRequestBody: Data = {
        let formats = acceptedFormats.map { ["container": $0.container, "audio_codec": $0.codec] }
        return (try? JSONSerialization.data(withJSONObject: ["accepted_formats": formats], options: [.sortedKeys])) ?? Data()
    }()

    struct Grant: Decodable {
        let url: String
        let delivery: String?
        let contentType: String?
    }

    /// Decoded here rather than through `HTTPClient`, whose decoding-failure
    /// log includes the body, and the body holds the signed URL.
    static func decodeGrant(_ data: Data) -> Grant? {
        guard let grant = try? HTTPClient.makeJSONDecoder().decode(Grant.self, from: data), !grant.url.isEmpty else { return nil }
        return grant
    }

    /// An absolute http or https URL as it is (a proxy node can serve the
    /// audio), or a root-relative one resolved against the server, the same
    /// way as v2 artwork. Anything else is refused.
    static func resolveGrantURL(_ raw: String, serverURL: String) -> URL? {
        let resolved: URL?
        if raw.hasPrefix("/") {
            guard !raw.hasPrefix("//") else { return nil }
            resolved = SiloAPICompatibility.artworkURL(raw, relativeTo: URL(string: serverURL))
        } else {
            resolved = URL(string: raw)
        }
        guard let resolved,
              let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
              resolved.host?.isEmpty == false
        else { return nil }
        return resolved
    }

    /// An ID as one percent-encoded path segment.
    static func pathSegment(_ id: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return encoded
    }
}

/// The theme capability per account, credential generation and viewing
/// profile (`allowed` is profile-scoped). A decoded answer or a 404 (no
/// theme support) is kept for five minutes; a transport failure isn't kept.
actor SiloThemeCapabilityCache {
    static let shared = SiloThemeCapabilityCache()

    static let lifetime: TimeInterval = 300

    private struct Key: Hashable {
        let account: RefreshAccountIdentity
        let profileID: String?
    }

    private var answers: [Key: (playable: Bool, at: Date)] = [:]
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func isPlayable(http: HTTPClient, tokenStore: TokenStore) async -> Bool {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { return false }
        let key = Key(account: auth.account, profileID: auth.profileId)
        if let answer = answers[key], now().timeIntervalSince(answer.at) < Self.lifetime { return answer.playable }

        let playable: Bool
        do {
            guard let response = try await http.optionalSiloV2Request(
                method: "GET", path: "/api/v2/catalog/themes/capabilities", quietStatuses: SiloThemeMusic.quietStatuses
            ) else { return false }
            playable = SiloThemeMusic.capabilityAllowsPlayback(response.data)
        } catch HTTPError.http(let status, _) where status == 404 {
            playable = false
        } catch {
            return false
        }
        if answers.count >= 16 { answers.removeAll() }
        answers[key] = (playable, now())
        return playable
    }
}

/// Downloads converted theme streams, which have no length or byte ranges,
/// and hands them to the shared ``ThemeSongFiles`` store.
enum SiloThemeDownload {
    /// The whole stream saved as a local `.m4a`; nil on any failure, a
    /// non-200 status, an empty body, past the size cap, or once cancelled.
    static func converted(_ url: URL) async -> URL? {
        guard let data = await read(url), !Task.isCancelled else { return nil }
        return ThemeSongFiles.store(data, fileExtension: "m4a")
    }

    /// An ephemeral session keeps the signed URL and audio out of any cache.
    private static func read(_ url: URL) async -> Data? {
        let maxBytes = ThemeSongFiles.maximumBytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: PlainHTTPRedirectGuard.SessionDelegate.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        var data = Data()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(65_536)
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 65_536 {
                    data.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                    if data.count > maxBytes { return nil }
                }
            }
        } catch {
            return nil
        }
        data.append(contentsOf: chunk)
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return data
    }
}
