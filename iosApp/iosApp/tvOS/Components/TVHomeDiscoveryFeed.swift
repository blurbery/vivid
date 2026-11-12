#if os(tvOS)
import SwiftUI
import Observation
import UIKit

/// The Apple TV Home feed: the Spotlight carousel, Studios & Networks, the
/// server's rows and (on Home) the Collections row. It remembers which card
/// each row last had focused, returns focus to whatever opened a detail page,
/// and gates row artwork to the rows near focus.
struct TVHomeDiscoveryFeed: View {
    let sections: [ResolvedSection]
    let slides: [TVHomeSpotlightSlide]
    let focusRequest: Int
    let detailReturnFocusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: (() -> Void)?
    let onItemTap: (String, SectionItem) -> Void
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    /// Home pins the Collections row below its rows; other feeds don't.
    var showsCollections = false
    /// Opens a Spotlight slide with the zoom source of its card.
    var onSpotlightTap: ((String, SectionItem, String) -> Void)? = nil

    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var spotlightEnterRequest = 0
    @State private var rowFocusOwnership = TVHomeFocusOwnership()
    @State private var rowFocusMemory = TVHomeRowFocusMemory()
    @State private var spotlightAmbience = TVHomeSpotlightAmbience()
    @State private var rowArtworkWindow = TVHomeRowArtworkWindow()
    @State private var scrollDiagnostics = TVHomeScrollDiagnostics()
    @State private var firstRowFocusRequest = 0
    @State private var studiosNetworksFocusRequest = 0
    @State private var spotlightOpenedDetail = false
    @State private var studiosNetworksOpenedDetail = false
    @State private var collectionsFocusRequest = 0
    @State private var collectionsOpenedDetail = false
    @State private var appliedFocusRequest = 0

    private static let spotlightAnchor = "vivid.home.discovery.spotlight"
    /// Focus owner while Studios & Networks has focus. It isn't a Home
    /// section, so no section restores focus, and the top menu boundary
    /// knows focus has left the Spotlight.
    private static let studiosNetworksOwner = "vivid.home.studiosNetworks"
    /// Focus owner while the Collections row has focus, for the same reasons.
    private static let collectionsOwner = "vivid.home.collections"

    var body: some View {
        let _ = scrollDiagnostics.event("feed.body")
        Group {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if !slides.isEmpty {
                        TVHomeSpotlightCarousel(
                            slides: slides,
                            enterRequest: spotlightEnterRequest,
                            initialPosition: rowFocusMemory.spotlightPosition,
                            onPositionChange: {
                                rowFocusMemory.spotlightPosition = $0
                                spotlightAmbience.position = $0
                                if rowFocusMemory.spotlightFocused { reportSpotlightFocus(position: $0) }
                            },
                            onFocusChange: { focused in
                                rowFocusMemory.spotlightFocused = focused
                                if focused {
                                    reportSpotlightFocus(position: rowFocusMemory.spotlightPosition)
                                    rowFocusOwnership.rowID = nil
                                    rowArtworkWindow.focus(index: 0)
                                }
                            },
                            onEnterFirstRow: enterStudiosNetworks,
                            onSelect: { slide, position in
                                spotlightOpenedDetail = true
                                studiosNetworksOpenedDetail = false
                                collectionsOpenedDetail = false
                                rowFocusOwnership.rowID = nil
                                // An episode with a known series and season
                                // opens its series directly, as its Continue
                                // Watching card does.
                                let destination = TVSeriesDetailNavigationContextStore.destination(for: slide.item)
                                if let onSpotlightTap {
                                    let zoomSourceID = tvSpotlightZoomSourceID(position: position)
                                    // The card's logo goes a frame before the page
                                    // opens, so the flying copy never doubles it.
                                    TVSpotlightLogoFlight.shared.prepare(sourceID: zoomSourceID, slideID: slide.id)
                                    DispatchQueue.main.async {
                                        TVSpotlightLogoFlight.shared.open(sourceID: zoomSourceID, slideID: slide.id)
                                        onSpotlightTap(destination, slide.item, zoomSourceID)
                                    }
                                } else {
                                    onItemTap(destination, slide.item)
                                }
                            }
                        )
                        .id(Self.spotlightAnchor)
                    }

                    // Shown with or without the Spotlight; without it, the row
                    // tops Home and takes focus first.
                    studiosNetworksRow

                    VStack(alignment: .leading, spacing: TVHomeRowGeometry.rowSpacing) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            SectionRow(
                                section: section,
                                onItemTap: { id, item in
                                    spotlightOpenedDetail = false
                                    studiosNetworksOpenedDetail = false
                                    collectionsOpenedDetail = false
                                    onItemTap(id, item)
                                },
                                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                                onSetWatched: onSetWatched,
                                showsHeadingIcon: false,
                                prefersDefaultFocusOnFirstItem: slides.isEmpty && index == 0 && !StudiosNetworksStore.shared.showsRow,
                                defaultFocusPriority: .userInitiated,
                                focusRequest: index == 0 ? firstRowFocusRequest : 0,
                                defaultFocusItemId: rowFocusMemory.items[section.id],
                                focusRequestItemId: rowFocusMemory.items[section.id],
                                detailReturnFocusRequest: spotlightOpenedDetail || studiosNetworksOpenedDetail || collectionsOpenedDetail
                                    ? 0 : detailReturnFocusRequest,
                                onMoveUp: index == 0 && slides.isEmpty && !StudiosNetworksStore.shared.showsRow
                                    ? { onTopMenuFocusRequest?() } : nil,
                                onItemFocus: { item in
                                    scrollDiagnostics.focus(row: index, card: section.items.firstIndex { $0.contentId == item.contentId } ?? -1)
                                    rowArtworkWindow.focus(index: index)
                                    rowFocusMemory.items[section.id] = item.contentId
                                    if rowFocusOwnership.rowID != section.id { rowFocusOwnership.rowID = section.id }
                                    TVAdaptiveAmbience.shared.focused(artwork: adaptiveArtwork(for: item, in: section))
                                },
                                cardWidth: VividTheme.Skyline.densePosterCardWidth,
                                homeRowIndex: index,
                                focusRestorationOwner: Binding(
                                    get: { rowFocusOwnership.rowID == section.id },
                                    set: { if $0 { rowFocusOwnership.rowID = section.id } }
                                ),
                                isSpotlightHandoffPending: { index == 0 && rowFocusMemory.spotlightFocused }
                            )
                            .frame(height: TVHomeRowGeometry.headingHeight
                                + TVHomeRowGeometry.headingSpacing
                                + TVHomeRowGeometry.stripHeight(
                                    layout: section.tvHomeUsesLandscapeArtwork ? .thumbnail : .poster,
                                    posterWidth: VividTheme.Skyline.densePosterCardWidth,
                                    presentation: homeCards.presentation,
                                    hasEpisodes: section.tvHomeHasEpisodes
                                ), alignment: .top)
                            .id(section.id)
                            .modifier(TVHomeRowArtworkVisibility(index: index, window: rowArtworkWindow))
                            .modifier(TVHomeDiagnosticRow(diagnostics: scrollDiagnostics, index: index))
                        }
                    }

                    // Always last, below the server's rows and outside their limit.
                    if showsCollections, HomeCollectionsStore.shared.showsRow {
                        collectionsRow
                    }
                }
                .environment(\.tvHomeStableRows, true)
                .padding(.top, VividTheme.Skyline.barTopInset + (slides.isEmpty ? 96 : 91))
                .padding(.bottom, 80)
                // Part of the scrolling content, so it leaves with the
                // spotlight and has faded out by the first rows.
                .background(alignment: .top) {
                    if !slides.isEmpty {
                        TVHomeSpotlightGlow(
                            ambience: spotlightAmbience,
                            slides: slides,
                            initialPosition: rowFocusMemory.spotlightPosition
                        )
                    }
                }
            }
            .modifier(TVHomeDiagnosticFeed(diagnostics: scrollDiagnostics))
            .onChange(of: focusRequest, initial: true) { _, request in
                guard request > appliedFocusRequest, !isTopMenuFocused else { return }
                appliedFocusRequest = request
                if slides.isEmpty { enterStudiosNetworks() }
                else { enterSpotlight() }
            }
            .onChange(of: detailReturnFocusRequest) { _, _ in
                if spotlightOpenedDetail { enterSpotlight() }
                else if studiosNetworksOpenedDetail { enterStudiosNetworks() }
                else if collectionsOpenedDetail { enterCollections() }
            }
            .onChange(of: slides.isEmpty) { _, empty in
                if empty && rowFocusMemory.spotlightFocused { enterStudiosNetworks() }
            }
            .onChange(of: isTopMenuFocused) { _, focused in
                if focused { rowFocusOwnership.rowID = nil }
            }
        }
        .modifier(TVHomeArtworkWarmupModifier(sections: sections,
            presentation: homeCards.presentation, focus: rowFocusOwnership, memory: rowFocusMemory,
            seriesBackdrops: showsCollections))
        .background {
            TVHomeTopMenuBoundary(focus: rowFocusOwnership, hasSpotlight: !slides.isEmpty)
        }
        .environment(\.homeCardPresentation, homeCards.presentation)
        .environment(\.showsHomeSeriesBackdrops, showsCollections)
        .environment(\.tvHomeFocusOwnership, rowFocusOwnership)
        .environment(\.tvHomeScrollDiagnostics, scrollDiagnostics.enabled ? scrollDiagnostics : nil)
        .onDisappear { rowArtworkWindow.stopPendingPreparation() }
        // Theme Mode Adaptive: start on the Spotlight's colour when nothing
        // has set one, even if focus is on the tab bar.
        .onAppear { seedAdaptiveSpotlight() }
        // A reload, or an episode's series background arriving after its
        // slide first appeared, changes the current slide's artwork in place.
        .onChange(of: currentSpotlightArtwork) {
            if rowFocusMemory.spotlightFocused { reportSpotlightFocus(position: rowFocusMemory.spotlightPosition) }
            else { seedAdaptiveSpotlight() }
        }
        // Loads Studios & Networks, and again once TMDb is available for the account.
        .task(id: TVTMDbStore.shared.isConfigured) { await StudiosNetworksStore.shared.loadIfNeeded() }
        .ignoresSafeArea()
    }

    /// Theme Mode Adaptive: the Spotlight's colour while it has focus.
    private func reportSpotlightFocus(position: Int) {
        guard !slides.isEmpty else { return }
        let slide = slides[((position % slides.count) + slides.count) % slides.count]
        TVAdaptiveAmbience.shared.focused(artwork: slide.content.backdropUrl ?? slide.content.fallbackArtworkUrl,
                                          source: .spotlight)
    }

    private func seedAdaptiveSpotlight() {
        TVAdaptiveAmbience.shared.seedSpotlight(artwork: currentSpotlightArtwork)
    }

    /// The artwork of the slide the carousel last reported, as the Spotlight
    /// Only backdrop works it out.
    private var currentSpotlightArtwork: String? {
        guard !slides.isEmpty else { return nil }
        let position = rowFocusMemory.spotlightPosition
        let slide = slides[((position % slides.count) + slides.count) % slides.count]
        return slide.content.backdropUrl ?? slide.content.fallbackArtworkUrl
    }

    /// The artwork a Home card shows, chosen as the artwork warm-up does:
    /// a landscape row's series backdrop or thumbnail, otherwise the poster.
    private func adaptiveArtwork(for item: SectionItem, in section: ResolvedSection) -> String? {
        let wide = section.tvHomeUsesLandscapeArtwork
        if wide && showsCollections && HomeSeriesBackdrops.applies(toSectionType: section.sectionType) {
            return HomeSeriesBackdrops.shared.art(for: item).url
        }
        return wide ? (item.backdropUrl.flatMap { $0.isEmpty ? nil : $0 } ?? item.posterUrl) : item.posterUrl
    }

    private func enterSpotlight() {
        guard !slides.isEmpty else { onTopMenuFocusRequest?(); return }
        // The spotlight is mounted eagerly. Let the focus engine perform its
        // own scroll instead of racing a separate ScrollViewReader animation.
        rowFocusOwnership.rowID = nil
        spotlightEnterRequest += 1
    }

    /// Pinned between the Spotlight and the first row when it has tiles.
    private var studiosNetworksRow: some View {
        TVStudiosNetworksRow(
            enterRequest: studiosNetworksFocusRequest,
            onMoveUp: slides.isEmpty ? { onTopMenuFocusRequest?() } : nil,
            onFocused: { rowFocusOwnership.rowID = Self.studiosNetworksOwner },
            onOpen: {
                spotlightOpenedDetail = false
                studiosNetworksOpenedDetail = true
                collectionsOpenedDetail = false
            }
        )
    }

    /// Pinned below the last row, with the same reserved height as a poster row.
    private var collectionsRow: some View {
        TVHomeCollectionsRow(
            enterRequest: collectionsFocusRequest,
            onFocused: {
                if rowFocusOwnership.rowID != Self.collectionsOwner { rowFocusOwnership.rowID = Self.collectionsOwner }
                rowArtworkWindow.focus(index: sections.count)
            },
            onOpen: {
                spotlightOpenedDetail = false
                studiosNetworksOpenedDetail = false
                collectionsOpenedDetail = true
            }
        )
        .frame(height: TVHomeRowGeometry.headingHeight
            + TVHomeRowGeometry.headingSpacing
            + TVHomeRowGeometry.stripHeight(
                layout: .poster,
                posterWidth: VividTheme.Skyline.densePosterCardWidth,
                presentation: homeCards.presentation
            ), alignment: .top)
        .modifier(TVHomeRowArtworkVisibility(index: sections.count, window: rowArtworkWindow))
    }

    /// Back from a collection's page, focus returns to the card that opened it.
    private func enterCollections() {
        guard HomeCollectionsStore.shared.showsRow else { enterFirstRow(); return }
        rowFocusOwnership.rowID = Self.collectionsOwner
        collectionsFocusRequest += 1
    }

    /// Spotlight Down lands on Studios & Networks when it's showing,
    /// otherwise on the first row as before.
    private func enterStudiosNetworks() {
        guard StudiosNetworksStore.shared.showsRow else { enterFirstRow(); return }
        rowFocusOwnership.rowID = Self.studiosNetworksOwner
        studiosNetworksFocusRequest += 1
    }

    private func enterFirstRow() {
        guard let first = sections.first else { return }
        rowFocusOwnership.rowID = first.id
        firstRowFocusRequest += 1
    }
}

/// The collection carries this reference without observing its value. Only
/// hosted card leaves observe changes, so artwork gating cannot refresh a rail.
@Observable
final class TVHomeRowArtworkGate {
    var enabled = false {
        didSet {
            if oldValue != enabled {
                VividImageDiagnostics.shared.count(enabled ? "gate.enabled" : "gate.disabled")
            }
        }
    }
}

private struct TVHomeRowArtworkGateKey: EnvironmentKey {
    static let defaultValue: TVHomeRowArtworkGate? = nil
}

extension EnvironmentValues {
    var tvHomeRowArtworkGate: TVHomeRowArtworkGate? {
        get { self[TVHomeRowArtworkGateKey.self] }
        set { self[TVHomeRowArtworkGateKey.self] = newValue }
    }
}

/// Non-observable bookkeeping: a focus event updates only gates whose state
/// changes. Nearby rows remain enabled across short Up/Down reversals.
private final class TVHomeRowArtworkWindow {
    private var current = 0
    private var gates: [Int: TVHomeRowArtworkGate] = [:]
    private var settle: DispatchWorkItem?

    func register(_ gate: TVHomeRowArtworkGate, index: Int) {
        gates[index] = gate
        update(gate, index: index)
    }

    func unregister(_ gate: TVHomeRowArtworkGate, index: Int) {
        if gates[index] === gate { gates.removeValue(forKey: index) }
    }

    func focus(index: Int) {
        guard current != index else { return }
        current = index
        // Only the immediate destinations are enabled in the focus callback.
        for offset in -1...1 {
            if let gate = gates[index + offset], !gate.enabled { gate.enabled = true }
        }
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for (index, gate) in gates { update(gate, index: index) }
            settle = nil
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func stopPendingPreparation() {
        settle?.cancel()
        settle = nil
    }

    deinit { settle?.cancel() }

    private func update(_ gate: TVHomeRowArtworkGate, index: Int) {
        if (current - 1 ... current + 2).contains(index) {
            if !gate.enabled { gate.enabled = true }
        } else if abs(index - current) > 4, gate.enabled {
            gate.enabled = false
        }
    }

}

private struct TVHomeRowArtworkVisibility: ViewModifier {
    let index: Int
    let window: TVHomeRowArtworkWindow
    @State private var gate = TVHomeRowArtworkGate()

    func body(content: Content) -> some View {
        content
            .environment(\.tvHomeRowArtworkGate, gate)
            .onAppear { window.register(gate, index: index) }
            .onDisappear { window.unregister(gate, index: index) }
            .onChange(of: index) { oldIndex, newIndex in
                window.unregister(gate, index: oldIndex)
                window.register(gate, index: newIndex)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                window.stopPendingPreparation()
                gate.enabled = false
            }
    }
}

/// Keep a real upward focus destination available while browsing the spotlight.
struct TVHomeTopMenuAvailabilityKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct TVHomeTopMenuBoundary: View {
    let focus: TVHomeFocusOwnership
    let hasSpotlight: Bool

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .preference(key: TVHomeTopMenuAvailabilityKey.self,
                        value: hasSpotlight && focus.rowID == nil)
    }
}

// Temporary local diagnostics. Inert unless explicitly enabled at launch.
// Records geometry and timing only, never titles, URLs or account information.
private struct TVHomeDiagnosticRow: ViewModifier {
    let diagnostics: TVHomeScrollDiagnostics
    let index: Int

    @ViewBuilder func body(content: Content) -> some View {
        if diagnostics.enabled && !VividImageDiagnostics.shared.enabled {
            content.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("vivid.home.diagnostics"))
            } action: { frame in
                diagnostics.row(index, frame: frame)
            }
            .onAppear { diagnostics.event("mount", index: index) }
            .onDisappear { diagnostics.event("unmount", index: index) }
        } else { content }
    }
}

private struct TVHomeDiagnosticFeed: ViewModifier {
    let diagnostics: TVHomeScrollDiagnostics

    @ViewBuilder func body(content: Content) -> some View {
        if diagnostics.enabled {
            content.coordinateSpace(name: "vivid.home.diagnostics")
                .onScrollGeometryChange(for: TVHomeDiagnosticGeometry.self) { geometry in
                    TVHomeDiagnosticGeometry(offset: geometry.contentOffset,
                        content: geometry.contentSize, viewport: geometry.containerSize)
                } action: { _, geometry in
                    diagnostics.scroll(geometry)
                }
                .onScrollPhaseChange { _, phase in
                    diagnostics.event("phase.\(phase)")
                }
                .onAppear { diagnostics.arm() }
                .onDisappear { diagnostics.finish() }
        } else { content }
    }
}

struct TVHomeDiagnosticGeometry: Equatable {
    let offset: CGPoint
    let content: CGSize
    let viewport: CGSize
    var values: [Double] {
        [offset.x, offset.y, content.width, content.height, viewport.width, viewport.height]
    }
}

@MainActor
final class TVHomeScrollDiagnostics: NSObject {
    let enabled = ProcessInfo.processInfo.arguments.contains("--home-scroll-diagnostics")
    private struct Sample: Codable, Sendable {
        let time: Double
        let event: String
        let index: Int?
        let values: [Double]
    }
    private struct Capture: Codable, Sendable {
        let status: String
        let duration: Double
        let samples: [Sample]
    }
    private var samples: [Sample] = []
    private var geometry: TVHomeDiagnosticGeometry?
    private var rows: [Int: CGRect] = [:]
    private var focusedRow = -1
    private var focusedCard = -1
    private var started: Double?
    private var previousFrame: Double?
    private var previousResources: (time: Double, cpu: Double)?
    private var displayLink: CADisplayLink?
    private var deadline: DispatchWorkItem?
    private var armed = false
    private var awaitingFirstRow = false
    private var outputURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vivid-home-navigation-diagnostics.json")
    }

    func arm() {
        guard enabled, !armed else { return }
        armed = true
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer else { return }
            let recorder = Unmanaged<TVHomeScrollDiagnostics>.fromOpaque(observer).takeUnretainedValue()
            let isStart = name?.rawValue as String? == "com.blurbery.vivid.home-diagnostics.start"
            Task { @MainActor [weak recorder] in
                if isStart { recorder?.start() } else { recorder?.finish() }
            }
        }
        for name in ["com.blurbery.vivid.home-diagnostics.start", "com.blurbery.vivid.home-diagnostics.stop"] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(), callback, name as CFString,
                nil, .deliverImmediately)
        }
        write(Capture(status: "armed", duration: 0, samples: []))
        if ProcessInfo.processInfo.arguments.contains("--home-scroll-diagnostics-autostart") {
            if VividImageDiagnostics.shared.enabled {
                awaitingFirstRow = true
                write(Capture(status: "waitingForRowFocus", duration: 0, samples: []))
                if focusedRow >= 0 { awaitingFirstRow = false; start() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.start() }
            }
        }
    }

    private func start() {
        guard started == nil else { return }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16000)
        started = CACurrentMediaTime()
        VividImageDiagnostics.shared.begin()
        previousFrame = nil
        previousResources = nil
        if let geometry { event("scroll", values: geometry.values) }
        for (index, frame) in rows { row(index, frame: frame) }
        event("focus", index: focusedRow, values: [Double(focusedCard)])
        resources()
        write(Capture(status: "recording", duration: 0, samples: samples))
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let stop = DispatchWorkItem { [weak self] in self?.finish() }
        deadline = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + (VividImageDiagnostics.shared.enabled ? 90 : 60), execute: stop)
    }

    func scroll(_ geometry: TVHomeDiagnosticGeometry) {
        self.geometry = geometry
        event("scroll", values: geometry.values)
    }

    func row(_ index: Int, frame: CGRect) {
        rows[index] = frame
        event("row", index: index, values: [frame.minX, frame.minY, frame.width, frame.height])
    }

    func focus(row: Int, card: Int) {
        guard enabled else { return }
        focusedRow = row
        focusedCard = card
        if awaitingFirstRow {
            awaitingFirstRow = false
            start()
            return
        }
        event("focus", index: row, values: [Double(card)])
    }

    func event(_ event: String, index: Int? = nil, values: [Double] = []) {
        guard enabled, let started else { return }
        samples.append(Sample(time: CACurrentMediaTime() - started,
            event: event, index: index, values: values))
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let previousFrame {
            event("frame", values: [now - previousFrame, link.targetTimestamp - link.timestamp])
        }
        previousFrame = now
        if now - (previousResources?.time ?? 0) >= 1 { resources() }
    }

    private func resources() {
        let now = CACurrentMediaTime()
        sampleImages()
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let percent = previousResources.map { (cpu - $0.cpu) / max(0.001, now - $0.time) * 100 } ?? 0
        previousResources = (now, cpu)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        event("resources", values: [percent, result == KERN_SUCCESS ? Double(info.phys_footprint) : -1])
    }

    func finish() {
        guard let started else { return }
        let duration = CACurrentMediaTime() - started
        sampleImages()
        VividImageDiagnostics.shared.end()
        self.started = nil
        displayLink?.invalidate()
        displayLink = nil
        deadline?.cancel()
        deadline = nil
        write(Capture(status: "finished", duration: duration, samples: samples))
        samples.removeAll(keepingCapacity: true)
    }

    private func sampleImages() {
        guard VividImageDiagnostics.shared.enabled else { return }
        for (name, values) in VividImageDiagnostics.shared.drain() { event(name, values: values) }
        event("image.decode.operations", values: VividImagePipeline.shared.diagnosticDecodeOperations())
    }

    private func write(_ capture: Capture) {
        let url = outputURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(capture) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    deinit {
        if armed {
            CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque())
        }
    }
}

/// Keep focus bookkeeping outside the feed's view dependencies. Only the
/// affected rows and artwork worker need to observe a change of row owner.
@Observable
final class TVHomeFocusOwnership {
    var rowID: String? {
        didSet {
            guard oldValue != rowID, let oldValue else { return }
            cancellations[oldValue]?()
        }
    }
    @ObservationIgnored private var cancellations: [String: () -> Void] = [:]

    func registerCancellation(for rowID: String, action: @escaping () -> Void) {
        cancellations[rowID] = action
    }

    func unregisterCancellation(for rowID: String) {
        cancellations.removeValue(forKey: rowID)
    }
}

private struct TVHomeFocusOwnershipKey: EnvironmentKey {
    static let defaultValue: TVHomeFocusOwnership? = nil
}

private struct TVHomeScrollDiagnosticsKey: EnvironmentKey {
    static let defaultValue: TVHomeScrollDiagnostics? = nil
}

extension EnvironmentValues {
    var tvHomeFocusOwnership: TVHomeFocusOwnership? {
        get { self[TVHomeFocusOwnershipKey.self] }
        set { self[TVHomeFocusOwnershipKey.self] = newValue }
    }
    var tvHomeScrollDiagnostics: TVHomeScrollDiagnostics? {
        get { self[TVHomeScrollDiagnosticsKey.self] }
        set { self[TVHomeScrollDiagnosticsKey.self] = newValue }
    }
}

private struct TVHomeArtworkWarmupKey: Equatable {
    let sections: [ResolvedSection]
    let presentation: CardPresentationPreference
    let rowID: String?
    let scenePhase: ScenePhase
}

private struct TVHomeArtworkWarmupModifier: ViewModifier {
    let sections: [ResolvedSection]
    let presentation: CardPresentationPreference
    let focus: TVHomeFocusOwnership
    let memory: TVHomeRowFocusMemory
    /// Home's Continue Watching and Next Up show series backgrounds; warm those.
    var seriesBackdrops = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var artworkWarmup = TVHomeArtworkWarmup()

    func body(content: Content) -> some View {
        content
            .task(id: TVHomeArtworkWarmupKey(sections: sections, presentation: presentation,
                rowID: focus.rowID, scenePhase: scenePhase)) {
                // Cached Home starts warming immediately. Repeated row changes
                // defer request construction and reprioritisation until a pause.
                if focus.rowID != nil {
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                artworkWarmup.update(homeArtworkRequests)
            }
            .onDisappear { artworkWarmup.stop() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                artworkWarmup.stop()
            }
    }

    private var homeArtworkRequests: [VividImageRequest] {
        guard scenePhase == .active, !sections.isEmpty else { return [] }
        let current = sections.firstIndex { $0.id == focus.rowID } ?? 0
        let indices = [current] + Array((current + 1)..<min(sections.count, current + 4))
            + (current > 0 ? [current - 1] : [])
        let viewportWidth = max(1, UIScreen.main.bounds.width - VividTheme.safePadding * 2)
        var priorityCards: [VividImageRequest] = []
        var rows: [[VividImageRequest]] = []
        for index in indices {
            let section = sections[index]
            let wide = section.tvHomeUsesLandscapeArtwork
            let baseWidth = wide ? VividTheme.thumbnailCardWidth : VividTheme.Skyline.densePosterCardWidth
            let ratio = wide ? VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth
                : VividTheme.posterCardHeight / VividTheme.posterCardWidth
            // Use the same arithmetic as the card before rounding to pixel keys.
            let width = baseWidth * presentation.posterSize.scale
            let height = width * ratio
            let size = CGSize(width: width * PosterImageCache.displayScale,
                              height: height * PosterImageCache.displayScale)
            let visibleCount = max(1, Int(ceil((viewportWidth + 40) / (width + 40))))
            let focusedIndex = section.items.firstIndex { $0.contentId == memory.items[section.id] } ?? 0
            // Each collection keeps its horizontal offset when another row
            // takes focus. Warm that destination, including the full final
            // screenful, instead of decoding card 1 again for a row at card 20.
            let start = min(max(0, focusedIndex - 1), max(0, section.items.count - visibleCount))
            let end = min(section.items.count, start + visibleCount)
            let seriesArt = wide && seriesBackdrops && HomeSeriesBackdrops.applies(toSectionType: section.sectionType)
            let rowRequests: [VividImageRequest] = section.items[start..<end].compactMap { item in
                let value = seriesArt ? HomeSeriesBackdrops.shared.art(for: item).url
                    : wide ? (item.backdropUrl.flatMap { $0.isEmpty ? nil : $0 } ?? item.posterUrl) : item.posterUrl
                guard let value, let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return PosterImageCache.displayRequest(url: url, pixelSize: size, priority: .low)
            }
            if index == current {
                priorityCards = Array(rowRequests.prefix(3))
            }
            rows.append(rowRequests)
        }
        // Keep the focused card's neighbours ready, then favour vertical
        // travel before filling the remainder of the current screenful.
        // Card memory is non-observable: horizontal moves do not requeue work.
        let upcomingCount = min(3, sections.count - current - 1)
        let upcoming = rows.dropFirst().prefix(upcomingCount).flatMap { $0 }
        let remaining = (rows.first ?? []) + rows.dropFirst(1 + upcomingCount).flatMap { $0 }
        var seen = Set<VividImageRequest>()
        let requests = (priorityCards + upcoming + remaining).filter { seen.insert($0).inserted }
        return requests
    }

}

@MainActor
private final class TVHomeArtworkWarmup {
    private let prefetcher = VividImagePrefetcher(
        pipeline: VividImagePipeline.shared, destination: .memoryCache,
        maxConcurrentRequestCount: 2
    )

    func update(_ requests: [VividImageRequest]) {
        guard !requests.isEmpty else { stop(); return }
        // Finish at most two active requests, then favour the newly focused row.
        PosterImageCache.setHomeBrowsingMemoryBudget(true)
        prefetcher.replacePendingPrefetching(with: requests.filter {
            VividImagePipeline.shared.cache[$0] == nil
        })
    }

    func stop() {
        prefetcher.stopPrefetching()
        PosterImageCache.setHomeBrowsingMemoryBudget(false)
    }
}

/// Settings > General > Appearance > Theme Mode, on Apple TV only: what
/// colours the background over the base theme.
enum TVThemeMode: String, CaseIterable, Identifiable {
    /// Only the base theme.
    case off
    /// Home's first screen takes the Spotlight slide's colour.
    case spotlightOnly
    /// The root pages take the colour of whatever poster has focus.
    case adaptive

    static let storageKey = "vivid.tv.themeMode"
    /// The On and Off setting this replaced. Off stays Off.
    private static let legacyKey = "vivid.tv.spotlightGradient"

    /// The value until one is chosen, carried over from the old setting.
    static var defaultValue: TVThemeMode {
        UserDefaults.standard.object(forKey: legacyKey) as? Bool == false ? .off : .spotlightOnly
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .spotlightOnly: String(localized: "Spotlight Only", comment: "Apple TV theme mode")
        case .adaptive: String(localized: "Adaptive", comment: "Apple TV theme mode")
        }
    }
}

/// The Spotlight and Adaptive backdrops' shading, shared so both look the same.
enum TVThemeWash {
    /// Opaque shades of the slide's own hue, so the theme behind doesn't
    /// show through: near black at the bottom left, lit at the top right.
    /// Matte rather than glossy: the colour stays saturated all the way
    /// down instead of greying out in the dark, the top right is a soft
    /// lift rather than a sheen, and hues that look dim at the same
    /// brightness (blue, red, purple) are lifted to match bright ones
    /// (yellow, green), so no part reads paler than the colour.
    static func gradient(_ tint: Color) -> LinearGradient {
        gradient(shades: shades(tint))
    }

    /// The gradient's four colours, bottom left to top right.
    static func gradient(shades: [Color]) -> LinearGradient {
        LinearGradient(
            stops: zip(shades, locations).map { Gradient.Stop(color: $0, location: $1) },
            startPoint: .bottomLeading, endPoint: .topTrailing
        )
    }

    private static let locations: [CGFloat] = [0, 0.45, 0.8, 1]

    static func shades(_ tint: Color) -> [Color] {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(tint).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // A neutral tint (black and white artwork) stays neutral; any real
        // colour gets enough saturation to hold its hue in the dark.
        let edge = min(1, max(0, (saturation - 0.06) / 0.14))
        let lift = edge * edge * (3 - 2 * edge)
        let rich = min(0.9, saturation * 1.25 + 0.12 * lift)
        // How bright the hue looks at full brightness, from its linear
        // luminance; dim hues get up to 30% more brightness.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(hue: hue, saturation: rich, brightness: 1, alpha: 1).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let evenness = min(1.3, max(1, pow(1 / max(luminance, 0.01), 0.2)))
        func shade(_ value: CGFloat, saturationBoost: CGFloat = 0) -> Color {
            Color(hue: hue, saturation: min(0.95, rich + saturationBoost * lift), brightness: min(1, value * evenness))
        }
        return [
            shade(0.035, saturationBoost: 0.08),
            shade(0.075, saturationBoost: 0.05),
            shade(0.15, saturationBoost: 0.02),
            shade(0.21)
        ]
    }

    static let grainTile: UIImage = {
        let size = 128
        var seed: UInt32 = 0x4D415454
        var pixels = [UInt8](repeating: 0, count: size * size)
        for index in pixels.indices {
            seed = seed &* 1664525 &+ 1013904223
            // 0 to 15% grey: at 4% that's at most 1.5 levels, enough to
            // dither the ramp while barely lifting the darkest corner.
            pixels[index] = UInt8(truncatingIfNeeded: (seed >> 24) * 38 / 255)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: image)
    }()
}

/// The carousel's position, for the glow behind Home. Only the glow
/// observes it, so a slide change doesn't invalidate the feed.
@Observable
private final class TVHomeSpotlightAmbience {
    var position: Int?
}

/// An opaque backdrop in the current slide's colour behind the top of Home:
/// brightest at the top right, darkest at the bottom left. It covers the
/// first screen and fades out below it, so it ends without an edge. A new slide's colour fades in over the old one;
/// only opacity animates.
private struct TVHomeSpotlightGlow: View {
    let ambience: TVHomeSpotlightAmbience
    let slides: [TVHomeSpotlightSlide]
    /// Where the carousel starts, until it reports a position.
    let initialPosition: Int

    @State private var front: Color?
    @State private var back: Color?
    @State private var frontOpacity: Double = 0
    @State private var run = 0
    @AppStorage(TVThemeMode.storageKey) private var themeMode = TVThemeMode.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Adaptive draws its own backdrop behind every root page instead.
    private var isEnabled: Bool { themeMode == .spotlightOnly }

    /// Solid for the whole first screen, then fading out below it.
    private static let height: CGFloat = 1620
    private static let solidHeight: CGFloat = 1100

    var body: some View {
        ZStack {
            if isEnabled {
                if let back { backdrop(back) }
                if let front { backdrop(front).opacity(frontOpacity) }
                if back != nil || front != nil {
                    grain.opacity(back != nil ? 1 : frontOpacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isEnabled ? artworkURL : nil) {
            // Off: the theme shows as before and no colour is looked up.
            guard isEnabled else {
                front = nil
                back = nil
                return
            }
            // A slide with no artwork has no colour of its own; don't leave
            // the last slide's showing.
            guard let string = artworkURL, let url = URL(string: string) else {
                hide()
                return
            }
            let cached = TVHomeMetadataCache.shared.cachedSpotlightTint(for: url)
            let prepared: Color?
            if let cached { prepared = cached } else {
                prepared = await TVHomeMetadataCache.shared.preparedSpotlightTint(for: url)
            }
            guard !Task.isCancelled else { return }
            if let tint = prepared { show(tint) } else { hide() }
        }
    }

    /// The artwork the current slide shows. Worked out here from the live
    /// slides, so it follows a reload that changes the slide in place and an
    /// episode's series background arriving after the slide first appears.
    private var artworkURL: String? {
        guard !slides.isEmpty else { return nil }
        let position = ambience.position ?? initialPosition
        let slide = slides[((position % slides.count) + slides.count) % slides.count]
        return slide.content.backdropUrl ?? slide.content.fallbackArtworkUrl
    }

    /// The first screen is the plain gradient. Only the strip below it,
    /// off screen until Home scrolls, is masked to fade out; both pieces
    /// are windows onto the same gradient, so they meet without a seam.
    private func backdrop(_ tint: Color) -> some View {
        VStack(spacing: 0) {
            wash(tint)
                .frame(height: Self.height)
                .frame(height: Self.solidHeight, alignment: .top)
                .clipped()
            wash(tint)
                .frame(height: Self.height)
                .frame(height: Self.height - Self.solidHeight, alignment: .bottom)
                .clipped()
                .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom) }
        }
    }

    private func wash(_ tint: Color) -> some View {
        TVThemeWash.gradient(tint)
    }

    /// A fixed, faint grain over the colour that gives it a matte finish and
    /// breaks up banding in the dark ramp. It's one small tile drawn once and
    /// repeated, it never animates, and it's dark on average so it doesn't
    /// grey out the colour under it.
    /// Like the backdrop, only the strip below the first screen is masked.
    private var grain: some View {
        VStack(spacing: 0) {
            grainTiles.frame(height: Self.solidHeight)
            grainTiles
                .frame(height: Self.height - Self.solidHeight)
                .mask { LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom) }
        }
        .opacity(0.04)
    }

    private var grainTiles: some View {
        Image(uiImage: TVThemeWash.grainTile)
            .resizable(resizingMode: .tile)
            .interpolation(.none)
    }


    /// Fades the backdrop out to the theme.
    private func hide() {
        guard front != nil || back != nil else { return }
        run += 1
        let token = run
        var snap = Transaction(animation: nil)
        snap.disablesAnimations = true
        withTransaction(snap) { back = nil }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.6)) {
            frontOpacity = 0
        } completion: {
            if token == run { front = nil }
        }
    }

    /// The colour on show drops behind and the new one fades in over it.
    private func show(_ tint: Color) {
        run += 1
        let token = run
        var snap = Transaction(animation: nil)
        snap.disablesAnimations = true
        withTransaction(snap) {
            if let front, frontOpacity > 0.5 { back = front }
            front = tint
            frontOpacity = 0
        }
        DispatchQueue.main.async {
            guard token == run else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 1.6)) {
                frontOpacity = 1
            } completion: {
                // The colour underneath is fully covered now; stop drawing it.
                if token == run { back = nil }
            }
        }
    }
}

/// Remember card selection without invalidating the entire feed for every
/// horizontal focus move. Each row already observes its own focused card.
private final class TVHomeRowFocusMemory {
    var items: [String: String] = [:]
    var spotlightPosition = 0
    var spotlightFocused = false
}

private struct TVHomeSpotlightCarousel: View {
    let slides: [TVHomeSpotlightSlide]
    let enterRequest: Int
    let onFocusChange: (Bool) -> Void
    let onEnterFirstRow: () -> Void
    @FocusState private var focusedPosition: Int?
    @State private var appliedEnterRequest: Int
    @State private var automaticAdvanceInFlight = false
    @State private var alignmentAttempted = false
    private var focus: FocusState<Int?>.Binding { $focusedPosition }
    let onPositionChange: (Int) -> Void
    let onSelect: (TVHomeSpotlightSlide, Int) -> Void

    /// The space either side of the centred card.
    private static let sideMargin: CGFloat = 60
    /// The gap between cards. As wide as the side margin, so the cards
    /// either side of the centred one rest just off screen and only show
    /// while the carousel slides.
    private static let cardSpacing: CGFloat = sideMargin

    @State private var visualPosition = 0
    @State private var scrollPosition = ScrollPosition(id: 0, anchor: .center)
    @State private var scrollGeometry = TVSpotlightScrollGeometry()
    @State private var lowerPosition: Int
    @State private var upperPosition: Int
    @State private var pendingPosition: Int?
    /// Set when a card is pressed, so an automatic advance can't start under
    /// the zoom and play back the other way on Back.
    @State private var holdsForSelection = false
    /// Whether the press being held for opened a page, so only its flight
    /// back releases the hold.
    @State private var holdOpenedPage = false
    @State private var isOnScreen = false
    @State private var initialCardPresented = false
    @State private var centredPosition: Int?
    @Namespace private var carouselSpace
    @State private var scrollIsMoving = false
    @State private var cycleElapsed: TimeInterval = 0
    @State private var cycleResumedAt: Date?
    @State private var readyPositions: [Int: String] = [:]
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.tvHomeScrollDiagnostics) private var diagnostics

    init(
        slides: [TVHomeSpotlightSlide],
        enterRequest: Int,
        initialPosition: Int,
        onPositionChange: @escaping (Int) -> Void,
        onFocusChange: @escaping (Bool) -> Void,
        onEnterFirstRow: @escaping () -> Void,
        onSelect: @escaping (TVHomeSpotlightSlide, Int) -> Void
    ) {
        self.slides = slides
        self.enterRequest = enterRequest
        _appliedEnterRequest = State(initialValue: enterRequest)
        self.onFocusChange = onFocusChange
        self.onEnterFirstRow = onEnterFirstRow
        let startPosition = initialPosition
        self.onPositionChange = onPositionChange
        self.onSelect = onSelect
        _visualPosition = State(initialValue: startPosition)
        _scrollPosition = State(initialValue: ScrollPosition(id: startPosition, anchor: .center))
        let span = max(1, slides.count * 3)
        _lowerPosition = State(initialValue: startPosition - span)
        _upperPosition = State(initialValue: startPosition + span + 1)
    }

    private var index: Int {
        guard !slides.isEmpty else { return 0 }
        return ((visualPosition % slides.count) + slides.count) % slides.count
    }
    private func slide(at position: Int) -> TVHomeSpotlightSlide {
        slides[((position % slides.count) + slides.count) % slides.count]
    }
    private var homeIsOpen: Bool {
        scenePhase == .active && router.authState == .authenticated
            && router.path.isEmpty && router.presentedPlayer == nil
            && !TVSavedAccountStore.shared.busy
            && !TVSavedAccountStore.shared.showsSelector
            && !TVLoginPreparation.shared.isPresented
    }
    private var canRotate: Bool {
        initialCardPresented && homeIsOpen && !holdsForSelection && isOnScreen && slides.count > 1 && !scrollIsMoving
            && !voiceOverEnabled && centredPosition == visualPosition
            && readyPositions[visualPosition] == slide(at: visualPosition).id
    }
    private var rotationKey: String {
        "\(slides.map(\.id).joined(separator: "|"))#\(visualPosition)#\(canRotate)"
    }
    private var renderedPositions: Range<Int> {
        guard !slides.isEmpty else { return 0..<0 }
        return slides.count == 1 ? visualPosition..<(visualPosition + 1) : lowerPosition..<upperPosition
    }

    private func updatePositionWindow(around position: Int, isIdle: Bool = false) {
        guard slides.count > 1 else { return }
        let margin = slides.count
        let span = slides.count * 3
        // Keep a runway in both directions without changing card identities.
        if position - lowerPosition < margin || upperPosition - position <= margin {
            diagnostics?.event("spotlight.recycle", values: [Double(position), Double(lowerPosition)])
            if focus.wrappedValue == nil || isIdle {
                // Automatic movement recycles after its animation has finished.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    lowerPosition = position - span
                    upperPosition = position + span + 1
                    scrollPosition.scrollTo(id: position, anchor: .center)
                }
            } else {
                // Preserve the exact visible offset, including a partial slide,
                // when removing copies changes the content coordinate origin.
                let shift = CGFloat(position - span - lowerPosition) * scrollGeometry.cardStride
                let offset = scrollGeometry.offset - shift
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                transaction.scrollPositionUpdatePreservesVelocity = true
                withTransaction(transaction) {
                    lowerPosition = position - span
                    upperPosition = position + span + 1
                    scrollPosition.scrollTo(x: offset)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            GeometryReader { geometry in
                let cardWidth = max(1, geometry.size.width - Self.sideMargin * 2)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.cardSpacing) {
                        ForEach(renderedPositions, id: \.self) { position in
                            let slide = slide(at: position)
                            Button { selectCard(slide, at: position) } label: {
                                Group {
                                    if abs(position - visualPosition) <= 3 {
                                        TVHomeSpotlightArtwork(slide: slide, zoomSourceID: tvSpotlightZoomSourceID(position: position), onReady: {
                                            readyPositions[position] = slide.id
                                            revealPendingSlide()
                                        })
                                        .id(slide.id)
                                        .onDisappear {
                                            if readyPositions[position] == slide.id {
                                                readyPositions.removeValue(forKey: position)
                                            }
                                        }
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: cardWidth, height: 775)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .modifier(TVSpotlightZoomSource(id: tvSpotlightZoomSourceID(position: position)))
                                .overlay(alignment: .bottomTrailing) {
                                    // On the card itself, so it slides with it.
                                    if slides.count > 1, !voiceOverEnabled, abs(position - visualPosition) <= 1 {
                                        cycleProgressPill(at: position).padding(48)
                                    }
                                }
                            }
                            .buttonStyle(TVSpotlightButtonStyle(
                                artworkURL: slide.content.backdropUrl ?? slide.content.fallbackArtworkUrl
                            ))
                            .focused(focus, equals: position)
                            .onGeometryChange(for: Bool.self) { proxy in
                                let frame = proxy.frame(in: .named(carouselSpace))
                                return abs(frame.midX - geometry.size.width / 2) <= 2
                            } action: { centred in
                                if centred { centredPosition = position }
                                else if centredPosition == position { centredPosition = nil }
                                finishAutomaticAdvanceIfReady()
                                completeInitialPresentationIfReady()
                            }
                            .accessibilityLabel(slide.content.title)
                            .accessibilityValue("Slide \(((position % slides.count) + slides.count) % slides.count + 1) of \(slides.count)")
                            .accessibilityHint("Press to open. Swipe left or right to change the spotlight.")
                            .id(position)
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, Self.sideMargin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .defaultScrollAnchor(.center, for: .initialOffset)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) {
                    $0.contentOffset.x + $0.contentInsets.leading
                } action: { _, offset in
                    scrollGeometry.offset = offset
                    scrollGeometry.cardStride = cardWidth + Self.cardSpacing
                    if focus.wrappedValue == visualPosition {
                        updatePositionWindow(around: visualPosition)
                    }
                }
                .coordinateSpace(name: carouselSpace)
                .defaultFocus(focus, visualPosition)
                .scrollClipDisabled()
                .onScrollPhaseChange { _, phase in
                    diagnostics?.event("spotlight.phase.\(phase)")
                    scrollIsMoving = phase != .idle
                    if phase == .idle {
                        finishAutomaticAdvanceIfReady()
                        if focusedPosition == nil { updatePositionWindow(around: visualPosition) }
                    }
                    // A recycled origin can leave a fractional offset after
                    // native deceleration. At most one correction per selection:
                    // another idle callback must not start an animation loop.
                    let target = CGFloat(visualPosition - lowerPosition) * scrollGeometry.cardStride
                    if phase == .idle, initialCardPresented,
                       automaticAdvanceInFlight || focus.wrappedValue == nil || focus.wrappedValue == visualPosition,
                       !alignmentAttempted, abs(scrollGeometry.offset - target) > 2 {
                        alignmentAttempted = true
                        diagnostics?.event("spotlight.align", values: [Double(scrollGeometry.offset), Double(target)])
                        let residual = abs(scrollGeometry.offset - target)
                        var transaction = Transaction(animation: reduceMotion || residual < scrollGeometry.cardStride - Self.cardSpacing
                            ? nil : .easeOut(duration: 0.12))
                        transaction.disablesAnimations = transaction.animation == nil
                        withTransaction(transaction) {
                            scrollPosition.scrollTo(id: visualPosition, anchor: .center)
                        }
                    }
                }
                .focusSection()
                .onMoveCommand { direction in
                    guard direction == .down, focusedPosition != nil else { return }
                    // The destination makes the single focus claim. Clearing
                    // this binding first would invite an intermediate repair.
                    onEnterFirstRow()
                }
            }
            .frame(height: 775)
        }
        .onChange(of: enterRequest, initial: true) { _, request in
            guard request > appliedEnterRequest else { return }
            appliedEnterRequest = request
            focusedPosition = visualPosition
        }
        .onChange(of: focusedPosition) { previous, position in
            alignmentAttempted = false
            if (previous != nil) != (position != nil) { onFocusChange(position != nil) }
            if let position, position != visualPosition {
                automaticAdvanceInFlight = false
                pendingPosition = nil
                selectPosition(position)
            }
            completeInitialPresentationIfReady()
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isOnScreen = visible
            if visible { completeInitialPresentationIfReady() }
        }
        .onDisappear {
            isOnScreen = false
            pauseCycle()
            onFocusChange(false)
            automaticAdvanceInFlight = false
            pendingPosition = nil
        }
        .onChange(of: homeIsOpen, initial: true) { _, open in
            // Only a page on the stack counts as the press having opened one;
            // backgrounding or the profile picker also close Home.
            if !open, holdsForSelection, !router.path.isEmpty { holdOpenedPage = true }
            if open {
                // Home is back as Back starts; the hold lasts until the flight
                // back has landed, so the carousel can't move under it. Home
                // back without a page keeps the two-second release.
                if holdsForSelection {
                    let delay = holdOpenedPage ? TVSpotlightLogoFlight.totalDuration + 0.1 : 2
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        if homeIsOpen, holdsForSelection {
                            holdsForSelection = false
                            holdOpenedPage = false
                        }
                    }
                }
                completeInitialPresentationIfReady()
            }
        }
        .task(id: holdsForSelection) {
            // Lets go if the press never opened a page.
            guard holdsForSelection else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if homeIsOpen, !holdOpenedPage { holdsForSelection = false }
        }
        .onChange(of: canRotate, initial: true) { _, running in
            if running {
                if cycleResumedAt == nil { cycleResumedAt = Date() }
                revealPendingSlide()
            } else {
                pauseCycle()
            }
        }
        .onChange(of: slides.map(\.id)) { _, ids in
            pendingPosition = nil
            readyPositions = readyPositions.filter { ids.contains($0.value) }
        }
        // Slides can come from rows Home hides, so look up their series
        // backgrounds here as well as in the rows.
        .task(id: slides.map(\.id)) {
            await HomeSeriesBackdrops.shared.keepPrepared(slides.map(\.item))
        }
        .task(id: rotationKey) {
            guard canRotate else { return }
            let remaining = max(0, 6 - elapsedCycle(at: Date()))
            // Scrolling only recycles while focus is already on the new
            // card, and focus catches up after an automatic scroll ends, so
            // a focused Spotlight never recycled and stalled once it ran out
            // of rendered copies. Recycle while the carousel is still, well
            // clear of the focus update and the next scroll.
            let recycleDelay = min(1, remaining / 2)
            do { try await Task.sleep(for: .seconds(recycleDelay)) } catch { return }
            guard !Task.isCancelled else { return }
            updatePositionWindow(around: visualPosition, isIdle: true)
            do { try await Task.sleep(for: .seconds(remaining - recycleDelay)) } catch { return }
            guard !Task.isCancelled else { return }
            pendingPosition = visualPosition + 1
            revealPendingSlide()
        }
    }

    /// A small pill in each card's bottom-right corner that fills over the
    /// slide's six seconds, so it's clear the Spotlight moves on by itself.
    /// Cards before the current one show it full and cards after it show
    /// it empty, so moving forward the old card leaves full and the new one
    /// arrives empty.
    private func cycleProgressPill(at position: Int) -> some View {
        TVSpotlightCyclePill(
            isCurrent: position == visualPosition,
            restsFull: position < visualPosition,
            elapsed: cycleElapsed,
            resumedAt: cycleResumedAt
        )
    }

    /// Opens a card. Rotation stops at once, and a slide already on its way
    /// to the next card snaps back to the pressed one without animation, so
    /// the zoom leaves from and returns to the card that was chosen.
    private func selectCard(_ slide: TVHomeSpotlightSlide, at position: Int) {
        holdsForSelection = true
        pendingPosition = nil
        // The card gets its full six seconds once Home is back.
        cycleElapsed = 0
        cycleResumedAt = nil
        if visualPosition != position {
            automaticAdvanceInFlight = false
            selectPosition(position)
            var snap = Transaction(animation: nil)
            snap.disablesAnimations = true
            withTransaction(snap) {
                scrollPosition.scrollTo(id: position, anchor: .center)
            }
        }
        onSelect(slide, position)
    }

    private func selectPosition(_ position: Int) {
        guard !slides.isEmpty, position != visualPosition else { return }
        let previousIndex = index
        alignmentAttempted = false
        visualPosition = position
        // The parent restores this exact native card after leaving the spotlight.
        onPositionChange(position)
        if index != previousIndex {
            cycleElapsed = 0
            cycleResumedAt = canRotate ? Date() : nil
        }
    }

    private func completeInitialPresentationIfReady() {
        guard homeIsOpen, isOnScreen, !initialCardPresented,
              centredPosition == visualPosition else { return }
        // Artwork readiness can precede initial placement when Home is cached.
        // It cannot consume any of the first card's six-second countdown.
        pendingPosition = nil
        cycleElapsed = 0
        cycleResumedAt = nil
        initialCardPresented = true
    }

    private func elapsedCycle(at date: Date) -> TimeInterval {
        cycleElapsed + (cycleResumedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    private func pauseCycle() {
        cycleElapsed = elapsedCycle(at: Date())
        cycleResumedAt = nil
    }

    private func finishAutomaticAdvanceIfReady() {
        guard automaticAdvanceInFlight, !scrollIsMoving,
              centredPosition == visualPosition else { return }
        automaticAdvanceInFlight = false
        // Never steal focus from a shelf after an interrupted auto-advance.
        if focusedPosition != nil { focusedPosition = visualPosition }
    }

    private func revealPendingSlide() {
        guard canRotate, let position = pendingPosition, !slides.isEmpty,
              readyPositions[position] == slide(at: position).id else { return }
        pendingPosition = nil
        // Move the artwork first. Moving focus to an off-centre future
        // slide gives native Down the wrong horizontal origin.
        automaticAdvanceInFlight = true
        selectPosition(position)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            scrollPosition.scrollTo(id: position, anchor: .center)
        }

    }
}

/// The Spotlight's countdown pill. One linear animation runs each stretch
/// of the wait, so nothing is recomputed per frame and the carousel isn't
/// invalidated while it fills.
private struct TVSpotlightCyclePill: View {
    let isCurrent: Bool
    let restsFull: Bool
    /// Time already counted before the current stretch.
    let elapsed: TimeInterval
    /// When the current stretch started; nil while rotation is paused.
    let resumedAt: Date?

    @State private var progress: Double = 0
    @State private var run = 0

    private static let width: CGFloat = 80
    private static let cycle: TimeInterval = 6

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .overlay {
                // Moved, not resized, so the fill is a plain transform.
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .offset(x: -Self.width * (1 - progress))
            }
            .clipShape(Capsule())
            .frame(width: Self.width, height: 6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: isCurrent, initial: true) { sync() }
            .onChange(of: restsFull) { sync() }
            .onChange(of: elapsed) { sync() }
            .onChange(of: resumedAt) { sync() }
    }

    /// Jumps to where the wait stands now, then runs the rest of it.
    private func sync() {
        run += 1
        let token = run
        let counted = isCurrent
            ? elapsed + (resumedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
            : (restsFull ? Self.cycle : 0)
        let current = min(1, max(0, counted / Self.cycle))
        var snap = Transaction(animation: nil)
        snap.disablesAnimations = true
        withTransaction(snap) { progress = current }
        guard isCurrent, resumedAt != nil, current < 1 else { return }
        // In its own update, so it animates from the snapped value.
        DispatchQueue.main.async {
            guard token == run else { return }
            withAnimation(.linear(duration: Self.cycle * (1 - current))) { progress = 1 }
        }
    }
}

/// Registers a Spotlight card as the zoom source for the page it opens.
private struct TVSpotlightZoomSource: ViewModifier {
    let id: String
    @Environment(\.tvSpotlightZoomSpace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: 22))
            }
        } else {
            content
        }
    }
}

/// A native button with a fixed-size focus outline for the large hero card.
private struct TVSpotlightButtonStyle: ButtonStyle {
    let artworkURL: String?
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Read only prepared colour; a missing tint keeps the white outline.
        let tint = artworkURL.flatMap { URL(string: $0) }
            .flatMap { TVHomeMetadataCache.shared.cachedSpotlightTint(for: $0) } ?? .white
        return configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(
                        LinearGradient(stops: [
                            .init(color: .white.opacity(0.95), location: 0),
                            .init(color: tint.opacity(0.45), location: 0.28),
                            .init(color: .white.opacity(0.15), location: 0.52),
                            .init(color: tint.opacity(0.4), location: 0.76),
                            .init(color: .white.opacity(0.8), location: 1)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1.5
                    )
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A Spotlight slide's overview in at most three lines that never stops
/// mid-sentence: the whole overview when it fits, otherwise as many
/// complete sentences as fit.
private struct TVSpotlightOverview: View {
    let text: String

    private static let fontSize: CGFloat = 22
    private static let width: CGFloat = 760
    private static let maxLines = 3

    var body: some View {
        Text(Self.fitted(text))
            .font(.system(size: Self.fontSize, weight: .regular))
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(Self.maxLines)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func fitted(_ text: String) -> String {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        let limit = font.lineHeight * CGFloat(maxLines) + 1
        func fits(_ candidate: String) -> Bool {
            let height = (candidate as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil
            ).height
            return ceil(height) <= limit
        }
        if fits(text) { return text }
        var sentenceEnds: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            sentenceEnds.append(range.upperBound)
        }
        // Longest run of whole sentences that fits; the first sentence alone
        // is the last resort, and the line limit catches one too long to fit.
        for end in sentenceEnds.dropLast().reversed() {
            let candidate = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if fits(candidate) { return candidate }
        }
        return sentenceEnds.first.map { text[..<$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? text
    }
}

/// Scroll measurements do not invalidate artwork or the Home view on each frame.
private final class TVSpotlightScrollGeometry {
    var offset: CGFloat = 0
    var cardStride: CGFloat = 1
}

private struct TVHomeSpotlightArtwork: View {
    let slide: TVHomeSpotlightSlide
    /// This card's zoom source, which also keys its logo for the flight to
    /// the detail page.
    let zoomSourceID: String
    let onReady: () -> Void
    @State private var artworkReady = false
    @State private var logoReady = false
    @State private var reportedReady = false
    @State private var model = TVSpotlightArtworkModel()
    @State private var logo: UIImage?

    private static let fadeStops: [Gradient.Stop] = {
        let anchors: [(Double, Double)] = [(0, 0), (0.28, 0.02), (0.45, 0.08), (0.72, 0.4), (1, 0.82)]
        return (0...128).map { step in
            let x = Double(step) / 128
            let segment = (0..<anchors.count - 1).first { x <= anchors[$0 + 1].0 } ?? anchors.count - 2
            let (start, from) = anchors[segment]
            let (end, to) = anchors[segment + 1]
            let t = (x - start) / (end - start)
            let eased = t * t * (3 - 2 * t)
            return .init(color: .black.opacity(from + (to - from) * eased), location: x)
        }
    }()

    private static let fadeDither: UIImage = {
        let size = 128
        var seed: UInt32 = 0x56495649
        var pixels = [UInt8](repeating: 0, count: size * size)
        for index in pixels.indices {
            seed = seed &* 1664525 &+ 1013904223
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: image)
    }()

    /// The centred card starts 60 points in from the screen edge (the
    /// carousel's margin), so this puts the logo and details on the detail
    /// pages' logo edge and the logo flies straight up when a title opens.
    private static let contentLeadingInset = TVDetailHeroLayout.horizontalInset - 60

    var body: some View {
        GeometryReader { geometry in
            let artworkSize = CGSize(
                width: min(geometry.size.width, 1800),
                height: geometry.size.height
            )
            ZStack(alignment: .bottom) {
                model.tintColor
                if let url = model.backdropURL {
                    TVSpotlightBackdropImage(url: url, size: artworkSize, fillsViewport: true,
                                             onReady: { artworkReady = true },
                                             onLayout: { image, crop in
                                                 TVSpotlightLogoFlight.shared.registerBackdrop(
                                                     sourceID: zoomSourceID, slideID: slide.id, image: image, crop: crop)
                                             })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                LinearGradient(
                    stops: Self.fadeStops,
                    startPoint: .top, endPoint: .bottom
                )
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                // Darkens the corner behind the logo so it stands off bright
                // artwork while the rest of the image stays clear.
                RadialGradient(
                    stops: [
                        .init(color: .black.opacity(0.6), location: 0),
                        .init(color: .black.opacity(0.3), location: 0.45),
                        .init(color: .clear, location: 1)
                    ],
                    center: .bottomLeading, startRadius: 0, endRadius: geometry.size.width * 0.6
                )
                Image(uiImage: Self.fadeDither)
                    .resizable(resizingMode: .tile)
                    .opacity(0.008)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0.15),
                            .init(color: .white, location: 0.35),
                            .init(color: .white, location: 0.8),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                    }
                VStack(alignment: .leading, spacing: 18) {
                    if let logo {
                        Image(uiImage: logo)
                            .resizable().interpolation(.high).scaledToFit()
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                TVSpotlightLogoFlight.shared.register(sourceID: zoomSourceID, slideID: slide.id,
                                                                      image: logo, frame: frame)
                            }
                            .opacity(TVSpotlightLogoFlight.shared.hiddenSourceID == zoomSourceID ? 0 : 1)
                            .frame(width: 600, height: 200, alignment: .bottomLeading)
                            .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 6)
                    } else {
                        Text(slide.content.title)
                            .font(.system(size: 62, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 760, alignment: .leading)
                            .shadow(color: .black.opacity(0.5), radius: 22, x: 0, y: 6)
                    }
                    Group {
                        if isEpisode {
                            Text(([typeLabel] + slide.content.metaParts
                                  + [slide.content.contentRatingBadge].compactMap { $0 }).joined(separator: "  ·  "))
                                .font(.system(size: 23, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        } else {
                            // The same heading as the title's detail page.
                            TVDetailCompactHeading(
                                tokens: [typeLabel],
                                genres: Array((slide.item.genres ?? []).filter { !$0.isEmpty }.prefix(2)),
                                contentRating: TVHeroMetadata.contentRating(slide.item.contentRating)
                            )
                        }
                    }
                    // The detail heading's height, so the logo sits at the
                    // same height for every slide, rated or not.
                    .frame(width: logo == nil ? 760 : 600, height: 36, alignment: .leading)
                    .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 2)
                    if let overview = slide.item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !overview.isEmpty {
                        TVSpotlightOverview(text: overview)
                            .frame(width: 760, alignment: .leading)
                            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 2)
                    }
                }
                .foregroundStyle(.white)
                .padding(.vertical, 48)
                .padding(.leading, Self.contentLeadingInset)
                .padding(.trailing, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            TVSpotlightLogoFlight.shared.registerCard(sourceID: zoomSourceID, frame: frame)
        }
        .onAppear {
            model.resume()
            model.seed(slide.content)
            if model.backdropURL == nil { artworkReady = true }
            if reportedReady { onReady() }
        }
        .onDisappear { model.suspend() }
        .onChange(of: artworkReady && logoReady) { _, ready in
            if ready { reportReady() }
        }
        .task(id: slide.item.logoUrl) {
            defer { logoReady = true }
            guard let string = slide.item.logoUrl, let url = URL(string: string) else { return }
            // Trimmed, so a logo with empty space baked into its image
            // still sits right on the details line.
            var request = VividImageRequest(url: url)
            request.trimsTransparentEdges = true
            let image = try? await VividImagePipeline.shared.image(for: request)
            guard !Task.isCancelled else { return }
            logo = image
        }
    }

    private var isEpisode: Bool { slide.item.type.lowercased() == "episode" }

    /// The item's type in the app's language. Types without a label of
    /// their own show as the server names them.
    private var typeLabel: String {
        let type = slide.item.type
        if type.lowercased() == "movie" { return String(localized: "Movie") }
        if type.lowercased() == "episode" { return String(localized: "Episode") }
        if type.lowercased() == "series" {
            return String(localized: "series.typeLabel", defaultValue: "Series", comment: "Media type label for a single series")
        }
        return type.capitalized
    }

    private func reportReady() {
        guard !reportedReady else { return }
        reportedReady = true
        onReady()
    }
}

#endif
