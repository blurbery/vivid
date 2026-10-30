#if os(tvOS)
import Foundation

/// Keeps the detail page models of recently opened titles, so going back to
/// one paints at once, and warms the data a focused card would open.
@MainActor
final class ItemDetailCache {
    static let shared = ItemDetailCache()

    private static let capacity = 20

    private var models: [String: ItemDetailViewModel] = [:]
    /// Content ids, least recently used first.
    private var recency: [String] = []

    private init() {}

    func viewModel(for contentId: String) -> ItemDetailViewModel {
        if let model = models[contentId] {
            model.hydrateFromCache(contentId: contentId)
            markUsed(contentId)
            return model
        }
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: contentId)
        models[contentId] = model
        markUsed(contentId)
        while recency.count > Self.capacity {
            models.removeValue(forKey: recency.removeFirst())
        }
        return model
    }

    /// Fills the response cache with what the title's page and its play
    /// button need, after a short settle. Stops quietly when the card loses
    /// focus or the server or profile changes.
    func prepareFocusedDetail(contentId id: String) async {
        let serverId = ServerRegistry.shared.activeServerId
        let profileId = ServerRegistry.shared.activeProfileId
        let isCurrent = {
            !Task.isCancelled
                && ServerRegistry.shared.activeServerId == serverId
                && ServerRegistry.shared.activeProfileId == profileId
        }
        let responses = ResponseCache.shared
        let pool = MetadataRequestPool.shared
        do {
            try await Task.sleep(for: .milliseconds(180))
            guard isCurrent() else { return }

            let detailKey = CacheKey.itemDetail(id)
            let detail = try await cachedOrFetched(detailKey) { try await pool.itemDetail(contentId: id) }
            guard isCurrent() else { return }
            responses.set(detail, for: detailKey)
            var playbackId = detail.contentId

            if detail.type == "series" {
                let seasonsKey = CacheKey.itemSeasons(id)
                let seasons = try await cachedOrFetched(seasonsKey) { try await pool.seasons(seriesId: id) }
                guard isCurrent() else { return }
                responses.set(seasons, for: seasonsKey)

                let chooser = models[id] ?? ItemDetailViewModel()
                guard let season = chooser.preferredInitialSeason(seasons: seasons.seasons.sortedForDisplay()) else { return }
                let number = season.seasonNumber
                let episodesKey = CacheKey.itemEpisodes(seriesId: id, seasonNumber: number)
                let episodes = try await cachedOrFetched(episodesKey) {
                    try await pool.episodes(seriesId: id, seasonNumber: number)
                }
                guard isCurrent() else { return }
                responses.set(episodes, for: episodesKey)

                let ordered = episodes.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
                let next = ordered.first(where: { $0.userData?.isInProgress == true })
                    ?? ordered.first(where: { $0.userData?.played != true })
                    ?? ordered.first
                guard let next else { return }
                playbackId = next.contentId
            } else if detail.type == "episode", let seriesId = detail.seriesId {
                let seriesKey = CacheKey.itemDetail(seriesId)
                if responses.get(seriesKey, as: ItemDetail.self) == nil {
                    let series = try await pool.itemDetail(contentId: seriesId)
                    guard isCurrent() else { return }
                    responses.set(series, for: seriesKey)
                }
            }

            guard ["movie", "series", "episode"].contains(detail.type) else { return }
            let watchKey = CacheKey.itemWatchDetail(playbackId)
            if responses.get(watchKey, as: WatchDetail.self) == nil {
                let watch = try await pool.watchDetail(contentId: playbackId)
                guard isCurrent() else { return }
                responses.set(watch, for: watchKey)
            }
        } catch {
            // Cancelled or failed: the page loads normally when opened.
        }
    }

    /// Reloads a title after a change made on it, with its series and season
    /// pages when they are kept here.
    func markStaleFamily(contentId: String) {
        refresh(contentId)
        guard let detail = models[contentId]?.detail, let seriesId = detail.seriesId else { return }
        refresh(seriesId)
        if let season = detail.seasonNumber, season > 0 {
            refresh("\(seriesId)-S\(season)")
        }
    }

    /// Reloads the kept pages a playback session touched, most recently used
    /// first, and returns the ids it set out to reload.
    @discardableResult
    func refreshAfterPlayback(contentIds: Set<String>) async -> Set<String> {
        var targets = contentIds
        for id in contentIds {
            guard let detail = models[id]?.detail,
                  let seriesId = detail.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !seriesId.isEmpty else { continue }
            targets.insert(seriesId)
            if let season = detail.seasonNumber {
                targets.insert("\(seriesId)-S\(season)")
            }
        }
        let ordered = recency.reversed().filter { targets.contains($0) }
        for id in ordered {
            guard let model = models[id] else { continue }
            await model.loadDetail(contentId: id, coalescesMetadataRequests: false)
        }
        return Set(ordered)
    }

    func clearAll() {
        models.removeAll()
        recency.removeAll()
    }

    private func cachedOrFetched<Value>(_ key: String, fetch: () async throws -> Value) async throws -> Value {
        if let cached = ResponseCache.shared.get(key, as: Value.self) { return cached }
        return try await fetch()
    }

    private func markUsed(_ id: String) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    /// Starts a reload of a kept page without waiting for it.
    private func refresh(_ id: String) {
        guard let model = models[id] else { return }
        Task { @MainActor in
            await model.loadDetail(contentId: id, coalescesMetadataRequests: false)
        }
    }
}
#endif
