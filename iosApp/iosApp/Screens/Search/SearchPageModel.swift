import Foundation
import Observation

/// The kinds of title Search can be limited to.
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

    /// The catalogue's `type` value.
    var queryValue: String {
        switch self {
        case .all: "video"
        case .movie: "movie"
        case .series: "series"
        }
    }
}

/// Search's results, built from the on-device library index and the
/// server's catalogue. Strong index matches show at once; the server's
/// titles, the weaker matches and the query's pieces follow as they arrive.
@Observable
@MainActor
final class SearchViewModel {
    var query = ""
    var mediaType: SearchMediaType = .all
    private(set) var results: [BrowseItem] = []
    private(set) var isSearching = false
    private(set) var error: ErrorState?
    private(set) var hasSearched = false
    private(set) var hasMore = false
    private(set) var displayedTotal = 0

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var nextOffset = 0
    /// Moves on with every change of query or type, so older work can tell
    /// it has been replaced.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var serverTotal: Int?
    @ObservationIgnored private var list = SearchResultList()

    private static let pageSize = 60
    private nonisolated static let pieceLimit = 100
    private nonisolated static let indexLimit = 100
    private static let artworkRefreshLimit = 3

    nonisolated static func pieceQuery(_ piece: String, type: String) -> [String: String] {
        [
            "source": "query",
            "q": piece,
            "type": type,
            "limit": String(pieceLimit),
            "offset": "0",
        ]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    var isQueryBlank: Bool { trimmedQuery.isEmpty }

    func queryDidChange() {
        debounce?.cancel()
        generation += 1
        guard !isQueryBlank else {
            reset()
            return
        }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.search(reset: true)
        }
    }

    func mediaTypeDidChange() async {
        debounce?.cancel()
        generation += 1
        guard !isQueryBlank else { return }
        await search(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isSearching else { return }
        await search(reset: false)
    }

    /// Starts loading the library index so the first search can use it.
    func warmUp() {
        Task { @MainActor in
            _ = StudiosNetworksStore.shared.searchIndex()
        }
    }

    func search(reset isReset: Bool) async {
        let text = trimmedQuery
        guard !text.isEmpty else {
            reset()
            return
        }
        if !isReset && !hasMore { return }
        if isReset { generation += 1 }
        let token = generation
        let offset = isReset ? 0 : nextOffset
        let type = mediaType.queryValue
        isSearching = true
        error = nil

        var indexMatches: [LibrarySearchIndex.Match] = []
        var startedList = false
        if isReset {
            let index = StudiosNetworksStore.shared.searchIndex()
            let types: Set<String>? = mediaType == .all ? nil : [type]
            indexMatches = await Task.detached(priority: .userInitiated) {
                index?.search(text, types: types, limit: Self.indexLimit) ?? []
            }.value
            guard isCurrent(token) else { return }
            let strong = indexMatches.filter(\.isStrong).map(\.item)
            if !strong.isEmpty {
                list = SearchResultList()
                list.append(strong)
                serverTotal = nil
                hasMore = false
                nextOffset = 0
                show()
                hasSearched = true
                startedList = true
            }
        }
        let weaker = indexMatches.filter { !$0.isStrong }.map(\.item)
        let usesPieces = isReset && indexMatches.isEmpty
        async let pieceItems = Self.pieceResults(
            usesPieces ? SearchMatching.pieces(of: text) : [],
            type: type,
            query: text
        )

        var serverItems: [BrowseItem]?
        do {
            let response = try await VividAPI.shared.catalog(query: [
                "source": "query",
                "q": text,
                "limit": String(Self.pageSize),
                "offset": String(offset),
                "type": type,
            ])
            guard isCurrent(token) else { return }
            let kept = response.items.filter { VividMediaType.isSupportedSectionItem($0.type) }
            if isReset && !startedList { list = SearchResultList() }
            list.merge(kept)
            list.append(weaker)
            nextOffset = offset + response.items.count
            serverTotal = response.total
            hasMore = response.hasMore ?? false
            show()
            hasSearched = true

            if isReset {
                let found = await pieceItems
                guard isCurrent(token) else { return }
                list.append(found)
                if usesPieces, !SearchMatching.hasMatch(in: list.items, query: text) {
                    let splitItems = await Self.pieceResults(SearchMatching.splits(of: text), type: type, query: text)
                    guard isCurrent(token) else { return }
                    list.append(splitItems)
                }
                show()
                serverItems = kept
            }
        } catch {
            guard isCurrent(token) else { return }
            if isReset && !indexMatches.isEmpty {
                // The index still has something to show.
                if !startedList { list = SearchResultList() }
                list.append(weaker)
                serverTotal = nil
                hasMore = false
                show()
            } else {
                self.error = ErrorState(error)
                if isReset {
                    list = SearchResultList()
                    serverTotal = nil
                    hasMore = false
                    show()
                }
            }
            if isReset { hasSearched = true }
        }

        isSearching = false
        if let serverItems, !indexMatches.isEmpty {
            await refreshArtwork(from: indexMatches, excluding: serverItems, type: type, token: token)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        !Task.isCancelled && token == generation
    }

    private func show() {
        results = list.items
        displayedTotal = hasMore ? max(serverTotal ?? 0, results.count) : results.count
    }

    private func reset() {
        list = SearchResultList()
        results = []
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        displayedTotal = 0
        serverTotal = nil
        nextOffset = 0
    }

    /// Titles found through the query's pieces: every piece is asked for at
    /// once, then the titles holding the whole query are kept.
    private nonisolated static func pieceResults(_ pieces: [String], type: String, query: String) async -> [BrowseItem] {
        guard !pieces.isEmpty else { return [] }
        let pages = await withTaskGroup(of: (Int, [BrowseItem]).self) { group in
            for (position, piece) in pieces.enumerated() {
                group.addTask {
                    let response = try? await VividAPI.shared.catalog(query: pieceQuery(piece, type: type))
                    return (position, response?.items ?? [])
                }
            }
            var pages = Array(repeating: [BrowseItem](), count: pieces.count)
            for await (position, items) in group {
                pages[position] = items
            }
            return pages
        }
        return SearchMatching.matches(in: pages, query: query)
            .filter { VividMediaType.isSupportedSectionItem($0.type) }
    }

    /// The index can hold signed artwork links that are about to expire.
    /// Asks the server again for a few of those titles and swaps in its cards.
    private func refreshArtwork(
        from matches: [LibrarySearchIndex.Match],
        excluding serverItems: [BrowseItem],
        type: String,
        token: Int
    ) async {
        let served = Set(serverItems.map(\.contentId))
        let soon = Date().addingTimeInterval(60)
        let ordered = matches.filter(\.isStrong) + matches.filter { !$0.isStrong }
        var titles: [String] = []
        for match in ordered {
            let item = match.item
            guard !served.contains(item.contentId), !titles.contains(item.title),
                  let poster = item.posterUrl,
                  let expiry = SiloAPICompatibility.artworkExpiry(poster), expiry < soon else { continue }
            titles.append(item.title)
            if titles.count == Self.artworkRefreshLimit { break }
        }
        guard !titles.isEmpty else { return }
        let refreshed = await withTaskGroup(of: [BrowseItem].self) { group in
            for title in titles {
                group.addTask {
                    (try? await VividAPI.shared.catalog(query: Self.pieceQuery(title, type: type)))?.items ?? []
                }
            }
            var items: [BrowseItem] = []
            for await found in group {
                items += found
            }
            return items
        }
        guard isCurrent(token) else { return }
        list.replace(refreshed)
        show()
    }
}
