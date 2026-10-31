#if os(tvOS)
import SwiftUI

/// A series on the native page, with the continuous episode shelf. Play
/// targets one pinned episode; browsing the shelf never moves it.
struct TVSeriesDetailPage: View {
    let viewModel: ItemDetailViewModel
    let detail: ItemDetail
    let contentId: String
    let playTarget: EpisodeListItem?
    let activeEpisodeId: String?
    let nextUp: TVDetailNextUp
    let picks: TVDetailNextUpPicks
    let trailerEntries: [TrailerRailEntry]
    let actions: TVDetailPageActions
    let selectSeason: (Season) -> Void
    /// Plays an episode with the file the page sends, from the beginning
    /// when true. The entry page makes it the Play target first.
    let playEpisode: (String, Int?, Bool) -> Void

    @ObservedObject private var profilePrefs = ProfilePrefsStore.shared
    @FocusState private var heroFocus: TVDetailHeroFocus?
    @Namespace private var scope
    @State private var playHadFocus = false
    @State private var actionHadFocusWithoutTarget = false
    /// Translation shows under the synopsis only while it describes the
    /// series rather than a focused episode.
    @State private var showsSeriesOverview = true
    @State private var tmdbRating: TMDbRatingResult?

    var body: some View {
        let playback = playbackInputs
        TVDetailNativeShell(
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            logoUrl: detail.logoUrl,
            title: detail.title
        ) { showcase in
            hero(showcase: showcase, playback: playback)
        } shelves: {
            shelves(playback: playback)
        }
        .focusScope(scope)
        .defaultFocus($heroFocus, .play, priority: .userInitiated)
        .onAppear {
            showsSeriesOverview = activeEpisodeId == nil
        }
        .onChange(of: heroFocus) { _, focus in
            guard let focus, focus.isActionRow else { return }
            if focus == .play {
                playHadFocus = true
            } else if playTarget == nil {
                actionHadFocusWithoutTarget = true
            }
        }
        .task(id: "\(contentId)|\(TVTMDbStore.shared.contextKey)", priority: .utility) {
            await loadRating()
        }
    }

    // MARK: Playback inputs

    private struct PlaybackInputs {
        /// The Play target's playback detail, if loaded or cached.
        let matching: ItemDetail?
        let versions: [FileVersion]
        let current: FileVersion?
    }

    private var playbackInputs: PlaybackInputs {
        let matching = matchingDetail
        let versions = Self.versions(matching: matching, target: playTarget)
        let current = DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: picks.fileId,
            lastFileId: matching?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
        return PlaybackInputs(matching: matching, versions: versions, current: current)
    }

    private var matchingDetail: ItemDetail? {
        guard let playTarget else { return nil }
        if let detail = nextUp.detail, detail.contentId == playTarget.contentId { return detail }
        return ResponseCache.shared.get(CacheKey.itemDetail(playTarget.contentId))
    }

    private static func versions(matching: ItemDetail?, target: EpisodeListItem?) -> [FileVersion] {
        if let versions = matching?.versions, !versions.isEmpty { return versions }
        if let target, let watch: WatchDetail = ResponseCache.shared.get(CacheKey.itemWatchDetail(target.contentId)) {
            return watch.versions
        }
        return []
    }

    /// The next-up file pick, sent only for the episode it was picked for.
    private func fileId(for episodeId: String, playback: PlaybackInputs) -> Int? {
        guard let pick = picks.fileId, playback.matching?.contentId == episodeId,
              playback.versions.contains(where: { $0.fileId == pick }) else { return nil }
        return pick
    }

    private func playAction(_ playback: PlaybackInputs) -> TVDetailPlayAction {
        guard let target = playTarget else {
            return TVDetailPlayAction(title: nil, subtitle: nil, progress: nil, offersStartOver: false, play: {}, startOver: {})
        }
        let season = String(target.seasonNumber)
        let episode = String(target.episodeNumber)
        let title = target.userData?.isInProgress == true
            ? String(localized: "Resume S\(season):E\(episode)")
            : String(localized: "Play S\(season):E\(episode)")
        let progress = ResumePresentation(
            position: target.userData?.positionSeconds,
            duration: target.userData?.durationSeconds,
            episodeLabel: TVDetailEpisodeCode.spaced(season: target.seasonNumber, episode: target.episodeNumber)
        )
        let file = fileId(for: target.contentId, playback: playback)
        return TVDetailPlayAction(
            title: title,
            subtitle: nil,
            progress: progress,
            offersStartOver: progress != nil,
            play: { playEpisode(target.contentId, file, false) },
            startOver: { playEpisode(target.contentId, file, true) }
        )
    }

    // MARK: Hero

    private var seriesTypeLabel: String {
        String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
    }

    private func hero(showcase: CGFloat, playback: PlaybackInputs) -> some View {
        TVDetailHero(layout: .showcase(height: showcase), creditLine: TVHeroMetadata.creditLine(detail)) {
            TVDetailCompactPrimary(
                title: detail.title,
                logoUrl: detail.logoUrl,
                headingTokens: [seriesTypeLabel] + TVHeroMetadata.seriesHeadingFacts(
                    detail: detail,
                    seasons: viewModel.seasons,
                    selectedSeason: viewModel.selectedSeason,
                    selectedEpisodes: viewModel.episodes,
                    isLoadingEpisodes: viewModel.isLoadingEpisodes,
                    pages: viewModel.episodesBySeason
                ),
                genres: TVHeroMetadata.genreTokens(detail),
                contentRating: TVHeroMetadata.contentRating(detail),
                overview: detail.overview,
                synopsisEnabled: playHadFocus || actionHadFocusWithoutTarget,
                focus: $heroFocus
            ) {
                if showsSeriesOverview {
                    DescriptionTranslationView(viewModel: viewModel, contentId: contentId)
                        .id(contentId)
                }
            }
        } summary: {
            TVDetailTechnicalRow(
                releaseFacts: TVHeroMetadata.releaseFacts(year: detail.year, runtime: playTarget?.runtime ?? detail.runtime),
                badges: TVHeroMetadata.sourceBadges(
                    playback.current,
                    summary: picks.fileId == nil ? (playback.matching?.overlaySummary ?? detail.overlaySummary) : nil
                ),
                tmdbScore: tmdbRating?.value(for: contentId)
            )
        } actions: {
            TVDetailActionRow(
                play: playAction(playback),
                selectors: TVDetailSelectorInputs(
                    version: playback.current,
                    subtitleContext: TVDetailPlaybackRules.subtitleContext(for: playback.matching),
                    audioPick: picks.audio,
                    subtitlePick: picks.subtitle,
                    onAudio: picks.pickAudio,
                    onSubtitle: picks.pickSubtitle
                ),
                inWatchlist: viewModel.inWatchlist,
                onToggleWatchlist: actions.toggleWatchlist,
                focus: $heroFocus,
                scope: scope,
                claimKey: TVDetailFocusClaimKey(pageKey: contentId)
            ) {
                moreMenu(playback)
            }
        }
    }

    @ViewBuilder
    private func moreMenu(_ playback: PlaybackInputs) -> some View {
        TVDetailVersionMenu(versions: playback.versions, pick: picks.fileId, onPick: picks.pickVersion)
        if let target = playTarget, target.userData?.isInProgress == true {
            let file = fileId(for: target.contentId, playback: playback)
            TVDetailMoreMenuRows.startOver { playEpisode(target.contentId, file, true) }
        }
        TVDetailMoreMenuRows.favorite(isFavorite: viewModel.isFavorite, action: actions.toggleFavorite)
        if let target = playTarget {
            let played = target.userData?.played ?? false
            TVDetailMoreMenuRows.episodeWatched(isWatched: played) {
                Task { _ = await actions.setEpisodeWatched(target.contentId, !played) }
            }
        }
        if let season = viewModel.selectedSeason {
            TVDetailMoreMenuRows.seasonWatched(isWatched: season.userData?.played ?? false) {
                Task { await viewModel.toggleSelectedSeasonWatched() }
            }
        }
        TVDetailMoreMenuRows.seriesWatched(isWatched: viewModel.isWatched, action: actions.toggleWatched)
    }

    // MARK: Shelves

    /// The loaded pages with the selected season's current list in its slot
    /// and spoilers covered. Worked out once per draw, not per focus move.
    private var shelfPages: [Int: [EpisodeListItem]] {
        var pages = viewModel.episodesBySeason
        if !viewModel.isLoadingEpisodes, let selected = viewModel.selectedSeason {
            pages[selected.seasonNumber] = viewModel.episodes
        }
        if PlayerSettings.shared.hideFutureEpisodeSpoilers {
            let position = EpisodeSpoilerPolicy.currentPosition(seasons: viewModel.seasons, pages: pages)
            pages = EpisodeSpoilerPolicy.cover(pages, after: position)
        }
        return pages
    }

    private func shelves(playback: PlaybackInputs) -> some View {
        VStack(alignment: .leading, spacing: TVDetailHeroLayout.sectionSpacing) {
            TVSeriesEpisodeShelf(
                seasons: viewModel.seasons,
                pages: shelfPages,
                selectedSeason: viewModel.selectedSeason,
                currentEpisodeId: activeEpisodeId,
                playTarget: playTarget,
                isActionRowFocused: heroFocus?.isActionRow == true,
                favoriteStates: viewModel.episodeFavoriteStates,
                onSelectSeason: selectSeason,
                onEpisodeFocus: { _ in showsSeriesOverview = false },
                onPlayEpisode: { id in playEpisode(id, fileId(for: id, playback: playback), false) },
                onSetWatched: actions.setEpisodeWatched,
                onSetFavorite: actions.setEpisodeFavorite
            )
            TVDetailTrailersRail(entries: trailerEntries, onSelect: actions.selectTrailer)
            if CastCrewGrouping.hasPeople(cast: detail.cast, crew: detail.crew) {
                TVDetailSection(title: "Cast & Crew") {
                    TVDetailCastRail(cast: detail.cast ?? [], crew: detail.crew ?? [], onSelectPerson: actions.selectPerson)
                }
            }
            TVMoreLikeThisSection(sourceId: contentId, sourceDetail: detail, onSelect: actions.selectItem)
            TVDetailSection(title: "Media Information") {
                if nextUp.isLoading {
                    ProgressView()
                } else {
                    DetailMediaSection(version: playback.current)
                }
            }
        }
    }

    // MARK: Loads

    private func loadRating() async {
        let store = TVTMDbStore.shared
        let context = store.contextKey
        let rating = try? await store.rating(for: detail)
        guard !Task.isCancelled else { return }
        tmdbRating = rating.map { TMDbRatingResult(contentId: contentId, context: context, value: $0) }
    }
}
#endif
