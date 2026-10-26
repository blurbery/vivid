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
    /// The most titles the library index adds to a search.
    private static let localLimit = 100
    /// The most titles searched for again when their index posters have expired.
    private static let artworkRefreshLimit = 3
    /// The server's own total for the query, without the titles its pieces added.
    private var serverTotal: Int?
    private var list = SearchResultList()

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
        let type = selectedMediaType.queryValue

        isSearching = true
        error = nil

        // The first page starts with what the library index finds on the
        // device, so typos and any spacing or punctuation still match. Strong
        // matches show straight away, ahead of the server's titles, and weaker
        // ones follow the server's. See `LibrarySearchIndex`.
        var local: [LibrarySearchIndex.Match] = []
        // Until something replaces them, the last query's results stay up.
        var startedList = !reset
        if reset {
            let index = await StudiosNetworksStore.shared.searchIndex()
            let types: Set<String>? = selectedMediaType == .all ? nil : [type]
            local = await Self.localMatches(index, query: trimmed, types: types)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            let strong = local.filter(\.isStrong).map(\.item)
            if !strong.isEmpty {
                list = SearchResultList()
                list.append(strong)
                startedList = true
                serverTotal = nil
                hasMore = false
                offset = 0
                show()
                hasSearched = true
            }
        }
        let weaker = local.filter { !$0.isStrong }.map(\.item)
        // Without an index, or when it finds nothing (a title added since the
        // library was read), the query's pieces stand in for it.
        let usesPieces = reset && local.isEmpty
        // The first page's cards from the server, once it answers.
        var serverCards: [BrowseItem]?

        do {
            var searchQuery: [String: String] = [
                "source": "query",
                "q": trimmed,
                "limit": String(pageSize),
                "offset": String(requestOffset),
            ]
            searchQuery["type"] = type

            // `spiderman` also asks for `spide`, so Spider-Man shows. See `SearchMatching`.
            async let added = Self.pieceMatches(
                usesPieces ? SearchMatching.pieces(of: trimmed) : [],
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
            if !startedList { list = SearchResultList() }
            list.merge(supportedItems)
            list.append(weaker)

            offset = requestOffset + response.items.count
            serverTotal = response.total
            hasMore = response.hasMore ?? false
            show()
            hasSearched = true

            if reset {
                let found = await added
                guard !Task.isCancelled, generation == searchGeneration else { return }
                list.append(found)
                // With nothing holding the query yet, the title may split it
                // before the pieces reach, as X-Men splits `xmen`.
                if usesPieces, !SearchMatching.hasMatch(in: list.items, query: trimmed) {
                    let split = await Self.pieceMatches(SearchMatching.splits(of: trimmed), query: trimmed, type: type)
                    guard !Task.isCancelled, generation == searchGeneration else { return }
                    list.append(split)
                }
                show()
                serverCards = supportedItems
            }
        } catch let err {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            if reset, !local.isEmpty {
                // The index's titles still show when the server can't answer.
                if !startedList { list = SearchResultList() }
                list.append(weaker)
                serverTotal = nil
                hasMore = false
                show()
            } else {
                self.error = ErrorState(err)
                if reset {
                    list = SearchResultList()
                    serverTotal = nil
                    hasMore = false
                    show()
                }
            }
            if reset { hasSearched = true }
        }
        isSearching = false
        if let serverCards, !local.isEmpty {
            await refreshArtwork(of: local.map(\.item), besides: serverCards, type: type, generation: generation)
        }
    }

    /// Starts loading the library index, so it's ready by the first search.
    func prepare() {
        Task { @MainActor in _ = StudiosNetworksStore.shared.searchIndex() }
    }

    private func show() {
        results = list.items
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

    /// The library index's matches, best first, worked out off the main actor.
    private static func localMatches(
        _ index: LibrarySearchIndex?, query: String, types: Set<String>?
    ) async -> [LibrarySearchIndex.Match] {
        guard let index else { return [] }
        return await Task.detached(priority: .userInitiated) {
            index.search(query, types: types, limit: localLimit)
        }.value
    }

    /// Silo signs poster URLs for a few hours, and the library index can be
    /// older. Titles only the index found whose posters have expired are
    /// searched for again, up to `artworkRefreshLimit` different titles at
    /// once, and the server's fresh cards replace the shown ones where they
    /// stand. It runs after the search has finished, so loading more results
    /// never waits for it.
    private func refreshArtwork(of local: [BrowseItem], besides fresh: [BrowseItem], type: String, generation: Int) async {
        let current = Set(fresh.map(\.contentId))
        let soon = Date().addingTimeInterval(60)
        var titles: [String] = []
        for item in local where !current.contains(item.contentId) && !titles.contains(item.title)
            && (item.posterUrl.flatMap(SiloAPICompatibility.artworkExpiry).map { $0 < soon } ?? false) {
            titles.append(item.title)
            if titles.count == Self.artworkRefreshLimit { break }
        }
        guard !titles.isEmpty else { return }
        let cards = await withTaskGroup(of: [BrowseItem].self) { group in
            for title in titles {
                group.addTask { (try? await VividAPI.shared.catalog(query: Self.pieceQuery(title, type: type)))?.items ?? [] }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        guard !Task.isCancelled, generation == searchGeneration else { return }
        list.replace(cards)
        show()
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
        list = SearchResultList()
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
