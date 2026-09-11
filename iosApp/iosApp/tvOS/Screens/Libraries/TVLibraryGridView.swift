#if os(tvOS)
import SwiftUI

/// Grid + letter-rail view for a single library on tvOS.
///
/// Can be entered either from the landing page (with a pre-applied filter,
/// e.g. genre=Action) or directly (`TVLibraryFilter.none`) for a full browse.
/// The letter rail always sits on the right and modifies `namePrefix` on the
/// current filter, so "Action / T" is a valid composite state.
struct TVLibraryGridView: View {
    let libraryId: Int
    let libraryName: String
    let libraryType: String
    let initialFilter: CatalogFilterState
    let subtitle: String?
    /// Pushed full-screen entries render the big library header; Skyline
    /// pill embeds hide it — the top bar + pill row already say where the
    /// user is.
    let showsHeader: Bool
    /// The A–Z jump rail only makes sense for title-sorted browsing; the
    /// Recently Added pill turns it off.
    let showsAlphabetRail: Bool
    /// Top inset before the first content. Pushed entries keep the compact
    /// default; pill embeds pass the Skyline chrome clearance.
    let topContentInset: CGFloat
    /// Focus hand-down token from the root shell. Embedded Browse tabs use this
    /// to land on the control row after the top menu hands focus to content.
    let focusRequest: Int
    /// Deferred focus claims are dropped while the top menu is focused so async
    /// page work never yanks focus back into Browse.
    let isTopMenuFocused: Bool
    /// Boundary hand-up from the control row to the root top menu. Nil for
    /// pushed grid routes where the root menu is not visible.
    let onTopMenuFocusRequest: (() -> Void)?

    var libraryTabs: [Library] = []
    var onSelectLibrary: ((Library) -> Void)? = nil
    @FocusState private var focusedLibraryId: Int?

    @State private var viewModel: TVLibraryGridViewModel
    @State private var loadedLibraryId: Int
    @State private var selectedPrefix: String? = nil
    @State private var controlsOwnFocus = false
    @State private var returnControl: TVBrowseControlFocus = .sort
    @State private var controlFocusRequest = 0
    @State private var gridFocusRequest = 0
    @State private var gridOwnsFocus = false
    @State private var lastShellFocusRequest = 0

    @Environment(AppRouter.self) private var router

    init(
        libraryId: Int,
        libraryName: String,
        libraryType: String,
        initialFilter: CatalogFilterState = .none,
        subtitle: String? = nil,
        showsHeader: Bool = true,
        showsAlphabetRail: Bool = true,
        topContentInset: CGFloat = VividTheme.smallPadding,
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil,
        libraryTabs: [Library] = [],
        onSelectLibrary: ((Library) -> Void)? = nil
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.libraryType = libraryType
        self.initialFilter = initialFilter
        self.subtitle = subtitle
        self.showsHeader = showsHeader
        self.showsAlphabetRail = showsAlphabetRail
        self.topContentInset = topContentInset
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
        self.libraryTabs = libraryTabs
        self.onSelectLibrary = onSelectLibrary
        _loadedLibraryId = State(initialValue: libraryId)
        _viewModel = State(initialValue: TVLibraryGridViewModel(
            libraryId: libraryId,
            libraryType: libraryType,
            initialFilter: initialFilter
        ))
        _selectedPrefix = State(initialValue: initialFilter.namePrefix)
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                gridColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()


            }
        }
        .vividBackground()
        .task(id: libraryId) {
            if loadedLibraryId != libraryId {
                viewModel.cancelPosterPrefetch()
                viewModel = TVLibraryGridViewModel(
                    libraryId: libraryId,
                    libraryType: libraryType,
                    initialFilter: initialFilter
                )
                loadedLibraryId = libraryId
                selectedPrefix = viewModel.filter.namePrefix
            }
            let model = viewModel
            async let facetLoad: Void = model.loadFacetsIfNeeded()
            if model.items.isEmpty {
                await model.loadInitial()
            }
            await facetLoad
        }
        .onChange(of: viewModel.filter.namePrefix) { _, prefix in selectedPrefix = prefix }
        .onAppear { noteShellFocusRequest(focusRequest) }
        .onDisappear { viewModel.cancelPosterPrefetch() }
        .onChange(of: focusRequest) { _, request in noteShellFocusRequest(request) }
        .onChange(of: isTopMenuFocused) { _, focused in
            if !focused { noteShellFocusRequest(focusRequest) }
        }
    }

    // MARK: - Grid column

    private var gridColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if showsHeader {
                    header
                        .padding(.horizontal, VividTheme.safePadding)
                        .padding(.top, topContentInset)
                } else {
                    Color.clear
                        .frame(height: topContentInset)
                }

                if !libraryTabs.isEmpty {
                    libraryTabRow.disabled(controlsOwnFocus)
                }

                TVBrowseControlRow(
                    mediaType: viewModel.mediaType,
                    filter: viewModel.filter,
                    facets: viewModel.facets,
                    isLoadingFacets: viewModel.isLoadingFacets,
                    facetsLoadFailed: viewModel.facetsLoadFailed,
                    facetsFailureReason: viewModel.facetsFailureReason,
                    showsAlphabetMenu: showsAlphabetRail && viewModel.filter.sort == .title,
                    preserveEnabled: viewModel.preserveEnabled,
                    focusRequest: controlFocusRequest,
                    returnControl: returnControl,
                    onFocus: { control in
                        controlsOwnFocus = true
                        returnControl = control
                        gridOwnsFocus = false
                    },
                    onMoveUp: {
                        controlsOwnFocus = false
                        if libraryTabs.isEmpty { onTopMenuFocusRequest?() }
                        else { focusedLibraryId = libraryId }
                    },
                    onMoveDown: claimGridFocus,
                    onSort: { key in Task { await viewModel.setSort(key) } },
                    onFilterChange: { filter in Task { await viewModel.applyFilter(filter) } },
                    onPreserveChange: viewModel.setPreserveEnabled,
                    onLoadFacets: { Task { await viewModel.loadFacetsIfNeeded() } },
                    onSelectPrefix: { prefix in Task { await viewModel.jumpToPrefix(prefix) } }
                )
                .padding(.horizontal, VividTheme.safePadding)

                if viewModel.items.isEmpty && viewModel.isLoading {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if let error = viewModel.error, viewModel.items.isEmpty {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadInitial() } })
                } else if viewModel.items.isEmpty {
                    EmptyStateView(
                        icon: emptyGridIcon,
                        title: "No titles match",
                        subtitle: "Try a different letter or filter."
                    )
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    TVCatalogGrid(
                        items: viewModel.items,
                        isLoading: viewModel.isLoading,
                        hasMore: viewModel.hasMore,
                        onItemTap: { item in
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        onNearEnd: { _ in
                            Task { await viewModel.loadMoreIfNeeded() }
                        },
                        fixedColumnCount: libraryTabs.isEmpty ? nil : 7,
                        focusRequest: gridOwnsFocus && !isTopMenuFocused ? gridFocusRequest : 0,
                        onFirstRowMoveUp: { gridOwnsFocus = false; controlFocusRequest += 1 },
                        onRowVisibilityChange: { range, isVisible in
                            if libraryTabs.isEmpty { viewModel.setPosterRowVisibility(range, isVisible: isVisible) }
                        }
                    )
                    .disabled(controlsOwnFocus)
                    .padding(.horizontal, VividTheme.safePadding)
                }
            }
            .padding(.bottom, 48)
        }
    }

    private var libraryTabRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(libraryTabs) { library in
                        let focused = focusedLibraryId == library.id
                        Button { onSelectLibrary?(library) } label: {
                            Text(libraryTabTitle(library))
                                .font(.system(size: 26, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(focused ? Color.black : .white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 10)
                                .background(
                                    focused ? Color.white : Color.white.opacity(library.id == libraryId ? 0.18 : 0.06),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.vividFlat)
                        .focused($focusedLibraryId, equals: library.id)
                        .accessibilityLabel(library.name)
                        .accessibilityAddTraits(library.id == libraryId ? .isSelected : [])
                        .id("\(libraryType):\(library.id)")
                    }
                }
            }
            .scrollClipDisabled()
            .onChange(of: focusedLibraryId) { _, id in
                if let id { proxy.scrollTo("\(libraryType):\(id)", anchor: .center) }
            }
            .onMoveCommand { direction in
                if direction == .up { onTopMenuFocusRequest?() }
                else if direction == .down { controlFocusRequest += 1 }
            }
            .focusSection()
        }
        .padding(.horizontal, VividTheme.safePadding)
    }

    private func libraryTabTitle(_ library: Library) -> String {
        let shortened = tvLibrarySubtabLabel(library.name, isSeries: VividMediaType.isSeries(libraryType))
        let hasCollision = libraryTabs.contains {
            $0.id != library.id
                && tvLibrarySubtabLabel($0.name, isSeries: VividMediaType.isSeries(libraryType)).localizedCaseInsensitiveCompare(shortened) == .orderedSame
        }
        return hasCollision ? library.name : shortened
    }

    // MARK: - Focus routing

    private func noteShellFocusRequest(_ request: Int) {
        guard request > 0, request != lastShellFocusRequest else { return }
        guard !isTopMenuFocused else { return }
        controlsOwnFocus = false
        gridOwnsFocus = false
        lastShellFocusRequest = request
        if libraryTabs.isEmpty {
            controlFocusRequest += 1
        } else {
            focusedLibraryId = libraryId
        }
    }

    private func claimGridFocus() {
        guard !viewModel.items.isEmpty else { return }
        controlsOwnFocus = false
        gridOwnsFocus = true
        gridFocusRequest += 1
    }

    private var emptyGridIcon: String {
        if VividMediaType.isSeries(libraryType) { return "tv" }
        return "film.stack"
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(libraryName)
                .font(.system(size: 64, weight: .bold))
                .foregroundColor(.vividOnSurface)

            if let prefix = selectedPrefix {
                Text(prefix == "#" ? "Titles starting with a number or symbol" : "Titles starting with \(prefix)")
                    .font(.vividHeadline)
                    .foregroundColor(.vividSecondaryText)
            } else if let subtitle {
                Text(subtitle)
                    .font(.vividHeadline)
                    .foregroundColor(.vividSecondaryText)
            } else if let total = totalLabel {
                Text(total)
                    .font(.vividHeadline)
                    .foregroundColor(.vividSecondaryText)
            }
        }
    }

    private var totalLabel: String? {
        guard !viewModel.items.isEmpty else { return nil }
        return viewModel.hasMore
            ? "\(viewModel.items.count)+ titles"
            : "\(viewModel.items.count) titles"
    }
}
#endif
