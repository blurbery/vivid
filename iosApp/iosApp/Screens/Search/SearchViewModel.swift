import Foundation

enum SearchMediaType: String, CaseIterable, Identifiable {
    case all
    case movie
    case series

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .movie: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    /// The `type` query value for this video-only search surface.
    var queryValue: String {
        switch self {
        case .all: "video"
        case .movie: "movie"
        case .series: "series"
        }
    }
}

@Observable
class SearchViewModel {
    var query = ""
    var selectedMediaType: SearchMediaType = .all
    var results: [BrowseItem] = []

    var availableMediaTypes: [SearchMediaType] { SearchMediaType.allCases }
    var isSearching = false
    var error: ErrorState?
    var hasSearched = false
    var hasMore = false
    var total = 0

    private var searchTask: Task<Void, Never>?
    private let pageSize = 60
    /// Results asked for per piece of the query. A piece matches more of the
    /// library than the query, so it gets more than a page.
    static let pieceLimit = 100
    private var offset = 0
    private var searchGeneration = 0
    /// The server's own total for the query, without the titles its pieces added.
    private var serverTotal: Int?

    /// Debounced search triggered on query change.
    func onQueryChanged() {
        searchTask?.cancel()
        searchGeneration += 1

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            resetState()
            return
        }

        searchTask = Task {
            // 300ms debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(reset: true)
        }
    }

    func applyMediaType() async {
        searchTask?.cancel()
        searchGeneration += 1

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        await performSearch(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isSearching else { return }
        await performSearch(reset: false)
    }

    func performSearch(reset: Bool = true) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resetState()
            return
        }

        if !reset, !hasMore {
            return
        }

        if reset { searchGeneration += 1 }
        let generation = searchGeneration
        let requestOffset = reset ? 0 : offset

        isSearching = true
        error = nil

        do {
            var searchQuery: [String: String] = [
                "source": "query",
                "q": trimmed,
                "limit": String(pageSize),
                "offset": String(requestOffset),
            ]
            let type = selectedMediaType.queryValue
            searchQuery["type"] = type

            // Only the first page adds titles found by the query's pieces, so
            // `spiderman` also shows Spider-Man. See `SearchMatching`.
            async let added = Self.pieceMatches(
                reset ? SearchMatching.pieces(of: trimmed) : [],
                query: trimmed, type: type
            )

            let response: CatalogResponse = try await VividAPI.shared.get(
                "/api/v1/catalog",
                query: searchQuery
            )
            guard !Task.isCancelled, generation == searchGeneration else { return }

            let supportedItems = response.items.filter {
                VividMediaType.isSupportedSectionItem($0.type)
            }
            if reset {
                results = supportedItems
            } else {
                let existingIds = Set(results.map(\.contentId))
                results.append(contentsOf: supportedItems.filter {
                    !existingIds.contains($0.contentId)
                })
            }

            offset = requestOffset + response.items.count
            serverTotal = response.total
            hasMore = response.hasMore ?? false
            updateTotal()
            hasSearched = true

            if reset {
                let found = await added
                guard !Task.isCancelled, generation == searchGeneration else { return }
                add(found)
                // With nothing holding the query yet, the title may split it
                // before the pieces reach, as X-Men splits `xmen`.
                if !SearchMatching.hasMatch(in: results, query: trimmed) {
                    let split = await Self.pieceMatches(SearchMatching.splits(of: trimmed), query: trimmed, type: type)
                    guard !Task.isCancelled, generation == searchGeneration else { return }
                    add(split)
                }
            }
        } catch let err {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            self.error = ErrorState(err)
            if reset {
                results = []
                total = 0
                serverTotal = nil
                hasMore = false
                hasSearched = true
            }
        }
        isSearching = false
    }

    /// Adds the titles the query's pieces found that aren't shown yet.
    private func add(_ found: [BrowseItem]) {
        let shown = Set(results.map(\.contentId))
        let extra = found.filter { !shown.contains($0.contentId) }
        results.append(contentsOf: extra)
        updateTotal()
    }

    /// A title the pieces added can also be on a page that hasn't loaded, and
    /// so already in the server's total. Until every page is in, the count is
    /// the server's total or the titles shown, whichever is more. After that
    /// it's the titles shown.
    private func updateTotal() {
        total = hasMore ? max(serverTotal ?? 0, results.count) : results.count
    }

    /// The catalog request for one piece of the query. Emby and Jellyfin send
    /// it as their own `SearchTerm`, as they do the query.
    static func pieceQuery(_ piece: String, type: String) -> [String: String] {
        ["source": "query", "q": piece, "type": type, "limit": String(pieceLimit), "offset": "0"]
    }

    /// The titles the query's pieces find that match it apart from spacing and
    /// punctuation. A piece that fails adds nothing, leaving the query's own results.
    private static func pieceMatches(_ pieces: [String], query: String, type: String) async -> [BrowseItem] {
        guard !pieces.isEmpty else { return [] }
        var pages = Array(repeating: [BrowseItem](), count: pieces.count)
        await withTaskGroup(of: (Int, [BrowseItem]).self) { group in
            for (index, piece) in pieces.enumerated() {
                group.addTask {
                    let response = try? await VividAPI.shared.catalog(query: Self.pieceQuery(piece, type: type))
                    return (index, response?.items ?? [])
                }
            }
            for await (index, items) in group { pages[index] = items }
        }
        return SearchMatching.matches(in: pages, query: query)
            .filter { VividMediaType.isSupportedSectionItem($0.type) }
    }

    private func resetState() {
        results = []
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        total = 0
        serverTotal = nil
        offset = 0
    }
}
