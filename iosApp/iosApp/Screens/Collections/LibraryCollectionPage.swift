import SwiftUI

/// One collection's titles, 60 at a time. Silo's first page is cached so a
/// return visit paints straight away.
struct LibraryCollectionDetailView: View {
    let libraryId: Int
    let collectionId: String
    let title: String?
    let kind: LibraryCollectionKind?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var hasMore = true
    /// Only set when the server's total is exact.
    @State private var total: Int?
    @State private var nextOffset = 0
    @State private var snapshot: String?
    @Environment(AppRouter.self) private var router

    private let pageSize = 60

    init(libraryId: Int, collectionId: String, title: String?, kind: LibraryCollectionKind?) {
        self.libraryId = libraryId
        self.collectionId = collectionId
        self.title = title
        self.kind = kind
    }

    private struct LoadKey: Hashable {
        let libraryId: Int
        let collectionId: String
    }

    var body: some View {
        content
            .vividBackground()
            .navigationTitle(title ?? String(localized: "Collection"))
            .vividNavigationTitleDisplayMode(.large)
            #if os(iOS)
            .refreshable { await load(reset: true) }
            #endif
            .task(id: LoadKey(libraryId: libraryId, collectionId: collectionId)) { await load(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: VividTheme.padding) {
                    Text(countLabel)
                        .font(.vividCaption)
                        .foregroundStyle(Color.vividSecondaryText)
                    grid
                }
                #if os(iOS)
                .padding(.horizontal, VividTheme.padding)
                #else
                .padding(.horizontal, VividTheme.safePadding)
                #endif
                .padding(.top, VividTheme.smallPadding)
                .padding(.bottom, VividTheme.largePadding)
            }
        } else if let error {
            ErrorView(state: error, onRetry: { Task { await load(reset: true) } })
        } else if isLoading {
            Color.clear
        } else {
            EmptyStateView(
                icon: "square.stack.3d.up.fill",
                title: "Collection is empty",
                subtitle: "This collection does not have any items yet."
            )
        }
    }

    @ViewBuilder
    private var grid: some View {
        #if os(iOS)
        CatalogGrid(
            items: items,
            isLoading: isLoading,
            hasMore: hasMore,
            forcesThreeColumnsOnPhone: true,
            onItemTap: open,
            onLoadMore: loadNextPage
        )
        #else
        TVCatalogGrid(
            items: items,
            isLoading: isLoading,
            hasMore: hasMore,
            onItemTap: open,
            onNearEnd: { _ in loadNextPage() },
            fixedColumnCount: 7
        )
        #endif
    }

    private var countLabel: String {
        if let total, !hasMore { return String(localized: "\(total) items") }
        if hasMore { return String(localized: "\(items.count)+ items") }
        return String(localized: "\(items.count) items")
    }

    private func open(_ item: BrowseItem) {
        router.navigate(to: Route.itemDetail(browseItem: item))
    }

    private func loadNextPage() {
        guard hasMore, !isLoading else { return }
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        let itemsKey = CacheKey.collectionItems(collectionId)
        if reset {
            // A cached first page is only painted while the first page is
            // fetched again; paging always restarts from the top.
            if items.isEmpty, MediaServerProvider.active == .silo,
               let cached = ResponseCache.shared.get(itemsKey, as: CatalogResponse.self) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                total = cached.totalExact == false ? nil : cached.total
            } else {
                items = []
                hasMore = true
                total = nil
            }
            nextOffset = 0
            snapshot = nil
        } else {
            guard hasMore else { return }
        }

        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page: CatalogResponse
            if kind == .userCollections {
                page = try await VividAPI.shared.userCollectionItems(
                    collectionId: collectionId, offset: nextOffset, limit: pageSize, snapshot: snapshot
                )
            } else {
                page = try await VividAPI.shared.libraryCollectionItems(
                    libraryId: libraryId, collectionId: collectionId,
                    offset: nextOffset, limit: pageSize, snapshot: snapshot
                )
            }
            if reset {
                items = page.items
                ResponseCache.shared.set(page, for: itemsKey)
            } else {
                items += page.items
            }
            total = page.totalExact == false ? nil : page.total
            hasMore = page.hasMore ?? false
            nextOffset += page.items.count
            if snapshot == nil { snapshot = page.snapshot }
        } catch {
            if items.isEmpty { self.error = ErrorState(error) }
        }
    }
}

// MARK: - Collection labels

/// The spoken label for a collection card: its name, what kind of
/// collection it is and how many titles it holds.
@MainActor
func libraryCollectionAccessibilityLabel(_ collection: LibraryCollection) -> String {
    let counted = countedCollection(collection)
    let type = counted.kind == .userCollections
        ? String(localized: "User collection")
        : collectionTypeName(counted.collectionType) ?? String(localized: "Collection")
    var parts = [counted.name, type]
    if let count = counted.itemCount {
        parts.append(String(localized: "\(count) items"))
    } else if !MediaServerProvider.active.usesNativeUser {
        parts.append(String(localized: "Smart"))
    }
    return parts.joined(separator: ", ")
}

/// The badge on a For You collection card: the title count, or "Smart" for
/// a Silo collection the server doesn't count.
@MainActor
func libraryCollectionCountBadge(_ collection: LibraryCollection) -> String? {
    if let count = countedCollection(collection).itemCount { return String(count) }
    return MediaServerProvider.active.usesNativeUser ? nil : String(localized: "Smart")
}

/// Emby leaves counts out of its collection list, so they come from Home's.
@MainActor
private func countedCollection(_ collection: LibraryCollection) -> LibraryCollection {
    MediaServerProvider.active.usesNativeUser ? HomeCollectionsStore.shared.withKnownCount(collection) : collection
}

private func collectionTypeName(_ type: String?) -> String? {
    guard let type else { return nil }
    switch type.lowercased() {
    case "manual": return String(localized: "Manual", comment: "Collection type: titles added by hand")
    case "smart": return String(localized: "Smart")
    case "collection": return String(localized: "Collection")
    case "movies": return String(localized: "Movies")
    default: return type.capitalized
    }
}
