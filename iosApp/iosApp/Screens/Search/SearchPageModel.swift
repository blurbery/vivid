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
    /// The other saved profiles' titles for this search, in saved order,
    /// each shown as a row under these results. Only profiles that found
    /// something are here.
    private(set) var otherProfiles: [OtherProfileResults] = []
    /// The query that found `otherProfiles`.
    private(set) var otherProfilesQuery = ""

    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var nextOffset = 0
    /// Moves on with every change of query or type, so older work can tell
    /// it has been replaced.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var serverTotal: Int?
    @ObservationIgnored private var list = SearchResultList()
    /// The other saved profiles' search, run beside this profile's so it
    /// never holds up the grid.
    @ObservationIgnored private var otherProfileSearch: Task<Void, Never>?

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
        otherProfileSearch?.cancel()
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
        otherProfileSearch?.cancel()
        generation += 1
        guard !isQueryBlank else { return }
        await search(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isSearching else { return }
        await search(reset: false)
    }

    /// Turning the setting off clears the other profiles' rows at once;
    /// turning it on searches them for the query already shown.
    func otherProfilesSettingDidChange() {
        guard !isQueryBlank else {
            otherProfileSearch?.cancel()
            otherProfiles = []
            return
        }
        searchOtherProfiles(trimmedQuery, type: mediaType.queryValue, token: generation)
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
        if isReset {
            searchOtherProfiles(text, type: type, token: token)
        }
        isSearching = true
        error = nil

        var indexMatches: [LibrarySearchIndex.Match] = []
        /// The matches' details, read from the saved library.
        var matchedItems: [String: BrowseItem] = [:]
        var startedList = false
        if isReset {
            let index = StudiosNetworksStore.shared.searchIndex()
            let types: Set<String>? = mediaType == .all ? nil : [type]
            indexMatches = await Task.detached(priority: .userInitiated) {
                index?.search(text, types: types, limit: Self.indexLimit) ?? []
            }.value
            guard isCurrent(token) else { return }
            for item in await StudiosNetworksStore.shared.libraryItems(indexMatches.map(\.contentId)) {
                matchedItems[item.contentId] = item
            }
            guard isCurrent(token) else { return }
            let strong = indexMatches.filter(\.isStrong).compactMap { matchedItems[$0.contentId] }
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
        let weaker = indexMatches.filter { !$0.isStrong }.compactMap { matchedItems[$0.contentId] }
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
            let matched = (indexMatches.filter(\.isStrong) + indexMatches.filter { !$0.isStrong })
                .compactMap { matchedItems[$0.contentId] }
            await refreshArtwork(from: matched, excluding: serverItems, type: type, token: token)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        !Task.isCancelled && token == generation
    }

    /// Searches the other saved profiles for a new query or type. The rows
    /// from the last search go when the new search starts, and each new row
    /// is added at the end as soon as its profile answers, so a slow server
    /// only holds back its own row and a shown row never moves.
    /// While a new query waits out the debounce the old rows stay, so their
    /// headers search with `otherProfilesQuery`, the query that found them.
    private func searchOtherProfiles(_ text: String, type: String, token: Int) {
        otherProfileSearch?.cancel()
        otherProfileSearch = nil
        otherProfiles = []
        otherProfilesQuery = text
        guard OtherProfileSearchSettings.shared.isEnabled else { return }
        otherProfileSearch = Task { [weak self] in
            await OtherProfileSearch.searchAll(query: text, type: type) { row in
                guard let self, self.isCurrent(token), let row = Self.withoutRepeats(row) else { return }
                self.otherProfiles.append(row)
            }
        }
    }

    /// The row with each title only once, since a row's cards are told apart
    /// by content ID, or nil when nothing is left.
    private static func withoutRepeats(_ row: OtherProfileResults) -> OtherProfileResults? {
        var seen = Set<String>()
        var row = row
        row.items = row.items.filter { seen.insert($0.contentId).inserted }
        return row.items.isEmpty ? nil : row
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
        otherProfileSearch?.cancel()
        otherProfileSearch = nil
        otherProfiles = []
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
        from ordered: [BrowseItem],
        excluding serverItems: [BrowseItem],
        type: String,
        token: Int
    ) async {
        let served = Set(serverItems.map(\.contentId))
        let soon = Date().addingTimeInterval(60)
        var titles: [String] = []
        for item in ordered {
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
