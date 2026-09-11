import SwiftUI

/// Full-window search with debounced query and grid results — Plezy style.
struct SearchView: View {
    @State private var viewModel = SearchViewModel()
    @State private var requestsViewModel = RequestSearchSectionViewModel()
    #if os(tvOS) || os(iOS)
    @State private var seerr = TVSeerrConnectionStore.shared
    #endif
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #endif
    private let usesTVTopMenuInset: Bool
    private let blurRequest: Int

    init(usesTVTopMenuInset: Bool = true, blurRequest: Int = 0) {
        self.usesTVTopMenuInset = usesTVTopMenuInset
        self.blurRequest = blurRequest
    }

    var body: some View {
        ScrollView {
            VStack(spacing: contentSpacing) {
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(searchPrompt, text: $viewModel.query)
                            .focused($isSearchFieldFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                        if !viewModel.query.isEmpty {
                            Button { viewModel.query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(.white.opacity(0.1), in: Capsule())
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                #endif
                if shouldShowFilters {
                    mediaTypeFilter
                    #if os(tvOS)
                        .padding(.horizontal, VividTheme.padding)
                        // Stretch the picker focus section across the
                        // full row so up-moves from the grid's outer
                        // columns land here instead of skipping straight
                        // to the search field above.
                        .frame(maxWidth: .infinity)
                        .focusSection()
                    #elseif os(macOS)
                        .padding(.horizontal, VividTheme.padding)
                    #endif
                }

                content

                // TMDB titles the library can't answer — the request
                // system's organic entry point. Renders nothing when the
                // server has requests disabled.
                #if os(tvOS) || os(iOS)
                if seerr.isConfigured { RequestSearchSectionView(viewModel: requestsViewModel) }
                #else
                RequestSearchSectionView(viewModel: requestsViewModel)
                #endif
            }
            #if os(tvOS)
            .padding(.top, usesTVTopMenuInset ? TVTopMenuLayout.contentTopInset : VividTheme.padding)
            .frame(maxWidth: .infinity)
            #else
            .padding(.horizontal, VividTheme.padding)
            .padding(.top, VividTheme.smallPadding)
            #endif
        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        #endif
        .navigationTitle("Search")
        .vividNavigationTitleDisplayMode(.inline)
        .vividToolbarColorSchemeDark()
        #if os(iOS)
        .toolbarBackground(Color.black, for: .navigationBar)
        #else
        .vividNavigationBarSurfaceBackground()
        #endif
        .modifier(SearchNativeField(query: $viewModel.query, prompt: searchPrompt))
        #if os(iOS)
        .searchFocused($isSearchFieldFocused)
        .onChange(of: blurRequest) { _, _ in
            isSearchFieldFocused = false
        }
        .onChange(of: router.presentedItemDetail?.id) { _, detailID in
            if detailID != nil {
                isSearchFieldFocused = false
            }
        }
        .onDisappear { isSearchFieldFocused = false }
        #endif
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChanged()
            requestsViewModel.onQueryChanged(viewModel.query, mediaType: requestMediaType)
        }
        .onChange(of: viewModel.selectedMediaType) { _, _ in
            requestsViewModel.onQueryChanged(viewModel.query, mediaType: requestMediaType)
            Task { await viewModel.applyMediaType() }
        }
        #if os(tvOS) || os(iOS)
        .onChange(of: seerr.identity) { _, _ in requestsViewModel.onQueryChanged(viewModel.query, mediaType: requestMediaType) }
        #endif
        .onAppear {
            requestsViewModel.onQueryChanged(viewModel.query, mediaType: requestMediaType)
        }
    }

    private var requestMediaType: RequestMediaType {
        viewModel.selectedMediaType == .movie ? .movie : viewModel.selectedMediaType == .series ? .series : .all
    }

    private var searchPrompt: String {
        "Search movies and series..."
    }

    private var contentSpacing: CGFloat {
        #if os(tvOS)
        VividTheme.spacing
        #else
        VividTheme.padding
        #endif
    }

    // MARK: - Shared Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            Color.clear
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.performSearch() } })
        } else if viewModel.hasSearched && viewModel.results.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    subtitle: "Try a different search term"
                )
            }
        } else if viewModel.results.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search Vivid",
                    subtitle: "Find movies and series"
                )
            }
        } else {
            VStack(alignment: .leading, spacing: contentSpacing) {
                Text("\(viewModel.total) result\(viewModel.total == 1 ? "" : "s")")
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)

#if os(tvOS)
                TVCatalogGrid(
                    items: viewModel.results,
                    isLoading: viewModel.isSearching,
                    hasMore: viewModel.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onNearEnd: { _ in
                        Task { await viewModel.loadMore() }
                    },
                    columnCount: 7,
                    fixedColumnCount: 7,
                    cardWidth: 190,
                    prefersDefaultFocusOnFirstItem: true
                )
#else
                CatalogGrid(
                    items: viewModel.results,
                    isLoading: viewModel.isSearching,
                    hasMore: viewModel.hasMore,
                    forcesThreeColumnsOnPhone: true,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onLoadMore: {
                        Task { await viewModel.loadMore() }
                    }
                )
#endif
            }
        }
    }

    private var shouldShowFilters: Bool {
        #if os(tvOS)
        true
        #else
        !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
        #endif
    }

    @ViewBuilder
    private var mediaTypeFilter: some View {
        #if os(iOS)
        HStack(spacing: 4) {
            ForEach([SearchMediaType.all, .movie, .series]) { type in
                Button { viewModel.selectedMediaType = type } label: {
                    Text(type == .all ? "Top Results" : type.title)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .foregroundStyle(viewModel.selectedMediaType == type ? Color.black : .white)
                        .background(viewModel.selectedMediaType == type ? Color.white : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(5).vividGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false))
        .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 520 : .infinity)
        .frame(maxWidth: .infinity)
        #elseif os(tvOS)
        HStack(spacing: 24) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            HStack(spacing: 8) {
                ForEach([SearchMediaType.all, .movie, .series]) { type in
                    Button { viewModel.selectedMediaType = type } label: {
                        Text(type == .all ? "Top Results" : type.title)
                            .font(.system(size: 23, weight: .semibold))
                            .padding(.horizontal, 24).padding(.vertical, 13)
                    }
                    .buttonStyle(TVSearchTabStyle(selected: viewModel.selectedMediaType == type))
                }
            }
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            .fixedSize()
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
        }
        .padding(.vertical, 20)
        #else
        mediaTypePicker
        #endif
    }

    private var mediaTypePicker: some View {
        Picker("Media Type", selection: $viewModel.selectedMediaType) {
            ForEach(viewModel.availableMediaTypes) { mediaType in
                Text(mediaType.title)
                    .tag(mediaType)
            }
        }
        .pickerStyle(.segmented)
#if os(tvOS)
        .vividFormWidth(tvFilterWidth)
#endif
    }

#if os(tvOS)
    /// Narrower than the results column so the segmented control reads as a
    /// centered pill rather than stretching across the whole search page.
    private var tvFilterWidth: CGFloat { 760 }
#endif
}

#if os(tvOS)
private struct TVSearchTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        TVSearchTabBody(configuration: configuration, selected: selected)
    }
}
private struct TVSearchTabBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isFocused) private var focused
    var body: some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : Color.white)
            .background(focused ? Color.white : selected ? Color.white.opacity(0.24) : .clear, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
#endif

private struct SearchNativeField: ViewModifier {
    @Binding var query: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            content
        } else {
            content.vividSearchable(text: $query, prompt: prompt)
        }
        #else
        content.vividSearchable(text: $query, prompt: prompt)
        #endif
    }
}
