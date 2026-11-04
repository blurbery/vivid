#if os(iOS)
import CoreMotion
import Observation
import UIKit

/// SwiftUI's app delegate. Here it only answers UIKit's question about the
/// allowed orientations, from the shared coordinator.
final class VividAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        PlayerOrientationCoordinator.shared.supportedOrientations
    }
}

enum PlayerScreenOrientation: Equatable {
    case portrait
    case landscape

    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .landscapeLeft, .landscapeRight:
            self = .landscape
        case .portrait, .portraitUpsideDown:
            self = .portrait
        default:
            return nil
        }
    }

    var toggled: Self {
        switch self {
        case .portrait: .landscape
        case .landscape: .portrait
        }
    }

    var title: String {
        switch self {
        case .portrait: String(localized: "Portrait")
        case .landscape: String(localized: "Landscape")
        }
    }

    /// The accessibility label of the button that turns the screen to this
    /// orientation.
    var rotateAccessibilityLabel: String {
        switch self {
        case .portrait: String(localized: "Rotate to Portrait")
        case .landscape: String(localized: "Rotate to Landscape")
        }
    }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .landscape: .landscape
        }
    }
}

/// The rotation lock for one player session. A lock holds the exact
/// orientation it was set in, landscape side included, and the rotate button
/// moves a lock instead of releasing it. A landscape lock is saved as
/// `player.orientation_mode`, so the next session opens locked as well.
struct PlayerRotationState {
    private(set) var isPlayerActive = false
    private(set) var lockedOrientation: UIInterfaceOrientationMask?

    var isLocked: Bool { lockedOrientation != nil }

    /// The saved mode for this state: unlocked is `rotateFreely` and a lock
    /// on either landscape side is `landscapeLocked`. A portrait lock has no
    /// saved form, so it leaves the setting alone.
    var persistedOrientationMode: PlayerOrientationMode? {
        switch lockedOrientation {
        case nil:
            .rotateFreely
        case let lock? where lock.isSubset(of: .landscape):
            .landscapeLocked
        default:
            nil
        }
    }

    mutating func activate(lockedOrientation: UIInterfaceOrientationMask? = nil) {
        isPlayerActive = true
        self.lockedOrientation = lockedOrientation
    }

    mutating func deactivate() {
        isPlayerActive = false
        lockedOrientation = nil
    }

    mutating func toggleLock(at orientation: UIInterfaceOrientationMask) {
        if !isPlayerActive { return }
        lockedOrientation = lockedOrientation == nil ? orientation : nil
    }

    mutating func manuallyRotate(to orientation: UIInterfaceOrientationMask) {
        if !isPlayerActive || !isLocked { return }
        lockedOrientation = orientation
    }
}

/// Which orientations the iPhone and iPad app allows, during browsing and in
/// the player. Playback code doesn't know about it: the coordinator only sets
/// UIKit's orientation masks and, while the full-screen player is up, asks
/// the scene to turn.
@Observable
final class PlayerOrientationCoordinator {
    static let shared = PlayerOrientationCoordinator()

    /// The orientations browsing starts with: portrait only on iPhone, and
    /// everything the Info.plist lists on iPad, so its split view and detail
    /// deck can turn. The iPhone Duo's inner screen turns too, but that's
    /// decided at runtime through `rotatesBrowsing`.
    static var appDefaultOrientations: UIInterfaceOrientationMask {
        browsingOrientations(isPad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    static func browsingOrientations(
        isPad: Bool,
        portraitPagePresented: Bool = false
    ) -> UIInterfaceOrientationMask {
        if portraitPagePresented || !isPad { return .portrait }
        return .allButUpsideDown
    }

    static func orientationMask(
        isPlayerActive: Bool, lockedOrientation: UIInterfaceOrientationMask? = nil,
        browsingOrientations: UIInterfaceOrientationMask = appDefaultOrientations
    ) -> UIInterfaceOrientationMask {
        // The Info.plist has to keep listing landscape for the video's sake;
        // pages outside the player are held to their own orientations here.
        // In the player, only the lock button limits turning with the device.
        isPlayerActive ? (lockedOrientation ?? .allButUpsideDown) : browsingOrientations
    }

    static func geometryMask(
        isPlayerActive: Bool, preferredOrientation: UIInterfaceOrientationMask?,
        lockedOrientation: UIInterfaceOrientationMask? = nil,
        browsingOrientations: UIInterfaceOrientationMask = appDefaultOrientations
    ) -> UIInterfaceOrientationMask {
        let permitted = orientationMask(
            isPlayerActive: isPlayerActive,
            lockedOrientation: lockedOrientation,
            browsingOrientations: browsingOrientations
        )
        guard let preferredOrientation else { return permitted }
        // A landscape request still queued when the video closes falls back
        // to what the page allows, so it can't turn the page.
        let overlap = preferredOrientation.intersection(permitted)
        return overlap.isEmpty ? permitted : overlap
    }

    /// The orientation gravity says the device is held in, or `nil` when it's
    /// lying flat, upside down or somewhere in between.
    static func physicalOrientation(gravityX x: Double, y: Double, z: Double) -> UIInterfaceOrientationMask? {
        guard [x, y, z].allSatisfy(\.isFinite), abs(z) < 0.85 else { return nil }
        let sideways = abs(x)
        let upright = abs(y)
        if sideways > 0.5, sideways > upright + 0.15 {
            return x > 0 ? .landscapeLeft : .landscapeRight
        }
        if y < -0.5, upright > sideways + 0.15 {
            return .portrait
        }
        return nil
    }

    private var rotationState = PlayerRotationState()
    private(set) var isPortraitPagePresented = false
    /// The iPhone Duo is half folded like a laptop under the player, which
    /// then stays portrait with the video on the top half.
    private(set) var isDuoTabletop = false
    private(set) var observedOrientation: PlayerScreenOrientation = .portrait

    private let motionManager = CMMotionManager()
    @ObservationIgnored private var motionSettling = MotionSettling()
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []

    var isPlayerActive: Bool { rotationState.isPlayerActive }
    var isRotationLocked: Bool { rotationState.isLocked }

    /// iPad and the iPhone Duo's unfolded inner screen browse in every
    /// orientation. The Duo's cover screen stays portrait like any iPhone.
    var rotatesBrowsing: Bool {
        if UIDevice.current.userInterfaceIdiom == .pad { return true }
        guard PhoneDuo.isDuo else { return false }
        return liveScenes.contains { scene in
            PhoneDuo.isInnerScreen(scene.coordinateSpace.bounds.size)
        }
    }

    var supportedOrientations: UIInterfaceOrientationMask {
        if isPlayerActive, isDuoTabletop { return .portrait }
        return Self.orientationMask(
            isPlayerActive: isPlayerActive,
            lockedOrientation: rotationState.lockedOrientation,
            browsingOrientations: currentBrowsingOrientations
        )
    }

    var nextPlayerOrientation: PlayerScreenOrientation {
        observedOrientation.toggled
    }

    private var currentBrowsingOrientations: UIInterfaceOrientationMask {
        Self.browsingOrientations(
            isPad: rotatesBrowsing,
            portraitPagePresented: isPortraitPagePresented
        )
    }

    private init() {
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.endMotionTracking()
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.beginMotionTracking()
            }
        )
    }

    // MARK: - Player sessions

    func activatePlayer() {
        refreshInterfaceOrientation()
        // `player.orientation_mode` is the saved lock. A landscape lock opens
        // the session locked to the preferred landscape side; rotate freely
        // opens it unlocked.
        let opensLocked = PlayerSettings.shared.playerOrientationMode.isLandscapeLocked
        let savedLock = opensLocked ? landscapeSideToUse() : nil
        rotationState.activate(lockedOrientation: savedLock)
        beginMotionTracking()
        applyPolicy(preferring: savedLock ?? currentDeviceMask())
    }

    func deactivatePlayer() {
        if !isPlayerActive { return }
        rotationState.deactivate()
        endMotionTracking()
        // The iPhone Duo replays a geometry request after its next unfold, so
        // there the orientations are only queried again: the cover screen
        // goes back to portrait and the inner screen keeps the video's way up.
        if PhoneDuo.isDuo {
            UIView.performWithoutAnimation { invalidateAllScenes() }
            return
        }
        let browsing = currentBrowsingOrientations
        let preferred: UIInterfaceOrientationMask = browsing.contains(.portrait) ? .portrait : browsing
        // iPhone snaps back to portrait without the rotation animation.
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        guard isPhone else {
            applyPolicy(preferring: preferred)
            return
        }
        UIView.performWithoutAnimation { applyPolicy(preferring: preferred) }
    }

    /// Search and settings open as full-window pages. Callers pass
    /// `!rotatesBrowsing`, so the pages stay portrait on iPhone and turn on
    /// iPad and the Duo's inner screen. An active player takes priority;
    /// closing it puts this policy back before the page shows again.
    func setPortraitPagePresented(_ isPresented: Bool) {
        guard isPresented != isPortraitPagePresented else { return }
        isPortraitPagePresented = isPresented
        if isPlayerActive { return }
        applyPolicy(preferring: isPresented ? .portrait : currentBrowsingOrientations)
    }

    /// Folding or unfolding the iPhone Duo moves the scene to the other
    /// screen. The orientations are only queried again: iOS turns the cover
    /// screen to portrait by itself and the inner screen follows the device.
    /// A geometry request here would be replayed after the next unfold and
    /// pin the inner screen in portrait.
    func duoScreenDidChange(portraitPagePresented: Bool) {
        guard PhoneDuo.isDuo else { return }
        isPortraitPagePresented = portraitPagePresented
        if isPlayerActive { return }
        invalidateAllScenes()
    }

    /// Queries the orientations again only, for the same reason as a fold.
    func setDuoTabletop(_ isTabletop: Bool) {
        guard PhoneDuo.isDuo, isTabletop != isDuoTabletop else { return }
        isDuoTabletop = isTabletop
        invalidateAllScenes()
    }

    func refreshInterfaceOrientation() {
        if let shown = interfaceOrientation.flatMap(PlayerScreenOrientation.init(interfaceOrientation:)) {
            observedOrientation = shown
        }
    }

    /// The rotate button. It reads the real interface orientation on every
    /// tap, works whether or not the lock is on, and never touches the
    /// video session.
    func togglePlayerOrientation() {
        if !isPlayerActive { return }
        refreshInterfaceOrientation()
        let target: UIInterfaceOrientationMask =
            nextPlayerOrientation == .landscape ? landscapeSideToUse() : .portrait
        rotationState.manuallyRotate(to: target)
        motionSettling.lastSettled = sampledPhysicalOrientation
        saveRotationLock()
        applyPolicy(preferring: target)
    }

    func toggleRotationLock() {
        if !isPlayerActive { return }
        refreshInterfaceOrientation()
        let lockAt = interfaceOrientation?.exactMask ?? observedOrientation.mask
        rotationState.toggleLock(at: lockAt)
        saveRotationLock()
        applyPolicy(preferring: rotationState.lockedOrientation ?? currentDeviceMask())
    }

    /// Writes the lock back to `player.orientation_mode`, so it outlasts the
    /// session and matches Android and the settings contract.
    private func saveRotationLock() {
        guard let wanted = rotationState.persistedOrientationMode else { return }
        if PlayerSettings.shared.playerOrientationMode != wanted {
            PlayerSettings.shared.setPlayerOrientationMode(wanted)
        }
    }

    // MARK: - Motion

    private var sampledPhysicalOrientation: UIInterfaceOrientationMask? {
        guard let gravity = motionManager.deviceMotion?.gravity else { return nil }
        return Self.physicalOrientation(gravityX: gravity.x, y: gravity.y, z: gravity.z)
    }

    private func beginMotionTracking() {
        guard isPlayerActive,
              motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 0.2
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion, self.isPlayerActive else { return }
            self.handleMotion(motion)
        }
    }

    private func handleMotion(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let physical = Self.physicalOrientation(gravityX: gravity.x, y: gravity.y, z: gravity.z)
        guard let settled = motionSettling.settle(on: physical, at: motion.timestamp) else { return }
        // A settled turn still waits for an unlocked, flat-screen player in
        // the foreground that isn't already showing that way.
        guard !isRotationLocked,
              !isDuoTabletop,
              UIApplication.shared.applicationState == .active,
              interfaceOrientation?.exactMask != settled else { return }
        applyPolicy(preferring: settled)
    }

    private func endMotionTracking() {
        motionManager.stopDeviceMotionUpdates()
        motionSettling.reset()
    }

    // MARK: - Applying the policy

    private func applyPolicy(preferring preferred: UIInterfaceOrientationMask) {
        if Thread.isMainThread {
            commitPolicy(preferring: preferred)
            return
        }
        DispatchQueue.main.async { [weak coordinator = self] in
            coordinator?.commitPolicy(preferring: preferred)
        }
    }

    private func commitPolicy(preferring preferred: UIInterfaceOrientationMask) {
        let scenes = liveScenes
        for scene in scenes {
            invalidateOrientations(in: scene)
        }
        let mask = Self.geometryMask(
            isPlayerActive: isPlayerActive,
            preferredOrientation: preferred,
            lockedOrientation: rotationState.lockedOrientation,
            browsingOrientations: currentBrowsingOrientations
        )
        guard let target = scenes.first else { return }
        // The handler only runs when the request fails: read back where the
        // screen ended up and have the scene query the orientations again.
        target.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
            self?.geometryRequestFailed(in: target)
        }
    }

    private func geometryRequestFailed(in scene: UIWindowScene) {
        refreshInterfaceOrientation()
        invalidateOrientations(in: scene)
    }

    private func invalidateAllScenes() {
        for scene in liveScenes {
            invalidateOrientations(in: scene)
        }
    }

    private func invalidateOrientations(in scene: UIWindowScene) {
        for root in scene.windows.compactMap(\.rootViewController) {
            invalidateOrientations(from: root)
        }
    }

    /// Asks a controller, and everything it shows, to read the supported
    /// orientations again.
    private func invalidateOrientations(from controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        (controller as? UINavigationController)?.visibleViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        (controller as? UITabBarController)?.selectedViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        if let presented = controller.presentedViewController {
            invalidateOrientations(from: presented)
        }
        for child in controller.children {
            invalidateOrientations(from: child)
        }
    }

    // MARK: - Reading the screen and device

    /// Window scenes in the foreground, active or not.
    private var liveScenes: [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { scene -> UIWindowScene? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            switch windowScene.activationState {
            case .foregroundActive, .foregroundInactive:
                return windowScene
            default:
                return nil
            }
        }
    }

    private var interfaceOrientation: UIInterfaceOrientation? {
        liveScenes
            .map { $0.effectiveGeometry.interfaceOrientation }
            .first { $0 != .unknown }
    }

    /// The landscape side to use: the screen's own when it's already
    /// landscape, otherwise the side the device is turned to, otherwise
    /// landscape right.
    private func landscapeSideToUse() -> UIInterfaceOrientationMask {
        if let current = interfaceOrientation, current.isLandscape, let exact = current.exactMask {
            return exact
        }
        if let deviceSide = UIDevice.current.orientation.matchingInterfaceMask, deviceSide != .portrait {
            return deviceSide
        }
        return .landscapeRight
    }

    private func currentDeviceMask() -> UIInterfaceOrientationMask {
        if motionManager.isDeviceMotionAvailable {
            return sampledPhysicalOrientation
                ?? interfaceOrientation?.exactMask
                ?? observedOrientation.mask
        }
        return UIDevice.current.orientation.matchingInterfaceMask
            ?? interfaceOrientation?.exactMask
            ?? .portrait
    }
}

/// Waits for the device to hold a new physical orientation before it counts,
/// and lets each settled orientation through only once.
private struct MotionSettling {
    private var candidate: UIInterfaceOrientationMask?
    private var candidateSince: TimeInterval = 0
    /// The last orientation let through. The rotate button also sets it, so
    /// motion doesn't turn the screen straight back.
    var lastSettled: UIInterfaceOrientationMask?

    /// Feeds one sample. Returns the orientation once it has held for 0.35
    /// seconds, if it isn't the one let through last.
    mutating func settle(
        on orientation: UIInterfaceOrientationMask?,
        at time: TimeInterval
    ) -> UIInterfaceOrientationMask? {
        guard let orientation else {
            candidate = nil
            return nil
        }
        guard candidate == orientation else {
            candidate = orientation
            candidateSince = time
            return nil
        }
        guard time - candidateSince >= 0.35, lastSettled != orientation else { return nil }
        lastSettled = orientation
        return orientation
    }

    mutating func reset() {
        candidate = nil
        lastSettled = nil
    }
}

private extension UIInterfaceOrientation {
    /// The mask holding just this orientation, for the three the player uses.
    var exactMask: UIInterfaceOrientationMask? {
        switch self {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}

private extension UIDeviceOrientation {
    /// The interface orientation mask that shows upright for this device
    /// orientation. The landscape sides are swapped, because the device's
    /// left is the interface's right.
    var matchingInterfaceMask: UIInterfaceOrientationMask? {
        switch self {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}
#endif
