enum TVVisibleRootsFocusRearm: Equatable {
    case none
    case topMenu
    case content
}

func tvVisibleRootsFocusRearm(
    menuOwnedFocus: Bool,
    isShowingRoot: Bool,
    selectedRootWasRemoved: Bool
) -> TVVisibleRootsFocusRearm {
    guard isShowingRoot else { return .none }
    if menuOwnedFocus { return .topMenu }
    return selectedRootWasRemoved ? .content : .none
}

#if os(tvOS)
import SwiftUI

private enum TVPersonalRootDestination: Hashable, CaseIterable {
    case watchlist
    case favorites
    case collections

    var title: String {
        switch self {
        case .watchlist: return "Watchlist"
        case .favorites: return "Favourites"
        case .collections: return "Collections"
        }
    }
}

/// Root tvOS shell. Owns a custom Skyline top bar instead of relying on
/// `TabView(.sidebarAdaptable)`, so content can use horizontal remote
/// navigation without the system sidebar claiming leftward focus.
///
/// Tabs are content-type-first: Home, Movies, Series and For You.
/// Each library-type tab
/// appears only if the profile can see at least one library of that type.
struct TVMainTabView: View {
    @Bindable var router: AppRouter
    @State private var isReturningFromSettings = false
    @State private var selectedRoot: TVRootDestination = .home
    /// Selection within the current For You page.
    @State private var forYouSection: TVPersonalRootDestination = .watchlist
    /// Seeded from the startup prefetch so the bar's first frame already
    /// shows the active profile's avatar instead of filling it in late.
    @State private var profileStore = CurrentProfileStore.shared
    private var currentProfile: UserProfile? { profileStore.profile }
    @State private var registry = ServerRegistry.shared
    @State private var uiCustomization = UICustomizationPreferences.shared
    /// Visible libraries for the active profile; drives which type tabs
    /// exist and which library each type tab scopes to. Seeded from the
    /// startup prefetch so all type tabs are in the bar's first frame —
    /// waiting for `.task` made the library tabs pop in a beat after the
    /// splash lifted.
    @State private var libraries: [Library] =
        ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self)?.libraries ?? []
    @State private var loadedLibraryAuthority: MainTabLibraryAuthority? = {
        let registry = ServerRegistry.shared
        return MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }()
    /// Selected library within each Movies or Series page.
    @State private var scopeSelections: [TVLibraryTabType: Int] = [:]
    @State private var isTopMenuFocused = false
    @State private var isTopMenuFocusSuppressed = true
    /// True while Search or Settings is pushed from the bar. On return,
    /// focus returns to the bar — the explicit "next owner" choice
    /// (docs/apple-tv-focus.md); leaving it to the engine landed on an
    /// arbitrary row card. Card-pushed routes (detail pages) never set this;
    /// their pops emit `detailReturnFocusRequest` so the exact launch row/card
    /// explicitly reclaims focus.
    @State private var barOwnsFocusOnPopToRoot = false
    @State private var topMenuFocusRequest = 0
    /// Bumped by the focus watchdog to drop the bar's `@FocusState` when the
    /// engine has already dropped focus without telling it. Re-suppressing is
    /// not enough: the bar nils on the *transition* into suppression, and the
    /// wedge is observed while suppression is already true.
    @State private var topMenuFocusResetRequest = 0
    /// Active focus hand-down generation. Incremented whenever a root is
    /// selected so the freshly-swapped-in content imperatively claims
    /// focus, instead of relying on `prefersDefaultFocus` (which can lose
    /// to geometric proximity, per CLAUDE.md's "tvOS default focus on
    /// d-pad entry"). Starts at 1 so the initial Home content focuses on
    /// first appear.
    @State private var contentFocusRequest = 1
    /// Card-pushed detail routes return to their exact Skyline owner instead
    /// of relying on NavigationStack's best-effort focus restoration.
    @State private var detailReturnFocusRequest = 0
    @Namespace private var tabContentNamespace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $router.path) {
                rootContent
                    .navigationDestination(for: Route.self) { route in
                        routeContent(for: route)
                    }
                    .navigationDestination(for: TVSettingsCategory.self) { category in
                        if category == .about {
                            AboutSettingsView()
                        } else {
                            TVSettingsView(category: category)
                        }
                    }
                    .navigationDestination(for: TVAccountRoute.self) { route in
                        switch route { case .editor(let id): TVSavedAccountEditor(accountID: id) }
                    }
            }

            if router.path.isEmpty {
                TVTopMenuBar(
                    roots: visibleRoots,
                    selectedRoot: selectedRoot,
                    currentProfile: currentProfile,
                    isMenuFocused: $isTopMenuFocused,
                    isFocusSuppressed: isTopMenuFocusSuppressed,
                    focusRequest: topMenuFocusRequest,
                    focusResetRequest: topMenuFocusResetRequest,
                    onSelectRoot: selectRoot(_:),
                    onSearch: { navigateFromBar(.search) },
                    onProfilePressed: { navigateFromBar(.settings) },
                    onContentFocusHandoff: suppressTopMenuFocusForContentHandoff,
                    onExit: selectedRoot == .home ? nil : returnToHomeInMenu
                )
            }

        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .tint(.vividOnSurface)
        .fullScreenCover(item: $router.presentedPlayer) { payload in
            PlayerView(
                contentId: payload.contentId,
                preferredFileId: payload.fileId,
                preferredAudioTrackIndex: payload.audioTrackIndex,
                preferredSubtitleTrackIndex: payload.subtitleTrackIndex,
                startFromBeginning: payload.startFromBeginning,
                resumePositionOverride: payload.resumePosition,
                prefersLastUsedVersion: payload.prefersLastUsedVersion,
                posterURLHint: payload.posterURL,
                backdropURLHint: payload.backdropURL,
                onPlaybackStarted: {
                    guard let returnToContentId = payload.returnToContentId,
                          router.presentedPlayer?.id == payload.id else { return }
                    router.replaceCurrent(with: .itemDetail(contentId: returnToContentId))
                }
            )
        }
        // Outside the presentation modifiers so the video player inherits
        // the router — ErrorView requires it and traps when it's absent.
        .environment(router)
        .task {
            await uiCustomization.refresh()
        }
        .task(id: currentLibraryAuthority) {
            await profileStore.refresh()
            await loadLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: router.path.isEmpty) { _, isEmpty in
            if isEmpty, isReturningFromSettings {
                isReturningFromSettings = false
                return // selectRoot already handed focus to Home once.
            }
            // Returning from a pushed route (Search, detail, settings)
            // re-mounts the bar with whatever suppression it had when it
            // unmounted — pushing from the bar leaves it *enabled*, so the
            // engine's post-pop focus restore can land on the last bar
            // element (e.g. the search icon) for a frame before the
            // content-boundary Up handler re-pins the selected tab. Content
            // owns focus after a pop, so re-assert the suppressed invariant;
            // Up from content re-arms the bar explicitly as usual.
            if isEmpty {
                suppressTopMenuFocusForContentHandoff()
                if barOwnsFocusOnPopToRoot {
                    barOwnsFocusOnPopToRoot = false
                    // Deferred one turn: the bar re-mounts in this same
                    // transaction, so a synchronous request bump would be
                    // its *initial* value and onChange(focusRequest) would
                    // never fire.
                    DispatchQueue.main.async {
                        focusTopMenuIfVisible()
                    }
                } else {
                    detailReturnFocusRequest += 1
                }
            }
        }
        .onChange(of: router.requestedTab) { _, requestedTab in
            guard let requestedTab else { return }
            router.requestedTab = nil

            // tvOS owns a custom root selector rather than MainTabView's
            // AppTab binding. Settings uses this one-shot request so its
            // final Menu/Back exits to Home regardless of the prior root.
            if requestedTab == .home {
                isReturningFromSettings = !router.path.isEmpty
                barOwnsFocusOnPopToRoot = false
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selectRoot(.home) }
            }
        }
        .onChange(of: visibleRoots) { _, _ in
            reconcileVisibleRootsChange()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                let authority = currentLibraryAuthority
                Task { await loadLibraries(for: authority) }
            }
        }
        .tvFocusWatchdog(isActive: focusWatchdogIsActive, onRepair: repairLostFocus)
    }

    /// The watchdog's reading is only actionable while this shell's focus graph
    /// is the one on screen. Covers, dialogs, and the standby overlay own (or
    /// legitimately suspend) focus themselves, and a backgrounded scene has no
    /// focused item by definition.
    private var focusWatchdogIsActive: Bool {
        scenePhase == .active
            && router.presentedPlayer == nil
    }

    /// One nudge per detected focus outage (docs/apple-tv-focus.md: do not fight
    /// the engine). At root the shell owns the hand-down, so clear the bar's
    /// stale focus state and re-arm content entry focus — the same path a tab
    /// selection uses. On a pushed route the shell owns no focus target, so ask
    /// the engine to re-resolve from the window instead of pinning one.
    ///
    private func repairLostFocus() {
        topMenuFocusResetRequest += 1
        if router.path.isEmpty {
            suppressTopMenuFocusForContentHandoff()
            contentFocusRequest += 1
        } else {
            TVFocusSystemProbe.requestFocusUpdate()
        }
    }

    private var rootContent: some View {
        ZStack(alignment: .top) {
            Color.clear
                .ignoresSafeArea()

            selectedRootContent
                .id(selectedRoot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // §4.2 tab content switch: an explicit 200 ms opacity
                // crossfade keyed on the selected root, so the incoming page
                // fades in and the outgoing one fades out in place (it never
                // slides). The crossfade animation is supplied by `selectRoot`;
                // Reduce Motion snaps via the `.identity` transition.
                .transition(reduceMotion ? .identity : .opacity)
                .focusScope(tabContentNamespace)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onExitCommand {
            if router.path.isEmpty {
                focusTopMenuIfVisible()
            } else {
                // The root remains mounted behind NavigationStack pushes.
                // Its old no-op top-menu request consumed Back/Menu while the
                // bar was absent, stranding detail pages. On a push, Back owns
                // exactly one stack pop so focus can restore to the launch card.
                router.goBack()
            }
        }
    }

    @ViewBuilder
    private var selectedRootContent: some View {
        switch selectedRoot {
        case .home:
            HomeView(
                homeFocusRequest: contentFocusRequest,
                detailReturnFocusRequest: detailReturnFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        case .recommendations:
            TVForYouView(
                selection: $forYouSection,
                libraries: libraries.filter { $0.isMovieLibrary || $0.isSeriesLibrary || $0.isMixedLibrary },
                focusRequest: contentFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        case .libraryType(let type):
            let active = activeLibrary(for: type)
            Group {
                if let active {
                    TVLibraryGridView(
                        libraryId: active.id,
                        libraryName: active.name,
                        libraryType: type == .movies ? "movies" : "series",
                        showsHeader: false,
                        topContentInset: 144,
                        focusRequest: contentFocusRequest,
                        isTopMenuFocused: isTopMenuFocused,
                        onTopMenuFocusRequest: { focusTopMenuIfVisible() },
                        libraryTabs: libraries(of: type),
                        onSelectLibrary: { library in
                            scopeSelections[type] = library.id
                            TVLibraryScopeStore.shared.setSelectedLibraryId(library.id, for: type)
                        }
                    )
                } else {
                    EmptyStateView(icon: "square.stack.3d.up", title: "No libraries", subtitle: nil)
                }
            }
            .id(type)
        }
    }

    // MARK: - Tab derivation

    /// Contract-ordered roots for this TV family. Search and Profile remain
    /// fixed outside this list, which keeps their focus anchors stable while
    /// the user rearranges content tabs.
    private var visibleRoots: [TVRootDestination] {
        var roots: [TVRootDestination] = []
        for item in uiCustomization.resolvedPrimaryMenuItems(availableLibraries: libraries) {
            let root: TVRootDestination?
            switch item {
            case .builtin(.home): root = .home
            case .builtin(.movies): root = availableRoot(for: .movies)
            case .builtin(.series): root = availableRoot(for: .series)
            case .builtin(.forYou): root = .recommendations
            case .library, .section, .collection:
                root = nil
            }
            if let root, !roots.contains(root) { roots.append(root) }
        }
        if !roots.contains(.home) { roots.insert(.home, at: 0) }
        return roots
    }

    private func availableRoot(for type: TVLibraryTabType) -> TVRootDestination? {
        libraries.contains(where: { type.matches($0) }) ? .libraryType(type) : nil
    }

    private func libraries(of type: TVLibraryTabType) -> [Library] {
        libraries
            .filter { type.matches($0) }
            .sorted {
                ($0.sortOrder ?? Int.max, $0.id) < ($1.sortOrder ?? Int.max, $1.id)
            }
    }

    /// The library a type tab is currently scoped to (§3.1): the in-session
    /// selection if it still exists, else the persisted choice, else the
    /// first library by sort order (cold start). Returns `nil` only when the
    /// type has no visible libraries.
    private func activeLibrary(for type: TVLibraryTabType) -> Library? {
        let available = libraries(of: type)
        if let selectedId = scopeSelections[type],
           let match = available.first(where: { $0.id == selectedId }) {
            return match
        }
        return TVLibraryScopeStore.shared.resolvedLibrary(for: type, in: available)
    }

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }

    private func loadLibraries(for authority: MainTabLibraryAuthority?) async {
        if loadedLibraryAuthority != authority {
            loadedLibraryAuthority = authority
            libraries = []
            scopeSelections = [:]
            ensureSelectedRootIsVisible()
        }
        guard let authority else { return }

        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            ensureSelectedRootIsVisible()
        }

        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            loadedLibraryAuthority = authority
            libraries = response.libraries
            ensureSelectedRootIsVisible()
        } catch {
            // Keep whatever tabs we already have (cached or none) — Home
            // and Calendar always stay reachable, so a transient failure
            // never strands the user.
        }
    }

    /// The selected root can stop being visible — a library refresh removes
    /// its type (e.g. profile permissions changed), or the user hides its tab
    /// from Settings. Snap back to Home rather than leaving a tab-less content
    /// view on screen. Home is always injected into `visibleRoots`, so this
    /// never strands the user.
    private func ensureSelectedRootIsVisible(requestContentFocus: Bool = true) {
        if !visibleRoots.contains(selectedRoot) {
            selectedRoot = .home
            if requestContentFocus {
                contentFocusRequest += 1
            }
        }
    }

    /// A synced menu edit can remove the bar button that currently owns focus
    /// even when the selected page remains visible. Capture the owner before
    /// explicitly re-arming that same focus zone after the
    /// graph changes so tvOS never has to repair from an ownerless state.
    private func reconcileVisibleRootsChange() {
        let menuOwnedFocus = !isTopMenuFocusSuppressed
        let isShowingRoot = router.path.isEmpty
        let selectedRootWasRemoved = !visibleRoots.contains(selectedRoot)
        let focusRearm = tvVisibleRootsFocusRearm(
            menuOwnedFocus: menuOwnedFocus,
            isShowingRoot: isShowingRoot,
            selectedRootWasRemoved: selectedRootWasRemoved
        )

        ensureSelectedRootIsVisible(requestContentFocus: false)

        switch focusRearm {
        case .none:
            break
        case .topMenu:
            focusTopMenuIfVisible()
        case .content:
            suppressTopMenuFocusForContentHandoff()
            contentFocusRequest += 1
        }
    }

    // MARK: - Root selection & focus

    private func selectRoot(_ root: TVRootDestination) {
        let isReselect = root == selectedRoot
        router.popToRoot()

        suppressTopMenuFocusForContentHandoff()
        // Tab content switches crossfade over 200 ms (§4.2); the outgoing
        // view never owns focus here because selection happens from the bar.
        // Reduce Motion snaps (the `.identity` transition + nil animation).
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VividTheme.normalDuration)) {
            selectedRoot = root
        }
        // Push focus into whichever root content is swapping in. Suppressing
        // the menu relinquishes its focus (TVTopMenuBar.onChange(isFocusSuppressed)),
        // so without an active hand-down the new content never claims focus and
        // the remote goes dead until the user blindly swipes.
        if isReselect {
            // Re-selecting the current tab keeps the content view alive (same
            // `.id`), so a synchronous bump lands the row's focus claim in the
            // same transaction as the bar's disable + focus teardown — and the
            // engine's repair from the resigning tab button wins, leaving focus
            // stranded in the menu. Defer one turn so the first card's claim is
            // applied after the bar has fully resigned; a fresh tab doesn't need
            // this because its content mounts a render later and claims in
            // onAppear anyway.
            DispatchQueue.main.async {
                contentFocusRequest += 1
            }
        } else {
            contentFocusRequest += 1
        }
    }

    /// Return focus to the selected top-level tab.
    private func focusTopMenuIfVisible() {
        // The custom top menu only exists on root pages. Pushed detail,
        // player, and settings routes should keep normal navigation-stack
        // back behavior instead of being intercepted by the root shell.
        guard router.path.isEmpty else { return }

        // Claim ownership before the bar's @FocusState lands so content
        // hand-down tokens cannot briefly re-focus rows during an Up return.
        isTopMenuFocused = true

        withAnimation(reduceMotion ? nil : VividTheme.springAnimation) {
            isTopMenuFocusSuppressed = false
        }
        // Let the bar's enabled state commit before asking its @FocusState to
        // claim the selected tab. A swipe-up move can arrive in the same
        // transaction that unsuppresses the bar; writing both together made
        // tvOS occasionally reject the claim, forcing another swipe or Back.
        DispatchQueue.main.async {
            guard router.path.isEmpty,
                  isTopMenuFocused,
                  !isTopMenuFocusSuppressed else { return }
            topMenuFocusRequest += 1
        }
    }

    private func returnToHomeInMenu() {
        selectedRoot = .home
        withAnimation(reduceMotion ? nil : VividTheme.springAnimation) {
            // Un-suppress before requesting focus: requestMenuFocus drops the
            // request while the menu is suppressed, which could leave the
            // Home button unfocused after the exit-to-home gesture.
            isTopMenuFocusSuppressed = false
            topMenuFocusRequest += 1
        }
    }

    private func suppressTopMenuFocusForContentHandoff() {
        isTopMenuFocused = false
        isTopMenuFocusSuppressed = true
    }

    /// Push Search or Settings from the bar. Popping back to root hands
    /// focus to the bar instead of letting the engine free-resolve into
    /// the row band.
    private func navigateFromBar(_ route: Route) {
        barOwnsFocusOnPopToRoot = true
        if case .search = route {
            // The native searchable interface manages its own presentation.
            // Do not also animate the outgoing custom chrome/navigation push.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                router.navigate(to: route)
            }
        } else {
            router.navigate(to: route)
        }
    }

    @ViewBuilder
    private func routeContent(for route: Route) -> some View {
        switch route {
        case .library(let libraryId, let title):
            BrowseView(libraryId: libraryId, title: title)
        case .libraryCollection(let libraryId, let collectionId, let title, let kind):
            LibraryCollectionDetailView(
                libraryId: libraryId,
                collectionId: collectionId,
                title: title,
                kind: kind
            )
        case .itemDetail(let contentId, let tvSeed):
            ItemDetailView(contentId: contentId, tvSeed: tvSeed)
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        case .player(let contentId, let startFromBeginning, let resumePosition, let prefersLastUsedVersion):
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition,
                prefersLastUsedVersion: prefersLastUsedVersion
            )
        case .playerWithFile(let contentId, let fileId, let audioTrackIndex, let subtitleTrackIndex, let startFromBeginning, let resumePosition):
            PlayerView(
                contentId: contentId,
                preferredFileId: fileId,
                preferredAudioTrackIndex: audioTrackIndex,
                preferredSubtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
        case .favorites:
            FavoritesView()
        case .watchlist:
            WatchlistView()
        case .history:
            HistoryView()
        case .collections:
            CollectionsView()
        case .collectionDetail(let id):
            CollectionDetailView(collectionId: id)
        case .browse(let libraryId):
            BrowseView(libraryId: libraryId)
        case .requestsHub:
            RequestsHubView()
        case .requestDetail(let mediaType, let tmdbId):
            RequestDetailView(mediaType: mediaType, tmdbId: tmdbId)
        case .myRequests:
            MyRequestsView()
        case .search:
            SearchView(usesTVTopMenuInset: false)
        case .settings:
            TVSettingsView()
        case .recommendations:
            RecommendationsView()
        case .serverList:
            ServerListView()
        case .serverSetup:
            // Pushed from the profile menu's "Add Server…" button — staying
            // on the nav stack means the tvOS back button returns to the
            // previous active server instead of dropping the authenticated
            // tree entirely. Successful `connect()` flips authState to
            // `.needsLogin` and replaces this view tree.
            TVServerSetupView(router: router)
        case .tvLibraryGrid(let libraryId, let libraryName, let libraryType, let payload, let subtitle):
            TVLibraryGridView(
                libraryId: libraryId,
                libraryName: libraryName,
                libraryType: libraryType,
                initialFilter: payload.toFilterState(),
                subtitle: subtitle
            )
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividBackground()
        }
    }
}

private struct TVForYouView: View {
    @Binding var selection: TVPersonalRootDestination
    let libraries: [Library]
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    private struct CachedPage {
        let response: CatalogResponse
    }
    @State private var prefixes: [TVPersonalRootDestination: String] = [:]
    @FocusState private var alphabetFocused: Bool
    private var selectedPrefix: String? { prefixes[selection] }
    private var cacheKey: String { "personal:tvForYou:\(selection):prefix=\(selectedPrefix ?? "all")" }

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var error: ErrorState?
    @State private var nextOffset = 0
    @State private var generation = 0
    @State private var gridFocusRequest = 0
    @FocusState private var focusedTab: TVPersonalRootDestination?
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {

            if selection == .collections {
                TVLibraryCollectionsView(
                    library: nil,
                    combinedLibraries: libraries,
                    namePrefix: selectedPrefix,
                    suppressesEdgeShading: true,
                    topContentInset: 0,
                    fixedColumnCount: 7,
                    focusRequest: focusedTab == nil && !alphabetFocused && !isTopMenuFocused ? gridFocusRequest : 0,
                    isTopMenuFocused: isTopMenuFocused || focusedTab != nil || alphabetFocused,
                    onMoveUp: { focusedTab = selection }
                )
                .environment(\.forYouScrollHeader, AnyView(sectionTabs))
            } else {
                ScrollView {
                    sectionTabs
                        .padding(.bottom, 32)
                    if let error, items.isEmpty {
                        ErrorView(state: error, onRetry: { Task { await reload() } })
                    } else if items.isEmpty && !isLoading {
                        EmptyStateView(
                            icon: selection == .watchlist ? "bookmark" : "heart",
                            title: "Your \(selection.title.lowercased()) is empty",
                            subtitle: nil
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                        .focusable()
                        .onMoveCommand { if $0 == .up { focusedTab = selection } }
                    } else {
                        TVCatalogGrid(
                            items: items,
                            isLoading: isLoading,
                            hasMore: hasMore,
                            onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                            onNearEnd: { _ in Task { await loadMore() } },
                            showsMediaTypePills: true,
                            fixedColumnCount: 7,
                            focusRequest: focusedTab == nil && !alphabetFocused && !isTopMenuFocused ? gridFocusRequest : 0,
                            onFirstRowMoveUp: { focusedTab = selection }
                        )
                        .padding(.horizontal, VividTheme.safePadding)
                        .padding(.bottom, 48)
                    }
                }
                .contentMargins(.top, 28, for: .scrollContent)
                .scrollClipDisabled()
                .modifier(TVPersonalScrollAppearance())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 176)
        .task(id: cacheKey) { await reload() }
        .onChange(of: focusRequest) { _, request in
            if request > 0, !isTopMenuFocused { focusedTab = selection }
        }
        .onAppear {
            if focusRequest > 0, !isTopMenuFocused { focusedTab = selection }
        }
    }

    private var sectionTabs: some View {
        HStack(spacing: 14) {
                ForEach(TVPersonalRootDestination.allCases, id: \.self) { tab in
                    let focused = focusedTab == tab
                    Button {
                        selection = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 26, weight: .semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .foregroundStyle(focused ? Color.black : .white.opacity(selection == tab ? 1 : 0.65))
                            .background(
                                focused ? Color.white : .white.opacity(selection == tab ? 0.18 : 0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.vividFlat)
                    .focusEffectDisabled()
                    .focused($focusedTab, equals: tab)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
                TVAlphabetMenu(selected: selectedPrefix) { prefix in
                    prefixes[selection] = prefix
                }
                .focused($alphabetFocused)
            }
            .padding(.horizontal, VividTheme.safePadding)
            .focusSection()
            .onMoveCommand { direction in
                if direction == .up { alphabetFocused = false; focusedTab = nil; onTopMenuFocusRequest() }
                if direction == .down {
                    alphabetFocused = false
                    focusedTab = nil
                    gridFocusRequest += 1
                }
            }
    }

    private func reload() async {
        generation += 1
        items = []
        nextOffset = 0
        hasMore = true
        isLoading = false
        error = nil
        guard selection != .collections else { return }
        if let cached: CachedPage = ResponseCache.shared.get(cacheKey) {
            items = cached.response.items
            nextOffset = items.count
            hasMore = cached.response.hasMore ?? false
        }
        await loadMore(reset: true)
    }

    private func loadMore(reset: Bool = false) async {
        guard selection != .collections, reset || hasMore, !isLoading else { return }
        let requestGeneration = generation
        let requestedSection = selection
        let requestedPrefix = selectedPrefix
        let requestedCacheKey = cacheKey
        isLoading = true
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            var query = [
                "source": requestedSection == .watchlist ? "watchlist" : "favorites",
                "offset": String(reset ? 0 : nextOffset),
                "limit": "70",
                "include_total": "false"
            ]
            if let requestedPrefix {
                query["name_prefix"] = requestedPrefix
                query["sort"] = CatalogSortKey.title.field
                query["order"] = CatalogSortOrder.asc.rawValue
            }
            let response = try await VividAPI.shared.catalog(query: query)
            guard requestGeneration == generation, requestedSection == selection, requestedPrefix == selectedPrefix,
                  !Task.isCancelled else { return }
            if reset {
                items = []
                nextOffset = 0
                ResponseCache.shared.set(CachedPage(response: response), for: requestedCacheKey)
            }
            var seen = Set(items.map(\.contentId))
            items.append(contentsOf: response.items.filter { seen.insert($0.contentId).inserted })
            nextOffset += response.items.count
            hasMore = response.hasMore ?? (response.total.map { nextOffset < $0 } ?? false)
        } catch {
            guard requestGeneration == generation, requestedSection == selection, requestedPrefix == selectedPrefix,
                  !Task.isCancelled else { return }
            self.error = ErrorState(error)
        }
    }
}

#endif
