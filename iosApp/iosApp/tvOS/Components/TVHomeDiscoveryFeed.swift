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
    @FocusState private var spotlightFocusedPosition: Int?
    @State private var rowFocusOwnership = TVHomeFocusOwnership()
    @State private var rowFocusMemory = TVHomeRowFocusMemory()
    @State private var scrollDiagnostics = TVHomeScrollDiagnostics()
    @State private var firstRowFocusRequest = 0
    @State private var spotlightOpenedDetail = false
    @State private var appliedFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spotlightFocused: Bool { spotlightFocusedPosition != nil }
    private static let spotlightAnchor = "vivid.home.discovery.spotlight"

    var body: some View {
        let _ = scrollDiagnostics.event("feed.body")
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if !slides.isEmpty {
                        TVHomeSpotlightCarousel(
                            slides: slides,
                            focus: $spotlightFocusedPosition,
                            initialPosition: rowFocusMemory.spotlightPosition,
                            onPositionChange: { rowFocusMemory.spotlightPosition = $0 },
                            isTopMenuFocused: isTopMenuFocused,
                            onSelect: { slide in
                                spotlightOpenedDetail = true
                                rowFocusOwnership.rowID = nil
                                onItemTap(slide.item.contentId, slide.item)
                            },
                            onMoveUp: { onTopMenuFocusRequest?() }
                        )
                        .id(Self.spotlightAnchor)
                    }

                    LazyVStack(alignment: .leading, spacing: TVHomeRowGeometry.rowSpacing) {
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
                                    rowFocusMemory.items[section.id] = item.contentId
                                    if rowFocusOwnership.rowID != section.id { rowFocusOwnership.rowID = section.id }
                                },
                                cardWidth: VividTheme.Skyline.densePosterCardWidth,
                                focusRestorationOwner: Binding(
                                    get: { rowFocusOwnership.rowID == section.id },
                                    set: { if $0 { rowFocusOwnership.rowID = section.id } }
                                )
                            )
                            .id(section.id)
                            .modifier(TVHomeDiagnosticRow(diagnostics: scrollDiagnostics, index: index))
                        }
                    }
                    // The row cells remain lazy, but the scroll range must not
                    // change as the stack revises its off-screen size estimates.
                    .frame(height: rowsHeight, alignment: .topLeading)
                }
                .environment(\.tvHomeStableRows, true)
                .padding(.top, 152)
                .padding(.bottom, 80)
            }
            .background(Color.black.ignoresSafeArea())
            .modifier(TVHomeDiagnosticFeed(diagnostics: scrollDiagnostics))
            .onChange(of: focusRequest, initial: true) { _, request in
                guard request > appliedFocusRequest, !isTopMenuFocused else { return }
                appliedFocusRequest = request
                if slides.isEmpty { enterFirstRow(using: proxy) }
                else { enterSpotlight(using: proxy) }
            }
            .onChange(of: detailReturnFocusRequest) { _, _ in
                if spotlightOpenedDetail { enterSpotlight(using: proxy) }
            }
            .onChange(of: slides.isEmpty) { _, empty in
                if empty && spotlightFocused { enterFirstRow(using: proxy) }
            }
            .onChange(of: isTopMenuFocused) { _, focused in
                if focused { rowFocusOwnership.rowID = nil }
            }
            .onChange(of: spotlightFocused) { _, focused in
                if focused { rowFocusOwnership.rowID = nil }
            }
        }
        .modifier(TVHomeArtworkWarmupModifier(sections: sections,
            presentation: homeCards.presentation, focus: rowFocusOwnership))
        .environment(\.homeCardPresentation, homeCards.presentation)
        .ignoresSafeArea()
    }

    private var rowsHeight: CGFloat {
        sections.reduce(CGFloat.zero) { height, section in
            height + TVHomeRowGeometry.rowHeight(
                layout: section.tvHomeUsesLandscapeArtwork ? .thumbnail : .poster,
                posterWidth: VividTheme.Skyline.densePosterCardWidth,
                presentation: homeCards.presentation)
        } + CGFloat(max(0, sections.count - 1)) * TVHomeRowGeometry.rowSpacing
    }

    private func enterSpotlight(using proxy: ScrollViewProxy) {
        guard !slides.isEmpty else { onTopMenuFocusRequest?(); return }
        // The spotlight is mounted eagerly. Let the focus engine perform its
        // own scroll instead of racing a separate ScrollViewReader animation.
        rowFocusOwnership.rowID = nil
        spotlightFocusedPosition = rowFocusMemory.spotlightPosition
    }

    private func enterFirstRow(using proxy: ScrollViewProxy) {
        guard let first = sections.first else { return }
        spotlightFocusedPosition = nil
        rowFocusOwnership.rowID = first.id
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            proxy.scrollTo(first.id, anchor: .center)
        }
        firstRowFocusRequest += 1
    }
}

// Temporary local diagnostics. Inert unless explicitly enabled at launch.
// Records geometry and timing only, never titles, URLs or account information.
private struct TVHomeDiagnosticRow: ViewModifier {
    let diagnostics: TVHomeScrollDiagnostics
    let index: Int

    @ViewBuilder func body(content: Content) -> some View {
        if diagnostics.enabled {
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

private struct TVHomeDiagnosticGeometry: Equatable {
    let offset: CGPoint
    let content: CGSize
    let viewport: CGSize
    var values: [Double] {
        [offset.x, offset.y, content.width, content.height, viewport.width, viewport.height]
    }
}

@MainActor
private final class TVHomeScrollDiagnostics: NSObject {
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
    }

    private func start() {
        guard started == nil else { return }
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16000)
        started = CACurrentMediaTime()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: stop)
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
        event("focus", index: row, values: [Double(card)])
    }

    func event(_ event: String, index: Int? = nil, values: [Double] = []) {
        guard let started else { return }
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
        self.started = nil
        displayLink?.invalidate()
        displayLink = nil
        deadline?.cancel()
        deadline = nil
        write(Capture(status: "finished", duration: duration, samples: samples))
        samples.removeAll(keepingCapacity: true)
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
private final class TVHomeFocusOwnership {
    var rowID: String?
}

private struct TVHomeArtworkWarmupModifier: ViewModifier {
    let sections: [ResolvedSection]
    let presentation: CardPresentationPreference
    let focus: TVHomeFocusOwnership
    @Environment(\.scenePhase) private var scenePhase
    @State private var artworkWarmup = TVHomeArtworkWarmup()

    func body(content: Content) -> some View {
        content
            .task(id: homeArtworkRequests) { artworkWarmup.update(homeArtworkRequests) }
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
        let scale = presentation.posterSize.scale * PosterImageCache.displayScale
        var requests: [VividImageRequest] = []
        var seen = Set<VividImageRequest>()
        for index in indices {
            let section = sections[index]
            // Match SectionRow's tvOS artwork layout, including mixed resume rows.
            let wide = section.tvHomeUsesLandscapeArtwork
            let width = wide ? VividTheme.thumbnailCardWidth : VividTheme.Skyline.densePosterCardWidth
            let ratio = wide ? VividTheme.thumbnailCardHeight / VividTheme.thumbnailCardWidth
                : VividTheme.posterCardHeight / VividTheme.posterCardWidth
            let size = CGSize(width: width * scale, height: width * ratio * scale)
            for item in section.items.prefix(index == current ? 20 : 8) {
                let value = wide ? (item.backdropUrl.flatMap { $0.isEmpty ? nil : $0 } ?? item.posterUrl) : item.posterUrl
                guard let value, let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                let request = PosterImageCache.displayRequest(url: url, pixelSize: size, priority: .low)
                if seen.insert(request).inserted { requests.append(request) }
            }
        }
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
}

private struct TVHomeSpotlightCarousel: View {
    let slides: [TVHomeSpotlightSlide]
    let focus: FocusState<Int?>.Binding
    let initialPosition: Int
    let onPositionChange: (Int) -> Void
    let isTopMenuFocused: Bool
    let onSelect: (TVHomeSpotlightSlide) -> Void
    let onMoveUp: () -> Void

    @State private var visualPosition = 0
    @State private var scrollPosition: Int? = 0
    @State private var positions = -2...2
    @State private var pendingPosition: Int?
    @State private var isVisible = true
    @State private var scrollIsMoving = false
    @State private var manualStep = 0
    @State private var ambientTint = Color.black
    @State private var cycleStarted = Date()
    @State private var tints: [String: Color] = [:]
    @State private var readyIDs = Set<String>()
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var index: Int {
        guard !slides.isEmpty else { return 0 }
        return ((visualPosition % slides.count) + slides.count) % slides.count
    }
    private func slide(at position: Int) -> TVHomeSpotlightSlide {
        slides[((position % slides.count) + slides.count) % slides.count]
    }
    private var canRotate: Bool {
        !slides.isEmpty && slides.count > 1 && isVisible && !scrollIsMoving && scenePhase == .active
            && router.path.isEmpty && !voiceOverEnabled
            && readyIDs.contains(slide(at: visualPosition).id)
    }
    private var rotationKey: String {
        "\(slides.map(\.id).joined(separator: "|"))#\(visualPosition)#\(manualStep)#\(canRotate)"
    }
    private var maintenanceKey: String { "\(visualPosition)#\(scrollIsMoving)" }
    private var renderedPositions: [Int] {
        guard !slides.isEmpty else { return [] }
        return slides.count == 1 ? [visualPosition] : Array(positions)
    }

    var body: some View {
        VStack(spacing: 22) {
            GeometryReader { geometry in
                let cardWidth = max(1, geometry.size.width - 120)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 22) {
                        ForEach(renderedPositions, id: \.self) { position in
                            let slide = slide(at: position)
                            Button { onSelect(slide) } label: {
                                TVHomeSpotlightArtwork(slide: slide, onTint: { tint in
                                    tints[slide.id] = tint
                                    if position == visualPosition { ambientTint = tint }
                                }, onReady: {
                                    readyIDs.insert(slide.id)
                                    revealPendingSlide()
                                })
                                .id(slide.id)
                                .frame(width: cardWidth, height: 580)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                            }
                            .buttonStyle(.card)
                            .focused(focus, equals: position)
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
                .scrollPosition(id: $scrollPosition, anchor: .center)
                .scrollClipDisabled()
                .onScrollPhaseChange { _, phase in scrollIsMoving = phase != .idle }
                .focusSection()
                .onMoveCommand { direction in
                    if direction == .up { onMoveUp() }
                }
            }
            .frame(height: 580)
            .background {
                TVSpotlightEdgeFade(tint: ambientTint)
                    .opacity(0.75)
                    .padding(-TVSpotlightEdgeFade.canvasInset)
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: ambientTint)
            }

            HStack(spacing: 10) {
                ForEach(slides.indices, id: \.self) { dot in
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !canRotate || reduceMotion || dot != index)) { timeline in
                                let elapsed = max(0, timeline.date.timeIntervalSince(cycleStarted))
                                let progress = reduceMotion || dot != index ? 1 : min(elapsed / 6, 1)
                                Rectangle()
                                    .fill(.white)
                                    .frame(width: 36 * progress)
                                    .transaction { $0.animation = nil }
                            }
                            .id(canRotate)
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
        .onChange(of: focus.wrappedValue) { _, position in
            guard let position else { return }
            pendingPosition = nil
            selectPosition(position)
            manualStep &+= 1
        }
        .onChange(of: scrollPosition) { _, position in
            guard focus.wrappedValue == nil, let position else { return }
            selectPosition(position)
        }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .onAppear {
            isVisible = true
            if initialPosition != visualPosition {
                selectPosition(initialPosition)
                scrollPosition = initialPosition
            }
            cycleStarted = Date()
            manualStep &+= 1
        }
        .onDisappear {
            isVisible = false
            pendingPosition = nil
        }
        .onChange(of: slides.map(\.id)) { _, ids in
            pendingPosition = nil
            readyIDs.formIntersection(ids)
            tints = tints.filter { ids.contains($0.key) }
        }
        .task(id: maintenanceKey) {
            // Retain the focused card's identity while trimming old loop copies
            // after movement settles. ScrollPosition preserves its alignment.
            guard !scrollIsMoving else { return }
            let position = visualPosition
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard !Task.isCancelled, visualPosition == position else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { positions = (position - 2)...(position + 2) }
            let retainedIDs = Set(renderedPositions.map { slide(at: $0).id })
            readyIDs.formIntersection(retainedIDs)
            tints = tints.filter { retainedIDs.contains($0.key) }
        }
        .task(id: rotationKey) {
            guard canRotate else { return }
            cycleStarted = Date()
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled else { return }
            pendingPosition = visualPosition + 1
            revealPendingSlide()
        }
    }

    private func selectPosition(_ position: Int) {
        guard !slides.isEmpty else { return }
        positions = min(positions.lowerBound, position - 2)...max(positions.upperBound, position + 2)
        visualPosition = position
        onPositionChange(position)
        cycleStarted = Date()
        let slide = slide(at: position)
        ambientTint = tints[slide.id] ?? .black
    }

    private func revealPendingSlide() {
        guard let position = pendingPosition, !slides.isEmpty,
              readyIDs.contains(slide(at: position).id) else { return }
        pendingPosition = nil
        if focus.wrappedValue != nil {
            // The focus engine scrolls the newly focused native card into view.
            focus.wrappedValue = position
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
                scrollPosition = position
            }
        }
    }
}

private struct TVSpotlightEdgeFade: View {
    let tint: Color
    static let canvasInset: CGFloat = 200

    // Dark artwork still gets a subdued halo; preserve its sampled hue.
    private var glowTint: Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(tint).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return tint }
        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(max(0.28, brightness)))
    }

    var body: some View {
        Canvas { context, size in
            let card = CGRect(origin: .zero, size: size).insetBy(dx: Self.canvasInset, dy: Self.canvasInset)
            let steps = 64
            let color = glowTint
            var previousOpacity = 0.0
            for step in stride(from: steps, through: 0, by: -1) {
                let amount = CGFloat(step) / CGFloat(steps)
                let targetOpacity = 0.34 * pow(1 - Double(amount), 2)
                let opacity = (targetOpacity - previousOpacity) / (1 - previousOpacity)
                context.fill(outline(card: card, amount: amount), with: .color(color.opacity(opacity)))
                previousOpacity = targetOpacity
            }
        }
        .blur(radius: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func outline(card: CGRect, amount t: CGFloat) -> Path {
        let left = card.minX - 105 * t
        let right = card.maxX + 130 * t
        let top = card.minY - 80 * t
        let bottom = card.maxY + 135 * t
        let radius = 24 + 24 * t
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addCurve(
            to: CGPoint(x: right - radius, y: top),
            control1: CGPoint(x: card.minX + card.width * 0.32, y: top - 30 * t),
            control2: CGPoint(x: card.minX + card.width * 0.72, y: top + 15 * t)
        )
        path.addQuadCurve(to: CGPoint(x: right, y: top + radius), control: CGPoint(x: right, y: top))
        path.addCurve(
            to: CGPoint(x: right, y: bottom - radius),
            control1: CGPoint(x: right + 15 * t, y: card.minY + card.height * 0.3),
            control2: CGPoint(x: right - 20 * t, y: card.minY + card.height * 0.7)
        )
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addCurve(
            to: CGPoint(x: left + radius, y: bottom),
            control1: CGPoint(x: card.minX + card.width * 0.72, y: bottom + 45 * t),
            control2: CGPoint(x: card.minX + card.width * 0.28, y: bottom - 20 * t)
        )
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - radius), control: CGPoint(x: left, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: top + radius),
            control1: CGPoint(x: left + 25 * t, y: card.minY + card.height * 0.65),
            control2: CGPoint(x: left - 12 * t, y: card.minY + card.height * 0.25)
        )
        path.addQuadCurve(to: CGPoint(x: left + radius, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}

private struct TVHomeSpotlightArtwork: View {
    let slide: TVHomeSpotlightSlide
    let onTint: (Color) -> Void
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
        .onAppear { model.resume(); model.seed(slide.content) }
        .onDisappear { model.suspend() }
        .onChange(of: model.tintColor, initial: true) { _, tint in onTint(tint) }
        .onChange(of: artworkReady && logoReady) { _, ready in
            if ready { reportReady() }
        }
        .task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled else { return }
            reportReady()
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
        onTint(model.tintColor)
        onReady()
    }
}

#endif
