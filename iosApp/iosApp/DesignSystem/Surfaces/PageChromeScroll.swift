import SwiftUI

/// How far a page has scrolled, as far as its top chrome cares. Values past
/// the point where the chrome is fully shown are not kept, so deep scrolling
/// causes no updates.
@Observable @MainActor
final class PageChromeScrollState {
    private(set) var offset: CGFloat = 0

    init() {}

    func reset() {
        if offset != 0 { offset = 0 }
    }

    func report(_ distance: CGFloat) {
        let clamped = min(max(distance, 0), PageChromeFade.end)
        guard abs(clamped - offset) >= 0.5 else { return }
        offset = clamped
    }
}

/// Glass behind a page's pinned top chrome. It fades in as the page scrolls
/// under it and reaches the top of the screen by itself.
struct PageChromeGlass: View {
    private let scrollState: PageChromeScrollState
    @Environment(\.usesDuoSideTabBar) private var usesDuoSideTabBar

    init(scrollState: PageChromeScrollState) {
        self.scrollState = scrollState
    }

    var body: some View {
        #if os(iOS)
        if !usesDuoSideTabBar {
            // Only the opacity follows the scroll; the glass keeps its layer.
            PageChromeStrip()
                .opacity(PageChromeFade.opacity(for: scrollState.offset))
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct PageChromeStrip: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Color(.sRGB, white: 0.16, opacity: 0.98)
        } else {
            Color.clear
                .vividGlass(in: Rectangle(), tint: .black.opacity(0.10))
                .overlay {
                    Color.white.opacity(0.025)
                }
        }
    }
}
#endif

private enum PageChromeFade {
    static let start: CGFloat = 8
    static let end: CGFloat = 56

    /// Smoothstep from `start` to `end`.
    static func opacity(for offset: CGFloat) -> Double {
        let progress = min(max((offset - start) / (end - start), 0), 1)
        return Double(progress * progress * (3 - 2 * progress))
    }
}

/// Hides the floating tab bar while the user reads down a page and brings
/// it back as soon as they scroll up or return to the top.
@Observable @MainActor
final class MobileTabBarScrollState {
    private(set) var isHidden = false

    @ObservationIgnored private var lastOffset: CGFloat?
    @ObservationIgnored private var travel: CGFloat = 0

    private static let topZone: CGFloat = 2
    private static let jump: CGFloat = 160
    private static let hideAfter: CGFloat = 18
    private static let showAfter: CGFloat = 12

    init() {}

    func reset() {
        setHidden(false)
        lastOffset = nil
        travel = 0
    }

    func report(_ offset: CGFloat) {
        guard let previous = lastOffset else {
            lastOffset = offset
            return
        }
        lastOffset = offset

        if offset <= Self.topZone {
            travel = 0
            setHidden(false)
            return
        }

        let change = offset - previous
        // A programmatic scroll or restored position, not a gesture.
        if abs(change) >= Self.jump {
            travel = 0
            return
        }

        if (change > 0 && travel < 0) || (change < 0 && travel > 0) {
            travel = 0
        }
        travel += change

        if travel > Self.hideAfter {
            travel = 0
            setHidden(true)
        } else if travel < -Self.showAfter {
            travel = 0
            setHidden(false)
        }
    }

    private func setHidden(_ hidden: Bool) {
        if isHidden != hidden { isHidden = hidden }
    }
}

extension View {
    /// Feeds this vertical scroll view's distance from the top to `state`,
    /// and to the tab bar when one is listening.
    func reportsPageChromeScroll(to state: PageChromeScrollState) -> some View {
        #if os(iOS)
        modifier(PageScrollReporter(pageState: state))
        #else
        self
        #endif
    }

    /// The same for shared content that doesn't know who is listening: the
    /// page chrome and tab bar states in the environment, if any.
    func reportsPageChromeScroll() -> some View {
        #if os(iOS)
        modifier(InheritedPageScrollReporter())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PageScrollReporter: ViewModifier {
    let pageState: PageChromeScrollState?
    @Environment(MobileTabBarScrollState.self) private var tabBarState: MobileTabBarScrollState?

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self, of: Self.distance) { _, distance in
            pageState?.report(distance)
            tabBarState?.report(distance)
        }
    }

    /// Distance scrolled from the resting top, within the reachable range.
    private static func distance(_ geometry: ScrollGeometry) -> CGFloat {
        let insets = geometry.contentInsets
        let reachable = max(0, geometry.contentSize.height + insets.top + insets.bottom - geometry.containerSize.height)
        return min(max(geometry.contentOffset.y + insets.top, 0), reachable)
    }
}

private struct InheritedPageScrollReporter: ViewModifier {
    @Environment(PageChromeScrollState.self) private var pageState: PageChromeScrollState?
    @Environment(MobileTabBarScrollState.self) private var tabBarState: MobileTabBarScrollState?

    func body(content: Content) -> some View {
        if pageState == nil && tabBarState == nil {
            content
        } else {
            content.modifier(PageScrollReporter(pageState: pageState))
        }
    }
}
#endif
