import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The Home tab: the server's rows in the profile's chosen order, with the
/// spotlight, Studios and Networks and Collections around them.
struct HomeView: View {
    var homeFocusRequest: Int
    var detailReturnFocusRequest: Int
    var isTopMenuFocused: Bool
    var onTopMenuFocusRequest: (() -> Void)?

    @State private var model = HomeViewModel()
    @State private var layout = HomeSectionPreferences.shared
    @State private var isOnScreen = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    #if os(tvOS)
    @State private var hiddenSince: Date?
    #else
    @State private var chromeScroll = PageChromeScrollState()
    @State private var isShowingRefreshStatus = false
    @State private var isPullArmed = false
    @State private var refreshRequest = 0
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
    #endif

    init(
        homeFocusRequest: Int = 0,
        detailReturnFocusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil
    ) {
        self.homeFocusRequest = homeFocusRequest
        self.detailReturnFocusRequest = detailReturnFocusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
    }

    // MARK: Shared

    private var shownRows: [ResolvedSection] {
        layout.arrangedSections(model.regularSections)
    }

    private var isInFront: Bool {
        guard isOnScreen,
              scenePhase == .active,
              router.authState == .authenticated,
              router.path.isEmpty,
              router.presentedPlayer == nil else { return false }
        #if os(iOS)
        return router.presentedItemDetail == nil
        #else
        return true
        #endif
    }

    var body: some View {
        platformBody
            .onAppear { isOnScreen = true }
            .task(id: isInFront) {
                guard isInFront else { return }
                await HomeCollectionsStore.shared.loadIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
                #if os(tvOS)
                let inFront = isInFront
                Task { await model.refreshPlaybackSections(refreshImmediately: inFront) }
                #else
                Task { await model.refreshPlaybackSections() }
                #endif
            }
            .alert("Couldn\u{2019}t Update Item", isPresented: $model.isShowingActionError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let message = model.actionError?.message {
                    Text(verbatim: message)
                } else {
                    Text("The item could not be updated. Try again.")
                }
            }
    }

    @ViewBuilder
    private var stateView: some View {
        if showsContent {
            content
        } else if let error = model.error {
            ErrorView(state: error) {
                Task { await model.loadSections() }
            }
        } else if model.isLoading {
            VividLoadingDots()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.regularSections.isEmpty {
            EmptyStateView(
                icon: "eye.slash",
                title: "Home sections are hidden",
                subtitle: "Choose which rows appear in Settings \u{2192} General \u{2192} Home Sections."
            )
        } else {
            EmptyStateView(
                icon: "play.rectangle.on.rectangle",
                title: "Nothing to watch yet",
                subtitle: "Add media to your libraries or start watching to see it here."
            )
        }
    }

    private func openItem(_ destinationContentId: String, _ item: SectionItem) {
        router.navigate(to: .itemDetail(destinationContentId: destinationContentId, sectionItem: item))
    }

    private func removeFromContinueWatching(_ item: SectionItem) {
        Task { await model.dismissContinueWatchingItem(item) }
    }

    private func setWatched(_ item: SectionItem, _ played: Bool) async -> Bool {
        await model.setWatched(item, played: played)
    }

    #if os(tvOS)
    // MARK: Apple TV

    private var slides: [TVHomeSpotlightSlide] {
        TVHomeSpotlightPreferences.shared.slides(from: model.regularSections)
    }

    private var showsContent: Bool {
        !shownRows.isEmpty || !slides.isEmpty
    }

    private var content: some View {
        TVHomeDiscoveryFeed(
            sections: shownRows,
            slides: slides,
            focusRequest: homeFocusRequest,
            detailReturnFocusRequest: detailReturnFocusRequest,
            isTopMenuFocused: isTopMenuFocused,
            onTopMenuFocusRequest: onTopMenuFocusRequest,
            onItemTap: openItem,
            onRemoveFromContinueWatching: removeFromContinueWatching,
            onSetWatched: setWatched,
            showsCollections: true
        )
        .id(layout.layoutRevision)
    }

    private var platformBody: some View {
        stateView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDisappear {
                isOnScreen = false
                if hiddenSince == nil { hiddenSince = Date() }
            }
            .task {
                HomeSectionPreferences.shared.refresh()
                TVHomeSpotlightPreferences.shared.refresh()
                TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: model.sections)
            }
            .onChange(of: model.regularSections.map(\.id), initial: true) {
                TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: model.sections)
            }
            .task(id: isInFront) {
                guard isInFront else {
                    if hiddenSince == nil { hiddenSince = Date() }
                    return
                }
                await model.refreshForHomeEntry(sinceLastHidden: hiddenSince)
                if !Task.isCancelled { hiddenSince = nil }
                while !Task.isCancelled, isInFront,
                      let interval = HomeViewModel.televisionRefreshInterval(provider: .active) {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    guard isInFront, !Task.isCancelled else { return }
                    await model.loadSections()
                }
            }
    }

    #else
    // MARK: iPhone and iPad

    private static let scrollSpace = "home.scroll"
    private static let fixedSpace = "home.fixed"

    private var showsContent: Bool {
        !shownRows.isEmpty || !TVHomeSpotlightPreferences.shared.slides(from: shownRows).isEmpty
    }

    private var retriesFailedEmbyLoad: Bool {
        isInFront && model.lastRefreshFailed && MediaServerProvider.active == .emby
    }

    private var platformBody: some View {
        ZStack(alignment: .top) {
            VividAppBackdrop()
            stateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusPill
        }
        .animation(.easeInOut(duration: 0.18), value: isShowingRefreshStatus)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { isOnScreen = false }
        .task {
            HomeSectionPreferences.shared.refresh()
            TVHomeSpotlightPreferences.shared.refresh()
            await model.loadSections()
            TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: model.sections)
        }
        .task(id: isInFront) {
            guard isInFront else { return }
            await model.loadSections()
            guard MediaServerProvider.active != .emby else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard isInFront else { return }
                await model.loadSections()
            }
        }
        .task(id: retriesFailedEmbyLoad) {
            guard retriesFailedEmbyLoad else { return }
            while !Task.isCancelled, model.lastRefreshFailed {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard isInFront, !Task.isCancelled else { return }
                await model.loadSections()
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if isShowingRefreshStatus {
            RefreshStatusPill(compactGlass: true)
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
        } else if ConnectionMonitor.shared.isOffline, !model.sections.isEmpty {
            ServerUnreachablePill()
                .padding(.top, 64)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
        }
    }

    private var content: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let spotlightHeight = min(650, max(420, proxy.size.height * 0.68)) - topInset
            let rows = shownRows
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if rows.isEmpty || TVHomeSpotlightPreferences.shared.slides(from: model.regularSections).isEmpty {
                        Color.clear
                            .frame(height: topInset + 16)
                    }
                    HomeSpotlight(
                        rows: rows.isEmpty ? [] : model.sections,
                        height: spotlightHeight,
                        topInset: topInset,
                        scrollSpace: Self.scrollSpace,
                        fixedSpace: Self.fixedSpace,
                        onSelect: openSpotlightItem
                    )
                    .task(id: TVTMDbStore.shared.isConfigured) {
                        await StudiosNetworksStore.shared.loadIfNeeded()
                    }
                    PhoneStudiosNetworksRow()
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(rows) { row in
                            HomeFeedRow(
                                section: row,
                                onRemoveFromContinueWatching: removeFromContinueWatching,
                                onSetWatched: setWatched
                            )
                            .id("home.row.\(row.id)")
                        }
                    }
                    PhoneHomeCollectionsRow()
                }
                .padding(.bottom, 96)
            }
            .reportsPageChromeScroll(to: chromeScroll)
            .modifier(pullToRefresh)
            .modifier(MobileTopScrollEdgeModifier())
            .coordinateSpace(.named(Self.scrollSpace))
            .ignoresSafeArea(.container, edges: .top)
        }
        .coordinateSpace(.named(Self.fixedSpace))
    }

    private func openSpotlightItem(_ item: SectionItem) {
        let destination = item.type == "episode" ? (item.seriesId ?? item.contentId) : item.contentId
        openItem(destination, item)
    }

    // MARK: Pull to refresh

    private var pullToRefresh: HomePullToRefresh {
        HomePullToRefresh(
            isArmed: $isPullArmed,
            phase: $scrollPhase,
            request: $refreshRequest,
            isShowingStatus: isShowingRefreshStatus,
            onRequest: performRefresh
        )
    }

    private func performRefresh() async {
        refreshHideTask?.cancel()
        refreshHideTask = nil
        refreshStartedAt = Date()
        isShowingRefreshStatus = true

        async let rows: Void = model.loadSections()
        async let libraries: Void = loadLibrariesIgnoringErrors()
        async let collections: Void = HomeCollectionsStore.shared.loadIfNeeded(force: true)
        _ = await (rows, libraries, collections)

        let elapsed = refreshStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = RefreshStatusPill.minimumVisibleDuration - elapsed
        refreshHideTask?.cancel()
        refreshHideTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            isShowingRefreshStatus = false
            refreshStartedAt = nil
            refreshHideTask = nil
        }
    }

    private func loadLibrariesIgnoringErrors() async {
        _ = try? await StartupContentPrefetcher.fetchUserLibraries()
    }
    #endif
}

#if os(iOS)
/// Home's own pull to refresh: a 90-point pull, released while dragging,
/// asks for one refresh. VoiceOver gets a Refresh action instead.
private struct HomePullToRefresh: ViewModifier {
    @Binding var isArmed: Bool
    @Binding var phase: ScrollPhase
    @Binding var request: Int
    let isShowingStatus: Bool
    let onRequest: () async -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top) >= 90
            } action: { _, pulledFarEnough in
                guard phase == .interacting, !isShowingStatus else { return }
                isArmed = pulledFarEnough
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                phase = newPhase
                if newPhase == .tracking {
                    isArmed = false
                }
                if oldPhase == .interacting, newPhase != .interacting, newPhase != .tracking {
                    if isArmed, !isShowingStatus {
                        request += 1
                    }
                    isArmed = false
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isArmed) { _, armed in armed }
            .sensoryFeedback(.impact(weight: .light), trigger: request)
            .task(id: request) {
                guard request > 0 else { return }
                await onRequest()
            }
            .accessibilityAction(named: Text("Refresh")) {
                guard !isShowingStatus else { return }
                request += 1
            }
    }
}

// MARK: - Spotlight

/// The full-width carousel at the top of iPhone and iPad Home. It wraps
/// round and moves on every six seconds while it can be seen.
private struct HomeSpotlight: View {
    let rows: [ResolvedSection]
    let height: CGFloat
    let topInset: CGFloat
    let scrollSpace: String
    let fixedSpace: String
    let onSelect: (SectionItem) -> Void

    private static let cycle: TimeInterval = 6

    @State private var selection = 0
    @State private var isOnScreen = false
    @State private var cycleStart = Date()
    @State private var pausedAt: Date?
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slides = TVHomeSpotlightPreferences.shared.slides(from: rows)
        if !slides.isEmpty {
            carousel(slides)
        }
    }

    private var isRotating: Bool {
        isOnScreen && scenePhase == .active && !reduceMotion && !router.isItemDetailPresentationActive
    }

    private func slideIndex(_ tag: Int, count: Int) -> Int {
        ((tag % count) + count) % count
    }

    private func carousel(_ slides: [TVHomeSpotlightSlide]) -> some View {
        let count = slides.count
        let selectedIndex = slideIndex(selection, count: count)
        let selected = slides[selectedIndex]
        let tags = count > 1 ? Array(-1...count) : [0]
        return VStack(spacing: 0) {
            TabView(selection: $selection) {
                ForEach(tags, id: \.self) { tag in
                    page(slides[slideIndex(tag, count: count)])
                        .tag(tag)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height + 160)
            .overlay(alignment: .bottom) {
                dots(count: count, selectedIndex: selectedIndex)
            }
        }
        .background(alignment: .top) {
            SpotlightArtworkSurface(
                url: selected.item.backdropUrl ?? selected.item.posterUrl,
                thumbhash: selected.item.backdropThumbhash,
                height: height,
                topInset: topInset,
                scrollSpace: scrollSpace,
                fixedSpace: fixedSpace
            )
            .id(selected.item.backdropUrl ?? selected.item.contentId)
            .transition(.opacity)
            .allowsHitTesting(false)
            .onDuo { $0.ignoresSafeArea(.container, edges: .horizontal) }
            .modifier(TabletIgnoresHorizontalSafeArea())
        }
        .animation(.easeInOut(duration: 0.4), value: selection)
        .padding(.bottom, -56)
        .onScrollVisibilityChange(threshold: 0.01) { isOnScreen = $0 }
        .onAppear {
            cycleStart = Date()
            TVHomeSpotlightPreferences.shared.initializeIfNeeded(from: rows)
        }
        .onDisappear { isOnScreen = false }
        .onChange(of: slides.map(\.id)) { selection = 0 }
        .onChange(of: selectedIndex) {
            cycleStart = Date()
            if pausedAt != nil { pausedAt = cycleStart }
        }
        .onChange(of: isRotating) { _, rotating in
            if rotating {
                if let pausedAt {
                    cycleStart = cycleStart.addingTimeInterval(Date().timeIntervalSince(pausedAt))
                    self.pausedAt = nil
                }
            } else if pausedAt == nil {
                pausedAt = Date()
            }
        }
        .task(id: selection) {
            guard count > 1, selection == -1 || selection == count else { return }
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            var jump = Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { selection = slideIndex(selection, count: count) }
        }
        .task(id: RotationKey(isRotating: isRotating, index: selectedIndex)) {
            guard isRotating else { return }
            let remaining = max(0, Self.cycle - Date().timeIntervalSince(cycleStart))
            do {
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard isRotating, !Task.isCancelled, count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.4)) { selection += 1 }
        }
    }

    private struct RotationKey: Equatable {
        let isRotating: Bool
        let index: Int
    }

    // MARK: Pages

    private func page(_ slide: TVHomeSpotlightSlide) -> some View {
        Button {
            onSelect(slide.item)
        } label: {
            ZStack(alignment: .bottom) {
                VStack(alignment: .center, spacing: 10) {
                    heading(slide.item)
                    metadata(slide.item)
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
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func heading(_ item: SectionItem) -> some View {
        if let logo = item.logoUrl {
            CachedAsyncImage(url: logo, contentMode: .fit, alignment: .bottom, placeholderStyle: .clear)
                .frame(maxWidth: 430)
                .frame(height: min(max(height * 0.24, 104), 138))
        } else {
            Text(verbatim: item.title)
                .font(.title2.bold())
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func metadata(_ item: SectionItem) -> some View {
        let detail = TVHomeMetadataCache.shared.spotlightMetadata(for: item)
        let rating = ((detail?.contentRating ?? item.contentRating) ?? "").trimmingCharacters(in: .whitespaces)
        let year = detail?.year ?? item.year
        let genres = [detail?.genres, item.genres].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? []
        let tokens = (year.map { [String($0)] } ?? []) + genres.prefix(2)
        if !tokens.isEmpty || !rating.isEmpty {
            MetadataPillRow(tokens: tokens) {
                if !rating.isEmpty {
                    ContentRatingChip(rating: rating)
                }
            }
        }
    }

    // MARK: Dots

    private func dots(count: Int, selectedIndex: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    withAnimation(.easeInOut(duration: 0.4)) { selection = index }
                } label: {
                    dot(isSelected: index == selectedIndex)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Spotlight item \(index + 1)"))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: selection)
        .padding(.bottom, 24)
    }

    private func dot(isSelected: Bool) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.3))
            .overlay(alignment: .leading) {
                if isSelected {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isRotating)) { context in
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 36 * cycleProgress(at: context.date))
                            .transaction { $0.animation = nil }
                    }
                }
            }
            .frame(width: isSelected ? 36 : 8, height: 8)
            .clipShape(Capsule())
            .frame(minHeight: 44)
    }

    private func cycleProgress(at date: Date) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let elapsed = (pausedAt ?? date).timeIntervalSince(cycleStart)
        return CGFloat(min(max(elapsed / Self.cycle, 0), 1))
    }
}

private struct TabletIgnoresHorizontalSafeArea: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.ignoresSafeArea(.container, edges: .horizontal)
        } else {
            content
        }
    }
}

/// The selected slide's artwork behind the spotlight: a blurred, tinted
/// wash with the sharp artwork over it, fading into the page and
/// stretching when Home is pulled down.
private struct SpotlightArtworkSurface: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat
    let topInset: CGFloat
    let scrollSpace: String
    let fixedSpace: String

    @State private var tint = Color(white: 0.12)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isTablet: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var artworkHeight: CGFloat { height + (isTablet ? 300 : 90) }

    var body: some View {
        let artworkHeight = artworkHeight
        let fixedSpace = fixedSpace
        let topInset = topInset
        ZStack(alignment: .top) {
            Color.black
            tint
            if !reduceTransparency, let url {
                GeometryReader { proxy in
                    AsyncImageView(url: url, thumbhash: thumbhash, contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
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
                usesSubjectFraming: MediaServerProvider.active.usesNativeUser,
                coordinateSpaceName: scrollSpace,
                fadeStart: isTablet ? (height + 25) / artworkHeight : 0.64,
                fadeMiddle: 0.84,
                fadeEnd: isTablet ? (height + 220) / artworkHeight : 1,
                smoothFade: true
            )
        }
        .frame(height: height + 360)
        .clipped()
        .mask {
            SpotlightFadeMask(height: height, isTablet: isTablet)
                .equatable()
        }
        .visualEffect { content, proxy in
            let pull = max(0, proxy.frame(in: .named(fixedSpace)).minY + topInset)
            return content
                .scaleEffect(1 + pull / max(proxy.size.height, 1), anchor: .top)
                .offset(y: -pull)
        }
        .task(id: url) {
            guard let url, let address = URL(string: url) else { return }
            tint = HeroBackdropPalette.cachedTint(for: address) ?? Color(white: 0.12)
            let sampled = await HeroBackdropPalette.tintColor(for: address)
            guard !Task.isCancelled, let sampled else { return }
            tint = sampled
        }
    }
}

/// A wavy fade along the bottom of the spotlight artwork, drawn in thin
/// vertical strips. On iPad the edge is straight and lower.
private struct SpotlightFadeMask: View, Equatable {
    let height: CGFloat
    let isTablet: Bool

    private static let gradient = Gradient(stops: (0...48).map { step in
        let t = Double(step) / 48
        let eased = 6 * pow(t, 5) - 15 * pow(t, 4) + 10 * pow(t, 3)
        return Gradient.Stop(color: Color.white.opacity(1 - eased), location: t)
    })

    var body: some View {
        let gradient = Self.gradient
        let height = height
        let isTablet = isTablet
        Canvas { context, size in
            let width = size.width
            var x: CGFloat = 0
            while x < width {
                let f = x / max(1, width)
                let wave = 22 * sin(2 * .pi * f + 0.4) + 10 * sin(3.1 * .pi * f)
                let start = isTablet ? height + 140 : height + 25 + wave
                let end = isTablet ? size.height : size.height - 4 - 0.35 * (wave + 32)
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 2, height: size.height)),
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: x, y: start),
                        endPoint: CGPoint(x: x, y: end)
                    )
                )
                x += 2
            }
        }
    }
}
#endif
