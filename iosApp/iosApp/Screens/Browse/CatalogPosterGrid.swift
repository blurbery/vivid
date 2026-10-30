#if os(iOS)
import SwiftUI

/// A grid of poster cards that asks for more as its end comes into view.
/// The grid and its spinner are siblings, so the caller's stack spaces them
/// and its modifiers apply to both.
struct CatalogGrid: View {
    let items: [BrowseItem]
    let isLoading: Bool
    let hasMore: Bool
    var forcesThreeColumnsOnPhone = false
    let onItemTap: (BrowseItem) -> Void
    let onLoadMore: () -> Void

    @State private var width: CGFloat = 0
    /// One per grid, so detail knows which cards it was opened from.
    @State private var browseOrigin = UUID().uuidString
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let spacing: CGFloat = 8

    init(
        items: [BrowseItem],
        isLoading: Bool,
        hasMore: Bool,
        forcesThreeColumnsOnPhone: Bool = false,
        onItemTap: @escaping (BrowseItem) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.items = items
        self.isLoading = isLoading
        self.hasMore = hasMore
        self.forcesThreeColumnsOnPhone = forcesThreeColumnsOnPhone
        self.onItemTap = onItemTap
        self.onLoadMore = onLoadMore
    }

    var body: some View {
        let columns = columns
        let cardWidth = cardWidth(columnCount: columns.count)
        let loadMoreIndex = max(items.count - 6, 0)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.element.contentId) { index, item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    action: { onItemTap(item) },
                    contentId: item.contentId,
                    cardWidthOverride: cardWidth
                )
                .frame(maxWidth: .infinity)
                .onAppear {
                    if index == loadMoreIndex && hasMore { onLoadMore() }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if abs(newWidth - width) >= 0.5 { width = newWidth }
        }
        .scrollTargetLayout()
        .environment(
            \.itemDetailBrowseSource,
            ItemDetailBrowseSource(originID: browseOrigin, contentIDs: items.map(\.contentId))
        )

        if isLoading {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Color.vividOnSurface)
                    .padding()
                Spacer()
            }
        }
    }

    private var usesDuoWideLayout: Bool { PhoneDuo.usesWideLayout(horizontalSizeClass) }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var usesThreeColumns: Bool {
        forcesThreeColumnsOnPhone
            && (UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass != .regular)
    }

    private var posterSize: CardPosterSize {
        UICustomizationPreferences.shared.cardPresentation.posterSize
    }

    private var columns: [GridItem] {
        let count: Int
        if usesDuoWideLayout {
            count = AdaptiveColumns.duoPosterCount(containerWidth: width)
        } else if isPad {
            count = AdaptiveColumns.tabletPosterCount(containerWidth: width)
        } else if usesThreeColumns {
            count = 3
        } else {
            return AdaptiveColumns.posters(for: horizontalSizeClass, posterSize: posterSize, spacing: spacing)
        }
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
    }

    /// The cell width, undoing the card's own poster-size scaling so posters
    /// fill their cells.
    private func cardWidth(columnCount: Int) -> CGFloat {
        let fitted: CGFloat
        if usesDuoWideLayout {
            fitted = AdaptiveColumns.duoPosterWidth(containerWidth: width)
        } else if isPad {
            fitted = AdaptiveColumns.tabletPosterWidth(containerWidth: width)
        } else {
            fitted = AdaptiveColumns.fittedPosterWidth(
                containerWidth: width,
                columnCount: columnCount,
                spacing: spacing,
                maximumWidth: usesThreeColumns ? nil : VividTheme.posterCardWidth
            )
        }
        return fitted / posterSize.scale
    }
}
#endif
