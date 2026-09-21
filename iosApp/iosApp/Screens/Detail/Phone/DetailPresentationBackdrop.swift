#if os(iOS)
import SwiftUI
import UIKit
import CoreImage

/// Captures the visible source before UIKit starts covering it with the sheet.
/// The image is retained only for this presentation and never written to disk.
struct DetailBackdropSourceReader: UIViewRepresentable {
    let router: AppRouter

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        router.captureItemDetailBackdrop = { [weak view] in
            guard let window = view?.window,
                  window.traitCollection.userInterfaceIdiom == .phone else { return nil }
            let format = UIGraphicsImageRendererFormat()
            // The backdrop is softened and temporary; a point-resolution
            // image avoids retaining full Retina-sized screen buffers.
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
        }
    }
}

/// Blends a pre-blurred opaque image with the source as the native sheet moves.
/// No live backdrop filter or display-link work continues while the card rests.
struct DetailPresentationBackdrop: UIViewControllerRepresentable {
    let sourceImage: UIImage?

    func makeUIViewController(context: Context) -> BackdropController {
        let controller = BackdropController()
        controller.sourceImage = sourceImage
        return controller
    }

    func updateUIViewController(_ controller: BackdropController, context: Context) {}

    static func dismantleUIViewController(_ controller: BackdropController, coordinator: ()) {
        controller.removeBackdrop()
    }

    final class BackdropController: UIViewController, UIGestureRecognizerDelegate {
        var sourceImage: UIImage?
        private var backdrop: UIView?
        private var blurredImageView: UIImageView?
        private var displayLink: CADisplayLink?
        private var trackingGesture: UIPanGestureRecognizer?
        private var previousTop: CGFloat?
        private var stableFrames = 0
        private weak var cardView: UIView?
        private weak var containerView: UIView?
        private weak var sourceView: UIView?
        private var sourceWasAccessibilityHidden = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            installBackdrop()
            resumeTracking()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installBackdrop()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if sheetHost?.isBeingDismissed == true || sheetHost == nil {
                removeBackdrop()
            } else {
                // Playback covers retain the card, but need no backdrop updates.
                displayLink?.isPaused = true
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            resumeTracking()
        }

        private var sheetHost: UIViewController? {
            // Children inherit presentingViewController, but do not own the
            // sheet's presentation controller. Reach the actual modal host.
            var controller: UIViewController = self
            while let parent = controller.parent { controller = parent }
            return controller.presentingViewController == nil ? nil : controller
        }

        private func installBackdrop() {
            guard backdrop == nil, let sourceImage,
                  let host = sheetHost,
                  let presentation = host.presentationController,
                  let container = presentation.containerView,
                  let presentedView = presentation.presentedView else { return }

            var card = presentedView
            while let parent = card.superview, parent !== container {
                card = parent
            }
            guard card.superview === container else { return }

            let background = UIView(frame: container.bounds)
            background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            let imageView = UIImageView(image: sourceImage)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            let blurredView = UIImageView(image: blurredImage(from: sourceImage))
            blurredView.contentMode = .scaleAspectFill
            blurredView.clipsToBounds = true
            blurredView.isOpaque = true
            blurredView.alpha = 0
            for layer in [imageView, blurredView] {
                layer.frame = background.bounds
                layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                background.addSubview(layer)
            }
            // Native background interaction removes the black scrim. This
            // surface still prevents touching the source through the blur.
            container.insertSubview(background, belowSubview: card)
            backdrop = background
            blurredImageView = blurredView
            cardView = presentedView
            containerView = container
            sourceView = host.presentingViewController?.view
            sourceWasAccessibilityHidden = sourceView?.accessibilityElementsHidden ?? false
            sourceView?.accessibilityElementsHidden = true

            let target = DisplayLinkTarget(controller: self)
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(trackDrag))
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.delegate = self
            presentedView.addGestureRecognizer(gesture)
            trackingGesture = gesture
            updateBlur()
        }

        private func blurredImage(from image: UIImage) -> UIImage? {
            guard let input = CIImage(image: image) else { return image }
            let output = input.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28])
                .cropped(to: input.extent)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let result = context.createCGImage(output, from: input.extent) else { return image }
            return UIImage(cgImage: result, scale: image.scale, orientation: image.imageOrientation)
        }

        @objc private func trackDrag() {
            resumeTracking()
        }

        private func resumeTracking() {
            stableFrames = 0
            previousTop = nil
            displayLink?.isPaused = false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }

        fileprivate func updateBlur() {
            guard let cardView, let containerView, let blurredImageView else { return }
            let cardLayer = cardView.layer.presentation() ?? cardView.layer
            let containerLayer = containerView.layer.presentation() ?? containerView.layer
            let frame = cardLayer.convert(cardLayer.bounds, to: containerLayer)
            let height = containerView.bounds.height
            let openTop = max(containerView.safeAreaInsets.top, height - cardView.bounds.height)
            let progress = min(1, max(0, (height - frame.minY) / max(1, height - openTop)))
            // Smooth endpoints keep the lowest card position almost clear,
            // with the full colour-preserving blur reached at the top.
            blurredImageView.alpha = progress * progress * (3 - 2 * progress)
            if let previousTop, abs(previousTop - frame.minY) < 0.1 {
                stableFrames += 1
            } else {
                stableFrames = 0
            }
            previousTop = frame.minY
            let dragging = trackingGesture?.state == .began || trackingGesture?.state == .changed
            if stableFrames >= 8, !dragging { displayLink?.isPaused = true }
        }

        func removeBackdrop() {
            displayLink?.invalidate()
            displayLink = nil
            if let trackingGesture { cardView?.removeGestureRecognizer(trackingGesture) }
            trackingGesture = nil
            blurredImageView = nil
            backdrop?.removeFromSuperview()
            backdrop = nil
            sourceImage = nil
            sourceView?.accessibilityElementsHidden = sourceWasAccessibilityHidden
            sourceView = nil
        }

        private final class DisplayLinkTarget {
            weak var controller: BackdropController?

            init(controller: BackdropController) {
                self.controller = controller
            }

            @objc func tick() {
                controller?.updateBlur()
            }
        }
    }
}
#endif
