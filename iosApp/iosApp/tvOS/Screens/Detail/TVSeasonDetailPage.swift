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
                        let facts = TVDetailFactsBlock.facts(for: detail)
                        if !facts.isEmpty {
                            TVDetailSection(title: "Details", spacing: Self.sectionSpacing) {
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

    /// The file Play starts: the pick, else the entry page's choice for the
    /// next-up episode, so the selectors and summary describe what plays.
    private var currentVersion: FileVersion? {
        TVDetailPlaybackRules.effectiveVersion(of: nextUp.detail, filePick: picks.fileId)
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

// MARK: - Details facts

/// The season page's credits and dates in one glass panel.
struct TVDetailFactsBlock: View {
    struct Fact: Identifiable {
        /// A stable English identity, so labels that translate alike never
        /// collide.
        let id: String
        let label: String
        let value: String
    }

    let facts: [Fact]

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: fact.label)
                        .textCase(.uppercase)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color.white.opacity(0.55))
                    Text(verbatim: fact.value)
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 22)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 28)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vividGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: Color.white.opacity(isFocused ? 0.12 : 0.03)
        )
        .focusEffectDisabled()
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

    /// The facts for a season page, in display order, each only when known.
    static func facts(for detail: ItemDetail) -> [Fact] {
        let crew = detail.crew ?? []
        var facts: [Fact] = []

        let directors = crew.filter { ($0.job ?? "").lowercased() == "director" }.map(\.name)
        if let names = creditNames(directors) {
            facts.append(Fact(id: "Director", label: String(localized: "Director"), value: names))
        }

        let writerJobs: Set<String> = ["writer", "screenplay", "story"]
        let writers = crew.filter { writerJobs.contains(($0.job ?? "").lowercased()) }.map(\.name)
        if let names = creditNames(writers) {
            let hasScreenplay = crew.contains { ($0.job ?? "").lowercased() == "screenplay" }
            let label = hasScreenplay ? String(localized: "Writer") : String(localized: "Written by")
            facts.append(Fact(id: "Writer", label: label, value: names))
        }

        let lists: [(String, String, [String]?)] = [
            ("Studio", String(localized: "Studio"), detail.studios),
            ("Network", String(localized: "Network"), detail.networks),
            ("Country", String(localized: "Country"), detail.countries)
        ]
        for (id, label, values) in lists {
            let first = (values ?? []).prefix(3)
            if !first.isEmpty {
                facts.append(Fact(id: id, label: label, value: first.joined(separator: ", ")))
            }
        }

        let dates: [(String, String, String?)] = [
            ("Aired", String(localized: "Aired"), detail.airDate),
            ("Released", String(localized: "Released"), detail.releaseDate),
            ("First Aired", String(localized: "First Aired"), detail.firstAirDate),
            ("Last Aired", String(localized: "Last Aired"), detail.lastAirDate)
        ]
        for (id, label, raw) in dates {
            if let date = DetailDateFormatting.longDate(raw) {
                facts.append(Fact(id: id, label: label, value: date))
            }
        }
        return facts
    }

    /// Distinct names in plain string order, at most three, with an ellipsis
    /// when there are more.
    private static func creditNames(_ names: [String]) -> String? {
        let distinct = Array(Set(names)).sorted()
        let shown = distinct.prefix(3).joined(separator: ", ")
        // No names, or only empty ones, leave the fact out.
        guard !shown.isEmpty else { return nil }
        return distinct.count > 3 ? shown + ", \u{2026}" : shown
    }
}
#endif
