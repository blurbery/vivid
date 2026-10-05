import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Main Tab View

enum MainTabDestinationID: Hashable {
    case app(AppTab)
    case libraryCategory(PrimaryMenuBuiltin)
}

struct MainTabDestination: Identifiable, Equatable {
    let id: MainTabDestinationID
    let title: String
    let icon: String
    let selectedIcon: String

    static func app(_ tab: AppTab) -> MainTabDestination {
        .init(id: .app(tab), title: tab.rawValue, icon: tab.icon, selectedIcon: tab.selectedIcon)
    }


    static func libraryCategory(_ category: PrimaryMenuBuiltin) -> MainTabDestination {
        return .init(
            id: .libraryCategory(category),
            title: category.title,
            icon: category.navigationIcon,
            selectedIcon: category.navigationIcon
        )
    }
}

/// Projects the server menu onto the supported Apple tabs. Retired library,
/// section and collection shortcuts never become navigation roots.
func projectedMainTabDestinations(
    primaryMenu: PrimaryMenuPreference?,
    availableLibraries: [Library] = []
) -> [MainTabDestination] {
    guard let primaryMenu else {
        return AppTab.visibleCases.map(MainTabDestination.app)
    }

    let menuItems = primaryMenu.items.count == 1 && primaryMenu.items[0].isHome
        ? appleDefaultPrimaryMenuItems()
        : primaryMenu.items
    var destinations: [MainTabDestination] = []
    for item in menuItems {
        guard mainTabSupportsDestination(
            item,
            availableLibraries: availableLibraries
        ) else {
            continue
        }
        let destination: MainTabDestination?
        switch item {
        case .builtin(.home): destination = .app(.home)
        case .builtin(.movies): destination = .libraryCategory(.movies)
        case .builtin(.series): destination = .libraryCategory(.series)
        case .builtin(.forYou): destination = .app(.recommendations)
        case .library, .section, .collection:
            destination = nil
        }
        if let destination,
           !destinations.contains(where: { $0.id == destination.id }) {
            destinations.append(destination)
        }
    }
    if !destinations.contains(where: { $0.id == .app(.home) }) {
        destinations.insert(.app(.home), at: 0)
    }
    if destinations.count == 1, destinations[0].id == .app(.home) {
        var defaults: [MainTabDestination] = [.app(.home)]
        if availableLibraries.contains(where: {
            libraryMatchesPrimaryMenuCategory($0, category: .movies)
        }) {
            defaults.append(.libraryCategory(.movies))
        }
        if availableLibraries.contains(where: {
            libraryMatchesPrimaryMenuCategory($0, category: .series)
        }) {
            defaults.append(.libraryCategory(.series))
        }
        defaults.append(contentsOf: [
            .app(.recommendations),
        ])
        return defaults
    }
    return destinations
}

/// Runtime/editor capability gate for the non-tvOS Apple main shell. The
/// synced document remains untouched; roots that the active profile cannot
/// currently open simply stay out of the rendered navigation and editor.
func mainTabSupportsDestination(
    _ item: PrimaryMenuItem,
    availableLibraries: [Library]
) -> Bool {
    switch item {
    case .builtin(.movies):
        return availableLibraries.contains {
            libraryMatchesPrimaryMenuCategory($0, category: .movies)
        }
    case .builtin(.series):
        return availableLibraries.contains {
            libraryMatchesPrimaryMenuCategory($0, category: .series)
        }
    case .builtin(.home), .builtin(.forYou):
        return true
    case .library, .section, .collection:
        return false
    }
}

func resolvedVisibleMainTabDestination(
    _ requestedDestination: MainTabDestinationID,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    visibleDestinations.contains { $0.id == requestedDestination }
        ? requestedDestination
        : .app(.home)
}

func resolvedRequestedMainTabDestination(
    _ requestedTab: AppTab,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    if requestedTab == .libraries,
       !visibleDestinations.contains(where: { $0.id == .app(.libraries) }),
       let authoredLibraryRoot = visibleDestinations.first(where: {
           switch $0.id {
           case .libraryCategory:
               return true
           case .app:
               return false
           }
       }) {
        return authoredLibraryRoot.id
    }
    return resolvedVisibleMainTabDestination(
        .app(requestedTab),
        visibleDestinations: visibleDestinations
    )
}

struct MainTabLibraryAuthority: Hashable {
    let serverId: String
    let profileId: String

    init?(serverId: String?, profileId: String?) {
        guard let serverId, !serverId.isEmpty,
              let profileId, !profileId.isEmpty else { return nil }
        self.serverId = serverId
        self.profileId = profileId
    }
}

struct MainTabLibrarySnapshot: Equatable {
    let authority: MainTabLibraryAuthority?
    let libraries: [Library]

    func availableLibraries(
        for currentAuthority: MainTabLibraryAuthority?
    ) -> [Library] {
        guard let currentAuthority, authority == currentAuthority else { return [] }
        return libraries
    }

    @MainActor
    static func cachedForCurrentAuthority() -> Self {
        let registry = ServerRegistry.shared
        let authority = MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
        let libraries = ResponseCache.shared.get(
            CacheKey.userLibraries,
            as: LibrariesResponse.self
        )?.libraries ?? []
        return .init(authority: authority, libraries: libraries)
    }
}

struct MainTabView: View {
    @AppStorage(MobileProfilePreferenceKeys.key("vivid.mobile.showDownloadsTab")) private var showDownloadsTab = true
    @State private var tabBarScroll = MobileTabBarScrollState()
    @State private var showsSearchPage = false
    @State private var showsSettingsPage = false
    @Bindable var router: AppRouter
    @State private var selectedDestinationID: MainTabDestinationID = .app(.home)
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var serverRegistry = ServerRegistry.shared
    /// Tagged with the server/profile that authorized the library list. A
    /// profile transition fails direct roots closed immediately, even before
    /// its cache invalidation and network refresh finish.
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Shared namespace for the poster → detail zoom transition. Injected into
    /// the environment (`\.zoomNamespace`) so both the cards and the central
    /// detail destination resolve the same identity.
    @Namespace private var zoomNamespace
    @Environment(\.scenePhase) private var scenePhase
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            GeometryReader { geometry in
                ZStack {
                    tabLayout
                        .allowsHitTesting(!showsMobileUtilityPage)
                        .accessibilityHidden(showsMobileUtilityPage)

                    if showsSearchPage {
                        MobileSearchPage(safeAreaInsets: geometry.safeAreaInsets, onDismiss: dismissSearchPage)
                            .transition(.move(edge: .bottom))
                            .zIndex(10)
                    }

                    if showsSettingsPage {
                        MobileSettingsPage(router: router, safeAreaInsets: geometry.safeAreaInsets, onDismiss: dismissSettingsPage)
                            .transition(.move(edge: .bottom))
                            .zIndex(10)
                    }
                }
            }
            // A keyboard inside the player must not lift the underlying Home tab bar.
            .ignoresSafeArea(.keyboard, edges: showsMobileUtilityPage ? [] : .bottom)
            #else
            if prefersSidebarLayout { sidebarLayout } else { tabLayout }
            #endif
        }
        .tint(.vividOnSurface)
        #if os(iOS)
        .overlay {
            if UIDevice.current.userInterfaceIdiom == .pad, router.presentedItemDetail != nil {
                // Native sheets intentionally leave a narrow safe-area strip
                // above their largest detent. Mask the live tab content there
                // with dense glass so no logo, row or poster leaks around the
                // rounded detail card while it is open.
                Rectangle()
                    .fill(.ultraThickMaterial)
                    .overlay(Color.vividGlassStrong.opacity(0.92))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: router.presentedItemDetail != nil)
        #endif
        .task(id: currentLibraryAuthority) {
            await loadVisibleLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let authority = currentLibraryAuthority
            Task { await loadVisibleLibraries(for: authority) }
        }
        #if !os(tvOS)
        // Mirror Android's offline start-destination: launching with no
        // network but playable local downloads lands on Downloads instead of
        // a Home screen that can't load anything.
        .task {
            await ConnectionMonitor.shared.waitForInitialPath()
            guard !ConnectionMonitor.shared.isDeviceOnline else { return }
            // The auth-state task hydrates DownloadManager via onAppActive()
            // only after several awaited network refreshes, which is too late
            // for this check on an offline cold launch. Loading the scope
            // here is disk-only and idempotent — onAppActive() will skip the
            // reload when it eventually runs.
            _ = await DownloadManager.shared.activateScopeIfNeeded()
            guard DownloadManager.shared.downloadsEnabled,
                  DownloadManager.shared.records.contains(where: { $0.isPlayableOffline }),
                  // Don't clobber a tab the user (or a deep link) already
                  // selected while this task was waiting.
                  selectedDestinationID == .app(.home), router.requestedTab == nil
            else { return }
            selectedDestinationID = .app(.downloads)
        }
        #endif
        .onChange(of: router.requestedTab) { _, tab in
            guard let tab else { return }
            selectedDestinationID = resolvedRequestedMainTabDestination(
                tab,
                visibleDestinations: visibleDestinations
            )
            router.requestedTab = nil
        }
        .onChange(of: showDownloadsTab) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(selectedDestinationID, visibleDestinations: visibleDestinations)
            tabBarScroll.reset()
        }
        .onChange(of: uiCustomization.primaryMenu) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(
                selectedDestinationID,
                visibleDestinations: visibleDestinations
            )
        }
        .onChange(of: librarySnapshot) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(
                selectedDestinationID,
                visibleDestinations: visibleDestinations
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) {
            notification in
            guard let authority = currentLibraryAuthority,
                  let response = notification.object as? LibrariesResponse
            else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
        }
        #if !os(macOS)
        #if os(iOS)
        .modifier(PlayerPresentationModifier(router: router))
        #else
        .fullScreenCover(item: $router.presentedPlayer) { payload in
            PlayerView(
                contentId: payload.contentId,
                preferredFileId: payload.fileId,
                preferredAudioTrackIndex: payload.audioTrackIndex,
                preferredSubtitleTrackIndex: payload.subtitleTrackIndex,
                startFromBeginning: payload.startFromBeginning,
                resumePositionOverride: payload.resumePosition,
                prefersLastUsedVersion: payload.prefersLastUsedVersion,
                offlineDownloadId: payload.offlineDownloadId,
                posterURLHint: payload.posterURL,
                backdropURLHint: payload.backdropURL
            )
        }
        #endif
        #if os(iOS)
        .modifier(ItemDetailPresentationModifier(router: router, zoomNamespace: zoomNamespace))
        #endif
        #endif
        // Outside the presentation modifiers so the video player inherits
        // the router — ErrorView requires it and traps when it's absent.
        .environment(router)
    }

    private var prefersSidebarLayout: Bool {
        #if os(macOS)
        true
        #else
        hSize == .regular
        #endif
    }

    /// Visible tabs, plus a Downloads tab when the server advertises the
    /// downloads capability for this profile. Reading
    /// `DownloadManager.shared.downloadsEnabled` here registers the tab bar
    /// as an observer, so the tab appears as soon as capability loads.
    private var visibleDestinations: [MainTabDestination] {
        var destinations = projectedMainTabDestinations(
            primaryMenu: uiCustomization.primaryMenu,
            availableLibraries: librarySnapshot.availableLibraries(
                for: currentLibraryAuthority
            )
        )
        #if !os(tvOS)
        if showDownloadsTab,
           !destinations.contains(where: { $0.id == .app(.downloads) }) {
            destinations.append(.app(.downloads))
        }
        #endif
        return destinations
    }

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: serverRegistry.activeServerId,
            profileId: serverRegistry.activeProfileId
        )
    }

    private func loadVisibleLibraries(for authority: MainTabLibraryAuthority?) async {
        let retainedLibraries = librarySnapshot.authority == authority
            ? librarySnapshot.libraries
            : []
        librarySnapshot = .init(authority: authority, libraries: retainedLibraries)
        guard let authority else { return }
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
        } catch {
            // Keep the active-profile cache, or fail closed with no direct
            // library roots when there is no safe offline routing metadata.
        }
    }

    private var selectedDestination: MainTabDestination {
        visibleDestinations.first(where: { $0.id == selectedDestinationID })
            ?? .app(.home)
    }

    private var sidebarTitle: String {
        serverRegistry.activeServer?.displayName ?? "Media Server"
    }

    /// iPhone + iPad compact width: bottom tab bar, single navigation stack.
    private var tabLayout: some View {
        NavigationStack(path: $router.path) {
            Group {
                #if os(iOS)
                destinationContent(for: selectedDestination)
                    .id(selectedDestinationID)
                #else
            TabView(selection: $selectedDestinationID) {
                ForEach(visibleDestinations) { destination in
                    #if os(tvOS)
                    // Text-only tabs on tvOS keep the top bar compact — adding an
                    // icon blows up each tab's focus pill. The value-based `Tab`
                    // initializer requires an image on tvOS, so this arm stays on
                    // the `.tabItem { Text }` form to preserve the text-only look.
                    destinationContent(for: destination)
                        .tabItem { Text(destination.title) }
                        .tag(destination.id)
                    #else
                    Tab(
                        destination.title,
                        systemImage: selectedDestinationID == destination.id
                            ? destination.selectedIcon
                            : destination.icon,
                        value: destination.id
                    ) {
                        destinationContent(for: destination)
                    }
                    #endif
                }
            }
                #endif
            }
            .navigationDestination(for: Route.self) { route in
                routeContent(for: route)
            }
            #if os(iOS)
            .toolbar(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 2) {
                if router.path.isEmpty {
                    mobileGlassTabBar
                        .offset(y: tabBarScroll.isHidden ? 90 : 0)
                        .opacity(tabBarScroll.isHidden ? 0 : 1)
                        .allowsHitTesting(!tabBarScroll.isHidden)
                        .accessibilityHidden(tabBarScroll.isHidden)
                        .animation(.easeInOut(duration: 0.22), value: tabBarScroll.isHidden)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 0)
                }
            }
            #endif
        }
        .environment(\.zoomNamespace, zoomNamespace)
        .environment(tabBarScroll)
        .onChange(of: selectedDestinationID) { _, _ in tabBarScroll.reset() }
        .onChange(of: router.path.count) { _, _ in tabBarScroll.reset() }
    }

    #if os(iOS)
    private var mobileGlassTabBar: some View {
        MobileGlassNavigationBar(
            items: visibleDestinations.map { .init(id: String(describing: $0.id), title: $0.title, icon: $0.icon, selectedIcon: $0.selectedIcon) },
            selectedID: String(describing: selectedDestinationID),
            onSelect: { id in
                guard let destination = visibleDestinations.first(where: { String(describing: $0.id) == id }) else { return }
                selectedDestinationID = destination.id
            },
            onSearch: presentSearchPage,
            onProfile: presentSettingsPage
        )
    }

    private func presentSearchPage() {
        PlayerOrientationCoordinator.shared.setPortraitPagePresented(UIDevice.current.userInterfaceIdiom != .pad)
        showsSettingsPage = false
        withAnimation(.easeInOut(duration: 0.34)) {
            showsSearchPage = true
        }
    }

    private func presentSettingsPage() {
        PlayerOrientationCoordinator.shared.setPortraitPagePresented(UIDevice.current.userInterfaceIdiom != .pad)
        showsSearchPage = false
        withAnimation(.easeInOut(duration: 0.34)) {
            showsSettingsPage = true
        }
    }

    private func dismissSearchPage() {
        withAnimation(.easeInOut(duration: 0.34), completionCriteria: .logicallyComplete) {
            showsSearchPage = false
        } completion: {
            updateMobileUtilityOrientationPolicy()
        }
    }

    private func dismissSettingsPage() {
        withAnimation(.easeInOut(duration: 0.34), completionCriteria: .logicallyComplete) {
            showsSettingsPage = false
        } completion: {
            updateMobileUtilityOrientationPolicy()
        }
    }

    private func updateMobileUtilityOrientationPolicy() {
        PlayerOrientationCoordinator.shared.setPortraitPagePresented(
            (showsSettingsPage || showsSearchPage) && UIDevice.current.userInterfaceIdiom != .pad
        )
    }

    private var showsMobileUtilityPage: Bool {
        showsSearchPage || showsSettingsPage
    }
    #endif

    /// iPad regular width: the native sidebar overlays the detail pane without
    /// changing its original system material or row-selection appearance.
    /// macOS keeps the standard side-by-side split-view layout.
    ///
    /// Home / Libraries / Recommendations hide the nav bar (so SwiftUI's
    /// default sidebar toggle isn't visible on those screens). We inject a
    /// toggle closure through `\.sidebarToggle` instead — each custom header
    /// renders a `SidebarToggleButton` on its leading edge while the overlay is
    /// closed. Video playback doesn't overlap the sidebar because the player is
    /// presented via `fullScreenCover` on `router.presentedPlayer` rather than
    /// pushed into the detail pane.
    private var sidebarLayout: some View {
        Group {
            #if os(iOS)
            iPadSidebarLayout
                .environment(
                    \.sidebarToggle,
                    iPadColumnVisibility == .detailOnly ? toggleSidebar : nil
                )
                .environment(\.reservesSidebarToggleSpace, true)
            #else
            macSidebarLayout
                .environment(\.sidebarToggle, toggleSidebar)
            #endif
        }
        .environment(\.zoomNamespace, zoomNamespace)
    }

    #if os(iOS)
    private let iPadSidebarWidth: CGFloat = 320

    private var iPadSidebarLayout: some View {
        NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
            sidebarList(
                dismissAfterSelection: true
            )
                .background {
                    FixedPrimarySplitViewWidth(
                        width: iPadSidebarWidth,
                        sidebarIsHidden: iPadColumnVisibility == .detailOnly,
                        onSwipeLeft: finishInteractiveSidebarDismissal
                    )
                        .frame(width: 0, height: 0)
                }
                .navigationSplitViewColumnWidth(
                    min: iPadSidebarWidth,
                    ideal: iPadSidebarWidth,
                    max: iPadSidebarWidth
                )
                .toolbar(removing: .sidebarToggle)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    iPadSidebarHeader
                }
        } detail: {
            sidebarDetailContent
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.prominentDetail)
    }

    /// Custom sidebar header replacing the navigation bar so the server name
    /// and close button can sit lower than the system bar allows.
    private var iPadSidebarHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(
                    width: VividTheme.topBarIconHitSize,
                    height: VividTheme.topBarIconHitSize
                )
                .accessibilityHidden(true)

            Text(sidebarTitle)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: dismissSidebar) {
                Image(systemName: "arrow.left")
                    .font(.body.weight(.semibold))
                    .frame(
                        width: VividTheme.topBarIconHitSize,
                        height: VividTheme.topBarIconHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sidebar")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    #else
    private var macSidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarList(
                dismissAfterSelection: false
            )
                .navigationTitle(sidebarTitle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 280)
        } detail: {
            sidebarDetailContent
        }
    }
    #endif

    private var sidebarDetailContent: some View {
        NavigationStack(path: $router.path) {
            destinationContent(for: selectedDestination)
                .id(selectedDestination.id)
                .navigationDestination(for: Route.self) { route in
                    routeContent(for: route)
                        #if os(iOS)
                        .toolbar {
                            if routeNeedsSidebarToggle(route) {
                                ToolbarItem(placement: .topBarLeading) {
                                    SidebarToggleButton()
                                }
                            }
                        }
                        #endif
                }
        }
    }

    private func sidebarList(
        dismissAfterSelection: Bool
    ) -> some View {
        List(selection: Binding<MainTabDestinationID?>(
            get: { selectedDestinationID },
            set: { value in
                guard let value else { return }
                selectSidebarDestination(value)
                if dismissAfterSelection {
                    dismissSidebar()
                }
            }
        )) {
            ForEach(visibleDestinations) { destination in
                Label(
                    destination.title,
                    systemImage: selectedDestinationID == destination.id
                        ? destination.selectedIcon
                        : destination.icon
                )
                .tag(destination.id)
            }
        }
        // The sidebar's few rows rarely overflow; without this the list
        // still rubber-bands on drag, visually dragging the whole bar.
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Collapses or re-expands the sidebar without moving the detail content.
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            #if os(iOS)
            iPadColumnVisibility = iPadColumnVisibility == .detailOnly ? .all : .detailOnly
            #else
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            #endif
        }
    }

    /// Sidebar rows are root destinations, even when the same row is already
    /// selected beneath a pushed screen. Clear the detail stack first so, for
    /// example, tapping Home while Search is open actually returns to Home.
    private func selectSidebarDestination(_ destinationID: MainTabDestinationID) {
        router.popToRoot()
        selectedDestinationID = destinationID
    }

    private func dismissSidebar() {
        #if os(iOS)
        guard iPadColumnVisibility != .detailOnly else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            iPadColumnVisibility = .detailOnly
        }
        #endif
    }

    #if os(iOS)
    private func finishInteractiveSidebarDismissal() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            iPadColumnVisibility = .detailOnly
        }
    }
    #endif

    @ViewBuilder
    private func destinationContent(for destination: MainTabDestination) -> some View {
        switch destination.id {
        case .app(let tab):
            tabContent(for: tab)
        case .libraryCategory(let category):
            LibrariesTabView(
                category: category,
                libraryAuthority: currentLibraryAuthority,
                onLibrariesLoaded: acceptLoadedLibraries
            )
        }
    }

    private func acceptLoadedLibraries(
        authority: MainTabLibraryAuthority?,
        libraries: [Library]
    ) {
        guard let authority, authority == currentLibraryAuthority else { return }
        librarySnapshot = .init(authority: authority, libraries: libraries)
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()

        case .libraries:
            LibrariesTabView(
                libraryAuthority: currentLibraryAuthority,
                onLibrariesLoaded: acceptLoadedLibraries
            )

        case .search:
            SearchView()

        case .recommendations:
            RecommendationsView()

        case .downloads:
            #if os(tvOS)
            EmptyView()
            #else
            DownloadsView()
            #endif

        case .settings:
            SettingsView()

        case .switchProfile, .switchServer:
            // tvOS-only sidebar shortcuts; filtered out of iOS visibleCases.
            EmptyView()
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
        case .itemDetail(let contentId, _):
            ItemDetailView(contentId: contentId)
                // The iOS 26 poster → detail zoom transition
                // (`.navigationTransition(.zoom(sourceID:in:))`, keyed off
                // `pendingZoomSourceID`) is intentionally NOT applied here.
                // On iOS 26 the zoom transition keeps the pushed detail bound
                // to the source card's portal geometry; rotating the device
                // while the detail is up recomputes that transform against
                // stale geometry, leaving the whole page scaled up ("zoomed
                // in") after rotating back and the source card stuck on
                // screen. Deep-linked pushes (no zoom source) never showed
                // the bug. Restore the modifier once Apple fixes the
                // regression (see forums thread 807208).
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        #if os(iOS)
        case .studioNetwork(let brandId):
            PhoneStudioNetworkPage(brandId: brandId)
        #endif
        case .player(let contentId, let startFromBeginning, let resumePosition, let prefersLastUsedVersion):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition,
                prefersLastUsedVersion: prefersLastUsedVersion
            )
            #else
            // Player is presented as a full-screen cover (see MainTabView)
            // so it isn't boxed into the iPad detail pane. This route arm
            // exists only so switch exhaustiveness holds.
            EmptyView()
            #endif
        case .playerWithFile(
            let contentId,
            let fileId,
            let audioTrackIndex,
            let subtitleTrackIndex,
            let startFromBeginning,
            let resumePosition
        ):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                preferredFileId: fileId,
                preferredAudioTrackIndex: audioTrackIndex,
                preferredSubtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
            #else
            EmptyView()
            #endif
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
            SearchView()
        case .settings:
            SettingsView()
        case .recommendations:
            RecommendationsView()
        case .serverList:
            ServerListView()
        case .downloads:
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividPageBackground()
            #else
            DownloadsView()
            #endif
        case .offlinePlayer(let downloadId, let contentId, let startFromBeginning, let resumePosition):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition,
                offlineDownloadId: downloadId
            )
            #else
            // Presented as a full-screen cover (see MainTabView). This arm
            // exists only for switch exhaustiveness.
            EmptyView()
            #endif
        case .offlineSeriesBrowse(let seriesId):
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividPageBackground()
            #else
            OfflineSeriesBrowseView(seriesId: seriesId)
            #endif
        case .offlineDownloadDetail(let downloadId):
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividPageBackground()
            #else
            OfflineDownloadDetailView(downloadId: downloadId)
            #endif
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividPageBackground()
        }
    }

    #if os(iOS)
    private func routeNeedsSidebarToggle(_ route: Route) -> Bool {
        switch route {
        case .downloads, .recommendations:
            false
        default:
            true
        }
    }
    #endif
}
