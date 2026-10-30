import SwiftUI

/// The Libraries tab, and the Movies and Series tabs: one library at a time,
/// picked from a menu at the top, with its catalogue below.
struct LibrariesTabView: View {
    private let category: PrimaryMenuBuiltin?
    private let libraryAuthority: MainTabLibraryAuthority?
    private let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    #if os(iOS)
    @State private var libraries: [Library] = []
    @State private var selectedLibraryId: Int?
    @State private var isLoading = true
    @State private var error: ErrorState?
    @State private var storedLibraryId: Int
    /// The selection scope the selection was last resolved for.
    @State private var appliedScope: String?
    @State private var chromeScroll = PageChromeScrollState()
    #endif

    init(
        category: PrimaryMenuBuiltin? = nil,
        libraryAuthority: MainTabLibraryAuthority? = nil,
        onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)? = nil
    ) {
        self.category = category
        self.libraryAuthority = libraryAuthority
        self.onLibrariesLoaded = onLibrariesLoaded
        #if os(iOS)
        let key = librarySelectionStorageKey(category: category, fixedLibraryId: nil, authority: libraryAuthority)
        _storedLibraryId = State(initialValue: storedLibrarySelectionId(for: key))
        #endif
    }

    #if os(iOS)
    var body: some View {
        content
            .background(VividAppBackdrop())
            .toolbar(.hidden, for: .navigationBar)
            .task(id: selectionScope) {
                if let storageKey {
                    storedLibraryId = storedLibrarySelectionId(for: storageKey)
                }
                applySelection()
                await load()
            }
            .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) { notification in
                guard let response = notification.object as? LibrariesResponse else { return }
                accept(response)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let library = activeLibrary {
            BrowseView(libraryId: library.id, libraryType: library.type)
                .id(library.id)
                .environment(chromeScroll)
                .safeAreaInset(edge: .top, spacing: 0) {
                    libraryPicker(active: library)
                }
        } else if let error, visibleLibraries.isEmpty {
            ErrorView(state: error, onRetry: { Task { await load() } })
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

    private func libraryPicker(active: Library) -> some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(visibleLibraries, id: \.id) { library in
                        Button {
                            choose(library.id)
                        } label: {
                            if library.id == active.id {
                                Label(library.name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: library.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(verbatim: active.name)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .vividGlass(in: Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(PageChromeGlass(scrollState: chromeScroll))
    }

    // MARK: Selection

    private var storageKey: String? {
        librarySelectionStorageKey(category: category, fixedLibraryId: nil, authority: libraryAuthority)
    }

    /// Identifies whose libraries and which tab this is.
    private var selectionScope: String {
        let destination = category.map { "category:\($0.rawValue)" } ?? "all"
        return "\(libraryAuthority?.serverId ?? "none"):\(libraryAuthority?.profileId ?? "none"):\(destination)"
    }

    private var visibleLibraries: [Library] {
        visibleLibrariesForRoot(libraries, category: category, fixedLibraryId: nil)
    }

    private var activeLibrary: Library? {
        guard let selectedLibraryId else { return nil }
        return visibleLibraries.first { $0.id == selectedLibraryId }
    }

    private func applySelection() {
        let scope = selectionScope
        let resolved = resolvedLibraryIdForRoot(
            libraries,
            category: category,
            fixedLibraryId: nil,
            storedLibraryId: storedLibraryId,
            currentSelectionId: appliedScope == scope ? selectedLibraryId : nil
        )
        appliedScope = scope
        selectedLibraryId = resolved
        if let resolved { remember(resolved) }
    }

    private func choose(_ libraryId: Int) {
        selectedLibraryId = libraryId
        remember(libraryId)
    }

    /// Without a storage key the choice is kept for as long as the tab lives.
    private func remember(_ libraryId: Int) {
        storedLibraryId = libraryId
        if let storageKey {
            UserDefaults.standard.set(libraryId, forKey: storageKey)
        }
    }

    // MARK: Loading

    private func load() async {
        if libraries.isEmpty, let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            applySelection()
            onLibrariesLoaded?(libraryAuthority, cached.libraries)
        }
        if libraries.isEmpty { isLoading = true }
        error = nil
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled else { return }
            accept(response)
        } catch {
            guard !Task.isCancelled else { return }
            if libraries.isEmpty { self.error = ErrorState(error) }
        }
        isLoading = false
    }

    private func accept(_ response: LibrariesResponse) {
        libraries = response.libraries
        error = nil
        isLoading = false
        applySelection()
        onLibrariesLoaded?(libraryAuthority, response.libraries)
    }
    #else
    /// Apple TV has its own library grid; this exists so the shared tab
    /// shell compiles, and draws nothing.
    var body: some View {
        EmptyView()
    }
    #endif
}
