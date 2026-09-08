import SwiftUI
#if os(iOS)
import UIKit

private struct SearchPresentationReadyObserver: UIViewControllerRepresentable {
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onReady = onReady
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onReady = onReady
    }

    final class Controller: UIViewController {
        var onReady: (() -> Void)?
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let transitionCoordinator,
               transitionCoordinator.animate(alongsideTransition: nil, completion: { [weak self] transition in
                   if !transition.isCancelled { self?.onReady?() }
               }) { return }
            onReady?()
        }
    }
}
#endif

/// Full-screen search with debounced query and grid results — Plezy style.
struct SearchView: View {
    @State private var viewModel = SearchViewModel()
    @State private var requestsViewModel = RequestSearchSectionViewModel()
    #if os(tvOS) || os(iOS)
    @State private var seerr = TVSeerrConnectionStore.shared
    #endif
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    @State private var hasRequestedSearchFocus = false
    #endif
    private let usesTVTopMenuInset: Bool

    init(usesTVTopMenuInset: Bool = true) {
        self.usesTVTopMenuInset = usesTVTopMenuInset
    }

    var body: some View {
        ScrollView {
            VStack(spacing: VividTheme.padding) {
                if shouldShowFilters {
                    mediaTypeFilter
                    #if os(tvOS)
                        .padding(.horizontal, VividTheme.padding)
                        // The picker is a centered 760pt pill inside a
                        // 1600pt column. Stretch its focus section across
                        // the full row so up-moves from the grid's outer
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
            .padding(.horizontal, VividTheme.padding)
            #if os(tvOS)
            .padding(.top, usesTVTopMenuInset ? TVTopMenuLayout.contentTopInset : VividTheme.padding)
            #else
            .padding(.top, VividTheme.smallPadding)
            #endif
#if os(tvOS)
            .vividFormWidth(tvSearchContentWidth)
#endif
        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .safeAreaPadding(.horizontal, tvSearchSafeHorizontalPadding)
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
        .vividSearchable(text: $viewModel.query, prompt: searchPrompt)
        #if os(iOS)
        .searchFocused($isSearchFieldFocused)
        .background {
            SearchPresentationReadyObserver {
                guard !hasRequestedSearchFocus else { return }
                hasRequestedSearchFocus = true
                isSearchFieldFocused = true
            }.frame(width: 0, height: 0)
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
            VStack(alignment: .leading, spacing: VividTheme.padding) {
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
    /// Search needs a balanced horizontal inset so the page body clears the
    /// collapsed sidebar without shifting the whole screen right.
    private var tvSearchSafeHorizontalPadding: CGFloat { 110 }

    /// Search needs a centered column so the segmented media-type pill and
    /// the poster grid stay visually aligned while still clearing the
    /// collapsed sidebar affordance.
    private var tvSearchContentWidth: CGFloat { 1600 }

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
