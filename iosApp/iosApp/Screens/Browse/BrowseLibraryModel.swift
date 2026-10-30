#if os(iOS)
import Foundation
import Observation

extension BrowseView {
    /// One library's catalogue: its pages, filters and filter options.
    @Observable
    @MainActor
    final class Model {
        private(set) var items: [BrowseItem] = []
        private(set) var isLoading = false
        private(set) var error: ErrorState?
        private(set) var hasMore = true
        private(set) var filters = CatalogFilterState.none
        private(set) var mediaType: BrowseMediaType = .movie
        private(set) var facets: CatalogFacets?
        private(set) var facetsFailed = false
        private(set) var isLoadingFacets = false

        @ObservationIgnored private(set) var libraryId: Int?
        @ObservationIgnored private var nextPage = 0
        @ObservationIgnored private var isConfigured = false
        /// Moves on with every configure, so late facet results are dropped.
        @ObservationIgnored private var configureGeneration = 0
        /// Moves on with every reset or library change, so late pages are dropped.
        @ObservationIgnored private var pageGeneration = 0

        private static let pageSize = 60

        /// Points the model at a library. False when a newer configure
        /// started meanwhile, or the task was cancelled.
        @discardableResult
        func configure(libraryId: Int?, libraryType: String? = nil) async -> Bool {
            configureGeneration += 1
            let generation = configureGeneration
            let libraryChanged = !isConfigured || self.libraryId != libraryId
            let resolvedType = await Self.mediaType(libraryId: libraryId, libraryType: libraryType)
            guard generation == configureGeneration, !Task.isCancelled else { return false }

            self.libraryId = libraryId
            mediaType = resolvedType
            isConfigured = true
            if libraryChanged {
                pageGeneration += 1
                nextPage = 0
                hasMore = true
                items = []
                filters = BrowsePrefsStore.shared.savedState(libraryId: libraryId) ?? CatalogFilterState.none
            }
            facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
            facetsFailed = false
            isLoadingFacets = false
            showCachedFirstPage()
            return true
        }

        func load(reset: Bool) async {
            if reset {
                pageGeneration += 1
                showCachedFirstPage()
                nextPage = 0
                hasMore = true
            } else if isLoading {
                return
            }
            let generation = pageGeneration
            guard hasMore else {
                finishLoad(generation)
                return
            }
            isLoading = true
            error = nil
            do {
                let response: CatalogResponse
                if reset {
                    response = try await StartupContentPrefetcher.fetchBrowseFirstPage(libraryId: libraryId, state: filters)
                } else {
                    let query = CatalogQueryBuilder.build(
                        filters,
                        libraryId: libraryId,
                        mediaType: mediaType,
                        offset: nextPage * Self.pageSize,
                        limit: Self.pageSize,
                        includeType: false
                    )
                    response = try await VividAPI.shared.catalog(query: query)
                }
                guard generation == pageGeneration else { return }
                if reset {
                    items = response.items
                    ResponseCache.shared.set(response, for: firstPageKey)
                    adoptMediaType(from: response)
                } else {
                    items += response.items
                }
                hasMore = response.hasMore ?? false
                nextPage += 1
            } catch {
                if generation == pageGeneration, items.isEmpty {
                    self.error = ErrorState(error)
                }
            }
            finishLoad(generation)
        }

        func apply(_ state: CatalogFilterState) async {
            guard state != filters else { return }
            filters = state
            BrowsePrefsStore.shared.saveState(state, libraryId: libraryId)
            items = []
            showCachedFirstPage()
            await load(reset: true)
        }

        /// The current key flips its direction; another key starts in its
        /// natural direction.
        func sort(by key: CatalogSortKey) async {
            var state = filters
            if key == state.sort {
                state.order = state.effectiveOrder.flipped
            } else {
                state.sort = key
                state.order = nil
            }
            await apply(state)
        }

        func remove(_ chip: CatalogFilterState.Chip) async {
            var state = filters
            state.toggle(chip.facet, value: chip.value)
            await apply(state)
        }

        func resetFilters() async {
            var state = filters
            state.resetFilters()
            await apply(state)
        }

        func loadFacetsIfNeeded() async {
            guard facets == nil, !isLoadingFacets else { return }
            let generation = configureGeneration
            isLoadingFacets = true
            facetsFailed = false
            defer {
                if generation == configureGeneration { isLoadingFacets = false }
            }
            do {
                let loaded = try await FacetLoader.shared.facets(libraryId: libraryId)
                guard generation == configureGeneration, !Task.isCancelled else { return }
                facets = loaded
            } catch {
                guard generation == configureGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return }
                facetsFailed = true
            }
        }

        /// Whether this library's filters are kept between visits. Read from
        /// the store each time, not observed.
        var remembersFilters: Bool {
            get { BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId) }
            set {
                BrowsePrefsStore.shared.setPreserveEnabled(newValue, libraryId: libraryId)
                if newValue {
                    BrowsePrefsStore.shared.saveState(filters, libraryId: libraryId)
                }
            }
        }

        // MARK: Helpers

        private var firstPageKey: String {
            CacheKey.browse(libraryId: libraryId, filterKey: filters.cacheKeyFragment)
        }

        private func finishLoad(_ generation: Int) {
            if generation == pageGeneration { isLoading = false }
        }

        /// Paints the cached first page for these filters while nothing is shown.
        private func showCachedFirstPage() {
            guard items.isEmpty,
                  let cached = ResponseCache.shared.get(firstPageKey, as: CatalogResponse.self) else { return }
            items = cached.items
            hasMore = cached.hasMore ?? false
            adoptMediaType(from: cached)
        }

        /// The first title tells a single-type library's kind for sure.
        private func adoptMediaType(from response: CatalogResponse) {
            guard mediaType != .mixed, let first = response.items.first else { return }
            mediaType = BrowseMediaType.from(libraryType: first.type)
        }

        private static func mediaType(libraryId: Int?, libraryType: String?) async -> BrowseMediaType {
            if let libraryType { return BrowseMediaType.from(libraryType: libraryType) }
            guard let libraryId else { return .movie }
            if let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries),
               let library = cached.libraries.first(where: { $0.id == libraryId }) {
                return BrowseMediaType.from(libraryType: library.type)
            }
            if let fetched = try? await StartupContentPrefetcher.fetchUserLibraries(),
               let library = fetched.libraries.first(where: { $0.id == libraryId }) {
                return BrowseMediaType.from(libraryType: library.type)
            }
            return .movie
        }

        private static func isCancellation(_ error: Error) -> Bool {
            if error is CancellationError { return true }
            return (error as? URLError)?.code == .cancelled
        }
    }
}
#endif
