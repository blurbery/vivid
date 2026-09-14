#if os(tvOS)
import SwiftUI
import Observation
import UIKit

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

    @State private var homeCards = TVHomeCardPreferences.shared
    @State private var spotlightEnterRequest = 0
    @State private var rowFocusOwnership = TVHomeFocusOwnership()
    @State private var rowFocusMemory = TVHomeRowFocusMemory()
    @State private var rowArtworkWindow = TVHomeRowArtworkWindow()
    @State private var scrollDiagnostics = TVHomeScrollDiagnostics()
    @State private var firstRowFocusRequest = 0
    @State private var spotlightOpenedDetail = false
    @State private var appliedFocusRequest = 0

    private static let spotlightAnchor = "vivid.home.discovery.spotlight"

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
                            onPositionChange: { rowFocusMemory.spotlightPosition = $0 },
                            onFocusChange: { focused in
                                rowFocusMemory.spotlightFocused = focused
                                if focused {
                                    rowFocusOwnership.rowID = nil
                                    rowArtworkWindow.focus(index: 0)
                                }
                            },
                            onEnterFirstRow: enterFirstRow,
                            onSelect: { slide in
                                spotlightOpenedDetail = true
                                rowFocusOwnership.rowID = nil
                                onItemTap(slide.item.contentId, slide.item)
                            }
                        )
                        .id(Self.spotlightAnchor)
                    }

                    VStack(alignment: .leading, spacing: TVHomeRowGeometry.rowSpacing) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            SectionRow(
                                section: section,
                                onItemTap: { id, item in
                                    spotlightOpenedDetail = false
                                    onItemTap(id, item)
                                },
                                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                                onSetWatched: onSetWatched,
                                showsHeadingIcon: false,
                                prefersDefaultFocusOnFirstItem: slides.isEmpty && index == 0,
                                defaultFocusPriority: .userInitiated,
                                focusRequest: index == 0 ? firstRowFocusRequest : 0,
                                defaultFocusItemId: rowFocusMemory.items[section.id],
                                focusRequestItemId: rowFocusMemory.items[section.id],
                                detailReturnFocusRequest: spotlightOpenedDetail ? 0 : detailReturnFocusRequest,
                                onMoveUp: index == 0 && slides.isEmpty ? { onTopMenuFocusRequest?() } : nil,
                                onItemFocus: { item in
                                    scrollDiagnostics.focus(row: index, card: section.items.firstIndex { $0.contentId == item.contentId } ?? -1)
                                    rowArtworkWindow.focus(index: index)
                                    rowFocusMemory.items[section.id] = item.contentId
                                    if rowFocusOwnership.rowID != section.id { rowFocusOwnership.rowID = section.id }
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
                                    presentation: homeCards.presentation
                                ), alignment: .top)
                            .id(section.id)
                            .modifier(TVHomeRowArtworkVisibility(index: index, window: rowArtworkWindow))
                            .modifier(TVHomeDiagnosticRow(diagnostics: scrollDiagnostics, index: index))
                        }
                    }
                    // Controlled eager-row comparison: keep the reserved geometry
                    // and artwork gates while mounting the real row containers.
                }
                .environment(\.tvHomeStableRows, true)
                .padding(.top, 152)
                .padding(.bottom, 80)
            }
            .modifier(TVHomeDiagnosticFeed(diagnostics: scrollDiagnostics))
            .onChange(of: focusRequest, initial: true) { _, request in
                guard request > appliedFocusRequest, !isTopMenuFocused else { return }
                appliedFocusRequest = request
                if slides.isEmpty { enterFirstRow() }
                else { enterSpotlight() }
            }
            .onChange(of: detailReturnFocusRequest) { _, _ in
                if spotlightOpenedDetail { enterSpotlight() }
            }
            .onChange(of: slides.isEmpty) { _, empty in
                if empty && rowFocusMemory.spotlightFocused { enterFirstRow() }
            }
            .onChange(of: isTopMenuFocused) { _, focused in
                if focused { rowFocusOwnership.rowID = nil }
            }
        }
        .modifier(TVHomeArtworkWarmupModifier(sections: sections,
            presentation: homeCards.presentation, focus: rowFocusOwnership, memory: rowFocusMemory))
        .background {
            TVHomeTopMenuBoundary(focus: rowFocusOwnership, hasSpotlight: !slides.isEmpty)
        }
        .environment(\.homeCardPresentation, homeCards.presentation)
        .environment(\.tvHomeFocusOwnership, rowFocusOwnership)
        .environment(\.tvHomeScrollDiagnostics, scrollDiagnostics.enabled ? scrollDiagnostics : nil)
        .onDisappear { rowArtworkWindow.stopPendingPreparation() }
        .ignoresSafeArea()
    }

    private func enterSpotlight() {
        guard !slides.isEmpty else { onTopMenuFocusRequest?(); return }
        // The spotlight is mounted eagerly. Let the focus engine perform its
        // own scroll instead of racing a separate ScrollViewReader animation.
        rowFocusOwnership.rowID = nil
        spotlightEnterRequest += 1
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
            let start = index == current ? max(0, focusedIndex - 1) : 0
            let end = min(section.items.count, start + visibleCount)
            let rowRequests: [VividImageRequest] = section.items[start..<end].compactMap { item in
                let value = wide ? (item.backdropUrl.flatMap { $0.isEmpty ? nil : $0 } ?? item.posterUrl) : item.posterUrl
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
    let onSelect: (TVHomeSpotlightSlide) -> Void

    @State private var visualPosition = 0
    @State private var scrollPosition = ScrollPosition(id: 0, anchor: .center)
    @State private var scrollGeometry = TVSpotlightScrollGeometry()
    @State private var lowerPosition: Int
    @State private var upperPosition: Int
    @State private var pendingPosition: Int?
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
        onSelect: @escaping (TVHomeSpotlightSlide) -> Void
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
        initialCardPresented && homeIsOpen && isOnScreen && slides.count > 1 && !scrollIsMoving
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

    private func updatePositionWindow(around position: Int) {
        guard slides.count > 1 else { return }
        let margin = slides.count
        let span = slides.count * 3
        // Keep a runway in both directions without changing card identities.
        if position - lowerPosition < margin || upperPosition - position <= margin {
            diagnostics?.event("spotlight.recycle", values: [Double(position), Double(lowerPosition)])
            if focus.wrappedValue == nil {
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
                let cardWidth = max(1, geometry.size.width - 120)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(renderedPositions, id: \.self) { position in
                            let slide = slide(at: position)
                            Button { onSelect(slide) } label: {
                                Group {
                                    if abs(position - visualPosition) <= 3 {
                                        TVHomeSpotlightArtwork(slide: slide, onReady: {
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
                                .frame(width: cardWidth, height: 580)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
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
                .contentMargins(.horizontal, 60, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .defaultScrollAnchor(.center, for: .initialOffset)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) {
                    $0.contentOffset.x + $0.contentInsets.leading
                } action: { _, offset in
                    scrollGeometry.offset = offset
                    scrollGeometry.cardStride = cardWidth + 22
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
                        var transaction = Transaction(animation: reduceMotion || residual < scrollGeometry.cardStride - 22
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
            .frame(height: 580)

            HStack(spacing: 10) {
                ForEach(slides.indices, id: \.self) { dot in
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canRotate || reduceMotion || dot != index)) { timeline in
                                let elapsed = elapsedCycle(at: timeline.date)
                                let progress = reduceMotion || dot != index ? 1 : min(elapsed / 6, 1)
                                Rectangle()
                                    .fill(.white)
                                    .frame(width: 36 * progress)
                                    .transaction { $0.animation = nil }
                            }
                            .opacity(dot == index ? 1 : 0)
                        }
                        .frame(width: dot == index ? 36 : 8, height: 8)
                        .clipShape(Capsule())
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: index)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .accessibilityHidden(true)
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
            if open { completeInitialPresentationIfReady() }
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
        .task(id: rotationKey) {
            guard canRotate else { return }
            let remaining = max(0, 6 - elapsedCycle(at: Date()))
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled else { return }
            pendingPosition = visualPosition + 1
            revealPendingSlide()
        }
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

/// Scroll measurements do not invalidate artwork or the Home view on each frame.
private final class TVSpotlightScrollGeometry {
    var offset: CGFloat = 0
    var cardStride: CGFloat = 1
}

private struct TVHomeSpotlightArtwork: View {
    let slide: TVHomeSpotlightSlide
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
                                             onReady: { artworkReady = true })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                LinearGradient(
                    stops: Self.fadeStops,
                    startPoint: .top, endPoint: .bottom
                )
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
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
                VStack(alignment: .center, spacing: 18) {
                    if let logo {
                        Image(uiImage: logo)
                            .resizable().interpolation(.high).scaledToFit()
                            .frame(width: 480, height: 160, alignment: .bottom)
                    } else {
                        Text(slide.content.title)
                            .font(.system(size: 62, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 760, alignment: .center)
                    }
                    Text(([slide.item.type.capitalized] + spotlightMetaParts
                          + [slide.content.contentRatingBadge].compactMap { $0 }).joined(separator: "  ·  "))
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: logo == nil ? 760 : 480, alignment: .center)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 48)
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .allowsHitTesting(false)
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
            let image = try? await VividImagePipeline.shared.image(for: VividImageRequest(url: url))
            guard !Task.isCancelled else { return }
            logo = image
        }
    }

    private var spotlightMetaParts: [String] {
        var parts = slide.content.metaParts
        if slide.item.type.lowercased() == "movie",
           let runtime = slide.content.runtimeText,
           parts.indices.contains(slide.content.runtimeMetaIndex),
           parts[slide.content.runtimeMetaIndex] == runtime {
            parts.remove(at: slide.content.runtimeMetaIndex)
        }
        return parts
    }

    private func reportReady() {
        guard !reportedReady else { return }
        reportedReady = true
        onReady()
    }
}

#endif
