#if os(tvOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Siri Remote input for the Apple TV player.
//
// SwiftUI hands the player one move command per press. It can't tell a held
// arrow from a quick one, and it never reports a finger resting on the
// clickpad. The player needs both (a quick arrow skips, a held one starts a
// seek, and a light touch flips the clock labels), so these bridges read the
// press and touch lifecycle in UIKit and pass it back through closures.
//
// `TVPressCaptureView` takes focus and owns the remote while no controls are
// on screen. The three observers never take focus: they put recognisers on
// the window and recognise alongside everything else, so SwiftUI's focus
// engine keeps every press and touch it would have had anyway.

/// The focused press sink for the hidden-controls state.
///
/// An arrow let go within 0.3 seconds is a tap; one still down at 0.3 seconds
/// starts a hold. Select reports on press-down. Menu passes straight through,
/// so SwiftUI's `.onExitCommand` handlers keep it.
struct TVPressCaptureView: UIViewRepresentable {
    enum ArrowDirection: Hashable {
        case left, right, up, down

        /// The arrow a remote press stands for, or nil for any other button.
        init?(press: UIPress.PressType) {
            switch press {
            case .leftArrow: self = .left
            case .rightArrow: self = .right
            case .upArrow: self = .up
            case .downArrow: self = .down
            default: return nil
            }
        }
    }

    /// An arrow pressed and let go inside the hold threshold.
    var onArrowTap: (ArrowDirection) -> Void = { _ in }
    /// An arrow still down at the hold threshold.
    var onArrowHoldBegin: (ArrowDirection) -> Void = { _ in }
    /// Every arrow press-down, before it's known whether it's a tap or a hold.
    var onDirectionalPressBegan: () -> Void = {}
    /// A finger on the clickpad, whether or not it goes on to click.
    var onTouchSurfaceContactBegan: () -> Void = {}
    var onTouchSurfaceContactEnded: () -> Void = {}
    var onTouchSurfaceContactCancelled: () -> Void = {}
    /// Select press-down.
    var onSelect: () -> Void = {}

    func makeUIView(context: Context) -> TVRemotePressSinkView {
        let sink = TVRemotePressSinkView()
        sink.owner = self
        return sink
    }

    func updateUIView(_ uiView: TVRemotePressSinkView, context: Context) {
        uiView.owner = self
    }
}

/// Left and Right taps and holds, watched from the window so the focused
/// timeline keeps its SwiftUI focus.
struct TVSideArrowObserver: UIViewRepresentable {
    var isActive: Bool
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }

    func makeUIView(context: Context) -> TVSideArrowObserverView {
        let observer = TVSideArrowObserverView()
        observer.settings = self
        return observer
    }

    func updateUIView(_ uiView: TVSideArrowObserverView, context: Context) {
        uiView.settings = self
    }
}

/// A light touch on the clickpad while the full controls are up, watched
/// from the window. It reads the raw touch lifecycle, as the press sink does,
/// because tvOS can arbitrate a tap or long-press recogniser away.
struct TVLightTouchObserver: UIViewRepresentable {
    var isActive: Bool
    var onContactBegan: () -> Void = {}
    var onContactEnded: () -> Void = {}
    var onContactCancelled: () -> Void = {}
    /// Any arrow click, so the touch it started with doesn't count as light.
    var onArrowClick: () -> Void = {}

    func makeUIView(context: Context) -> TVLightTouchObserverView {
        let observer = TVLightTouchObserverView()
        observer.settings = self
        return observer
    }

    func updateUIView(_ uiView: TVLightTouchObserverView, context: Context) {
        uiView.settings = self
    }
}

/// Continuous sideways drags on the clickpad for scrubbing, which SwiftUI
/// only reports as separate move commands.
struct TVSwipeObserver: UIViewRepresentable {
    var isActive: Bool
    var onSwipeBegan: () -> Void = {}
    /// Sideways movement in points since the last report.
    var onSwipeMoved: (CGFloat) -> Void = { _ in }
    var onSwipeEnded: () -> Void = {}

    func makeUIView(context: Context) -> TVSwipeObserverView {
        let observer = TVSwipeObserverView()
        observer.settings = self
        return observer
    }

    func updateUIView(_ uiView: TVSwipeObserverView, context: Context) {
        uiView.settings = self
    }
}

// MARK: - Window observers

/// Base for the invisible 1-point views that watch the remote from their
/// window. The recognisers go on when the view joins a window and come off
/// the moment it leaves, not at deinit, so a window the player has left never
/// keeps listening. They only begin while `isActive`, and they recognise
/// alongside every other recogniser so they never take input away.
class TVWindowRemoteObserverView: UIView, UIGestureRecognizerDelegate {
    /// Whether the recognisers may begin. Each subclass reads its SwiftUI
    /// setting.
    var isActive: Bool { false }

    /// The window holding the recognisers, or nil while there is none.
    private(set) weak var hostWindow: UIWindow?
    private var installed: [UIGestureRecognizer] = []

    /// A fresh set of recognisers for a window, added in this order.
    func buildRecognizers() -> [UIGestureRecognizer] { [] }

    /// Runs just before the recognisers leave their window.
    func recognizersWillDetach() {}

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else {
            recognizersWillDetach()
            uninstall()
            return
        }
        guard window !== hostWindow else { return }
        recognizersWillDetach()
        uninstall()
        hostWindow = window
        installed = buildRecognizers()
        installed.forEach(window.addGestureRecognizer)
    }

    deinit {
        uninstall()
    }

    private func uninstall() {
        installed.forEach { hostWindow?.removeGestureRecognizer($0) }
        installed = []
        hostWindow = nil
    }

    // This UIView method shares its selector with the delegate's, so it also
    // answers for every recogniser this view is the delegate of.
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

private extension UIGestureRecognizer {
    /// Listens to one remote button and no touches. A button recogniser that
    /// also took clickpad touches could cancel a focused button's touch.
    func listen(onlyTo press: UIPress.PressType) {
        allowedPressTypes = [NSNumber(value: press.rawValue)]
        allowedTouchTypes = []
    }

    /// Listens to clickpad touches and no buttons.
    func listenToClickpadOnly() {
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        allowedPressTypes = []
    }

    /// Lets the touches it sees carry on to their views, with `host`
    /// deciding when it may begin.
    func reportAlongside(_ host: UIGestureRecognizerDelegate) {
        cancelsTouchesInView = false
        delegate = host
    }
}

final class TVLightTouchObserverView: TVWindowRemoteObserverView {
    var settings = TVLightTouchObserver(isActive: false)
    override var isActive: Bool { settings.isActive }

    private var contactInProgress = false

    deinit {
        abandonContact()
    }

    override func buildRecognizers() -> [UIGestureRecognizer] {
        let contact = TVLightTouchRecognizer(target: self, action: #selector(contactChanged(_:)))
        // tvOS gives custom recognisers Select by default. This one handles
        // touches only, so a Select press would never finish in it and could
        // stop the focused button activating (Apple 111175673).
        contact.listenToClickpadOnly()
        contact.reportAlongside(self)
        contact.delaysTouchesBegan = false
        contact.delaysTouchesEnded = false

        let arrows: [UIPress.PressType] = [.leftArrow, .rightArrow, .upArrow, .downArrow]
        let clicks: [UIGestureRecognizer] = arrows.map { arrow in
            let click = TVPassiveArrowPressRecognizer(target: self, action: #selector(arrowWentDown(_:)))
            click.listen(onlyTo: arrow)
            click.minimumPressDuration = 0
            click.reportAlongside(self)
            return click
        }
        return [contact] + clicks
    }

    override func recognizersWillDetach() {
        abandonContact()
    }

    private func abandonContact() {
        guard contactInProgress else { return }
        contactInProgress = false
        settings.onContactCancelled()
    }

    @objc private func arrowWentDown(_ click: UILongPressGestureRecognizer) {
        guard isActive, click.state == .began else { return }
        settings.onArrowClick()
    }

    @objc private func contactChanged(_ contact: TVLightTouchRecognizer) {
        switch contact.state {
        case .began where isActive:
            contactInProgress = true
            settings.onContactBegan()
        case .ended:
            guard contactInProgress else { return }
            contactInProgress = false
            settings.onContactEnded()
        case .cancelled, .failed:
            abandonContact()
        default:
            break
        }
    }
}

/// A finger resting on the clickpad. It begins with the first clickpad touch,
/// ends when the last one lifts, and cancels as soon as any finger strays far
/// enough to be a swipe. It never blocks, and is never blocked by, the swipe
/// or focus recognisers, so watching for a light touch leaves the rest of the
/// remote alone.
final class TVLightTouchRecognizer: UIGestureRecognizer {
    /// A finger further than this from where it landed is swiping.
    private static let swipeDistance: CGFloat = 12

    /// Where each clickpad finger still down first landed.
    private var landings: [ObjectIdentifier: CGPoint] = [:]

    private var isLive: Bool {
        state == .began || state == .changed
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let fingers = touches.filter { $0.type == .indirect }
        guard !fingers.isEmpty else { return }
        let isFirstFinger = landings.isEmpty
        for finger in fingers {
            landings[ObjectIdentifier(finger)] = finger.location(in: view)
        }
        if isFirstFinger {
            state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard isLive else { return }
        let strayed = touches.contains { finger in
            guard finger.type == .indirect, let landing = landings[ObjectIdentifier(finger)] else { return false }
            let now = finger.location(in: view)
            return hypot(now.x - landing.x, now.y - landing.y) > Self.swipeDistance
        }
        state = strayed ? .cancelled : .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
        if landings.isEmpty && isLive {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
        if isLive {
            state = .cancelled
        }
    }

    override func reset() {
        landings.removeAll()
        super.reset()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func lift(_ touches: Set<UITouch>) {
        for finger in touches where finger.type == .indirect {
            landings[ObjectIdentifier(finger)] = nil
        }
    }
}

/// Sees an arrow click at press-down without joining gesture arbitration.
/// The full controls only use it to stop the touch under that click from
/// toggling the clock labels when it lifts.
final class TVPassiveArrowPressRecognizer: UILongPressGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}

final class TVSwipeObserverView: TVWindowRemoteObserverView {
    var settings = TVSwipeObserver(isActive: false)
    override var isActive: Bool { settings.isActive }

    /// The pan's translation at the last report.
    private var reportedX: CGFloat = 0

    override func buildRecognizers() -> [UIGestureRecognizer] {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panUpdated(_:)))
        pan.listenToClickpadOnly()
        pan.reportAlongside(self)
        return [pan]
    }

    @objc private func panUpdated(_ pan: UIPanGestureRecognizer) {
        let x = pan.translation(in: hostWindow).x
        switch pan.state {
        case .began where isActive:
            reportedX = x
            settings.onSwipeBegan()
            settings.onSwipeMoved(x)
        case .changed where isActive:
            let movement = x - reportedX
            reportedX = x
            settings.onSwipeMoved(movement)
        case .ended:
            if isActive {
                settings.onSwipeMoved(x - reportedX)
            }
            // The end is reported even if scrubbing stopped mid-drag, so
            // SwiftUI never thinks a drag is still going.
            settings.onSwipeEnded()
        case .cancelled, .failed:
            settings.onSwipeEnded()
        default:
            break
        }
    }
}

final class TVSideArrowObserverView: TVWindowRemoteObserverView {
    var settings = TVSideArrowObserver(isActive: false)
    override var isActive: Bool { settings.isActive }

    private static let holdDelay: TimeInterval = 0.3

    /// Which arrow each recogniser listens to.
    private var arrows: [ObjectIdentifier: TVPressCaptureView.ArrowDirection] = [:]

    override func buildRecognizers() -> [UIGestureRecognizer] {
        arrows.removeAll()
        var built: [UIGestureRecognizer] = []
        for press in [UIPress.PressType.leftArrow, .rightArrow] {
            guard let arrow = TVPressCaptureView.ArrowDirection(press: press) else { continue }
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.listen(onlyTo: press)
            hold.minimumPressDuration = Self.holdDelay
            hold.delegate = self

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.listen(onlyTo: press)
            tap.delegate = self
            tap.require(toFail: hold)

            arrows[ObjectIdentifier(tap)] = arrow
            arrows[ObjectIdentifier(hold)] = arrow
            built.append(contentsOf: [tap, hold])
        }
        return built
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard isActive, tap.state == .ended, let arrow = arrows[ObjectIdentifier(tap)] else { return }
        settings.onArrowTap(arrow)
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        guard isActive, hold.state == .began, let arrow = arrows[ObjectIdentifier(hold)] else { return }
        settings.onArrowHoldBegin(arrow)
    }
}

// MARK: - Focused press sink

final class TVRemotePressSinkView: UIView {
    /// The latest SwiftUI value, read whenever a callback fires.
    var owner = TVPressCaptureView()

    /// Short enough that a deliberate hold never feels ignored, long enough
    /// that an ordinary press and release doesn't become one.
    private static let holdDelay: TimeInterval = 0.3

    private struct DownArrow {
        let arrow: TVPressCaptureView.ArrowDirection
        let holdWork: DispatchWorkItem
        var holdStarted = false
    }

    /// Arrows currently down, by press type, so two at once (rare on a Siri
    /// Remote, possible on a keyboard) don't interfere.
    private var downArrows: [UIPress.PressType: DownArrow] = [:]
    private var clickpadFingers: Set<ObjectIdentifier> = []

    override var canBecomeFocused: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let hadContact = !clickpadFingers.isEmpty
        clickpadFingers.formUnion(Self.clickpadIDs(in: touches))
        if !hadContact && !clickpadFingers.isEmpty {
            owner.onTouchSurfaceContactBegan()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        liftFingers(touches, cancelled: false)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        liftFingers(touches, cancelled: true)
        super.touchesCancelled(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var consumed = false
        for press in presses {
            if let arrow = TVPressCaptureView.ArrowDirection(press: press.type) {
                consumed = true
                owner.onDirectionalPressBegan()
                arrowWentDown(press.type, arrow)
                continue
            }
            guard press.type == .select else { continue }
            consumed = true
            owner.onSelect()
        }
        guard !consumed else { return }
        super.pressesBegan(presses, with: event)
    }

    // Select's release isn't consumed here, only its press-down. The release
    // and any cancellation still travel up the responder chain.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let arrowTypes = Self.arrowTypes(in: presses)
        arrowTypes.forEach(arrowWentUp)
        guard arrowTypes.isEmpty else { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        Self.arrowTypes(in: presses).forEach(arrowWentUp)
        super.pressesCancelled(presses, with: event)
    }

    private func arrowWentDown(_ type: UIPress.PressType, _ arrow: TVPressCaptureView.ArrowDirection) {
        // If the arrow comes up first, arrowWentUp cancels this and reports
        // a tap instead.
        let holdWork = DispatchWorkItem { [weak self] in
            guard let self, self.downArrows[type] != nil else { return }
            self.downArrows[type]?.holdStarted = true
            self.owner.onArrowHoldBegin(arrow)
        }
        downArrows[type] = DownArrow(arrow: arrow, holdWork: holdWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: holdWork)
    }

    private func arrowWentUp(_ type: UIPress.PressType) {
        guard let down = downArrows.removeValue(forKey: type) else { return }
        down.holdWork.cancel()
        if !down.holdStarted {
            owner.onArrowTap(down.arrow)
        }
    }

    private func liftFingers(_ touches: Set<UITouch>, cancelled: Bool) {
        let lifted = Self.clickpadIDs(in: touches)
        guard !lifted.isEmpty else { return }
        clickpadFingers.subtract(lifted)
        guard clickpadFingers.isEmpty else { return }
        if cancelled {
            owner.onTouchSurfaceContactCancelled()
        } else {
            owner.onTouchSurfaceContactEnded()
        }
    }

    private static func clickpadIDs(in touches: Set<UITouch>) -> Set<ObjectIdentifier> {
        Set(touches.lazy.filter { $0.type == .indirect }.map { ObjectIdentifier($0) })
    }

    private static func arrowTypes(in presses: Set<UIPress>) -> [UIPress.PressType] {
        presses.map(\.type).filter { TVPressCaptureView.ArrowDirection(press: $0) != nil }
    }
}
#endif
