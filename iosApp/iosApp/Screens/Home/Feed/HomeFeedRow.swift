#if !os(tvOS)
import SwiftUI

/// One horizontal rail. Shared by every variant so the differences between
/// layouts stay structural rather than incidental.
struct HomeFeedRow: View {
    let section: ResolvedSection
    var headerStyle: HomeSectionHeader.Style = .standard
    var posterWidth: CGFloat = HomeFeedMetrics.posterWidth
    var cardSpacing: CGFloat = HomeFeedMetrics.cardSpacing
    /// Forces poster shape even for episode-bearing rows.
    var forcesPosters: Bool = false
    /// Long-press actions, forwarded to every card in the row.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var visibleItemId: String?
    @Environment(AppRouter.self) private var router

    private var isResume: Bool { HomeFeed.isResume(section) }

    private var hasEpisodes: Bool {
        section.items.contains { $0.type.lowercased() == "episode" }
    }

    /// Resume rows render as 16:9 stills — showing where you are inside a
    /// runtime is the entire job of the row, and a 2:3 poster can't do it.
    /// "Next Up" is episode-shaped for the same reason.
    private var usesStills: Bool {
        guard !forcesPosters else { return false }
        if isResume { return true }
        return section.sectionType.lowercased().contains("next") && hasEpisodes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(
                title: section.title,
                icon: nil,
                style: headerStyle
            )

            rowScroller
        }
    }

    @ViewBuilder
    private var rowScroller: some View {
        cardsScroll
            .scrollTargetBehavior(HorizontalMediaRailLayout.targetBehavior)
            .scrollPosition(id: $visibleItemId, anchor: HorizontalMediaRailLayout.scrollAnchor)
            .environment(\.itemDetailBrowseSource, detailBrowseSource)
            .onAppear {
                let initialId = validSelectionId(
                    preferred: visibleItemId ?? section.items.first?.contentId
                )
                visibleItemId = initialId
            }
            .onChange(of: section.items.map(\.contentId)) { _, newIds in
                let preferred = newIds.contains(visibleItemId ?? "")
                    ? visibleItemId
                    : newIds.first
                visibleItemId = preferred
            }
            #if os(iOS)
            .onChange(of: router.presentedItemDetail) { _, presentation in
                // Only iPad's horizontally paged detail deck drives its source
                // row. An iPhone detail opens in place; scrolling the row while
                // its zoom transition is restoring it creates a visible drift.
                guard !HorizontalMediaRailLayout.isPhone,
                      presentation?.browseSource?.originID == detailBrowseSource.originID,
                      let contentID = presentation?.contentId,
                      section.items.contains(where: { $0.contentId == contentID })
                else { return }

                withAnimation(.easeInOut(duration: 0.28)) {
                    visibleItemId = contentID
                }
            }
            #endif
    }

    private var cardsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: cardSpacing) {
                ForEach(section.items) { item in
                    Group {
                        if usesStills {
                            HomeStillCard(
                                item: item,
                                width: HomeFeedMetrics.stillWidth
                                    * homeCards.presentation.posterSize.scale,
                                showsCaption: homeCards.presentation.caption.showsTitle,
                                showsMetadata: homeCards.presentation.caption.showsMetadata,
                                showsEpisodeDetails: MediaServerProvider.active == .emby
                                    && section.sectionType.lowercased().contains("next"),
                                opensResumeContext: isResume || (MediaServerProvider.active == .emby && section.sectionType.lowercased().contains("next")),
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        } else {
                            HomePosterCard(
                                item: item,
                                width: posterWidth * homeCards.presentation.posterSize.scale,
                                showsCaption: homeCards.presentation.caption.showsTitle,
                                showsMetadata: homeCards.presentation.caption.showsMetadata,
                                showsProgress: isResume,
                                opensResumeContext: isResume || (MediaServerProvider.active == .emby && section.sectionType.lowercased().contains("next")),
                                episodeAccessibilityLabel: episodeAccessibilityLabel(for: item),
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        }
                    }
                    .id(item.contentId)
                }
            }
            .scrollTargetLayout()
            .phoneMediaRailBounds()
        }
        .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var detailBrowseSource: ItemDetailBrowseSource {
        ItemDetailBrowseSource(
            originID: "home:\(section.id)",
            contentIDs: section.items.map(\.contentId)
        )
    }

    private func validSelectionId(preferred: String?) -> String? {
        guard let preferred,
              section.items.contains(where: { $0.contentId == preferred }) else {
            return section.items.first?.contentId
        }
        return preferred
    }

    /// Episode context for accessibility when episode-discovery cards are
    /// visually captioned with their series name.
    private func episodeAccessibilityLabel(for item: SectionItem) -> String? {
        EpisodeCardCaption.accessibilityLabel(for: item)
    }

    /// Removal is only offered where it means something — a resume row.
    private func removalAction(for item: SectionItem) -> (() -> Void)? {
        guard isResume, let onRemoveFromContinueWatching else { return nil }
        return { onRemoveFromContinueWatching(item) }
    }

    private func watchedAction(for item: SectionItem) -> ((Bool) async -> Bool)? {
        guard let onSetWatched else { return nil }
        return { played in await onSetWatched(item, played) }
    }
}
#endif
