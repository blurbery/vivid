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
    var isSpotlightHandoffPending: (() -> Bool)? = nil

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
            && (lhs.isSpotlightHandoffPending == nil) == (rhs.isSpotlightHandoffPending == nil)
    }

    // Remembered IDs are consumed only by explicit entry/detail request tokens
    // or section changes, all compared above. Comparing passive memory here
    // would refresh every visited row when Spotlight re-renders the feed.


    @EnvironmentObject private var overlayStore: OverlayPrefsStore
    @Environment(\.homeCardPresentation) private var presentation
    @Environment(\.tvArtworkLoadingEnabled) private var artworkLoadingEnabled
    @Environment(\.tvHomeRowArtworkGate) private var artworkGate
    @Environment(\.tvHomeFocusOwnership) private var ownership
    @Environment(\.tvHomeScrollDiagnostics) private var diagnostics
    @StateObject private var proxy = CollectionHStackProxy()
    @StateObject private var focus = CollectionRowFocus()
    @State private var appliedEntry = 0
    @State private var appliedReturn = 0

    var body: some View {
        let _ = diagnostics?.event("collectionRow.body", index: rowIndex)
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
                                    ownsRestoration: { ownsReturnFocus?.wrappedValue == true },
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
            restore(rememberedItemID, allowsHandoffFallback: true)
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
        .onDisappear {
            focus.cancelRequest()
            ownership?.unregisterCancellation(for: section.id)
        }
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

    private func restore(_ itemID: String?, allowsHandoffFallback: Bool = false, forceScroll: Bool = false) {
        guard let target = itemID.flatMap({ id in section.items.first { $0.contentId == id } })
                ?? section.items.first else { return }
        ownership?.registerCancellation(for: section.id) { [weak focus] in focus?.cancelRequest() }
        let diagnosticRowIndex = rowIndex
        focus.onDiagnosticEvent = diagnostics.map { diagnostics in
            { event in diagnostics.event(event, index: diagnosticRowIndex) }
        }
        focus.request(target.contentId, onExpiry: allowsHandoffFallback ? {
            guard ownsReturnFocus?.wrappedValue == true,
                  isSpotlightHandoffPending?() == true else { return }
            // Only an unconsumed Spotlight entry can retry, once. Detail return
            // and ordinary directional movement never enter this fallback.
            restore(target.contentId, forceScroll: true)
        } : nil)
        // Only explicit restoration may need to mount an off-screen cell.
        // An existing cell receives the event; a newly mounted one reads it
        // on appearance, once, while this row still owns restoration.
        // The collection already retains its last focused card and offset.
        // A Spotlight handoff back to that card must not scroll it sideways.
        if forceScroll || target.contentId != focus.lastItemID {
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
    private final class Request {
        let itemID: String
        init(_ itemID: String) { self.itemID = itemID }
    }
    private var pending: Request?
    var lastItemID: String?
    var onDiagnosticEvent: ((String) -> Void)?

    func request(_ id: String, onExpiry: (() -> Void)?) {
        let request = Request(id)
        pending = request
        onDiagnosticEvent?("restore.request")
        // Ownership/focus events invalidate immediately. This is only a
        // backstop for a target that never materialises, not a retry cadence.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self, weak request] in
            guard let self, let request, self.pending === request else { return }
            self.onDiagnosticEvent?("restore.expire")
            self.cancelRequest()
            onExpiry?()
        }
    }

    func cancelRequest() {
        if pending != nil { onDiagnosticEvent?("restore.cancel") }
        pending = nil
    }

    func consumeRequest(for id: String, ownsRestoration: Bool) -> Bool {
        guard ownsRestoration else {
            cancelRequest()
            return false
        }
        guard pending?.itemID == id else { return false }
        onDiagnosticEvent?("restore.consume")
        // Consume before writing FocusState, even if UIKit cannot honour it.
        // Reuse must never turn one restoration into repeated focus claims.
        cancelRequest()
        return true
    }

    func didFocus(_ id: String) {
        lastItemID = id
        cancelRequest()
    }
}

private struct CollectionMediaCell<Content: View>: View {
    let itemID: String
    let coordinator: CollectionRowFocus
    let ownsRestoration: () -> Bool
    let onFocus: () -> Void
    @ViewBuilder let content: (FocusState<String?>.Binding) -> Content
    @FocusState private var focusedID: String?
    @Environment(\.tvArtworkLoadingEnabled) private var parentArtworkEnabled
    @Environment(\.tvHomeRowArtworkGate) private var artworkGate

    var body: some View {
        let _ = VividImageDiagnostics.shared.count("leaf.CollectionMediaCell.body")
        content($focusedID)
            .environment(\.tvArtworkLoadingEnabled, parentArtworkEnabled && (artworkGate?.enabled ?? true))
            .onChange(of: focusedID) { _, id in
                guard id == itemID else { return }
                coordinator.didFocus(itemID)
                onFocus()
            }
            .onAppear {
                VividImageDiagnostics.shared.count("cell.appear")
                if coordinator.consumeRequest(for: itemID, ownsRestoration: ownsRestoration()) {
                    focusedID = itemID
                }
            }
            .onDisappear { VividImageDiagnostics.shared.count("cell.disappear") }
            .onReceive(coordinator.requests) { id in
                guard id == itemID,
                      coordinator.consumeRequest(for: itemID, ownsRestoration: ownsRestoration()) else { return }
                focusedID = itemID
            }
    }
}
#endif
