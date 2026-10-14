// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import AVFoundation
import UIKit

/// One core's video surface: a black container at the bottom of the adapter's
/// host view, holding the layer Lucid draws into, plus the cover view the iOS
/// device shows while video is on an external screen. Main thread only.
///
/// Lucid sizes its output and subtitles from the layer's bounds and scale, so
/// those are only ever written with final values and without animation. Only
/// the container moves between parents; the layer never leaves it.
final class VividPlayerVideoSurface {
    /// Kept after teardown, so a later display clear can still find the TV.
    private(set) weak var window: UIWindow?
    private(set) weak var hostView: UIView?
    private(set) var container: UIView?
    private(set) var layer: VividSampleBufferLayer?
    private var cover: UIView?

    /// Builds the container and layer and mounts them at index 0 of the host view.
    init(window: UIWindow, hostView: UIView) {
        self.window = window
        self.hostView = hostView
        let container = UIView(frame: window.bounds)
        container.backgroundColor = .black
        container.isUserInteractionEnabled = false
        let layer = VividSampleBufferLayer()
        Self.withoutAnimation {
            layer.frame = container.bounds
            layer.contentsScale = window.screen.nativeScale
            layer.isOpaque = true
            layer.backgroundColor = UIColor.black.cgColor
            layer.videoGravity = .resizeAspect
            container.layer.addSublayer(layer)
            hostView.insertSubview(container, at: 0)
        }
        self.container = container
        self.layer = layer
    }

    var hasContainer: Bool { container != nil }

    /// A repeated `initialize` changes only which host view video returns to.
    func rememberHostView(_ hostView: UIView) {
        self.hostView = hostView
    }

    /// The window whose display the video is on: the container's own, or the
    /// one the core was initialised with.
    var displayWindow: UIWindow? { container?.window ?? window }

    /// Fits the container to its parent and the layer to the container, in
    /// one transaction so a resize snaps rather than stretches. Returns false
    /// when there is nothing to lay out.
    @discardableResult
    func updateGeometry() -> Bool {
        guard let container, let layer else { return false }
        Self.withoutAnimation {
            if let parent = container.superview {
                container.frame = parent.bounds
            } else if let window {
                container.frame = window.bounds
            }
            let area = container.bounds
            let bounds = CGRect(origin: .zero, size: area.size)
            let position = CGPoint(x: area.midX, y: area.midY)
            if layer.bounds != bounds || layer.position != position {
                layer.bounds = bounds
                layer.position = position
            }
            cover?.frame = window?.bounds ?? .zero
            if let scale = Self.scale(of: container.window?.screen ?? window?.screen),
               layer.contentsScale != scale {
                layer.contentsScale = scale
            }
        }
        return true
    }

    /// Puts the container in the external screen's root view when there is
    /// one, otherwise back in the host view while visible, and hides it when
    /// not visible. The cover view shows only while video is external.
    func place(externalTarget: UIView?, visible: Bool) {
        if let externalTarget {
            move(to: externalTarget)
            showCover()
        } else if visible, let window {
            move(to: hostView ?? window)
            removeCover()
        } else {
            removeCover()
        }
        showContainer(visible)
    }

    func showContainer(_ shown: Bool) {
        guard let container else { return }
        Self.withoutAnimation { container.isHidden = !shown }
    }

    #if os(iOS)
    /// A layer the system interrupted while the app was away may need a flush
    /// before it decodes again. The image stays, so a paused frame survives.
    func recoverLayerIfNeeded() {
        guard let layer, layer.requiresFlushToResumeDecoding || layer.status == .failed else { return }
        layer.flush()
    }
    #endif

    /// Takes the layer, container and cover out of every view. Lucid keeps
    /// its own reference to the layer until its video output is torn down.
    func tearDown() {
        Self.withoutAnimation {
            layer?.removeFromSuperlayer()
            container?.removeFromSuperview()
            cover?.removeFromSuperview()
        }
        layer = nil
        container = nil
        cover = nil
    }

    private func move(to target: UIView) {
        guard let container else { return }
        Self.withoutAnimation {
            if container.superview !== target || target.subviews.first !== container {
                target.insertSubview(container, at: 0)
            }
            container.frame = target.bounds
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
    }

    private func showCover() {
        guard let window else {
            removeCover()
            return
        }
        Self.withoutAnimation {
            let cover = self.cover ?? Self.makeCover()
            if cover.superview !== window || window.subviews.first !== cover {
                window.insertSubview(cover, at: 0)
            }
            cover.frame = window.bounds
            cover.isHidden = false
            self.cover = cover
        }
    }

    private func removeCover() {
        guard let cover else { return }
        Self.withoutAnimation { cover.removeFromSuperview() }
        self.cover = nil
    }

    private static func makeCover() -> UIView {
        let cover = UIView()
        cover.backgroundColor = .black
        cover.isUserInteractionEnabled = false
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return cover
    }

    private static func scale(of screen: UIScreen?) -> CGFloat? {
        guard let screen = screen ?? mainScreen else { return nil }
        return screen.nativeScale > 0 ? screen.nativeScale : screen.scale
    }

    private static var mainScreen: UIScreen? {
        #if os(tvOS)
        // `UIScreen.main` is deprecated on tvOS 26; Apple TV has one screen.
        return UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
        #else
        return UIScreen.main
        #endif
    }

    private static func withoutAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }
}
#endif
