#if os(tvOS)
import SwiftUI

/// The two kinds of library the Library tab offers.
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
    /// One library, opened from the Library tab: its name, the Sort, Filter
    /// and A–Z row, then its poster grid.
    struct LibraryPage: View {
        let library: Library

        @State private var model: TVLibraryGridViewModel?
        @State private var lastControl: LibraryControl = .sort
        @Environment(AppRouter.self) private var router

        /// Movie and series libraries ask for their own type, as the Movies
        /// and Series pages did; a mixed library browses every type.
        private var libraryType: String {
            if library.isMixedLibrary { return library.type }
            return library.isSeriesLibrary ? "series" : "movies"
        }

        private var isSeriesLibrary: Bool { VividMediaType.isSeries(libraryType) }

        var body: some View {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 32) {
                    Text(verbatim: library.name)
                        .font(.system(size: 36, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 80)
                        .padding(.top, 80)
                        .accessibilityAddTraits(.isHeader)
                    if let model {
                        LibraryControlRow(model: model, lastControl: $lastControl)
                        content(model)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, minHeight: 400)
                    }
                }
                .padding(.bottom, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Theme Mode Adaptive carries on from the Library tab, and this
            // library's posters drive its colour while the page is on show.
            .background { TVAdaptiveBackdrop(opensInCurrentColour: true) }
            // Owns its 80pt insets itself, like the root pages.
            .ignoresSafeArea(edges: [.top, .horizontal])
            .onAppear {
                TVAdaptiveAmbience.shared.isOnLibraryPage = true
                ensureModel()
            }
            .onDisappear { TVAdaptiveAmbience.shared.isOnLibraryPage = false }
            .task(id: library.id) { await openLibrary() }
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
                    icon: isSeriesLibrary ? "tv" : "film.stack",
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

        // MARK: Loading

        private func ensureModel() {
            guard model?.libraryId != library.id else { return }
            model = TVLibraryGridViewModel(libraryId: library.id, libraryType: libraryType)
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

        /// Read from the library when the row appears and whenever the shown
        /// library changes.
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
            .onChange(of: model.libraryId, initial: true) { preserves = model.preserveEnabled }
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
