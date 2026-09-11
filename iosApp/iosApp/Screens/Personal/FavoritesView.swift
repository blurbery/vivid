import SwiftUI

#if os(iOS)
/// Saved titles share a fitted grid on iPhone and iPad, using extra columns
/// only when the current window has regular width.
struct IOSPersonalMediaPosterLayout: View {
    let items: [BrowseItem]
    let onUserStateChanged: (BrowseItem, MediaItemUserState) -> Void

    @Environment(AppRouter.self) private var router
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @State private var originID = UUID().uuidString
    @Environment(\.horizontalSizeClass) private var hSize

    private var columnCount: Int {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterCount(containerWidth: gridWidth)
        }
        return hSize == .regular && UIDevice.current.userInterfaceIdiom != .phone ? 5 : 3
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: columnCount
            ),
            spacing: 12
        ) {
            ForEach(items) { item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    action: {
                        router.navigate(to: .itemDetail(contentId: item.contentId))
                    },
                    contentId: item.contentId,
                    cardWidthOverride: cardWidthOverride,
                    mediaTypeLabel: VividMediaType.isMovieLibrary(item.type) ? "Movie" : "Series",
                    onUserStateChanged: { state in
                        onUserStateChanged(item, state)
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
        .environment(
            \.itemDetailBrowseSource,
            ItemDetailBrowseSource(
                originID: originID,
                contentIDs: items.map(\.contentId)
            )
        )
    }

    /// MediaCard scales overrides by the selected global preference. Cancel
    /// that scale, then cap the standard width to the measured grid cell.
    private var cardWidthOverride: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return AdaptiveColumns.tabletPosterWidth(containerWidth: gridWidth)
                / uiCustomization.cardPresentation.posterSize.scale
        }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columnCount,
            spacing: 8
        ) / uiCustomization.cardPresentation.posterSize.scale
    }

}
#endif

/// Grid of the user's favorited items.
struct FavoritesView: View {
    @Environment(\.forYouScrollHeader) private var scrollHeader
    let showsNavigationTitle: Bool
    let usesTVTopMenu: Bool
    var focusRequest: Int
    var isTopMenuFocused: Bool
    var onTopMenuFocusRequest: (() -> Void)?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var uiCustomization = UICustomizationPreferences.shared
    #if os(tvOS)
    @State private var selectedSection: FavoriteMediaSection = .movies
    @FocusState private var focusedSection: FavoriteMediaSection?
    @State private var lastAppliedFocusRequest = 0
    #endif
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        #if os(tvOS)
        return Array(
            repeating: GridItem(.flexible(), spacing: 40, alignment: .top),
            count: 8
        )
        #else
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
        #endif
    }

    init(
        showsNavigationTitle: Bool = true,
        usesTVTopMenu: Bool = false,
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil
    ) {
        self.showsNavigationTitle = showsNavigationTitle
        self.usesTVTopMenu = usesTVTopMenu
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
    }

    #if os(iOS)
    private var iosGridContent: some View {
        ScrollView {
            scrollHeader
            IOSPersonalMediaPosterLayout(items: items) { item, state in
                guard !state.isFavorite else { return }
                withAnimation { items.removeAll { $0.contentId == item.contentId } }
            }
            .padding(VividTheme.padding)
        }
        .reportsPageChromeScroll()
    }

    #endif

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty { scrollHeader }
        Group {
            if !items.isEmpty {
                #if os(iOS)
                iosGridContent
                #else
                gridContent
                #endif
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadFavorites() } })
            } else if isLoading {
                // tvOS: this is a pushed destination, so the top menu bar
                // isn't there to hold focus — without a focusable element
                // the remote goes dead until the grid renders.
                Color.clear
                #if os(tvOS)
                    .focusable()
                #endif
            } else {
                EmptyStateView(
                    icon: "heart",
                    title: "No favorites",
                    subtitle: "Tap the heart icon on any item to add it here"
                )
            }
        }
        }
        .background(Color.black.ignoresSafeArea())
        .modifier(PersonalListNavigationChrome(title: showsNavigationTitle ? "Favorites" : nil))
        .task {
            await loadFavorites()
        }
        .refreshable {
            await loadFavorites()
        }
        #if os(tvOS)
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: items.map(\.contentId)) { _, _ in applyFocusRequest(focusRequest) }
        #endif
    }

    @ViewBuilder
    private var gridContent: some View {
        #if os(tvOS)
        tvGridContent
        #else
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        thumbhash: item.posterThumbhash,
                        year: item.year,
                        userState: item.userState,
                        overlayData: OverlayData.from(item),
                        action: {
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        playAction: playAction(for: item),
                        contentId: item.contentId,
                        onUserStateChanged: { state in
                            guard !state.isFavorite else { return }
                            withAnimation {
                                items.removeAll { $0.contentId == item.contentId }
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(VividTheme.padding)
        }
        .reportsPageChromeScroll()
        #endif
    }

    #if os(tvOS)
    private var filteredItems: [BrowseItem] {
        items.filter(selectedSection.includes)
    }

    private var tvGridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                if usesTVTopMenu {
                    Text("Favorites")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(Color.vividOnSurface)
                }

                sectionSelector

                if filteredItems.isEmpty {
                    selectedSectionEmptyState
                } else {
                    LazyVGrid(
                        columns: columns,
                        alignment: .leading,
                        spacing: 60
                    ) {
                        ForEach(filteredItems) { item in
                            favoriteCard(for: item)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, VividTheme.safePadding)
            .padding(.top, usesTVTopMenu ? TVTopMenuLayout.contentTopInset : 20)
            .padding(.bottom, VividTheme.safePadding)
        }
    }

    private var sectionSelector: some View {
        HStack(spacing: 14) {
            ForEach(FavoriteMediaSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: VividTheme.normalDuration)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(FavoriteSectionPillStyle(isSelected: selectedSection == section))
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                .focused($focusedSection, equals: section)
            }

            Spacer(minLength: 0)
        }
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                onTopMenuFocusRequest?()
            }
        }
    }

    private var selectedSectionEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedSection == .movies ? "film" : "tv")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.vividOnSurface.opacity(0.34))

            Text("No favorite \(selectedSection.rawValue.lowercased())")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)

            Text("Add favorites from any detail page and they will appear here.")
                .font(.system(size: 22))
                .foregroundStyle(Color.vividSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func favoriteCard(for item: BrowseItem) -> some View {
        MediaCard(
            title: item.title,
            posterUrl: item.posterUrl ?? "",
            thumbhash: item.posterThumbhash,
            year: item.year,
            userState: item.userState,
            overlayData: OverlayData.from(item),
            action: {
                router.navigate(to: .itemDetail(browseItem: item))
            },
            playAction: playAction(for: item),
            contentId: item.contentId,
            cardWidthOverride: tvCardWidthOverride,
            mediaTypeLabel: VividMediaType.isMovieLibrary(item.type) ? "Movie" : "Series",
            onUserStateChanged: { state in
                guard !state.isFavorite else { return }
                withAnimation(.easeInOut(duration: VividTheme.normalDuration)) {
                    items.removeAll { $0.contentId == item.contentId }
                }
            }
        )
    }

    /// `MediaCard` applies the global size preference after this override;
    /// divide it out so the final eight-across grid stays at 176 points.
    private var tvCardWidthOverride: CGFloat {
        VividTheme.Skyline.densePosterCardWidth
            / uiCustomization.cardPresentation.posterSize.scale
    }

    private func applyFocusRequest(_ request: Int) {
        guard usesTVTopMenu,
              request > 0,
              request != lastAppliedFocusRequest,
              !isTopMenuFocused,
              !items.isEmpty else { return }
        lastAppliedFocusRequest = request
        focusedSection = selectedSection
    }
    #endif

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard VividMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
    }

    private func loadFavorites() async {
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.favorites) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response: CatalogResponse = try await VividAPI.shared.get(
                "/api/v1/favorites"
            )
            ResponseCache.shared.set(response, for: CacheKey.favorites)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}

#if os(tvOS)
private enum FavoriteMediaSection: String, CaseIterable, Identifiable {
    case movies = "Movies"
    case tvShows = "TV Shows"

    var id: Self { self }

    func includes(_ item: BrowseItem) -> Bool {
        switch self {
        case .movies:
            return VividMediaType.isMovieLibrary(item.type)
        case .tvShows:
            return VividMediaType.isSeries(item.type)
                || item.type.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("episode") == .orderedSame
        }
    }
}

private struct FavoriteSectionPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        FavoriteSectionPillBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct FavoriteSectionPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .foregroundStyle(isFocused ? Color.vividBackground : Color.vividOnSurface)
            .background(
                Capsule().fill(
                    isFocused
                        ? Color.vividOnSurface
                        : (isSelected
                            ? Color.vividChromeSelectedFill
                            : Color.vividChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused
                        ? Color.clear
                        : (isSelected
                            ? Color.vividChromeSelectedBorder
                            : Color.vividChromeRestingBorder),
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }
}
#endif
