import SwiftUI

#if !os(tvOS)
/// The movie page, which episodes use too: hero, actions and selectors,
/// then the season's episodes for an episode, trailers, cast, similar
/// titles, the TMDb collection and media information.
struct MobileMoviePage: View {
    let contentId: String
    let detail: ItemDetail
    let session: MobileDetailSession
    let scrollState: PhoneDetailScrollState
    let navigation: MobileDetailNavigation

    @State private var showsResumeAlert = false
    @State private var showsDownloadOptions = false
    @State private var tmdbScore: TMDbRatingResult?
    @State private var collectionRow: MovieCollectionRowStore.Row?
    @State private var similarTitles = MobileSimilarTitles()
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var model: ItemDetailViewModel { session.model }
    private var isEpisode: Bool { detail.type == "episode" }
    private var effectiveVersion: FileVersion? { session.effectiveMovieVersion(detail) }
    private var resumePosition: Double? { MobileDetailSession.displayResumePosition(detail.userData) }

    private struct ScoreKey: Equatable {
        let contentId: String
        let context: String
    }

    private struct CollectionKey: Equatable {
        let contentId: String
        let context: String
        let lookupRevision: Int
    }

    var body: some View {
        MobileDetailSurface(
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            isArtworkGlassEnabled: VividMediaType.isMovieLibrary(detail.type)
        ) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: PhoneDuo.usesPhoneDetailLayout(horizontalSizeClass) ? 32 : 16) {
                    MobileDetailHero(content: heroContent) {
                        actions
                    } underOverview: {
                        underOverview
                    }
                    belowFold
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(.named("phone-detail-scroll"))
            .detailScrollDismissal()
            .reportsDetailScroll(to: scrollState)
        }
        .vividResumePlaybackAlert(
            isPresented: $showsResumeAlert,
            stoppedAt: MobileDetailControls.stoppedAt(resumePosition),
            onResume: { play(fromBeginning: false) },
            onRestart: { play(fromBeginning: true) }
        )
        .task(id: ScoreKey(contentId: contentId, context: TVTMDbStore.shared.contextKey), priority: .utility) {
            await loadScore()
        }
        .task(
            id: CollectionKey(
                contentId: contentId,
                context: TVTMDbStore.shared.contextKey,
                lookupRevision: StudiosNetworksStore.shared.movieLookupRevision
            ),
            priority: .utility
        ) {
            await loadCollection()
        }
    }

    // MARK: Hero

    private var heroContent: MobileHeroContent {
        var content = MobileHeroContent(title: detail.title)
        content.seriesTitle = isEpisode ? detail.seriesTitle : nil
        content.logoUrl = isEpisode ? (model.episodeSeriesLogoUrl ?? detail.logoUrl) : detail.logoUrl
        let poster = posterArtwork
        content.posterUrl = poster?.url
        content.posterThumbhash = poster?.thumbhash
        content.backdropUrl = detail.backdropUrl
        content.backdropThumbhash = detail.backdropThumbhash
        content.eyebrow = isEpisode ? nil : MobileHeroRules.eyebrow(detail)
        content.sourceTokens = MobileHeroRules.movieSourceTokens(detail)
        content.ageRating = MobileHeroRules.ageRating(detail)
        content.overview = detail.overview
        content.credit = MobileHeroRules.credit(detail)
        content.factsTokens = MobileHeroRules.movieFacts(detail)
        content.parallax = VividMediaType.isMovieLibrary(detail.type)
        content.tmdbScore = tmdbScore?.value(for: contentId)
        content.headingTokens = isEpisode ? [] : [String(localized: "Movie")]
        content.releaseFacts = MobileHeroRules.releaseFacts(year: detail.year, runtime: detail.runtime)
        content.qualityBadges = MobileHeroRules.qualityBadges(
            version: effectiveVersion,
            summary: session.movieVersionId == nil ? detail.overlaySummary : nil
        )
        return content
    }

    /// An episode shows its season's poster, else the series poster.
    private var posterArtwork: (url: String, thumbhash: String?)? {
        guard isEpisode else {
            guard let url = detail.posterUrl else { return nil }
            return (url, detail.posterThumbhash)
        }
        if let season = model.seasons.first(where: { $0.seasonNumber == detail.seasonNumber }),
           let url = season.posterUrl, !MobileHeroRules.isBlank(url) {
            return (url, season.posterThumbhash)
        }
        if let url = model.episodeSeriesPosterUrl, !MobileHeroRules.isBlank(url) {
            return (url, model.episodeSeriesPosterThumbhash)
        }
        return nil
    }

    private var underOverview: some View {
        VStack(alignment: .center, spacing: 14) {
            DescriptionTranslationView(viewModel: model, contentId: detail.contentId)
                .id(detail.contentId)
            if effectiveVersion != nil {
                MobileSelectorsPlacement {
                    selectors
                }
            }
        }
    }

    private var selectors: some View {
        MobilePlaybackSelectors(
            versions: detail.versions ?? [],
            currentVersion: effectiveVersion,
            chosenVersionId: session.movieVersionId,
            chosenAudioIndex: session.movieAudioIndex,
            onChooseVersion: { session.chooseMovieVersion($0, detail: detail) },
            onChooseAudio: { session.chooseMovieAudio($0, detail: detail) }
        )
    }

    // MARK: Actions

    private var playTitle: String {
        if isEpisode, let season = detail.seasonNumber, let episode = detail.episodeNumber {
            let seasonText = String(season)
            let episodeText = String(episode)
            return season == 0
                ? String(localized: "Play E\(episodeText)")
                : String(localized: "Play S\(seasonText)·E\(episodeText)")
        }
        return String(localized: "Play")
    }

    private var actions: some View {
        VStack(spacing: 14) {
            PhoneDetailPrimaryActions {
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: playTitle,
                    action: playTapped,
                    fullWidth: true,
                    resumeProgress: ResumePresentation(position: resumePosition, duration: detail.userData?.durationSeconds)
                )
            } selectors: {
                if effectiveVersion != nil {
                    MobileSelectorsPlacement {
                        selectors
                    }
                }
            } actions: {
                PhoneLabeledActionRow {
                    actionRow
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionRow: some View {
        MobileNamedAction(
            icon: "heart",
            activeIcon: "heart.fill",
            isActive: model.isFavorite,
            caption: "Favorite",
            spokenLabel: model.isFavorite ? "Remove from Favorites" : "Add to Favorites"
        ) {
            Task { await model.toggleFavorite() }
        }
        .mobileMovesToMore()
        MobileNamedAction(
            icon: "bookmark",
            activeIcon: "bookmark.fill",
            isActive: model.inWatchlist,
            caption: "Watchlist",
            spokenLabel: model.inWatchlist ? "Remove from Watchlist" : "Add to Watchlist"
        ) {
            Task { await model.toggleWatchlist() }
        }
        if isEpisode {
            MobileNamedMenu(icon: "checkmark.circle", caption: "Watched") {
                episodeWatchedButtons
            }
            .mobileMovesToMore()
        } else {
            MobileNamedAction(
                icon: "checkmark.circle",
                activeIcon: "checkmark.circle.fill",
                isActive: model.isWatched,
                caption: "Watched",
                spokenLabel: model.isWatched ? "Mark as Unwatched" : "Mark as Watched"
            ) {
                Task { await model.toggleWatched() }
            }
            .mobileMovesToMore()
        }
        downloadButton
        MobileMoreMenu {
            if resumePosition != nil {
                Button {
                    play(fromBeginning: true)
                } label: {
                    Label("Start Over", systemImage: "backward.end.fill")
                }
            }
            MobileFavoriteMenuButton(isFavorite: model.isFavorite) {
                Task { await model.toggleFavorite() }
            }
            if isEpisode {
                episodeWatchedButtons
            } else if model.isWatched {
                Button("Mark as Unwatched") { Task { await model.toggleWatched() } }
            } else {
                Button("Mark as Watched") { Task { await model.toggleWatched() } }
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if detail.type == "movie" || isEpisode {
            if isEpisode, detail.seriesId != nil {
                SeriesDownloadMenuButton(
                    detail: detail,
                    seasons: model.seasons,
                    selectedSeason: model.selectedSeason,
                    episodes: model.episodes,
                    episodesBySeason: model.episodesBySeason,
                    episodeVersions: detail.versions ?? [],
                    selectedVersionFileId: session.movieVersionId,
                    style: .labeled
                )
            } else {
                DownloadActionButton(
                    detail: detail,
                    versions: detail.versions ?? [],
                    selectedVersionFileId: session.movieVersionId,
                    showOptions: $showsDownloadOptions,
                    style: .labeled
                )
            }
        }
    }

    /// The episode, its season and the whole series.
    @ViewBuilder
    private var episodeWatchedButtons: some View {
        if model.isWatched {
            Button("Mark Episode as Unwatched") { Task { await model.toggleWatched() } }
        } else {
            Button("Mark Episode as Watched") { Task { await model.toggleWatched() } }
        }
        if let season = model.selectedSeason {
            MobileSeasonWatchedButton(season: season) {
                Task { await model.toggleSelectedSeasonWatched() }
            }
        }
        if !model.seasons.isEmpty, model.seasons.allSatisfy({ $0.userData?.played == true }) {
            Button("Mark Series as Unwatched") { Task { await model.toggleSeriesWatched() } }
        } else {
            Button("Mark Series as Watched") { Task { await model.toggleSeriesWatched() } }
        }
    }

    private func playTapped() {
        if resumePosition != nil {
            showsResumeAlert = true
        } else {
            play(fromBeginning: false)
        }
    }

    private func play(fromBeginning: Bool) {
        session.playMovie(contentId: contentId, detail: detail, fromBeginning: fromBeginning, router: router)
    }

    // MARK: Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            if isEpisode, !model.seasons.isEmpty || !model.episodes.isEmpty || model.isLoadingEpisodes {
                episodesSection
            }
            MobileTrailersSection(contentId: contentId)
            if CastCrewGrouping.hasPeople(cast: detail.cast, crew: detail.crew) {
                MobileCastCrewSection(
                    cast: detail.cast ?? [],
                    crew: detail.crew ?? [],
                    onSelectPerson: navigation.openPerson
                )
            }
            if !isEpisode {
                MobileSimilarSection(titles: similarTitles) { item in
                    navigation.openItem(item.contentId)
                }
            }
            if let collectionRow {
                MobileCollectionSection(row: collectionRow, currentContentId: detail.contentId) { item in
                    navigation.openItem(item.contentId)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                MobileSectionHeader(title: Text("Media Information"))
                DetailMediaSection(version: effectiveVersion)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Episodes have no More Like This.
        .loadsSimilarTitles(similarTitles, contentId: contentId, detail: detail, isEnabled: !isEpisode)
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.seasons.isEmpty {
                MobileSeasonChips(seasons: model.seasons, selectedSeason: model.selectedSeason) { season in
                    Task { await model.selectSeason(season) }
                }
            }
            MobileSectionHeader(title: Text("\(seasonHeading) Episodes"))
                .padding(.horizontal, 16)
            MobileEpisodeBrowser(
                seasons: model.seasons,
                selectedSeason: model.selectedSeason,
                episodes: model.episodes,
                episodesBySeason: model.episodesBySeason,
                isLoading: model.isLoadingEpisodes,
                onSelectSeason: { season in
                    Task { await model.selectSeason(season) }
                },
                onSelectEpisode: { episode in
                    navigation.openItem(episode.contentId)
                },
                currentEpisodeId: detail.contentId
            )
        }
    }

    /// "Season 2", or "This Season" when the number isn't known.
    private var seasonHeading: String {
        if let number = model.selectedSeason?.seasonNumber ?? detail.seasonNumber, number > 0 {
            return String(localized: "Season \(String(number))")
        }
        return String(localized: "This Season")
    }

    // MARK: Loading

    private func loadScore() async {
        guard detail.type == "movie" else { return }
        let store = TVTMDbStore.shared
        let context = store.contextKey
        let value = try? await store.rating(for: detail)
        guard !Task.isCancelled else { return }
        if let value {
            tmdbScore = TMDbRatingResult(contentId: contentId, context: context, value: value)
        } else {
            tmdbScore = nil
        }
    }

    private func loadCollection() async {
        let store = MovieCollectionRowStore.shared
        if !store.canKeep(collectionRow, for: detail) {
            collectionRow = nil
        }
        let row = await store.loadRow(for: detail)
        guard !Task.isCancelled else { return }
        collectionRow = row
    }
}
#endif
