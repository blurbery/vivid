import Foundation
import Observation

private final class TMDbRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@Observable @MainActor
final class TVTMDbStore {
    static let shared = TVTMDbStore()
    private(set) var isConfigured = false
    private(set) var revision = 0
    private let keychain = SharedKeychain(audience: .currentUser)
    private var credentialKey: String {
        VividCloudPreferences.activeCredentialKey("tmdb") ?? legacyCredentialKey
    }
    private var legacyCredentialKey: String {
        #if os(iOS)
        MobileProfilePreferenceKeys.key("vivid.tmdb.credential.v1")
        #else
        "vivid.tmdb.credential.v1"
        #endif
    }
    private var loadedCredentialKey: String?
    private var credential = ""
    private let session: URLSession
    private var videoCache: [String: (Date, [ItemVideo])] = [:]

    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }

    var contextKey: String {
        [ServerRegistry.shared.activeServerId ?? "", accountContext,
         AuthService.shared.profileId ?? "", String(revision)].joined(separator: "|")
    }

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: TMDbRedirectPolicy(), delegateQueue: nil)
        reloadForCurrentProfile()
    }

    func reloadForCurrentProfile(force: Bool = false) {
        guard VividCloudPreferences.matchingActiveAccount != nil else {
            credential = ""
            isConfigured = false
            loadedCredentialKey = nil
            invalidate()
            return
        }
        let key = credentialKey
        guard force || loadedCredentialKey != key else { return }
        if key != legacyCredentialKey, legacyCredentialKey != "vivid.tmdb.credential.v1", keychain.get(key) == nil, let legacy = keychain.get(legacyCredentialKey) {
            if keychain.set(legacy, for: key) { _ = keychain.delete(legacyCredentialKey) }
        }
        loadedCredentialKey = key
        credential = keychain.get(key) ?? ""
        isConfigured = !credential.isEmpty
        invalidate()
    }

    func connect(_ input: String) async throws {
        reloadForCurrentProfile()
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw Failure.unavailable }
        let key = credentialKey
        let context = contextKey
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= 4096,
              !candidate.contains(where: { $0.isWhitespace }) else { throw Failure.invalidKey }
        let validation: Validation = try await request("authentication", credential: candidate)
        guard validation.success else { throw Failure.invalidKey }
        try Task.checkCancellation()
        guard key == credentialKey, context == contextKey else { throw CancellationError() }
        guard keychain.set(candidate, for: key) else { throw Failure.storage }
        credential = candidate
        isConfigured = true
        invalidate()
        VividCloudPreferences.shared.schedule()
    }

    func disconnect() throws {
        reloadForCurrentProfile()
        guard VividCloudPreferences.matchingActiveAccount != nil else { throw Failure.unavailable }
        guard keychain.delete(credentialKey) else { throw Failure.storage }
        credential = ""
        isConfigured = false
        invalidate()
        VividCloudPreferences.shared.schedule()
    }

    private func invalidate() {
        revision += 1
        videoCache.removeAll()
    }

    func videos(contentId: String) async throws -> [ItemVideo] {
        reloadForCurrentProfile()
        guard isConfigured else { return [] }
        let context = contextKey
        let cacheKey = context + "|" + contentId
        if let cached = videoCache[cacheKey], Date().timeIntervalSince(cached.0) < 1800 { return cached.1 }
        guard let source = try await source(contentId: contentId, context: context) else { return [] }
        try checkContext(context)
        let response: Videos = try await request("\(source.kind)/\(source.id)/videos", credential: credential)
        try checkContext(context)
        let main = Self.rankedTrailers(response.results)
        var candidates = main
        if source.kind == "tv" {
            do {
                let series: Series = try await request("tv/\(source.id)", credential: credential)
                try checkContext(context)
                if let latest = series.seasons.filter({ $0.season_number > 0 }).max(by: { $0.season_number < $1.season_number }) {
                    let season: Videos = try await request("tv/\(source.id)/season/\(latest.season_number)/videos", credential: credential)
                    try checkContext(context)
                    candidates = Array(main.prefix(1)) + Self.rankedTrailers(season.results) + Array(main.dropFirst())
                }
            } catch {
                try checkContext(context)
            }
        }
        var seen = Set<String>()
        let videos = candidates.filter { seen.insert($0.key).inserted }.prefix(3).map {
            ItemVideo(kind: "trailer", site: "youtube", siteKey: $0.key,
                      name: $0.name, language: $0.iso_639_1, isOfficial: $0.official ?? false)
        }
        if videoCache.count >= 40 { videoCache.removeAll() }
        videoCache[cacheKey] = (Date(), videos)
        return videos
    }

    private func source(contentId: String, context: String) async throws -> (kind: String, id: Int)? {
        var detail = try await MetadataRequestPool.shared.itemDetail(contentId: contentId)
        try checkContext(context)
        if detail.type == "episode", let seriesID = detail.seriesId {
            detail = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
            try checkContext(context)
        }
        let kind: String
        if detail.type == "movie" { kind = "movie" }
        else if VividMediaType.isSeries(detail.type) { kind = "tv" }
        else { return nil }
        if let id = Int(detail.tmdbId ?? ""), id > 0 { return (kind,id) }
        guard MediaServerProvider.active == .emby, let imdb = detail.imdbId, imdb.range(of:"^tt[0-9]{7,10}$",options:.regularExpression) != nil else { return nil }
        let result: ExternalMatches = try await request("find/" + imdb,credential:credential,query:["external_source":"imdb_id"])
        try checkContext(context)
        let matches = kind == "movie" ? result.movie_results : result.tv_results
        guard let id = matches.first?.id, id > 0 else { return nil }
        return (kind,id)
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard isConfigured, contextKey == expected else { throw CancellationError() }
    }

    private func request<T: Decodable>(_ path: String, credential: String, query: [String:String] = [:]) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        let isAPIKey = credential.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name:$0.key,value:$0.value) } }
        if isAPIKey { components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: credential)] }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !isAPIKey { request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
            if response.statusCode == 401 || response.statusCode == 403 { throw Failure.invalidKey }
            guard response.statusCode == 200, data.count <= 2_000_000 else { throw Failure.unavailable }
            return try JSONDecoder().decode(T.self, from: data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as Failure { throw error }
        catch { throw Failure.unavailable }
    }

    enum Failure: LocalizedError {
        case invalidKey, unavailable, storage
        var errorDescription: String? {
            switch self {
            case .invalidKey: "TMDb could not validate this API key or read access token."
            case .unavailable: "TMDb is unavailable right now. Please try again."
            case .storage: "Could not update the saved TMDb key on this Apple TV."
            }
        }
    }
    private static func rankedTrailers(_ videos: [Video]) -> [Video] {
        videos.filter {
            $0.site.lowercased() == "youtube" && $0.type.lowercased() == "trailer"
                && $0.key.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
        }.sorted {
            let first = $0.official ?? false
            let second = $1.official ?? false
            if first != second { return first }
            let firstMain = ["official trailer", "main trailer", "trailer"].contains(($0.name ?? "").lowercased())
            let secondMain = ["official trailer", "main trailer", "trailer"].contains(($1.name ?? "").lowercased())
            if firstMain != secondMain { return firstMain }
            return ($0.published_at ?? "") > ($1.published_at ?? "")
        }
    }
    private struct ExternalMatches: Decodable { let movie_results: [ExternalMatch]; let tv_results: [ExternalMatch] }
    private struct ExternalMatch: Decodable { let id: Int }
    private struct Series: Decodable { let seasons: [Season] }
    private struct Season: Decodable { let season_number: Int }
    private struct Validation: Decodable { let success: Bool }
    private struct Videos: Decodable { let results: [Video] }
    private struct Video: Decodable {
        let key: String; let name: String?; let site: String; let type: String
        let official: Bool?; let iso_639_1: String?; let published_at: String?
    }
}
