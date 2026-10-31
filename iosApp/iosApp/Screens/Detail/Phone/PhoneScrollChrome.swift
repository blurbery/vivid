import SwiftUI

#if !os(tvOS)
extension EnvironmentValues {
    /// The whole screen behind a detail cover, safe areas included. The iPad
    /// hero sizes itself from it; zero outside a cover.
    @Entry var detailViewportSize: CGSize = .zero
}

/// How far a detail page has scrolled, for the glass title bar. Small
/// movements near the top count as unscrolled, and the value stops growing
/// once the bar is fully shown.
@Observable @MainActor
final class PhoneDetailScrollState {
    private(set) var offset: CGFloat = 0
    @ObservationIgnored private var preparedContentId: String?

    init() {}

    func update(_ rawOffset: CGFloat) {
        let clamped = min(max(rawOffset, 0), MobileScrollChromeMetrics.maximumOffset)
        let value = clamped <= MobileScrollChromeMetrics.restingOffset ? 0 : clamped
        guard abs(value - offset) >= 0.5 else { return }
        offset = value
    }

    /// A new title starts unscrolled. Coming back to the same title, from a
    /// person or a nested page, keeps the bar as it was.
    func prepare(for contentId: String) {
        guard contentId != preparedContentId else { return }
        preparedContentId = contentId
        offset = 0
    }
}

enum MobileScrollChromeMetrics {
    static let restingOffset: CGFloat = 150
    static let maximumOffset: CGFloat = 480

    /// The offset a page reports for its scroll geometry.
    static func reportedOffset(contentOffset: CGFloat, topInset: CGFloat) -> CGFloat {
        let raw = max(0, contentOffset + topInset)
        return raw <= restingOffset ? 0 : min(raw, maximumOffset)
    }

    static func smoothstep(_ value: CGFloat, from lower: CGFloat, to upper: CGFloat) -> CGFloat {
        let progress = min(max((value - lower) / (upper - lower), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
}

extension View {
    /// Reports a detail page's scroll position to its title bar.
    func reportsDetailScroll(to state: PhoneDetailScrollState) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            MobileScrollChromeMetrics.reportedOffset(
                contentOffset: geometry.contentOffset.y,
                topInset: geometry.contentInsets.top
            )
        } action: { _, offset in
            state.update(offset)
        }
    }
}
#endif

#if os(iOS)
/// The close or back control over a detail page, and on iPhone the glass
/// bar and title that fade in as the page scrolls. On the Duo the control
/// moves beside the status icons and the bar stays off.
struct PhoneDetailTopChrome: View {
    let title: String
    let isScrollGlassEnabled: Bool
    let scrollState: PhoneDetailScrollState
    let leadingSystemName: String?
    let leadingAccessibilityLabel: String?
    let onLeadingTap: () -> Void

    @State private var sideStrip: PhoneDuo.SideStrip?
    @State private var controlCorner: PhoneDuo.ControlCorner?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        title: String,
        isScrollGlassEnabled: Bool,
        scrollState: PhoneDetailScrollState,
        leadingSystemName: String?,
        leadingAccessibilityLabel: String?,
        onLeadingTap: @escaping () -> Void
    ) {
        self.title = title
        self.isScrollGlassEnabled = isScrollGlassEnabled
        self.scrollState = scrollState
        self.leadingSystemName = leadingSystemName
        self.leadingAccessibilityLabel = leadingAccessibilityLabel
        self.onLeadingTap = onLeadingTap
    }

    private var showsScrollGlass: Bool {
        isScrollGlassEnabled && sideStrip == nil && controlCorner == nil
    }

    var body: some View {
        // The body never reads the scroll offset: only the small fade views
        // below do, so the layout, glass and button stay put while scrolling.
        let glassShown = showsScrollGlass
        ZStack(alignment: .top) {
            if glassShown {
                MobileScrollFade(scrollState: scrollState, curve: .strip) {
                    MobileChromeGlassStrip(reduceTransparency: reduceTransparency)
                        .equatable()
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                MobileScrollFade(scrollState: scrollState, curve: .title) {
                    scrollTitle
                }
                .allowsHitTesting(false)
            }
            HStack {
                if let leadingSystemName, controlCorner == nil {
                    control(systemName: leadingSystemName, glassShown: glassShown)
                }
                Spacer(minLength: 20)
            }
            .padding(.leading, 9)
            .padding(.trailing, 18)
            .padding(.top, 9)
            if let corner = controlCorner, let leadingSystemName {
                control(systemName: leadingSystemName, glassShown: glassShown)
                    .frame(width: 2 * PhoneDuo.ControlCorner.centreFromEdge)
                    .padding(.top, corner.top)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: corner.edge == .trailing ? .topTrailing : .topLeading
                    )
                    .ignoresSafeArea()
            }
        }
        .onDuo { chrome in
            // Measured within the safe area, so the proxy reports the insets
            // the Duo's side strip shows up in.
            chrome.background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: MobileChromeGeometry(proxy), initial: true) {
                            measureDuoPlacement(proxy)
                        }
                }
            }
        }
        .zIndex(20)
    }

    private func measureDuoPlacement(_ proxy: GeometryProxy) {
        let strip = PhoneDuo.sideStrip(proxy)
        let corner = PhoneDuo.controlCorner(proxy)
        if strip != sideStrip { sideStrip = strip }
        if corner != controlCorner { controlCorner = corner }
    }

    private var scrollTitle: some View {
        Text(verbatim: title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 96)
            .frame(maxWidth: .infinity, minHeight: VividTheme.topBarIconHitSize)
            .padding(.top, 9)
    }

    private func control(systemName: String, glassShown: Bool) -> some View {
        let size = VividTheme.topBarIconHitSize
        return Button(action: onLeadingTap) {
            ZStack {
                // The glass fades out as the bar fades in, and only then.
                MobileScrollFade(scrollState: scrollState, curve: glassShown ? .controlGlass : nil) {
                    MobileChromeGlassCircle(size: size)
                        .equatable()
                }
                Image(systemName: systemName)
                    .font(.system(size: systemName == "chevron.left" ? 17 : 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(leadingAccessibilityLabel ?? String(localized: "Back"))
    }
}

/// How the chrome's parts fade with the scroll offset.
private enum MobileChromeFade {
    case strip, title, controlGlass

    func opacity(at offset: CGFloat) -> CGFloat {
        switch self {
        case .strip:
            MobileScrollChromeMetrics.smoothstep(offset, from: 200, to: 360)
        case .title:
            MobileScrollChromeMetrics.smoothstep(offset, from: 400, to: 480)
        case .controlGlass:
            1 - MobileScrollChromeMetrics.smoothstep(offset, from: 150, to: 260)
        }
    }
}

/// The only part of the chrome that reads the scroll offset. It sets its
/// content's opacity, and hides the title from VoiceOver while it's faint.
/// With no curve it stays opaque and doesn't follow the scroll at all.
private struct MobileScrollFade<Content: View>: View {
    let scrollState: PhoneDetailScrollState
    let curve: MobileChromeFade?
    @ViewBuilder let content: Content

    var body: some View {
        let opacity = curve.map { $0.opacity(at: scrollState.offset) } ?? 1
        content
            .opacity(opacity)
            .accessibilityHidden(curve == .title && opacity < 0.5)
    }
}

/// The bar's 62 points, reaching up through the status bar.
private struct MobileChromeGlassStrip: View, Equatable {
    let reduceTransparency: Bool

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: VividTheme.topBarIconHitSize + 18)
            .background(alignment: .bottom) {
                fill.ignoresSafeArea(edges: .top)
            }
    }

    @ViewBuilder
    private var fill: some View {
        if reduceTransparency {
            Color(white: 0.16).opacity(0.98)
        } else {
            Color.clear
                .vividGlass(in: Rectangle(), tint: .black.opacity(0.10))
                .overlay(Color.white.opacity(0.025))
        }
    }
}

/// The close or back control's own glass circle.
private struct MobileChromeGlassCircle: View, Equatable {
    let size: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            .vividGlass(in: Circle(), interactive: true)
    }
}

/// What the Duo placement depends on, so it is measured again only when
/// the chrome's size or insets change.
private struct MobileChromeGeometry: Equatable {
    let size: CGSize
    let insets: EdgeInsets

    init(_ proxy: GeometryProxy) {
        size = proxy.size
        insets = proxy.safeAreaInsets
    }
}
#endif
