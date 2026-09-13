import SwiftUI

func libraryMatchesPrimaryMenuCategory(
    _ library: Library,
    category: PrimaryMenuBuiltin
) -> Bool {
    switch category {
    case .movies:
        return library.isMovieLibrary || library.isMixedLibrary
    case .series:
        return library.isSeriesLibrary || library.isMixedLibrary
    case .home, .forYou:
        return false
    }
}

private func sharesPrimaryMenuCategory(_ lhs: Library, _ rhs: Library) -> Bool {
    // Mixed libraries participate in both authored Movies and Series roots,
    // but a direct mixed-library root is its own scope. Treating its two
    // category memberships as sibling relationships would expose every movie
    // and series library from that direct root.
    if lhs.isMixedLibrary {
        return rhs.isMixedLibrary
    }
    let categories: [PrimaryMenuBuiltin] = [.movies, .series]
    return categories.contains {
        libraryMatchesPrimaryMenuCategory(lhs, category: $0)
            && libraryMatchesPrimaryMenuCategory(rhs, category: $0)
    }
}

func visibleLibrariesForRoot(
    _ libraries: [Library],
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?
) -> [Library] {
    if let fixedLibraryId {
        // A direct library root still requires the exact library to be
        // accessible, but exposes sibling libraries of the same media type
        // so the top selector can switch between them like media-type roots.
        guard let fixed = libraries.first(where: { $0.id == fixedLibraryId }) else {
            return []
        }
        return libraries.filter {
            $0.id == fixed.id || sharesPrimaryMenuCategory(fixed, $0)
        }
    }
    guard let category else {
        return libraries
    }
    return libraries.filter { libraryMatchesPrimaryMenuCategory($0, category: category) }
}

func libraryRootCanSwitch(fixedLibraryId: Int?, visibleLibraryCount: Int) -> Bool {
    visibleLibraryCount > 1
}

func resolvedLibraryIdForRoot(
    _ libraries: [Library],
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    storedLibraryId: Int,
    currentSelectionId: Int? = nil
) -> Int? {
    let visible = visibleLibrariesForRoot(
        libraries,
        category: category,
        fixedLibraryId: fixedLibraryId
    )
    if let fixedLibraryId {
        // Keep an in-session switch to a sibling library, but always land on
        // the requested library when entering the root fresh.
        if let current = currentSelectionId,
           visible.contains(where: { $0.id == current }) {
            return current
        }
        return visible.first(where: { $0.id == fixedLibraryId })?.id
    }
    if storedLibraryId != 0,
       let restored = visible.first(where: { $0.id == storedLibraryId }) {
        return restored.id
    }
    return visible.first?.id
}

private func libraryRootScopeID(
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String {
    let destination: String
    if let fixedLibraryId {
        destination = "library:\(fixedLibraryId)"
    } else if let category {
        destination = "category:\(category.rawValue)"
    } else {
        destination = "all"
    }
    return "\(authority?.serverId ?? "none"):\(authority?.profileId ?? "none"):\(destination)"
}

func librarySelectionStorageKey(
    category: PrimaryMenuBuiltin?,
    fixedLibraryId: Int?,
    authority: MainTabLibraryAuthority?
) -> String? {
    guard fixedLibraryId == nil else { return nil }
    guard category != nil else { return "librariesTabSelectedLibraryId" }
    guard authority != nil else { return nil }
    let scopeId = libraryRootScopeID(
        category: category,
        fixedLibraryId: nil,
        authority: authority
    )
    return "librariesTabSelectedLibraryId.\(scopeId)"
}

func storedLibrarySelectionId(
    for storageKey: String?,
    defaults: UserDefaults = .standard
) -> Int {
    guard let storageKey else { return 0 }
    if defaults.object(forKey: storageKey) != nil {
        return defaults.integer(forKey: storageKey)
    }
    // Seed new category-scoped selections from the legacy aggregate choice.
    // The first resolved selection is persisted under its own scoped key.
    return defaults.integer(forKey: "librariesTabSelectedLibraryId")
}

/// Browse grid for the selected movie or series library, retaining the
/// current library selector and its saved selection.
struct LibrariesTabView: View {
    let category: PrimaryMenuBuiltin?
    let fixedLibraryId: Int?
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @State private var libraries: [Library] = []
    @State private var selectedLibraryId: Int?
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var showPicker = false
    /// Feeds the glass strip behind the hoisted top chrome. Tab content reads
    /// it from the environment so each tab's ScrollView can report its offset.
    @State private var chromeScrollState = PageChromeScrollState()

    /// Persist the last-selected library per authored root so visiting Series
    /// cannot replace the Movies or aggregate selection. Fixed-library roots
    /// have no persistence key because their destination already fixes the ID.
    private let selectionStorageKey: String?
    @State private var storedLibraryId: Int
    /// Scope owning the selection when SwiftUI reuses a library view.
    @State private var appliedScopeID: String?

    @Environment(AppRouter.self) private var router

    init(
        category: PrimaryMenuBuiltin? = nil,
        fixedLibraryId: Int? = nil,
        libraryAuthority: MainTabLibraryAuthority? = nil,
        onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)? = nil
    ) {
        self.category = category
        self.fixedLibraryId = fixedLibraryId
        self.libraryAuthority = libraryAuthority
        self.onLibrariesLoaded = onLibrariesLoaded
        let storageKey = librarySelectionStorageKey(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )
        selectionStorageKey = storageKey
        _storedLibraryId = State(initialValue: storedLibrarySelectionId(for: storageKey))
    }

    var body: some View {
        Group {
            if let activeLibrary {
                loadedContent(activeLibrary: activeLibrary)
            } else if let error, visibleLibraries.isEmpty {
                ErrorView(state: error, onRetry: { Task { await loadLibraries() } })
            } else if isLoading && visibleLibraries.isEmpty {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "No libraries available",
                    subtitle: "Libraries visible to this profile will appear here."
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: libraryRootScopeID(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )) {
            storedLibraryId = storedLibrarySelectionId(for: selectionStorageKey)
            // SwiftUI can preserve this view while a split-view selection
            // changes from one direct library root to another. Reconcile the
            // selection before awaiting I/O so the old library never renders
            // under the new destination.
            applyLibrarySelection()
            await loadLibraries()
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) {
            notification in
            guard let response = notification.object as? LibrariesResponse else { return }
            acceptRefreshedLibraries(response)
        }
        .sheet(isPresented: $showPicker) {
            LibraryPickerSheet(
                libraries: visibleLibraries,
                scopedCategory: pickerScopeCategory,
                selectedLibraryId: selectedLibraryId,
                onSelect: { id in
                    selectedLibraryId = id
                    persistLibrarySelection(id)
                    showPicker = false
                }
            )
        }
    }

    @ViewBuilder
    private func loadedContent(activeLibrary: Library) -> some View {
        tabContent(activeLibrary: activeLibrary)
            // Forces the whole tab subtree to reset when switching
            // libraries, so stale content never flashes on screen.
            .id(activeLibrary.id)
            .environment(chromeScrollState)
            .safeAreaInset(edge: .top, spacing: 0) {
                topChrome(activeLibrary: activeLibrary)
                    // Same scroll-driven glass as the Detail page chrome so
                    // the selector and actions stay legible over posters.
                    .background {
                        PageChromeGlass(scrollState: chromeScrollState)
                    }
            }
    }

    private func tabContent(activeLibrary: Library) -> some View {
        BrowseView(libraryId: activeLibrary.id, title: nil, showsSearchShortcut: false, libraryType: activeLibrary.type)
    }

    @ViewBuilder
    private func topChrome(activeLibrary: Library) -> some View {
        VStack(spacing: 0) {
            #if os(iOS)
            HStack {
                Menu {
                    ForEach(visibleLibraries) { library in
                        Button {
                            selectedLibraryId = library.id
                            persistLibrarySelection(library.id)
                        } label: {
                            if library.id == activeLibrary.id {
                                Label(library.name, systemImage: "checkmark")
                            } else { Text(library.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(activeLibrary.name).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .vividGlass(in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VividTheme.padding)
            .padding(.vertical, VividTheme.smallPadding)
            #else
            LibrariesTopBar(
                activeLibrary: activeLibrary,
                canSwitch: libraryRootCanSwitch(
                    fixedLibraryId: fixedLibraryId,
                    visibleLibraryCount: visibleLibraries.count
                ),
                onLibraryTap: { showPicker = true },
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: {
                    router.switchProfile()
                },
                onSwitchServer: { router.navigate(to: .serverList) },
                onSignOut: { router.signOutAndReset() }
            )
            .padding(.horizontal, VividTheme.padding)
            .padding(.top, VividTheme.smallPadding)
            .padding(.bottom, VividTheme.smallPadding)

            #endif

        }
    }

    private var activeLibrary: Library? {
        visibleLibraries.first(where: { $0.id == selectedLibraryId })
    }

    /// The media-type scope the picker opened under, if any. A direct-library
    /// root inherits the requested library's type since its siblings share it.
    /// Mixed-library roots have their own scope rather than inheriting either
    /// Movies or Series.
    private var pickerScopeCategory: PrimaryMenuBuiltin? {
        if let category { return category }
        guard let fixedLibraryId,
              let fixed = libraries.first(where: { $0.id == fixedLibraryId }),
              !fixed.isMixedLibrary
        else { return nil }
        return [PrimaryMenuBuiltin.movies, .series].first {
            libraryMatchesPrimaryMenuCategory(fixed, category: $0)
        }
    }

    private var visibleLibraries: [Library] {
        visibleLibrariesForRoot(
            libraries,
            category: category,
            fixedLibraryId: fixedLibraryId
        )
    }

    private func loadLibraries() async {
        // Hydrate from cache so a returning visit paints last-known
        // libraries instantly while the refresh runs.
        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            applyLibrarySelection()
            onLibrariesLoaded?(libraryAuthority, cached.libraries)
        }
        if libraries.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            acceptRefreshedLibraries(response)
        } catch {
            if libraries.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Apply library metadata refreshed elsewhere (for example Home pull to
    /// refresh) so retained tab instances cannot keep renamed or revoked
    /// libraries in their local state.
    private func acceptRefreshedLibraries(_ response: LibrariesResponse) {
        libraries = response.libraries
        error = nil
        isLoading = false
        applyLibrarySelection()
        onLibrariesLoaded?(libraryAuthority, response.libraries)
    }

    /// Preserve the stored selection if it still exists; otherwise fall
    /// back to the first available library.
    private func applyLibrarySelection() {
        let scopeID = libraryRootScopeID(
            category: category,
            fixedLibraryId: fixedLibraryId,
            authority: libraryAuthority
        )
        let resolved = resolvedLibraryIdForRoot(
            libraries,
            category: category,
            fixedLibraryId: fixedLibraryId,
            storedLibraryId: storedLibraryId,
            currentSelectionId: appliedScopeID == scopeID ? selectedLibraryId : nil
        )
        appliedScopeID = scopeID
        selectedLibraryId = resolved
        if let resolved { persistLibrarySelection(resolved) }
    }

    private func persistLibrarySelection(_ libraryId: Int) {
        if let selectionStorageKey {
            storedLibraryId = libraryId
            UserDefaults.standard.set(libraryId, forKey: selectionStorageKey)
        }
        mirrorSelectionToMediaTypeRoots(libraryId)
    }

    /// Landing on (or switching within) a direct-library root also records
    /// the selection for the matching media-type roots, so tapping "Movies"
    /// after visiting "4K Movies" lands on 4K Movies.
    private func mirrorSelectionToMediaTypeRoots(_ libraryId: Int) {
        guard fixedLibraryId != nil,
              libraryAuthority != nil,
              let library = libraries.first(where: { $0.id == libraryId })
        else { return }
        for mediaType in [PrimaryMenuBuiltin.movies, .series]
        where libraryMatchesPrimaryMenuCategory(library, category: mediaType) {
            guard let key = librarySelectionStorageKey(
                category: mediaType,
                fixedLibraryId: nil,
                authority: libraryAuthority
            ) else { continue }
            UserDefaults.standard.set(libraryId, forKey: key)
        }
    }

}

// MARK: - Top Bar

/// Plex-style top bar: library selector on the left, shared action icons
/// (search / profile) on the right.
private struct LibrariesTopBar: View {
    let activeLibrary: Library
    let canSwitch: Bool
    let onLibraryTap: () -> Void
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SidebarToggleButton()

            LibrarySelectorButton(
                library: activeLibrary,
                canSwitch: canSwitch,
                onTap: onLibraryTap
            )

            Spacer(minLength: 8)

            TabTopBarActions(
                onSearch: onSearch,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
        }
    }
}

/// Compact library selector: library name with a small chevron, stacked above
/// a secondary label. Tap opens the picker sheet.
private struct LibrarySelectorButton: View {
    let library: Library
    let canSwitch: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(library.name)
                        .font(.vividTitle)
                    .foregroundStyle(Color.vividOnSurface)
                        .lineLimit(1)
                    if canSwitch {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.vividOnSurface)
                    }
                }
                Text(typeLabel)
                    .font(.vividCaption)
                    .foregroundStyle(Color.vividSecondaryText)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSwitch)
    }

    private var typeLabel: String {
        if library.isMixedLibrary { return "Movies & Series" }
        if library.isSeriesLibrary { return "Series" }
        if library.type == "movies" { return "Movies" }
        return "Library"
    }
}

// MARK: - Library Picker Sheet

/// Sheet listing all libraries available to the active profile. Used for
/// switching the active library from the Libraries tab.
private struct LibraryPickerSheet: View {
    let libraries: [Library]
    let scopedCategory: PrimaryMenuBuiltin?
    let selectedLibraryId: Int?
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        // tvOS does not support medium detents or presentation drags; render
        // as a full-screen focus-friendly list instead.
        content
        #else
        NavigationStack {
            content
                .toolbar {
                    #if os(macOS)
                    ToolbarItem {
                        Button("Done") { dismiss() }
                    }
                    #else
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                    #endif
                }
        }
        #if !os(macOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(libraries) { library in
                    LibraryPickerRow(
                        library: library,
                        scopedCategory: scopedCategory,
                        isSelected: library.id == selectedLibraryId,
                        onTap: { onSelect(library.id) }
                    )
                }
            }
            .padding(.horizontal, VividTheme.padding)
            .padding(.vertical, VividTheme.padding)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Libraries")
    }
}

private struct LibraryPickerRow: View {
    let library: Library
    let scopedCategory: PrimaryMenuBuiltin?
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.vividOnSurface.opacity(0.12))
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.vividOnSurface)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .font(.vividHeadline)
                        .foregroundColor(.vividOnSurface)
                    if let typeLabel {
                        Text(typeLabel)
                            .font(.vividCaption)
                            .foregroundColor(.vividSecondaryText)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.vividOnSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                    .fill(isSelected ? Color.vividOnSurface.opacity(0.10) : Color.vividSurfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                            .stroke(Color.vividOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if library.isMixedLibrary { return "square.stack.3d.up.fill" }
        if library.isSeriesLibrary { return "tv.fill" }
        if library.type == "movies" { return "film.fill" }
        return "square.stack.3d.up.fill"
    }

    /// Nil when the caption would just repeat the media-type scope the picker
    /// opened under — every non-mixed library there shares that type. Mixed
    /// libraries keep their caption since they stand out from the scope.
    private var typeLabel: String? {
        if scopedCategory != nil && !library.isMixedLibrary { return nil }
        if library.isMixedLibrary { return "Movies & Series library" }
        if library.isSeriesLibrary { return "TV library" }
        if library.type == "movies" { return "Movies library" }
        return "Library"
    }
}
