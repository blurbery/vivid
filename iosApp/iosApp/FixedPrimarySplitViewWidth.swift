import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
/// SwiftUI treats `navigationSplitViewColumnWidth` as a preference on iPad.
/// Pin the backing UIKit split controller to the same width so its divider
/// cannot resize the overlay while retaining the system sidebar presentation.
struct FixedPrimarySplitViewWidth: UIViewControllerRepresentable {
    let width: CGFloat
    let sidebarIsHidden: Bool
    let onSwipeLeft: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(width: width, onSwipeLeft: onSwipeLeft)
        controller.sidebarIsHidden = sidebarIsHidden
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.width = width
        controller.sidebarIsHidden = sidebarIsHidden
        controller.onSwipeLeft = onSwipeLeft
        controller.applyWidthLock()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.tearDown()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var width: CGFloat
        var sidebarIsHidden = false
        var onSwipeLeft: () -> Void
        private var dragStartOffset: CGFloat = 0
        private var isDismissAnimationRunning = false
        private weak var managedSplitViewController: UISplitViewController?
        private weak var dragPresentationView: UIView?
        private weak var dragDimmingView: UIView?
        private var dimmingBaseAlpha: CGFloat = 1
        private weak var swipeHostView: UIView?
        private lazy var swipeLeftRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleSwipeLeft(_:))
            )
            recognizer.maximumNumberOfTouches = 1
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        init(width: CGFloat, onSwipeLeft: @escaping () -> Void) {
            self.width = width
            self.onSwipeLeft = onSwipeLeft
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyWidthLock()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyWidthLock()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyWidthLock()
            resetStrandedSidebarTransformIfNeeded()
        }

        /// `sidebarPresentationView` walks one level of private hierarchy; if
        /// an iPadOS release reshuffles it, or an interrupted animation leaks
        /// a translation, a stale transform would leave the sidebar visually
        /// offset with no gesture in flight. Layout passes are the safety net:
        /// when nothing owns the view, force it back to identity.
        private func resetStrandedSidebarTransformIfNeeded() {
            guard !isDragActive, !isDismissAnimationRunning,
                  let strandedView = dragPresentationView,
                  strandedView.transform != .identity,
                  strandedView.layer.animationKeys()?.isEmpty != false
            else { return }
            strandedView.transform = .identity
            dragPresentationView = nil
            releaseDimmingView(restoring: true)
        }

        func applyWidthLock() {
            guard let splitViewController = splitViewControllerAncestor else { return }
            managedSplitViewController = splitViewController
            // While the sidebar is visible the direct-touch pan below is the
            // sole interactive transition owner: keeping UIKit's built-in pan
            // enabled would let both recognizers move the same primary column
            // simultaneously. While the sidebar is hidden our recognizer only
            // accepts leftward swipes, so the system edge swipe stays enabled
            // to reveal the sidebar.
            splitViewController.presentsWithGesture = sidebarIsHidden
            if splitViewController.preferredPrimaryColumnWidth != width {
                splitViewController.preferredPrimaryColumnWidth = width
            }
            if splitViewController.minimumPrimaryColumnWidth != width {
                splitViewController.minimumPrimaryColumnWidth = width
            }
            if splitViewController.maximumPrimaryColumnWidth != width {
                splitViewController.maximumPrimaryColumnWidth = width
            }
            installSwipeRecognizer(in: splitViewController)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = panGesture.velocity(in: swipeHostView)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.1
        }

        @objc private func handleSwipeLeft(_ gestureRecognizer: UIPanGestureRecognizer) {
            guard let splitViewController = splitViewControllerAncestor else { return }

            let presentationView: UIView
            if gestureRecognizer.state == .began {
                guard let resolvedView = sidebarPresentationView(in: splitViewController) else {
                    return
                }
                presentationView = resolvedView
                dragPresentationView = resolvedView
            } else {
                guard let activeView = dragPresentationView else { return }
                presentationView = activeView
            }

            switch gestureRecognizer.state {
            case .began:
                let visibleTransform = presentationView.layer
                    .presentation()?
                    .affineTransform() ?? presentationView.transform
                presentationView.layer.removeAllAnimations()
                UIView.performWithoutAnimation {
                    presentationView.transform = visibleTransform
                }
                dragStartOffset = visibleTransform.tx
                // The dismiss/restore animations also own the scrim's alpha.
                // Strip that animation alongside the transform one, or the
                // shared animation transaction outlives the re-grab and its
                // delayed completion can hide the column mid-drag.
                if let dimmingView = dragDimmingView {
                    let visibleAlpha = dimmingView.layer.presentation()?.opacity
                        ?? Float(dimmingView.alpha)
                    dimmingView.layer.removeAllAnimations()
                    UIView.performWithoutAnimation {
                        dimmingView.alpha = CGFloat(visibleAlpha)
                    }
                }
                resolveDimmingView(
                    in: splitViewController,
                    excluding: presentationView
                )

            case .changed:
                let translation = gestureRecognizer.translation(in: splitViewController.view)
                let horizontalOffset = max(
                    -width,
                    min(0, dragStartOffset + translation.x)
                )
                presentationView.transform = CGAffineTransform(
                    translationX: horizontalOffset,
                    y: 0
                )
                updateDimming(forSidebarOffset: horizontalOffset)

            case .ended:
                let translation = gestureRecognizer.translation(in: splitViewController.view)
                let velocity = gestureRecognizer.velocity(in: splitViewController.view)
                let horizontalOffset = max(
                    -width,
                    min(0, dragStartOffset + translation.x)
                )
                let shouldDismiss = horizontalOffset <= -(width * 0.25) || velocity.x <= -700
                dragStartOffset = 0

                if shouldDismiss {
                    isDismissAnimationRunning = true
                    UIView.animate(
                        withDuration: 0.18,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        presentationView.transform = CGAffineTransform(
                            translationX: -self.width,
                            y: 0
                        )
                        self.dragDimmingView?.alpha = 0
                    } completion: { finished in
                        self.isDismissAnimationRunning = false
                        // A new drag re-owns the view mid-animation; leave its
                        // state alone. Any other interruption (rotation, split
                        // relayout) must still complete the hide, or the
                        // sidebar stays "visible" while translated off-screen
                        // with no toggle button rendered to recover it.
                        guard finished || !self.isDragActive else { return }
                        UIView.performWithoutAnimation {
                            splitViewController.hide(.primary)
                            self.onSwipeLeft()
                            presentationView.transform = .identity
                            // The hide dismantles the overlay presentation,
                            // but UIKit may reuse the scrim next time the
                            // sidebar opens — leave it at its resting alpha,
                            // not the zero we faded it to.
                            self.releaseDimmingView(restoring: true)
                            splitViewController.view.layoutIfNeeded()
                            self.dragPresentationView = nil
                        }
                    }
                } else {
                    restoreSidebarPosition(presentationView)
                }

            case .cancelled, .failed:
                dragStartOffset = 0
                restoreSidebarPosition(presentationView)

            default:
                break
            }
        }

        /// UIKit's overlay presentation dims the detail pane behind the
        /// sidebar but knows nothing about our interactive drag, so the dim
        /// would stay opaque until dismissal completes and then pop off. Track
        /// the dimming view (identified structurally: a full-size, non-opaque
        /// scrim under the sidebar surface) and fade it with the drag. If the
        /// hierarchy doesn't match, everything degrades to the old pop.
        private func resolveDimmingView(
            in splitViewController: UISplitViewController,
            excluding presentationView: UIView
        ) {
            guard dragDimmingView == nil else { return }
            guard let dimmingView = findDimmingView(
                from: splitViewController.view,
                excluding: presentationView,
                depth: 0
            ) else {
                #if DEBUG
                logSidebarHierarchy(splitViewController.view, presentationView: presentationView)
                #endif
                return
            }
            dragDimmingView = dimmingView
            dimmingBaseAlpha = dimmingView.alpha
        }

        #if DEBUG
        /// One-shot dump of the split view's subtree when no scrim was found,
        /// so a mismatched iPadOS hierarchy is diagnosable from device logs.
        private static var didLogSidebarHierarchy = false
        private func logSidebarHierarchy(_ root: UIView, presentationView: UIView) {
            guard !Self.didLogSidebarHierarchy else { return }
            Self.didLogSidebarHierarchy = true
            func describe(_ view: UIView, indent: String) -> String {
                let marker = view === presentationView ? " <sidebar-surface>" : ""
                let color = view.backgroundColor.map { " bg=\($0)" } ?? ""
                var lines = "\(indent)\(type(of: view)) frame=\(view.frame) alpha=\(view.alpha)\(color)\(marker)\n"
                guard indent.count < 12 else { return lines }
                for subview in view.subviews {
                    lines += describe(subview, indent: indent + "  ")
                }
                return lines
            }
            DiagLog.d(
                .other,
                "SidebarDrag",
                "No dimming view found; hierarchy:\n\(describe(root, indent: ""))"
            )
        }
        #endif

        /// The scrim is identified by class name ("Dimming"), the same way
        /// UIKit names it across releases (`UIDimmingView`, knockout backdrop
        /// variants). The sidebar surface's own subtree is excluded so we
        /// never fade something that slides with the drag.
        private func findDimmingView(
            from root: UIView,
            excluding presentationView: UIView,
            depth: Int
        ) -> UIView? {
            guard depth <= 6 else { return nil }
            for candidate in root.subviews {
                guard candidate !== presentationView else { continue }
                if !candidate.isHidden,
                   String(describing: type(of: candidate))
                       .localizedCaseInsensitiveContains("dimming") {
                    return candidate
                }
                if let nested = findDimmingView(
                    from: candidate,
                    excluding: presentationView,
                    depth: depth + 1
                ) {
                    return nested
                }
            }
            return nil
        }

        private func updateDimming(forSidebarOffset horizontalOffset: CGFloat) {
            guard let dimmingView = dragDimmingView, width > 0 else { return }
            let visibleFraction = max(0, min(1, 1 + horizontalOffset / width))
            dimmingView.alpha = dimmingBaseAlpha * visibleFraction
        }

        private func releaseDimmingView(restoring: Bool = false) {
            if restoring {
                dragDimmingView?.alpha = dimmingBaseAlpha
            }
            dragDimmingView = nil
        }

        /// Whether a pan is actively re-owning the sidebar mid-animation.
        private var isDragActive: Bool {
            switch swipeLeftRecognizer.state {
            case .began, .changed: return true
            default: return false
            }
        }

        private func restoreSidebarPosition(_ presentationView: UIView) {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                presentationView.transform = .identity
                self.dragDimmingView?.alpha = self.dimmingBaseAlpha
            } completion: { finished in
                if finished {
                    self.dragPresentationView = nil
                    self.releaseDimmingView(restoring: true)
                }
            }
        }

        private func sidebarPresentationView(
            in splitViewController: UISplitViewController
        ) -> UIView? {
            guard let primaryView = splitViewController
                .viewController(for: .primary)?
                .view
            else { return nil }

            // On iPadOS the navigation controller is wrapped by a clipping
            // view and then by the adaptive column surface that owns the
            // sidebar's glass background and shadow. Move that complete
            // fixed-width surface when it matches the primary geometry;
            // otherwise fall back to the public primary view.
            guard let columnView = primaryView.superview?.superview,
                  columnView !== splitViewController.view,
                  abs(columnView.bounds.width - width) <= 1,
                  abs(columnView.bounds.height - primaryView.bounds.height) <= 1
            else { return primaryView }
            return columnView
        }

        private func installSwipeRecognizer(in splitViewController: UISplitViewController) {
            guard let primaryView = splitViewController
                .viewController(for: .primary)?
                .view,
                  swipeHostView !== primaryView
            else { return }

            swipeHostView?.removeGestureRecognizer(swipeLeftRecognizer)
            primaryView.addGestureRecognizer(swipeLeftRecognizer)
            swipeHostView = primaryView
        }

        func tearDown() {
            dragPresentationView?.layer.removeAllAnimations()
            dragPresentationView?.transform = .identity
            dragPresentationView = nil
            releaseDimmingView(restoring: true)
            swipeHostView?.layer.removeAllAnimations()
            swipeHostView?.transform = .identity
            swipeHostView?.removeGestureRecognizer(swipeLeftRecognizer)
            swipeHostView = nil
            managedSplitViewController?.presentsWithGesture = true
            managedSplitViewController = nil
        }

        private var splitViewControllerAncestor: UISplitViewController? {
            var ancestor = parent
            while let controller = ancestor {
                if let splitViewController = controller as? UISplitViewController {
                    return splitViewController
                }
                ancestor = controller.parent
            }
            return nil
        }
    }
}
#endif
