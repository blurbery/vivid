#if os(tvOS)
import Foundation
import Observation

/// One Movies or Series library: its filter, facets and pages of titles.
/// Opening a library paints its saved first page at once; a refetch then
/// swaps in a fresh copy.
@Observable @MainActor
final class TVLibraryGridViewModel {
    let libraryId: Int
    let mediaType: BrowseMediaType

    private(set) var items: [BrowseItem] = []
    private(set) var error: ErrorState?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var hasMore = true
    private(set) var hasRequestedFirstPage = false
    private(set) var filter: CatalogFilterState
    private(set) var facets: CatalogFacets?
    private(set) var isLoadingFacets = false
    private(set) var facetsFailed = false
    private(set) var facetFailureReason: String?

    /// Whether queries name the media type (Movies and Series pages do).
    @ObservationIgnored private let sendsMediaType: Bool
    @ObservationIgnored private let requestCatalog: ([String: String]) async throws -> CatalogResponse
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var snapshot: String?
    @ObservationIgnored private var hasLoadedLaterPage = false
    /// Bumped by every reload; older responses change nothing.
    @ObservationIgnored private var generation = 0

    private static let pageSize = 70

    init(
        libraryId: Int,
        libraryType: String,
        requestCatalog: @escaping ([String: String]) async throws -> CatalogResponse = { query in
            try await VividAPI.shared.get("/api/v1/catalog", query: query)
        }
    ) {
        self.libraryId = libraryId
        let mediaType = BrowseMediaType.from(libraryType: libraryType)
        self.mediaType = mediaType
        let sendsMediaType = VividMediaType.isSeries(libraryType) || VividMediaType.isMovieLibrary(libraryType)
        self.sendsMediaType = sendsMediaType
        var saved = BrowsePrefsStore.shared.savedState(libraryId: libraryId, mediaScope: mediaType.catalogTypeParam) ?? .none
        if sendsMediaType { saved.mediaScope = nil }
        filter = saved
        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        self.requestCatalog = requestCatalog
        showCachedFirstPage()
    }

    var preserveEnabled: Bool {
        BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId, mediaScope: mediaType.catalogTypeParam)
    }

    func setPreserveEnabled(_ enabled: Bool) {
        BrowsePrefsStore.shared.setPreserveEnabled(enabled, libraryId: libraryId, mediaScope: mediaType.catalogTypeParam)
        if enabled { save(filter) }
    }

    // MARK: Pages

    func loadInitial() async {
        await reload(usingCache: true)
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isRefreshing else { return }
        await fetch(reset: false)
    }

    /// Fetches page 1 again behind the cached copy, unless the grid has
    /// already paged further.
    func refreshFirstPage() async {
        guard !items.isEmpty, !hasLoadedLaterPage, !isLoading, !isRefreshing else { return }
        await fetch(reset: true)
    }

    // MARK: Filter

    /// A letter switches to Title A to Z first; the letter itself is never saved.
    func jumpToPrefix(_ letter: String?) async {
        if letter != nil, !(filter.sort == .title && filter.effectiveOrder == .asc) {
            filter.sort = .title
            filter.order = nil
            save(filter)
        }
        filter.namePrefix = letter
        await reload(usingCache: true)
    }

    func applyFilter(_ newFilter: CatalogFilterState) async {
        var newFilter = newFilter
        if sendsMediaType { newFilter.mediaScope = nil }
        guard newFilter != filter else { return }
        filter = newFilter
        save(newFilter)
        await reload(usingCache: false)
    }

    /// The current key flips its direction; another key starts in its own.
    func setSort(_ key: CatalogSortKey) async {
        var next = filter
        if next.sort == key {
            next.order = next.effectiveOrder.flipped
        } else {
            next.sort = key
            next.order = nil
        }
        next.namePrefix = nil
        await applyFilter(next)
    }

    func loadFacetsIfNeeded() async {
        guard facets == nil, !isLoadingFacets else { return }
        isLoadingFacets = true
        facetsFailed = false
        facetFailureReason = nil
        defer { isLoadingFacets = false }
        do {
            facets = try await FacetLoader.shared.facets(libraryId: libraryId)
        } catch {
            guard !Task.isCancelled else { return }
            facetsFailed = true
            if MediaServerProvider.active == .emby {
                facetFailureReason = Self.failureReason(error)
            }
        }
    }

    // MARK: Loading

    private var firstPageKey: String {
        CacheKey.tvLibrary(libraryId: libraryId, filterKey: "type=\(mediaType.rawValue)|\(filter.cacheKeyFragment)")
    }

    private func save(_ state: CatalogFilterState) {
        BrowsePrefsStore.shared.saveState(state, libraryId: libraryId, mediaScope: mediaType.catalogTypeParam)
    }

    private func showCachedFirstPage() {
        guard let cached = ResponseCache.shared.get(firstPageKey, as: CatalogResponse.self) else { return }
        items = cached.items
        hasMore = cached.hasMore ?? false
        nextOffset = cached.items.count
        snapshot = cached.snapshot
    }

    private func reload(usingCache: Bool) async {
        generation += 1
        items = []
        nextOffset = 0
        snapshot = nil
        hasLoadedLaterPage = false
        error = nil
        hasMore = true
        if usingCache { showCachedFirstPage() }
        await fetch(reset: true)
    }

    private func fetch(reset: Bool) async {
        let requestGeneration = generation
        if reset { hasRequestedFirstPage = true }
        if reset && !items.isEmpty {
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            if requestGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }

        let cacheKey = firstPageKey
        let query = CatalogQueryBuilder.build(
            filter,
            libraryId: libraryId,
            mediaType: mediaType,
            offset: reset ? 0 : nextOffset,
            limit: Self.pageSize,
            snapshot: reset ? nil : snapshot,
            includeTotal: false,
            includeType: sendsMediaType
        )
        do {
            let response = try await requestCatalog(query)
            guard requestGeneration == generation else { return }
            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: cacheKey)
                nextOffset = response.items.count
                snapshot = response.snapshot
            } else {
                items.append(contentsOf: response.items)
                nextOffset += response.items.count
                if snapshot == nil { snapshot = response.snapshot }
                hasLoadedLaterPage = true
            }
            hasMore = response.hasMore ?? false
        } catch {
            guard requestGeneration == generation else { return }
            if items.isEmpty { self.error = ErrorState(error) }
        }
    }

    /// Why facets failed, shown on Emby's retry button.
    private static func failureReason(_ error: Error) -> String {
        if let embyError = error as? EmbyError {
            switch embyError {
            case .filterRequestFailed(let step, let status):
                return filterRequestFailureText(step: step, status: status)
            case .signInRequired:
                return String(localized: "Sign-in required")
            case .invalidResponse:
                return String(localized: "Unexpected response")
            case .unsupportedFeature:
                return String(localized: "Unsupported request")
            default:
                return String(localized: "Request failed")
            }
        }
        if let httpError = error as? HTTPError {
            switch httpError {
            case .http(let status, _):
                return "HTTP \(status)"
            case .decodingFailed:
                return String(localized: "Unreadable response")
            case .requestIdentityChanged:
                return String(localized: "Account changed")
            default:
                return String(localized: "Request failed")
            }
        }
        if let urlError = error as? URLError {
            return String(localized: "Network \(String(urlError.code.rawValue))")
        }
        return String(localized: "Request failed")
    }
}
#endif
