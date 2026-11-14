#if os(iOS)
import SwiftUI
import UIKit

/// Where the Library row is scrolled to. The page keeps it so the row comes
/// back to the same place when the list under it changes. A plain object:
/// the row writes it on every scroll frame and that never redraws anything.
final class PhoneLibraryRowScrollMemory {
    /// The scroll view's content offset; it rests at minus the leading margin.
    var offset: CGFloat = 0
    var rowWidth: CGFloat = 0
    /// The library at the row's leading edge while nothing is held.
    var leadingLibraryId: Int?
}

/// The Library tab's row of libraries on iPhone and iPad: landscape cards
/// the size of Home's Continue Watching cards, each with its library's name
/// below, as the server gives it.
///
/// Holding a card picks it up. While it is held the row zooms out so more
/// libraries fit, the card follows the finger, and holding it near either
/// end scrolls the row. Letting go drops it and the row zooms back in. Each
/// move saves as it happens.
struct PhoneLibraryCardRow: View {
    /// In the order shown.
    let libraries: [Library]
    /// True while a card is held, so the page can hold still under it.
    @Binding var isHolding: Bool
    let scrollMemory: PhoneLibraryRowScrollMemory
    let onOpen: (Library) -> Void
    let onMove: (Library, Int) -> Void

    /// The held library, by id.
    @State private var movingId: Int?
    /// The finger, in the row's own space.
    @State private var finger: CGPoint = .zero
    /// Where the hold began: the finger, and once the zoomed-out row has
    /// settled under it, the held card's place and the row's scroll offset.
    /// Moves are counted from here, so the card only moves as far as the
    /// finger (and the row under it) has.
    @State private var pickupX: CGFloat = 0
    @State private var origin: (index: Int, offset: CGFloat)?
    /// Counts up while a card is held. The work each tick does runs in the
    /// view, where the library order is current; a long-running task would
    /// keep the order it started with.
    @State private var holdTick = 0
    @State private var lastEdgeScroll = ContinuousClock.now
    /// The card last dropped, and a count that asks the row to settle on it.
    @State private var droppedId: Int?
    @State private var settleRequest = 0
    @State private var dropAnchor: UnitPoint = .center
    /// When a hold last ended, so the lift of that finger isn't read as a tap.
    @State private var holdEnded = Date.distantPast
    @State private var homeCards = TVHomeCardPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "vivid.libraryRow"
    /// How much of its size a card keeps while one is held.
    private static let heldScale: CGFloat = 0.5
    /// How close to an end the finger scrolls the row, and how often it
    /// brings the next library in.
    private static let edgeZone: CGFloat = 56
    private static let edgePause: Duration = .milliseconds(320)

    private var isReordering: Bool { movingId != nil }

    private var fullWidth: CGFloat {
        HomeFeedMetrics.stillWidth * homeCards.presentation.posterSize.scale
    }

    private var cardWidth: CGFloat { isReordering ? fullWidth * Self.heldScale : fullWidth }

    private var step: CGFloat { cardWidth + HomeFeedMetrics.cardSpacing }

    /// A full-size card with its name, which the row keeps as its height
    /// while it is zoomed out, so nothing below it moves.
    private var fullCardHeight: CGFloat { fullWidth * 9 / 16 + 8 + Self.nameHeight }

    private static let nameHeight = UIFont.systemFont(ofSize: 13, weight: .semibold).lineHeight.rounded(.up)

    var body: some View {
        let width = cardWidth
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: HomeFeedMetrics.cardSpacing) {
                    // Keyed by library so a held card keeps its gesture as
                    // it changes place.
                    ForEach(libraries) { library in
                        card(library, width: width).id(library.id)
                    }
                }
                .frame(height: fullCardHeight, alignment: .center)
                .padding(.vertical, 6)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: libraries.map(\.id))
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
            .scrollClipDisabled()
            // The finger moves the held card, not the row.
            .scrollDisabled(isReordering)
            .onScrollGeometryChange(for: ScrollMeasure.self) { geometry in
                ScrollMeasure(offset: geometry.contentOffset.x, row: geometry.containerSize.width)
            } action: { _, measure in
                remember(measure)
            }
            .onAppear {
                if let leading = scrollMemory.leadingLibraryId, leading != libraries.first?.id {
                    proxy.scrollTo(leading, anchor: .leading)
                }
            }
            // The row zooms out under a held card; bring that card's slot
            // back under the finger in the same animation.
            .onChange(of: movingId) { _, held in
                guard let held else { return }
                let width = max(scrollMemory.rowWidth, 1)
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    proxy.scrollTo(held, anchor: UnitPoint(x: min(max(pickupX / width, 0), 1), y: 0.5))
                }
            }
            .task(id: movingId) { await tickWhileHeld() }
            .onChange(of: holdTick) { holdTicked(proxy) }
            // After a drop the row zooms back in; keep the dropped card where
            // it was let go rather than wherever the row lands.
            .onChange(of: settleRequest) {
                guard let droppedId else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    proxy.scrollTo(droppedId, anchor: dropAnchor)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .overlay(alignment: .topLeading) { heldCard }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isReordering)
        .onChange(of: isReordering) { _, holding in
            isHolding = holding
        }
        .onDisappear {
            drop()
            isHolding = false
        }
    }

    private struct ScrollMeasure: Equatable {
        let offset: CGFloat
        let row: CGFloat
    }

    /// Kept outside view state, so scrolling the row redraws nothing.
    private func remember(_ measure: ScrollMeasure) {
        scrollMemory.offset = measure.offset
        scrollMemory.rowWidth = measure.row
        guard !isReordering, !libraries.isEmpty else { return }
        let index = Int(((measure.offset + HomeFeedMetrics.gutter) / step).rounded())
        scrollMemory.leadingLibraryId = libraries[min(max(index, 0), libraries.count - 1)].id
    }

    private func card(_ library: Library, width: CGFloat) -> some View {
        let isMoving = movingId == library.id
        return VStack(alignment: .leading, spacing: 8) {
            artwork(library, width: width)
            Text(verbatim: library.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.vividOnSurface)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        // The held card's slot stays open; its copy follows the finger.
        .opacity(isMoving ? 0.001 : 1)
        .contentShape(Rectangle())
        .onTapGesture { tap(library) }
        .gesture(PhoneLibraryHoldGesture(space: Self.space) { state, point in
            hold(library, state: state, at: point)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: library.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Open library"))
        .accessibilityAction(named: "Move earlier") { onMove(library, -1) }
        .accessibilityAction(named: "Move later") { onMove(library, 1) }
    }

    /// The copy of the held card that follows the finger.
    @ViewBuilder
    private var heldCard: some View {
        if let movingId, let library = libraries.first(where: { $0.id == movingId }) {
            let width = fullWidth * Self.heldScale
            artwork(library, width: width)
                .scaleEffect(reduceMotion ? 1 : 1.1)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                .position(x: finger.x, y: 6 + fullCardHeight / 2 - (8 + Self.nameHeight) / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
        }
    }

    private func tap(_ library: Library) {
        // The lift that ends a hold isn't a tap.
        guard movingId == nil, Date().timeIntervalSince(holdEnded) > 0.3 else { return }
        onOpen(library)
    }

    /// Hold to pick a card up, then keep dragging to move it.
    private func hold(_ library: Library, state: UIGestureRecognizer.State, at point: CGPoint) {
        switch state {
        case .began:
            guard movingId == nil else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            finger = point
            pickupX = point.x
            origin = nil
            movingId = library.id
        case .changed:
            guard movingId == library.id else { return }
            finger = point
            retarget()
        case .ended, .cancelled, .failed:
            if movingId == library.id { drop() }
        default:
            break
        }
    }

    /// Moves the held card one slot towards where the finger has taken it:
    /// as many slots from where it started as the finger, and the row under
    /// the finger, have travelled.
    private func retarget() {
        guard let movingId, let origin,
              let index = libraries.firstIndex(where: { $0.id == movingId }) else { return }
        let travelled = (finger.x - pickupX) + (scrollMemory.offset - origin.offset)
        let wanted = origin.index + Int((travelled / step).rounded())
        let target = min(max(wanted, 0), libraries.count - 1)
        guard target != index else { return }
        onMove(libraries[index], target > index ? 1 : -1)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Ticks while a card is held, after the zoomed-out row has had time to
    /// settle under it.
    private func tickWhileHeld() async {
        guard let held = movingId else { return }
        try? await Task.sleep(for: .milliseconds(300))
        while !Task.isCancelled, movingId == held {
            holdTick += 1
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    /// The first tick notes where the held card and the row are. Later
    /// ticks keep the card in step with the finger and, while the finger
    /// rests near either end, bring the next library in from that side.
    private func holdTicked(_ proxy: ScrollViewProxy) {
        guard let held = movingId,
              let index = libraries.firstIndex(where: { $0.id == held }) else { return }
        if origin == nil {
            origin = (index, scrollMemory.offset)
            lastEdgeScroll = .now
        } else if ContinuousClock.now - lastEdgeScroll >= Self.edgePause, scrollMemory.rowWidth > 0 {
            if finger.x < Self.edgeZone, index > 0 {
                lastEdgeScroll = .now
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(libraries[index - 1].id, anchor: .leading)
                }
            } else if finger.x > scrollMemory.rowWidth - Self.edgeZone, index < libraries.count - 1 {
                lastEdgeScroll = .now
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(libraries[index + 1].id, anchor: .trailing)
                }
            }
        }
        // Also catches moves the row's own scrolling asks for.
        retarget()
    }

    private func drop() {
        guard let held = movingId else { return }
        holdEnded = Date()
        // Where across the row the finger let go, so the card can stay there.
        let width = max(scrollMemory.rowWidth, 1)
        dropAnchor = UnitPoint(x: min(max(finger.x / width, 0), 1), y: 0.5)
        droppedId = held
        origin = nil
        movingId = nil
        settleRequest += 1
    }

    /// The library's own image, or its symbol on a plain tile when the
    /// server has none.
    @ViewBuilder
    private func artwork(_ library: Library, width: CGFloat) -> some View {
        let size = CGSize(width: width, height: width * 9 / 16)
        let url = library.posterUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ZStack {
            Color.white.opacity(0.08)
            Image(systemName: Self.symbol(for: library))
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
            if !url.isEmpty {
                AsyncImageView(url: url, thumbhash: nil, targetSize: size, contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: HomeFeedMetrics.stillRadius, style: .continuous))
    }

    private static func symbol(for library: Library) -> String {
        if library.isMixedLibrary { return library.navigationIcon }
        return library.isSeriesLibrary ? PrimaryMenuBuiltin.series.navigationIcon
            : PrimaryMenuBuiltin.movies.navigationIcon
    }
}

/// A press held on a library card, then dragged. UIKit's own long press: it
/// leaves quick swipes to the row's scrolling, which a SwiftUI long press
/// and drag attached to the cards did not.
private struct PhoneLibraryHoldGesture: UIGestureRecognizerRepresentable {
    let space: String
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recogniser = UILongPressGestureRecognizer()
        recogniser.minimumPressDuration = 0.3
        // The same drift a scroll allows before it starts, so a slow scroll
        // that begins on a card stays a scroll.
        recogniser.allowableMovement = 10
        recogniser.cancelsTouchesInView = false
        recogniser.delegate = context.coordinator
        return recogniser
    }

    /// Runs alongside the row's and the page's scrolling and the cards' taps,
    /// so none of them can stop a hold from being recognised. Once a card is
    /// held the row and the page are told to hold still.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    func handleUIGestureRecognizerAction(_ recogniser: UILongPressGestureRecognizer, context: Context) {
        onChange(recogniser.state, context.converter.location(in: .named(space)))
    }
}

/// One library, opened from the Library tab: its name over the catalogue
/// page with its sort, filter and letter menus.
struct PhoneLibraryPage: View {
    let library: Library

    @State private var chromeScroll = PageChromeScrollState()

    var body: some View {
        BrowseView(libraryId: library.id, libraryType: library.type)
            .environment(chromeScroll)
            .navigationTitle(library.name)
            .vividNavigationTitleDisplayMode(.inline)
    }
}
#endif
