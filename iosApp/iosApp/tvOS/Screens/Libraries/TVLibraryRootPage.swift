#if os(tvOS)
import SwiftUI

extension TVMainTabView {
    /// The Library tab's sub-tabs.
    enum ForYouTab: Hashable, CaseIterable, Identifiable {
        case watchlist
        case favourites
        case collections

        var id: Self { self }

        var title: String {
            switch self {
            case .watchlist: String(localized: "Watchlist")
            case .favourites: String(localized: "Favourites")
            case .collections: String(localized: "Collections")
            }
        }

        /// The catalogue source a list pages through.
        var source: String { self == .watchlist ? "watchlist" : "favorites" }
    }

    /// The Library tab: the row of libraries, then Watchlist, Favourites and
    /// Collections, each with its own filter and A–Z letter.
    struct LibraryRootPage: View {
        @Binding var tab: ForYouTab
        /// The libraries in the server's order. The row shows them in the
        /// order the profile arranged; Collections reads them as given.
        let libraries: [Library]
        let focusRequest: Int
        let isTopMenuFocused: Bool
        let onTopMenuFocusRequest: () -> Void

        @State private var letters: [ForYouTab: String] = [:]
        @State private var filters: [ForYouTab: PersonalListFilter] = [:]
        @State private var items: [BrowseItem] = []
        @State private var isLoading = false
        @State private var hasMore = true
        @State private var error: ErrorState?
        @State private var nextOffset = 0
        /// Bumped by every reload; older responses are dropped.
        @State private var generation = 0
        @State private var lastAppliedFocusRequest = 0
        /// The library card that last held focus, which entry returns to.
        @State private var lastLibraryId: Int?
        /// The library row is being rearranged; Menu ends it.
        @State private var isArrangingLibraries = false
        @State private var libraryOrder = LibraryRowOrderStore.shared
        @FocusState private var focusedLibraryId: Int?
        @FocusState private var focusedTab: ForYouTab?
        @FocusState private var alphabetFocused: Bool
        @FocusState private var filterFocused: Bool
        @Environment(AppRouter.self) private var router

        private static let pageSize = 70

        private var choices: PersonalListFilter.Choices {
            tab == .collections ? .collections : .lists
        }

        private var selectedFilter: PersonalListFilter {
            (filters[tab] ?? PersonalListFilter()).limited(to: choices)
        }

        private var letter: String? { letters[tab] }

        /// In memory under `personal:`, so a profile change clears it.
        private var pageCacheKey: String {
            "personal:tvForYou:\(tab):letter=\(letter ?? "none"):\(selectedFilter.cacheKey)"
        }

        var body: some View {
            let shownLibraries = libraryOrder.ordered(libraries)
            VStack(alignment: .leading, spacing: 32) {
                ScrollView(.vertical) {
                    if !libraries.isEmpty {
                        LibraryCardRow(
                            libraries: shownLibraries,
                            focusedLibraryId: $focusedLibraryId,
                            defaultLibraryId: entryLibraryId,
                            isArranging: $isArrangingLibraries,
                            onOpen: { router.navigate(to: .library(libraryId: $0.id, title: $0.name)) },
                            onMove: { library, offset in
                                libraryOrder.move(library, by: offset, in: shownLibraries)
                            },
                            onMoveUp: handUpToTopMenu
                        )
                        .padding(.bottom, 16)
                    }
                    subTabRow
                        .padding(.bottom, tab == .collections ? 0 : 32)
                    content
                }
                .contentMargins(.top, 28, for: .scrollContent)
                .scrollClipDisabled()
                .scrollIndicators(tab == .collections ? .hidden : .automatic)
                .modifier(TVPersonalScrollAppearance())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, VividTheme.Skyline.barTopInset + 82)
            .task(id: pageCacheKey) { await reload() }
            .onDisappear { isArrangingLibraries = false }
            .onAppear(perform: applyFocusRequest)
            .onChange(of: focusRequest) { applyFocusRequest() }
            .onChange(of: isTopMenuFocused) {
                if !isTopMenuFocused { applyFocusRequest() }
            }
            .onChange(of: focusedLibraryId) {
                if let focusedLibraryId { lastLibraryId = focusedLibraryId }
            }
        }

        // MARK: Sub-tabs

        private var subTabRow: some View {
            HStack(spacing: 14) {
                ForEach(ForYouTab.allCases) { option in
                    subTabButton(option)
                }
                Spacer()
                if !choices.isEmpty {
                    filterMenu
                }
                TVAlphabetMenu(selected: letter) { letters[tab] = $0 }
                    .focused($alphabetFocused)
            }
            .padding(.horizontal, 80)
            .focusSection()
            .defaultFocus($focusedTab, tab, priority: .userInitiated)
            .onMoveCommand { direction in
                // With libraries above, Up moves to their row natively.
                guard direction == .up, libraries.isEmpty else { return }
                handUpToTopMenu()
            }
        }

        private func subTabButton(_ option: ForYouTab) -> some View {
            let isSelected = option == tab
            let isFocused = focusedTab == option
            return Button { tab = option } label: {
                Text(verbatim: option.title)
                    .font(.system(size: 26, weight: .semibold))
                    .padding(.horizontal, 22)
                    .frame(height: TVBrowseControlPillStyle.height)
                    .foregroundStyle(isFocused || isSelected ? Color.white : Color.white.opacity(0.65))
                    .background(TVBrowsePillBackground(isFocused: isFocused, isSelected: isSelected))
            }
            .buttonStyle(.vividFlat)
            .focusEffectDisabled()
            .focused($focusedTab, equals: option)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        private var filterMenu: some View {
            let filter = selectedFilter
            return Menu {
                PersonalListFilterMenuContent(
                    filter: Binding(get: { selectedFilter }, set: { filters[tab] = $0 }),
                    showsAlphabet: false,
                    choices: choices
                )
            } label: {
                Label {
                    if filter.isActive {
                        Text("Filter · \(filter.activeCount)")
                    } else {
                        Text("Filter")
                    }
                } icon: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
            }
            .menuStyle(.button)
            .buttonStyle(TVBrowseControlPillStyle(active: filter.isActive))
            .focused($filterFocused)
            .accessibilityHint(Text("Choose filters"))
        }

        // MARK: Content

        @ViewBuilder
        private var content: some View {
            if tab == .collections {
                TVLibraryCollectionsView(
                    libraries: libraries,
                    filter: selectedFilter,
                    letter: letter,
                    isFocusUp: isTopMenuFocused || focusedLibraryId != nil || focusedTab != nil
                        || alphabetFocused || filterFocused
                )
            } else if items.isEmpty, let error {
                ErrorView(state: error, onRetry: { Task { await reload() } })
            } else if items.isEmpty && !isLoading {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .focusable()
            } else {
                TVCatalogGrid(
                    items: items,
                    isLoading: isLoading,
                    hasMore: hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onNearEnd: { _ in Task { await loadPage(reset: false) } },
                    fixedColumnCount: 7
                )
                .padding(.horizontal, 80)
                .padding(.bottom, 48)
            }
        }

        /// A chosen letter narrows the list as much as a filter does.
        @ViewBuilder
        private var emptyState: some View {
            if selectedFilter.isActive || letter != nil {
                EmptyStateView(
                    icon: "line.3.horizontal.decrease",
                    title: String(localized: "No titles match these filters")
                )
            } else if tab == .watchlist {
                EmptyStateView(icon: "bookmark", title: String(localized: "Your watchlist is empty"))
            } else {
                EmptyStateView(icon: "heart", title: String(localized: "Your favourites are empty"))
            }
        }

        /// The remembered library card while it's still offered, else the
        /// first.
        private var entryLibraryId: Int? {
            if let lastLibraryId, libraries.contains(where: { $0.id == lastLibraryId }) { return lastLibraryId }
            return libraryOrder.ordered(libraries).first?.id
        }

        private func handUpToTopMenu() {
            focusedLibraryId = nil
            focusedTab = nil
            alphabetFocused = false
            filterFocused = false
            onTopMenuFocusRequest()
        }

        /// Each request lands once, on the library row or, without
        /// libraries, on the current sub-tab. Coming back from a pushed page
        /// leaves focus where the navigation stack restores it.
        private func applyFocusRequest() {
            guard focusRequest > 0, focusRequest != lastAppliedFocusRequest, !isTopMenuFocused else { return }
            lastAppliedFocusRequest = focusRequest
            if let entryLibraryId {
                focusedLibraryId = entryLibraryId
            } else {
                focusedTab = tab
            }
        }

        // MARK: Loading

        /// What a cached first page keeps: the titles as shown, repeats
        /// already dropped.
        private struct CachedPage {
            let items: [BrowseItem]
            let hasMore: Bool
        }

        private func reload() async {
            generation += 1
            items = []
            nextOffset = 0
            hasMore = true
            isLoading = false
            error = nil
            guard tab != .collections else { return }
            if let cached = ResponseCache.shared.get(pageCacheKey, as: CachedPage.self) {
                items = cached.items
                nextOffset = cached.items.count
                hasMore = cached.hasMore
            }
            await loadPage(reset: true)
        }

        private func loadPage(reset: Bool) async {
            guard tab != .collections else { return }
            if !reset && !hasMore { return }
            guard !isLoading else { return }

            isLoading = true
            let requestGeneration = generation
            let requestTab = tab
            let requestLetter = letter
            let requestFilter = selectedFilter
            let cacheKey = pageCacheKey
            defer { if generation == requestGeneration { isLoading = false } }

            let isCurrent = {
                generation == requestGeneration
                    && tab == requestTab
                    && letter == requestLetter
                    && selectedFilter == requestFilter
                    && !Task.isCancelled
            }

            var query = [
                "source": requestTab.source,
                "offset": String(reset ? 0 : nextOffset),
                "limit": String(Self.pageSize),
                "include_total": "false",
            ]
            if let requestLetter {
                query["name_prefix"] = requestLetter
                query["sort"] = "title"
                query["order"] = "asc"
            }
            requestFilter.apply(to: &query)

            do {
                let pageItems: [BrowseItem]
                let serverHasMore: Bool?
                let total: Int?
                if requestFilter.anime != .any {
                    var wholeListFilter = requestFilter
                    wholeListFilter.namePrefix = requestLetter
                    pageItems = try await PersonalListLoader.loadAll(source: requestTab.source, filter: wholeListFilter)
                    serverHasMore = false
                    total = nil
                } else {
                    let response = try await VividAPI.shared.catalog(query: query)
                    pageItems = response.items
                    serverHasMore = response.hasMore
                    total = response.total
                }
                guard isCurrent() else { return }

                if reset {
                    items = []
                    nextOffset = 0
                }
                var seen = Set(items.map(\.contentId))
                items.append(contentsOf: pageItems.filter { seen.insert($0.contentId).inserted })
                nextOffset += pageItems.count
                hasMore = serverHasMore ?? total.map { nextOffset < $0 } ?? false
                if reset {
                    ResponseCache.shared.set(CachedPage(items: items, hasMore: hasMore), for: cacheKey)
                }
            } catch {
                guard isCurrent() else { return }
                self.error = ErrorState(error)
            }
        }
    }
}
#endif
