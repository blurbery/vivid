#if os(iOS)
import SwiftUI
import UIKit

/// The signed-in shell on iPhone and iPad: one navigation stack under a
/// glass tab bar, with Search and Settings opening as pages over it.
struct MainTabView: View {
    @Bindable var router: AppRouter

    @AppStorage private var showsDownloadsTab: Bool
    @AppStorage private var showsCalendarTab: Bool
    @State private var tabBarScroll = MobileTabBarScrollState()
    @State private var showsSearchPage = false
    @State private var showsSettingsPage = false
    @State private var duoSideStrip: PhoneDuo.SideStrip?
    @State private var duoControlCorner: PhoneDuo.ControlCorner?
    @State private var usesPadSideBar = false
    @State private var selectedID: MainTabDestinationID = .app(.home)
    @State private var librarySnapshot: MainTabLibrarySnapshot
    @State private var libraryRefreshes = 0
    @Namespace private var zoomNamespace
    @Environment(\.scenePhase) private var scenePhase

    init(router: AppRouter) {
        self.router = router
        _showsDownloadsTab = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showDownloadsTab"))
        _showsCalendarTab = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab"))
        _librarySnapshot = State(initialValue: MainTabLibrarySnapshot.cachedForCurrentAuthority())
    }

    // MARK: Tabs

    private var currentAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: ServerRegistry.shared.activeServerId,
            profileId: ServerRegistry.shared.activeProfileId
        )
    }

    private var visibleDestinations: [MainTabDestination] {
        var destinations = projectedMainTabDestinations(
            primaryMenu: UICustomizationPreferences.shared.primaryMenu,
            availableLibraries: librarySnapshot.availableLibraries(for: currentAuthority)
        )
        if showsCalendarTab, !destinations.contains(where: { $0.id == .app(.calendar) }) {
            destinations.append(.app(.calendar))
        }
        if showsDownloadsTab, !destinations.contains(where: { $0.id == .app(.downloads) }) {
            destinations.append(.app(.downloads))
        }
        return destinations
    }

    private var selectedDestination: MainTabDestination {
        visibleDestinations.first { $0.id == selectedID } ?? .app(.home)
    }

    private var isPageShown: Bool { showsSearchPage || showsSettingsPage }

    // MARK: Body

    var body: some View {
        layeredShell
            .task(id: LibraryRefreshKey(authority: currentAuthority, activation: libraryRefreshes)) {
                await refreshLibraries(for: currentAuthority)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { libraryRefreshes += 1 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) { notification in
                applyRefreshedLibraries(notification)
            }
            .onChange(of: router.requestedTab, initial: true) {
                applyRequestedTab()
            }
            .onChange(of: showsDownloadsTab) {
                keepSelectionVisible(resettingTabBar: true)
            }
            .onChange(of: showsCalendarTab) {
                keepSelectionVisible(resettingTabBar: true)
            }
            .onChange(of: UICustomizationPreferences.shared.primaryMenu) {
                keepSelectionVisible()
            }
            .onChange(of: librarySnapshot) {
                keepSelectionVisible()
            }
            .task {
                await startOnDownloadsIfOffline()
            }
            .modifier(PlayerPresentationModifier(router: router))
            .modifier(ItemDetailPresentationModifier(router: router, zoomNamespace: zoomNamespace))
            .environment(router)
    }

    private var layeredShell: some View {
        GeometryReader { geometry in
            ZStack {
                tabLayout
                    .allowsHitTesting(!isPageShown)
                    .accessibilityHidden(isPageShown)

                if let duoSideStrip, router.path.isEmpty {
                    duoSideTabBar(duoSideStrip)
                        .allowsHitTesting(!isPageShown)
                        .accessibilityHidden(isPageShown)
                }

                if showsSearchPage {
                    MobileSearchPage(safeAreaInsets: geometry.safeAreaInsets, onDismiss: dismissSearch)
                        .transition(.move(edge: .bottom))
                        .zIndex(10)
                }

                if showsSettingsPage {
                    MobileSettingsPage(router: router, safeAreaInsets: geometry.safeAreaInsets, onDismiss: dismissSettings)
                        .transition(.move(edge: .bottom))
                        .zIndex(10)
                }
            }
            .environment(\.usesDuoSideTabBar, duoSideStrip?.edge != nil)
            .environment(\.duoSideStrip, duoSideStrip)
            .environment(\.duoControlCorner, duoControlCorner)
            .onChange(of: LayoutFrame(geometry), initial: true) {
                updateLayout(geometry)
            }
            .onChange(of: PhoneDuo.isInnerScreen(geometry)) { _, isInnerScreen in
                guard PhoneDuo.isDuo else { return }
                // Folding moves the app between screens.
                PlayerOrientationCoordinator.shared.duoScreenDidChange(portraitPagePresented: isPageShown && !isInnerScreen)
            }
        }
        .readsDuoStatusArea()
        .ignoresSafeArea(.keyboard, edges: isPageShown ? [] : .bottom)
        .tint(Color.vividOnSurface)
    }

    private var tabLayout: some View {
        NavigationStack(path: $router.path) {
            rootPage(for: selectedDestination.id)
                .id(selectedID)
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: duoSideStrip == nil ? 2 : 0) {
                    if router.path.isEmpty, duoSideStrip == nil, !usesPadSideBar {
                        bottomTabBar
                    }
                }
                .safeAreaInset(edge: .trailing, spacing: 2) {
                    if router.path.isEmpty, usesPadSideBar {
                        glassTabBar(isVertical: true)
                            .frame(maxHeight: .infinity)
                            .padding(.trailing, 16)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    pushedPage(for: route)
                        .duoStripBackButton()
                }
        }
        .environment(\.zoomNamespace, zoomNamespace)
        .environment(tabBarScroll)
        .onChange(of: selectedID) { tabBarScroll.reset() }
        .onChange(of: router.path.count) { tabBarScroll.reset() }
    }

    private var bottomTabBar: some View {
        let isHidden = tabBarScroll.isHidden
        return glassTabBar(isVertical: false)
            .padding(.horizontal, 16)
            .padding(.bottom, 0)
            .offset(y: isHidden ? 90 : 0)
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .accessibilityHidden(isHidden)
            .animation(.easeInOut(duration: 0.22), value: isHidden)
    }

    /// On the Duo the bar stands in the status bar strip, on the status
    /// icons' line.
    private func duoSideTabBar(_ strip: PhoneDuo.SideStrip) -> some View {
        let growth = DuoStatusArea.shared.growth
        let alignment: Alignment = strip.isInnerScreen
            ? (strip.edge == .trailing ? .trailing : .leading)
            : (strip.edge == .trailing ? .bottomTrailing : .bottomLeading)
        let columnWidth: CGFloat = 2 * 36
        return glassTabBar(isVertical: true)
            .frame(width: columnWidth)
            .frame(maxHeight: 420 - growth)
            .padding(.top, 150 + growth)
            .padding(.bottom, strip.isInnerScreen ? 0 : PhoneDuo.pageTabsBottomPadding + PhoneDuo.pageTabsRowHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .offset(x: strip.edge == .trailing ? columnWidth : -columnWidth)
    }

    private func glassTabBar(isVertical: Bool) -> some View {
        let destinations = visibleDestinations
        return MobileGlassNavigationBar(
            items: destinations.map {
                MobileGlassNavigationBar.Item(id: Self.itemID($0.id), title: $0.title, icon: $0.icon, selectedIcon: $0.selectedIcon)
            },
            selectedID: Self.itemID(selectedDestination.id),
            onSelect: { itemID in
                if let destination = destinations.first(where: { Self.itemID($0.id) == itemID }) {
                    selectedID = destination.id
                }
            },
            onSearch: presentSearch,
            onProfile: presentSettings,
            isVertical: isVertical
        )
    }

    private static func itemID(_ id: MainTabDestinationID) -> String {
        switch id {
        case .app(let tab): "app.\(tab.rawValue)"
        case .libraryCategory(let category): "category.\(category.rawValue)"
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func rootPage(for id: MainTabDestinationID) -> some View {
        switch id {
        case .app(.home):
            HomeView()
        case .app(.libraries):
            LibrariesTabView(libraryAuthority: currentAuthority, onLibrariesLoaded: storeReportedLibraries)
        case .app(.recommendations):
            RecommendationsView()
        case .app(.calendar):
            CalendarView()
        case .app(.downloads):
            DownloadsView()
        case .libraryCategory(let category):
            LibrariesTabView(category: category, libraryAuthority: currentAuthority, onLibrariesLoaded: storeReportedLibraries)
        case .app:
            unknownPage
        }
    }

    @ViewBuilder
    private func pushedPage(for route: Route) -> some View {
        switch route {
        case .libraryCollection(let libraryId, let collectionId, let title, let kind):
            LibraryCollectionDetailView(libraryId: libraryId, collectionId: collectionId, title: title, kind: kind)
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        case .studioNetwork(let brandId):
            PhoneStudioNetworkPage(brandId: brandId)
        case .player:
            // The player is a cover, not a page.
            EmptyView()
        case .offlineSeriesBrowse(let seriesId):
            OfflineSeriesBrowseView(seriesId: seriesId)
        case .offlineDownloadDetail(let downloadId):
            OfflineDownloadDetailView(downloadId: downloadId)
        default:
            unknownPage
        }
    }

    private var unknownPage: some View {
        EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
            .vividPageBackground()
    }

    private func presentSearch() {
        let orientation = PlayerOrientationCoordinator.shared
        orientation.setPortraitPagePresented(!orientation.rotatesBrowsing)
        showsSettingsPage = false
        withAnimation(.easeInOut(duration: 0.34)) { showsSearchPage = true }
    }

    private func presentSettings() {
        let orientation = PlayerOrientationCoordinator.shared
        orientation.setPortraitPagePresented(!orientation.rotatesBrowsing)
        showsSearchPage = false
        withAnimation(.easeInOut(duration: 0.34)) { showsSettingsPage = true }
    }

    private func dismissSearch() {
        withAnimation(.easeInOut(duration: 0.34), completionCriteria: .logicallyComplete) {
            showsSearchPage = false
        } completion: {
            pageDismissalDidFinish()
        }
    }

    private func dismissSettings() {
        withAnimation(.easeInOut(duration: 0.34), completionCriteria: .logicallyComplete) {
            showsSettingsPage = false
        } completion: {
            pageDismissalDidFinish()
        }
    }

    private func pageDismissalDidFinish() {
        let orientation = PlayerOrientationCoordinator.shared
        orientation.setPortraitPagePresented(isPageShown && !orientation.rotatesBrowsing)
    }

    // MARK: Layout

    /// The window's size and safe areas, which decide where the bar goes.
    private struct LayoutFrame: Equatable {
        let size: CGSize
        let insets: EdgeInsets

        init(_ geometry: GeometryProxy) {
            size = geometry.size
            insets = geometry.safeAreaInsets
        }
    }

    private func updateLayout(_ geometry: GeometryProxy) {
        let insets = geometry.safeAreaInsets
        let windowWidth = geometry.size.width + insets.leading + insets.trailing
        let windowHeight = geometry.size.height + insets.top + insets.bottom
        usesPadSideBar = UIDevice.current.userInterfaceIdiom == .pad && windowWidth > windowHeight
        guard PhoneDuo.isDuo else { return }
        duoSideStrip = PhoneDuo.sideStrip(geometry)
        duoControlCorner = PhoneDuo.controlCorner(geometry)
    }

    // MARK: Libraries and selection

    private func refreshLibraries(for requested: MainTabLibraryAuthority?) async {
        let kept = librarySnapshot.authority == requested ? librarySnapshot.libraries : []
        librarySnapshot = MainTabLibrarySnapshot(authority: requested, libraries: kept)
        guard let requested else { return }
        guard let response = try? await StartupContentPrefetcher.fetchUserLibraries(),
              !Task.isCancelled, requested == currentAuthority else { return }
        librarySnapshot = MainTabLibrarySnapshot(authority: requested, libraries: response.libraries)
    }

    private func applyRefreshedLibraries(_ notification: Notification) {
        guard let response = notification.object as? LibrariesResponse, let authority = currentAuthority else { return }
        librarySnapshot = MainTabLibrarySnapshot(authority: authority, libraries: response.libraries)
    }

    private func storeReportedLibraries(_ authority: MainTabLibraryAuthority?, _ libraries: [Library]) {
        guard let authority, authority == currentAuthority else { return }
        librarySnapshot = MainTabLibrarySnapshot(authority: authority, libraries: libraries)
    }

    private func applyRequestedTab() {
        guard let tab = router.requestedTab else { return }
        selectedID = resolvedRequestedMainTabDestination(tab, visibleDestinations: visibleDestinations)
        router.requestedTab = nil
    }

    private func keepSelectionVisible(resettingTabBar: Bool = false) {
        selectedID = resolvedVisibleMainTabDestination(selectedID, visibleDestinations: visibleDestinations)
        if resettingTabBar { tabBarScroll.reset() }
    }

    /// Offline at launch with something to watch: start on Downloads.
    private func startOnDownloadsIfOffline() async {
        let connection = ConnectionMonitor.shared
        await connection.waitForInitialPath()
        guard !connection.isDeviceOnline else { return }
        let downloads = DownloadManager.shared
        await downloads.activateScopeIfNeeded()
        guard downloads.downloadsEnabled, downloads.records.contains(where: \.isPlayableOffline),
              selectedID == .app(.home), router.requestedTab == nil else { return }
        selectedID = .app(.downloads)
    }
}

/// The library fetch reruns when the authority changes and on every scene
/// activation.
private struct LibraryRefreshKey: Equatable {
    let authority: MainTabLibraryAuthority?
    let activation: Int
}

#endif
