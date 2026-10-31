import SwiftUI

#if !os(tvOS)
/// The season page: the hero plays the season's next episode, then its
/// episodes, cast and the season's details.
struct MobileSeasonPage: View {
    let contentId: String
    let detail: ItemDetail
    let session: MobileDetailSession
    let navigation: MobileDetailNavigation

    @State private var playsWhenReady = false
    @State private var showsResumeAlert = false
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var model: ItemDetailViewModel { session.model }

    private var nextUpEpisode: EpisodeListItem? {
        MobileDetailSession.defaultEpisode(model.episodes)
    }

    /// The selected season, or else the one this page is for.
    private var shownSeason: Season? {
        model.selectedSeason ?? model.seasons.first { $0.seasonNumber == detail.seasonNumber }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: PhoneDuo.usesPhoneDetailLayout(horizontalSizeClass) ? 32 : 16) {
                MobileDetailHero(content: heroContent) {
                    actions
                } underOverview: {
                    DescriptionTranslationView(viewModel: model, contentId: detail.contentId)
                        .id(detail.contentId)
                }
                belowFold
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .detailScrollDismissal()
        .vividResumePlaybackAlert(
            isPresented: $showsResumeAlert,
            stoppedAt: MobileDetailControls.stoppedAt(
                MobileDetailSession.displayResumePosition(nextUpEpisode?.userData)
            ),
            onResume: {
                if let episode = nextUpEpisode { play(episode, fromBeginning: false) }
            },
            onRestart: {
                if let episode = nextUpEpisode { play(episode, fromBeginning: true) }
            }
        )
        .task(id: session.playbackEpisode(isSeries: false)?.contentId) {
            await session.refreshNextUp(isSeries: false)
        }
        .onChange(of: nextUpEpisode?.contentId) { _, id in
            guard playsWhenReady, id != nil, let episode = nextUpEpisode else { return }
            playsWhenReady = false
            playOrAskToResume(episode)
        }
    }

    // MARK: Hero

    private var heroContent: MobileHeroContent {
        var content = MobileHeroContent(title: detail.title)
        content.posterUrl = detail.posterUrl
        content.posterThumbhash = detail.posterThumbhash
        content.backdropUrl = detail.backdropUrl
        content.backdropThumbhash = detail.backdropThumbhash
        content.eyebrow = detail.seriesTitle
        content.sourceTokens = MobileHeroRules.seasonSourceTokens(detail, liveEpisodeCount: model.episodes.count)
        content.overview = detail.overview
        content.qualityBadges = MobileHeroRules.qualityBadges(version: session.effectiveNextUpVersion, summary: nil)
        return content
    }

    // MARK: Actions

    private var playTitle: String {
        guard let episode = nextUpEpisode else { return String(localized: "Play") }
        return String(localized: "Play E\(MobileDetailControls.digits(episode.episodeNumber))")
    }

    private var actions: some View {
        VStack(spacing: 12) {
            PhoneDetailPrimaryActions(stackedSpacing: 12) {
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: playTitle,
                    action: playTapped,
                    fullWidth: true,
                    resumeProgress: MobileDetailControls.resumeProgress(for: nextUpEpisode)
                )
            } selectors: {
                MobileSelectorsPlacement {
                    nextUpSelectors
                }
            } actions: {
                PhoneLabeledActionRow {
                    actionRow
                }
            }
            MobileSelectorsPlacement {
                nextUpSelectors
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var nextUpSelectors: some View {
        if nextUpEpisode != nil, let version = session.effectiveNextUpVersion {
            MobilePlaybackSelectors(
                versions: session.nextUpDetail?.versions ?? [],
                currentVersion: version,
                chosenVersionId: session.nextUpVersionId,
                chosenAudioIndex: session.nextUpAudioIndex,
                onChooseVersion: { session.chooseNextUpVersion($0) },
                onChooseAudio: { session.chooseNextUpAudio($0) }
            )
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        MobileNamedAction(
            icon: "heart",
            activeIcon: "heart.fill",
            isActive: model.isFavorite,
            caption: "Favorite",
            spokenLabel: model.isFavorite ? "Remove from favorites" : "Add to favorites"
        ) {
            Task { await model.toggleFavorite() }
        }
        .mobileMovesToMore()
        MobileNamedAction(
            icon: "bookmark",
            activeIcon: "bookmark.fill",
            isActive: model.inWatchlist,
            caption: "Watchlist",
            spokenLabel: model.inWatchlist ? "Remove from watchlist" : "Add to watchlist"
        ) {
            Task { await model.toggleWatchlist() }
        }
        MobileNamedMenu(icon: "checkmark.circle", caption: "Watched") {
            seasonWatchedButtons
        }
        .mobileMovesToMore()
        SeriesDownloadMenuButton(
            detail: detail,
            seasons: model.seasons,
            selectedSeason: shownSeason,
            episodes: model.episodes,
            episodesBySeason: model.episodesBySeason,
            style: .labeled
        )
        MobileMoreMenu {
            MobileFavoriteMenuButton(isFavorite: model.isFavorite) {
                Task { await model.toggleFavorite() }
            }
            seasonWatchedButtons
        }
    }

    /// This season, then the whole series when the season belongs to one.
    @ViewBuilder
    private var seasonWatchedButtons: some View {
        if model.isWatched {
            Button("Mark Season as Unwatched") { Task { await model.toggleWatched() } }
        } else {
            Button("Mark Season as Watched") { Task { await model.toggleWatched() } }
        }
        if detail.seriesId != nil {
            if !model.seasons.isEmpty, model.seasons.allSatisfy({ $0.userData?.played == true }) {
                Button("Mark Series as Unwatched") { Task { await model.toggleSeriesWatched() } }
            } else {
                Button("Mark Series as Watched") { Task { await model.toggleSeriesWatched() } }
            }
        }
    }

    private func playTapped() {
        guard let episode = nextUpEpisode else {
            playsWhenReady = true
            return
        }
        playOrAskToResume(episode)
    }

    private func playOrAskToResume(_ episode: EpisodeListItem) {
        if episode.userData?.isInProgress == true {
            showsResumeAlert = true
        } else {
            play(episode, fromBeginning: false)
        }
    }

    private func play(_ episode: EpisodeListItem, fromBeginning: Bool) {
        session.playEpisode(
            episode.contentId,
            fromBeginning: fromBeginning,
            fileChoice: session.nextUpVersionId,
            isSeries: false,
            router: router
        )
    }

    // MARK: Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            episodesSection
            if CastCrewGrouping.hasPeople(cast: detail.cast, crew: detail.crew) {
                MobileCastCrewSection(
                    cast: detail.cast ?? [],
                    crew: detail.crew ?? [],
                    onSelectPerson: navigation.openPerson
                )
            }
            VStack(alignment: .leading, spacing: 14) {
                MobileSectionHeader(title: Text("Details"))
                MobileSeasonFacts(detail: detail)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var episodesSection: some View {
        let title = shownSeason.map { String(localized: "\($0.downloadDisplayName) Episodes") }
            ?? String(localized: "Episodes")
        return VStack(alignment: .leading, spacing: 14) {
            if !model.seasons.isEmpty {
                MobileSeasonChips(seasons: model.seasons, selectedSeason: model.selectedSeason, onSelect: openSeason)
            }
            MobileSectionHeader(title: Text(verbatim: title))
                .padding(.horizontal, 16)
            MobileEpisodeBrowser(
                seasons: model.seasons,
                selectedSeason: model.selectedSeason,
                episodes: model.episodes,
                episodesBySeason: model.episodesBySeason,
                isLoading: model.isLoadingEpisodes,
                onSelectSeason: openSeason,
                onSelectEpisode: { episode in
                    navigation.openItem(episode.contentId)
                },
                allowsSeasonPaging: false
            )
        }
    }

    /// Another season opens its own page.
    private func openSeason(_ season: Season) {
        guard season.id != detail.contentId else { return }
        navigation.openItem(season.contentId)
    }
}
#endif
