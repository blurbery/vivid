#if os(tvOS)
import SwiftUI

/// One server row on Apple TV Home, drawn as a collection row. Continue
/// Watching episodes open their series at the episode.
struct SectionRow: View {
    let section: ResolvedSection
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    let onRemoveFromContinueWatching: ((SectionItem) -> Void)?
    let onSetWatched: ((SectionItem, Bool) async -> Bool)?
    let focusRequest: Int
    let defaultFocusItemId: String?
    let focusRequestItemId: String?
    let detailReturnFocusRequest: Int
    let onMoveUp: (() -> Void)?
    let onItemFocus: ((SectionItem) -> Void)?
    let cardWidth: CGFloat?
    let homeRowIndex: Int?
    let focusRestorationOwner: Binding<Bool>?
    let isSpotlightHandoffPending: (() -> Bool)?

    @Environment(AppRouter.self) private var router

    /// `showsHeadingIcon`, `prefersDefaultFocusOnFirstItem` and
    /// `defaultFocusPriority` are accepted for the feed's sake and unused.
    init(
        section: ResolvedSection,
        onItemTap: @escaping (_ destinationContentId: String, _ item: SectionItem) -> Void,
        onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil,
        onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil,
        showsHeadingIcon: Bool = true,
        prefersDefaultFocusOnFirstItem: Bool = false,
        defaultFocusPriority: DefaultFocusEvaluationPriority = .userInitiated,
        focusRequest: Int = 0,
        defaultFocusItemId: String? = nil,
        focusRequestItemId: String? = nil,
        detailReturnFocusRequest: Int = 0,
        onMoveUp: (() -> Void)? = nil,
        onItemFocus: ((SectionItem) -> Void)? = nil,
        cardWidth: CGFloat? = nil,
        homeRowIndex: Int? = nil,
        focusRestorationOwner: Binding<Bool>? = nil,
        isSpotlightHandoffPending: (() -> Bool)? = nil
    ) {
        self.section = section
        self.onItemTap = onItemTap
        self.onRemoveFromContinueWatching = onRemoveFromContinueWatching
        self.onSetWatched = onSetWatched
        self.focusRequest = focusRequest
        self.defaultFocusItemId = defaultFocusItemId
        self.focusRequestItemId = focusRequestItemId
        self.detailReturnFocusRequest = detailReturnFocusRequest
        self.onMoveUp = onMoveUp
        self.onItemFocus = onItemFocus
        self.cardWidth = cardWidth
        self.homeRowIndex = homeRowIndex
        self.focusRestorationOwner = focusRestorationOwner
        self.isSpotlightHandoffPending = isSpotlightHandoffPending
    }

    var body: some View {
        VividCollectionMediaRow(
            section: section,
            onSelect: select,
            onPlay: play,
            onSetWatched: setWatched,
            onRemove: section.isContinueWatchingSection ? onRemoveFromContinueWatching : nil,
            onSeeAll: nil,
            onItemFocus: onItemFocus,
            onMoveUp: onMoveUp,
            focusRequest: focusRequest,
            detailReturnFocusRequest: detailReturnFocusRequest,
            rememberedItemID: focusRequestItemId ?? defaultFocusItemId,
            ownsReturnFocus: focusRestorationOwner,
            posterWidth: cardWidth ?? VividTheme.posterCardWidth,
            rowIndex: homeRowIndex,
            isSpotlightHandoffPending: isSpotlightHandoffPending
        )
        .equatable()
    }

    private func setWatched(_ item: SectionItem, _ played: Bool) async -> Bool {
        guard let onSetWatched else { return false }
        return await onSetWatched(item, played)
    }

    private func play(_ item: SectionItem) {
        router.presentPlayer(
            contentId: item.contentId,
            resumePosition: item.positionSeconds,
            prefersLastUsedVersion: section.isContinueWatchingSection,
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
    }

    private func select(_ contentId: String) {
        guard let item = section.items.first(where: { $0.contentId == contentId }) else { return }
        guard section.isContinueWatchingSection else {
            onItemTap(contentId, item)
            return
        }
        let isEpisode = item.type.lowercased() == "episode" || item.episodeNumber != nil
        let seriesId = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isEpisode, !seriesId.isEmpty, let season = item.seasonNumber {
            TVSeriesDetailNavigationContextStore.stage(
                seriesContentId: seriesId,
                seasonNumber: season,
                episodeContentId: item.contentId
            )
            onItemTap(seriesId, item)
        } else {
            onItemTap(item.contentId, item)
        }
    }
}
#endif
