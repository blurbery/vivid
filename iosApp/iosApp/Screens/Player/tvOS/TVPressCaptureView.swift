#if os(tvOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Siri Remote input bridges for the Apple TV player.
///
/// SwiftUI's `.onMoveCommand` reports one event per press, with no way to
/// tell a held press from a tap or to see a light touch on the clickpad.
/// The player needs both: a quick press skips, a held press starts a seek
/// session, and a light touch toggles the clock labels. These views read
/// the press and touch lifecycle from UIKit and report it through closures.
///
/// `TVPressCaptureView` is a focusable view that owns the remote while the
/// player has no controls on screen. The other three never take focus: they
/// attach recognisers to the window, so SwiftUI keeps owning focus while
/// they observe the remote alongside it.

/// Focusable press sink. A press released within 0.3 seconds is a tap; one
/// still held at 0.3 seconds starts a hold. Select is reported on press-down.
/// Menu is never intercepted, so SwiftUI's `.onExitCommand` chain keeps it.
struct TVPressCaptureView: UIViewRepresentable {
    enum ArrowDirection: Hashable {
        case left, right, up, down
    }

    /// Press and release within the hold threshold.
    var onArrowTap: (ArrowDirection) -> Void = { _ in }
    /// The press is still held at the threshold, so a seek session starts.
    var onArrowHoldBegin: (ArrowDirection) -> Void = { _ in }
    /// Any arrow press-down, before it is known to be a tap or a hold.
    var onDirectionalPressBegan: () -> Void = {}
    /// Finger contact with the Siri Remote touch surface, without a click.
    var onTouchSurfaceContactBegan: () -> Void = {}
    var onTouchSurfaceContactEnded: () -> Void = {}
    var onTouchSurfaceContactCancelled: () -> Void = {}
    /// Select (centre click) press-down.
    var onSelect: () -> Void = {}

    func makeUIView(context: Context) -> PressCaptureUIView {
        let view = PressCaptureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: PressCaptureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: PressCaptureUIView) {
        view.onArrowTap = onArrowTap
        view.onArrowHoldBegin = onArrowHoldBegin
        view.onDirectionalPressBegan = onDirectionalPressBegan
        view.onTouchSurfaceContactBegan = onTouchSurfaceContactBegan
        view.onTouchSurfaceContactEnded = onTouchSurfaceContactEnded
        view.onTouchSurfaceContactCancelled = onTouchSurfaceContactCancelled
        view.onSelect = onSelect
    }
}

/// Left and Right tap and hold, observed on the window while the focused
/// scrubber keeps SwiftUI focus.
struct TVDirectionalPressGestureView: UIViewRepresentable {
    var isActive: Bool
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }

    func makeUIView(context: Context) -> DirectionalPressGestureUIView {
        let view = DirectionalPressGestureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: DirectionalPressGestureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: DirectionalPressGestureUIView) {
        view.isActive = isActive
        view.onArrowTap = onArrowTap
        view.onArrowHoldBegin = onArrowHoldBegin
    }
}

/// Light-touch contact with the Siri Remote surface, observed on the window
/// while the full controls are up. It follows the raw indirect-touch
/// lifecycle, like `PressCaptureUIView`, rather than tap or long-press
/// recognisers that tvOS may arbitrate away.
struct TVTouchSurfaceContactGestureView: UIViewRepresentable {
    var isActive: Bool
    var onContactBegan: () -> Void = {}
    var onContactEnded: () -> Void = {}
    var onContactCancelled: () -> Void = {}
    var onDirectionalPressBegan: () -> Void = {}

    func makeUIView(context: Context) -> TouchSurfaceContactGestureUIView {
        let view = TouchSurfaceContactGestureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TouchSurfaceContactGestureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TouchSurfaceContactGestureUIView) {
        view.isActive = isActive
        view.onContactBegan = onContactBegan
        view.onContactEnded = onContactEnded
        view.onContactCancelled = onContactCancelled
        view.onDirectionalPressBegan = onDirectionalPressBegan
    }
}

/// Continuous horizontal drag on the Siri Remote surface, for scrubbing the
/// timeline. SwiftUI only reports the surface as discrete move commands.
struct TVPanCaptureView: UIViewRepresentable {
    var isActive: Bool
    var onPanBegan: () -> Void = {}
    /// Horizontal translation in points since the previous call.
    var onPanChanged: (CGFloat) -> Void = { _ in }
    var onPanEnded: () -> Void = {}

    func makeUIView(context: Context) -> PanCaptureUIView {
        let view = PanCaptureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: PanCaptureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: PanCaptureUIView) {
        view.isActive = isActive
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
    }
}

// MARK: - Window recogniser hosts

/// Shared base for the 1-point views that put recognisers on their window.
/// Recognisers attach when the view joins a window and come off as soon as
/// it leaves one, not at deinit, so an old window never keeps observing.
/// They only begin while `isActive`, and recognise alongside everything
/// else so they never take a press or touch away from the focus engine.
class TVWindowGestureHostView: UIView, UIGestureRecognizerDelegate {
    var isActive = false

    /// The window the recognisers are on, or nil while detached.
    private(set) weak var attachedWindow: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            detachRecognizers()
        } else {
            attachRecognizersIfNeeded()
        }
    }

    deinit {
        removeRecognizers()
    }

    /// The recognisers to add to a new window, in the order they are added.
    func makeRecognizers() -> [UIGestureRecognizer] { [] }

    /// Called just before the recognisers come off the window.
    func willDetachRecognizers() {}

    private func attachRecognizersIfNeeded() {
        guard let window, attachedWindow !== window else { return }
        detachRecognizers()
        attachedWindow = window
        recognizers = makeRecognizers()
        for recognizer in recognizers {
            window.addGestureRecognizer(recognizer)
        }
    }

    private func detachRecognizers() {
        willDetachRecognizers()
        removeRecognizers()
    }

    private func removeRecognizers() {
        if let attachedWindow {
            for recognizer in recognizers {
                attachedWindow.removeGestureRecognizer(recognizer)
            }
        }
        recognizers.removeAll()
        attachedWindow = nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

final class TouchSurfaceContactGestureUIView: TVWindowGestureHostView {
    var onContactBegan: () -> Void = {}
    var onContactEnded: () -> Void = {}
    var onContactCancelled: () -> Void = {}
    var onDirectionalPressBegan: () -> Void = {}

    private var isTrackingContact = false

    deinit {
        cancelTrackedContact()
    }

    override func makeRecognizers() -> [UIGestureRecognizer] {
        let contact = TouchSurfaceContactGestureRecognizer(target: self, action: #selector(handleContact(_:)))
        contact.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        // Custom recognisers accept Select by default on tvOS. This one only
        // handles touches, so a press would never reach a terminal state and
        // could block the focused button's activation (Apple 111175673).
        contact.allowedPressTypes = []
        contact.cancelsTouchesInView = false
        contact.delaysTouchesBegan = false
        contact.delaysTouchesEnded = false
        contact.delegate = self

        let presses = [UIPress.PressType.leftArrow, .rightArrow, .upArrow, .downArrow].map { pressType in
            let press = NonPreventingDirectionalPressGestureRecognizer(
                target: self,
                action: #selector(handleDirectionalPress(_:))
            )
            press.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            press.allowedTouchTypes = []
            press.minimumPressDuration = 0
            press.cancelsTouchesInView = false
            press.delegate = self
            return press
        }
        return [contact] + presses
    }

    override func willDetachRecognizers() {
        cancelTrackedContact()
    }

    private func cancelTrackedContact() {
        guard isTrackingContact else { return }
        isTrackingContact = false
        onContactCancelled()
    }

    @objc private func handleDirectionalPress(_ recognizer: UILongPressGestureRecognizer) {
        guard isActive, recognizer.state == .began else { return }
        onDirectionalPressBegan()
    }

    @objc private func handleContact(_ recognizer: TouchSurfaceContactGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isActive else { return }
            isTrackingContact = true
            onContactBegan()
        case .ended:
            guard isTrackingContact else { return }
            isTrackingContact = false
            onContactEnded()
        case .cancelled, .failed:
            cancelTrackedContact()
        default:
            break
        }
    }
}

/// Raw contact with the Siri Remote surface. Begins on the first indirect
/// touch, ends when the last one lifts, and cancels once any touch moves
/// far enough to be a swipe. It never prevents, and is never prevented by,
/// the scrubber's pan or focus recognisers, so watching for a light touch
/// changes nothing else about the remote.
final class TouchSurfaceContactGestureRecognizer: UIGestureRecognizer {
    private static let movementTolerance: CGFloat = 12

    private var initialLocations: [ObjectIdentifier: CGPoint] = [:]
    private var activeTouchIDs: Set<ObjectIdentifier> = []

    private var isTracking: Bool { state == .began || state == .changed }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let indirectTouches = touches.filter { $0.type == .indirect }
        guard !indirectTouches.isEmpty else { return }

        let wasIdle = activeTouchIDs.isEmpty
        for touch in indirectTouches {
            let id = ObjectIdentifier(touch)
            activeTouchIDs.insert(id)
            initialLocations[id] = touch.location(in: view)
        }
        if wasIdle {
            state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isTracking else { return }

        for touch in touches where touch.type == .indirect {
            guard let origin = initialLocations[ObjectIdentifier(touch)] else { continue }
            let location = touch.location(in: view)
            if hypot(location.x - origin.x, location.y - origin.y) > Self.movementTolerance {
                state = .cancelled
                return
            }
        }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        forget(touches)
        if activeTouchIDs.isEmpty, isTracking {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        forget(touches)
        if isTracking {
            state = .cancelled
        }
    }

    override func reset() {
        initialLocations.removeAll()
        activeTouchIDs.removeAll()
        super.reset()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func forget(_ touches: Set<UITouch>) {
        for touch in touches where touch.type == .indirect {
            let id = ObjectIdentifier(touch)
            activeTouchIDs.remove(id)
            initialLocations.removeValue(forKey: id)
        }
    }
}

/// Sees a directional click at press-down without taking part in gesture
/// arbitration. The full controls use it only to stop the current light
/// touch from toggling the clock labels when it lifts.
final class NonPreventingDirectionalPressGestureRecognizer: UILongPressGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

final class PanCaptureUIView: TVWindowGestureHostView {
    var onPanBegan: () -> Void = {}
    var onPanChanged: (CGFloat) -> Void = { _ in }
    var onPanEnded: () -> Void = {}

    private var lastTranslationX: CGFloat = 0

    override func makeRecognizers() -> [UIGestureRecognizer] {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.allowedPressTypes = []
        pan.cancelsTouchesInView = false
        pan.delegate = self
        return [pan]
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translationX = recognizer.translation(in: attachedWindow).x
        switch recognizer.state {
        case .began:
            guard isActive else { return }
            lastTranslationX = translationX
            onPanBegan()
            onPanChanged(translationX)
        case .changed:
            guard isActive else { return }
            onPanChanged(translationX - lastTranslationX)
            lastTranslationX = translationX
        case .ended, .cancelled, .failed:
            if isActive, recognizer.state == .ended {
                onPanChanged(translationX - lastTranslationX)
            }
            // Report the end even when the scrub went inactive under the
            // finger, so SwiftUI never thinks a pan is still running.
            onPanEnded()
        default:
            break
        }
    }
}

final class DirectionalPressGestureUIView: TVWindowGestureHostView {
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }

    private static let holdThreshold: TimeInterval = 0.3
    private static let leftName = "vivid.leftPress"
    private static let rightName = "vivid.rightPress"

    override func makeRecognizers() -> [UIGestureRecognizer] {
        [(UIPress.PressType.leftArrow, Self.leftName), (.rightArrow, Self.rightName)].flatMap { pressType, name in
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            tap.allowedTouchTypes = []
            tap.delegate = self
            tap.name = name

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
            hold.allowedPressTypes = [NSNumber(value: pressType.rawValue)]
            hold.allowedTouchTypes = []
            hold.minimumPressDuration = Self.holdThreshold
            hold.delegate = self
            hold.name = name

            tap.require(toFail: hold)
            return [tap, hold] as [UIGestureRecognizer]
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isActive, recognizer.state == .ended, let direction = direction(of: recognizer) else { return }
        onArrowTap(direction)
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        guard isActive, recognizer.state == .began, let direction = direction(of: recognizer) else { return }
        onArrowHoldBegin(direction)
    }

    private func direction(of recognizer: UIGestureRecognizer) -> TVPressCaptureView.ArrowDirection? {
        switch recognizer.name {
        case Self.leftName: return .left
        case Self.rightName: return .right
        default: return nil
        }
    }
}

// MARK: - Focused press sink

final class PressCaptureUIView: UIView {
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onDirectionalPressBegan: () -> Void = {}
    var onTouchSurfaceContactBegan: () -> Void = {}
    var onTouchSurfaceContactEnded: () -> Void = {}
    var onTouchSurfaceContactCancelled: () -> Void = {}
    var onSelect: () -> Void = {}

    /// 300 ms is short enough that a deliberate press never feels missed and
    /// long enough that a natural press and release doesn't start a hold.
    private static let holdThreshold: TimeInterval = 0.3

    private struct PendingArrow {
        let direction: TVPressCaptureView.ArrowDirection
        let holdTimer: DispatchWorkItem
        var didFireHold = false
    }

    /// Arrow presses in flight, keyed by press type so simultaneous presses
    /// (rare on the Siri Remote, possible on a keyboard) stay independent.
    private var pendingArrows: [UIPress.PressType: PendingArrow] = [:]
    private var activeIndirectTouchIDs: Set<ObjectIdentifier> = []

    override var canBecomeFocused: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasIdle = activeIndirectTouchIDs.isEmpty
        activeIndirectTouchIDs.formUnion(touches.filter { $0.type == .indirect }.map(ObjectIdentifier.init))
        if wasIdle, !activeIndirectTouchIDs.isEmpty {
            onTouchSurfaceContactBegan()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIndirectTouches(touches, cancelled: false)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIndirectTouches(touches, cancelled: true)
        super.touchesCancelled(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let direction = Self.arrowDirection(of: press.type) {
                handled = true
                onDirectionalPressBegan()
                startArrow(press.type, direction: direction)
            } else if press.type == .select {
                handled = true
                onSelect()
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses where Self.arrowDirection(of: press.type) != nil {
            handled = true
            endArrow(press.type)
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where Self.arrowDirection(of: press.type) != nil {
            endArrow(press.type)
        }
        super.pressesCancelled(presses, with: event)
    }

    private func startArrow(_ type: UIPress.PressType, direction: TVPressCaptureView.ArrowDirection) {
        // If the press ends before this runs, endArrow cancels it and
        // reports a tap instead.
        let holdTimer = DispatchWorkItem { [weak self] in
            guard let self, self.pendingArrows[type] != nil else { return }
            self.pendingArrows[type]?.didFireHold = true
            self.onArrowHoldBegin(direction)
        }
        pendingArrows[type] = PendingArrow(direction: direction, holdTimer: holdTimer)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: holdTimer)
    }

    private func endArrow(_ type: UIPress.PressType) {
        guard let arrow = pendingArrows.removeValue(forKey: type) else { return }
        arrow.holdTimer.cancel()
        if !arrow.didFireHold {
            onArrowTap(arrow.direction)
        }
    }

    private func finishIndirectTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        let endedIDs = touches.filter { $0.type == .indirect }.map(ObjectIdentifier.init)
        guard !endedIDs.isEmpty else { return }
        activeIndirectTouchIDs.subtract(endedIDs)
        guard activeIndirectTouchIDs.isEmpty else { return }
        if cancelled {
            onTouchSurfaceContactCancelled()
        } else {
            onTouchSurfaceContactEnded()
        }
    }

    private static func arrowDirection(of type: UIPress.PressType) -> TVPressCaptureView.ArrowDirection? {
        switch type {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        default: return nil
        }
    }
}
#endif
