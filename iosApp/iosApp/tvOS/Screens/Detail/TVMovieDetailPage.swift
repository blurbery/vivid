#if os(tvOS)
import SwiftUI

/// A movie on the native page, or any other single item (an episode that
/// couldn't open its series, for one) on the older scrolling layout.
struct TVMovieDetailPage: View {
    let viewModel: ItemDetailViewModel
    let detail: ItemDetail
    let contentId: String
    /// An episode's series, for its logo, title and cast.
    let supportingDetail: ItemDetail?
    let trailerEntries: [TrailerRailEntry]
    let actions: TVDetailPageActions
    /// Plays the item, from the beginning when true.
    let play: (Bool) -> Void
    let pickVersion: (Int?) -> Void
    let pickAudio: (Int?) -> Void
    let pickSubtitle: (Int?) -> Void
    let selectEpisode: (String) -> Void
    let playEpisodeShortcut: (String) -> Void

    @ObservedObject private var profilePrefs = ProfilePrefsStore.shared
    @FocusState private var heroFocus: TVDetailHeroFocus?
    @Namespace private var scope
    @State private var playHadFocus = false
    @State private var collectionRow: MovieCollectionRowStore.Row?
    @State private var tmdbRating: TMDbRatingResult?
    @State private var focusedEpisodeId: String?
    @State private var moreLikeThisFocused = false

    var body: some View {
        Group {
            if detail.type == "movie" {
                nativeLayout
            } else {
                olderLayout
            }
        }
        .task(id: collectionKey, priority: .utility) {
            await loadCollection()
        }
        .onChange(of: heroFocus) { _, focus in
            if focus == .play { playHadFocus = true }
        }
    }

    // MARK: Playback inputs

    private var versions: [FileVersion] { detail.versions ?? [] }

    private var currentVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: viewModel.preferredVersionFileId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private var selectorInputs: TVDetailSelectorInputs {
        TVDetailSelectorInputs(
            version: currentVersion,
            subtitleContext: TVDetailPlaybackRules.subtitleContext(for: detail),
            audioPick: viewModel.preferredAudioTrackIndex,
            subtitlePick: viewModel.preferredSubtitleTrackIndex,
            onAudio: pickAudio,
            onSubtitle: pickSubtitle
        )
    }

    /// The saved position Play resumes from.
    private var resumePosition: Double? {
        guard let position = detail.userData?.positionSeconds, position > 30 else { return nil }
        if let duration = detail.userData?.durationSeconds, duration > 0, position >= duration - 5 { return nil }
        return position
    }

    private var playAction: TVDetailPlayAction {
        let resume = resumePosition
        return TVDetailPlayAction(
            title: resume.map { String(localized: "Resume \(PlayerTimeFormatter.formatHMS($0))") } ?? String(localized: "Play"),
            subtitle: nil,
            progress: resume.flatMap { ResumePresentation(position: $0, duration: detail.userData?.durationSeconds) },
            offersStartOver: resume != nil,
            play: { play(false) },
            startOver: { play(true) }
        )
    }

    private var actionRow: some View {
        TVDetailActionRow(
            play: playAction,
            selectors: selectorInputs,
            inWatchlist: viewModel.inWatchlist,
            onToggleWatchlist: actions.toggleWatchlist,
            focus: $heroFocus,
            scope: scope,
            claimKey: TVDetailFocusClaimKey(pageKey: contentId)
        ) {
            moreMenu
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        TVDetailVersionMenu(versions: versions, pick: viewModel.preferredVersionFileId, onPick: pickVersion)
        if resumePosition != nil {
            TVDetailMoreMenuRows.startOver { play(true) }
        }
        TVDetailMoreMenuRows.favorite(isFavorite: viewModel.isFavorite, action: actions.toggleFavorite)
        if detail.type == "episode" {
            TVDetailMoreMenuRows.episodeWatched(isWatched: viewModel.isWatched, action: actions.toggleWatched)
        } else {
            TVDetailMoreMenuRows.titleWatched(isWatched: viewModel.isWatched, action: actions.toggleWatched)
        }
        if let seriesId = detail.seriesId {
            if let season = detail.seasonNumber, season > 0 {
                TVDetailMoreMenuRows.goToSeason { actions.selectItem("\(seriesId)-S\(season)") }
            }
            TVDetailMoreMenuRows.goToSeries { actions.selectItem(seriesId) }
        }
    }

    private var translation: some View {
        DescriptionTranslationView(viewModel: viewModel, contentId: contentId)
            .id(contentId)
    }

    // MARK: Native layout

    private var nativeLayout: some View {
        TVDetailNativeShell(
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            logoUrl: detail.logoUrl,
            title: detail.title
        ) { showcase in
            TVDetailHero(layout: .showcase(height: showcase), creditLine: TVHeroMetadata.creditLine(detail)) {
                TVDetailCompactPrimary(
                    title: detail.title,
                    logoUrl: detail.logoUrl,
                    headingTokens: [String(localized: "Movie")],
                    genres: TVHeroMetadata.genreTokens(detail),
                    contentRating: TVHeroMetadata.contentRating(detail),
                    overview: detail.overview,
                    synopsisEnabled: playHadFocus,
                    focus: $heroFocus
                ) {
                    translation
                }
            } summary: {
                TVDetailTechnicalRow(
                    releaseFacts: TVHeroMetadata.releaseFacts(year: detail.year, runtime: detail.runtime),
                    badges: TVHeroMetadata.sourceBadges(
                        currentVersion,
                        summary: viewModel.preferredVersionFileId == nil ? detail.overlaySummary : nil
                    ),
                    tmdbScore: tmdbRating?.value(for: contentId)
                )
            } actions: {
                actionRow
            }
        } shelves: {
            VStack(alignment: .leading, spacing: TVDetailHeroLayout.sectionSpacing) {
                TVDetailTrailersRail(entries: trailerEntries, onSelect: actions.selectTrailer)
                castSection(cast: detail.cast ?? [], crew: detail.crew ?? [])
                TVMoreLikeThisSection(sourceId: contentId, sourceDetail: detail, onSelect: actions.selectItem)
                collectionSection
                mediaSection
            }
        }
        .focusScope(scope)
        .defaultFocus($heroFocus, .play, priority: .userInitiated)
        .onPlayPauseCommand {
            play(false)
        }
        .task(id: "\(contentId)|\(TVTMDbStore.shared.contextKey)", priority: .utility) {
            await loadRating()
        }
    }

    // MARK: Older layout

    private var olderLayout: some View {
        TVDetailStandardSurface(backdropUrl: detail.backdropUrl) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        olderHero
                            .id(TVDetailScrollAnchor.hero)
                        VStack(alignment: .leading, spacing: TVDetailHeroLayout.sectionSpacing) {
                            episodesSection
                            TVDetailTrailersRail(entries: trailerEntries, onSelect: actions.selectTrailer)
                            castSection(cast: olderCast, crew: detail.crew ?? [])
                            TVMoreLikeThisSection(
                                sourceId: moreLikeThisSourceId,
                                sourceDetail: detail,
                                onSelect: actions.selectItem,
                                onFocusChange: { moreLikeThisFocused = $0 }
                            )
                            .id(TVDetailScrollAnchor.moreLikeThis)
                            collectionSection
                            mediaSection
                        }
                        .padding(.horizontal, TVDetailHeroLayout.horizontalInset)
                        .padding(.bottom, TVDetailHeroLayout.pageBottomPadding)
                        .background(alignment: .top) {
                            TVDetailLowerBackground()
                        }
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
                        moreLikeThis: moreLikeThisFocused,
                        seasonRow: false
                    )
                ))
            }
        }
        .modifier(TVEpisodePlayPause(isEnabled: detail.type == "episode") {
            if let focusedEpisodeId, focusedEpisodeId != contentId {
                playEpisodeShortcut(focusedEpisodeId)
            } else {
                play(false)
            }
        })
    }

    /// An episode's series title, for the hierarchy title and metadata rows.
    private var olderSeriesTitle: String? {
        guard detail.type == "episode" else { return nil }
        let title = (supportingDetail?.title ?? detail.seriesTitle)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private var olderLogoUrl: String? {
        detail.type == "episode" ? (supportingDetail?.logoUrl ?? detail.logoUrl) : detail.logoUrl
    }

    private var olderCast: [CastMember] {
        if detail.type == "episode", let seriesCast = supportingDetail?.cast, !seriesCast.isEmpty {
            return seriesCast
        }
        return detail.cast ?? []
    }

    private var moreLikeThisSourceId: String {
        detail.type == "episode" ? (detail.seriesId ?? contentId) : contentId
    }

    private var olderHero: some View {
        let seriesTitle = olderSeriesTitle
        let treatment: TVDetailTitleTreatment = seriesTitle.map {
            .hierarchy(seriesTitle: $0, seriesLogoUrl: olderLogoUrl, episodeTitle: detail.title)
        } ?? .logo(url: olderLogoUrl, title: detail.title)
        return TVDetailHero(
            layout: .standard(clipsToHeight: false),
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            creditLine: TVHeroMetadata.creditLine(detail)
        ) {
            TVDetailStandardPrimary(
                eyebrow: nil,
                treatment: treatment,
                metadata: TVDetailMetadataSlots(
                    separatesSourceRow: seriesTitle != nil,
                    sourceTokens: TVHeroMetadata.olderSourceTokens(detail),
                    facts: TVHeroMetadata.olderFacts(detail),
                    contentRating: TVHeroMetadata.contentRating(detail)
                ),
                overview: detail.overview,
                synopsisEnabled: true,
                focus: $heroFocus
            ) {
                translation
            }
        } summary: {
            TVDetailPlaybackSummary(values: TVDetailPlaybackSummaryValues(version: currentVersion))
        } actions: {
            actionRow
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        if detail.type == "episode", !viewModel.episodes.isEmpty {
            VStack(alignment: .leading, spacing: TVDetailHeroLayout.sectionHeaderSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    episodesHeader
                    Spacer()
                    Text("Current season")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.vividSecondaryText)
                }
                if viewModel.isLoadingEpisodes {
                    ProgressView()
                        .tint(Color.vividOnSurface)
                        .padding()
                        .frame(maxWidth: .infinity)
                } else {
                    TVEpisodeRail(
                        episodes: viewModel.episodes,
                        onSelect: selectEpisode,
                        spoilerSeasons: viewModel.seasons,
                        onFocusedEpisodeChange: { focusedEpisodeId = $0 },
                        onSetWatched: actions.setEpisodeWatched,
                        onSetFavorite: actions.setEpisodeFavorite,
                        currentContentId: contentId,
                        currentContentIsFavorite: viewModel.isFavorite,
                        favoriteStates: viewModel.episodeFavoriteStates,
                        prefersCurrentContentFocus: true
                    )
                }
            }
        }
    }

    private var episodesHeader: TVDetailSectionHeader {
        if let season = viewModel.selectedSeason {
            if season.seasonNumber > 0 {
                return TVDetailSectionHeader("Season \(String(season.seasonNumber)) Episodes")
            }
            if let title = season.title {
                return TVDetailSectionHeader("\(title) Episodes")
            }
            return TVDetailSectionHeader("Specials Episodes")
        }
        if let number = detail.seasonNumber, number > 0 {
            return TVDetailSectionHeader("Season \(String(number)) Episodes")
        }
        return TVDetailSectionHeader("Episodes")
    }

    // MARK: Shared shelves

    @ViewBuilder
    private func castSection(cast: [CastMember], crew: [CrewMember]) -> some View {
        if CastCrewGrouping.hasPeople(cast: cast, crew: crew) {
            TVDetailSection(title: "Cast & Crew") {
                TVDetailCastRail(cast: cast, crew: crew, onSelectPerson: actions.selectPerson)
            }
        }
    }

    @ViewBuilder
    private var collectionSection: some View {
        if let collectionRow {
            TVCollectionRailSection(row: collectionRow, currentContentId: detail.contentId, onSelect: actions.selectItem)
        }
    }

    private var mediaSection: some View {
        TVDetailSection(title: "Media Information") {
            DetailMediaSection(version: currentVersion)
        }
    }

    // MARK: Loads

    private var collectionKey: String {
        "\(contentId)|\(TVTMDbStore.shared.contextKey)|\(StudiosNetworksStore.shared.movieLookupRevision)"
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

    private func loadRating() async {
        let store = TVTMDbStore.shared
        let context = store.contextKey
        let rating = try? await store.rating(for: detail)
        guard !Task.isCancelled else { return }
        tmdbRating = rating.map { TMDbRatingResult(contentId: contentId, context: context, value: $0) }
    }
}

/// Play/Pause on the older layout, for episodes only.
private struct TVEpisodePlayPause: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.onPlayPauseCommand(perform: action)
        } else {
            content
        }
    }
}
#endif
