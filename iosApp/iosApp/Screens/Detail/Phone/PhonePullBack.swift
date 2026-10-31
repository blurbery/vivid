import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// Pulling a pushed detail page down from its top steps back one page
    /// in the detail cover. Apple TV keeps the view as it is.
    func detailScrollDismissal() -> some View {
        #if os(iOS)
        modifier(MobilePullBackModifier())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct DetailPullBackActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the detail cover on pushed pages: steps back one page.
    var detailPullBackAction: (() -> Void)? {
        get { self[DetailPullBackActionKey.self] }
        set { self[DetailPullBackActionKey.self] = newValue }
    }
}

/// When a downward pull at the top of a page counts as going back.
enum DetailDismissalPolicy {
    /// At the top, or pulled down past it. The bounce counts, so the pull
    /// can start without waiting for scrolling to settle.
    static func isAtTop(offset: CGFloat, topInset: CGFloat) -> Bool {
        offset + topInset <= 1
    }

    /// Only a mostly vertical, downward pull from the top.
    static func canBeginBack(isAtTop: Bool, velocity: CGPoint) -> Bool {
        isAtTop && velocity.y > 0 && abs(velocity.x) < 0.6 * velocity.y
    }

    /// A long pull, or a shorter quick one. Anything else cancels.
    static func shouldCompleteBack(translation: CGPoint, velocity: CGPoint) -> Bool {
        let distance = translation.y
        guard distance > 0, abs(translation.x) < 0.6 * distance else { return false }
        return distance >= 100 || (distance >= 35 && velocity.y >= 900)
    }
}

private struct MobilePullBackModifier: ViewModifier {
    @Environment(\.detailPullBackAction) private var pullBack
    @State private var isAtTop = true

    func body(content: Content) -> some View {
        content
            .modifier(MobileTopScrollEdgeModifier())
            .onScrollGeometryChange(for: Bool.self) { geometry in
                DetailDismissalPolicy.isAtTop(
                    offset: geometry.contentOffset.y,
                    topInset: geometry.contentInsets.top
                )
            } action: { _, atTop in
                isAtTop = atTop
            }
            .gesture(MobilePullBackRecogniser(isAtTop: isAtTop, pullBack: pullBack))
    }
}

/// A one-finger pan that runs alongside the scroll view's own gestures.
private struct MobilePullBackRecogniser: UIGestureRecognizerRepresentable {
    let isAtTop: Bool
    let pullBack: (() -> Void)?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recogniser = UIPanGestureRecognizer()
        recogniser.maximumNumberOfTouches = 1
        recogniser.cancelsTouchesInView = false
        recogniser.delegate = context.coordinator
        return recogniser
    }

    func updateUIGestureRecognizer(_ recogniser: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isAtTop = isAtTop
        context.coordinator.hasAction = pullBack != nil
        recogniser.isEnabled = pullBack != nil
    }

    func handleUIGestureRecognizerAction(_ recogniser: UIPanGestureRecognizer, context: Context) {
        guard recogniser.state == .ended, let pullBack else { return }
        let view = recogniser.view
        if DetailDismissalPolicy.shouldCompleteBack(
            translation: recogniser.translation(in: view),
            velocity: recogniser.velocity(in: view)
        ) {
            pullBack()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isAtTop = true
        var hasAction = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard hasAction, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return DetailDismissalPolicy.canBeginBack(isAtTop: isAtTop, velocity: pan.velocity(in: pan.view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
