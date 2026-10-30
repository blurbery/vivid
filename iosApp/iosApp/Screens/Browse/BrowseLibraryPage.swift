import SwiftUI

/// One library's catalogue, with sort, filter and letter menus above a
/// poster grid. Shown inside the Libraries tab on iPhone and iPad.
struct BrowseView: View {
    private let libraryId: Int?
    private let libraryType: String?

    #if os(iOS)
    @State private var model = Model()
    @Environment(AppRouter.self) private var router
    #endif

    /// `title` is accepted for callers' sake and not shown.
    init(libraryId: Int?, title: String? = nil, libraryType: String? = nil) {
        self.libraryId = libraryId
        self.libraryType = libraryType
    }

    #if os(iOS)
    private struct Configuration: Equatable {
        let libraryId: Int?
        let libraryType: String?
    }

    private var isOffline: Bool { ConnectionMonitor.shared.isOffline }

    var body: some View {
        content
            .vividBackground()
            .overlay(alignment: .top) {
                if isOffline && !model.items.isEmpty {
                    ServerUnreachablePill()
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isOffline)
            .refreshable { await model.load(reset: true) }
            .task(id: Configuration(libraryId: libraryId, libraryType: libraryType)) {
                guard await model.configure(libraryId: libraryId, libraryType: libraryType) else { return }
                await model.load(reset: true)
                await model.loadFacetsIfNeeded()
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.items.isEmpty {
            ScrollView(.vertical) {
                VStack(spacing: 16) {
                    controls
                    CatalogGrid(
                        items: model.items,
                        isLoading: model.isLoading,
                        hasMore: model.hasMore,
                        forcesThreeColumnsOnPhone: libraryId != nil,
                        onItemTap: { router.navigate(to: Route.itemDetail(browseItem: $0)) },
                        onLoadMore: { Task { await model.load(reset: false) } }
                    )
                    .padding(.horizontal, 16)
                }
            }
            .reportsPageChromeScroll()
        } else if let error = model.error {
            ErrorView(state: error, onRetry: { Task { await model.load(reset: true) } })
        } else if model.isLoading {
            Color.clear
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 16) {
                    controls
                    EmptyStateView(icon: "film", title: "No items found", subtitle: "Try adjusting your filters")
                        .frame(minHeight: 320)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity)
            }
            .reportsPageChromeScroll()
        }
    }

    /// The menus row, and the chips for active filters below it.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 9) {
            sortMenu
            filterMenu
            Spacer(minLength: 0)
            letterMenu
        }
        .padding(.horizontal, 16)
        if model.filters.hasActiveFilters {
            chipRow
        }
    }

    // MARK: Menus

    private func capsuleLabel(
        systemImage: String,
        title: LocalizedStringKey,
        detail: String? = nil,
        badge: Int = 0
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.vividBody)
            if let detail {
                Text(verbatim: detail)
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
            }
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.vividBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.vividOnSurface))
            }
        }
        .foregroundStyle(Color.vividOnSurface)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .vividGlass(in: .capsule)
    }

    private var sortMenu: some View {
        let filters = model.filters
        return Menu {
            ForEach(CatalogSortKey.available(for: model.mediaType), id: \.self) { key in
                Button {
                    Task { await model.sort(by: key) }
                } label: {
                    if key == filters.sort {
                        Label(key.label, systemImage: filters.effectiveOrder == .asc ? "arrow.up" : "arrow.down")
                    } else {
                        Text(verbatim: key.label)
                    }
                }
            }
        } label: {
            capsuleLabel(
                systemImage: "arrow.up.arrow.down",
                title: "Sort",
                detail: filters.sort.directionLabel(for: filters.effectiveOrder)
            )
        }
    }

    private var filterMenu: some View {
        Menu {
            if model.facetsFailed {
                Text("Couldn’t load filter options")
                Button {
                    Task { await model.loadFacetsIfNeeded() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                Divider()
            } else if model.isLoadingFacets {
                Text("Loading filter options…")
            }
            facetMenus
            Divider()
            if !MediaServerProvider.active.usesNativeUser {
                Toggle("Match all filters", isOn: binding(\.matchAll))
            }
            Toggle("Remember filters", isOn: Binding(
                get: { model.remembersFilters },
                set: { model.remembersFilters = $0 }
            ))
            Button("Reset filters") {
                Task { await model.resetFilters() }
            }
            .disabled(!model.filters.canResetFilters)
        } label: {
            capsuleLabel(
                systemImage: "line.3.horizontal.decrease",
                title: "Filter",
                badge: model.filters.activeFacetCount
            )
        }
    }

    @ViewBuilder
    private var facetMenus: some View {
        let facets = model.facets ?? CatalogFacets()
        let hasProfile = !(AuthService.shared.profileId ?? "").isEmpty
        ForEach(CatalogFacet.available(for: model.mediaType), id: \.self) { facet in
            let options = facets.optionPairs(for: facet, hasProfile: hasProfile)
            if !options.isEmpty {
                Menu(facet.title) {
                    ForEach(options.indices, id: \.self) { index in
                        let option = options[index]
                        Toggle(option.label, isOn: Binding(
                            get: { model.filters.isSelected(facet, value: option.value) },
                            set: { _ in
                                var state = model.filters
                                state.toggle(facet, value: option.value)
                                Task { await model.apply(state) }
                            }
                        ))
                    }
                }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CatalogFilterState, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.filters[keyPath: keyPath] },
            set: { value in
                var state = model.filters
                state[keyPath: keyPath] = value
                Task { await model.apply(state) }
            }
        )
    }

    /// All, then `#` and A to Z.
    private static let letters: [String?] = [nil, "#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }

    private var letterMenu: some View {
        let prefix = model.filters.namePrefix
        return Menu {
            ForEach(Self.letters, id: \.self) { letter in
                Button {
                    var state = model.filters
                    state.namePrefix = letter
                    state.sort = .title
                    state.order = .asc
                    Task { await model.apply(state) }
                } label: {
                    letterLabel(letter, isCurrent: letter == prefix)
                }
            }
        } label: {
            Text(verbatim: prefix ?? String(localized: "A–Z"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .vividGlass(in: Capsule())
        }
        .accessibilityLabel(Text("A–Z, \(prefix ?? String(localized: "All"))"))
    }

    @ViewBuilder
    private func letterLabel(_ letter: String?, isCurrent: Bool) -> some View {
        let title = letter.map { Text(verbatim: $0) } ?? Text("All")
        if isCurrent {
            Label { title } icon: { Image(systemName: "checkmark") }
        } else {
            title
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.filters.activeChips) { chip in
                    HStack(spacing: 4) {
                        Text(verbatim: chip.label)
                            .font(.vividCaption)
                            .foregroundStyle(Color.vividOnSurface)
                        Button {
                            Task { await model.remove(chip) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.vividSecondaryText)
                        }
                        .accessibilityLabel(Text("Remove \(chip.label)"))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .vividGlass(in: .capsule)
                }
            }
            .padding(.horizontal, 16)
        }
    }
    #else
    /// Apple TV browses libraries in its own grid; this exists so the
    /// shared routes compile, and draws nothing.
    var body: some View {
        EmptyView()
    }
    #endif
}
