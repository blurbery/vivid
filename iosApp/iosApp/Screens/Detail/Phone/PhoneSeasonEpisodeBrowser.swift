#if !os(tvOS)
import SwiftUI

/// Shared season and episode browser for series, season, and episode detail.
/// It follows the real detail-column width: compact containers retain the
/// phone carousel, while regular-width panes use readable episode rows.
struct PhoneSeasonEpisodeBrowser: View {
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    let isLoadingEpisodes: Bool
    let onSelectSeason: (Season) -> Void
    let onSelectEpisode: (String) -> Void
    var onPlayEpisode: ((String) -> Void)? = nil
    var currentContentId: String? = nil
    var selectsCenteredEpisode = false
    /// Some detail layouts place the selector before their Episodes heading
    /// to match tvOS. They render the shared chips themselves and suppress the
    /// browser's internal copy with this flag.
    var showsSeasonSelector = true
    /// The redesigned series overview always uses the same horizontal episode
    /// carousel on iPhone and iPad. Keeping one fixed-height presentation is
    /// what lets season skeletons replace it without moving the page.
    var forcesEpisodeCarousel = false
    /// Detail-specific override used when episode identity must remain attached
    /// to its artwork regardless of the global library-card caption setting.
    var episodeCaptionStyleOverride: CardCaptionStyle? = nil
    /// Series and episode pages browse seasons in place. A dedicated season
    /// page instead navigates when a chip is picked, so horizontal paging is
    /// intentionally disabled there to keep its hero identity coherent.
    var allowsSeasonPaging = true

    @State private var availableWidth: CGFloat = 0

    private var usesExpandedList: Bool {
        !forcesEpisodeCarousel && availableWidth >= 640
    }

    @State private var playerSettings = PlayerSettings.shared

    /// The viewer's current position when Hide Episode Spoilers is on; the
    /// selected season's live list counts as a loaded page.
    private var spoilerPosition: EpisodeSpoilerPolicy.Position? {
        guard playerSettings.hideFutureEpisodeSpoilers else { return nil }
        var pages = episodesBySeason
        if let selectedSeason, !isLoadingEpisodes { pages[selectedSeason.seasonNumber] = episodes }
        return EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
    }

    var body: some View {
        let position = spoilerPosition
        let shownEpisodes = EpisodeSpoilerPolicy.cover(episodes, after: position)
        let shownEpisodesBySeason = EpisodeSpoilerPolicy.cover(episodesBySeason, after: position)
        Group {
            if selectedSeason == nil,
               seasons.isEmpty,
               episodes.isEmpty,
               !isLoadingEpisodes {
                EmptyView()
            } else if usesExpandedList, allowsSeasonPaging, seasons.count > 1 {
                PhoneSeasonEpisodePager(
                    seasons: seasons,
                    selectedSeason: selectedSeason,
                    episodes: shownEpisodes,
                    episodesBySeason: shownEpisodesBySeason,
                    isLoadingEpisodes: isLoadingEpisodes,
                    onSelectSeason: onSelectSeason,
                    onSelectEpisode: onSelectEpisode,
                    onPlayEpisode: onPlayEpisode,
                    currentContentId: currentContentId,
                    selectsCenteredEpisode: selectsCenteredEpisode,
                    showsSeasonSelector: showsSeasonSelector,
                    availableWidth: availableWidth
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if showsSeasonSelector, seasons.count > 1 {
                        PhoneSeasonChips(
                            seasons: seasons,
                            selected: selectedSeason,
                            onSelect: onSelectSeason
                        )
                    }

                    PhoneEpisodePage(
                        episodes: shownEpisodes,
                        isLoading: isLoadingEpisodes,
                        usesExpandedList: usesExpandedList,
                        onSelect: onSelectEpisode,
                        onPlay: onPlayEpisode,
                        currentContentId: currentContentId,
                        selectsCenteredEpisode: selectsCenteredEpisode,
                        captionStyleOverride: episodeCaptionStyleOverride
                    )
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - availableWidth) > 1 else { return }
            availableWidth = width
        }
    }
}
#endif
