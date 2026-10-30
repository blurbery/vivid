#if os(tvOS)
import SwiftUI

/// Finds a card's position by content id without walking the whole list on
/// every focus move.
struct TVCatalogItemIndex {
    /// Cheap change detection: the count and the ids at both ends.
    struct Signature: Equatable {
        private let count: Int
        private let firstId: String?
        private let lastId: String?

        init(_ items: [BrowseItem]) {
            count = items.count
            firstId = items.first?.contentId
            lastId = items.last?.contentId
        }
    }

    private var positions: [String: Int] = [:]

    init() {}

    mutating func rebuild(_ items: [BrowseItem]) {
        var map = [String: Int](minimumCapacity: items.count)
        for (position, item) in items.enumerated() where map[item.contentId] == nil {
            map[item.contentId] = position
        }
        positions = map
    }

    /// The mapped position when it still holds the id, else a search of the
    /// list as it is now.
    func index(of contentId: String, in items: [BrowseItem]) -> Int? {
        if let position = positions[contentId], items.indices.contains(position),
           items[position].contentId == contentId {
            return position
        }
        return items.firstIndex { $0.contentId == contentId }
    }
}

/// The poster grid For You, Movies, Series, Search and the other catalogue
/// pages share. Rows build as they near the screen and ask for more before
/// the end is reached.
struct TVCatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    let onItemTap: (BrowseItem) -> Void
    let onNearEnd: (Int) -> Void
    let columnCount: Int
    let fixedColumnCount: Int?
    let cardWidth: CGFloat
    let prefersDefaultFocusOnFirstItem: Bool

    @State private var measuredWidth: CGFloat?
    @State private var visibleRows: Set<Int> = []
    @State private var itemIndex = TVCatalogItemIndex()
    @State private var artwork = TVPosterArtworkWindow()
    @State private var isOnScreen = false
    @FocusState private var focusedId: String?
    @Namespace private var scope
    @Environment(\.displayScale) private var displayScale
    @Environment(AppRouter.self) private var router

    private static let columnSpacing: CGFloat = 40
    private static let rowSpacing: CGFloat = 60
    private static let unmeasuredWidth: CGFloat = 1760

    init(
        items: [BrowseItem],
        isLoading: Bool,
        hasMore: Bool,
        onItemTap: @escaping (BrowseItem) -> Void,
        onNearEnd: @escaping (Int) -> Void,
        columnCount: Int = 6,
        fixedColumnCount: Int? = nil,
        cardWidth: CGFloat = VividTheme.posterCardWidth,
        prefersDefaultFocusOnFirstItem: Bool = false
    ) {
        self.items = items
        self.isLoading = isLoading
        self.hasMore = hasMore
        self.onItemTap = onItemTap
        self.onNearEnd = onNearEnd
        self.columnCount = columnCount
        self.fixedColumnCount = fixedColumnCount
        self.cardWidth = cardWidth
        self.prefersDefaultFocusOnFirstItem = prefersDefaultFocusOnFirstItem
    }

    // The grid and the spinner are siblings, so callers' modifiers reach both.
    var body: some View {
        grid
        if isLoading {
            ProgressView()
                .tint(Color.vividOnSurface)
                .padding()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Layout

    private var posterScale: CGFloat {
        UICustomizationPreferences.shared.cardPresentation.posterSize.scale
    }

    private var columns: Int {
        if let fixedColumnCount { return max(1, fixedColumnCount) }
        let size = UICustomizationPreferences.shared.cardPresentation.posterSize
        return max(1, AdaptiveColumns.tvPosterCount(standardCount: columnCount, posterSize: size))
    }

    private var availableWidth: CGFloat { measuredWidth ?? Self.unmeasuredWidth }

    private func cellWidth(columns: Int) -> CGFloat {
        let gaps = Self.columnSpacing * CGFloat(columns - 1)
        return max(1, (availableWidth - gaps) / CGFloat(columns))
    }

    private func resolvedCardWidth(columns: Int) -> CGFloat {
        fixedColumnCount == nil ? cardWidth : cellWidth(columns: columns) / posterScale
    }

    private var leadRows: Int { fixedColumnCount == nil ? 8 : 4 }

    // MARK: Grid

    private var grid: some View {
        let columns = columns
        let width = resolvedCardWidth(columns: columns)
        let band = artworkRange(columns: columns)
        let focusedIndex = focusedId.flatMap { itemIndex.index(of: $0, in: items) }
        let starts = Array(stride(from: 0, to: items.count, by: columns))
        return LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(starts, id: \.self) { start in
                let end = min(start + columns, items.count)
                let rowVisible = visibleRows.contains(start)
                PosterRow(
                    start: start,
                    items: Array(items[start..<end]),
                    artworkFlags: (start..<end).map { index in
                        fixedColumnCount == nil || band.contains(index) || rowVisible || focusedIndex == index
                    },
                    emptySlots: columns - (end - start),
                    itemCount: items.count,
                    hasMore: hasMore,
                    cardWidth: width,
                    prefersDefaultFocus: prefersDefaultFocusOnFirstItem && start == 0,
                    scope: scope,
                    focus: $focusedId,
                    onSelect: onItemTap,
                    onPlay: play,
                    onCardAppear: checkNearEnd
                )
                .equatable()
                .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                    if isVisible {
                        visibleRows.insert(start)
                        checkNearEnd(min(start + columns, items.count) - 1)
                    } else {
                        visibleRows.remove(start)
                    }
                }
                .onDisappear { visibleRows.remove(start) }
            }
        }
        .focusScope(scope)
        .focusSection()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .onChange(of: TVCatalogItemIndex.Signature(items), initial: true) {
            itemIndex.rebuild(items)
        }
        .onChange(of: focusedId) {
            guard let focusedId, let index = itemIndex.index(of: focusedId, in: items) else { return }
            checkNearEnd(index)
        }
        .onChange(of: items.count) {
            guard let lowest = visibleRows.max() else { return }
            checkNearEnd(min(lowest + columns, items.count) - 1)
        }
        .onChange(of: artworkKey(columns: columns, band: band)) {
            if isOnScreen { updateArtwork() }
        }
        .onAppear {
            isOnScreen = true
            updateArtwork()
        }
        .onDisappear {
            isOnScreen = false
            artwork.clear()
            visibleRows = []
        }
    }

    // MARK: Paging

    private func checkNearEnd(_ index: Int) {
        guard hasMore, index >= 0 else { return }
        if index >= items.count - leadRows * columns {
            onNearEnd(index)
        }
    }

    private func play(_ item: BrowseItem) {
        router.presentPlayer(contentId: item.contentId, posterURL: item.posterUrl, backdropURL: item.backdropUrl)
    }

    // MARK: Artwork

    private struct ArtworkKey: Hashable {
        let band: Range<Int>
        let firstVisible: Int?
        let fixedColumnCount: Int?
        let width: CGFloat
        let displayScale: CGFloat
        let posterURLs: [String?]
    }

    private func artworkRange(columns: Int) -> Range<Int> {
        let firstVisible = visibleRows.min()
        let focusedIndex = firstVisible == nil ? focusedId.flatMap { itemIndex.index(of: $0, in: items) } : nil
        return TVPosterArtworkWindow.range(
            firstVisible: firstVisible,
            focusedIndex: focusedIndex,
            itemCount: items.count,
            columns: columns
        )
    }

    private func artworkKey(columns: Int, band: Range<Int>) -> ArtworkKey {
        ArtworkKey(
            band: band,
            firstVisible: visibleRows.min(),
            fixedColumnCount: fixedColumnCount,
            width: availableWidth,
            displayScale: displayScale,
            posterURLs: fixedColumnCount == nil ? [] : items[band].map(\.posterUrl)
        )
    }

    private func updateArtwork() {
        artwork.update(artworkEntries())
    }

    /// Visible rows and below first, then the look-behind nearest first.
    private func artworkEntries() -> [TVPosterArtworkWindow.Entry] {
        guard fixedColumnCount != nil else { return [] }
        let columns = columns
        let band = artworkRange(columns: columns)
        guard !band.isEmpty else { return [] }
        let pivot = min(max(visibleRows.min() ?? band.lowerBound, band.lowerBound), band.upperBound)
        let order = Array(pivot..<band.upperBound) + Array((band.lowerBound..<pivot).reversed())
        let base = MediaServerProvider.active == .silo ? URL(string: ServerRegistry.shared.activeServerUrl) : nil
        let pixelWidth = cellWidth(columns: columns) * displayScale
        let pixelSize = CGSize(width: pixelWidth, height: pixelWidth * 1.5)
        return order.compactMap { index in
            guard let raw = items[index].posterUrl,
                  let url = SiloAPICompatibility.artworkURL(raw, relativeTo: base) else { return nil }
            return TVPosterArtworkWindow.Entry(url: url, pixelSize: pixelSize)
        }
    }
}

/// One row of cards. Redrawn only when its own inputs change; the actions
/// are left out of the comparison and read current state when called.
private struct PosterRow: View, Equatable {
    let start: Int
    let items: [BrowseItem]
    let artworkFlags: [Bool]
    let emptySlots: Int
    let itemCount: Int
    let hasMore: Bool
    let cardWidth: CGFloat
    let prefersDefaultFocus: Bool
    let scope: Namespace.ID
    let focus: FocusState<String?>.Binding
    let onSelect: (BrowseItem) -> Void
    let onPlay: (BrowseItem) -> Void
    let onCardAppear: (Int) -> Void

    static func == (lhs: PosterRow, rhs: PosterRow) -> Bool {
        lhs.start == rhs.start
            && lhs.items == rhs.items
            && lhs.artworkFlags == rhs.artworkFlags
            && lhs.emptySlots == rhs.emptySlots
            && lhs.itemCount == rhs.itemCount
            && lhs.hasMore == rhs.hasMore
            && lhs.cardWidth == rhs.cardWidth
            && lhs.prefersDefaultFocus == rhs.prefersDefaultFocus
            && lhs.scope == rhs.scope
    }

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            ForEach(Array(items.enumerated()), id: \.element.contentId) { offset, item in
                TVMediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    posterThumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    action: { onSelect(item) },
                    playAction: VividMediaType.isDirectlyPlayable(item.type) ? { onPlay(item) } : nil,
                    cardWidth: cardWidth,
                    loadsArtwork: artworkFlags[offset],
                    prefersDefaultFocus: prefersDefaultFocus && offset == 0,
                    defaultFocusNamespace: scope,
                    focusBinding: focus,
                    focusContentId: item.contentId,
                    contentId: item.contentId
                )
                .frame(maxWidth: .infinity)
                .onAppear { onCardAppear(start + offset) }
            }
            ForEach(0..<max(0, emptySlots), id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .focusSection()
    }
}
#endif
