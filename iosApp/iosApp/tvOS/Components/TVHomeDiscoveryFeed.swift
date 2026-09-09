#if os(tvOS)
import SwiftUI

struct TVHomeDiscoveryFeed: View {
    let sections: [ResolvedSection]
    let slides: [TVHomeSpotlightSlide]
    let focusRequest: Int
    let detailReturnFocusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: (() -> Void)?
    let onItemTap: (String, SectionItem) -> Void
    let onRemoveFromContinueWatching: (SectionItem) -> Void
    let onSetWatched: (SectionItem, Bool) async -> Bool

    @State private var homeCards = TVHomeCardPreferences.shared
    @FocusState private var spotlightFocused: Bool
    @State private var rowOwner: String?
    @State private var rowFocusItems: [String: String] = [:]
    @State private var firstRowFocusRequest = 0
    @State private var spotlightOpenedDetail = false
    @State private var appliedFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let spotlightAnchor = "vivid.home.discovery.spotlight"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if !slides.isEmpty {
                        TVHomeSpotlightCarousel(
                            slides: slides,
                            focus: $spotlightFocused,
                            isTopMenuFocused: isTopMenuFocused,
                            onSelect: { slide in
                                spotlightOpenedDetail = true
                                rowOwner = nil
                                onItemTap(slide.item.contentId, slide.item)
                            },
                            onMoveUp: { onTopMenuFocusRequest?() }
                        )
                        .id(Self.spotlightAnchor)
                    }

                    LazyVStack(alignment: .leading, spacing: 30) {
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
                                prefersDefaultFocusOnFirstItem: index == 0,
                                defaultFocusPriority: .userInitiated,
                                focusRequest: index == 0 ? firstRowFocusRequest : 0,
                                defaultFocusItemId: rowFocusItems[section.id],
                                focusRequestItemId: rowFocusItems[section.id],
                                detailReturnFocusRequest: spotlightOpenedDetail ? 0 : detailReturnFocusRequest,
                                onMoveUp: index == 0 ? { enterSpotlight(using: proxy) } : nil,
                                onItemFocus: { item in
                                    rowOwner = section.id
                                    rowFocusItems[section.id] = item.contentId
                                },
                                cardWidth: VividTheme.Skyline.densePosterCardWidth,
                                focusRestorationOwner: Binding(
                                    get: { rowOwner == section.id },
                                    set: { if $0 { rowOwner = section.id } }
                                )
                            )
                            .id(section.id)
                        }
                    }
                }
                .padding(.top, 152)
                .padding(.bottom, 80)
            }
            .background(Color.black.ignoresSafeArea())
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
                if focused { rowOwner = nil }
            }
        }
        .environment(\.homeCardPresentation, homeCards.presentation)
        .ignoresSafeArea()
    }

    private func enterSpotlight(using proxy: ScrollViewProxy) {
        guard !slides.isEmpty else { onTopMenuFocusRequest?(); return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.spotlightAnchor, anchor: .center)
        }
        spotlightFocused = true
    }

    private func enterFirstRow(using proxy: ScrollViewProxy) {
        guard let first = sections.first else { return }
        spotlightFocused = false
        rowOwner = first.id
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            proxy.scrollTo(first.id, anchor: .center)
        }
        firstRowFocusRequest += 1
    }
}

private struct TVHomeSpotlightCarousel: View {
    let slides: [TVHomeSpotlightSlide]
    let focus: FocusState<Bool>.Binding
    let isTopMenuFocused: Bool
    let onSelect: (TVHomeSpotlightSlide) -> Void
    let onMoveUp: () -> Void

    @State private var selectedID: String?
    @State private var isVisible = true
    @State private var manualStep = 0
    @State private var ambientTint = Color.black
    @State private var visibleID: String?
    @State private var retiringID: String?
    @State private var cycleStarted = Date()
    @State private var tints: [String: Color] = [:]
    @State private var readyIDs = Set<String>()
    @State private var retirementTask: Task<Void, Never>?
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var requested: TVHomeSpotlightSlide? {
        slides.first { $0.id == selectedID } ?? slides.first
    }
    private var index: Int { slides.firstIndex { $0.id == visibleID } ?? 0 }
    private var current: TVHomeSpotlightSlide? { slides.first { $0.id == visibleID } ?? requested }
    private var layers: [TVHomeSpotlightSlide] {
        var seen = Set<String>()
        let upcoming = visibleID != nil && requested?.id == visibleID && slides.count > 1
            && isVisible && scenePhase == .active && router.path.isEmpty
            ? slides[(index + 1) % slides.count].id : nil
        return [retiringID, visibleID, requested?.id, upcoming].compactMap { $0 }
            .filter { seen.insert($0).inserted }
            .compactMap { id in slides.first { $0.id == id } }
    }
    private var canRotate: Bool {
        slides.count > 1 && isVisible && scenePhase == .active
            && router.path.isEmpty && !voiceOverEnabled
            && visibleID == requested?.id
    }
    private var rotationKey: String {
        "\(slides.map(\.id).joined(separator: "|"))#\(index)#\(manualStep)#\(canRotate)"
    }

    var body: some View {
        VStack(spacing: 22) {
            Button {
                if let current { onSelect(current) }
            } label: {
                ZStack {
                    Color(white: 0.055)
                    ForEach(layers) { slide in
                        TVHomeSpotlightArtwork(slide: slide, neighbours: neighbours(for: slide), onTint: { tint in
                            tints[slide.id] = tint
                            if slide.id == visibleID { ambientTint = tint }
                        }, onReady: {
                            readyIDs.insert(slide.id)
                            reveal(slide)
                        })
                        .opacity(slide.id == visibleID || slide.id == retiringID ? 1 : 0)
                        .accessibilityHidden(slide.id != visibleID)
                    }
                }
                .frame(height: 580)
                .clipped()
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(focus.wrappedValue ? .white.opacity(0.9) : .clear)
                        .frame(width: 120, height: 2)
                        .padding(.bottom, 8)
                }
            }
            .buttonStyle(TVHomeSpotlightButtonStyle())
            .focusEffectDisabled()
            .background {
                TVSpotlightEdgeFade(tint: ambientTint)
                    .padding(-TVSpotlightEdgeFade.canvasInset)
                .allowsHitTesting(false)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: ambientTint)
            }
            .focused(focus)
            .accessibilityLabel(current?.content.title ?? "Discovery spotlight")
            .accessibilityValue("Slide \(index + 1) of \(slides.count)")
            .accessibilityHint("Press to open. Swipe left or right to change the spotlight.")
            .onMoveCommand { direction in
                switch direction {
                case .left: advance(-1)
                case .right: advance(1)
                case .up: onMoveUp()
                default: break
                }
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
        .onChange(of: requested?.id) { _, id in
            if let id, readyIDs.contains(id), let slide = requested { reveal(slide) }
        }
        .onChange(of: layers.map(\.id)) { _, ids in
            readyIDs.formIntersection(ids)
            tints = tints.filter { ids.contains($0.key) }
        }
        .onScrollVisibilityChange(threshold: 0.5) { isVisible = $0 }
        .onAppear {
            isVisible = true
            if let visibleID { selectedID = visibleID }
            cycleStarted = Date()
            manualStep += 1
        }
        .onDisappear { isVisible = false; retirementTask?.cancel() }
        .task(id: rotationKey) {
            guard canRotate else { return }
            cycleStarted = Date()
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled else { return }
            advance(1)
        }
    }

    private func neighbours(for slide: TVHomeSpotlightSlide) -> [TVHomeSpotlightSlide] {
        guard slides.count > 1, let position = slides.firstIndex(where: { $0.id == slide.id }) else { return [] }
        return [slides[(position + slides.count - 1) % slides.count], slides[(position + 1) % slides.count]]
    }

    private func advance(_ step: Int) {
        guard !slides.isEmpty else { return }
        let requestedIndex = slides.firstIndex { $0.id == requested?.id } ?? index
        selectedID = slides[(requestedIndex + step + slides.count) % slides.count].id
        manualStep &+= 1
    }

    private func reveal(_ slide: TVHomeSpotlightSlide) {
        guard requested?.id == slide.id, visibleID != slide.id else { return }
        retirementTask?.cancel()
        retiringID = visibleID
        cycleStarted = Date()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) {
            visibleID = slide.id
            ambientTint = tints[slide.id] ?? .black
        }
        retirementTask = Task {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled else { return }
            retiringID = nil
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

private struct TVHomeSpotlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct TVHomeSpotlightArtwork: View {
    let slide: TVHomeSpotlightSlide
    let neighbours: [TVHomeSpotlightSlide]
    let onTint: (Color) -> Void
    let onReady: () -> Void
    @State private var artworkReady = false
    @State private var logoReady = false
    @State private var reportedReady = false
    @State private var model = TVFocusMarqueeModel()
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
                width: min(geometry.size.width, geometry.size.height * 16 / 9 * 1.2),
                height: geometry.size.height
            )
            ZStack(alignment: .bottom) {
                model.tintColor
                ForEach(neighbours.indices, id: \.self) { side in
                    TVSpotlightNeighbourArtwork(slide: neighbours[side], size: artworkSize)
                        .id("\(side)-\(neighbours[side].id)")
                        .blur(radius: 22)
                        .opacity(0.65)
                        .offset(x: (side == 0 ? -1 : 1) * artworkSize.width * 0.82)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if let url = model.backdropURL {
                    TVSpotlightBackdropImage(url: url, size: artworkSize, onReady: { artworkReady = true })
                    .frame(width: artworkSize.width, height: artworkSize.height)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.2),
                                .init(color: .black, location: 0.8),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
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
                .padding(48)
                .frame(maxWidth: .infinity, alignment: .center)
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

private struct TVSpotlightNeighbourArtwork: View {
    let slide: TVHomeSpotlightSlide
    let size: CGSize
    @State private var model = TVFocusMarqueeModel()

    var body: some View {
        ZStack {
            model.tintColor
            if let url = model.backdropURL {
                TVSpotlightBackdropImage(url: url, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { model.resume(); model.seed(slide.content) }
        .onDisappear { model.suspend() }
    }
}

#endif
