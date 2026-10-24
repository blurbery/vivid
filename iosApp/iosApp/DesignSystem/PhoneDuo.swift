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
    /// its inner screen has a regular width like iPad.
    static func usesPhoneDetailLayout(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        horizontalSizeClass != .regular || isDuo
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
        let controlsTop: CGFloat
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
            isInnerScreen: isInner,
            controlsTop: isInner ? 114 : 160
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

extension EnvironmentValues {
    /// True while the tab bar sits in the Duo's side strip. For You and
    /// Search then move their page tabs into the free space at the bottom.
    @Entry var usesDuoSideTabBar = false
    /// The Duo's status bar strip beside the tab view and the pages it
    /// pushes, where their X and back buttons stand.
    @Entry var duoSideStrip: PhoneDuo.SideStrip? = nil
    /// Set by a page that hides its back button, so the strip shows none.
    @Entry var duoStripBackHidden = false
}
