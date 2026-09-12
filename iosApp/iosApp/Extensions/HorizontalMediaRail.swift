import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Phone rails share a top edge even when one card has more metadata.
/// Other platforms retain their existing layout and focus behavior.
enum HorizontalMediaRailLayout {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var cardAlignment: VerticalAlignment { isPhone ? .top : .center }
    static var scrollAnchor: UnitPoint { isPhone ? .leading : .center }
    static var targetBehavior: ViewAlignedScrollTargetBehavior {
        #if os(iOS)
        // The explicit leading anchor is iOS 26+. iOS 18 keeps the system
        // anchor, which still snaps whole cards into view.
        if #available(iOS 26.0, *) {
            return .viewAligned(limitBehavior: .always, anchor: isPhone ? .leading : nil)
        } else {
            return .viewAligned(limitBehavior: .always)
        }
        #else
        return .viewAligned(limitBehavior: .always, anchor: isPhone ? .leading : nil)
        #endif
    }
}

extension View {
    /// Attach to the stack INSIDE a horizontal media ScrollView, so the
    /// nearest native scroll view is the rail, not its vertically scrolling page.
    @ViewBuilder
    func phoneMediaRailBounds() -> some View {
        #if os(iOS)
        if HorizontalMediaRailLayout.isPhone {
            background(PhoneMediaRailBounds().allowsHitTesting(false))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PhoneMediaRailBounds: UIViewRepresentable {
    func makeUIView(context: Context) -> PhoneMediaRailBoundsView {
        PhoneMediaRailBoundsView()
    }

    func updateUIView(_ uiView: PhoneMediaRailBoundsView, context: Context) {
        uiView.configureEnclosingRail()
        // SwiftUI can attach or update its native scroll view after this call.
        // One deferred pass handles that without polling or replacing delegates.
        DispatchQueue.main.async { [weak uiView] in
            uiView?.configureEnclosingRail()
        }
    }
}

final class PhoneMediaRailBoundsView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        configureEnclosingRail()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureEnclosingRail()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Reassert after a detail cover/zoom restores SwiftUI's scroll host.
        configureEnclosingRail()
    }

    func configureEnclosingRail() {
        var ancestor = superview
        while let view = ancestor {
            if let rail = view as? UIScrollView {
                // Native scrolling/deceleration stays in charge. Unlike
                // .basedOnSize, these flags also stop long rails overscrolling
                // past their first/last card and drifting vertically on a drag.
                if rail.bouncesHorizontally { rail.bouncesHorizontally = false }
                if rail.bouncesVertically { rail.bouncesVertically = false }
                if rail.alwaysBounceHorizontal { rail.alwaysBounceHorizontal = false }
                if rail.alwaysBounceVertical { rail.alwaysBounceVertical = false }
                if !rail.isDirectionalLockEnabled { rail.isDirectionalLockEnabled = true }
                return
            }
            ancestor = view.superview
        }
    }
}
#endif

#if os(tvOS)
private struct TVHomeStableRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var tvHomeStableRows: Bool {
        get { self[TVHomeStableRowsKey.self] }
        set { self[TVHomeStableRowsKey.self] = newValue }
    }
}

/// Match the fixed tvOS caption fonts without measuring lazily mounted cards.
enum TVHomeRowGeometry {
    static let headingHeight = ceil(UIFont.systemFont(ofSize: 36, weight: .semibold).lineHeight)
    static let headingSpacing: CGFloat = 20
    static let rowSpacing: CGFloat = 30
    static let cardPadding: CGFloat = 24
    static let titleHeight = ceil(UIFont.systemFont(ofSize: 20, weight: .medium).lineHeight)
    static let metadataHeight = ceil(UIFont.systemFont(ofSize: 18, weight: .regular).lineHeight)

    static func captionHeight(_ style: CardCaptionStyle) -> CGFloat {
        guard style.showsTitle else { return 0 }
        return titleHeight + (style.showsMetadata ? 4 + metadataHeight : 0)
    }

    static func stripHeight(artworkHeight: CGFloat, caption: CardCaptionStyle,
                            captionGap: CGFloat, verticalPadding: CGFloat) -> CGFloat {
        artworkHeight + (caption.showsTitle ? captionGap + captionHeight(caption) : 0)
            + verticalPadding * 2
    }

    static func stripHeight(layout: MediaRowLayout, posterWidth: CGFloat,
                            presentation: CardPresentationPreference,
                            verticalPadding: CGFloat = cardPadding) -> CGFloat {
        let artworkHeight: CGFloat
        let captionGap: CGFloat
        switch layout {
        case .poster:
            artworkHeight = posterWidth * presentation.posterSize.scale
                * VividTheme.posterCardHeight / VividTheme.posterCardWidth
            captionGap = 22
        case .thumbnail:
            artworkHeight = VividTheme.thumbnailCardHeight * presentation.posterSize.scale
            captionGap = 14
        }
        return stripHeight(artworkHeight: artworkHeight, caption: presentation.caption,
                           captionGap: captionGap, verticalPadding: verticalPadding)
    }

    static func rowHeight(layout: MediaRowLayout, posterWidth: CGFloat,
                          presentation: CardPresentationPreference) -> CGFloat {
        headingHeight + headingSpacing
            + stripHeight(layout: layout, posterWidth: posterWidth, presentation: presentation)
    }
}
#endif
