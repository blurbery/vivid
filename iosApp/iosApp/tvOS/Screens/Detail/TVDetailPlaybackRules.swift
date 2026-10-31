#if os(tvOS)
import Foundation

/// The episode or item playback starts from on each page, the selector
/// picks that stay valid for it, and the cache warming around it.
@MainActor
enum TVDetailPlaybackRules {
    // MARK: Positions and versions

    /// A saved position worth resuming: past 30 seconds and not within the
    /// last 5 seconds of a known duration.
    static func resumePosition(_ position: Double?, duration: Double?) -> Double? {
        guard let position, position.isFinite, position > 30 else { return nil }
        if let duration, duration.isFinite, duration > 0, position >= duration - 5 { return nil }
        return position
    }

    /// The version a detail would play for a file pick.
    static func effectiveVersion(of detail: ItemDetail?, filePick: Int?) -> FileVersion? {
        guard let detail else { return nil }
        return DetailVersionSelection.displayVersion(
            versions: detail.versions ?? [],
            selectedFileId: filePick,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    /// An audio pick survives only as a valid track index of the version.
    static func sanitisedAudio(_ pick: Int?, version: FileVersion?) -> Int? {
        guard let pick, let version else { return nil }
        return (version.audioTracks ?? []).indices.contains(pick) ? pick : nil
    }

    /// A negative pick (subtitles off) always survives; any other pick must
    /// name one of the version's subtitle tracks.
    static func sanitisedSubtitle(_ pick: Int?, version: FileVersion?) -> Int? {
        guard let pick else { return nil }
        if pick < 0 { return pick }
        guard let version else { return nil }
        return (version.subtitleTracks ?? []).contains { $0.selectionIndex == pick } ? pick : nil
    }

    /// The OpenSubtitles context for an item, before the file is set.
    static func subtitleContext(for item: ItemDetail?) -> OpenSubtitlePlaybackContext? {
        guard let item else { return nil }
        let title = item.type == "episode" ? (item.seriesTitle ?? item.title) : item.title
        return OpenSubtitlePlaybackContext(
            contentID: item.contentId,
            generation: 0,
            query: OpenSubtitleQuery(
                title: title,
                type: item.type,
                season: item.seasonNumber,
                episode: item.episodeNumber
            )
        )
    }

    /// The episode in progress, else the first unwatched, else the first.
    static func nextUpEpisode(in episodes: [EpisodeListItem]) -> EpisodeListItem? {
        episodes.first { $0.userData?.isInProgress == true }
            ?? episodes.first { $0.userData?.played != true }
            ?? episodes.first
    }

    // MARK: Enrichment and warming

    /// The item with its playback fields (versions, subtitles, intro,
    /// credits and the effective subtitle settings) from its watch detail.
    /// A series comes back unchanged; any failure gives nil.
    static func enrich(_ item: ItemDetail, watch: WatchDetail? = nil) async -> ItemDetail? {
        guard item.type != "series" else { return item }
        do {
            let watchDetail: WatchDetail
            if let watch {
                watchDetail = watch
            } else {
                watchDetail = try await MetadataRequestPool.shared.watchDetail(contentId: item.contentId)
            }
            ResponseCache.shared.set(watchDetail, for: CacheKey.itemWatchDetail(item.contentId))
            return ItemDetail(
                contentId: item.contentId,
                type: item.type,
                status: item.status,
                title: item.title,
                sortTitle: item.sortTitle,
                originalTitle: item.originalTitle,
                originalLanguage: item.originalLanguage,
                showStatus: item.showStatus,
                year: item.year,
                overview: item.overview,
                tagline: item.tagline,
                runtime: item.runtime,
                contentRating: item.contentRating,
                genres: item.genres,
                ratingImdb: item.ratingImdb,
                ratingTmdb: item.ratingTmdb,
                ratingRtCritic: item.ratingRtCritic,
                ratingRtAudience: item.ratingRtAudience,
                imdbId: item.imdbId,
                tmdbId: item.tmdbId,
                tvdbId: item.tvdbId,
                cast: item.cast,
                crew: item.crew,
                studios: item.studios,
                networks: item.networks,
                countries: item.countries,
                releaseDate: item.releaseDate,
                firstAirDate: item.firstAirDate,
                lastAirDate: item.lastAirDate,
                posterUrl: item.posterUrl,
                posterThumbhash: item.posterThumbhash,
                backdropUrl: item.backdropUrl,
                backdropThumbhash: item.backdropThumbhash,
                logoUrl: item.logoUrl,
                seasonCount: item.seasonCount,
                seriesId: item.seriesId,
                seriesTitle: item.seriesTitle,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                episodeCount: item.episodeCount,
                airDate: item.airDate,
                isSpecials: item.isSpecials,
                userData: item.userData,
                versions: watchDetail.versions,
                subtitles: watchDetail.subtitles,
                intro: watchDetail.intro,
                credits: watchDetail.credits,
                effectiveSubtitleMode: watchDetail.effectiveSubtitleMode,
                effectiveShowForcedSubtitles: watchDetail.effectiveShowForcedSubtitles,
                effectiveSubtitleTrackSignature: watchDetail.effectiveSubtitleTrackSignature,
                overlaySummary: item.overlaySummary,
                pendingTranslationLanguage: item.pendingTranslationLanguage,
                videos: item.videos,
                extras: item.extras
            )
        } catch {
            return nil
        }
    }

    /// Caches playable details for the episodes either side of the Play
    /// target, so moving Play along the season starts without a wait.
    static func warmNeighbours(of episodeId: String, in episodes: [EpisodeListItem]) async {
        guard let index = episodes.firstIndex(where: { $0.contentId == episodeId }) else { return }
        for position in [index - 1, index + 1] where episodes.indices.contains(position) {
            guard !Task.isCancelled else { return }
            let id = episodes[position].contentId
            let key = CacheKey.itemDetail(id)
            if let cached: ItemDetail = ResponseCache.shared.get(key), !(cached.versions ?? []).isEmpty { continue }
            guard let item = try? await MetadataRequestPool.shared.itemDetail(contentId: id) else {
                if Task.isCancelled { return }
                continue
            }
            guard !Task.isCancelled else { return }
            let enriched = await enrich(item)
            guard !Task.isCancelled else { return }
            if let enriched, !(enriched.versions ?? []).isEmpty {
                ResponseCache.shared.set(enriched, for: key)
            }
        }
    }

    /// Loads every other season's episodes, nearest first, so the series
    /// shelf can show them before the viewer gets there.
    static func warmNeighbourSeasons(of viewModel: ItemDetailViewModel) async {
        guard let detail = viewModel.detail, detail.type == "series",
              let selected = viewModel.selectedSeason,
              let selectedIndex = viewModel.seasons.firstIndex(where: { $0.contentId == selected.contentId }) else { return }
        let seriesId = detail.contentId
        let seasons = viewModel.seasons
        let order = seasons.indices
            .filter { $0 != selectedIndex }
            .sorted { (abs($0 - selectedIndex), $0) < (abs($1 - selectedIndex), $1) }
        for index in order {
            guard !Task.isCancelled else { return }
            let number = seasons[index].seasonNumber
            let key = CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: number)
            let response: EpisodesResponse
            if let cached: EpisodesResponse = ResponseCache.shared.get(key) {
                response = cached
            } else {
                guard let fetched = try? await MetadataRequestPool.shared.episodes(seriesId: seriesId, seasonNumber: number),
                      !Task.isCancelled else {
                    if Task.isCancelled { return }
                    continue
                }
                ResponseCache.shared.set(fetched, for: key)
                response = fetched
            }
            let stills = response.episodes.prefix(6).compactMap { $0.stillUrl.flatMap { URL(string: $0) } }
            PosterImageCache.prefetchCardArtwork(stills)
            if viewModel.episodesBySeason[number] == nil {
                viewModel.episodesBySeason[number] = response.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
            }
        }
    }

    // MARK: Completed playback

    /// What a finished playback session changes on the series page.
    struct CompletionOutcome {
        /// The new Play target, or nil to leave it.
        var activeEpisodeId: String?
        /// Whether the event waits for more pages to load.
        var staysPending: Bool
    }

    /// Moves Play on to the next episode after one finished. Returns nil
    /// when the event changes nothing, and keeps it pending while a page it
    /// depends on hasn't loaded.
    static func completionOutcome(
        completed: Set<String>,
        activeEpisodeId: String?,
        seasons: [Season],
        pages: [Int: [EpisodeListItem]]
    ) -> CompletionOutcome? {
        let ordered = seasons.sorted { $0.seasonNumber < $1.seasonNumber }
        let slots: [[EpisodeListItem]?] = ordered.map { pages[$0.seasonNumber] }

        var startIndex = 0
        if let activeEpisodeId {
            guard let index = slots.firstIndex(where: { $0?.contains { $0.contentId == activeEpisodeId } == true }) else {
                return CompletionOutcome(activeEpisodeId: nil, staysPending: true)
            }
            startIndex = index
        }
        let remaining = Array(slots[startIndex...])
        let candidates = DetailEpisodeSequence.contiguousEpisodes(remaining)

        let concerned = activeEpisodeId == nil
            || completed.contains(activeEpisodeId ?? "")
            || candidates.contains { completed.contains($0.contentId) }
        guard concerned else { return nil }

        let hasGap = remaining.contains { $0 == nil }
        let isUnplayed: (EpisodeListItem) -> Bool = { $0.userData?.played != true }

        if let resuming = candidates.first(where: { $0.userData?.isInProgress == true && isUnplayed($0) }) {
            return CompletionOutcome(activeEpisodeId: resuming.contentId, staysPending: false)
        }
        if let activeEpisodeId, let activeIndex = candidates.firstIndex(where: { $0.contentId == activeEpisodeId }) {
            if let next = candidates[(activeIndex + 1)...].first(where: isUnplayed) {
                return CompletionOutcome(activeEpisodeId: next.contentId, staysPending: false)
            }
            return CompletionOutcome(activeEpisodeId: nil, staysPending: hasGap)
        }
        if activeEpisodeId == nil, let first = candidates.first(where: isUnplayed) {
            return CompletionOutcome(activeEpisodeId: first.contentId, staysPending: false)
        }
        return CompletionOutcome(activeEpisodeId: nil, staysPending: hasGap)
    }
}
#endif
