import SwiftUI

#if !os(tvOS)
/// A series' episodes: a carousel for the chosen season, or on wide pages a
/// list, paged sideways by season when there are several.
struct MobileEpisodeBrowser: View {
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    let isLoading: Bool
    let onSelectSeason: (Season) -> Void
    let onSelectEpisode: (EpisodeListItem) -> Void
    var onPlayEpisode: ((EpisodeListItem) -> Void)? = nil
    var currentEpisodeId: String? = nil
    var selectsCentredCard = false
    var allowsSeasonPaging = true
    var forcesCarousel = false
    var captionOverride: CardCaptionStyle? = nil

    @State private var width: CGFloat = 0
    @State private var playerSettings = PlayerSettings.shared

    var body: some View {
        if selectedSeason != nil || !seasons.isEmpty || !episodes.isEmpty || isLoading {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    if abs(newWidth - width) > 1 { width = newWidth }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let isExpanded = !forcesCarousel && width >= 640
        let position = spoilerPosition
        let coveredEpisodes = EpisodeSpoilerPolicy.cover(episodes, after: position)
        if isExpanded, allowsSeasonPaging, seasons.count > 1 {
            MobileSeasonPager(
                seasons: seasons,
                selectedSeason: selectedSeason,
                episodes: coveredEpisodes,
                episodesBySeason: EpisodeSpoilerPolicy.cover(episodesBySeason, after: position),
                isLoading: isLoading,
                width: width,
                currentEpisodeId: currentEpisodeId,
                selectsCentredCard: selectsCentredCard,
                onSelectSeason: onSelectSeason,
                onSelectEpisode: onSelectEpisode
            )
        } else {
            MobileEpisodePage(
                episodes: coveredEpisodes,
                isLoading: isLoading,
                isExpanded: isExpanded,
                currentEpisodeId: currentEpisodeId,
                selectsCentredCard: selectsCentredCard,
                captionOverride: captionOverride,
                onSelect: onSelectEpisode,
                onPlay: onPlayEpisode
            )
        }
    }

    /// Where the viewer is up to, when Hide Episode Spoilers is on.
    private var spoilerPosition: EpisodeSpoilerPolicy.Position? {
        guard playerSettings.hideFutureEpisodeSpoilers else { return nil }
        var pages = episodesBySeason
        if !isLoading, let selectedSeason {
            pages[selectedSeason.seasonNumber] = episodes
        }
        return EpisodeSpoilerPolicy.currentPosition(seasons: seasons, pages: pages)
    }
}

/// Seasons side by side, one page each, swiped like a book. Resting on a
/// page chooses its season.
private struct MobileSeasonPager: View {
    let seasons: [Season]
    let selectedSeason: Season?
    let episodes: [EpisodeListItem]
    let episodesBySeason: [Int: [EpisodeListItem]]
    let isLoading: Bool
    let width: CGFloat
    let currentEpisodeId: String?
    let selectsCentredCard: Bool
    let onSelectSeason: (Season) -> Void
    let onSelectEpisode: (EpisodeListItem) -> Void

    @State private var visibleSeasonId: String?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 96
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(seasons) { season in
                    MobileEpisodePage(
                        episodes: page(for: season),
                        isLoading: isPageLoading(season),
                        isExpanded: true,
                        currentEpisodeId: currentEpisodeId,
                        selectsCentredCard: selectsCentredCard,
                        captionOverride: nil,
                        onSelect: onSelectEpisode,
                        onPlay: nil
                    )
                    .frame(width: width, alignment: .top)
                    .id(season.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $visibleSeasonId)
        .frame(height: estimatedHeight, alignment: .top)
        .clipped()
        .onAppear {
            visibleSeasonId = selectedSeason?.id ?? seasons.first?.id
        }
        .onChange(of: selectedSeason?.id) { _, id in
            guard let id, id != visibleSeasonId else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: VividTheme.normalDuration)) {
                visibleSeasonId = id
            }
        }
        .onScrollPhaseChange { _, phase in
            guard phase == .idle, let visibleSeasonId, visibleSeasonId != selectedSeason?.id,
                  let season = seasons.first(where: { $0.id == visibleSeasonId }) else { return }
            onSelectSeason(season)
        }
    }

    private func isSelected(_ season: Season) -> Bool {
        season.id == selectedSeason?.id
    }

    private func page(for season: Season) -> [EpisodeListItem] {
        if let cached = episodesBySeason[season.seasonNumber] { return cached }
        return isSelected(season) ? episodes : []
    }

    private func isPageLoading(_ season: Season) -> Bool {
        isSelected(season) ? isLoading : episodesBySeason[season.seasonNumber] == nil
    }

    private var estimatedHeight: CGFloat {
        guard let season = seasons.first(where: { $0.id == visibleSeasonId }) else { return 72 }
        let count: Int
        if let cached = episodesBySeason[season.seasonNumber] {
            count = cached.count
        } else if isSelected(season), !episodes.isEmpty {
            count = episodes.count
        } else {
            count = season.episodeCount
        }
        return MobileEpisodeList.estimatedHeight(episodeCount: count, width: width, rowHeight: rowHeight)
    }
}

/// One season's episodes, with skeletons while they load and the last
/// height kept so the page doesn't jump.
private struct MobileEpisodePage: View {
    let episodes: [EpisodeListItem]
    let isLoading: Bool
    let isExpanded: Bool
    let currentEpisodeId: String?
    let selectsCentredCard: Bool
    let captionOverride: CardCaptionStyle?
    let onSelect: (EpisodeListItem) -> Void
    let onPlay: ((EpisodeListItem) -> Void)?

    @State private var measuredHeight: CGFloat = 0
    @State private var settledHeight: CGFloat = 0

    private var isLoadingEmpty: Bool {
        isLoading && episodes.isEmpty
    }

    private var showsSettledEpisodes: Bool {
        !isLoading && !episodes.isEmpty
    }

    var body: some View {
        let keepsHeight = isLoadingEmpty && settledHeight > 0
        content
            .frame(minHeight: keepsHeight ? settledHeight : nil, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                measuredHeight = height
                if showsSettledEpisodes, height > 0 {
                    settledHeight = height
                }
            }
            .onChange(of: showsSettledEpisodes) { _, settled in
                if settled, measuredHeight > 0 {
                    settledHeight = measuredHeight
                }
            }
            .animation(.easeInOut(duration: 0.16), value: isLoadingEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if isLoadingEmpty {
            if isExpanded {
                MobileEpisodeListSkeleton()
            } else {
                MobileEpisodeCarouselSkeleton(captionOverride: captionOverride)
            }
        } else if episodes.isEmpty {
            Text("No episodes available")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } else if isExpanded {
            MobileEpisodeList(episodes: episodes, currentEpisodeId: currentEpisodeId, onSelect: onSelect)
        } else {
            MobileEpisodeCarousel(
                episodes: episodes,
                currentEpisodeId: currentEpisodeId,
                selectsCentredCard: selectsCentredCard,
                captionOverride: captionOverride,
                onSelect: onSelect,
                onPlay: onPlay
            )
        }
    }
}
#endif
