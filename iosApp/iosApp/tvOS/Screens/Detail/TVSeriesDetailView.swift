#if os(tvOS)
import SwiftUI

/// Apple-sample detail presentation with one continuous native episode shelf.
struct TVSeriesDetailView<BelowSynopsis: View>: View {
    let detail: ItemDetail
    let isFavorite: Bool
    let inWatchlist: Bool
    let isWatched: Bool
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    let activeEpisodeContentId: String?
    let resumeEpisode: EpisodeListItem?
    let episodeFavoriteStates: [String: Bool]
    let isLoadingEpisodes: Bool
    let selectedNextUpFileId: Int?
    let selectedNextUpAudioTrackIndex: Int?
    let selectedNextUpSubtitleTrackIndex: Int?
    let nextUpPlaybackDetail: ItemDetail?
    let isLoadingNextUpPlaybackDetail: Bool
    let didLoadNextUpPlaybackDetail: Bool
    var nextUpSubtitleOverrideCleared = false
    let trailerEntries: [TrailerRailEntry]
    let onSelectTrailer: (TrailerRailEntry) -> Void
    let supportsTrailerFetch: Bool
    let onFindTrailers: () -> Void
    let trailerFetchStatus: String?
    let isFetchingTrailers: Bool
    let onTrailerStatusShown: () -> Void
    let onSelectSeason: (Season) -> Void
    /// Playback selection is independent of rail focus.
    let onActivateEpisode: (_ contentId: String) -> Void
    let onPlayEpisode: (_ contentId: String, _ fileId: Int?, _ startFromBeginning: Bool) -> Void
    let onSetEpisodeWatched: (_ contentId: String, _ played: Bool) async -> Bool
    let onSetEpisodeFavorite: (_ contentId: String, _ isFavorite: Bool) async -> Bool
    let onSelectNextUpVersion: (Int?) -> Void
    let onSelectNextUpAudioTrack: (Int?) -> Void
    let onSelectNextUpSubtitleTrack: (Int?) -> Void
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void
    let onToggleWatched: () -> Void
    let onToggleSeasonWatched: () -> Void
    let onPersonTap: (String) -> Void
    let onNavigateToItem: (String) -> Void
    @ViewBuilder let belowSynopsis: () -> BelowSynopsis


    @Namespace private var detailFocusNamespace
    @State private var didEstablishPlayFocus = false
    @FocusState private var playFocused: Bool
    @FocusState private var showActionRowFocused: Bool
    @State private var isShowingSeriesOverview = true
    @ObservedObject private var profilePrefsStore = ProfilePrefsStore.shared

    var body: some View {
        TVAppleDetailPage(backdropURL: detail.backdropUrl, backdropThumbhash: detail.backdropThumbhash, logoURL: detail.logoUrl, title: detail.title) { height in
            heroView(height: height)
        } shelves: {
            VStack(alignment: .leading, spacing: TVDetailLayout.bodySectionSpacing) {
                TVContinuousEpisodeShelf(seasons: seasons, pages: continuousPages,
                    selectedSeason: selectedSeason, currentContentId: activeEpisodeContentId,
                    heroEntryEpisode: showActionRowFocused ? playbackEpisode : nil,
                    favorites: episodeFavoriteStates, onSeason: onSelectSeason,
                    onFocus: { _ in
                        isShowingSeriesOverview = false
                    }, onPlay: { episode in
                        onActivateEpisode(episode.contentId)
                        onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
                    }, onWatched: onSetEpisodeWatched, onFavorite: onSetEpisodeFavorite)
                trailersSection
                if let cast = detail.cast, !cast.isEmpty { castSection(cast: cast) }
                similarSection
                detailsSection
            }
        }
        .focusScope(detailFocusNamespace)
        .defaultFocus($playFocused, true, priority: .userInitiated)
        .onChange(of: playFocused) { _, focused in
            if focused { didEstablishPlayFocus = true }
        }
        .onChange(of: showActionRowFocused) { _, focused in
            // An empty series has no Play target. Unlock the synopsis after
            // another action receives focus, without exposing it during entry.
            if focused && playbackEpisode == nil { didEstablishPlayFocus = true }
        }
        .onAppear { isShowingSeriesOverview = activeEpisodeContentId == nil }
    }

    private var continuousPages: [Int: [EpisodeListItem]] {
        var pages = episodesBySeason
        if let selectedSeason, !isLoadingEpisodes { pages[selectedSeason.seasonNumber] = episodes }
        return pages
    }

    private func heroView(height: CGFloat) -> some View {
        TVDetailHero(
            title: detail.title,
            seriesTitle: nil,
            logoUrl: detail.logoUrl,
            backdropUrl: detail.backdropUrl,
            backdropThumbhash: detail.backdropThumbhash,
            eyebrow: nil,
            sourceTokens: heroSourceTokens,
            ratingChip: TVHeroMetadata.contentRatingChip(from: detail),
            overview: heroOverview,
            factsLine: heroFactsLine,
            starringText: TVHeroMetadata.starringText(from: detail),
            playbackSummary: TVPlaybackSelectionSummary.make(
                currentVersion: effectiveNextUpVersion,
                selectedVersionFileId: selectedNextUpFileId,
                selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                subtitleMode: nextUpSubtitleOverrideCleared
                    ? nil
                    : matchingPlaybackDetail?.effectiveSubtitleMode,
                subtitleContext: matchingPlaybackDetail.map(Self.subtitleContext(for:))
            ),
            usesCompactMetadata: true,
            allowsSynopsisFocus: didEstablishPlayFocus,
            qualityVersion: effectiveNextUpVersion,
            qualitySummary: selectedNextUpFileId == nil ? (matchingPlaybackDetail?.overlaySummary ?? detail.overlaySummary) : nil,
            metadataHeading: ["Series"] + heroFactsLine.compactMap { token in
                guard case .text(let value) = token, value != detail.year.map(String.init) else { return nil }
                return value
            },
            releaseFacts: TVHeroMetadata.releaseFacts(year: detail.year, runtime: playbackEpisode?.runtime ?? detail.runtime),
            backdropHeight: TVDetailLayout.heroHeight,
            heroHeight: height,
            heroTopInset: TVDetailLayout.browsingHeroTopInset(for: height),
            editorialContentWidth: TVDetailLayout.heroContentWidth,
            editorialReservedHeight: TVDetailLayout.editorialHeight,
            metadataReservedHeight: 36,
            synopsisReservedHeight: 112,
            creditReservedHeight: 28,
            actionSpacing: TVDetailLayout.disclosureSpacing,
            usesFixedPageArtwork: true,
            extendsBackdropFadeBelowHero: true,
            actions: {
                showActionRow
            },
            belowSynopsis: {
                if isShowingSeriesOverview {
                    belowSynopsis()
                }
            }
        )
    }

    private var heroOverview: String? { detail.overview }

    private var heroSourceTokens: [String] {
        TVHeroMetadata.seriesSourceTokens(from: detail)
    }

    private var heroFactsLine: [TVHeroFactToken] {
        let regularSeasons = seasons.filter { $0.seasonNumber > 0 }
        let seasonCount = regularSeasons.isEmpty ? detail.seasonCount : regularSeasons.count
        guard seasonCount == 1 else { return TVHeroMetadata.seriesFactsLine(from: detail) }
        var facts: [TVHeroFactToken] = []
        if let year = detail.year, year > 0 { facts.append(.text(String(year))) }
        let seasonNumber = regularSeasons.first?.seasonNumber ?? 1
        let loaded = episodesBySeason[seasonNumber]
            ?? (selectedSeason?.seasonNumber == seasonNumber && !isLoadingEpisodes ? episodes : nil)
        if let loaded {
            let count = TVHeroMetadata.releasedEpisodeCount(loaded)
            facts.append(.text("\(count) Episode\(count == 1 ? "" : "s")"))
        } else {
            facts.append(.text("Episodes"))
        }
        return facts
    }

    private var showActionRow: some View {
        TVDetailActionRow(
            playTitle: playbackEpisode.map(showPlayTitle(for:)),
            playSubtitle: nil,
            resumeProgress: ResumePresentation(position: playbackEpisode?.userData?.positionSeconds, duration: playbackEpisode?.userData?.durationSeconds, episodeLabel: playbackEpisode.map { "S\($0.seasonNumber) E\($0.episodeNumber)" }),
            onPlay: {
                guard let episode = playbackEpisode else { return }
                onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
            },
            onStartOver: nil,
            inWatchlist: inWatchlist,
            onToggleWatchlist: onToggleWatchlist,
            focusResetKey: detail.contentId,
            initialFocusScope: .page,
            focusNamespace: detailFocusNamespace,
            playFocused: $playFocused,
            rowFocused: $showActionRowFocused,
            stabilizesFocusMotion: true,
            primaryButtonWidth: 280,
            onResumeStartOver: ResumePresentation(position: playbackEpisode?.userData?.positionSeconds, duration: playbackEpisode?.userData?.durationSeconds) != nil ? {
                guard let episode = playbackEpisode else { return }
                onPlayEpisode(episode.contentId, selectedFileId(for: episode), true)
            } : nil,
            playbackSelectors: {
                // Keep both track triggers mounted while a newly focused
                // episode's playback detail loads. They disable themselves
                // until a valid version arrives, preserving every x-position.
                TVPlaybackActionSelectors(
                    versions: nextUpVersions,
                    currentVersion: effectiveNextUpVersion,
                    selectedVersionFileId: selectedNextUpFileId,
                    selectedAudioTrackIndex: selectedNextUpAudioTrackIndex,
                    selectedSubtitleTrackIndex: selectedNextUpSubtitleTrackIndex,
                    subtitleMode: nextUpSubtitleOverrideCleared
                        ? nil
                        : matchingPlaybackDetail?.effectiveSubtitleMode,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack,
                    subtitleContext: matchingPlaybackDetail.map(Self.subtitleContext(for:))
                )
            },
            moreMenu: { moreMenu }
        )
    }

    private func showPlayTitle(for episode: EpisodeListItem) -> String {
        let verb = episode.userData?.isInProgress == true ? "Resume" : "Play"
        return "\(verb) S\(episode.seasonNumber):E\(episode.episodeNumber)"
    }

    private static func subtitleContext(for item: ItemDetail) -> OpenSubtitlePlaybackContext {
        .init(contentID: item.contentId, generation: 0,
              query: .init(title: item.type == "episode" ? (item.seriesTitle ?? item.title) : item.title,
                           type: item.type, season: item.seasonNumber, episode: item.episodeNumber))
    }

    private var moreMenu: some View {
        TVCircleMenuButton(
            icon: "ellipsis",
            title: "More",
            accessibilityLabel: "More options",
            stabilizesFocusMotion: true
        ) {
            TVDetailVersionMenu(versions: nextUpVersions, selectedFileId: selectedNextUpFileId, onSelect: onSelectNextUpVersion)
            if let episode = playbackEpisode, episode.userData?.isInProgress == true {
                Button {
                    onPlayEpisode(episode.contentId, selectedFileId(for: episode), true)
                } label: {
                    Label("Start Over", systemImage: "backward.end.fill")
                }
            }
            if supportsTrailerFetch {
                Button(action: onFindTrailers) {
                    Label("Find Trailers", systemImage: "film.stack")
                }
            }
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.fill" : "heart"
                )
            }
            if let episode = playbackEpisode {
                Button {
                    Task { await onSetEpisodeWatched(episode.contentId, episode.userData?.played != true) }
                } label: {
                    Label(
                        episode.userData?.played == true ? "Mark Episode Unwatched" : "Mark Episode Watched",
                        systemImage: episode.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
            }
            if let selectedSeason {
                Button(action: onToggleSeasonWatched) {
                    Label(
                        selectedSeason.userData?.played == true ? "Mark Season Unwatched" : "Mark Season Watched",
                        systemImage: selectedSeason.userData?.played == true ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }
            }
            Button(action: onToggleWatched) {
                Label(isWatched ? "Mark Series Unwatched" : "Mark Series Watched",
                      systemImage: isWatched ? "checkmark.circle.fill" : "checkmark.circle")
            }
        }
    }

    private var playbackEpisode: EpisodeListItem? {
        resumeEpisode
    }

    private var matchingPlaybackDetail: ItemDetail? {
        guard let playbackEpisode else { return nil }
        if nextUpPlaybackDetail?.contentId == playbackEpisode.contentId {
            return nextUpPlaybackDetail
        }
        return ResponseCache.shared.get(CacheKey.itemDetail(playbackEpisode.contentId))
    }

    private var nextUpVersions: [FileVersion] {
        if let versions = matchingPlaybackDetail?.versions, !versions.isEmpty { return versions }
        guard let playbackEpisode else { return [] }
        let cachedWatch: WatchDetail? = ResponseCache.shared.get(CacheKey.itemWatchDetail(playbackEpisode.contentId))
        return cachedWatch?.versions ?? []
    }

    private var effectiveNextUpVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: nextUpVersions,
            selectedFileId: selectedNextUpFileId,
            lastFileId: matchingPlaybackDetail?.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private func selectedFileId(for episode: EpisodeListItem) -> Int? {
        // Never carry a file choice from the previously focused episode into
        // a quick Play that arrives before the new playback detail is ready.
        guard matchingPlaybackDetail?.contentId == episode.contentId,
              let selectedNextUpFileId else { return nil }
        return nextUpVersions.contains(where: { $0.fileId == selectedNextUpFileId })
            ? selectedNextUpFileId
            : nil
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Media Information")
            if isLoadingNextUpPlaybackDetail {
                ProgressView()
            } else {
                DetailMediaSection(version: effectiveNextUpVersion)
            }
        }
    }

    private var similarSection: some View {
        TVSimilarRail(contentId: detail.contentId, title: "More Like This",
                      sourceDetail: detail, onSelect: onNavigateToItem)
    }

    private var trailersSection: some View {
        TVTrailersRail(entries: trailerEntries, onSelect: onSelectTrailer)
    }

    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }
}
#endif
