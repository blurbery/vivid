import SwiftUI

#if !os(tvOS)
/// The series page: the hero plays the next episode, then the season's
/// episodes, trailers, cast, similar titles and the next episode's media
/// information.
struct MobileSeriesPage: View {
    let contentId: String
    let detail: ItemDetail
    let session: MobileDetailSession
    let scrollState: PhoneDetailScrollState
    let navigation: MobileDetailNavigation

    /// Play was tapped before the next episode was known.
    private struct PendingPlay: Equatable {
        let seasonNumber: Int?
    }

    private struct ScoreKey: Equatable {
        let contentId: String
        let context: String
    }

    @State private var pendingPlay: PendingPlay?
    @State private var resumeEpisode: EpisodeListItem?
    @State private var tmdbScore: TMDbRatingResult?
    @State private var similarTitles = MobileSimilarTitles()
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var model: ItemDetailViewModel { session.model }

    /// The episode the page offers to play next.
    private var nextUpEpisode: EpisodeListItem? {
        let episodes = model.episodes
        guard let id = session.seriesNextUpEpisodeId else { return MobileDetailSession.defaultEpisode(episodes) }
        if let episode = episodes.first(where: { $0.contentId == id }) { return episode }
        return MediaServerProvider.active == .jellyfin ? nil : MobileDetailSession.defaultEpisode(episodes)
    }

    var body: some View {
        MobileDetailSurface(
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            isArtworkGlassEnabled: true
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
            isPresented: Binding(
                get: { resumeEpisode != nil },
                set: { if !$0 { resumeEpisode = nil } }
            ),
            stoppedAt: MobileDetailControls.stoppedAt(
                MobileDetailSession.displayResumePosition(resumeEpisode?.userData)
            ),
            onResume: {
                if let resumeEpisode { play(resumeEpisode, fromBeginning: false) }
            },
            onRestart: {
                if let resumeEpisode { play(resumeEpisode, fromBeginning: true) }
            }
        )
        .task(id: session.playbackEpisode(isSeries: true)?.contentId) {
            await session.refreshNextUp(isSeries: true)
        }
        .task(id: ScoreKey(contentId: contentId, context: TVTMDbStore.shared.contextKey), priority: .utility) {
            await loadScore()
        }
        .onChange(of: nextUpEpisode?.contentId) { _, id in
            guard let pending = pendingPlay, id != nil, let episode = nextUpEpisode else { return }
            pendingPlay = nil
            // A play meant for another season is dropped.
            if let season = pending.seasonNumber, episode.seasonNumber != season { return }
            playOrAskToResume(episode)
        }
        .onChange(of: model.isLoadingEpisodes) { _, isLoading in
            if !isLoading, nextUpEpisode == nil {
                pendingPlay = nil
            }
        }
    }

    // MARK: Hero

    private var heroContent: MobileHeroContent {
        var content = MobileHeroContent(title: detail.title)
        content.logoUrl = detail.logoUrl
        content.posterUrl = detail.posterUrl
        content.posterThumbhash = detail.posterThumbhash
        content.backdropUrl = detail.backdropUrl
        content.backdropThumbhash = detail.backdropThumbhash
        content.eyebrow = MobileHeroRules.eyebrow(detail)
        content.sourceTokens = MobileHeroRules.seriesSourceTokens(detail)
        content.ageRating = MobileHeroRules.ageRating(detail)
        content.overview = detail.overview
        content.credit = MobileHeroRules.credit(detail)
        content.factsTokens = MobileHeroRules.seriesFacts(detail)
        content.parallax = true
        content.tmdbScore = tmdbScore?.value(for: contentId)
        var heading = [
            String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
        ]
        if let seasons = detail.seasonCount, seasons > 0 {
            heading.append(String(localized: "\(seasons) Seasons"))
        }
        content.headingTokens = heading
        content.releaseFacts = MobileHeroRules.releaseFacts(
            year: detail.year,
            runtime: nextUpEpisode?.runtime ?? detail.runtime
        )
        content.qualityBadges = MobileHeroRules.qualityBadges(
            version: session.effectiveNextUpVersion,
            summary: session.nextUpVersionId == nil ? detail.overlaySummary : nil
        )
        return content
    }

    private var underOverview: some View {
        VStack(alignment: .center, spacing: 14) {
            DescriptionTranslationView(viewModel: model, contentId: detail.contentId)
                .id(detail.contentId)
            if nextUpEpisode != nil {
                MobileSelectorsPlacement {
                    selectorSlot
                }
            }
        }
    }

    /// Holds its height while the next episode's options load, so nothing
    /// below it moves.
    private var selectorSlot: some View {
        let isLoading = session.isLoadingNextUp
        let version = session.effectiveNextUpVersion
        return ZStack(alignment: .top) {
            MobileSelectorSkeleton()
                .opacity(isLoading || version == nil ? 1 : 0)
            if version != nil {
                MobilePlaybackSelectors(
                    versions: session.nextUpDetail?.versions ?? [],
                    currentVersion: version,
                    chosenVersionId: session.nextUpVersionId,
                    chosenAudioIndex: session.nextUpAudioIndex,
                    onChooseVersion: { session.chooseNextUpVersion($0) },
                    onChooseAudio: { session.chooseNextUpAudio($0) }
                )
                .opacity(isLoading ? 0 : 1)
                .allowsHitTesting(!isLoading)
            }
        }
        .frame(minHeight: 52, alignment: .top)
        .animation(.easeInOut(duration: 0.16), value: isLoading)
        .accessibilityElement(children: isLoading ? .ignore : .contain)
        .accessibilityLabel(isLoading ? Text("Loading playback options") : Text("Playback options"))
    }

    // MARK: Actions

    private var playTitle: String {
        guard let episode = nextUpEpisode else { return String(localized: "Play") }
        let season = String(episode.seasonNumber)
        let number = String(episode.episodeNumber)
        return String(localized: "Play S\(season)·E\(number)")
    }

    private var actions: some View {
        VStack(spacing: 14) {
            PhoneDetailPrimaryActions {
                PhonePrimaryPillButton(
                    icon: "play.fill",
                    title: playTitle,
                    action: playTapped,
                    fullWidth: true,
                    resumeProgress: MobileDetailControls.resumeProgress(for: nextUpEpisode)
                )
            } selectors: {
                if nextUpEpisode != nil {
                    MobileSelectorsPlacement {
                        selectorSlot
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
        MobileNamedMenu(icon: "checkmark.circle", caption: "Watched") {
            seriesWatchedButtons
        }
        .mobileMovesToMore()
        SeriesDownloadMenuButton(
            detail: detail,
            seasons: model.seasons,
            selectedSeason: model.selectedSeason,
            episodes: model.episodes,
            episodesBySeason: model.episodesBySeason,
            style: .labeled
        )
        MobileMoreMenu {
            MobileFavoriteMenuButton(isFavorite: model.isFavorite) {
                Task { await model.toggleFavorite() }
            }
            seriesWatchedButtons
        }
    }

    /// The next episode, the season that's showing and the whole series.
    @ViewBuilder
    private var seriesWatchedButtons: some View {
        if let episode = nextUpEpisode {
            let episodeId = episode.contentId
            if episode.userData?.played == true {
                Button("Mark Episode as Unwatched") {
                    Task { _ = await model.setEpisodeWatched(contentId: episodeId, played: false) }
                }
            } else {
                Button("Mark Episode as Watched") {
                    Task { _ = await model.setEpisodeWatched(contentId: episodeId, played: true) }
                }
            }
        }
        if let season = model.selectedSeason {
            MobileSeasonWatchedButton(season: season) {
                Task { await model.toggleSelectedSeasonWatched() }
            }
        }
        if model.isWatched {
            Button("Mark Series as Unwatched") { Task { await model.toggleWatched() } }
        } else {
            Button("Mark Series as Watched") { Task { await model.toggleWatched() } }
        }
    }

    private func playTapped() {
        guard let episode = nextUpEpisode else {
            pendingPlay = PendingPlay(seasonNumber: model.selectedSeason?.seasonNumber)
            return
        }
        playOrAskToResume(episode)
    }

    private func playOrAskToResume(_ episode: EpisodeListItem) {
        if episode.userData?.isInProgress == true {
            resumeEpisode = episode
        } else {
            play(episode, fromBeginning: false)
        }
    }

    private func play(_ episode: EpisodeListItem, fromBeginning: Bool) {
        session.playEpisode(
            episode.contentId,
            fromBeginning: fromBeginning,
            fileChoice: fileChoice(for: episode),
            isSeries: true,
            router: router
        )
    }

    /// The chosen version, when it belongs to this episode.
    private func fileChoice(for episode: EpisodeListItem) -> Int? {
        guard let chosen = session.nextUpVersionId, episode.contentId == nextUpEpisode?.contentId else { return nil }
        let versions = session.nextUpDetail?.versions ?? []
        if !versions.isEmpty {
            return versions.contains { $0.fileId == chosen } ? chosen : nil
        }
        return (episode.files ?? []).contains { $0.fileId == chosen } ? chosen : nil
    }

    // MARK: Below the fold

    private var belowFold: some View {
        VStack(alignment: .leading, spacing: 36) {
            episodesSection
            MobileTrailersSection(contentId: contentId)
            if CastCrewGrouping.hasPeople(cast: detail.cast, crew: detail.crew) {
                MobileCastCrewSection(
                    cast: detail.cast ?? [],
                    crew: detail.crew ?? [],
                    onSelectPerson: navigation.openPerson
                )
            }
            MobileSimilarSection(titles: similarTitles) { item in
                navigation.openItem(item.contentId)
            }
            mediaInformation
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .loadsSimilarTitles(similarTitles, contentId: contentId, detail: detail)
    }

    private var episodesSection: some View {
        let selected = model.selectedSeason
        let title = selected.map { String(localized: "\($0.downloadDisplayName) Episodes") }
            ?? String(localized: "Episodes")
        let count = selected?.episodeCount ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            if !model.seasons.isEmpty {
                MobileSeasonChips(seasons: model.seasons, selectedSeason: selected, onSelect: chooseSeason)
            }
            MobileSectionHeader(
                title: Text(verbatim: title),
                trailing: count > 0 ? String(localized: "\(count) episodes") : nil
            )
            .padding(.horizontal, 16)
            MobileEpisodeBrowser(
                seasons: model.seasons,
                selectedSeason: selected,
                episodes: model.episodes,
                episodesBySeason: model.episodesBySeason,
                isLoading: model.isLoadingEpisodes,
                onSelectSeason: chooseSeason,
                onSelectEpisode: chooseEpisode,
                onPlayEpisode: { card in
                    if let episode = model.episodes.first(where: { $0.contentId == card.contentId }) {
                        playOrAskToResume(episode)
                    }
                },
                currentEpisodeId: nextUpEpisode?.contentId,
                selectsCentredCard: true,
                forcesCarousel: true,
                captionOverride: .titleMetadata
            )
        }
    }

    private func chooseSeason(_ season: Season) {
        pendingPlay = nil
        session.selectedEpisodeId = nil
        Task { await model.selectSeason(season) }
    }

    private func chooseEpisode(_ episode: EpisodeListItem) {
        pendingPlay = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            session.selectedEpisodeId = episode.contentId
        }
    }

    private var mediaInformation: some View {
        VStack(alignment: .leading, spacing: 14) {
            MobileSectionHeader(title: Text("Media Information"))
            if let episode = nextUpEpisode {
                Text(verbatim: Self.episodeCaption(episode))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            if session.isLoadingNextUp {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                DetailMediaSection(version: session.effectiveNextUpVersion)
            }
        }
        .padding(.horizontal, 16)
    }

    /// "S1 · E2 [em dash] Title", without the title when the title is nil.
    /// An empty title still gets the dash.
    private static func episodeCaption(_ episode: EpisodeListItem) -> String {
        let season = String(episode.seasonNumber)
        let number = String(episode.episodeNumber)
        if let title = episode.title {
            return String(localized: "S\(season) · E\(number) \u{2014} \(title)")
        }
        return String(localized: "S\(season) · E\(number)")
    }

    // MARK: Loading

    private func loadScore() async {
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
}
#endif
