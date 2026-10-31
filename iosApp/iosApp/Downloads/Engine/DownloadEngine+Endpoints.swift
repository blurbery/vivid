import Foundation

/// The downloads, subscriptions and offline progress endpoints. On Emby and
/// Jellyfin the networking layer answers these paths itself, in Silo's shapes.
extension VividAPI {
    func downloadCapability(auth: CapturedOrdinaryRequestAuth? = nil) async throws -> DownloadCapability {
        try await http.get("/api/v1/downloads/capability", expectedAuth: auth)
    }

    func createDownload(_ request: CreateDownloadRequest, auth: CapturedOrdinaryRequestAuth? = nil) async throws -> [ServerDownloadRow] {
        let created: DownloadEngine.CreatedRows = try await http.post("/api/v1/downloads", body: request, expectedAuth: auth)
        return created.rows
    }

    func listDownloads(auth: CapturedOrdinaryRequestAuth? = nil) async throws -> [ServerDownloadRow] {
        let list: DownloadEngine.RowList = try await http.get("/api/v1/downloads", expectedAuth: auth)
        return list.downloads
    }

    func patchDownloadStatus(id: String, status: String, revision: Int? = nil, updatedAt: Date = Date(),
                             auth: CapturedOrdinaryRequestAuth? = nil) async throws {
        let body = DownloadEngine.StatusUpdate(status: status, revision: revision, updatedAt: updatedAt)
        try await http.patchVoid("/api/v1/downloads/\(id)", body: body, expectedAuth: auth)
    }

    func deleteDownloadRow(id: String, auth: CapturedOrdinaryRequestAuth? = nil) async throws {
        try await http.delete("/api/v1/downloads/\(id)", expectedAuth: auth)
    }

    func fetchManifest(downloadId: String, auth: CapturedOrdinaryRequestAuth) async throws -> OfflineManifest {
        try await http.get("/api/v1/downloads/\(downloadId)/manifest", expectedAuth: auth)
    }

    /// Artwork, subtitle files and series posters. Emby and Jellyfin fetch
    /// through the connection that matches the identity; Silo only from its
    /// own origin, or from storage it signed when the path is a bare https URL.
    func fetchDownloadAssetData(path: String, auth: CapturedOrdinaryRequestAuth) async throws -> Data {
        switch MediaServerProvider.forServerID(auth.account.serverId) {
        case .jellyfin:
            return try await JellyfinConnection.current(matching: auth).assetData(path)
        case .emby:
            return try await EmbyConnection.current(matching: auth).assetData(path)
        case .silo:
            let location: DownloadEngine.AssetLocation
            do {
                location = try DownloadEngine.AssetLocation(path, serverURL: auth.account.serverURL)
            } catch {
                guard let signed = DownloadEngine.AssetLocation.signedArtworkURL(path) else { throw error }
                return try await Self.signedArtworkData(signed)
            }
            return try await http.getData(location.path, query: location.query, expectedAuth: auth)
        }
    }

    /// A poster Silo signed onto its storage: fetched with no credentials,
    /// images only, at most 20 MB.
    static func signedArtworkData(_ url: URL) async throws -> Data {
        let limit = 20_000_000
        let (bytes, response) = try await DownloadEngine.signedArtworkSession.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidURL(url.absoluteString) }
        guard (200...299).contains(http.statusCode) else { throw HTTPError.http(statusCode: http.statusCode, body: nil) }
        guard http.mimeType?.lowercased().hasPrefix("image/") == true, http.expectedContentLength <= Int64(limit) else {
            throw HTTPError.invalidURL(url.absoluteString)
        }
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw HTTPError.invalidURL(url.absoluteString) }
        }
        guard !data.isEmpty else { throw HTTPError.invalidURL(url.absoluteString) }
        return data
    }

    /// Where the background session fetches the media file. Nil when it
    /// can't be worked out.
    func downloadFileURL(downloadId: String, auth: CapturedOrdinaryRequestAuth) async -> URL? {
        switch MediaServerProvider.forServerID(auth.account.serverId) {
        case .jellyfin:
            guard let connection = try? await JellyfinConnection.current(matching: auth) else { return nil }
            return try? await JellyfinDownloads.shared.fileURL(id: downloadId, connection: connection)
        case .emby:
            guard let connection = try? await EmbyConnection.current(matching: auth) else { return nil }
            return try? await EmbyDownloads.shared.fileURL(id: downloadId, connection: connection)
        case .silo:
            var server = auth.account.serverURL
            guard !server.isEmpty else { return nil }
            if server.hasSuffix("/") { server.removeLast() }
            guard let url = URL(string: "\(server)/api/v1/downloads/\(downloadId)/file") else { return nil }
            guard let usesV2 = try? await SiloAPIDiscovery.shared.usesV2(for: url, session: .shared) else { return nil }
            guard usesV2 else { return url }
            return (try? SiloAPICompatibility.request(URLRequest(url: url)))?.url
        }
    }

    // MARK: Subscriptions

    func createSubscription(_ request: CreateSubscriptionRequest) async throws -> CreateSubscriptionResponse {
        try await http.post("/api/v1/downloads/subscriptions", body: request)
    }

    /// Asks the server to register new episodes for every subscription now.
    @discardableResult
    func syncSubscriptions() async throws -> Int {
        let sync: DownloadEngine.SubscriptionSync = try await http.post("/api/v1/downloads/subscriptions/sync")
        return sync.registered
    }

    func updateSubscription(id: String, _ request: UpdateSubscriptionRequest) async throws -> CreateSubscriptionResponse {
        try await http.patch("/api/v1/downloads/subscriptions/\(id)", body: request)
    }

    func deleteSubscription(id: String) async throws {
        try await http.delete("/api/v1/downloads/subscriptions/\(id)")
    }

    // MARK: Offline progress

    /// Sends offline progress 100 items at a time, pinned to the identity
    /// current when it starts. Once a chunk has been acknowledged, a later
    /// failure returns what came back so far; the rest go next time.
    func syncProgressBatch(items: [SyncProgressItem]) async throws -> [SyncProgressResult] {
        guard !items.isEmpty else { return [] }
        let identity = await TokenStore.shared.captureOrdinaryRequestAuth()
        var results: [SyncProgressResult] = []
        var acknowledged = false
        for start in stride(from: 0, to: items.count, by: 100) {
            let chunk = Array(items[start..<min(start + 100, items.count)])
            do {
                let response: SyncProgressResultsResponse = try await http.post(
                    "/api/v1/sync/progress", body: SyncProgressRequest(items: chunk), expectedAuth: identity
                )
                results += response.results
                acknowledged = true
            } catch {
                if !acknowledged { throw error }
                break
            }
        }
        return results
    }

    func pullProgressDeltas(since cursor: String?) async throws -> ProgressPullResponse {
        var query: [String: String] = [:]
        if let cursor, !cursor.isEmpty { query["since"] = cursor }
        return try await http.get("/api/v1/progress", query: query)
    }

    /// The server's current progress for these items, 100 ids per request.
    func currentProgress(mediaItemIds: [String]) async throws -> [ProgressPullItem] {
        guard !mediaItemIds.isEmpty else { return [] }
        let identity = await TokenStore.shared.captureOrdinaryRequestAuth()
        var items: [ProgressPullItem] = []
        for start in stride(from: 0, to: mediaItemIds.count, by: 100) {
            let ids = mediaItemIds[start..<min(start + 100, mediaItemIds.count)].joined(separator: ",")
            let response: ProgressPullResponse = try await http.get(
                "/api/v1/progress", query: ["ids": ids], expectedAuth: identity
            )
            items += response.progress
        }
        return items
    }
}

/// Emby and Jellyfin image and video paths, relative to the account's server.
enum ServerAssetPath {
    /// The path of `url` under `base`, when both are the same server and the
    /// path is an item image or a video. Paths compare decoded.
    static func relative(_ url: URL, base: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == base.scheme?.lowercased(),
              let host = url.host?.lowercased(), host == base.host?.lowercased(),
              url.port == base.port,
              url.user == nil, url.password == nil else { return nil }
        var basePath = base.path
        if basePath.hasSuffix("/") { basePath.removeLast() }
        let path = url.path
        let relative: String
        if basePath.isEmpty {
            relative = path
        } else {
            guard path.hasPrefix(basePath + "/") else { return nil }
            relative = String(path.dropFirst(basePath.count))
        }
        guard relative.hasPrefix("/Items/") || relative.hasPrefix("/Videos/") else { return nil }
        return relative
    }
}

extension DownloadEngine {
    /// Turns an asset or file location into a request path and query on the
    /// account's own server. Absolute locations must be on that server, under
    /// its base path; relative ones are taken as they are. Percent-encoding is
    /// kept as it was.
    struct AssetLocation: Equatable, Sendable {
        let path: String
        let query: [String: String]

        init(_ text: String, serverURL: String) throws {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let asset = URLComponents(string: trimmed) else { throw HTTPError.invalidURL(trimmed) }
            var path = asset.percentEncodedPath
            if asset.scheme != nil || asset.host != nil {
                guard let server = URLComponents(string: serverURL),
                      let scheme = asset.scheme?.lowercased(), scheme == server.scheme?.lowercased(),
                      let host = asset.host?.lowercased(), host == server.host?.lowercased(),
                      Self.effectivePort(asset) == Self.effectivePort(server),
                      asset.user == nil, asset.password == nil else { throw HTTPError.invalidURL(trimmed) }
                let base = server.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !base.isEmpty {
                    let prefix = "/" + base
                    guard path == prefix || path.hasPrefix(prefix + "/") else { throw HTTPError.invalidURL(trimmed) }
                    path.removeFirst(prefix.count)
                }
            }
            if path.isEmpty { path = "/" } else if !path.hasPrefix("/") { path = "/" + path }
            self.path = path
            var query: [String: String] = [:]
            for item in asset.queryItems ?? [] { query[item.name] = item.value ?? "" }
            self.query = query
        }

        private static func effectivePort(_ components: URLComponents) -> Int? {
            if let port = components.port { return port }
            switch components.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }

        /// A location Silo signed onto its storage: an absolute https URL with
        /// a host and no user or password.
        static func signedArtworkURL(_ text: String) -> URL? {
            guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
    }

    /// No cookies, no cache and no credentials for signed storage links.
    static let signedArtworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()
}
