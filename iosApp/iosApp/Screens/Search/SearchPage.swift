import SwiftUI

/// The Search tab: library titles from the server and the on-device index,
/// with titles to request below them when Seerr is set up.
struct SearchView: View {
    private let blurRequest: Int
    @Binding private var seededQuery: AppRouter.SearchRequest?

    @State private var model = SearchViewModel()
    @State private var requests = RequestSearchSectionViewModel()
    @State private var seerr = TVSeerrConnectionStore.shared
    @Environment(AppRouter.self) private var router

    #if os(iOS)
    @FocusState private var fieldFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.usesDuoSideTabBar) private var usesDuoSideTabBar
    #endif

    /// `usesTVTopMenuInset` is accepted for callers' sake; the Apple TV top
    /// inset is fixed.
    init(
        usesTVTopMenuInset: Bool = true,
        blurRequest: Int = 0,
        seededQuery: Binding<AppRouter.SearchRequest?> = .constant(nil)
    ) {
        self.blurRequest = blurRequest
        _seededQuery = seededQuery
    }

    var body: some View {
        page
            .onChange(of: model.query) {
                model.queryDidChange()
                updateRequests()
            }
            .onChange(of: model.mediaType) {
                updateRequests()
                Task { await model.mediaTypeDidChange() }
            }
            .onChange(of: seerr.identity) {
                updateRequests()
            }
            .onAppear {
                model.warmUp()
                updateRequests()
            }
            .task(id: seededQuery?.id) {
                // A Siri search applies once, then the request is cleared.
                guard let request = seededQuery else { return }
                model.mediaType = .all
                model.query = request.query
                seededQuery = nil
            }
    }

    private var requestMediaType: RequestMediaType {
        switch model.mediaType {
        case .all: .all
        case .movie: .movie
        case .series: .series
        }
    }

    private func updateRequests() {
        requests.onQueryChanged(model.query, mediaType: requestMediaType)
    }

    private func tabTitle(_ type: SearchMediaType) -> String {
        type == .all ? String(localized: "Top Results") : type.title
    }

    private func open(_ item: BrowseItem) {
        router.navigate(to: .itemDetail(browseItem: item))
    }

    private func loadMore() {
        Task { await model.loadMore() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.isSearching && model.results.isEmpty {
            Color.clear
        } else if let error = model.error, model.results.isEmpty {
            // A failed next page keeps the results already on screen.
            ErrorView(state: error, onRetry: { Task { await model.search(reset: true) } })
        } else if model.hasSearched && model.results.isEmpty {
            emptyState(title: "No results", subtitle: "Try a different search term")
        } else if model.results.isEmpty {
            emptyState(title: "Search Vivid", subtitle: "Find movies and series")
        } else {
            resultsGrid
        }
    }

    private func emptyState(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack {
            Spacer(minLength: 80)
            EmptyStateView(icon: "magnifyingglass", title: title, subtitle: subtitle)
        }
    }

    private var resultsGrid: some View {
        VStack(alignment: .leading, spacing: resultsSpacing) {
            Text("\(model.displayedTotal) results")
                .font(.vividCaption)
                .foregroundStyle(Color.vividSecondaryText)
            #if os(iOS)
            CatalogGrid(
                items: model.results,
                isLoading: model.isSearching,
                hasMore: model.hasMore,
                forcesThreeColumnsOnPhone: true,
                onItemTap: open,
                onLoadMore: loadMore
            )
            #else
            TVCatalogGrid(
                items: model.results,
                isLoading: model.isSearching,
                hasMore: model.hasMore,
                onItemTap: open,
                onNearEnd: { _ in loadMore() },
                columnCount: 7,
                fixedColumnCount: 7,
                cardWidth: 190,
                prefersDefaultFocusOnFirstItem: true
            )
            #endif
        }
    }

    #if os(iOS)
    private var resultsSpacing: CGFloat { 16 }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var showsTypeTabs: Bool { !model.isQueryBlank }

    private var page: some View {
        ScrollView(.vertical) {
            VStack(spacing: 16) {
                if isPad {
                    inlineField
                }
                if showsTypeTabs && !usesDuoSideTabBar {
                    typeTabs
                }
                content
                if seerr.isConfigured {
                    RequestSearchSectionView(viewModel: requests)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onDuo { scrollView in
            scrollView.safeAreaInset(edge: .bottom) {
                if showsTypeTabs && usesDuoSideTabBar {
                    typeTabs
                        .frame(height: PhoneDuo.pageTabsRowHeight)
                        .padding(.horizontal, 16)
                        .padding(.bottom, PhoneDuo.pageTabsBottomPadding)
                }
            }
        }
        .background(VividAppBackdrop())
        .navigationTitle("Search")
        .vividNavigationTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        .toolbarBackground(Color.black, for: .navigationBar)
        .modifier(PhoneSearchField(isActive: !isPad, text: $model.query, isFocused: $fieldFocused))
        .onDuoTabletopChange { posture in
            if posture != nil, router.presentedItemDetail == nil, router.presentedPlayer == nil, router.path.isEmpty {
                fieldFocused = true
            }
        }
        .onChange(of: blurRequest) { fieldFocused = false }
        .onChange(of: router.presentedItemDetail?.id) { _, id in
            if id != nil { fieldFocused = false }
        }
        .onDisappear { fieldFocused = false }
    }

    private var inlineField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search movies and series..."), text: $model.query)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.1), in: Capsule())
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var typeTabs: some View {
        HStack(spacing: 4) {
            ForEach(SearchMediaType.allCases) { type in
                let isSelected = type == model.mediaType
                Button {
                    model.mediaType = type
                } label: {
                    Text(verbatim: tabTitle(type))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(isSelected ? Color.black : Color.white)
                        .background(Capsule().fill(isSelected ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .vividGlass(in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .frame(maxWidth: isPad ? 520 : .infinity)
        .onDuo { $0.frame(maxWidth: PhoneDuo.pageTabsMaxWidth(horizontalSizeClass)) }
        .frame(maxWidth: .infinity)
    }

    /// The system search field in the navigation bar, used on iPhone. iPad
    /// shows its own field in the page instead.
    private struct PhoneSearchField: ViewModifier {
        let isActive: Bool
        let text: Binding<String>
        let isFocused: FocusState<Bool>.Binding

        func body(content: Content) -> some View {
            if isActive {
                content
                    .vividSearchable(text: text, prompt: String(localized: "Search movies and series..."))
                    .searchFocused(isFocused)
            } else {
                content
            }
        }
    }
    #else
    private var resultsSpacing: CGFloat { 24 }

    private var page: some View {
        ScrollView(.vertical) {
            VStack(spacing: 24) {
                typeTabs
                    .padding(.horizontal, 48)
                    .frame(maxWidth: .infinity)
                    .focusSection()
                content
                if seerr.isConfigured {
                    RequestSearchSectionView(viewModel: requests)
                }
            }
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Search")
        .vividSearchable(text: $model.query, prompt: String(localized: "Search movies and series..."))
    }

    private var typeTabs: some View {
        HStack(spacing: 24) {
            rule
            HStack(spacing: 8) {
                ForEach(SearchMediaType.allCases) { type in
                    Button {
                        model.mediaType = type
                    } label: {
                        Text(verbatim: tabTitle(type))
                            .font(.system(size: 23, weight: .semibold))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(TabButtonStyle(isSelected: type == model.mediaType))
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
            rule
        }
        .padding(.vertical, 20)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private struct TabButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            TabButton(configuration: configuration, isSelected: isSelected)
        }
    }

    private struct TabButton: View {
        let configuration: ButtonStyleConfiguration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .background(Capsule().fill(fill))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }

        private var fill: Color {
            if isFocused { return .white }
            return isSelected ? Color.white.opacity(0.24) : .clear
        }
    }
    #endif
}
