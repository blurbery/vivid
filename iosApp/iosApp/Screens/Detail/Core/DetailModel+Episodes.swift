import Foundation

/// Seasons and episode pages: which season opens first, season selection,
/// episode requests, the Continue Watching entry, iPhone and iPad warming of
/// the other seasons, and Apple TV's episode favourites.
extension ItemDetailViewModel {
    // MARK: - Initial season

    /// The season a page opens on: the resume season, else one in progress,
    /// else one partly watched, else the first unwatched (regular seasons
    /// before specials), else the first regular season.
    func preferredInitialSeason(seasons: [Season]) -> Season? {
        if let resume = initialResumeSeasonNumber, let season = seasons.first(where: { $0.seasonNumber == resume }) {
            return season
        }
        if let season = seasons.first(where: { ($0.userData?.inProgressCount ?? 0) > 0 }) {
            return season
        }
        if let season = seasons.first(where: { season in
            guard let userData = season.userData else { return false }
            let watched = userData.watchedCount ?? 0
            return watched > 0 && watched < season.episodeCount
        }) {
            return season
        }
        let isSpecials: (Season) -> Bool = { $0.isSpecials == true || $0.seasonNumber == 0 }
        if let season = seasons.first(where: { !isSpecials($0) && $0.userData?.played != true })
            ?? seasons.first(where: { $0.userData?.played != true }) {
            return season
        }
        return seasons.first(where: { !isSpecials($0) }) ?? seasons.first
    }

    // MARK: - Selecting a season

    /// Selects a season and shows its episodes: the kept page at once when
    /// there is one (unless forced), otherwise from a request.
    func selectSeason(_ season: Season, forceRefresh: Bool = false, coalescesMetadataRequest: Bool = true) async {
        #if os(iOS)
        // A tap on a chip or page replaces the Continue Watching intent.
        if !forceRefresh { initialResumeSeasonNumber = nil }
        #endif
        let fallbackSeasonNumber = shownSeasonNumber ?? selectedSeason?.seasonNumber
        selectedSeason = season
        guard let seriesId = seriesIdInUse else { return }

        if !forceRefresh, let page = episodesBySeason[season.seasonNumber] {
            episodeTurn += 1
            #if os(tvOS)
            cancelDeferredEpisodeFavoriteStateRefresh()
            #endif
            episodes = page
            shownSeasonNumber = season.seasonNumber
            isLoadingEpisodes = false
            return
        }
        await loadEpisodes(seriesId: seriesId, seasonNumber: season.seasonNumber,
                           fallbackSeasonNumber: fallbackSeasonNumber, pooled: coalescesMetadataRequest)
    }

    // MARK: - Episode pages

    /// Shows the kept or cached page straight away (or an empty, loading
    /// rail), then the server's page. A request that a newer one has
    /// replaced writes nothing.
    func loadEpisodes(seriesId: String, seasonNumber: Int, fallbackSeasonNumber: Int?, pooled: Bool) async {
        #if os(tvOS)
        cancelDeferredEpisodeFavoriteStateRefresh()
        #endif
        episodeTurn += 1
        let turn = episodeTurn

        var found = episodesBySeason[seasonNumber]
        if found == nil,
           let cached = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber),
                                                 as: EpisodesResponse.self) {
            let page = Self.sortedEpisodes(cached.episodes)
            episodesBySeason[seasonNumber] = page
            found = page
        }

        if mayShowEpisodes(of: seasonNumber) {
            if let found {
                episodes = found
                shownSeasonNumber = seasonNumber
            } else {
                episodes = []
                isLoadingEpisodes = true
            }
        }

        do {
            let response = try await requestEpisodes(seriesId: seriesId, seasonNumber: seasonNumber, pooled: pooled)
            guard turn == episodeTurn else { return }
            ResponseCache.shared.set(response, for: CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber))
            let page = Self.sortedEpisodes(response.episodes)
            episodesBySeason[seasonNumber] = page
            if mayShowEpisodes(of: seasonNumber) {
                episodes = page
                shownSeasonNumber = seasonNumber
                isLoadingEpisodes = false
            }
        } catch {
            guard turn == episodeTurn else { return }
            if mayShowEpisodes(of: seasonNumber) {
                // With nothing to show for the new season, go back to the
                // season that was on screen.
                if found == nil, let fallbackSeasonNumber, let page = episodesBySeason[fallbackSeasonNumber],
                   let fallback = seasons.first(where: { $0.seasonNumber == fallbackSeasonNumber }) {
                    selectedSeason = fallback
                    episodes = page
                    shownSeasonNumber = fallbackSeasonNumber
                }
                isLoadingEpisodes = false
            }
        }

        #if os(tvOS)
        if turn == episodeTurn, mayShowEpisodes(of: seasonNumber) {
            scheduleEpisodeFavoriteRefresh(page: episodesBySeason[seasonNumber] ?? episodes, turn: turn)
        }
        #endif
    }

    /// A season's episodes may be shown when no season is selected or that
    /// season is.
    private func mayShowEpisodes(of seasonNumber: Int) -> Bool {
        selectedSeason == nil || selectedSeason?.seasonNumber == seasonNumber
    }

    /// One season's episode page: an injected request when given, else on
    /// Jellyfin centred on the resume episode for its season, else pooled or
    /// direct.
    func requestEpisodes(seriesId: String, seasonNumber: Int, pooled: Bool,
                         injected: (@Sendable (String, Int) async throws -> EpisodesResponse)? = nil) async throws -> EpisodesResponse {
        if let injected {
            return try await injected(seriesId, seasonNumber)
        }
        if MediaServerProvider.active == .jellyfin, let resume = jellyfinResumeEpisode, resume.seasonNumber == seasonNumber {
            return try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber,
                                                      jellyfinResumeEpisodeId: resume.contentId)
        }
        if pooled {
            return try await MetadataRequestPool.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber)
        }
        return try await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: seasonNumber)
    }

    // MARK: - Season list

    /// Loads the season list. A watched change made while it loads drops
    /// the response, which may not include it yet; a favourite or watchlist
    /// change doesn't touch seasons, so it keeps the response.
    func loadSeasonList(seriesId: String, autoSelect: Bool, pooled: Bool) async {
        let writeTurn = watchedWriteTurn
        let response: SeasonsResponse
        do {
            response = pooled
                ? try await MetadataRequestPool.shared.seasons(seriesId: seriesId)
                : try await VividAPI.shared.seasons(seriesId: seriesId)
        } catch {
            return
        }
        guard watchedWriteTurn == writeTurn else { return }
        ResponseCache.shared.set(response, for: CacheKey.itemSeasons(seriesId))
        seasons = response.seasons.sortedForDisplay()
        guard autoSelect, let initial = preferredInitialSeason(seasons: seasons) else { return }
        #if os(iOS)
        initialResumeSeasonNumber = nil
        #endif
        await selectSeason(initial, forceRefresh: true, coalescesMetadataRequest: pooled)
    }

    // MARK: - Continue Watching entry

    /// Requests the season list and the resume season's episodes together,
    /// alongside the catalogue request, when a Continue Watching card opens
    /// a series. Returns true only when both answered or, when the list no
    /// longer has the resume season, when the list answered and the season
    /// that replaced it is now selected and shown (its page is then loaded
    /// the usual way and the resume season's page is not used). A season
    /// tap made meanwhile wins, and unchanged data is not assigned again, so
    /// an open page doesn't redraw. The resume intent is left for the caller.
    @discardableResult
    func loadContinueWatchingStructure(
        contentId: String,
        seasonNumber: Int?,
        detailGeneration expectedDetailGeneration: Int? = nil,
        fetchSeasons: @escaping @Sendable (String) async throws -> SeasonsResponse = { try await MetadataRequestPool.shared.seasons(seriesId: $0) },
        fetchEpisodes: (@Sendable (String, Int) async throws -> EpisodesResponse)? = nil
    ) async -> Bool {
        guard let requested = seasonNumber else { return false }
        // Before any suspension, so a season tap made while these requests
        // are out finds the series and takes a newer turn.
        seriesIdInUse = contentId
        let turn = episodeTurn
        defer {
            if episodeTurn == turn && isLoadingEpisodes { isLoadingEpisodes = false }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled
                && (expectedDetailGeneration == nil || expectedDetailGeneration == publishTurn)
                && episodeTurn == turn
        }

        async let pageAnswer = structureEpisodes(contentId: contentId, seasonNumber: requested, injected: fetchEpisodes)
        async let listAnswer = Self.structureSeasons(contentId: contentId, fetch: fetchSeasons)

        let list = await listAnswer
        guard isCurrent() else { return false }
        if let list {
            ResponseCache.shared.set(list, for: CacheKey.itemSeasons(contentId))
            let ordered = list.seasons.sortedForDisplay()
            if ordered != seasons { seasons = ordered }
        }

        guard let target = seasons.first(where: { $0.seasonNumber == requested })
                ?? preferredInitialSeason(seasons: seasons) else { return false }
        #if os(tvOS)
        if selectedSeason?.seasonNumber != target.seasonNumber || shownSeasonNumber != target.seasonNumber {
            episodes = episodesBySeason[target.seasonNumber] ?? []
        }
        #endif
        if selectedSeason != target { selectedSeason = target }

        if target.seasonNumber != requested {
            // The requested season is gone: load the one that replaced it.
            await selectSeason(target, forceRefresh: true)
            return list != nil
                && !Task.isCancelled
                && (expectedDetailGeneration == nil || expectedDetailGeneration == publishTurn)
                && selectedSeason?.seasonNumber == target.seasonNumber
                && shownSeasonNumber == target.seasonNumber
        }

        let waitsForEpisodes = episodes.isEmpty
        if isLoadingEpisodes != waitsForEpisodes { isLoadingEpisodes = waitsForEpisodes }
        let page = await pageAnswer
        guard isCurrent() else { return false }
        if let page {
            ResponseCache.shared.set(page, for: CacheKey.itemEpisodes(seriesId: contentId, seasonNumber: requested))
            let sorted = Self.sortedEpisodes(page.episodes)
            if episodesBySeason[requested] != sorted { episodesBySeason[requested] = sorted }
            if episodes != sorted { episodes = sorted }
            shownSeasonNumber = requested
        }
        if isLoadingEpisodes { isLoadingEpisodes = false }
        return list != nil && page != nil
    }

    /// The resume season's page, or nil when the request failed.
    private func structureEpisodes(contentId: String, seasonNumber: Int,
                                   injected: (@Sendable (String, Int) async throws -> EpisodesResponse)?) async -> EpisodesResponse? {
        try? await requestEpisodes(seriesId: contentId, seasonNumber: seasonNumber, pooled: true, injected: injected)
    }

    /// The season list, or nil when the request failed.
    private nonisolated static func structureSeasons(contentId: String,
                                                     fetch: @Sendable (String) async throws -> SeasonsResponse) async -> SeasonsResponse? {
        try? await fetch(contentId)
    }

    // MARK: - Warming other seasons (iPhone and iPad)

    #if os(iOS)
    /// Keeps the other seasons' episode pages ready, nearest season first,
    /// once the visible selectors have what they need: cached pages at once,
    /// the rest two at a time from the server.
    func prefetchSeasonsAfterPlaybackSelectors() {
        guard let seriesId = seriesIdInUse, let selected = selectedSeason else { return }
        stopEpisodePagePrefetch()

        let anchor = seasons.firstIndex(where: { $0.id == selected.id }) ?? 0
        let others = seasons.enumerated()
            .filter { $0.element.seasonNumber != selected.seasonNumber }
            .sorted { (abs($0.offset - anchor), $0.offset) < (abs($1.offset - anchor), $1.offset) }
            .map(\.element)

        var missing: [Int] = []
        for season in others where episodesBySeason[season.seasonNumber] == nil {
            let number = season.seasonNumber
            if let cached = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: number),
                                                     as: EpisodesResponse.self) {
                episodesBySeason[number] = Self.sortedEpisodes(cached.episodes)
            } else {
                missing.append(number)
            }
        }
        guard !missing.isEmpty else { return }

        seasonWarming = Task { [weak self] in
            for start in stride(from: 0, to: missing.count, by: 2) {
                if Task.isCancelled { return }
                let pair = Array(missing[start..<min(start + 2, missing.count)])
                let answers = await withTaskGroup(of: (Int, EpisodesResponse?).self) { group in
                    for number in pair {
                        group.addTask {
                            (number, try? await VividAPI.shared.episodes(seriesId: seriesId, seasonNumber: number))
                        }
                    }
                    var collected: [Int: EpisodesResponse] = [:]
                    for await (number, response) in group {
                        if let response { collected[number] = response }
                    }
                    return collected
                }
                guard !Task.isCancelled, let self, self.seriesIdInUse == seriesId else { return }
                for number in pair {
                    guard let response = answers[number] else { continue }
                    ResponseCache.shared.set(response, for: CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: number))
                    if self.episodesBySeason[number] == nil {
                        self.episodesBySeason[number] = ItemDetailViewModel.sortedEpisodes(response.episodes)
                    }
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.seasonWarming = nil
        }
    }

    func stopEpisodePagePrefetch() {
        seasonWarming?.cancel()
        seasonWarming = nil
    }
    #endif

    // MARK: - Episode favourites (Apple TV)

    #if os(tvOS)
    /// Stops a scheduled or running favourite refresh; a refresh already
    /// asking the server discards its answers.
    func cancelDeferredEpisodeFavoriteStateRefresh() {
        favoriteRefresh?.cancel()
        favoriteRefresh = nil
        favoriteRefreshTurn += 1
    }

    /// Favourites or unfavourites one episode (or the page's own title).
    /// Nothing changes on screen until the server accepts it.
    func setEpisodeFavorite(contentId: String, isFavorite: Bool) async -> Bool {
        do {
            try await VividAPI.shared.toggleFavorite(contentId: contentId, isFavorite: isFavorite)
        } catch {
            return false
        }
        if contentId == detail?.contentId {
            localChangeTurn += 1
            self.isFavorite = isFavorite
            storeUserState(for: contentId)
        } else {
            // Its watchlist half isn't known here.
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
        }
        episodeFavoriteEdits[contentId, default: 0] += 1
        episodeFavoriteStates[contentId] = isFavorite
        dropStaleCacheEntries(contentId: contentId)
        return true
    }

    /// Refreshes the shown episodes' favourite flags shortly after a page
    /// settles, at low priority: asks the server about each episode, six at
    /// a time, and publishes the answers if the same episodes are still
    /// shown. A flag changed here since the refresh began keeps its local
    /// value. The task re-reads its weak reference after every wait, so a
    /// model that has gone away stops it.
    private func scheduleEpisodeFavoriteRefresh(page: [EpisodeListItem], turn: Int) {
        guard !page.isEmpty else { return }
        favoriteRefresh?.cancel()
        let ids = page.map(\.contentId)
        favoriteRefresh = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled, let start = self?.beginEpisodeFavoriteRefresh(episodeTurn: turn) else { return }
            var answers: [String: Bool] = [:]
            for batchStart in stride(from: 0, to: ids.count, by: 6) {
                guard !Task.isCancelled, self?.favoriteRefreshTurn == start.refreshTurn else { return }
                let batch = Array(ids[batchStart..<min(batchStart + 6, ids.count)])
                let batchAnswers = await ItemDetailViewModel.favoriteAnswers(for: batch)
                answers.merge(batchAnswers) { _, new in new }
                guard !Task.isCancelled, self?.favoriteRefreshTurn == start.refreshTurn else { return }
            }
            self?.publishEpisodeFavoriteStates(answers, queried: ids, refreshTurn: start.refreshTurn,
                                               editsAtStart: start.edits)
            guard !Task.isCancelled, self?.episodeTurn == turn else { return }
            self?.favoriteRefresh = nil
        }
    }

    /// Takes a refresh turn and notes each episode's edit count, unless a
    /// newer episode load has started.
    private func beginEpisodeFavoriteRefresh(episodeTurn turn: Int) -> (refreshTurn: Int, edits: [String: Int])? {
        guard episodeTurn == turn else { return nil }
        favoriteRefreshTurn += 1
        return (favoriteRefreshTurn, episodeFavoriteEdits)
    }

    /// One batch of favourite lookups, asked together; a failed lookup
    /// gives no answer.
    private nonisolated static func favoriteAnswers(for ids: [String]) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool?).self) { group in
            for id in ids {
                group.addTask { (id, try? await VividAPI.shared.isFavorite(contentId: id)) }
            }
            var collected: [String: Bool] = [:]
            for await (id, value) in group {
                if let value { collected[id] = value }
            }
            return collected
        }
    }

    /// Publishes a refresh's answers if its turn is still the newest and the
    /// same episodes are shown.
    private func publishEpisodeFavoriteStates(_ answers: [String: Bool], queried ids: [String],
                                              refreshTurn: Int, editsAtStart: [String: Int]) {
        let shown = Set(episodes.map(\.contentId))
        guard favoriteRefreshTurn == refreshTurn, shown == Set(ids) else { return }
        var states = episodeFavoriteStates.filter { shown.contains($0.key) }
        for (id, value) in answers where episodeFavoriteEdits[id, default: 0] == editsAtStart[id, default: 0] {
            states[id] = value
        }
        episodeFavoriteStates = states
    }
    #endif
}
