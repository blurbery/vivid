#if os(iOS)
import SwiftUI

/// For You's Watchlist or Favourites list. Without a filter it shows the
/// first 100 titles (cached between visits); with one it loads every title
/// the filter keeps.
struct SavedTitlesList: View {
    enum Kind {
        case watchlist
        case favourites

        /// The catalogue source `PersonalListLoader` pages through.
        var source: String { self == .watchlist ? "watchlist" : "favorites" }
        var cacheKey: String { self == .watchlist ? CacheKey.watchlist : CacheKey.favorites }
    }

    /// What reloads the list. Favourites reloads on any filter change; the
    /// Watchlist also reloads when a tracker plugin changes it on the server.
    private struct ReloadKey: Hashable {
        var filter: PersonalListFilter?
        var filterKey: String?
        var syncRevision: Int?
    }

    let kind: Kind
    let filter: PersonalListFilter

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    /// The filter `items` was loaded with.
    @State private var itemsFilter = PersonalListFilter()
    /// Bumped by every load, so only the newest one lands.
    @State private var loadGeneration = 0
    @Environment(\.forYouPageTabs) private var pageTabs

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                pageTabs
                stateView
            } else {
                ScrollView {
                    pageTabs
                    SavedTitlesGrid(items: items, onRemovedState: removeIfNoLongerSaved)
                        .padding(16)
                }
                .reportsPageChromeScroll()
            }
        }
        .vividBackground()
        .refreshable { await load() }
        .task(id: reloadKey) { await load() }
        .onDisappear {
            // A Watchlist load still running when the list goes away is dropped.
            if kind == .watchlist { loadGeneration += 1 }
        }
    }

    private var reloadKey: ReloadKey {
        switch kind {
        case .favourites:
            ReloadKey(filter: filter)
        case .watchlist:
            ReloadKey(
                filterKey: filter.cacheKey,
                syncRevision: MDBListSyncStore.shared.watchlistRevision + SimklSyncStore.shared.watchlistRevision
            )
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if let error {
            ErrorView(state: error, onRetry: { Task { await load() } })
        } else if isLoading {
            Color.clear
        } else if filter.isActive {
            EmptyStateView(icon: "line.3.horizontal.decrease", title: "No titles match these filters")
        } else if kind == .watchlist {
            EmptyStateView(
                icon: "bookmark",
                title: "Watchlist is empty",
                subtitle: "Tap the bookmark icon on any item to add it here"
            )
        } else {
            EmptyStateView(
                icon: "heart",
                title: "No favorites",
                subtitle: "Tap the heart icon on any item to add it here"
            )
        }
    }

    private func load() async {
        if kind == .watchlist, Task.isCancelled { return }
        loadGeneration += 1
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoading = false } }
        let isCurrent = { generation == loadGeneration && !Task.isCancelled }

        if filter != itemsFilter {
            items = []
            itemsFilter = filter
        }

        if filter.isActive {
            error = nil
            if items.isEmpty { isLoading = true }
            do {
                let loaded = try await PersonalListLoader.loadAll(source: kind.source, filter: filter)
                guard isCurrent() else { return }
                items = loaded
            } catch {
                guard isCurrent() else { return }
                items = []
                self.error = ErrorState(error)
            }
            return
        }

        if items.isEmpty, let cached = ResponseCache.shared.get(kind.cacheKey, as: CatalogResponse.self) {
            items = cached.items
        }
        if items.isEmpty { isLoading = true }
        error = nil
        do {
            let response: CatalogResponse
            if kind == .watchlist {
                response = try await VividAPI.shared.watchlist(offset: 0, limit: 100)
            } else {
                response = try await VividAPI.shared.favorites(offset: 0, limit: 100)
            }
            guard isCurrent() else { return }
            ResponseCache.shared.set(response, for: kind.cacheKey)
            items = response.items
        } catch {
            guard isCurrent(), items.isEmpty else { return }
            self.error = ErrorState(error)
        }
    }

    /// A card's context menu took the title off this list.
    private func removeIfNoLongerSaved(_ contentId: String, _ state: MediaItemUserState) {
        let stillSaved = kind == .watchlist ? state.inWatchlist : state.isFavorite
        guard !stillSaved else { return }
        withAnimation {
            items.removeAll { $0.contentId == contentId }
        }
    }
}

/// The poster grid For You's lists share, sized like Home's posters.
private struct SavedTitlesGrid: View {
    let items: [BrowseItem]
    let onRemovedState: (String, MediaItemUserState) -> Void

    @State private var width: CGFloat = 0
    @State private var browseOrigin = UUID().uuidString
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppRouter.self) private var router

    private let spacing: CGFloat = 8

    var body: some View {
        let columns = columnCount
        let cardWidth = cardWidth(columns: columns)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columns),
            spacing: 12
        ) {
            ForEach(items) { item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    usesHomeCaption: true,
                    action: { router.navigate(to: .itemDetail(contentId: item.contentId)) },
                    contentId: item.contentId,
                    cardWidthOverride: cardWidth,
                    onUserStateChanged: { onRemovedState(item.contentId, $0) }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if abs(newWidth - width) >= 0.5 { width = newWidth }
        }
        .environment(
            \.itemDetailBrowseSource,
            ItemDetailBrowseSource(originID: browseOrigin, contentIDs: items.map(\.contentId))
        )
    }

    private var usesDuoWideLayout: Bool { PhoneDuo.usesWideLayout(horizontalSizeClass) }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var columnCount: Int {
        if usesDuoWideLayout { return AdaptiveColumns.duoPosterCount(containerWidth: width) }
        if isPad { return AdaptiveColumns.tabletPosterCount(containerWidth: width) }
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        return horizontalSizeClass == .regular && !isPhone ? 5 : 3
    }

    /// The cell width, undoing the card's own poster-size scaling so posters
    /// fill their cells.
    private func cardWidth(columns: Int) -> CGFloat {
        let fitted: CGFloat
        if usesDuoWideLayout {
            fitted = AdaptiveColumns.duoPosterWidth(containerWidth: width)
        } else if isPad {
            fitted = AdaptiveColumns.tabletPosterWidth(containerWidth: width)
        } else {
            fitted = AdaptiveColumns.fittedPosterWidth(
                containerWidth: width, columnCount: columns, spacing: spacing, maximumWidth: nil
            )
        }
        return fitted / UICustomizationPreferences.shared.cardPresentation.posterSize.scale
    }
}
#endif
