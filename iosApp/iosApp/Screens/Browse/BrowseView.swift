import SwiftUI

/// Browse/catalog screen with grid display and filters — Plezy style.
struct BrowseView: View {
    let libraryId: Int?
    var title: String? = "Browse"
    var showsSearchShortcut = true
    var libraryType: String? = nil

    @State private var viewModel = BrowseViewModel()
    @State private var showFilters = false
    @Environment(AppRouter.self) private var router

    @ViewBuilder
    var body: some View {
        if let title {
            rootContent
                .navigationTitle(title)
                .vividNavigationTitleDisplayMode(.large)
        } else {
            rootContent
        }
    }

    private var rootContent: some View {
        Group {
            if !viewModel.items.isEmpty {
                scrollContent
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadItems(reset: true) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                emptyContent
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) {
            // Grid is painted from cache but the server can't be reached —
            // flag the staleness instead of letting refresh fail silently.
            if ConnectionMonitor.shared.isOffline, !viewModel.items.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, VividTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .sheet(isPresented: $showFilters) {
            FilterView(viewModel: viewModel)
        }
        .task(id: BrowseConfigurationID(libraryId: libraryId, libraryType: libraryType)) {
            guard await viewModel.configure(libraryId: libraryId, libraryType: libraryType) else { return }
            await viewModel.loadItems(reset: true)
            await viewModel.loadFacetsIfNeeded()
        }
        .refreshable {
            await viewModel.loadItems(reset: true)
        }
    }

    // MARK: - Content

    private var emptyContent: some View {
        ScrollView {
            VStack(spacing: VividTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                EmptyStateView(
                    icon: "film",
                    title: "No items found",
                    subtitle: "Try adjusting your filters"
                )
                .frame(minHeight: 320)
                .padding(.horizontal, VividTheme.padding)
            }
            .frame(maxWidth: .infinity)
        }
        .reportsPageChromeScroll()
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: VividTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    forcesThreeColumnsOnPhone: libraryId != nil,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onLoadMore: {
                        Task { await viewModel.loadItems() }
                    }
                )
                .padding(.horizontal, VividTheme.padding)
            }
        }
        .reportsPageChromeScroll()
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        Button {
            router.navigate(to: .search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.vividSecondaryText)
                Text("Search...")
                    .foregroundColor(.vividSecondaryText)
                Spacer()
            }
            .font(.vividBody)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                    .fill(Color.vividSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                            .stroke(Color.vividOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, VividTheme.padding)
    }

    // MARK: - Control bar (Sort + Filter)

    private var controlBar: some View {
        HStack(spacing: 9) {
            sortMenu
            #if os(iOS)
            nativeFilterMenu
            #else
            Button { showFilters = true } label: {
                controlChip(
                    icon: "line.3.horizontal.decrease",
                    text: "Filter",
                    badge: viewModel.filterState.activeFacetCount
                )
            }
            .buttonStyle(.plain)
            #endif
            Spacer(minLength: 0)
            #if os(iOS)
            alphabetMenu
            #endif
        }
        .padding(.horizontal, VividTheme.padding)
    }

    #if os(iOS)
    private var nativeFilterMenu: some View {
        Menu {
            if viewModel.facetsLoadFailed {
                Text("Couldn’t load filter options")
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await viewModel.loadFacetsIfNeeded() }
                }
                Divider()
            } else if viewModel.isLoadingFacets {
                Text("Loading filter options…")
            }
            ForEach(CatalogFacet.available(for: viewModel.mediaType), id: \.self) { facet in
                let options = (viewModel.facets ?? CatalogFacets()).optionPairs(for: facet, hasProfile: AuthService.shared.profileId?.isEmpty == false)
                if !options.isEmpty {
                    Menu(facet.title) {
                        ForEach(options, id: \.value) { option in
                            Toggle(option.label, isOn: Binding(
                                get: { viewModel.filterState.isSelected(facet, value: option.value) },
                                set: { _ in
                                    var next = viewModel.filterState
                                    next.toggle(facet, value: option.value)
                                    Task { await viewModel.apply(next) }
                                }
                            ))
                        }
                    }
                }
            }
            Divider()
            if MediaServerProvider.active != .emby {
            Toggle("Match all filters", isOn: Binding(
                get: { viewModel.filterState.matchAll },
                set: { value in
                    var next = viewModel.filterState
                    next.matchAll = value
                    Task { await viewModel.apply(next) }
                }
            ))
            }
            Toggle("Remember filters", isOn: Binding(
                get: { viewModel.preserveEnabled },
                set: { viewModel.setPreserveEnabled($0) }
            ))
            Button("Reset filters") { Task { await viewModel.resetFilters() } }
                .disabled(!viewModel.filterState.canResetFilters)
        } label: {
            controlChip(icon: "line.3.horizontal.decrease", text: "Filter", badge: viewModel.filterState.activeFacetCount)
        }
    }

    private var alphabetMenu: some View {
        Menu {
            ForEach(["All", "#"] + (65...90).compactMap { UnicodeScalar($0).map(String.init) }, id: \.self) { letter in
                Button {
                    var next = viewModel.filterState
                    next.namePrefix = letter == "All" ? nil : letter
                    next.sort = .title
                    next.order = .asc
                    Task { await viewModel.apply(next) }
                } label: {
                    if (viewModel.filterState.namePrefix ?? "All") == letter {
                        Label(letter, systemImage: "checkmark")
                    } else { Text(letter) }
                }
            }
        } label: {
            Text(viewModel.filterState.namePrefix ?? "A–Z")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .vividGlass(in: Capsule())
        }
        .accessibilityLabel("A–Z, \(viewModel.filterState.namePrefix ?? "All")")
    }
    #endif

    private var sortMenu: some View {
        Menu {
            ForEach(CatalogSortKey.available(for: viewModel.mediaType), id: \.self) { key in
                Button {
                    Task { await viewModel.setSort(key) }
                } label: {
                    if viewModel.filterState.sort == key {
                        Label(
                            key.label,
                            systemImage: viewModel.filterState.effectiveOrder == .asc ? "arrow.up" : "arrow.down"
                        )
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            controlChip(
                icon: "arrow.up.arrow.down",
                text: "Sort",
                trailing: viewModel.filterState.sort.directionLabel(for: viewModel.filterState.effectiveOrder)
            )
        }
    }

    private func controlChip(icon: String, text: String, trailing: String? = nil, badge: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.vividBody)
            if let trailing {
                Text(trailing)
                    .font(.vividCaption)
                    .foregroundColor(.vividSecondaryText)
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.vividBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.vividOnSurface))
            }
        }
        .foregroundColor(.vividOnSurface)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .vividGlass(in: .capsule)
    }

    // MARK: - Active Filters

    private var hasActiveFilters: Bool { viewModel.hasActiveFilters }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.filterState.activeChips()) { chip in
                    filterChip(label: chip.label) {
                        Task { await viewModel.removeChip(chip) }
                    }
                }
            }
            .padding(.horizontal, VividTheme.padding)
        }
    }

    private func filterChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.vividCaption)
                .foregroundColor(.vividOnSurface)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.vividSecondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .vividGlass(in: .capsule)
    }
}

private struct BrowseConfigurationID: Hashable {
    let libraryId: Int?
    let libraryType: String?
}
