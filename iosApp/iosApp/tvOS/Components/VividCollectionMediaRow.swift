#if os(tvOS)
import CollectionHStack
import Combine
import SwiftUI

struct VividCollectionMediaRow: View, Equatable {
    let section: ResolvedSection
    let onSelect: (String) -> Void
    let onPlay: (SectionItem) -> Void
    let onSetWatched: (SectionItem, Bool) async -> Bool
    var onRemove: ((SectionItem) -> Void)?
    var onSeeAll: (() -> Void)?
    var onItemFocus: ((SectionItem) -> Void)?
    var onMoveUp: (() -> Void)?
    var focusRequest = 0
    var detailReturnFocusRequest = 0
    var rememberedItemID: String?
    var ownsReturnFocus: Binding<Bool>?
    var posterWidth = VividTheme.Skyline.densePosterCardWidth
    var rowIndex: Int? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section
            && lhs.focusRequest == rhs.focusRequest
            && lhs.detailReturnFocusRequest == rhs.detailReturnFocusRequest
            && lhs.posterWidth == rhs.posterWidth
            && lhs.rowIndex == rhs.rowIndex
            && (lhs.onSeeAll == nil) == (rhs.onSeeAll == nil)
            && (lhs.onRemove == nil) == (rhs.onRemove == nil)
            && (lhs.onMoveUp == nil) == (rhs.onMoveUp == nil)
            && (lhs.onItemFocus == nil) == (rhs.onItemFocus == nil)
            && (lhs.ownsReturnFocus == nil) == (rhs.ownsReturnFocus == nil)
    }

    // Remembered IDs are consumed only by explicit entry/detail request tokens
    // or section changes, all compared above. Comparing passive memory here
    // would refresh every visited row when Spotlight re-renders the feed.


    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    @Environment(\.homeCardPresentation) private var presentation
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    @Environment(\.tvHomeRowArtworkGate) private var artworkGate
    @StateObject private var proxy = CollectionHStackProxy()
    @StateObject private var focus = CollectionRowFocus()
    @State private var appliedEntry = 0
    @State private var appliedReturn = 0

    var body: some View {
        VStack(alignment: .leading, spacing: TVHomeRowGeometry.headingSpacing) {
            HStack {
                Text(section.title)
                    .font(.system(size: 36, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let onSeeAll { Button("See All", action: onSeeAll) }
            }
            .frame(height: TVHomeRowGeometry.headingHeight)
            .padding(.horizontal, VividTheme.safePadding)

            CollectionHStack(uniqueElements: section.items, layout: .selfSizingSameSize(rows: 1)) { item in
                CollectionMediaCell(itemID: item.contentId, coordinator: focus,
                                    onFocus: { onItemFocus?(item) }) { binding in
                    card(item, focus: binding)
                }
                .environmentObject(overlayStore)
                .environment(\.homeCardPresentation, presentation)
                .environment(\.tvHomeStableRows, true)
                .environment(\.tvArtworkLoadingEnabled, artworkLoadingEnabled)
                .environment(\.tvHomeRowArtworkGate, artworkGate)
            }
            .proxy(proxy)
            .clipsToBounds(false)
            .insets(horizontal: VividTheme.safePadding, vertical: TVHomeRowGeometry.cardPadding)
            .itemSpacing(40)
            .scrollBehavior(.continuousLeadingEdge)
        }
        .focusSection()
        .onChange(of: focusRequest, initial: true) { _, request in
            guard request > appliedEntry else { return }
            appliedEntry = request
            restore(rememberedItemID)
        }
        .onChange(of: detailReturnFocusRequest, initial: true) { _, request in
            guard request > appliedReturn else { return }
            appliedReturn = request
            guard ownsReturnFocus?.wrappedValue == true else { return }
            restore(focus.lastItemID ?? rememberedItemID)
        }
        .onChange(of: section.items.map(\.contentId)) { oldIDs, newIDs in
            guard ownsReturnFocus?.wrappedValue == true,
                  let removed = focus.lastItemID ?? rememberedItemID,
                  let index = oldIDs.firstIndex(of: removed),
                  !newIDs.contains(removed), !newIDs.isEmpty else { return }
            restore(newIDs[min(index, newIDs.count - 1)])
        }
        .modifier(CollectionRowUpperBoundary(onMoveUp: onMoveUp))
    }

    @ViewBuilder
    private func card(_ item: SectionItem, focus: FocusState<String?>.Binding) -> some View {
        let playable = VividMediaType.isDirectlyPlayable(item.type)
        let play: (() -> Void)? = playable ? { onPlay(item) } : nil
        let remove: (() -> Void)? = onRemove.map { action in { action(item) } }
        let playTitle: String? = section.isContinueWatchingSection && playable
            ? ((item.positionSeconds ?? 0) > 0 ? "Resume" : "Play") : nil
        if section.tvHomeUsesLandscapeArtwork {
            EpisodeThumbCard(
                item: item,
                showProgress: true,
                action: { onSelect(item.contentId) },
                showsEpisodeDetails: MediaServerProvider.active == .emby
                    && section.sectionType.lowercased().contains("next"),
                playAction: play,
                focusedItemId: focus,
                contextPlayTitle: playTitle,
                onRemoveFromContinueWatching: remove,
                onSetWatched: { played in await onSetWatched(item, played) },
                initialIsFavorite: item.userState?.isFavorite == true
            )
        } else {
            MediaCard(
                title: item.type.lowercased() == "episode" ? (item.seriesTitle ?? item.title) : item.title,
                posterUrl: item.posterUrl ?? "",
                thumbhash: item.posterThumbhash,
                year: item.year,
                subtitle: EpisodeCardCaption.line(for: item),
                userState: item.userState,
                overlayData: OverlayData.from(item),
                action: { onSelect(item.contentId) },
                playAction: play,
                focusedItemId: focus,
                contentId: item.contentId,
                onSetWatched: { played in await onSetWatched(item, played) },
                cardWidthOverride: posterWidth,
                episodeAccessibilityLabel: EpisodeCardCaption.accessibilityLabel(for: item)
            )
        }
    }

    private func restore(_ itemID: String?) {
        guard let target = itemID.flatMap({ id in section.items.first { $0.contentId == id } })
                ?? section.items.first else { return }
        focus.pendingItemID = target.contentId
        // Only explicit restoration may need to mount an off-screen cell.
        // An existing cell receives the event; a newly mounted one reads it
        // on appearance. No delayed claims or normal-navigation retries.
        // The collection already retains its last focused card and offset.
        // A Spotlight handoff back to that card must not scroll it sideways.
        if target.contentId != focus.lastItemID {
            proxy.scrollTo(id: target.contentId, animated: false)
        }
        focus.requests.send(target.contentId)
    }
}

private struct CollectionRowUpperBoundary: ViewModifier {
    let onMoveUp: (() -> Void)?

    @ViewBuilder func body(content: Content) -> some View {
        if let onMoveUp {
            content.onMoveCommand { direction in
                if direction == .up { onMoveUp() }
            }
        } else {
            content
        }
    }
}

@MainActor
private final class CollectionRowFocus: ObservableObject {
    let requests = PassthroughSubject<String, Never>()
    var pendingItemID: String?
    var lastItemID: String?

    func didFocus(_ id: String) {
        lastItemID = id
        pendingItemID = nil
    }
}

private struct CollectionMediaCell<Content: View>: View {
    let itemID: String
    let coordinator: CollectionRowFocus
    let onFocus: () -> Void
    @ViewBuilder let content: (FocusState<String?>.Binding) -> Content
    @FocusState private var focusedID: String?
    @Environment(\.tvArtworkLoadingEnabled) private var parentArtworkEnabled
    @Environment(\.tvHomeRowArtworkGate) private var artworkGate

    var body: some View {
        content($focusedID)
            .environment(\.tvArtworkLoadingEnabled, parentArtworkEnabled && (artworkGate?.enabled ?? true))
            .onChange(of: focusedID) { _, id in
                guard id == itemID else { return }
                coordinator.didFocus(itemID)
                onFocus()
            }
            .onAppear {
                if coordinator.pendingItemID == itemID { focusedID = itemID }
            }
            .onReceive(coordinator.requests) { id in
                guard id == itemID else { return }
                if focusedID == itemID { coordinator.pendingItemID = nil }
                else { focusedID = itemID }
            }
    }
}
#endif
