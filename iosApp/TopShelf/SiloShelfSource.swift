import Foundation

/// Reads the Top Shelf rows from a Silo server for one viewing profile.
struct SiloShelfSource: Sendable {
    private let transport: SiloTransport
    private let tokens: SiloAccessTokens
    private let profileID: String
    private let profileToken: String?

    /// - Parameters:
    ///   - refreshToken: read only if the server turns the access token down.
    ///   - stillAllowed: whether the viewer may still be shown, asked before
    ///     every request.
    init(
        server: String,
        accessToken: String,
        profileID: String,
        profileToken: String?,
        refreshToken: @escaping @Sendable () -> String?,
        session: URLSession = SiloTransport.session,
        stillAllowed: @escaping @Sendable () -> Bool
    ) {
        let transport = SiloTransport(server: server, session: session, stillAllowed: stillAllowed)
        self.transport = transport
        self.profileID = profileID
        self.profileToken = profileToken
        tokens = SiloAccessTokens(current: accessToken) {
            try await Self.freshAccessToken(from: transport, refreshToken: refreshToken())
        }
    }

    func fetchFeed() async throws -> ShelfFeed {
        // A server that can't say which artwork sizes it has still has rows.
        let capability = try? await get(.imageCapability).decoded(
            ImageSizeCapabilityResponse.self,
            keys: .convertFromSnakeCase
        )
        let imageQuery = ImageSizeSelection.queryEntries(capability: capability, prefersLargeImages: true)

        let reply = try await get(.homeSections, query: imageQuery)
        let home = try reply.decoded(SiloHomePayload.self)
        guard !home.isUnreadable else { throw ShelfFailure.badResponse }
        func entries(where matches: (String) -> Bool) -> [ShelfEntry] {
            home.sections.filter { matches($0.kind) }.flatMap(\.items).map { entry(from: $0, relativeTo: reply.url) }
        }
        var feed = ShelfFeed(
            resume: entries { $0 == "continue_watching" || $0 == "in_progress" },
            upNext: entries { $0.contains("next") }
        )

        let series = Set((feed.resume + feed.upNext).filter { $0.kind == .episode }.compactMap(\.seriesID))
        let posters = await seriesPosters(for: series, imageQuery: imageQuery)
        feed.resume = feed.resume.map { $0.withSeriesPoster(from: posters) }
        feed.upNext = feed.upNext.map { $0.withSeriesPoster(from: posters) }
        return feed
    }

    private func entry(from item: SiloHomePayload.Item, relativeTo url: URL) -> ShelfEntry {
        let kind: ShelfEntry.Kind
        switch item.type {
        case "movie": kind = .movie
        case "episode": kind = .episode
        default: kind = .other
        }
        return ShelfEntry(
            id: item.contentID,
            kind: kind,
            title: item.title,
            seriesID: item.seriesID,
            seriesTitle: item.seriesTitle,
            season: item.seasonNumber,
            episode: item.episodeNumber,
            progress: ShelfEntry.progress(positionSeconds: item.positionSeconds, durationSeconds: item.durationSeconds),
            poster: Self.artworkURL(item.posterURL, relativeTo: url)
        )
    }

    // MARK: - Episode artwork

    /// Each series' main poster, one lookup per series, all at once. An
    /// episode's own image is a 16:9 still that would look wrong in a poster
    /// tile. A series whose lookup fails is left out, and its episodes keep
    /// their own image.
    private func seriesPosters(for seriesIDs: Set<String>, imageQuery: [String: String]) async -> [String: URL] {
        await withTaskGroup(of: (String, URL?).self) { group in
            for id in seriesIDs {
                group.addTask {
                    guard let reply = try? await get(.item(id), query: imageQuery),
                          let payload = try? reply.decoded(SiloItemPayload.self)
                    else { return (id, nil) }
                    return (id, Self.artworkURL(payload.posterURL, relativeTo: reply.url))
                }
            }
            var found: [String: URL] = [:]
            for await (id, poster) in group {
                if let poster { found[id] = poster }
            }
            return found
        }
    }

    /// A server-relative path is resolved against the server it came from;
    /// the shared helper refuses one that would resolve to another host.
    private static func artworkURL(_ raw: String?, relativeTo url: URL) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return SiloAPICompatibility.artworkURL(raw, relativeTo: url)
    }

    // MARK: - Requests

    /// A signed GET. When the server answers 401 the request is tried once
    /// more with a refreshed access token, if one can be had.
    private func get(_ route: SiloRoute, query: [String: String] = [:]) async throws -> SiloTransport.Reply {
        let token = await tokens.current
        var reply = try await send(route, query: query, accessToken: token)
        if reply.status == 401, let fresh = try await tokens.replacement(for: token) {
            reply = try await send(route, query: query, accessToken: fresh)
        }
        guard reply.succeeded else { throw ShelfFailure.http(reply.status) }
        return reply
    }

    private func send(
        _ route: SiloRoute,
        query: [String: String],
        accessToken: String
    ) async throws -> SiloTransport.Reply {
        try await transport.send(route, query: query) { request in
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
            request.setValue(profileID, forHTTPHeaderField: "X-Profile-Id")
            if let profileToken { request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token") }
        }
    }

    /// Trades the stored refresh token for a new access token. The request
    /// carries no bearer or profile headers: the refresh token is the proof.
    private static func freshAccessToken(from transport: SiloTransport, refreshToken: String?) async throws -> String {
        guard let refreshToken, !refreshToken.isEmpty else { throw ShelfFailure.refreshRefused }
        let body = try JSONEncoder().encode(["refresh_token": refreshToken])
        let reply = try await transport.send(.refresh, mapsReply: false) { request in
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        switch reply.status {
        case 200..<300:
            let token = try reply.decoded(SiloRefreshPayload.self).accessToken
            guard !token.isEmpty else { throw ShelfFailure.badResponse }
            return token
        case 400, 401, 403:
            // The sign-in itself has ended. Only the app can fix that.
            throw ShelfFailure.refreshRefused
        default:
            throw ShelfFailure.http(reply.status)
        }
    }
}

private extension SiloTransport.Reply {
    func decoded<Payload: Decodable>(
        _ type: Payload.Type,
        keys: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
    ) throws -> Payload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keys
        return try decoder.decode(type, from: body)
    }
}

private extension ShelfEntry {
    /// An episode shows its series' main poster when it's known. Films and
    /// anything else keep their own.
    func withSeriesPoster(from posters: [String: URL]) -> ShelfEntry {
        guard kind == .episode, let seriesID, let poster = posters[seriesID] else { return self }
        var entry = self
        entry.poster = poster
        return entry
    }
}
