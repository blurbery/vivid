import Foundation
import OSLog

/// More Like This from the viewer's own library. Emby and Jellyfin ask the
/// server for similar titles. Silo has no such endpoint, so Vivid samples the
/// catalogue for titles sharing the source's genres, studios or networks and
/// ranks them on the device.
@MainActor
final class TVLibrarySimilarityStore {
    static let shared = TVLibrarySimilarityStore()

    private static let logger = Logger(subsystem: "com.blurbery.vivid", category: "LibrarySimilarity")
    private static let cacheLifetime: TimeInterval = 1800
    private static let cacheCapacity = 40
    private static let resultLimit = 10
    /// Native Silo cursors bind the page size as well as the filters, so the
    /// first page and every sampled page use the same size.
    private static let candidatePageSize = 100

    private struct CachedResult {
        let savedAt: Date
        let items: [SimilarPosterItem]
    }

    private var cache: [String: CachedResult] = [:]

    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }

    /// The server, account and profile the suggestions belong to.
    var contextKey: String {
        [ServerRegistry.shared.activeServerId ?? "", accountContext,
         AuthService.shared.profileId ?? ""].joined(separator: "|")
    }

    /// Up to ten titles like `contentId` (an episode stands in for its
    /// series). Pass `sourceDetail` when the page already has it. Throws
    /// `CancellationError` when the server, account or profile changes
    /// while it works.
    func suggestions(contentId: String, sourceDetail: ItemDetail? = nil) async throws -> [SimilarPosterItem] {
        Self.logger.notice("suggestions started")
        let context = contextKey
        let key = context + "|" + contentId
        if let cached = cache[key], Date().timeIntervalSince(cached.savedAt) < Self.cacheLifetime {
            return cached.items
        }

        var source: ItemDetail
        if let sourceDetail, sourceDetail.contentId == contentId {
            source = sourceDetail
        } else {
            source = try await MetadataRequestPool.shared.itemDetail(contentId: contentId)
        }
        try checkContext(context)
        if source.type == "episode", let seriesID = source.seriesId {
            source = try await MetadataRequestPool.shared.itemDetail(contentId: seriesID)
            try checkContext(context)
        }
        guard source.type == "movie" || VividMediaType.isSeries(source.type) else { return [] }

        switch MediaServerProvider.active {
        case .jellyfin:
            let connection = try await JellyfinConnection.current()
            let sourceID = try JellyfinConnection.id(source.contentId)
            let catalog = try await JellyfinAdapter(connection: connection).items(
                "/Items/\(sourceID)/Similar", query: ["Limit": "12", "Fields": "Overview,Genres,Studios,ProviderIds,PrimaryImageAspectRatio"]
            )
            let response: CatalogResponse = try JellyfinAdapter.decode(catalog)
            try checkContext(context)
            return store(serverSuggestions(response, excluding: source), for: key)
        case .emby:
            let connection = try await EmbyConnection.current()
            let sourceID = try EmbyConnection.id(source.contentId)
            // Poster cards only need browse fields, not cast, chapters or file details.
            let catalog = try await EmbyAdapter(connection: connection).items(
                "/Items/\(sourceID)/Similar", query: ["Limit": "12", "Fields": EmbyAdapter.browseFields]
            )
            let response: CatalogResponse = try EmbyAdapter.decode(catalog)
            try checkContext(context)
            return store(serverSuggestions(response, excluding: source), for: key)
        case .silo:
            return try await siloSuggestions(for: source, context: context, key: key)
        }
    }

    // MARK: Silo

    private func siloSuggestions(for source: ItemDetail, context: String, key: String) async throws -> [SimilarPosterItem] {
        Self.logger.notice("source metadata genres=\(source.genres?.count ?? 0) studios=\(source.studios?.count ?? 0) networks=\(source.networks?.count ?? 0)")
        var filters = CatalogFilterState()
        filters.genres = Set(source.genres ?? [])
        filters.studios = Set(source.studios ?? [])
        filters.networks = Set(source.networks ?? [])
        filters.matchAll = false
        guard !filters.genres.isEmpty || !filters.studios.isEmpty || !filters.networks.isEmpty else { return [] }
        filters.sort = .ratingImdb
        let mediaType: BrowseMediaType = source.type == "movie" ? .movie : .series

        let firstQuery = CatalogQueryBuilder.build(filters, libraryId: nil,
            mediaType: mediaType, offset: 0, limit: Self.candidatePageSize, snapshot: nil, includeTotal: true)
        let first: CatalogResponse = try await VividAPI.shared.get("/api/v1/catalog", query: firstQuery)
        try checkContext(context)

        var candidates = first.items
        var seen = Set(candidates.map(\.contentId))
        var isComplete = true
        let offsets = Self.candidateOffsets(total: first.total ?? 300, seed: source.contentId)
        for offset in offsets where offset != 0 {
            let query = CatalogQueryBuilder.build(filters, libraryId: nil,
                mediaType: mediaType, offset: offset, limit: Self.candidatePageSize,
                snapshot: first.snapshot, includeTotal: false)
            do {
                let page: CatalogResponse = try await VividAPI.shared.get("/api/v1/catalog", query: query)
                try checkContext(context)
                candidates += page.items.filter { seen.insert($0.contentId).inserted }
            } catch {
                try checkContext(context)
                Self.logger.error("catalog failed type=\(String(describing: type(of: error)), privacy: .public)")
                if candidates.isEmpty { throw error }
                isComplete = false
            }
        }
        try checkContext(context)

        let result = Self.rank(candidates, relativeTo: source).map { SimilarPosterItem(item: $0) }
        Self.logger.notice("ranked count=\(result.count)")
        // A partial sample isn't kept, so the next visit tries again.
        return isComplete ? store(result, for: key) : result
    }

    /// Up to ten library titles like `source`, best first: the same kind of
    /// title, sharing at least one genre, studio or network. Genre overlap
    /// counts most; shared studios, networks and a close release year break
    /// ties. Equal scores keep an order that depends only on the source and
    /// the candidates' ids.
    static func rank(_ candidates: [BrowseItem], relativeTo source: ItemDetail) -> [BrowseItem] {
        let genres = normalised(source.genres)
        let studios = normalised(source.studios)
        let networks = normalised(source.networks)
        var seen = Set<String>()
        var scored: [(item: BrowseItem, score: Double)] = []
        for item in candidates {
            guard item.contentId != source.contentId, seen.insert(item.contentId).inserted,
                  source.type == "movie" ? item.type == "movie" : VividMediaType.isSeries(item.type) else { continue }
            let itemGenres = normalised(item.genres)
            let sharedGenres = genres.intersection(itemGenres).count
            let sharedStudios = studios.intersection(normalised(item.studios)).count
            let sharedNetworks = networks.intersection(normalised(item.networks)).count
            guard sharedGenres + sharedStudios + sharedNetworks > 0 else { continue }

            var score = 100 * Double(sharedGenres) / Double(max(1, genres.union(itemGenres).count))
            score += Double(min(sharedStudios, 2) * 8 + min(sharedNetworks, 2) * 8)
            if let year = source.year, let itemYear = item.year {
                score += max(0, 5 - Double(abs(year - itemYear)) / 5)
            }
            scored.append((item, score))
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            let leftOrder = stableOrder(source.contentId + "|" + left.item.contentId)
            let rightOrder = stableOrder(source.contentId + "|" + right.item.contentId)
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return left.item.contentId < right.item.contentId
        }
        .prefix(resultLimit)
        .map(\.item)
    }

    /// Where to read 100-title pages of a catalogue of `total` titles: every
    /// page of a small one, otherwise one page from each third, placed by
    /// `seed` so the same source always samples the same pages.
    static func candidateOffsets(total: Int, seed: String) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 3 * candidatePageSize {
            return Array(stride(from: 0, to: total, by: candidatePageSize))
        }
        return (0..<3).map { third in
            let lower = total * third / 3
            let upper = total * (third + 1) / 3
            let room = max(1, upper - lower - candidatePageSize + 1)
            return lower + Int(stableOrder(seed + "|" + String(third)) % UInt64(room))
        }
    }

    // MARK: Helpers

    /// The server's own similar titles without the source or repeats.
    private func serverSuggestions(_ response: CatalogResponse, excluding source: ItemDetail) -> [SimilarPosterItem] {
        var seen = Set<String>()
        return response.items
            .filter { $0.contentId != source.contentId && seen.insert($0.contentId).inserted }
            .prefix(Self.resultLimit)
            .map { SimilarPosterItem(item: $0) }
    }

    private func store(_ items: [SimilarPosterItem], for key: String) -> [SimilarPosterItem] {
        if cache.count >= Self.cacheCapacity { cache.removeAll() }
        cache[key] = CachedResult(savedAt: Date(), items: items)
        return items
    }

    /// FNV-1a, so tie order stays the same between launches.
    private static func stableOrder(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    private static func normalised(_ values: [String]?) -> Set<String> {
        Set((values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard contextKey == expected else { throw CancellationError() }
    }
}
