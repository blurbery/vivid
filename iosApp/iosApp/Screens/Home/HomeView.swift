import SwiftUI

extension Notification.Name {
    static let homeSectionsShouldRefresh = Notification.Name("homeSectionsShouldRefresh")
}

/// Home rows with an optional, independent spotlight on tvOS.
struct HomeView: View {
    var homeFocusRequest: Int = 0
    /// tvOS-only: a pushed detail page has popped and Home should restore the
    /// exact card/row that launched it instead of leaving the focus graph empty.
    var detailReturnFocusRequest: Int = 0
    /// tvOS-only: whether the custom top menu holds focus. Deferred entry
    /// claims are dropped while the user is up in the menu so late data
    /// loads never yank focus.
    var isTopMenuFocused: Bool = false
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel = HomeViewModel()
    @State private var isHomeVisible = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(tvOS)
    @State private var homeSectionPreferences = HomeSectionPreferences.shared
    @State private var spotlightPreferences = TVHomeSpotlightPreferences.shared
    #endif
    #if !os(tvOS)
    @State private var homeSectionPreferences = HomeSectionPreferences.shared
    @State private var isRefreshing = false
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
    /// Feeds the glass strip behind the floating header as rows scroll under it.
    @State private var chromeScrollState = PageChromeScrollState()
    #if os(iOS)
    @State private var pullRefreshArmed = false
    @State private var pullRefreshRequest = 0
    @State private var homeScrollPhase: ScrollPhase = .idle
    /// Breathing room between the status-bar safe area and the floating
    /// header. Uses the same value as the Libraries and For You top chrome so
    /// the shared action cluster sits at one height on every root page.
    private let headerTopInset: CGFloat = VividTheme.smallPadding
    /// The LazyVStack already contributes its normal section spacing after the
    /// header runway. Adding a second large header gap pushed the first
    /// visible row far down the screen whenever an earlier Home row was hidden.
    private let headerToContentGap: CGFloat = 0
    #endif
    #endif
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
        #if os(tvOS)
        Group {
            if !displayedSections.isEmpty || !spotlightPreferences.slides(from: viewModel.regularSections).isEmpty {
                TVHomeDiscoveryFeed(
                    sections: displayedSections,
                    slides: spotlightPreferences.slides(from: viewModel.regularSections),
                    focusRequest: homeFocusRequest,
                    detailReturnFocusRequest: detailReturnFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: onTopMenuFocusRequest,
                    onItemTap: navigateToDetail,
                    onRemoveFromContinueWatching: dismissContinueWatching,
                    onSetWatched: setWatched
                )
                // Rebuild the feed when row visibility or ordering changes.
                .id(homeSectionPreferences.layoutRevision)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
            } else if viewModel.isLoading {
                Color.clear
            } else if !viewModel.regularSections.isEmpty {
                EmptyStateView(
                    icon: "eye.slash",
                    title: "Home sections are hidden",
                    subtitle: "Choose which rows appear in Settings → General → Home Sections."
                )
            } else {
                EmptyStateView(
                    icon: "play.rectangle.on.rectangle",
                    title: "Nothing to watch yet",
                    subtitle: "Add media to your libraries or start watching to see it here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            homeSectionPreferences.refresh()
            spotlightPreferences.refresh()
            spotlightPreferences.initializeIfNeeded(from: viewModel.sections)
        }
        .onChange(of: viewModel.regularSections.map(\.id), initial: true) { _, _ in
            spotlightPreferences.initializeIfNeeded(from: viewModel.sections)
        }
        #else
        ZStack(alignment: .top) {
            #if os(iOS)
            Color.black.ignoresSafeArea()
            #else
            homeFeedBackground.ignoresSafeArea()
            #endif

            Group {
                if hasVisibleHomeContent {
                    scrollContent
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
                } else if viewModel.isLoading {
                    Color.clear
                } else if !viewModel.regularSections.isEmpty {
                    EmptyStateView(
                        icon: "eye.slash",
                        title: "Home sections are hidden",
                        subtitle: "Choose which rows appear in Settings → General → Home Sections."
                    )
                } else {
                    EmptyStateView(
                        icon: "play.rectangle.on.rectangle",
                        title: "Nothing to watch yet",
                        subtitle: "Add media to your libraries or start watching to see it here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if !os(iOS)
            HStack(alignment: .center, spacing: 12) {
                #if !os(iOS)
                SidebarToggleButton()
                #endif
                // The wordmark is pinned with the utilities so it stays put
                // over the glass strip instead of scrolling away with the feed.
                // It occupies the same 44pt row as the icon buttons so its
                // centre lines up with theirs.
                VividMarkView(width: 72)
                    .frame(height: VividTheme.topBarIconHitSize)
                Spacer(minLength: 8)

                // Trailing action cluster shared by every root page.
                TabTopBarActions(
                    onSearch: { router.navigate(to: .search) },
                    onOpenSettings: { router.navigate(to: .settings) },
                    onOpenRequests: { router.navigate(to: .requestsHub) },
                    onSwitchProfile: {
                        router.switchProfile()
                    },
                    onSwitchServer: { router.navigate(to: .serverList) },
                    onSignOut: { router.signOutAndReset() }
                )
            }
            .padding(.horizontal, VividTheme.padding)
            #if os(iOS)
            .padding(.top, headerTopInset)
            #endif
            .padding(.bottom, VividTheme.smallPadding)
            // Same scroll-driven glass as the Detail page chrome so the
            // utilities stay legible over bright artwork once rows scroll
            // underneath.
            .background {
                PageChromeGlass(scrollState: chromeScrollState)
            }

            #endif

            if isRefreshing {
                #if os(iOS)
                RefreshStatusPill(compactGlass: true)
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                #else
                RefreshStatusPill()
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                #endif
            } else if ConnectionMonitor.shared.isOffline, !viewModel.sections.isEmpty {
                // Cached sections are painted but the server can't be
                // reached — say so instead of silently showing stale data.
                ServerUnreachablePill()
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            homeSectionPreferences.refresh()
            #if os(iOS)
            TVHomeSpotlightPreferences.shared.refresh()
            #endif
            await viewModel.loadSections()
            #if os(iOS)
            TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: viewModel.sections)
            #endif
        }
        #if !os(iOS)
        .refreshable {
            await refreshHome()
        }
        #endif
        #endif
        }
        #if os(iOS) || os(tvOS)
        .onAppear { isHomeVisible = true }
        .onDisappear { isHomeVisible = false }
        .task(id: shouldSyncHome) {
            guard shouldSyncHome else { return }
            await viewModel.loadSections()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled, shouldSyncHome else { return }
                await viewModel.loadSections()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
            Task { await viewModel.refreshPlaybackSections() }
        }
        #endif
        .alert(
            "Couldn’t Update Item",
            isPresented: $viewModel.isShowingActionError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError?.message ?? "The item could not be updated. Try again.")
        }
    }

    // MARK: - Content

    #if !os(tvOS)
    private var hasVisibleHomeContent: Bool {
        #if os(iOS)
        !displayedSections.isEmpty || !TVHomeSpotlightPreferences.shared.slides(from: displayedSections).isEmpty
        #else
        !displayedSections.isEmpty
        #endif
    }

    private var scrollContent: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                    // Clear runway under the pinned header so the first row
                    // starts below the wordmark and utilities.
                    #if !os(iOS)
                    Color.clear
                        .frame(height: topRunwaySpacing(topSafeAreaInset: runwaySafeAreaInset(geometry)))
                        .id(HomeFocusTarget.topSpacer)
                    #endif

                    #if os(iOS)
                    if displayedSections.isEmpty || TVHomeSpotlightPreferences.shared.slides(from: viewModel.regularSections).isEmpty {
                        Color.clear.frame(height: geometry.safeAreaInsets.top + 16)
                    }
                    PhoneDiscoverySpotlight(sections: displayedSections.isEmpty ? [] : viewModel.sections, height: min(650, max(420, geometry.size.height * 0.68)) - geometry.safeAreaInsets.top, topSafeAreaInset: geometry.safeAreaInsets.top) { item in
                        navigateToDetail(item.type == "episode" ? (item.seriesId ?? item.contentId) : item.contentId, item)
                    }
                    #endif
                    ForEach(displayedSections) { section in
                        HomeFeedRow(
                            section: section,
                            onRemoveFromContinueWatching: dismissContinueWatching,
                            onSetWatched: setWatched
                        )
                        .id(HomeFocusTarget.row(section.id))
                    }
                }
                .padding(.bottom, HomeFeedMetrics.bottomRunway)
            }
            .reportsPageChromeScroll(to: chromeScrollState)
            #if os(iOS)
            // Keep UIKit's refresh control out of this edge-to-edge hero:
            // its active inset clips the poster above the status bar.
            .onScrollGeometryChange(for: Bool.self) { scroll in
                -(scroll.contentOffset.y + scroll.contentInsets.top) >= 90
            } action: { _, beyondThreshold in
                guard homeScrollPhase == .interacting, !isRefreshing else { return }
                pullRefreshArmed = beyondThreshold
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                homeScrollPhase = newPhase
                if newPhase == .tracking { pullRefreshArmed = false }
                guard oldPhase == .interacting,
                      newPhase != .interacting, newPhase != .tracking else { return }
                let shouldRefresh = pullRefreshArmed && !isRefreshing
                pullRefreshArmed = false
                if shouldRefresh { pullRefreshRequest += 1 }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: pullRefreshArmed) { _, armed in
                armed
            }
            .sensoryFeedback(.impact(weight: .light), trigger: pullRefreshRequest)
            .task(id: pullRefreshRequest) {
                guard pullRefreshRequest > 0 else { return }
                await refreshHome()
            }
            .accessibilityAction(named: Text("Refresh")) {
                guard !isRefreshing else { return }
                pullRefreshRequest += 1
            }
            .coordinateSpace(name: "phone-home-spotlight-scroll")
            .ignoresSafeArea(.container, edges: .top)
            #endif
            #if os(macOS)
            .vividScrollEdgeEffect()
            #endif
        }
        #if os(iOS)
        .coordinateSpace(name: "phone-home-fixed-viewport")
        #endif
    }
    #endif

    private enum HomeFocusTarget: Hashable {
        case topSpacer
        case row(String)
    }

    /// Rows for the vertical list, in server Home order after filtering empty
    /// and featured sections. Recommendations stay in the For You tab.
    private var displayedSections: [ResolvedSection] {
        #if os(tvOS) || os(iOS)
        // Apply visibility and ordering before layout. Hidden sections occupy
        // no space; each visible row keeps its own poster or landscape height.
        return homeSectionPreferences.arrangedSections(viewModel.regularSections)
        #else
        return viewModel.regularSections
        #endif
    }

    private var shouldSyncHome: Bool {
        let isAvailable = isHomeVisible && scenePhase == .active
            && router.authState == .authenticated && router.path.isEmpty && router.presentedPlayer == nil
        #if os(iOS)
        return isAvailable && router.presentedItemDetail == nil
        #else
        return isAvailable
        #endif
    }

    #if !os(tvOS)
    /// Home uses the same fixed canvas as the rest of the signed-in app.
    private var homeFeedBackground: some View {
        VividPageBackdrop()
    }

    private func refreshHome() async {
        await MainActor.run {
            showRefreshStatus()
        }

        async let homeRefresh: Void = viewModel.loadSections()
        async let libraryRefresh: LibrariesResponse? = try? await StartupContentPrefetcher
            .fetchUserLibraries()
        _ = await (homeRefresh, libraryRefresh)

        await MainActor.run {
            scheduleRefreshStatusHide()
        }
    }

    private func showRefreshStatus() {
        refreshHideTask?.cancel()
        refreshStartedAt = Date()
        isRefreshing = true
    }

    private func scheduleRefreshStatusHide() {
        let elapsed = Date().timeIntervalSince(refreshStartedAt ?? Date())
        let remaining = RefreshStatusPill.minimumVisibleDuration - elapsed
        refreshHideTask?.cancel()
        refreshHideTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            isRefreshing = false
            refreshStartedAt = nil
            refreshHideTask = nil
        }
    }

    #endif

    // MARK: - Navigation

    private func navigateToDetail(_ destinationContentId: String, _ item: SectionItem) {
        if MediaServerProvider.active == .emby, item.type == "collection" {
            router.navigate(to:.libraryCollection(libraryId:0,collectionId:item.contentId,title:item.title,kind:.regular))
            return
        }
        router.navigate(
            to: .itemDetail(
                destinationContentId: destinationContentId,
                sectionItem: item
            )
        )
    }

    private func dismissContinueWatching(_ item: SectionItem) {
        Task {
            await viewModel.dismissContinueWatchingItem(item)
        }
    }

    private func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        await viewModel.setWatched(item, played: played)
    }

    #if !os(tvOS)
    private var sectionSpacing: CGFloat {
        VividTheme.largePadding
    }

    /// On iOS the ScrollView already starts inside the safe area, so the
    /// runway must not count the status-bar inset a second time.
    private func runwaySafeAreaInset(_ geometry: GeometryProxy) -> CGFloat {
        #if os(iOS)
        return 0
        #else
        return geometry.safeAreaInsets.top
        #endif
    }

    private func topRunwaySpacing(topSafeAreaInset: CGFloat) -> CGFloat {
        // Mirror the floating header's vertical footprint (icon-frame height +
        // bottom padding) so the first row clears it. LazyVStack supplies the
        // remaining row gap; don't double-count it here.
        #if os(iOS)
        return 8
        #else
        var runway = topSafeAreaInset + VividTheme.topBarIconHitSize + VividTheme.smallPadding
        #if os(iOS)
        runway += headerTopInset + headerToContentGap
        #else
        runway += VividTheme.largePadding + VividTheme.smallPadding
        #endif
        return runway
        #endif
    }
    #endif
}

#if os(iOS)
private struct PhoneDiscoverySpotlight: View {
    let sections: [ResolvedSection]
    let height: CGFloat
    let topSafeAreaInset: CGFloat
    let onSelect: (SectionItem) -> Void
    @State private var preferences = TVHomeSpotlightPreferences.shared
    @State private var selection = 0
    @State private var visible = false
    @State private var cycleStarted = Date()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var slides: [TVHomeSpotlightSlide] { preferences.slides(from: sections) }
    private func spotlightMetadata(for item: SectionItem) -> String {
        let metadata = TVHomeMetadataCache.shared.spotlightMetadata(for: item)
        let classification = metadata?.contentRating ?? item.contentRating
        let year = metadata?.year ?? item.year
        let genre = metadata?.genres?.first ?? item.genres?.first
        let detailRating = metadata?.ratingImdb ?? metadata?.ratingTmdb
        let rating = detailRating ?? item.ratingImdb ?? item.ratingTmdb
        let parts: [String?] = [classification, year.map(String.init), genre, rating.map { String(format: "★ %.1f", $0) }]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let slides = self.slides
        let selectedIndex = slides.isEmpty ? 0 : (selection % slides.count + slides.count) % slides.count
        let pageIndices = slides.count > 1 ? Array(-1...slides.count) : [0]
        if !slides.isEmpty {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(pageIndices, id: \.self) { index in
                        let slide = slides[(index % slides.count + slides.count) % slides.count]
                        Button { onSelect(slide.item) } label: {
                            ZStack(alignment: .bottom) {
                                VStack(alignment: .center, spacing: 10) {
                                    if let logo = slide.item.logoUrl {
                                        CachedAsyncImage(url: logo, contentMode: .fit, alignment: .bottom, placeholderStyle: .clear)
                                            .frame(maxWidth: 430)
                                            .frame(height: min(max(height * 0.24, 104), 138))
                                    } else {
                                        Text(slide.item.title).font(.title2.bold()).lineLimit(2)
                                    }
                                    Text(spotlightMetadata(for: slide.item))
                                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                                }
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 60)
                                .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: height + 160, alignment: .bottom)
                            .clipped()
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: height + 160)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 6) {
                    ForEach(slides.indices, id: \.self) { index in
                        Button { withAnimation(.easeInOut(duration: 0.4)) { selection = index } } label: {
                            Capsule()
                                .fill(.white.opacity(0.3))
                                .overlay(alignment: .leading) {
                                    if selectedIndex == index {
                                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !visible || scenePhase != .active || reduceMotion)) { timeline in
                                            let progress = reduceMotion ? 1 : min(max(timeline.date.timeIntervalSince(cycleStarted) / 6, 0), 1)
                                            Rectangle().fill(.white)
                                                .frame(width: 36 * progress)
                                                .transaction { $0.animation = nil }
                                        }
                                    }
                                }
                                .frame(width: selectedIndex == index ? 36 : 8, height: 8)
                                .clipShape(Capsule())
                                .frame(minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Spotlight item \(index + 1)")
                    }
                    }
                    .animation(.easeInOut(duration: 0.4), value: selection)
                    .padding(.bottom, 24)
                }
            }
            .background(alignment: .top) {
                let item = slides[selectedIndex].item
                PhoneSpotlightArtworkSurface(
                    url: item.backdropUrl ?? item.posterUrl,
                    thumbhash: item.backdropThumbhash,
                    height: height,
                    topSafeAreaInset: topSafeAreaInset
                )
                .id(item.backdropUrl ?? item.contentId)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.4), value: selection)
            .padding(.bottom, -56)
            .onAppear { visible = true; cycleStarted = Date(); preferences.initializeIfNeeded(from: sections) }
            .onDisappear { visible = false }
            .onChange(of: slides.map(\.id)) { _, _ in selection = 0 }
            .task(id: selection) {
                guard slides.count > 1, selection == -1 || selection == slides.count else { return }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { selection = selectedIndex }
            }
            .onChange(of: selectedIndex) { _, _ in cycleStarted = Date() }
            .task(id: "\(visible)-\(scenePhase == .active)-\(reduceMotion)-\(selectedIndex)") {
                guard visible, scenePhase == .active, !reduceMotion else { return }
                cycleStarted = Date()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    guard slides.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.4)) { selection += 1 }
                }
            }
        }
    }
}
private struct PhoneSpotlightArtworkSurface: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat
    let topSafeAreaInset: CGFloat
    @State private var tint = Color(white: 0.12)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var usesTabletFade: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        // The dots end 42 points above the spotlight's height + 160 bottom.
        // Introduce a faint tablet blend by the dots, then soften into the first row.
        let artworkHeight = height + (usesTabletFade ? 300 : 90)
        let fadeStart = usesTabletFade ? (height + 25) / artworkHeight : 0.64
        ZStack(alignment: .top) {
            Color.black
            tint
            if !reduceTransparency, let url {
                GeometryReader { geometry in
                    AsyncImageView(url: url, thumbhash: thumbhash, contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(1.18)
                        .saturation(1.15)
                        .brightness(-0.12)
                        .blur(radius: 48, opaque: true)
                        .overlay(tint.opacity(0.12))
                        .clipped()
                }
                .allowsHitTesting(false)
            }
            PhoneDetailParallaxArtwork(
                url: url,
                thumbhash: thumbhash,
                height: artworkHeight,
                isEnabled: true,
                usesSubjectFraming: MediaServerProvider.active == .emby,
                coordinateSpaceName: "phone-home-spotlight-scroll",
                fadeStart: fadeStart,
                fadeMiddle: 0.84,
                fadeEnd: usesTabletFade ? (height + 220) / artworkHeight : 1,
                smoothFade: true
            )
            Canvas { context, size in
                for x in stride(from: CGFloat.zero, to: size.width, by: 2) {
                    let fraction = x / max(1, size.width)
                    let wave = sin(fraction * .pi * 2 + 0.4) * 22 + sin(fraction * .pi * 3.1) * 10
                    let start = usesTabletFade ? height + 140 : height + 25 + wave
                    let end = usesTabletFade ? size.height : size.height - 4 - (wave + 32) * 0.35
                    let stops = (0...48).map { step -> Gradient.Stop in
                        let t = Double(step) / 48
                        let alpha = t * t * t * (t * (t * 6 - 15) + 10)
                        return .init(color: .black.opacity(alpha), location: t)
                    }
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                        with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: x, y: start), endPoint: CGPoint(x: x, y: end))
                    )
                }
            }
            .allowsHitTesting(false)

        }
        .frame(height: height + 360)
        .clipped()
        .visualEffect { content, proxy in
            // Stretch the complete artwork surface, including its fade, while
            // cancelling the scroll view's pull-down translation. Uniform
            // scaling zooms the poster without changing its aspect ratio.
            // The refresh control changes the scroll view's inset. Measure
            // against its fixed parent, including the ignored top safe area.
            let pull = max(0, proxy.frame(in: .named("phone-home-fixed-viewport")).minY + topSafeAreaInset)
            let scale = 1 + pull / max(proxy.size.height, 1)
            return content
                .scaleEffect(scale, anchor: .top)
                .offset(y: -pull)
        }
        .task(id: url) {
            guard let url, let imageURL = URL(string: url) else { return }
            tint = HeroBackdropPalette.cachedTint(for: imageURL) ?? Color(white: 0.12)
            if let resolved = await HeroBackdropPalette.tintColor(for: imageURL), !Task.isCancelled {
                tint = resolved
            }
        }
    }
}
#endif
