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
    @FocusState private var playFocused: Bool
    @FocusState private var showActionRowFocused: Bool
    @State private var isShowingSeriesOverview = true
    @State private var focusedEpisodeContentId: String?
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
                    onFocus: { episode in
                        focusedEpisodeContentId = episode.contentId
                        isShowingSeriesOverview = false
                    }, onPlay: { episode in
                        onActivateEpisode(episode.contentId)
                        onPlayEpisode(episode.contentId, selectedFileId(for: episode), false)
                    }, onWatched: onSetEpisodeWatched, onFavorite: onSetEpisodeFavorite)
                trailersSection
                similarSection
                if let cast = detail.cast, !cast.isEmpty { castSection(cast: cast) }
                detailsSection
            }
        }
        .focusScope(detailFocusNamespace)
        .defaultFocus($playFocused, true, priority: .userInitiated)
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
                subtitleSignature: nextUpSubtitleOverrideCleared
                    ? nil
                    : matchingPlaybackDetail?.effectiveSubtitleTrackSignature,
                preferredSubtitleLanguage: profilePrefsStore.preferredSubtitleLanguage,
                showForcedSubtitles: matchingPlaybackDetail?.effectiveShowForcedSubtitles ?? false
            ),
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
        guard !isShowingSeriesOverview, let episode = displayedEpisode else {
            return TVHeroMetadata.seriesSourceTokens(from: detail)
        }
        let season = episode.seasonNumber == 0 ? "Specials" : "Season \(episode.seasonNumber)"
        return [season, "Episode \(episode.episodeNumber)"]
    }

    private var heroFactsLine: [TVHeroFactToken] {
        guard !isShowingSeriesOverview, let episode = displayedEpisode else {
            return TVHeroMetadata.seriesFactsLine(from: detail)
        }
        var facts: [TVHeroFactToken] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            facts.append(.text(airDate))
        }
        if let runtime = episode.runtime, runtime > 0 {
            facts.append(.text(runtimeLabel(runtime)))
        }
        return facts
    }

    private var showActionRow: some View {
        TVDetailActionRow(
            playTitle: playbackEpisode.map(showPlayTitle(for:)),
            playSubtitle: nil,
            resumeProgress: ResumePresentation(position: playbackEpisode?.userData?.positionSeconds, duration: playbackEpisode?.userData?.durationSeconds),
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
                    subtitleSignature: nextUpSubtitleOverrideCleared
                        ? nil
                        : matchingPlaybackDetail?.effectiveSubtitleTrackSignature,
                    showForcedSubtitles: matchingPlaybackDetail?.effectiveShowForcedSubtitles
                        ?? false,
                    onSelectVersion: onSelectNextUpVersion,
                    onSelectAudioTrack: onSelectNextUpAudioTrack,
                    onSelectSubtitleTrack: onSelectNextUpSubtitleTrack
                )
            },
            moreMenu: { moreMenu }
        )
    }

    private func showPlayTitle(for episode: EpisodeListItem) -> String {
        let verb = episode.userData?.isInProgress == true ? "Resume" : "Play"
        return "\(verb) S\(episode.seasonNumber):E\(episode.episodeNumber)"
    }

    private var moreMenu: some View {
        TVCircleMenuButton(
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
                Label(isWatched ? "Mark Series Unwatched" : "Mark Series Watched", systemImage: "checkmark.circle")
            }
        }
    }

    private var suggestedEpisode: EpisodeListItem? {
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }

    private var displayedEpisode: EpisodeListItem? {
        if let focusedEpisodeContentId {
            return continuousPages.values.lazy.flatMap { $0 }.first { $0.contentId == focusedEpisodeContentId }
        }
        return suggestedEpisode
    }

    private var playbackEpisode: EpisodeListItem? {
        resumeEpisode
    }

    private var matchingPlaybackDetail: ItemDetail? {
        guard let playbackEpisode,
              nextUpPlaybackDetail?.contentId == playbackEpisode.contentId else {
            return nil
        }
        return nextUpPlaybackDetail
    }

    private var nextUpVersions: [FileVersion] {
        matchingPlaybackDetail?.versions ?? []
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

    private func runtimeLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
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
        TVTrailersRail(entries: trailerEntries, onSelect: onSelectTrailer, focusScale: TVMediaFocus.scale)
    }

    private func castSection(cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
            TVSectionHeader(title: "Cast & Crew")
            TVDetailCastRail(cast: cast, onTap: onPersonTap)
        }
    }
}
#endif
