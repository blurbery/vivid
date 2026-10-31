import Foundation
import Observation

/// A title's favourite and watchlist flags, kept in the response cache so
/// cards and detail pages show the same pair.
struct UserItemState {
    let isFavorite: Bool
    let inWatchlist: Bool
}

/// The trailer search a page could once start from its Find Trailers
/// button. Nothing in the shipped apps starts it, so this stand-in only
/// keeps the pages' references compiling: it never reports a status and
/// never fetches.
@MainActor
final class TrailerFetchCoordinator {
    nonisolated init() {}

    var statusMessage: String? { nil }
    var isFetching: Bool { false }
    func acknowledge() {}
}

/// The data behind one detail page: the catalogue item with its playback
/// metadata, the season list and episode pages, and the person's flags.
/// iPhone and iPad make one per page view; Apple TV keeps one per title in
/// `ItemDetailCache`, so its state outlives a trip into the player.
///
/// Loading, seasons and episodes live in this file and
/// `DetailModel+Episodes.swift`; favourites, watched writes and cache
/// clean-up in `DetailModel+Actions.swift`.
@Observable @MainActor
class ItemDetailViewModel {
    // MARK: Page state

    var detail: ItemDetail? = nil
    var error: ErrorState? = nil
    /// In display order (specials first).
    var seasons: [Season] = []
    var selectedSeason: Season? = nil
    /// The season a Continue Watching card opened on, until the page has
    /// loaded it or the person picks another.
    @ObservationIgnored var initialResumeSeasonNumber: Int?
    /// Set by the page on Jellyfin with a resume context, so that season's
    /// episode page is centred on the resume episode.
    @ObservationIgnored var jellyfinResumeEpisode: (contentId: String, seasonNumber: Int?)?
    /// The shown season's episodes, sorted by episode number.
    var episodes: [EpisodeListItem] = []
    var episodeSeriesPosterUrl: String? = nil
    var episodeSeriesPosterThumbhash: String? = nil
    #if os(iOS)
    var episodeSeriesLogoUrl: String? = nil
    #endif
    /// Sorted episode pages kept for each season number.
    var episodesBySeason: [Int: [EpisodeListItem]] = [:]
    #if os(tvOS)
    var episodeFavoriteStates: [String: Bool] = [:]
    #endif
    var isLoadingEpisodes = false
    var isFavorite = false
    var inWatchlist = false
    var isWatched = false

    // MARK: Apple TV playback choices
    // Stored here so they survive a trip into the player; the page reads
    // and writes them, the model never does.

    var preferredVersionFileId: Int? = nil
    var preferredAudioTrackIndex: Int? = nil
    var preferredSubtitleTrackIndex: Int? = nil
    var preferredSubtitleTrackWasManuallySelected = false
    var preferredNextUpFileId: Int? = nil
    var preferredNextUpAudioTrackIndex: Int? = nil
    var preferredNextUpSubtitleTrackIndex: Int? = nil

    // MARK: Trailer search stand-in

    @ObservationIgnored private let trailerStandIn = TrailerFetchCoordinator()
    var trailerFetch: TrailerFetchCoordinator { trailerStandIn }

    func startTrailerFetch() {}
    func stopTrailerFetch() {}
    func resumeTrailerFetchIfNeeded() {}

    // MARK: Bookkeeping

    /// The series whose seasons and episodes the page requests.
    @ObservationIgnored var seriesIdInUse: String?
    /// The season whose episodes `episodes` holds; it can differ from the
    /// selected chip while that season's page is requested.
    @ObservationIgnored var shownSeasonNumber: Int?
    /// Taken by every write to `detail` that waits on the network. A write
    /// publishes only while its turn is the newest.
    @ObservationIgnored var publishTurn = 0
    /// Taken by every episode load, stored-page switch and watched write.
    @ObservationIgnored var episodeTurn = 0
    /// Taken by favourite, watchlist and watched changes made here, so a
    /// response that started earlier can't undo them.
    @ObservationIgnored var localChangeTurn = 0
    @ObservationIgnored var isWatchedWritePending = false
    @ObservationIgnored var watchDetailFollowUp: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored var seasonWarming: Task<Void, Never>?
    #endif
    #if os(tvOS)
    @ObservationIgnored var episodeFavoriteEdits: [String: Int] = [:]
    @ObservationIgnored var favoriteRefreshTurn = 0
    @ObservationIgnored var favoriteRefresh: Task<Void, Never>?
    #endif

    // MARK: - Cache paint

    /// Paints what the response cache already holds, without waiting. Also
    /// the first step of every load.
    func hydrateFromCache(contentId: String) {
        let cache = ResponseCache.shared
        if detail == nil, let cached = cache.get(CacheKey.itemDetail(contentId), as: ItemDetail.self) {
            #if os(tvOS)
            PosterImageCache.prefetchVisibleMovieCast(for: cached)
            if Self.isLeaf(cached), let watch = cache.get(CacheKey.itemWatchDetail(contentId), as: WatchDetail.self) {
                detail = Self.merging(watch, into: cached)
            } else {
                detail = cached
            }
            #else
            detail = cached
            #endif
            isWatched = cached.userData?.played ?? false
            if cached.type == "series" {
                seriesIdInUse = contentId
            } else if cached.type == "season" || cached.type == "episode", let seriesId = cached.seriesId {
                seriesIdInUse = seriesId
            }
        }

        if let state = cache.get(CacheKey.itemUserState(contentId), as: UserItemState.self) {
            isFavorite = state.isFavorite
            inWatchlist = state.inWatchlist
        }

        if let seriesId = seriesIdInUse, seasons.isEmpty,
           let cachedSeasons = cache.get(CacheKey.itemSeasons(seriesId), as: SeasonsResponse.self) {
            seasons = cachedSeasons.seasons.sortedForDisplay()
        }

        #if os(tvOS)
        if let resume = initialResumeSeasonNumber, selectedSeason?.seasonNumber != resume {
            selectedSeason = nil
            episodes = []
        }
        #endif

        if let detail, let seriesId = seriesIdInUse, selectedSeason == nil {
            #if os(tvOS)
            if detail.type == "series" {
                selectedSeason = preferredInitialSeason(seasons: seasons)
            } else if let number = detail.seasonNumber {
                selectedSeason = seasons.first { $0.seasonNumber == number }
            }
            let paintsSelectedPage = true
            #else
            if detail.type == "series" {
                if let resume = initialResumeSeasonNumber {
                    selectedSeason = seasons.first { $0.seasonNumber == resume }
                }
            } else if let number = detail.seasonNumber {
                selectedSeason = seasons.first { $0.seasonNumber == number }
            }
            let paintsSelectedPage = detail.type == "series" && initialResumeSeasonNumber != nil
            #endif
            if paintsSelectedPage, let season = selectedSeason, episodes.isEmpty {
                showCachedPage(seriesId: seriesId, seasonNumber: season.seasonNumber)
            }
        }

        if let seriesId = seriesIdInUse, let detail, detail.type != "series",
           let number = detail.seasonNumber, episodes.isEmpty {
            showCachedPage(seriesId: seriesId, seasonNumber: number)
        }
    }

    /// Shows a season's cached episode page, if there is one, and keeps it
    /// as that season's page.
    private func showCachedPage(seriesId: String, seasonNumber: Int) {
        guard let cached = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber),
                                                    as: EpisodesResponse.self) else { return }
        let page = Self.sortedEpisodes(cached.episodes)
        episodes = page
        episodesBySeason[seasonNumber] = page
        shownSeasonNumber = seasonNumber
    }

    // MARK: - Loading

    /// Loads the title: the cache paint, then the catalogue item (published
    /// at once), then whatever its type needs. With a resume season the
    /// season list and that season's episodes are requested alongside the
    /// catalogue item. Errors land in `error`, and only while nothing is on
    /// screen.
    func loadDetail(contentId: String, preserveSeasonSelection: Bool = false, coalescesMetadataRequests: Bool = true) async {
        let pooled = coalescesMetadataRequests
        let resumeSeason = preserveSeasonSelection ? nil : initialResumeSeasonNumber

        if detail?.contentId != contentId {
            #if os(iOS)
            stopEpisodePagePrefetch()
            #endif
            episodeSeriesPosterUrl = nil
            episodeSeriesPosterThumbhash = nil
            #if os(iOS)
            episodeSeriesLogoUrl = nil
            #endif
        }

        hydrateFromCache(contentId: contentId)
        let turn = takePublishTurn()

        // Work that runs alongside the catalogue request. Leaving this scope
        // for any reason cancels whatever is still running and waits for it.
        async let structureLoaded = continueWatchingPiece(contentId: contentId, seasonNumber: resumeSeason, turn: turn)
        #if os(tvOS)
        let paintedThisTitle = detail?.contentId == contentId ? detail : nil
        let cachedFollowUpPayload = resumeSeason == nil ? paintedThisTitle : nil
        async let cachedFollowUp: Void = followUpPiece(cachedFollowUpPayload, preserveSeasonSelection: preserveSeasonSelection, pooled: pooled)
        async let _: Void = earlyWatchDetailPiece(
            contentId: contentId, turn: turn, runs: paintedThisTitle.map { Self.isLeaf($0) } ?? false)
        #endif

        error = nil
        let changeTurnAtStart = localChangeTurn
        async let favoriteAnswer = Self.answer { try await VividAPI.shared.isFavorite(contentId: contentId) }
        async let watchlistAnswer = Self.answer { try await VividAPI.shared.isInWatchlist(contentId: contentId) }

        let fetched: ItemDetail
        do {
            fetched = pooled
                ? try await MetadataRequestPool.shared.itemDetail(contentId: contentId)
                : try await VividAPI.shared.itemDetail(contentId: contentId)
        } catch {
            if Task.isCancelled || publishTurn != turn || Self.isCancellation(error) { return }
            if detail == nil { self.error = ErrorState(error) }
            return
        }

        guard let published = publishCatalogue(fetched, contentId: contentId, turn: turn, pooled: pooled) else { return }
        isWatched = published.userData?.played ?? false

        if let resumeSeason {
            let loaded = await structureLoaded
            if loaded, !Task.isCancelled, publishTurn == turn, initialResumeSeasonNumber == resumeSeason {
                initialResumeSeasonNumber = nil
            }
        } else {
            #if os(tvOS)
            if cachedFollowUpPayload != nil {
                await cachedFollowUp
            } else {
                await runFollowUp(for: published, preserveSeasonSelection: preserveSeasonSelection, pooled: pooled)
            }
            #else
            await runFollowUp(for: published, preserveSeasonSelection: preserveSeasonSelection, pooled: pooled)
            #endif
        }

        let favorite = await favoriteAnswer
        let watchlist = await watchlistAnswer
        if let favorite, let watchlist, detail?.contentId == contentId, localChangeTurn == changeTurnAtStart {
            isFavorite = favorite
            inWatchlist = watchlist
            ResponseCache.shared.set(UserItemState(isFavorite: favorite, inWatchlist: watchlist),
                                     for: CacheKey.itemUserState(contentId))
        }
    }

    private func continueWatchingPiece(contentId: String, seasonNumber: Int?, turn: Int) async -> Bool {
        guard let seasonNumber else { return false }
        return await loadContinueWatchingStructure(contentId: contentId, seasonNumber: seasonNumber, detailGeneration: turn)
    }

    #if os(tvOS)
    /// The follow-up for a payload the cache paint already showed, started
    /// without waiting for the catalogue request.
    private func followUpPiece(_ payload: ItemDetail?, preserveSeasonSelection: Bool, pooled: Bool) async {
        guard let payload else { return }
        await runFollowUp(for: payload, preserveSeasonSelection: preserveSeasonSelection, pooled: pooled)
    }

    /// Requests the painted title's playback metadata beside the catalogue
    /// request, so the selectors fill in sooner.
    private func earlyWatchDetailPiece(contentId: String, turn: Int, runs: Bool) async {
        guard runs else { return }
        guard let watch = try? await MetadataRequestPool.shared.watchDetail(contentId: contentId),
              publishTurn == turn, !Task.isCancelled else { return }
        ResponseCache.shared.set(watch, for: CacheKey.itemWatchDetail(contentId))
        if let current = detail, current.contentId == contentId {
            detail = Self.merging(watch, into: current)
        }
    }
    #endif

    // MARK: - Publishing

    /// Takes a publish turn, which also stops the playback metadata
    /// follow-up of any earlier publish.
    @discardableResult
    func takePublishTurn() -> Int {
        publishTurn += 1
        watchDetailFollowUp?.cancel()
        watchDetailFollowUp = nil
        return publishTurn
    }

    /// Publishes a fetched catalogue item, with cached playback metadata
    /// merged in for a playable item, and starts fetching fresh playback
    /// metadata. Returns nil when a newer write has started.
    private func publishCatalogue(_ item: ItemDetail, contentId: String, turn: Int, pooled: Bool) -> ItemDetail? {
        guard turn == publishTurn else { return nil }
        #if os(tvOS)
        PosterImageCache.prefetchVisibleMovieCast(for: item)
        #endif
        let cache = ResponseCache.shared
        let leaf = Self.isLeaf(item)
        let published: ItemDetail
        if leaf, let watch = cache.get(CacheKey.itemWatchDetail(contentId), as: WatchDetail.self) {
            published = Self.merging(watch, into: item)
        } else {
            published = item
        }
        detail = published
        cache.set(published, for: CacheKey.itemDetail(contentId))
        if leaf {
            startWatchDetailFollowUp(for: item, contentId: contentId, turn: turn, pooled: pooled)
        }
        return published
    }

    /// Fetches the playback metadata and publishes it merged into the
    /// fetched catalogue item, unless a newer write has started.
    private func startWatchDetailFollowUp(for item: ItemDetail, contentId: String, turn: Int, pooled: Bool) {
        watchDetailFollowUp?.cancel()
        watchDetailFollowUp = Task { [weak self] in
            let watch: WatchDetail
            do {
                watch = pooled
                    ? try await MetadataRequestPool.shared.watchDetail(contentId: contentId)
                    : try await VividAPI.shared.watchDetail(contentId: contentId)
            } catch {
                return
            }
            ResponseCache.shared.set(watch, for: CacheKey.itemWatchDetail(contentId))
            guard let self, !Task.isCancelled, self.publishTurn == turn else { return }
            let merged = ItemDetailViewModel.merging(watch, into: item)
            self.detail = merged
            ResponseCache.shared.set(merged, for: CacheKey.itemDetail(contentId))
        }
    }

    /// Publishes a re-fetched item exactly as given (used by description
    /// translation).
    func publishRefetchedDetail(_ item: ItemDetail, contentId: String) {
        takePublishTurn()
        detail = item
        ResponseCache.shared.set(item, for: CacheKey.itemDetail(contentId))
    }

    // MARK: - Follow-up by type

    /// Loads what the page needs beyond the catalogue item: the season list
    /// for a series, the episode page and season list for a season or an
    /// episode (plus the parent series artwork for an episode).
    func runFollowUp(for item: ItemDetail, preserveSeasonSelection: Bool, pooled: Bool) async {
        switch item.type {
        case "series":
            seriesIdInUse = item.contentId
            let rememberedSeason = preserveSeasonSelection ? selectedSeason?.seasonNumber : nil
            await loadSeasonList(seriesId: item.contentId, autoSelect: rememberedSeason == nil, pooled: pooled)
            if let rememberedSeason, let fresh = seasons.first(where: { $0.seasonNumber == rememberedSeason }) {
                selectedSeason = fresh
            }
        case "season":
            guard let seriesId = item.seriesId, let number = item.seasonNumber else { return }
            seriesIdInUse = seriesId
            await loadEpisodes(seriesId: seriesId, seasonNumber: number, fallbackSeasonNumber: nil, pooled: pooled)
            await loadSeasonList(seriesId: seriesId, autoSelect: false, pooled: pooled)
            selectedSeason = seasons.first { $0.seasonNumber == number }
        case "episode":
            guard let seriesId = item.seriesId, let number = item.seasonNumber else { return }
            seriesIdInUse = seriesId
            async let episodePage: Void = loadEpisodes(seriesId: seriesId, seasonNumber: number, fallbackSeasonNumber: nil, pooled: pooled)
            await loadSeasonList(seriesId: seriesId, autoSelect: false, pooled: pooled)
            selectedSeason = seasons.first { $0.seasonNumber == number }
            await loadParentSeriesArtwork(seriesId: seriesId, pooled: pooled)
            await episodePage
        default:
            return
        }
    }

    /// The parent series' poster (and, on iPhone and iPad, its logo) for an
    /// episode page.
    private func loadParentSeriesArtwork(seriesId: String, pooled: Bool) async {
        let cache = ResponseCache.shared
        let series: ItemDetail
        if let cached = cache.get(CacheKey.itemDetail(seriesId), as: ItemDetail.self) {
            series = cached
        } else {
            do {
                series = pooled
                    ? try await MetadataRequestPool.shared.itemDetail(contentId: seriesId)
                    : try await VividAPI.shared.itemDetail(contentId: seriesId)
            } catch {
                return
            }
            cache.set(series, for: CacheKey.itemDetail(seriesId))
        }
        guard let detail, detail.type == "episode", detail.seriesId == seriesId else { return }
        episodeSeriesPosterUrl = series.posterUrl
        episodeSeriesPosterThumbhash = series.posterThumbhash
        #if os(iOS)
        episodeSeriesLogoUrl = series.logoUrl
        #endif
    }

    // MARK: - Helpers

    /// Movies, episodes and anything else that isn't a series or a season.
    nonisolated static func isLeaf(_ item: ItemDetail) -> Bool {
        item.type != "series" && item.type != "season"
    }

    nonisolated static func sortedEpisodes(_ episodes: [EpisodeListItem]) -> [EpisodeListItem] {
        episodes.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    /// The catalogue item with its playback fields taken from the watch
    /// detail. User data, translation state, overlays and trailers stay the
    /// catalogue's.
    nonisolated static func merging(_ watch: WatchDetail, into item: ItemDetail) -> ItemDetail {
        ItemDetail(
            contentId: item.contentId, type: item.type, status: item.status, title: item.title,
            sortTitle: item.sortTitle, originalTitle: item.originalTitle, originalLanguage: item.originalLanguage,
            showStatus: item.showStatus, year: item.year, overview: item.overview, tagline: item.tagline,
            runtime: item.runtime, contentRating: item.contentRating, genres: item.genres,
            ratingImdb: item.ratingImdb, ratingTmdb: item.ratingTmdb, ratingRtCritic: item.ratingRtCritic,
            ratingRtAudience: item.ratingRtAudience, imdbId: item.imdbId, tmdbId: item.tmdbId, tvdbId: item.tvdbId,
            cast: item.cast, crew: item.crew, studios: item.studios, networks: item.networks,
            countries: item.countries, releaseDate: item.releaseDate, firstAirDate: item.firstAirDate,
            lastAirDate: item.lastAirDate, posterUrl: item.posterUrl, posterThumbhash: item.posterThumbhash,
            backdropUrl: item.backdropUrl, backdropThumbhash: item.backdropThumbhash, logoUrl: item.logoUrl,
            seasonCount: item.seasonCount, seriesId: item.seriesId, seriesTitle: item.seriesTitle,
            seasonNumber: item.seasonNumber, episodeNumber: item.episodeNumber, episodeCount: item.episodeCount,
            airDate: item.airDate, isSpecials: item.isSpecials, userData: item.userData,
            versions: watch.versions, subtitles: watch.subtitles, intro: watch.intro, credits: watch.credits,
            effectiveSubtitleMode: watch.effectiveSubtitleMode,
            effectiveShowForcedSubtitles: watch.effectiveShowForcedSubtitles,
            effectiveSubtitleTrackSignature: watch.effectiveSubtitleTrackSignature,
            overlaySummary: item.overlaySummary, pendingTranslationLanguage: item.pendingTranslationLanguage,
            videos: item.videos, extras: item.extras)
    }

    /// A lookup's answer, or nil when it failed.
    nonisolated static func answer(_ request: @Sendable () async throws -> Bool) async -> Bool? {
        try? await request()
    }

    /// A cancelled request, however it was wrapped, isn't an error to show.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        func isCancelled(_ error: Error) -> Bool {
            error is CancellationError || (error as? URLError)?.code == .cancelled
        }
        if isCancelled(error) { return true }
        if let httpError = error as? HTTPError, case .network(let underlying) = httpError {
            return isCancelled(underlying)
        }
        return false
    }
}
