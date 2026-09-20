import Foundation

/// Reads Top Shelf data using the selected account's provider and credentials.
/// Silo retains its home-section request; native providers request resume and
/// next-up rows directly. Expired sessions return no personalised content.
struct TopShelfHTTPClient {
    enum Error: Swift.Error {
        case notAuthenticated
        case invalidURL
        case unexpectedStatus(Int)
    }

    let defaults: SharedDefaults
    let accountKeychain: SharedKeychain
    let profileKeychain: SharedKeychain
    let session: URLSession

    init(defaults: SharedDefaults = .shared,
         keychain: SharedKeychain = SharedKeychain(),
         session: URLSession = .shared) {
        self.defaults = defaults
        self.accountKeychain = keychain.withAudience(SharedStorage.accountCredentialAudience)
        self.profileKeychain = keychain.withAudience(.currentUser)
        self.session = session
    }

    var isPersonalizedContentAllowed: Bool {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey) else {
            return false
        }
        guard TopShelfProfilePolicy.allowsSavedAccountContent(
            accountsData: defaults.data(forKey: SharedStorage.savedAccountsKey),
            activeAccountID: defaults.string(forKey: SharedStorage.activeSavedAccountKey),
            serverID: serverID,
            hasStoredPIN: { profileKeychain.get("vivid.account." + $0 + ".pin.v1") != nil }
        ) else { return false }
        let state = ProfileLaunchState.load(from: defaults)
        return TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: defaults.string(forKey: SharedStorage.profileIdKey),
            accountEpoch: accountKeychain.get(
                SharedStorage.accountEpochAccount(for: serverID)
            ),
            hasStoredProfileToken: profileKeychain.get(
                SharedStorage.profileTokenAccount(for: serverID)
            ) != nil
        )
    }

    struct ContentIdentity: Equatable {
        let serverID: String?
        let serverURL: String?
        let profileID: String?
        let accountID: String?
        let epoch: String?
    }

    var contentIdentity: ContentIdentity {
        let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey)
        return ContentIdentity(serverID: serverID,
            serverURL: defaults.string(forKey: SharedStorage.serverUrlKey),
            profileID: defaults.string(forKey: SharedStorage.profileIdKey),
            accountID: defaults.string(forKey: SharedStorage.activeSavedAccountKey),
            epoch: serverID.flatMap { accountKeychain.get(SharedStorage.accountEpochAccount(for: $0)) })
    }

    var usesNativeServer: Bool {
        let id = defaults.string(forKey: SharedStorage.activeServerIdKey) ?? ""
        return id.hasPrefix("emby:") || id.hasPrefix("jellyfin:")
    }

    private struct NativeIdentity: Equatable {
        let serverID: String
        let serverURL: String
        let userID: String
        let token: String
        let epoch: String?
    }

    private func nativeIdentity() throws -> NativeIdentity {
        guard usesNativeServer, isPersonalizedContentAllowed,
              let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey),
              let url = defaults.string(forKey: SharedStorage.serverUrlKey),
              let user = accountKeychain.get("vivid.nativeUserID." + serverID),
              user == defaults.string(forKey: SharedStorage.profileIdKey),
              let token = accountKeychain.get(SharedStorage.accessTokenAccount(for: serverID)), !token.isEmpty else {
            throw Error.notAuthenticated
        }
        return NativeIdentity(serverID: serverID, serverURL: url, userID: user, token: token,
                              epoch: accountKeychain.get(SharedStorage.accountEpochAccount(for: serverID)))
    }

    func fetchImageSizeQuery() async -> [String: String] {
        if usesNativeServer { return [:] }
        let capability: ImageSizeCapabilityResponse? = try? await get(
            "/api/v1/images/capability"
        )
        return ImageSizeSelection.queryEntries(
            capability: capability,
            prefersLargeImages: true
        )
    }

    func fetchHomeSections(imageSizeQuery: [String: String]) async throws -> TopShelfSectionsResponse {
        if usesNativeServer {
            let identity = try nativeIdentity()
            let client = TopShelfNativeClient(provider: identity.serverID.hasPrefix("emby:") ? .emby : .jellyfin,
                serverURL: identity.serverURL, userID: identity.userID, token: identity.token)
            let response = try await client.fetchHomeSections()
            guard try nativeIdentity() == identity else { throw Error.notAuthenticated }
            return response
        }
        return try await get("/api/v1/home/sections", query: imageSizeQuery)
    }

    func fetchSeasons(
        seriesId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfSeasonsResponse {
        try await get(
            "/api/v1/catalog/series/\(seriesId)/seasons",
            query: imageSizeQuery
        )
    }

    func fetchItemDetail(
        contentId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfItemDetail {
        try await get(
            "/api/v1/catalog/items/\(contentId)",
            query: imageSizeQuery
        )
    }

    // MARK: - Private

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey),
              isPersonalizedContentAllowed,
              let serverUrl = defaults.string(forKey: SharedStorage.serverUrlKey),
              !serverUrl.isEmpty,
              let accessToken = accountKeychain.get(
                SharedStorage.accessTokenAccount(for: serverID)
              )
        else {
            throw Error.notAuthenticated
        }

        guard var components = URLComponents(string: serverUrl) else {
            throw Error.invalidURL
        }
        let base = components.percentEncodedPath
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = trimmed + path
        components.queryItems = query
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Error.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let profileId = defaults.string(forKey: SharedStorage.profileIdKey) {
            request.setValue(profileId, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = profileKeychain.get(
            SharedStorage.profileTokenAccount(for: serverID)
        ) {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }

        let usesV2 = try await SiloAPIDiscovery.shared.usesV2(for: url, session: session)
        if usesV2 { request = try SiloAPICompatibility.request(request) }
        let (rawData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.unexpectedStatus(http.statusCode)
        }

        let data = usesV2 ? try SiloAPICompatibility.response(rawData, path: path) : rawData
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
