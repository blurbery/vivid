import Foundation

/// Typed calls to the app's server API. Requests are written against Silo's
/// `/api/v1` routes and go through `HTTPClient`, which signs them, maps them
/// to Silo v2 where the server needs it, and hands Emby and Jellyfin accounts
/// to their adapters. Session state comes from `TokenStore`.
///
/// A few older call sites still use the path-based `get`, `putVoid` and
/// `delete`, which route a path to the typed call for it.
actor VividAPI {
    static let shared = VividAPI()

    /// Shared with the endpoint extensions in other files.
    let http: HTTPClient
    private let tokenStore: TokenStore
    /// Vivid's own `ui.*` and `nav.*` settings on Silo servers.
    let localInterfaceSettings: SiloLocalInterfaceSettings

    init(
        http: HTTPClient = .shared,
        tokenStore: TokenStore = .shared,
        localInterfaceSettings: SiloLocalInterfaceSettings = .shared
    ) {
        self.http = http
        self.tokenStore = tokenStore
        self.localInterfaceSettings = localInterfaceSettings
    }

    // MARK: - Session

    func currentServerUrl() async -> String {
        await tokenStore.getServerUrl()
    }

    func currentAccessToken() async -> String? {
        await tokenStore.getAccessToken()
    }

    /// The profile the session is acting as, or nil before one is selected.
    func currentProfileId() async -> String? {
        await tokenStore.getProfileId()
    }

    /// The server the session is signed in to, or empty before one is chosen.
    func currentServerId() async -> String {
        await tokenStore.getActiveServerId()
    }

    // MARK: - Image sizes

    /// Query entries asking a Silo server for larger artwork in every image
    /// URL it returns. Empty for Emby and Jellyfin, off tvOS, and until (or
    /// unless) `ImageSizeCapability` finds the server supports it. Concurrent
    /// callers share one capability check.
    private var imageSizeQuery: [String: String] {
        get async {
            if MediaServerProvider.active.usesNativeUser { return [:] }
            await ImageSizeCapability.shared.refresh()
            return ImageSizeCapability.shared.requestQuery
        }
    }

    /// `query` with the image size entries added. The caller's own values win.
    private func withImageSize(_ query: [String: String]) async -> [String: String] {
        query.merging(await imageSizeQuery) { caller, _ in caller }
    }

    /// `GET /api/v1/images/capability`. Servers without image sizes answer
    /// 404, which the caller reads as off.
    func imageSizeCapability() async throws -> ImageSizeCapabilityResponse {
        try await http.get("/api/v1/images/capability")
    }

    // MARK: - Path-based calls

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let route = APIPath(path)
        if route.matches("api/v1/catalog") {
            return try cast(try await catalog(query: query))
        }
        throw APIError.unsupportedPath(path)
    }

    func putVoid(_ path: String, body: (any Encodable)? = nil) async throws {
        let route = APIPath(path)
        if let id = route.capture("api/v1/favorites/*") {
            try await toggleFavorite(contentId: id, isFavorite: true)
            return
        }
        if let id = route.capture("api/v1/watchlist/*") {
            try await toggleWatchlist(contentId: id, isInWatchlist: true)
            return
        }
        throw APIError.unsupportedPath(path)
    }

    func delete(_ path: String) async throws {
        let route = APIPath(path)
        if let id = route.capture("api/v1/favorites/*") {
            try await toggleFavorite(contentId: id, isFavorite: false)
        } else if let id = route.capture("api/v1/watchlist/*") {
            try await toggleWatchlist(contentId: id, isInWatchlist: false)
        } else {
            throw APIError.unsupportedPath(path)
        }
    }

    // MARK: - Account and settings

    func currentUser() async throws -> UserInfo {
        let user: AuthUser = try await http.get("/api/v1/auth/me")
        return UserInfo(id: String(user.id), username: user.username, isAdmin: user.role == "admin")
    }

    /// A setting stored for the user (not the device). An unset key answers
    /// 404, which callers catch to fall back to their own default.
    func getUserSetting(key: String) async throws -> SettingEntryResponse {
        try await http.get("/api/v1/settings/\(key)")
    }

    /// The server-wide card overlay switch and default overlays.
    func overlayConfig() async throws -> OverlayConfigResponse {
        try await http.get("/api/v1/settings/overlay-config")
    }

    // MARK: - Home

    func homeSections() async throws -> SectionsResponse {
        try await http.get("/api/v1/home/sections", query: await imageSizeQuery)
    }

    func dismissContinueWatchingItem(contentId: String, progressUpdatedAt: String) async throws {
        try await http.putVoid(
            "/api/v1/home/dismissals/continue_watching/\(contentId)",
            body: HomeDismissalBody(progressUpdatedAt: progressUpdatedAt)
        )
    }

    /// Next Up episodes have no progress row, so the server keys their
    /// dismissal on the series.
    func dismissNextUpItem(contentId: String, seriesId: String) async throws {
        try await http.putVoid(
            "/api/v1/home/dismissals/next_up/\(contentId)",
            body: NextUpDismissalBody(seriesId: seriesId)
        )
    }

    // MARK: - Catalogue

    /// Every catalogue list (browse, search, person credits, collection
    /// items, section pages) comes through here, so image sizes are added in
    /// one place.
    func catalog(query: [String: String]) async throws -> CatalogResponse {
        try await http.get("/api/v1/catalog", query: await withImageSize(query))
    }

    /// A catalogue page decoded into the caller's own shape, for fields
    /// `BrowseItem` doesn't keep, such as provider IDs.
    func catalog<Page: Decodable>(query: [String: String], as _: Page.Type) async throws -> Page {
        try await http.get("/api/v1/catalog", query: await withImageSize(query))
    }

    func itemDetail(contentId: String) async throws -> ItemDetail {
        try await http.get("/api/v1/catalog/items/\(contentId)", query: await imageSizeQuery)
    }

    func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) async throws -> CatalogFilters {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = String(libraryId) }
        // Adds the resolution, audio and subtitle filters.
        if includeTechnical { query["include_technical"] = "true" }
        return try await http.get("/api/v1/catalog/filters", query: query)
    }

    func seasons(seriesId: String) async throws -> SeasonsResponse {
        try await http.get("/api/v1/catalog/series/\(seriesId)/seasons", query: await imageSizeQuery)
    }

    /// `jellyfinResumeEpisodeId` only goes to Jellyfin, which uses it to
    /// find the season's resume point.
    func episodes(seriesId: String, seasonNumber: Int, jellyfinResumeEpisodeId: String? = nil) async throws -> EpisodesResponse {
        var query = await imageSizeQuery
        if MediaServerProvider.active == .jellyfin, let jellyfinResumeEpisodeId {
            query["resume_episode_id"] = jellyfinResumeEpisodeId
        }
        return try await http.get("/api/v1/catalog/series/\(seriesId)/seasons/\(seasonNumber)/episodes", query: query)
    }

    /// Every original file of one episode. Emby lists one source per
    /// episode, so download menus ask for the rest; Silo and Jellyfin
    /// already list them all, so this is empty for them.
    func episodeFiles(contentId: String) async throws -> [EpisodeFile] {
        guard MediaServerProvider.active == .emby else { return [] }
        let response: EpisodeFilesResponse = try await http.get("/api/v1/catalog/items/\(contentId)/files")
        return response.files
    }

    func watchDetail(contentId: String) async throws -> WatchDetail {
        try await http.get("/api/v1/watch/\(contentId)", query: await imageSizeQuery)
    }

    /// Subtitles Silo stores for a file (downloaded, uploaded or made by its
    /// AI), which the catalogue's tracks leave out.
    func storedSubtitles(fileID: Int) async throws -> SiloStoredSubtitleList {
        try await http.get("/api/v1/subtitles/\(fileID)")
    }

    func person(id: Int) async throws -> Person {
        try await http.get("/api/v1/people/\(id)")
    }

    func refreshPerson(id: Int) async throws -> PersonRefreshQueuedResponse {
        try await http.post("/api/v1/people/\(id)/refresh")
    }

    func personCatalogItems(
        personId: Int,
        type: String?,
        offset: Int,
        limit: Int,
        snapshot: String? = nil
    ) async throws -> CatalogResponse {
        var query = [
            "source": "person",
            "person_id": String(personId),
            "offset": String(offset),
            "limit": String(limit),
            "sort": "year",
            "order": "desc",
        ]
        if let type { query["type"] = type }
        if let snapshot { query["snapshot_at"] = snapshot }
        return try await catalog(query: query)
    }

    // MARK: - Libraries

    func libraries() async throws -> LibrariesResponse {
        let libraries: [Library] = try await http.get("/api/v1/user/libraries")
        return LibrariesResponse(libraries: libraries)
    }

    func libraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        let wire: LibraryCollectionsWireResponse = try await http.get("/api/v1/library/\(libraryId)/collections")
        return LibraryCollectionsResponse(collections: wire.collections, sections: wire.sections)
    }

    /// `libraryCollections` for a page that reads every library. The library
    /// list is the account's, so it can name a library this profile can't
    /// see, which Silo answers with 404: that reads as no collections.
    func visibleLibraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        do {
            return try await libraryCollections(libraryId: libraryId)
        } catch where Self.isNotFound(error) {
            return LibraryCollectionsResponse(collections: [], sections: [])
        }
    }

    /// The profile's own collections, shaped like library collections. A
    /// server without personal collections answers 404, which reads as none.
    func personalCollections(profileID: String?) async throws -> [LibraryCollection] {
        do {
            let personal = try await collections().collections ?? []
            return personal.map { LibraryCollection(personal: $0, profileID: profileID) }
        } catch where Self.isNotFound(error) {
            return []
        }
    }

    nonisolated static func isNotFound(_ error: Error) -> Bool {
        if let error = error as? HTTPError { return error.statusCode == 404 }
        if case .httpError(404)? = error as? APIError { return true }
        return false
    }

    func libraryCollectionItems(
        libraryId: Int,
        collectionId: String,
        offset: Int = 0,
        limit: Int = 60,
        snapshot: String? = nil,
        includeTotal: Bool = false
    ) async throws -> CatalogResponse {
        try await collectionCatalog(
            kind: .regular, collectionId: collectionId, offset: offset,
            limit: limit, snapshot: snapshot, includeTotal: includeTotal
        )
    }

    /// A personal collection's items through the catalogue, which fills them
    /// in. `/api/v1/collections/{id}/items` only returns bare join rows.
    func userCollectionItems(
        collectionId: String,
        offset: Int = 0,
        limit: Int = 60,
        snapshot: String? = nil,
        includeTotal: Bool = false
    ) async throws -> CatalogResponse {
        try await collectionCatalog(
            kind: .userCollections, collectionId: collectionId, offset: offset,
            limit: limit, snapshot: snapshot, includeTotal: includeTotal
        )
    }

    private func collectionCatalog(
        kind: LibraryCollectionKind,
        collectionId: String,
        offset: Int,
        limit: Int,
        snapshot: String?,
        includeTotal: Bool
    ) async throws -> CatalogResponse {
        var query = [
            "source": kind.catalogSource,
            "collection_id": collectionId,
            "offset": String(offset),
            "limit": String(limit),
        ]
        if let snapshot { query["snapshot"] = snapshot }
        if !includeTotal { query["include_total"] = "false" }
        return try await catalog(query: query)
    }

    // MARK: - Personal lists

    // These build their own query rather than going through `catalog`, so
    // each adds image sizes itself.

    func favorites(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/favorites", query: await withImageSize(page(offset, limit)))
    }

    func watchlist(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/watchlist", query: await withImageSize(page(offset, limit)))
    }

    func history(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/history", query: await withImageSize(page(offset, limit)))
    }

    /// The server answers 204 for a favourite and 404 otherwise.
    func isFavorite(contentId: String) async throws -> Bool {
        try await http.exists("/api/v1/favorites/\(contentId)")
    }

    func isInWatchlist(contentId: String) async throws -> Bool {
        try await http.exists("/api/v1/watchlist/\(contentId)")
    }

    func toggleFavorite(contentId: String, isFavorite: Bool) async throws {
        if isFavorite {
            try await http.putVoid("/api/v1/favorites/\(contentId)")
        } else {
            try await http.delete("/api/v1/favorites/\(contentId)")
        }
    }

    /// Also tells MDBList and Simkl sync, for the account that made the change.
    func toggleWatchlist(contentId: String, isInWatchlist: Bool) async throws {
        #if os(iOS) || os(tvOS)
        let auth = await tokenStore.captureOrdinaryRequestAuth()
        #endif
        if isInWatchlist {
            try await http.putVoid("/api/v1/watchlist/\(contentId)")
        } else {
            try await http.delete("/api/v1/watchlist/\(contentId)")
        }
        #if os(iOS) || os(tvOS)
        await MDBListSyncStore.shared.watchlistChanged(expected: auth)
        await SimklSyncStore.shared.watchlistChanged(expected: auth)
        #endif
    }

    /// Marks a movie, series, season or episode watched or unwatched; the
    /// server works out the episodes. The request is pinned to the account
    /// and profile captured first, or with `expectedAuth`, sent only while
    /// that sign-in and profile are still current. Only a confirmed watch
    /// goes on to MDBList and Simkl.
    func setWatched(contentId: String, played: Bool, expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws {
        #if os(iOS) || os(tvOS)
        let captured: CapturedOrdinaryRequestAuth?
        if let expectedAuth {
            captured = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: expectedAuth)
        } else {
            captured = await tokenStore.captureOrdinaryRequestAuth()
        }
        guard let auth = captured, let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(
            serverId: auth.account.serverId,
            serverURL: auth.account.serverURL,
            profileId: profile,
            clientFamily: "apple",
            credentialGenerationID: auth.account.credentialGenerationID
        )
        _ = try await http.requestData(
            method: played ? "POST" : "DELETE",
            path: "/api/v1/watched/\(contentId)",
            requestIdentity: identity
        )
        if played {
            await MDBListSyncStore.shared.completedWatch(contentID: contentId, expected: auth)
            await SimklSyncStore.shared.completedWatch(contentID: contentId, expected: auth)
        }
        #endif
    }

    // --- Collections ---

    func collections() async throws -> CollectionsResponse {
        try await http.get("/api/v1/collections")
    }

    func collectionItems(collectionId: String, offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/collections/\(collectionId)/items", query: page(offset, limit))
    }

    // MARK: - Profiles

    /// The list belongs to the account, so it goes without the active
    /// profile. Silo refuses every request naming a removed profile, and this
    /// list is how `AuthService.reconcileAvailableProfiles` finds out.
    func listProfiles() async throws -> [UserProfile] {
        let response: ProfilesResponse = try await http.get("/api/v1/profiles", sendsProfile: false)
        return response.profiles.map(\.asUserProfile)
    }

    /// Checks a profile choice without changing the session; `AuthService`
    /// then commits the profile and its proof together. Emby and Jellyfin
    /// have one profile, their own user. A Silo profile without a PIN has
    /// nothing to verify (the server refuses an empty PIN), so only a PIN is
    /// sent, and its proof token returned.
    func verifyProfileSelection(profileId: String, pin: String?) async throws -> String? {
        switch MediaServerProvider.active {
        case .jellyfin:
            let connection = try await JellyfinConnection.current()
            guard profileId == connection.userID else { throw JellyfinError.signInRequired }
            return nil
        case .emby:
            let connection = try await EmbyConnection.current()
            guard profileId == connection.userID else { throw EmbyError.signInRequired }
            return nil
        case .silo:
            guard let pin, !pin.isEmpty else { return nil }
            let response: VerifyPinResponse = try await http.post(
                "/api/v1/profiles/\(profileId)/verify-pin",
                body: VerifyPinRequest(pin: pin)
            )
            guard response.valid else { throw APIError.httpError(statusCode: 401) }
            return response.profileToken
        }
    }

    func createProfile(
        name: String,
        avatarEmoji: String?,
        pin: String?,
        isChild: Bool,
        maxContentRating: String? = nil,
        libraryRestrictionsEnabled: Bool = false,
        allowedLibraryIds: [Int] = []
    ) async throws -> UserProfile {
        let body = CreateProfileRequestBody(
            name: name,
            avatar: avatarEmoji,
            pin: pin,
            isChild: isChild,
            maxContentRating: maxContentRating,
            libraryRestrictionsEnabled: libraryRestrictionsEnabled,
            allowedLibraryIds: allowedLibraryIds
        )
        let profile: Profile = try await http.post("/api/v1/profiles", body: body)
        return profile.asUserProfile
    }

    // MARK: - Playback

    func playbackV3Capability() async throws -> PlaybackV3CapabilityResponse {
        try await http.get("/api/v1/playback/capability")
    }

    /// Planning a session can be slow on heavy files (probing, starting a
    /// transcode), so starts and replans use the extended timeout. A dead
    /// server still fails fast, since a refused connection fails at once.
    func startPlaybackV3(request: PlaybackV3StartRequest) async throws -> PlaybackV3DecisionResponse {
        try await http.post("/api/v1/playback/start", body: request, timeout: .extended)
    }

    func replanPlaybackV3(sessionId: String, request: PlaybackV3ReplanRequest) async throws -> PlaybackV3DecisionResponse {
        try await http.post("/api/v1/playback/\(sessionId)/replan", body: request, timeout: .extended)
    }

    func reportPlaybackRouteEventV3(_ event: PlaybackV3RouteEvent) async throws {
        try await http.postVoid("/api/v1/playback/route-events", body: event)
    }

    func reportPlaybackProgress(sessionId: String, report: ProgressReport) async throws {
        try await http.postVoid("/api/v1/playback/\(sessionId)/progress", body: report)
    }

    func syncProgress(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool = false
    ) async throws {
        let item = SyncProgressItem(
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            forceOverwrite: forceOverwrite
        )
        try await http.postVoid("/api/v1/sync/progress", body: SyncProgressRequest(items: [item]))
    }

    func stopPlayback(sessionId: String) async throws {
        try await http.delete("/api/v1/playback/\(sessionId)")
    }

    // MARK: - Helpers

    private func page(_ offset: Int, _ limit: Int) -> [String: String] {
        ["offset": String(offset), "limit": String(limit)]
    }

    private func cast<T>(_ value: Any) throws -> T {
        guard let typed = value as? T else {
            throw APIError.typeMismatch(
                expected: String(describing: T.self),
                actual: String(describing: Swift.type(of: value))
            )
        }
        return typed
    }
}

/// A request path split at `/` (empty pieces dropped), for matching patterns
/// such as `api/v1/favorites/*`.
private struct APIPath {
    private let parts: [Substring]

    init(_ path: String) {
        parts = path.split(separator: "/")
    }

    func matches(_ pattern: String) -> Bool {
        captures(pattern) != nil
    }

    /// The single piece standing in for the pattern's `*`.
    func capture(_ pattern: String) -> String? {
        captures(pattern)?.first
    }

    private func captures(_ pattern: String) -> [String]? {
        let expected = pattern.split(separator: "/")
        guard expected.count == parts.count else { return nil }
        var captured: [String] = []
        for (want, part) in zip(expected, parts) {
            if want == "*" {
                captured.append(String(part))
            } else if want != part {
                return nil
            }
        }
        return captured
    }
}

enum APIError: LocalizedError {
    case httpError(statusCode: Int)
    case unsupportedPath(String)
    case unsupportedBody(expected: String)
    case typeMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            String(localized: "Server returned status \(code)")
        case .unsupportedPath(let path):
            String(localized: "Unsupported API path: \(path)")
        case .unsupportedBody(let expected):
            String(localized: "Unsupported request body. Expected \(expected).")
        case .typeMismatch(let expected, let actual):
            String(localized: "API returned \(actual), expected \(expected).")
        }
    }
}

private struct HomeDismissalBody: Encodable {
    let progressUpdatedAt: String
}

private struct NextUpDismissalBody: Encodable {
    let seriesId: String
}
