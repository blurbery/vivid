import Foundation
import OSLog

@MainActor
final class TVLibrarySimilarityStore {
    static let shared = TVLibrarySimilarityStore()
    private static let logger = Logger(subsystem: "com.blurbery.vivid", category: "LibrarySimilarity")
    private var cache: [String: (Date, [SimilarPosterItem])] = [:]

    private var accountContext: String {
        #if os(tvOS)
        TVSavedAccountStore.shared.activeID ?? ""
        #else
        AuthService.shared.profileId ?? ""
        #endif
    }

    var contextKey: String {
        [ServerRegistry.shared.activeServerId ?? "", accountContext,
         AuthService.shared.profileId ?? ""].joined(separator: "|")
    }

    func suggestions(contentId: String, sourceDetail: ItemDetail? = nil) async throws -> [SimilarPosterItem] {
        Self.logger.notice("suggestions started")
        let context = contextKey
        let key = context + "|" + contentId
        if let cached = cache[key], Date().timeIntervalSince(cached.0) < 1800 { return cached.1 }
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
        Self.logger.notice("source metadata genres=\(source.genres?.count ?? 0) studios=\(source.studios?.count ?? 0) networks=\(source.networks?.count ?? 0)")
        var filters = CatalogFilterState()
        filters.genres = Set(source.genres ?? [])
        filters.studios = Set(source.studios ?? [])
        filters.networks = Set(source.networks ?? [])
        filters.matchAll = false
        guard !filters.genres.isEmpty || !filters.studios.isEmpty || !filters.networks.isEmpty else { return [] }
        filters.sort = .ratingImdb
        let mediaType: BrowseMediaType = source.type == "movie" ? .movie : .series
        let countQuery = CatalogQueryBuilder.build(filters, libraryId: nil,
            mediaType: mediaType, offset: 0, limit: 1, snapshot: nil, includeTotal: true)
        let summary: CatalogResponse = try await VividAPI.shared.get("/api/v1/catalog", query: countQuery)
        try checkContext(context)
        var candidates = summary.items
        var seen = Set(candidates.map(\.contentId))
        var complete = true
        let offsets = Self.candidateOffsets(total: summary.total ?? 300, seed: source.contentId)
        for offset in offsets {
            let query = CatalogQueryBuilder.build(filters, libraryId: nil,
                mediaType: mediaType, offset: offset, limit: 100,
                snapshot: summary.snapshot, includeTotal: false)
            do {
                let response: CatalogResponse = try await VividAPI.shared.get("/api/v1/catalog", query: query)
                try checkContext(context)
                for item in response.items where seen.insert(item.contentId).inserted {
                    candidates.append(item)
                }
            } catch {
                try checkContext(context)
                Self.logger.error("catalog failed type=\(String(describing: type(of: error)), privacy: .public)")
                if candidates.isEmpty { throw error }
                complete = false
            }
        }
        try checkContext(context)
        let result = Self.rank(candidates, relativeTo: source).map { SimilarPosterItem(item: $0) }
        Self.logger.notice("ranked count=\(result.count)")
        if complete {
            if cache.count >= 40 { cache.removeAll() }
            cache[key] = (Date(), result)
        }
        return result
    }

    static func rank(_ candidates: [BrowseItem], relativeTo source: ItemDetail) -> [BrowseItem] {
        let genres = normalized(source.genres)
        let studios = normalized(source.studios)
        let networks = normalized(source.networks)
        var seen = Set<String>()
        return candidates.compactMap { item -> (BrowseItem, Double)? in
            guard item.contentId != source.contentId, seen.insert(item.contentId).inserted,
                  source.type == "movie" ? item.type == "movie" : VividMediaType.isSeries(item.type) else { return nil }
            let itemGenres = normalized(item.genres)
            let sharedGenres = genres.intersection(itemGenres).count
            let sharedStudios = studios.intersection(normalized(item.studios)).count
            let sharedNetworks = networks.intersection(normalized(item.networks)).count
            guard sharedGenres + sharedStudios + sharedNetworks > 0 else { return nil }
            // Genre overlap dominates; production and release era break ties.
            let union = max(1, genres.union(itemGenres).count)
            var score = 100 * Double(sharedGenres) / Double(union)
            score += Double(min(sharedStudios, 2) * 8 + min(sharedNetworks, 2) * 8)
            if let year = source.year, let itemYear = item.year {
                score += max(0, 5 - Double(abs(year - itemYear)) / 5)
            }
            return (item, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let left = stableOrder(source.contentId + "|" + $0.0.contentId)
            let right = stableOrder(source.contentId + "|" + $1.0.contentId)
            if left != right { return left < right }
            return $0.0.contentId < $1.0.contentId
        }.prefix(10).map { $0.0 }
    }

    static func candidateOffsets(total: Int, seed: String) -> [Int] {
        guard total > 0 else { return [] }
        if total <= 300 { return Array(stride(from: 0, to: total, by: 100)) }
        return (0..<3).map { segment in
            let lower = total * segment / 3
            let upper = total * (segment + 1) / 3
            let room = max(1, upper - lower - 100 + 1)
            return lower + Int(stableOrder(seed + "|" + String(segment)) % UInt64(room))
        }
    }

    private static func stableOrder(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    private static func normalized(_ values: [String]?) -> Set<String> {
        Set((values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    private func checkContext(_ expected: String) throws {
        try Task.checkCancellation()
        guard contextKey == expected else { throw CancellationError() }
    }
}
