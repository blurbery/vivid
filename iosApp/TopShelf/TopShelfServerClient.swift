import Foundation

/// Reads the signed-in server and profile the app left in the shared app
/// group and Keychain, and fetches what the Top Shelf shows. Personal rows
/// are only shown when the app's profile rules allow it.
struct TopShelfServerClient {
    enum Failure: Error {
        case notAuthenticated
        case invalidURL
        case unexpectedStatus(Int)
    }

    /// Everything that decides whose rows these are. A change while loading
    /// means the result belongs to someone else.
    struct ContentIdentity: Equatable {
        let serverId: String?
        let serverURL: String?
        let profileId: String?
        let savedAccountId: String?
        let accountEpoch: String?
    }

    /// The credentials an Emby or Jellyfin fetch is made with.
    private struct NativeIdentity: Equatable {
        let serverId: String
        let serverURL: String
        let userID: String
        let token: String
        let accountEpoch: String?
    }

    private let defaults: SharedDefaults
    private let accountKeychain: SharedKeychain
    private let profileKeychain: SharedKeychain
    private let session: URLSession

    init(defaults: SharedDefaults = .shared, keychain: SharedKeychain = SharedKeychain(), session: URLSession = .shared) {
        self.defaults = defaults
        accountKeychain = keychain.withAudience(SharedStorage.accountCredentialAudience)
        profileKeychain = keychain.withAudience(.currentUser)
        self.session = session
    }

    // MARK: State

    private var activeServerId: String? {
        guard let serverId = defaults.string(forKey: SharedStorage.activeServerIdKey), !serverId.isEmpty else { return nil }
        return serverId
    }

    private var activeProfileId: String? {
        defaults.string(forKey: SharedStorage.profileIdKey)
    }

    private func accountEpoch(for serverId: String) -> String? {
        accountKeychain.get(SharedStorage.accountEpochAccount(for: serverId))
    }

    var contentIdentity: ContentIdentity {
        let serverId = activeServerId
        return ContentIdentity(
            serverId: serverId,
            serverURL: defaults.string(forKey: SharedStorage.serverUrlKey),
            profileId: activeProfileId,
            savedAccountId: defaults.string(forKey: SharedStorage.activeSavedAccountKey),
            accountEpoch: serverId.flatMap(accountEpoch(for:))
        )
    }

    var isNativeServer: Bool {
        let serverId = activeServerId ?? ""
        return serverId.hasPrefix("emby:") || serverId.hasPrefix("jellyfin:")
    }

    /// The same checks the app makes before it shows one profile's rows
    /// outside the profile itself.
    var allowsPersonalizedContent: Bool {
        guard let serverId = activeServerId else { return false }
        let profileKeychain = profileKeychain
        guard TopShelfProfilePolicy.allowsSavedAccountContent(
            accountsData: defaults.data(forKey: SharedStorage.savedAccountsKey),
            activeAccountID: defaults.string(forKey: SharedStorage.activeSavedAccountKey),
            serverID: serverId,
            hasStoredPIN: { accountID in profileKeychain.get("vivid.account.\(accountID).pin.v1") != nil }
        ) else { return false }
        let epoch = accountEpoch(for: serverId)
        guard TopShelfProfilePolicy.allowsViewingProfileCount(
            countsData: defaults.data(forKey: SharedStorage.viewingProfileCountsKey),
            serverID: serverId,
            accountEpoch: epoch
        ) else { return false }
        return TopShelfProfilePolicy.allowsPersonalizedContent(
            state: ProfileLaunchState.load(from: defaults),
            serverID: serverId,
            activeProfileID: activeProfileId,
            accountEpoch: epoch,
            hasStoredProfileToken: profileKeychain.get(SharedStorage.profileTokenAccount(for: serverId)) != nil,
            now: Date()
        )
    }

    private func nativeIdentity() throws -> NativeIdentity {
        guard isNativeServer, allowsPersonalizedContent,
              let serverId = activeServerId,
              let serverURL = defaults.string(forKey: SharedStorage.serverUrlKey),
              let userID = accountKeychain.get("vivid.nativeUserID.\(serverId)"),
              userID == activeProfileId,
              let token = accountKeychain.get(SharedStorage.accessTokenAccount(for: serverId)), !token.isEmpty
        else { throw Failure.notAuthenticated }
        return NativeIdentity(
            serverId: serverId, serverURL: serverURL, userID: userID, token: token,
            accountEpoch: accountEpoch(for: serverId)
        )
    }

    // MARK: Requests

    /// Asks for large artwork where a Silo server offers it.
    func imageSizeQuery() async -> [String: String] {
        guard !isNativeServer else { return [:] }
        let capability: ImageSizeCapabilityResponse? = try? await get("/api/v1/images/capability")
        return ImageSizeSelection.queryEntries(capability: capability, prefersLargeImages: true)
    }

    func fetchHomeSections(query: [String: String]) async throws -> TopShelfSectionsResponse {
        guard isNativeServer else {
            return try await get("/api/v1/home/sections", query: query)
        }
        let identity = try nativeIdentity()
        let provider: TopShelfNativeClient.Provider = identity.serverId.hasPrefix("emby:") ? .emby : .jellyfin
        let client = TopShelfNativeClient(
            provider: provider, serverURL: identity.serverURL, userID: identity.userID, token: identity.token
        )
        let response = try await client.fetchHomeSections()
        // The person may have switched profile or signed out meanwhile.
        guard try nativeIdentity() == identity else { throw Failure.notAuthenticated }
        return response
    }

    func seasons(seriesId: String, query: [String: String]) async throws -> TopShelfSeasonsResponse {
        try await get("/api/v1/catalog/series/\(seriesId)/seasons", query: query)
    }

    func itemDetail(contentId: String, query: [String: String]) async throws -> TopShelfItemDetail {
        try await get("/api/v1/catalog/items/\(contentId)", query: query)
    }

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Response {
        guard let serverId = activeServerId, allowsPersonalizedContent,
              let serverURL = defaults.string(forKey: SharedStorage.serverUrlKey), !serverURL.isEmpty,
              let token = accountKeychain.get(SharedStorage.accessTokenAccount(for: serverId))
        else { throw Failure.notAuthenticated }

        guard var components = URLComponents(string: serverURL) else { throw Failure.invalidURL }
        var basePath = components.percentEncodedPath
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Failure.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let profileId = activeProfileId, !profileId.isEmpty {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = profileKeychain.get(SharedStorage.profileTokenAccount(for: serverId)), !profileToken.isEmpty {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }

        let usesV2 = try await SiloAPIDiscovery.shared.usesV2(for: url, session: session)
        if usesV2 {
            request = try SiloAPICompatibility.request(request)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw Failure.unexpectedStatus(0) }
        guard (200...299).contains(httpResponse.statusCode) else { throw Failure.unexpectedStatus(httpResponse.statusCode) }

        // Root-relative artwork resolves against the server that answered.
        let body = usesV2
            ? try SiloAPICompatibility.response(data, path: path, requestURL: httpResponse.url ?? request.url)
            : data
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Response.self, from: body)
    }
}
