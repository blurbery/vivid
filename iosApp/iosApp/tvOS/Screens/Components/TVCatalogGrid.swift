#if os(tvOS)
import SwiftUI

/// Flexible poster grid for tvOS. Delegates pagination + prefetch to the
/// caller via callbacks so the same view works against any paged catalog
/// source (library browse, collection detail, filter result).
///
/// - Pagination: `onNearEnd(currentIndex)` fires when a cell in the last 8
///   rows of items appears. That's a generous lead time on a 100-item page,
///   which gives
///   the network room to complete before the user reaches the bottom.
/// - Prefetch: row visibility reports let the caller cancel stale work and
///   warm a bounded nearby window. The grid does not touch the image cache.
/// - Columns: caller picks `columnCount` (default 6). Drop to 5 when a
///   side-rail (alphabet jumper etc.) eats horizontal space, or the
///   fixed `posterCardWidth` cards start overlapping each other.
struct TVCatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    let onItemTap: (BrowseItem) -> Void
    let onNearEnd: (Int) -> Void
    var columnCount: Int = 6
    var fixedColumnCount: Int? = nil
    @State private var availableWidth: CGFloat = 1760
    @State private var visibleRows: Set<Int> = []
    @State private var lastFocusedItemId: String?
    @State private var artworkWindow = TVPosterArtworkWindow()
    @Environment(\.displayScale) private var displayScale
    /// Per-card width. Defaults to the theme poster size; shrink when a
    /// side-rail squeezes the usable width and the default cards would
    /// overflow their grid cells.
    var cardWidth: CGFloat = VividTheme.posterCardWidth
    var prefersDefaultFocusOnFirstItem: Bool = false
    var focusRequest: Int = 0
    var onFirstRowMoveUp: (() -> Void)? = nil
    var onRowVisibilityChange: ((Range<Int>, Bool) -> Void)? = nil
    var compactSearchCaption = false

    @Namespace private var gridFocusNamespace
    @FocusState private var focusedItemId: String?
    @State private var lastAppliedFocusRequest = 0
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router

    private let columnSpacing: CGFloat = 40
    private let rowSpacing: CGFloat = 60

    /// Trigger prefetch/pagination when a cell within this many rows of
    /// the end appears. 8 rows of lead time — larger buffer means fast
    /// scrolls that skip `.onAppear` events still hit the trigger
    /// before the user reaches the bottom.
    private var prefetchRowsRemaining: Int { fixedColumnCount == nil ? 8 : 2 }

    private var resolvedColumnCount: Int {
        if let fixedColumnCount { return fixedColumnCount }
        return AdaptiveColumns.tvPosterCount(
            standardCount: columnCount,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    private var artworkRange: Range<Int> {
        TVPosterArtworkWindow.range(
            firstVisible: visibleRows.min() ?? 0,
            focusedIndex: items.firstIndex { $0.contentId == lastFocusedItemId },
            itemCount: items.count,
            columns: resolvedColumnCount
        )
    }

    private var artworkEntries: [TVPosterArtworkEntry] {
        guard let columns = fixedColumnCount else { return [] }
        let width = max(1, (availableWidth - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)) * displayScale
        return items[artworkRange].compactMap { item in
            guard let raw = item.posterUrl, let url = URL(string: raw) else { return nil }
            return TVPosterArtworkEntry(url: url, size: CGSize(width: width, height: width * 1.5))
        }
    }

    private var rowStartIndices: [Int] {
        stride(from: 0, to: items.count, by: resolvedColumnCount).map { $0 }
    }

    var body: some View {
        // Rows are explicit full-width focus sections so a D-pad move into a
        // ragged row (fewer cards than columns) still lands: the focus engine
        // resolves moves geometrically, and a partially filled LazyVGrid row
        // has no focusable under most columns. The row's full-width section
        // frame is the catchment; the engine snaps to its nearest card.
        LazyVStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(rowStartIndices, id: \.self) { rowStart in
                HStack(alignment: .top, spacing: columnSpacing) {
                    ForEach(IndexedItems(rowItems(from: rowStart))) { indexed in
                        let item = indexed.element
                        TVMediaCard(
                            title: item.title,
                            posterUrl: item.posterUrl ?? "",
                            posterThumbhash: item.posterThumbhash,
                            year: item.year,
                            userState: item.userState,
                            overlayData: OverlayData.from(item),
                            action: { onItemTap(item) },
                            playAction: playAction(for: item),
                            cardWidth: fixedColumnCount.map {
                                max(1, (availableWidth - CGFloat($0 - 1) * columnSpacing) / CGFloat($0))
                                    / uiCustomization.cardPresentation.posterSize.scale
                            } ?? cardWidth,
                            loadsArtwork: fixedColumnCount == nil || artworkRange.contains(rowStart + indexed.index),
                            prefersDefaultFocus: prefersDefaultFocusOnFirstItem
                                && rowStart == 0 && indexed.index == 0,
                            defaultFocusNamespace: gridFocusNamespace,
                            focusBinding: $focusedItemId,
                            focusContentId: item.contentId,
                            contentId: item.contentId,
                            compactSearchCaption: compactSearchCaption
                        )
                        .frame(maxWidth: .infinity)
                        .onAppear { onCellAppear(index: rowStart + indexed.index) }
                        .modifier(TVCatalogFirstRowBoundary(onMoveUp: rowStart == 0 ? onFirstRowMoveUp : nil))
                    }
                    // Keep ragged-row cards in their column positions by
                    // filling the empty slots with equally flexible spacers.
                    ForEach(0..<emptySlotCount(from: rowStart), id: \.self) { _ in
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
                .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                    if isVisible { visibleRows.insert(rowStart) } else { visibleRows.remove(rowStart) }
                    onRowVisibilityChange?(
                        rowStart..<min(rowStart + resolvedColumnCount, items.count),
                        isVisible
                    )
                }
            }
        }
        .onChange(of: focusedItemId) { _, id in
            guard let id, let index = items.firstIndex(where: { $0.contentId == id }) else { return }
            lastFocusedItemId = id
            onCellAppear(index: index)
        }
        .onChange(of: artworkEntries) { _, entries in artworkWindow.update(entries) }
        .onAppear { artworkWindow.update(artworkEntries) }
        .onDisappear { artworkWindow.clear() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .focusScope(gridFocusNamespace)
        .focusSection()
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: items.map(\.contentId)) { _, _ in applyFocusRequest(focusRequest) }

        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(.vividOnSurface)
                    .padding()
                Spacer()
            }
        }
    }

    private func rowItems(from rowStart: Int) -> [BrowseItem] {
        Array(items[rowStart..<min(rowStart + resolvedColumnCount, items.count)])
    }

    private func emptySlotCount(from rowStart: Int) -> Int {
        resolvedColumnCount - rowItems(from: rowStart).count
    }

    private func onCellAppear(index: Int) {
        guard hasMore else { return }
        let threshold = items.count - (prefetchRowsRemaining * resolvedColumnCount)
        if index >= threshold {
            onNearEnd(index)
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        guard VividMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        guard let firstItemId = items.first?.contentId else { return }
        lastAppliedFocusRequest = request
        focusedItemId = firstItemId
    }
}

struct TVPosterArtworkEntry: Equatable {
    let url: URL
    let size: CGSize
    var key: String { "\(url.absoluteString)#\(size.width)x\(size.height)" }
    var request: VividImageRequest { PosterImageCache.displayRequest(url: url, pixelSize: size, priority: .low) }
}

@MainActor
final class TVPosterArtworkWindow {
    private let prefetcher = VividImagePrefetcher(pipeline: VividImagePipeline.shared, destination: .memoryCache, maxConcurrentRequestCount: 2)
    private var retained: [String: TVPosterArtworkEntry] = [:]

    nonisolated static func range(firstVisible: Int, focusedIndex: Int? = nil, itemCount: Int, columns: Int) -> Range<Int> {
        let columns = max(1, columns)
        let count = max(0, itemCount)
        let anchor = min(max(0, focusedIndex ?? firstVisible), max(0, count - 1))
        let start = max(0, (anchor / columns - 2) * columns)
        return start..<min(count, start + 10 * columns)
    }

    func update(_ entries: [TVPosterArtworkEntry]) {
        let desired = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let removed = retained.filter { desired[$0.key] == nil }.map(\.value)
        prefetcher.stopPrefetching(with: removed.map(\.request))
        for entry in removed {
            VividImagePipeline.shared.cache.removeCachedImage(for: entry.request, caches: .memory)
            VividImagePipeline.shared.cache.removeCachedImage(for: PosterImageCache.cardWarmRequest(for: entry.url), caches: .memory)
        }
        let added = entries.filter { retained[$0.key] == nil }
        retained = desired
        prefetcher.startPrefetching(with: added.map(\.request))
    }

    func clear() {
        prefetcher.stopPrefetching()
        update([])
    }
}

private struct TVCatalogFirstRowBoundary: ViewModifier {
    let onMoveUp: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onMoveUp {
            content.onMoveCommand { if $0 == .up { onMoveUp() } }
        } else {
            content
        }
    }
}

private struct IndexedItems<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Index == Int, Base.Element: Identifiable {
    let base: Base

    init(_ base: Base) {
        self.base = base
    }

    var startIndex: Int { base.startIndex }
    var endIndex: Int { base.endIndex }

    func index(after i: Int) -> Int {
        base.index(after: i)
    }

    func index(before i: Int) -> Int {
        base.index(before: i)
    }

    subscript(position: Int) -> IndexedItem<Base.Element> {
        IndexedItem(index: position, element: base[position])
    }
}

private struct IndexedItem<Element: Identifiable>: Identifiable {
    let index: Int
    let element: Element

    var id: Element.ID { element.id }
}
#endif
