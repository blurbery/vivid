#if os(tvOS)
import SwiftUI

/// The Movies and Series top-level pages and the libraries each one shows.
enum TVLibraryTabType: String, CaseIterable, Hashable {
    case movies
    case series

    var title: String {
        switch self {
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        }
    }

    /// Mixed libraries count for both. Emby and Jellyfin name movie
    /// libraries in the singular.
    func matches(_ library: Library) -> Bool {
        switch self {
        case .movies:
            library.type == "movies"
                || library.isMixedLibrary
                || (MediaServerProvider.active.usesNativeUser && library.type == "movie")
        case .series:
            library.isSeriesLibrary || library.isMixedLibrary
        }
    }
}

extension TVMainTabView {
    /// A Movies or Series page: library sub-tabs, the Sort, Filter and A–Z
    /// row, then the shown library's poster grid.
    struct LibraryTypePage: View {
        let type: TVLibraryTabType
        let library: Library
        let libraries: [Library]
        let focusRequest: Int
        let isTopMenuFocused: Bool
        let onTopMenuFocusRequest: () -> Void
        let onChooseLibrary: (Library) -> Void

        @State private var model: TVLibraryGridViewModel?
        @State private var loadedLibraryId: Int?
        @State private var lastAppliedFocusRequest = 0
        @State private var lastControl: LibraryControl = .sort
        @FocusState private var focusedLibraryId: Int?
        @Environment(AppRouter.self) private var router

        private var libraryType: String { type == .movies ? "movies" : "series" }
        private var isSeriesPage: Bool { VividMediaType.isSeries(libraryType) }

        var body: some View {
            ZStack {
                HStack(spacing: 0) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 32) {
                            Color.clear.frame(height: 144)
                            libraryTabs
                            if let model {
                                LibraryControlRow(model: model, lastControl: $lastControl)
                                content(model)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 400)
                            }
                        }
                        .padding(.bottom, 48)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
            }
            .onAppear {
                ensureModel()
                handDownFocus()
            }
            .task(id: library.id) { await openLibrary() }
            .onChange(of: focusRequest) { handDownFocus() }
            .onChange(of: isTopMenuFocused) {
                if !isTopMenuFocused { handDownFocus() }
            }
        }

        // MARK: Library sub-tabs

        private var libraryTabs: some View {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(libraries) { option in
                            libraryTab(option)
                        }
                    }
                }
                .scrollClipDisabled()
                .padding(.horizontal, 80)
                .focusSection()
                .defaultFocus($focusedLibraryId, library.id, priority: .userInitiated)
                .onMoveCommand { direction in
                    if direction == .up { onTopMenuFocusRequest() }
                }
                .onChange(of: focusedLibraryId) {
                    if let focusedLibraryId { proxy.scrollTo(focusedLibraryId, anchor: .center) }
                }
            }
        }

        private func libraryTab(_ option: Library) -> some View {
            let isShown = option.id == library.id
            let isFocused = focusedLibraryId == option.id
            return Button { onChooseLibrary(option) } label: {
                Text(verbatim: tabLabel(for: option))
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isFocused ? Color.black : Color.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(isFocused ? Color.white : Color.white.opacity(isShown ? 0.18 : 0.06))
                    )
            }
            .buttonStyle(.vividFlat)
            .focused($focusedLibraryId, equals: option.id)
            .id(option.id)
            .accessibilityLabel(Text(verbatim: option.name))
            .accessibilityAddTraits(isShown ? .isSelected : [])
        }

        /// The shortened label, unless another library in the row shortens
        /// to the same text; then the full name.
        private func tabLabel(for option: Library) -> String {
            let short = Self.shortLabel(option.name, isSeriesPage: isSeriesPage)
            let collides = libraries.contains { other in
                other.id != option.id
                    && Self.shortLabel(other.name, isSeriesPage: isSeriesPage).localizedCaseInsensitiveCompare(short) == .orderedSame
            }
            return collides ? option.name : short
        }

        /// Drops a leading "Movies", "TV Shows" and the like when a separator
        /// follows it.
        static func shortLabel(_ name: String, isSeriesPage: Bool) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = isSeriesPage ? #"series|tv\s+shows?|shows?"# : #"movies?"#
            let separators = "[\\s:\u{2013}\u{2014}_\\-]+"
            guard let match = trimmed.range(
                of: "^(?:\(words))\(separators)",
                options: [.regularExpression, .caseInsensitive]
            ) else { return trimmed }
            let rest = trimmed[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? trimmed : rest
        }

        // MARK: Content

        @ViewBuilder
        private func content(_ model: TVLibraryGridViewModel) -> some View {
            if model.items.isEmpty && model.isLoading {
                Color.clear.frame(maxWidth: .infinity, minHeight: 400)
            } else if model.items.isEmpty, let error = model.error {
                ErrorView(state: error, onRetry: { Task { await model.loadInitial() } })
            } else if model.items.isEmpty {
                EmptyStateView(
                    icon: isSeriesPage ? "tv" : "film.stack",
                    title: "No titles match",
                    subtitle: "Try a different letter or filter."
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            } else {
                TVCatalogGrid(
                    items: model.items,
                    isLoading: model.isLoading,
                    hasMore: model.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onNearEnd: { _ in Task { await model.loadMoreIfNeeded() } },
                    fixedColumnCount: 7
                )
                .padding(.horizontal, 80)
            }
        }

        // MARK: Loading and focus

        private func ensureModel() {
            guard loadedLibraryId != library.id else { return }
            model = TVLibraryGridViewModel(libraryId: library.id, libraryType: libraryType)
            loadedLibraryId = library.id
        }

        /// Paints the cached page, then refetches it once per visit.
        private func openLibrary() async {
            ensureModel()
            guard let model else { return }
            async let facets: Void = model.loadFacetsIfNeeded()
            if model.items.isEmpty {
                await model.loadInitial()
            } else if !model.hasRequestedFirstPage {
                await model.refreshFirstPage()
            }
            await facets
        }

        private func handDownFocus() {
            guard focusRequest > 0, focusRequest != lastAppliedFocusRequest, !isTopMenuFocused else { return }
            focusedLibraryId = library.id
            lastAppliedFocusRequest = focusRequest
        }
    }

    enum LibraryControl: Hashable {
        case sort
        case filter
        case alphabet
    }

    /// Sort, Filter and A–Z for the shown library, as native menus.
    struct LibraryControlRow: View {
        let model: TVLibraryGridViewModel
        @Binding var lastControl: LibraryControl

        /// Read from the library when the row first appears.
        @State private var preserves = false
        @FocusState private var focused: LibraryControl?

        var body: some View {
            HStack(spacing: 16) {
                sortMenu
                    .focused($focused, equals: .sort)
                filterControl
                    .focused($focused, equals: .filter)
                Spacer()
                TVAlphabetMenu(selected: model.filter.namePrefix) { letter in
                    Task { await model.jumpToPrefix(letter) }
                }
                .focused($focused, equals: .alphabet)
            }
            .font(.system(size: 24, weight: .medium))
            .padding(.horizontal, 80)
            .focusSection()
            .defaultFocus($focused, lastControl, priority: .userInitiated)
            .onChange(of: focused) {
                if let focused { lastControl = focused }
            }
            .onAppear { preserves = model.preserveEnabled }
        }

        // MARK: Sort

        private var sortMenu: some View {
            let filter = model.filter
            let direction = filter.sort.directionLabel(for: filter.effectiveOrder)
            return Menu {
                ForEach(CatalogSortKey.available(for: model.mediaType), id: \.self) { key in
                    Button {
                        Task { await model.setSort(key) }
                    } label: {
                        if key == filter.sort {
                            Label {
                                Text("\(key.label) · \(direction)")
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: key.label)
                        }
                    }
                }
            } label: {
                Label {
                    Text("Sort · \(filter.sort.label) \(direction)")
                } icon: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            .menuStyle(.button)
            .buttonStyle(TVBrowseControlPillStyle())
        }

        // MARK: Filter

        @ViewBuilder
        private var filterControl: some View {
            if model.facetsFailed {
                Button {
                    Task { await model.loadFacetsIfNeeded() }
                } label: {
                    if let reason = model.facetFailureReason {
                        Text("Retry filters · \(reason)")
                    } else {
                        Text("Retry filters")
                    }
                }
                .buttonStyle(TVBrowseControlPillStyle())
            } else {
                let count = model.filter.activeFacetCount
                Menu {
                    filterMenuContent
                } label: {
                    Label {
                        if count > 0 {
                            Text("Filter · \(count)")
                        } else {
                            Text("Filter")
                        }
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
                .menuStyle(.button)
                .buttonStyle(TVBrowseControlPillStyle(active: count > 0))
                .disabled(model.facets == nil)
                .accessibilityHint(model.facets == nil ? Text("Filter options are loading") : Text("Choose filters"))
            }
        }

        @ViewBuilder
        private var filterMenuContent: some View {
            if let facets = model.facets {
                ForEach(CatalogFacet.available(for: model.mediaType), id: \.self) { facet in
                    let options = facets.optionPairs(for: facet, hasProfile: AuthService.shared.hasProfile)
                    if !options.isEmpty {
                        Menu {
                            ForEach(options, id: \.value) { option in
                                Toggle(isOn: optionBinding(facet, value: option.value)) {
                                    Text(verbatim: option.label)
                                }
                                .menuActionDismissBehavior(.disabled)
                            }
                            Button {
                                var next = model.filter
                                next.clear(facet)
                                apply(next)
                            } label: {
                                Text("Clear \(facet.title)")
                            }
                            .disabled(model.filter.selectedValues(facet).isEmpty)
                        } label: {
                            Text(verbatim: facet.title)
                        }
                    }
                }
            }
            if !MediaServerProvider.active.usesNativeUser {
                Section {
                    Toggle("Match all selected filters", isOn: Binding(
                        get: { model.filter.matchAll },
                        set: { matchAll in
                            var next = model.filter
                            next.matchAll = matchAll
                            apply(next)
                        }
                    ))
                    .menuActionDismissBehavior(.disabled)
                } header: {
                    Text("Match")
                }
            }
            Section {
                Toggle("Preserve sort & filters", isOn: Binding(
                    get: { preserves },
                    set: { enabled in
                        preserves = enabled
                        model.setPreserveEnabled(enabled)
                    }
                ))
                .menuActionDismissBehavior(.disabled)
                Button("Reset filters") {
                    var next = model.filter
                    next.resetFilters()
                    apply(next)
                }
                .disabled(!model.filter.canResetFilters)
            }
        }

        private func optionBinding(_ facet: CatalogFacet, value: String) -> Binding<Bool> {
            Binding(
                get: { model.filter.isSelected(facet, value: value) },
                set: { isOn in
                    guard isOn != model.filter.isSelected(facet, value: value) else { return }
                    var next = model.filter
                    next.toggle(facet, value: value)
                    apply(next)
                }
            )
        }

        private func apply(_ filter: CatalogFilterState) {
            Task { await model.applyFilter(filter) }
        }
    }
}
#endif
