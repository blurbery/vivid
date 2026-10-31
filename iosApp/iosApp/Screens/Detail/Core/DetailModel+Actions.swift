import Foundation

/// The detail page's actions: Favourite, Watchlist and Watched, completed
/// playback, and dropping cached responses a change made stale.
extension ItemDetailViewModel {
    // MARK: - Favourite and Watchlist

    func toggleFavorite() async {
        guard let detail else { return }
        let contentId = detail.contentId
        localChangeTurn += 1
        isFavorite.toggle()
        storeUserState(for: contentId)
        do {
            if isFavorite {
                try await VividAPI.shared.putVoid("/api/v1/favorites/\(contentId)")
            } else {
                try await VividAPI.shared.delete("/api/v1/favorites/\(contentId)")
            }
            dropStaleCacheEntries(contentId: contentId)
        } catch {
            isFavorite.toggle()
            storeUserState(for: contentId)
        }
    }

    func toggleWatchlist() async {
        guard let detail else { return }
        let contentId = detail.contentId
        localChangeTurn += 1
        inWatchlist.toggle()
        storeUserState(for: contentId)
        do {
            if inWatchlist {
                try await VividAPI.shared.putVoid("/api/v1/watchlist/\(contentId)")
            } else {
                try await VividAPI.shared.delete("/api/v1/watchlist/\(contentId)")
            }
            dropStaleCacheEntries(contentId: contentId)
        } catch {
            inWatchlist.toggle()
            storeUserState(for: contentId)
        }
    }

    /// Keeps the shown pair where cards read it.
    func storeUserState(for contentId: String) {
        ResponseCache.shared.set(UserItemState(isFavorite: isFavorite, inWatchlist: inWatchlist),
                                 for: CacheKey.itemUserState(contentId))
    }

    // MARK: - Watched

    func toggleWatched() async {
        guard let detail else { return }
        _ = await writeWatched(contentId: detail.contentId, played: !isWatched)
    }

    func toggleSelectedSeasonWatched() async {
        guard let season = selectedSeason else { return }
        _ = await writeWatched(contentId: season.contentId, played: season.userData?.played != true)
    }

    /// Marks the series watched, or unwatched when every season already is.
    func toggleSeriesWatched() async {
        guard let seriesId = detail?.seriesId ?? seriesIdInUse else { return }
        let everySeasonPlayed = !seasons.isEmpty && seasons.allSatisfy { $0.userData?.played == true }
        _ = await writeWatched(contentId: seriesId, played: !everySeasonPlayed)
    }

    func setSeasonWatched(contentId: String, played: Bool) async -> Bool {
        guard seasons.contains(where: { $0.contentId == contentId }) else { return false }
        return await writeWatched(contentId: contentId, played: played)
    }

    func setEpisodeWatched(contentId: String, played: Bool) async -> Bool {
        await writeWatched(contentId: contentId, played: played)
    }

    /// Marks a title, season or series watched or unwatched. The page
    /// updates at once and rolls back if the server refuses. One write runs
    /// at a time; another started meanwhile returns false and changes
    /// nothing.
    private func writeWatched(contentId target: String, played: Bool) async -> Bool {
        guard !isWatchedWritePending else { return false }
        let refreshHome = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
        // The write drops any episode request still out, so a page from
        // before it can't undo it. A rail that was empty and waiting for
        // that request is reloaded once the write ends.
        let waitingSeasonNumber = isLoadingEpisodes ? (selectedSeason?.seasonNumber ?? detail?.seasonNumber) : nil
        localChangeTurn += 1
        watchedWriteTurn += 1
        episodeTurn += 1
        let writeEpisodeTurn = episodeTurn
        isLoadingEpisodes = false
        #if os(tvOS)
        cancelDeferredEpisodeFavoriteStateRefresh()
        #elseif os(iOS)
        stopEpisodePagePrefetch()
        #endif
        isWatchedWritePending = true

        let snapshotDetailId = detail?.contentId
        let snapshotEpisodes = episodes
        let snapshotPages = episodesBySeason
        let snapshotSeasons = seasons
        let snapshotSelectedSeason = selectedSeason
        let snapshotIsWatched = isWatched

        let seriesWide = target == seriesIdInUse || (detail?.type == "series" && detail?.contentId == target)
        let targetSeasonNumber: Int?
        if let season = seasons.first(where: { $0.contentId == target }) {
            targetSeasonNumber = season.seasonNumber
        } else if detail?.type == "season", detail?.contentId == target {
            targetSeasonNumber = detail?.seasonNumber
        } else {
            targetSeasonNumber = nil
        }

        // Episodes first, so other seasons can be recounted from them.
        let markEpisodes: ([EpisodeListItem]) -> [EpisodeListItem] = { list in
            list.map { episode in
                let inScope = seriesWide || episode.seasonNumber == targetSeasonNumber || episode.contentId == target
                return inScope ? Self.markedEpisode(episode, played: played) : episode
            }
        }
        episodes = markEpisodes(episodes)
        episodesBySeason = episodesBySeason.mapValues(markEpisodes)

        let selectedId = selectedSeason?.contentId
        seasons = seasons.map { season in
            var updated = season
            if seriesWide || season.seasonNumber == targetSeasonNumber {
                updated.userData = SeasonUserData(played: played, episodeCount: season.episodeCount)
            } else {
                let rows = season.contentId == selectedId ? episodes : episodesBySeason[season.seasonNumber]
                if let rows, !rows.isEmpty, rows.count >= season.episodeCount {
                    let playedRows = rows.filter { $0.userData?.played == true }.count
                    var userData = SeasonUserData(played: playedRows == rows.count, episodeCount: rows.count)
                    userData.watchedCount = playedRows
                    userData.unplayedCount = rows.count - playedRows
                    updated.userData = userData
                }
            }
            return updated
        }
        if let selectedId, let updated = seasons.first(where: { $0.contentId == selectedId }) {
            selectedSeason = updated
        }

        if target == detail?.contentId || seriesWide {
            isWatched = played
        } else if detail?.type == "episode", let targetSeasonNumber, detail?.seasonNumber == targetSeasonNumber {
            // The episode page's own season was written.
            isWatched = played
        } else if detail?.type == "series", !seasons.isEmpty {
            isWatched = seasons.allSatisfy { $0.userData?.played == true }
        }

        let succeeded: Bool
        do {
            try await VividAPI.shared.setWatched(contentId: target, played: played)
            dropStaleCacheEntries(contentId: target, seriesId: seriesIdInUse, seasonNumber: targetSeasonNumber)
            refreshHome()
            succeeded = true
        } catch {
            if detail?.contentId == snapshotDetailId {
                if selectedSeason?.contentId == snapshotSelectedSeason?.contentId {
                    episodes = snapshotEpisodes
                    selectedSeason = snapshotSelectedSeason
                }
                episodesBySeason = snapshotPages
                seasons = snapshotSeasons
                isWatched = snapshotIsWatched
            }
            succeeded = false
        }
        isWatchedWritePending = false

        if let waitingSeasonNumber, let seriesId = seriesIdInUse, episodeTurn == writeEpisodeTurn,
           detail?.contentId == snapshotDetailId, episodes.isEmpty,
           selectedSeason == nil || selectedSeason?.seasonNumber == waitingSeasonNumber {
            // Direct, so it can't join the dropped request if that is still
            // out and get the page from before the write.
            await loadEpisodes(seriesId: seriesId, seasonNumber: waitingSeasonNumber, fallbackSeasonNumber: nil, pooled: false)
        }
        return succeeded
    }

    /// Played, not in progress, back at the start.
    private nonisolated static func markedEpisode(_ episode: EpisodeListItem, played: Bool) -> EpisodeListItem {
        var marked = episode
        var userData = marked.userData ?? LeafItemUserData(played: played)
        userData.played = played
        userData.isInProgress = false
        userData.positionSeconds = 0
        marked.userData = userData
        return marked
    }

    // MARK: - Completed playback

    /// Marks episodes the player finished as watched in every copy the page
    /// holds. Seasons and caches are left to the reload that follows.
    func applyCompletedPlayback(contentIds: Set<String>) {
        guard !contentIds.isEmpty else { return }
        let markCompleted: ([EpisodeListItem]) -> [EpisodeListItem] = { list in
            list.map { contentIds.contains($0.contentId) ? Self.markedEpisode($0, played: true) : $0 }
        }
        let updatedEpisodes = markCompleted(episodes)
        if updatedEpisodes != episodes { episodes = updatedEpisodes }
        let updatedPages = episodesBySeason.mapValues(markCompleted)
        if updatedPages != episodesBySeason { episodesBySeason = updatedPages }
    }

    // MARK: - Stale cache entries

    /// Drops the cached responses a change to a title made stale: the title,
    /// its series and season, and the lists that show it. What is on screen
    /// stays; the next visit fetches fresh.
    func dropStaleCacheEntries(contentId: String, seriesId: String? = nil, seasonNumber: Int? = nil) {
        let cache = ResponseCache.shared
        cache.remove(CacheKey.itemDetail(contentId))
        if let series = seriesId ?? detail?.seriesId {
            cache.remove(CacheKey.itemDetail(series))
            cache.remove(CacheKey.itemSeasons(series))
            if let season = seasonNumber ?? detail?.seasonNumber {
                cache.remove(CacheKey.itemEpisodes(seriesId: series, seasonNumber: season))
            }
        }
        for key in [CacheKey.homeSections, CacheKey.recommendations, CacheKey.favorites, CacheKey.watchlist, CacheKey.history] {
            cache.remove(key)
        }
        #if os(tvOS)
        ItemDetailCache.shared.markStaleFamily(contentId: contentId)
        #endif
    }
}
