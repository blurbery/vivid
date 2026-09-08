import Foundation

/// Converts the artwork URLs used by detail screens into the relative API
/// location expected by `HTTPClient`. Detail artwork is commonly absolute,
/// while download manifests use relative paths. Passing an absolute URL to
/// `URLComponents.percentEncodedPath` as though it were a path traps in
/// Foundation, so normalise both forms before the request is built.
struct DownloadAssetRequestLocation: Equatable {
    let path: String
    let query: [String: String]

    static func resolve(_ rawValue: String, relativeTo serverURL: String) throws -> Self {
        let rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty,
              let asset = URLComponents(string: rawValue) else {
            throw HTTPError.invalidURL(rawValue)
        }

        let resolvedPath: String
        if asset.scheme != nil || asset.host != nil {
            guard let server = URLComponents(string: serverURL),
                  asset.scheme?.lowercased() == server.scheme?.lowercased(),
                  asset.host?.lowercased() == server.host?.lowercased(),
                  effectivePort(asset) == effectivePort(server),
                  asset.user == nil,
                  asset.password == nil else {
                throw HTTPError.invalidURL(rawValue)
            }

            let serverBasePath = server.percentEncodedPath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let basePrefix = serverBasePath.isEmpty ? "" : "/\(serverBasePath)"
            let absolutePath = asset.percentEncodedPath
            guard basePrefix.isEmpty
                    || absolutePath == basePrefix
                    || absolutePath.hasPrefix(basePrefix + "/") else {
                throw HTTPError.invalidURL(rawValue)
            }
            resolvedPath = String(absolutePath.dropFirst(basePrefix.count))
        } else {
            resolvedPath = asset.percentEncodedPath
        }

        let normalizedPath: String
        if resolvedPath.isEmpty {
            normalizedPath = "/"
        } else {
            normalizedPath = resolvedPath.hasPrefix("/") ? resolvedPath : "/" + resolvedPath
        }
        let query = Dictionary(
            (asset.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, latest in latest }
        )
        return Self(path: normalizedPath, query: query)
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Typed download / offline-sync endpoints, grouped as an extension on the
/// existing `VividAPI` facade. These reuse the facade's injected `http`
/// transport (auth injection, 401 refresh, snake_case JSON coders) rather
/// than the legacy path dispatcher. Contract: server `docs/downloads-api.md`.
extension VividAPI {

    // MARK: - Capability

    func downloadCapability() async throws -> DownloadCapability {
        try await http.get("/api/v1/downloads/capability")
    }

    // MARK: - Download registry

    /// Register a managed download. Returns one row for a single item, or
    /// every batch member for a series/season request.
    func createDownload(_ request: CreateDownloadRequest) async throws -> [ServerDownloadRow] {
        let response: CreateDownloadResponse = try await http.post(
            "/api/v1/downloads",
            body: request
        )
        return response.downloads
    }

    /// The calling device's managed entries. Primary poll-for-readiness and
    /// reconcile-on-launch call.
    func listDownloads() async throws -> [ServerDownloadRow] {
        let response: ServerDownloadsResponse = try await http.get("/api/v1/downloads")
        return response.downloads
    }

    /// Report local progression so the server row reflects reality. Only
    /// `downloading` / `completed` are accepted.
    func patchDownloadStatus(id: String, status: String) async throws {
        try await http.patchVoid(
            "/api/v1/downloads/\(id)",
            body: DownloadStatusUpdate(status: status)
        )
    }

    func deleteDownloadRow(id: String) async throws {
        try await http.delete("/api/v1/downloads/\(id)")
    }

    func fetchManifest(downloadId: String) async throws -> OfflineManifest {
        try await http.get("/api/v1/downloads/\(downloadId)/manifest")
    }

    func fetchBatchManifests(batchId: String) async throws -> [OfflineManifest] {
        let response: BatchManifestResponse = try await http.get(
            "/api/v1/downloads/batches/\(batchId)/manifests"
        )
        return response.manifests
    }

    /// Fetch the raw bytes of an authenticated proxy asset (artwork or
    /// subtitle). `path` is an API-relative path taken from the manifest
    /// (`artwork_urls.*` / `subtitles[].fetch_url`).
    func fetchDownloadAssetData(path: String) async throws -> Data {
        if MediaServerProvider.active == .emby { return try await EmbyConnection.current().assetData(path) }
        let location = try DownloadAssetRequestLocation.resolve(
            path,
            relativeTo: await currentServerUrl()
        )
        return try await http.getData(location.path, query: location.query)
    }

    /// Build the absolute file-endpoint URL for a download, resolved
    /// against the active server origin. Used by the background downloader.
    func downloadFileURL(downloadId: String) async -> URL? {
        if MediaServerProvider.active == .emby {
            guard let connection = try? await EmbyConnection.current() else { return nil }
            return try? await EmbyDownloads.shared.fileURL(id:downloadId,connection:connection)
        }
        let base = await currentServerUrl()
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/api/v1/downloads/\(downloadId)/file")
    }

    // MARK: - Subscriptions

    func createSubscription(_ request: CreateSubscriptionRequest) async throws -> CreateSubscriptionResponse {
        try await http.post("/api/v1/downloads/subscriptions", body: request)
    }

    /// Register newly in-scope episodes across all of this device's
    /// monitors. Returns how many were registered.
    @discardableResult
    func syncSubscriptions() async throws -> Int {
        let response: SubscriptionSyncResponse = try await http.post(
            "/api/v1/downloads/subscriptions/sync"
        )
        return response.registered
    }

    func listSubscriptions() async throws -> [ServerSubscription] {
        let response: SubscriptionsListResponse = try await http.get(
            "/api/v1/downloads/subscriptions"
        )
        return response.subscriptions
    }

    func updateSubscription(
        id: String,
        _ request: UpdateSubscriptionRequest
    ) async throws -> CreateSubscriptionResponse {
        try await http.patch("/api/v1/downloads/subscriptions/\(id)", body: request)
    }

    func deleteSubscription(id: String) async throws {
        try await http.delete("/api/v1/downloads/subscriptions/\(id)")
    }

    // MARK: - Progress reconciliation

    /// Flush a batch of queued offline progress events. Returns per-item
    /// results so the caller can drop acked items from its queue.
    func syncProgressBatch(items: [SyncProgressItem]) async throws -> [SyncProgressResult] {
        guard !items.isEmpty else { return [] }
        let response: SyncProgressResultsResponse = try await http.post(
            "/api/v1/sync/progress",
            body: SyncProgressRequest(items: items)
        )
        return response.results
    }

    /// Pull watch-state changes made on any device after `cursor`,
    /// server-ordered. Pass `nil` for the initial pull.
    func pullProgressDeltas(since cursor: String?) async throws -> ProgressPullResponse {
        var query: [String: String] = [:]
        if let cursor, !cursor.isEmpty { query["since"] = cursor }
        return try await http.get("/api/v1/progress", query: query)
    }
}

// MARK: - Request/response helpers

private struct DownloadStatusUpdate: Encodable {
    let status: String
}

/// `POST /api/v1/downloads` returns either a bare row (single item) or a
/// `{ "downloads": [...] }` batch. This decodes both into a row list.
struct CreateDownloadResponse: Decodable, Sendable {
    let downloads: [ServerDownloadRow]

    private enum CodingKeys: String, CodingKey {
        case downloads
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let rows = try? keyed.decode([ServerDownloadRow].self, forKey: .downloads) {
            self.downloads = rows
            return
        }
        let single = try ServerDownloadRow(from: decoder)
        self.downloads = [single]
    }
}

struct BatchManifestResponse: Decodable, Sendable {
    let manifests: [OfflineManifest]
}

/// Per-item result envelope from `POST /api/v1/sync/progress` (§5.1).
struct SyncProgressResultsResponse: Codable, Sendable {
    let results: [SyncProgressResult]
}

struct SyncProgressResult: Codable, Sendable {
    let mediaItemId: String
    let status: String
    let error: String?

    var isOK: Bool { status == "ok" }
}
