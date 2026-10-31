import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared settings for horizontal artwork rails. iPhone rails align cards by
/// their top edges and measure positions from the leading edge; iPad and
/// Apple TV keep centred cards.
enum HorizontalMediaRailLayout {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var cardAlignment: VerticalAlignment {
        isPhone ? .top : .center
    }

    static var scrollAnchor: UnitPoint {
        isPhone ? .leading : .center
    }

    static var targetBehavior: ViewAlignedScrollTargetBehavior {
        #if os(tvOS)
        .viewAligned(limitBehavior: .always, anchor: nil)
        #else
        if #available(iOS 26, *) {
            .viewAligned(limitBehavior: .always, anchor: isPhone ? .leading : nil)
        } else {
            .viewAligned(limitBehavior: .always)
        }
        #endif
    }
}

extension View {
    /// Stops the enclosing iPhone rail, and only that rail, from bouncing.
    func phoneMediaRailBounds() -> some View {
        #if os(iOS)
        modifier(PhoneMediaRailBoundsModifier())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct PhoneMediaRailBoundsModifier: ViewModifier {
    func body(content: Content) -> some View {
        if HorizontalMediaRailLayout.isPhone {
            content.background {
                PhoneMediaRailBoundsBridge()
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

private struct PhoneMediaRailBoundsBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> PhoneMediaRailBoundsView {
        PhoneMediaRailBoundsView()
    }

    func updateUIView(_ view: PhoneMediaRailBoundsView, context: Context) {
        view.applyRailSettings()
        // SwiftUI can attach the rail after this update; check again next turn.
        DispatchQueue.main.async { [weak view] in
            view?.applyRailSettings()
        }
    }
}

/// Placed inside a rail's content, this sets the nearest enclosing scroll
/// view to scroll without bouncing and to lock to one direction. Nothing
/// else about that scroll view changes.
class PhoneMediaRailBoundsView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyRailSettings()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyRailSettings()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRailSettings()
    }

    func applyRailSettings() {
        guard let rail = enclosingScrollView else { return }
        if rail.bouncesHorizontally { rail.bouncesHorizontally = false }
        if rail.bouncesVertically { rail.bouncesVertically = false }
        if rail.alwaysBounceHorizontal { rail.alwaysBounceHorizontal = false }
        if rail.alwaysBounceVertical { rail.alwaysBounceVertical = false }
        if !rail.isDirectionalLockEnabled { rail.isDirectionalLockEnabled = true }
    }

    private var enclosingScrollView: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView { return scrollView }
            ancestor = view.superview
        }
        return nil
    }
}
#endif
