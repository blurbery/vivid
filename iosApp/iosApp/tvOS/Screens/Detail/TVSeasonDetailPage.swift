#if os(tvOS)
import SwiftUI

/// One season of a series: its next-up episode in the hero, the season's
/// episodes, its people and its dates. The app backdrop shows through.
struct TVSeasonDetailPage: View {
    let viewModel: ItemDetailViewModel
    let detail: ItemDetail
    let nextUpEpisode: EpisodeListItem?
    let nextUp: TVDetailNextUp
    let picks: TVDetailNextUpPicks
    let actions: TVDetailPageActions
    let selectEpisode: (String) -> Void
    let selectSeason: (Season) -> Void
    /// Plays an episode with the file the page sends, from the beginning
    /// when true.
    let playEpisode: (String, Int?, Bool) -> Void

    @FocusState private var heroFocus: TVDetailHeroFocus?
    @Namespace private var scope
    @State private var seasonRowFocused = false

    private static let sectionSpacing: CGFloat = 28

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 48) {
                    hero
                        .id(TVDetailScrollAnchor.hero)
                    VStack(alignment: .leading, spacing: 72) {
                        episodesSection
                            .id(TVDetailScrollAnchor.episodes)
                        if CastCrewGrouping.hasPeople(cast: detail.cast, crew: detail.crew) {
                            TVDetailSection(title: "Cast & Crew", spacing: Self.sectionSpacing) {
                                TVCastAndCrewRail(cast: detail.cast ?? [], crew: detail.crew ?? [], onSelectPerson: actions.selectPerson)
                            }
                        }
                        TVDetailSection(title: "Details", spacing: Self.sectionSpacing) {
                            let facts = TVDetailFactsBlock.facts(for: detail)
                            if !facts.isEmpty {
                                TVDetailFactsBlock(facts: facts)
                            }
                        }
                    }
                    .padding(.horizontal, VividTheme.safePadding)
                    .padding(.bottom, 160)
                }
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .focusScope(scope)
            .defaultFocus($heroFocus, .play, priority: .userInitiated)
            .modifier(TVDetailFocusChoreography(
                proxy: proxy,
                region: TVDetailFocusRegion.current(
                    actionRow: heroFocus?.isActionRow == true,
                    moreLikeThis: false,
                    seasonRow: seasonRowFocused
                )
            ))
        }
    }

    // MARK: Playback inputs

    private var versions: [FileVersion] { nextUp.detail?.versions ?? [] }

    /// The picked file, else the last one used, else the first.
    private var currentVersion: FileVersion? {
        if let pick = picks.fileId, let version = versions.first(where: { $0.fileId == pick }) {
            return version
        }
        if let last = nextUp.detail?.userData?.lastFileId, let version = versions.first(where: { $0.fileId == last }) {
            return version
        }
        return versions.first
    }

    private var playAction: TVDetailPlayAction {
        guard let episode = nextUpEpisode else {
            return TVDetailPlayAction(title: nil, subtitle: nil, progress: nil, offersStartOver: false, play: {}, startOver: {})
        }
        let progress = ResumePresentation(
            position: episode.userData?.positionSeconds,
            duration: episode.userData?.durationSeconds,
            episodeLabel: TVDetailEpisodeCode.spaced(season: episode.seasonNumber, episode: episode.episodeNumber)
        )
        let file = picks.fileId
        return TVDetailPlayAction(
            title: episode.userData?.isInProgress == true ? String(localized: "Resume") : String(localized: "Play"),
            subtitle: String(localized: "S\(String(episode.seasonNumber)):E\(String(episode.episodeNumber))"),
            progress: progress,
            offersStartOver: progress != nil,
            play: { playEpisode(episode.contentId, file, false) },
            startOver: { playEpisode(episode.contentId, file, true) }
        )
    }

    /// The episode count (or the loaded count), then the first two genres.
    private var sourceTokens: [String] {
        var tokens: [String] = []
        if let count = detail.episodeCount, count > 0 {
            tokens.append(String(localized: "\(count) Episodes"))
        } else if !viewModel.episodes.isEmpty {
            tokens.append(String(localized: "\(viewModel.episodes.count) Episodes"))
        }
        return tokens + TVHeroMetadata.genreTokens(detail)
    }

    // MARK: Hero

    private var hero: some View {
        TVDetailHeroPanel(
            layout: .standard(clipsToHeight: true),
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            creditLine: TVHeroMetadata.creditLine(detail)
        ) {
            TVDetailStandardPrimary(
                eyebrow: detail.seriesTitle,
                treatment: .logo(url: nil, title: detail.title),
                metadata: TVDetailMetadataSlots(
                    separatesSourceRow: false,
                    sourceTokens: sourceTokens,
                    facts: [],
                    contentRating: nil
                ),
                overview: detail.overview,
                synopsisEnabled: true,
                focus: $heroFocus
            ) {
                DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                    .id(detail.contentId)
            }
        } summary: {
            TVDetailPlaybackSummary(values: TVDetailPlaybackSummaryValues(version: currentVersion))
        } actions: {
            TVDetailActionRow(
                play: playAction,
                selectors: TVDetailSelectorInputs(
                    version: currentVersion,
                    subtitleContext: TVDetailPlaybackRules.subtitleContext(for: nextUp.detail),
                    audioPick: picks.audio,
                    subtitlePick: picks.subtitle,
                    onAudio: picks.pickAudio,
                    onSubtitle: picks.pickSubtitle
                ),
                inWatchlist: viewModel.inWatchlist,
                onToggleWatchlist: actions.toggleWatchlist,
                focus: $heroFocus,
                scope: scope,
                claimKey: TVDetailFocusClaimKey(
                    pageKey: detail.contentId,
                    seasonKey: viewModel.selectedSeason?.contentId,
                    requiresSeasonKey: true
                )
            ) {
                moreMenu
            }
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVDetailVersionMenu(versions: versions, pick: picks.fileId, onPick: picks.pickVersion)
        if let episode = nextUpEpisode, episode.userData?.isInProgress == true {
            TVDetailMoreMenuRows.startOver { playEpisode(episode.contentId, picks.fileId, true) }
        }
        TVDetailMoreMenuRows.favorite(isFavorite: viewModel.isFavorite, action: actions.toggleFavorite)
        if let episode = nextUpEpisode {
            let played = episode.userData?.played ?? false
            TVDetailMoreMenuRows.episodeWatched(isWatched: played) {
                Task { _ = await actions.setEpisodeWatched(episode.contentId, !played) }
            }
        }
        TVDetailMoreMenuRows.seasonWatched(isWatched: viewModel.isWatched, action: actions.toggleWatched)
        if let seriesId = detail.seriesId {
            TVDetailMoreMenuRows.goToSeries { actions.selectItem(seriesId) }
        }
    }

    // MARK: Episodes

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            TVDetailSectionHeader("Episodes", label: "This Season")
            if viewModel.seasons.count > 1 {
                TVSeasonChipRow(
                    seasons: viewModel.seasons,
                    selectedSeasonId: viewModel.selectedSeason?.contentId,
                    onSelect: selectSeason,
                    onFocusChange: { seasonRowFocused = $0 }
                )
            }
            if viewModel.isLoadingEpisodes {
                ProgressView()
                    .tint(Color.vividOnSurface)
                    .padding()
                    .frame(maxWidth: .infinity)
            } else if viewModel.episodes.isEmpty {
                Text("No episodes available")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.vividSecondaryText)
            } else {
                TVEpisodeRail(
                    episodes: viewModel.episodes,
                    onSelect: selectEpisode,
                    spoilerSeasons: viewModel.seasons,
                    onSetWatched: actions.setEpisodeWatched,
                    onSetFavorite: actions.setEpisodeFavorite,
                    currentContentId: nextUpEpisode?.contentId,
                    currentContentIsFavorite: nextUpEpisode.flatMap { viewModel.episodeFavoriteStates[$0.contentId] } ?? false,
                    favoriteStates: viewModel.episodeFavoriteStates
                )
            }
        }
    }
}
#endif
