import SwiftUI

/// iPhone Duo support. Every Duo-specific layout and orientation change keys
/// off `isDuo`, so other iPhones, iPads and Apple TV keep their existing
/// behaviour. A later foldable that isn't listed here falls back to the
/// iPhone layout.
enum PhoneDuo {
    static let modelIdentifiers: Set<String> = ["iPhone19,4"]

    #if os(iOS)
    static let isDuo = modelIdentifiers.contains(AppHealthSystem.hardwareModel)
    #else
    static let isDuo = false
    #endif

    /// The unfolded inner screen is 669 × 951 points. The cover screen, like
    /// every other iPhone, is under 500 points on its short side. Read this
    /// from the current window size: folding moves the scene between screens.
    static func isInnerScreen(_ size: CGSize) -> Bool {
        isDuo && min(size.width, size.height) > 600
    }

    /// The inner screen has a regular width in both orientations; the cover
    /// screen is compact like other iPhones. The size class follows a fold.
    static func usesWideLayout(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isDuo && horizontalSizeClass == .regular
    }

    /// Page tab bars (For You, Search and Calendar) keep their portrait width
    /// on the inner screen, 669 points less the 16-point margins, instead of
    /// stretching across landscape.
    static func pageTabsMaxWidth(_ horizontalSizeClass: UserInterfaceSizeClass?) -> CGFloat {
        usesWideLayout(horizontalSizeClass) ? 669 - 2 * 16 : .infinity
    }

    /// Page tabs moved to the bottom sit this far above the safe area. On the
    /// cover screen the side tab bar ends where their row begins.
    static let pageTabsBottomPadding: CGFloat = 8
    static let pageTabsRowHeight: CGFloat = 51

    /// On the inner screen a detail page's actions, synopsis and selectors
    /// sit in one column this wide, centred under the title.
    static let detailColumnWidth: CGFloat = 560

    /// Detail pages and Home's spotlight keep the iPhone portrait design,
    /// with its parallax and artwork glass, at any width on the Duo, though
    /// its inner screen has a regular width like iPad. iPad copies it.
    @MainActor
    static func usesPhoneDetailLayout(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass != .regular || usesDuoDetailDesign
    }

    /// iPad detail pages share the inner screen's detail switches, though
    /// their hero copies Apple TV. Detail code checks this rather than
    /// `isDuo`, so the Duo's tab bar, status strip and other pages stay
    /// Duo-only.
    @MainActor
    static var usesDuoDetailDesign: Bool {
        #if os(iOS)
        isDuo || UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The inner screen's centred detail column, also used on iPad.
    @MainActor
    static func usesWideDetailLayout(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        usesDuoDetailDesign && horizontalSizeClass == .regular
    }

    /// `GeometryProxy.size` excludes the safe area, so measure the window.
    static func isInnerScreen(_ geometry: GeometryProxy) -> Bool {
        let insets = geometry.safeAreaInsets
        return isInnerScreen(CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        ))
    }

    /// The status bar strip down one side of the cover screen, and of the
    /// inner screen in landscape.
    struct SideStrip: Equatable {
        let edge: HorizontalEdge
        let width: CGFloat
        let isInnerScreen: Bool
        /// Where controls start, 14 points under the status icons. The time
        /// and connectivity icons end about 100 points down on the inner
        /// screen and 146 on the cover, where the camera sits above them.
        var usualControlsTop: CGFloat { isInnerScreen ? 114 : 160 }
        /// Widgets added to the strip push the controls further down.
        @MainActor var controlsTop: CGFloat { usualControlsTop + DuoStatusArea.shared.growth }
        /// iOS centres the status icons this far in from the strip's inner
        /// edge, rather than in the middle of the strip.
        static let iconCentreInset: CGFloat = 36
    }

    @MainActor static func sideStrip(_ geometry: GeometryProxy) -> SideStrip? {
        guard let edge = sideBarEdge(geometry) else { return nil }
        // A small view, such as a page's top controls, can't tell the screen
        // from its own size, so check the window as well.
        let isInner = isInnerScreen(geometry) || windowSize.map(isInnerScreen) == true
        return SideStrip(
            edge: edge,
            width: edge == .trailing ? geometry.safeAreaInsets.trailing : geometry.safeAreaInsets.leading,
            isInnerScreen: isInner
        )
    }

    @MainActor private static var windowSize: CGSize? {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .coordinateSpace.bounds.size
        #else
        nil
        #endif
    }

    /// Where a page's X or back button stands on the Duo: centred on the
    /// same line as the status icons, which iOS keeps 48 points in from the
    /// screen's edge, 14 points under the connectivity icon. That's in the
    /// side strip on the cover and in landscape, and the top corner on the
    /// inner screen in portrait, where the icons end about 62 points down.
    /// Widgets added to the status bar push it further down.
    struct ControlCorner: Equatable {
        let edge: HorizontalEdge
        let usualTop: CGFloat
        @MainActor var top: CGFloat { usualTop + DuoStatusArea.shared.growth }
        static let centreFromEdge: CGFloat = 48
    }

    @MainActor static func controlCorner(_ geometry: GeometryProxy) -> ControlCorner? {
        guard isDuo else { return nil }
        if let strip = sideStrip(geometry) {
            return ControlCorner(edge: strip.edge, usualTop: strip.usualControlsTop)
        }
        let isInner = isInnerScreen(geometry) || windowSize.map(isInnerScreen) == true
        return isInner ? ControlCorner(edge: .trailing, usualTop: 76) : nil
    }

    /// The cover screen, and the inner screen in landscape, put the status
    /// bar in a strip down one side. Vivid's tab bar stands in that strip.
    static func sideBarEdge(_ geometry: GeometryProxy) -> HorizontalEdge? {
        guard isDuo else { return nil }
        let insets = geometry.safeAreaInsets
        if insets.trailing >= 60 { return .trailing }
        if insets.leading >= 60 { return .leading }
        return nil
    }
}

extension View {
    /// Applies `transform` only on the iPhone Duo, so other devices keep the
    /// exact view they had. `isDuo` never changes while the app runs, so this
    /// never swaps a view's identity.
    @ViewBuilder
    func onDuo(@ViewBuilder _ transform: (Self) -> some View) -> some View {
        if PhoneDuo.isDuo {
            transform(self)
        } else {
            self
        }
    }

    /// Applies `transform` wherever detail pages use the Duo's design: on
    /// the Duo and on iPad. Neither changes while the app runs.
    @MainActor @ViewBuilder
    func onDuoDetail(@ViewBuilder _ transform: (Self) -> some View) -> some View {
        if PhoneDuo.usesDuoDetailDesign {
            transform(self)
        } else {
            self
        }
    }
}

/// The band iOS keeps clear at the top of the Duo's side strip, or of its top
/// corner in portrait, for the camera, the status icons and any widgets
/// added there. `DuoStatusAreaView` measures it on iOS 27.1.
@MainActor @Observable
final class DuoStatusArea {
    static let shared = DuoStatusArea()

    /// How much further down than usual the band ends. The strip's controls
    /// and tab bar move down by this much. Stays 0 when the band can't be
    /// read.
    private(set) var growth: CGFloat = 0

    func update(bandBottom: CGFloat, screen: CGSize) {
        guard PhoneDuo.isDuo else { return }
        // With just the time and connectivity icons the band ends 170 points
        // down on the cover, 120 in the inner screen's landscape strip and 82
        // in its portrait corner.
        let usualBottom: CGFloat = PhoneDuo.isInnerScreen(screen)
            ? (screen.width > screen.height ? 120 : 82)
            : 170
        let growth = max(0, (bandBottom - usualBottom).rounded())
        if growth != self.growth { self.growth = growth }
    }
}

extension EnvironmentValues {
    /// True while the tab bar sits in the Duo's side strip. For You and
    /// Search then move their page tabs into the free space at the bottom.
    @Entry var usesDuoSideTabBar = false
    /// The Duo's status bar strip beside the tab view and the pages it
    /// pushes.
    @Entry var duoSideStrip: PhoneDuo.SideStrip? = nil
    /// Where X and back buttons stand on the Duo, beside or under the status
    /// icons.
    @Entry var duoControlCorner: PhoneDuo.ControlCorner? = nil
    /// Set by a page that hides its back button, so the strip shows none.
    @Entry var duoStripBackHidden = false
}
