#if os(tvOS)
import SwiftUI

extension EnvironmentValues {
    /// The namespace Spotlight cards register their zoom sources in.
    @Entry var tvSpotlightZoomSpace: Namespace.ID? = nil
}

/// The zoom source ID for the Spotlight card at a carousel position. Loop
/// copies of a slide sit at different positions, so each copy is distinct.
func tvSpotlightZoomSourceID(position: Int) -> String {
    "spotlight.\(position)"
}

/// Zooms a detail page out of the Spotlight card that opened it, and back
/// into it on Back. Other pages keep the standard push, as does Reduce Motion.
struct TVSpotlightZoomTransition: ViewModifier {
    let sourceID: String?
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let sourceID, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

/// The signed-in Apple TV app: the top bar, the root pages, the navigation
/// stack and the player, and the focus hand-offs between them.
struct TVMainTabView: View {
    @Bindable var router: AppRouter

    /// A page the top bar can show.
    enum Root: Hashable {
        case home
        /// Every movie and series library, then Watchlist, Favourites and
        /// Collections.
        case library
        case calendar

        var title: String {
            switch self {
            case .home: String(localized: "Home")
            case .library: String(localized: "Library")
            case .calendar: String(localized: "Calendar")
            }
        }

        /// The symbol the bar shows while the tab is neither selected nor
        /// focused, the same one as on iPhone and iPad.
        var symbol: String {
            switch self {
            case .home: AppTab.home.icon
            case .library: AppTab.libraries.icon
            case .calendar: AppTab.calendar.icon
            }
        }

        var accessibilityHint: Text {
            switch self {
            case .library: Text("Open your libraries, Watchlist, Favourites, or Collections")
            case .calendar: Text("Open Upcoming or Trending")
            default: Text("Open page")
            }
        }
    }

    @State private var selectedRoot: Root = .home
    @State private var forYouTab: ForYouTab = .watchlist
    @State private var calendarPage: TVCalendarView.Page = .upcoming
    @State private var libraries: [Library]
    @State private var libraryAuthority: MainTabLibraryAuthority?
    @State private var barFocused = false
    @State private var barSuppressed = true
    @State private var homeAllowsBarFocus = false
    @State private var barOwnsFocusAfterPop = false
    @State private var heldSearchRequest: AppRouter.SearchRequest?
    @State private var siriSearchNeedsFocus = false
    @State private var returningFromSettings = false
    @State private var barFocusRequest = 0
    @State private var barFocusResetRequest = 0
    /// Starts at 1 so Home claims focus when it first appears.
    @State private var contentFocusRequest = 1
    @State private var detailReturnFocusRequest = 0
    @AppStorage private var showsCalendar: Bool
    @AppStorage private var swapsUtilities: Bool
    @Namespace private var rootScope
    /// Shared by the Spotlight cards and the detail pages they zoom into.
    @Namespace private var spotlightZoomSpace
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(router: AppRouter) {
        self.router = router
        _libraries = State(
            initialValue: ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self)?.libraries ?? []
        )
        _libraryAuthority = State(initialValue: MainTabLibraryAuthority(
            serverId: ServerRegistry.shared.activeServerId,
            profileId: ServerRegistry.shared.activeProfileId
        ))
        _showsCalendar = AppStorage(wrappedValue: true, MobileProfilePreferenceKeys.key("vivid.mobile.showCalendarTab"))
        _swapsUtilities = AppStorage(wrappedValue: false, MobileProfilePreferenceKeys.key("vivid.mobile.swapMenuUtilities"))
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $router.path) {
                rootContent
                    .environment(\.tvSpotlightZoomSpace, spotlightZoomSpace)
                    .navigationDestination(for: Route.self) { destination(for: $0) }
                    .navigationDestination(for: TVSettingsCategory.self) { category in
                        if category == .about {
                            AboutSettingsView()
                        } else {
                            TVSettingsView(category: category)
                        }
                    }
                    .navigationDestination(for: TVAccountRoute.self) { route in
                        switch route {
                        case .editor(let accountID):
                            TVSavedAccountEditor(accountID: accountID)
                        case .profiles:
                            TVSettingsProfilesPage()
                        }
                    }
            }
            if router.path.isEmpty {
                // Fades with the page transition rather than popping.
                topBar
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .tint(Color.vividOnSurface)
        .onPreferenceChange(TVHomeTopMenuAvailabilityKey.self) { homeAllowsBarFocus = $0 }
        .fullScreenCover(item: $router.presentedPlayer) { playerCover($0) }
        .environment(router)
        .modifier(FocusWatchdog(
            isActive: scenePhase == .active && router.presentedPlayer == nil,
            onRepair: repairFocus
        ))
        // Another profile or server starts on the base theme, even if it
        // changed while the player was up.
        .onChange(of: currentAuthority) { TVAdaptiveAmbience.shared.reset() }
        .task(id: currentAuthority) {
            let authority = currentAuthority
            await CurrentProfileStore.shared.refresh()
            await loadLibraries(for: authority)
        }
        .task { await UICustomizationPreferences.shared.refresh() }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            let authority = currentAuthority
            Task { await loadLibraries(for: authority) }
        }
        .onChange(of: router.path.isEmpty, initial: true) {
            TVAdaptiveAmbience.shared.isOnRootPage = router.path.isEmpty
        }
        .onChange(of: router.path.isEmpty) { pathEmptinessChanged() }
        .onChange(of: router.path.count) { old, new in
            TVSpotlightLogoFlight.shared.pathCountChanged(from: old, to: new)
        }
        // The shell goes away with the profile picker, session expiry or
        // sign-in, in the same update as those, so the counter below never
        // reaches it then; anything opened from the Spotlight is gone too.
        .onDisappear {
            TVSpotlightLogoFlight.shared.stackReplaced()
            // Kept while the player covers the shell, so playback returns
            // to the same colour.
            if router.presentedPlayer == nil { TVAdaptiveAmbience.shared.reset() }
        }
        .onChange(of: router.stackRootReplacements) {
            // The page the Spotlight opened was swapped out (Search replacing
            // the stack, say), so Back no longer returns to its card.
            TVSpotlightLogoFlight.shared.stackReplaced()
        }
        .onChange(of: router.requestedTab) { handleRequestedTab() }
        .onChange(of: router.requestedSearch, initial: true) { handleSiriSearch() }
        .onChange(of: isEnabled) {
            guard isEnabled, siriSearchNeedsFocus else { return }
            siriSearchNeedsFocus = false
            DispatchQueue.main.async { FocusWatchdog.reResolveFocus() }
        }
        .onChange(of: visibleRoots) { _, roots in rootsChanged(roots) }
    }

    // MARK: Root content

    private var rootContent: some View {
        ZStack(alignment: .top) {
            TVAppBackdrop()
            // Theme Mode Adaptive. Outside the page's identity, so it keeps
            // the last colour across tab changes.
            TVAdaptiveBackdrop()
            rootPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(selectedRoot)
                .transition(reduceMotion ? .identity : .opacity)
                .focusScope(rootScope)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onExitCommand {
            if router.path.isEmpty {
                focusBar()
            } else {
                router.goBack()
            }
        }
    }

    @ViewBuilder
    private var rootPage: some View {
        switch selectedRoot {
        case .home:
            HomeView(
                homeFocusRequest: contentFocusRequest,
                detailReturnFocusRequest: detailReturnFocusRequest,
                isTopMenuFocused: barFocused,
                onTopMenuFocusRequest: focusBar
            )
        case .calendar:
            TVCalendarView(
                page: $calendarPage,
                focusRequest: contentFocusRequest,
                isTopMenuFocused: barFocused,
                onTopMenuFocusRequest: focusBar
            )
        case .library:
            LibraryRootPage(
                tab: $forYouTab,
                libraries: browsableLibraries,
                focusRequest: contentFocusRequest,
                isTopMenuFocused: barFocused,
                onTopMenuFocusRequest: focusBar
            )
        }
    }

    private var topBar: some View {
        TopBar(
            roots: visibleRoots,
            profile: CurrentProfileStore.shared.profile,
            swapsUtilities: swapsUtilities,
            selectedRoot: $selectedRoot,
            isFocused: $barFocused,
            isSuppressed: $barSuppressed,
            homeAllowsFocus: $homeAllowsBarFocus,
            focusRequest: barFocusRequest,
            focusResetRequest: barFocusResetRequest,
            onSelect: { selectRoot($0) },
            onSearch: openSearch,
            onProfile: openSettings,
            onContentHandOff: handOffToContent,
            onExit: selectedRoot == .home ? nil : returnHomeInBar,
            isCovered: !router.path.isEmpty || router.presentedPlayer != nil
        )
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .library(let libraryId, _):
            if let library = browsableLibraries.first(where: { $0.id == libraryId }) {
                LibraryPage(library: library)
            } else {
                EmptyStateView(icon: "square.stack.3d.up", title: "No libraries")
                    .vividBackground()
            }
        case .libraryCollection(let libraryId, let collectionId, let title, let kind):
            LibraryCollectionDetailView(libraryId: libraryId, collectionId: collectionId, title: title, kind: kind)
        case .itemDetail(let contentId, let seed):
            ItemDetailView(contentId: contentId, tvSeed: seed)
                .modifier(TVSpotlightZoomTransition(sourceID: seed?.zoomSourceID, namespace: spotlightZoomSpace))
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
        case .requestDetail(let mediaType, let tmdbId):
            RequestDetailView(mediaType: mediaType, tmdbId: tmdbId)
        case .search:
            SearchView(usesTVTopMenuInset: false, seededQuery: $heldSearchRequest)
        case .settings:
            TVSettingsView()
        case .serverList:
            ServerListView()
        case .serverSetup:
            TVServerSetupView(router: router)
        case .studioNetwork(let brandId):
            TVStudioNetworkPage(brandId: brandId)
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown")
                .vividBackground()
        }
    }

    private func playerCover(_ presentation: AppRouter.PlayerPresentation) -> some View {
        PlayerView(
            contentId: presentation.contentId,
            preferredFileId: presentation.fileId,
            preferredAudioTrackIndex: presentation.audioTrackIndex,
            preferredSubtitleTrackIndex: presentation.subtitleTrackIndex,
            startFromBeginning: presentation.startFromBeginning,
            resumePositionOverride: presentation.resumePosition,
            prefersLastUsedVersion: presentation.prefersLastUsedVersion,
            posterURLHint: presentation.posterURL,
            backdropURLHint: presentation.backdropURL,
            onPlaybackStarted: {
                guard let returnId = presentation.returnToContentId,
                      router.presentedPlayer?.id == presentation.id else { return }
                router.replaceCurrent(with: .itemDetail(contentId: returnId))
            }
        )
    }

    // MARK: Roots and libraries

    private var currentAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: ServerRegistry.shared.activeServerId,
            profileId: ServerRegistry.shared.activeProfileId
        )
    }

    /// Home and Library, in the saved menu's order, then Calendar after
    /// Library when it's on. Library is always offered: it is the only way
    /// to the libraries and the personal lists.
    private var visibleRoots: [Root] {
        let items = UICustomizationPreferences.shared.resolvedPrimaryMenuItems(availableLibraries: libraries)
        var roots: [Root] = tvTabBarLibraryLeadsHome(in: items) ? [.library, .home] : [.home, .library]
        if showsCalendar, let library = roots.firstIndex(of: .library) {
            roots.insert(.calendar, at: library + 1)
        }
        return roots
    }

    /// The movie, series and mixed libraries in the server's order.
    private var browsableLibraries: [Library] { LibraryRowOrderStore.browsable(libraries) }

    private func loadLibraries(for authority: MainTabLibraryAuthority?) async {
        if authority != libraryAuthority {
            libraryAuthority = authority
            libraries = []
            ensureSelectedRootVisible()
        }
        guard authority != nil else { return }
        if libraries.isEmpty, let cached = ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self) {
            libraries = cached.libraries
            ensureSelectedRootVisible()
        }
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentAuthority == authority else { return }
            libraryAuthority = authority
            libraries = response.libraries
            ensureSelectedRootVisible()
        } catch {
            // Whatever is shown stays; Home and Calendar remain reachable.
        }
    }

    private func ensureSelectedRootVisible(requestingFocus: Bool = true) {
        guard !visibleRoots.contains(selectedRoot) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectedRoot = .home }
        if requestingFocus { contentFocusRequest += 1 }
    }

    private func rootsChanged(_ roots: [Root]) {
        let rearm = tvVisibleRootsFocusRearm(
            menuOwnedFocus: !barSuppressed,
            isShowingRoot: router.path.isEmpty,
            selectedRootWasRemoved: !roots.contains(selectedRoot)
        )
        ensureSelectedRootVisible(requestingFocus: false)
        switch rearm {
        case .topMenu:
            focusBar()
        case .content:
            handOffToContent()
            contentFocusRequest += 1
        case .none:
            break
        }
    }

    // MARK: Focus hand-offs

    private func selectRoot(_ root: Root, animated: Bool = true) {
        let wasSelected = root == selectedRoot
        router.popToRoot()
        handOffToContent()
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: 0.2) : nil) {
            selectedRoot = root
        }
        if wasSelected {
            // After the bar has resigned focus.
            DispatchQueue.main.async { contentFocusRequest += 1 }
        } else {
            contentFocusRequest += 1
        }
    }

    private func handOffToContent() {
        barFocused = false
        barSuppressed = true
    }

    private func focusBar() {
        guard router.path.isEmpty else { return }
        barFocused = true
        withAnimation(reduceMotion ? nil : VividTheme.springAnimation) {
            barSuppressed = false
        }
        DispatchQueue.main.async {
            guard router.path.isEmpty, barFocused, !barSuppressed else { return }
            barFocusRequest += 1
        }
    }

    /// Menu from a bar item away from Home: Home is selected in place and
    /// the bar keeps focus on its tab.
    private func returnHomeInBar() {
        selectedRoot = .home
        withAnimation(reduceMotion ? nil : VividTheme.springAnimation) {
            barSuppressed = false
            barFocusRequest += 1
        }
    }

    private func openSearch() {
        barOwnsFocusAfterPop = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { router.navigate(to: .search) }
    }

    private func openSettings() {
        barOwnsFocusAfterPop = true
        router.navigate(to: .settings)
    }

    private func pathEmptinessChanged() {
        guard router.path.isEmpty else { return }
        if returningFromSettings {
            // Selecting Home already handed focus over once.
            returningFromSettings = false
            return
        }
        handOffToContent()
        if barOwnsFocusAfterPop {
            barOwnsFocusAfterPop = false
            DispatchQueue.main.async { focusBar() }
        } else {
            detailReturnFocusRequest += 1
        }
    }

    private func handleRequestedTab() {
        guard let tab = router.requestedTab else { return }
        router.requestedTab = nil
        guard tab == .home else { return }
        if !router.path.isEmpty { returningFromSettings = true }
        barOwnsFocusAfterPop = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectRoot(.home, animated: false) }
    }

    private func handleSiriSearch() {
        guard let request = router.requestedSearch else { return }
        router.requestedSearch = nil
        heldSearchRequest = request
        if !isEnabled { siriSearchNeedsFocus = true }
        router.presentedPlayer = nil
        barOwnsFocusAfterPop = true
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { router.showSearchReplacingStack() }
    }

    private func repairFocus() {
        barFocusResetRequest += 1
        if router.path.isEmpty {
            handOffToContent()
            contentFocusRequest += 1
        } else {
            FocusWatchdog.reResolveFocus()
        }
    }
}
#endif
