// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
import AVFoundation
import UIKit

/// The layer Lucid draws into, passed to mpv as `wid`. One per core.
final class VividSampleBufferLayer: AVSampleBufferDisplayLayer {}

/// The UIKit half of Vivid's Lucid bridge. It owns the video surface and
/// wires it to the engine, Match Content and EDR, external screens and the
/// app lifecycle.
///
/// The adapter calls it on main. Two things are not on main:
/// `preparesDisplayCriteriaEarly` is also read on the event queue, and
/// `deinit` disposes on whichever thread lets go of the core last.
class VividPlayerCore: VividPlayerCoreBase {
    final var isPipActive = false
    final var hdrEnabled: Bool { true }
    final var matchContentEnabled = true
    final var onEnterBackground: (() -> Void)?

    final var sampleBufferDisplayLayer: VividSampleBufferLayer? { surface?.layer }

    private var surface: VividPlayerVideoSurface?
    private var lifecycle: VividPlayerLifecycleObserver?
    private var presentsVideo = false
    private var isInitialised = false

    deinit {
        dispose()
    }

    // MARK: Set-up and teardown

    /// A repeated call only remembers the new host view.
    final func initialize(in window: UIWindow, hostView: UIView) -> Bool {
        guard !isInitialised else {
            surface?.rememberHostView(hostView)
            return true
        }
        // The layer sits in its final parent before mpv exists, so Lucid's
        // video output always finds it there.
        let surface = VividPlayerVideoSurface(window: window, hostView: hostView)
        self.surface = surface
        guard let layer = surface.layer,
              startContext(wid: Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))) else {
            surface.tearDown()
            return false
        }
        lifecycle = VividPlayerLifecycleObserver(
            window: window,
            didEnterBackground: { [weak self] in self?.didEnterBackground() },
            willEnterForeground: { [weak self] in self?.willEnterForeground() },
            didActivate: { [weak self] in self?.didActivate() },
            displaySwitch: { [weak self] started in
                self?.delegate?.onEvent(name: started ? "display-switch-started" : "display-switch-ended", data: nil)
            })
        #if os(iOS)
        VividExternalDisplay.shared.attach(self)
        #endif
        isInitialised = true
        return true
    }

    /// Only the first call does anything, and only it calls `completion`, on
    /// the event queue once mpv is destroyed. Nothing here may capture the
    /// core, because `deinit` disposes too.
    final func dispose(preserveDisplayCriteria: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        guard beginDisposal() else { return }
        #if os(tvOS)
        if !preserveDisplayCriteria {
            // The adapter lets go of the core as soon as this returns, so the
            // TV leaves the title's mode now, while the container is still in
            // its window.
            VividPlayerDisplayCriteria.clear(in: surface?.displayWindow)
        }
        #endif
        lifecycle?.stop()
        lifecycle = nil
        #if os(iOS)
        VividExternalDisplay.shared.detach(self)
        #endif
        shutDownEngine(completion: completion)
        surface?.tearDown()
        isInitialised = false
    }

    // MARK: Surface

    final func setVisible(_ visible: Bool) {
        guard let surface, surface.hasContainer else { return }
        presentsVideo = visible
        refreshPlacement()
        surface.showContainer(visible)
    }

    final func updateFrame(_ frame: CGRect? = nil) {
        guard surface?.updateGeometry() == true else { return }
        #if os(iOS)
        applyExtendedDynamicRange(signalPeak: displayCriteria.signalPeak)
        #endif
    }

    final func externalDisplayDidChange() {
        refreshPlacement()
    }

    /// Picture in Picture shows only the pictures, so on iOS subtitles are
    /// burned into them while it runs. Sent on every call; Apple TV has no
    /// Picture in Picture.
    final func setPipSubtitleCompositing(_ enabled: Bool) {
        #if os(iOS)
        setProperty("avfoundation-pip-composite-osd", value: enabled ? "yes" : "no")
        #endif
    }

    /// External screens take the video only while it is visible and Picture
    /// in Picture is not running; Picture in Picture shows the device's layer.
    private func refreshPlacement() {
        guard let surface, surface.hasContainer else { return }
        #if os(iOS)
        let externalTarget = presentsVideo && !isPipActive ? VividExternalDisplay.shared.externalRootView : nil
        #else
        let externalTarget: UIView? = nil
        #endif
        surface.place(externalTarget: externalTarget, visible: presentsVideo)
        updateFrame()
    }

    // MARK: Display

    final override var preparesDisplayCriteriaEarly: Bool {
        #if os(tvOS)
        return matchContentEnabled
        #else
        return false
        #endif
    }

    final override func commitDisplayCriteria(_ request: VividPlayerDisplayCriteria.Request) -> Bool {
        VividPlayerDisplayCriteria.commit(request, matchContentEnabled: matchContentEnabled,
                                          window: surface?.displayWindow)
    }

    final override func applyExtendedDynamicRange(signalPeak: Double) {
        #if os(iOS)
        VividPlayerDisplayCriteria.applyExtendedDynamicRange(to: surface?.layer, signalPeak: signalPeak)
        #endif
    }

    // MARK: App lifecycle

    private func didEnterBackground() {
        // First, so the adapter's hook sees the state before the bridge changes it.
        onEnterBackground?()
        isBackgrounded = true
        // Deselecting video tears down Lucid's video output; audio carries on.
        if !isPipActive { setProperty("vid", value: "no") }
    }

    private func willEnterForeground() {
        isBackgrounded = false
        if !isPipActive { setProperty("vid", value: "auto") }
    }

    /// iOS only. Also fires for returns that never reached the background,
    /// such as Control Centre or an alert.
    private func didActivate() {
        isBackgrounded = false
        guard !isPipActive else { return }
        setProperty("vid", value: "auto")
        refreshPlacement()
        #if os(iOS)
        surface?.recoverLayerIfNeeded()
        #endif
        applyExtendedDynamicRange(signalPeak: displayCriteria.signalPeak)
        // A seek keeps the current picture until the next is ready, so this
        // redraws a paused frame without a black flash.
        if pauseTracker.showsPaused { command(["seek", "0", "relative+exact"]) }
    }
}
#endif
