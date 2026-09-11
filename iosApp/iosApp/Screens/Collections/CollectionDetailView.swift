import SwiftUI

/// Shows the items within a specific collection.
struct CollectionDetailView: View {
    let collectionId: String

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return Array(repeating: GridItem(.flexible(), spacing: 12),
                         count: AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth, spacing: 12))
        }
        #endif
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                gridContent
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems() } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: "Collection is empty",
                    subtitle: "Add items from their detail pages"
                )
            }
        }
        .vividPageBackground()
        .navigationTitle("Collection")
        .vividNavigationTitleDisplayMode(.large)
        .task {
            await loadItems()
        }
        .refreshable {
            await loadItems()
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        thumbhash: item.posterThumbhash,
                        year: item.year,
                        userState: item.userState,
                        overlayData: OverlayData.from(item),
                        action: {
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        playAction: playAction(for: item),
                        contentId: item.contentId,
                        cardWidthOverride: gridCardWidthOverride
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            #if os(iOS)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard abs(width - gridWidth) >= 0.5 else { return }
                gridWidth = width
            }
            #endif
            .padding(VividTheme.padding)
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard VividMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone || hSize != .regular
        #else
        false
        #endif
    }

    private var gridCardWidthOverride: CGFloat? {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth, spacing: 12)
                / uiCustomization.cardPresentation.posterSize.scale
        }
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: 12
        )
        return fittedWidth / uiCustomization.cardPresentation.posterSize.scale
        #else
        return nil
        #endif
    }

    private func loadItems() async {
        // Hydrate from cache so a return visit paints the previous grid
        // instantly while the silent revalidate runs.
        let cacheKey = CacheKey.collectionItems(collectionId)
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(cacheKey) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response: CatalogResponse = try await VividAPI.shared.get(
                "/api/v1/collections/\(collectionId)/items"
            )
            ResponseCache.shared.set(response, for: cacheKey)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}
