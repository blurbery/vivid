#if os(iOS)

import AVFoundation
import AVKit
import Combine
import CoreMedia
import Observation
import OSLog

/// Runs the system Picture in Picture window for the Vivid player on screen.
///
/// The engine offers PiP one of two pictures: an `AVPlayerLayer` on its
/// native route, or a `SampleBufferPiPSource` around the sample-buffer layer
/// its software route draws into. The coordinator follows the engine for
/// both, builds the matching AVKit controller, and keeps a running window up
/// when a reload only swaps the layer underneath it.
@MainActor
@Observable
final class PictureInPictureCoordinator {
    static let shared = PictureInPictureCoordinator()

    /// Why a tap on Picture in Picture didn't start it, so the player can
    /// say so rather than leave the button looking dead.
    enum StartFailure {
        /// AVKit refused the start.
        case failed(Error)
        /// AVKit can't start yet: `isPictureInPicturePossible` is still false.
        case notReady
    }

    /// AVKit would start PiP for the current picture right now.
    private(set) var isPossible = false
    /// The window is up: set by did-start, cleared by did-stop.
    private(set) var isActive = false
    /// Set by will-start, cleared once the start lands or fails.
    private(set) var isTransitioning = false
    /// The engine is offering a picture, native or software, that PiP can use.
    private(set) var hasSource = false

    /// PiP has playback, or is about to take it.
    var isEngaged: Bool { isActive || isTransitioning }
    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Which kind of picture the AVKit controller was built from.
    private enum Backend {
        case playerLayer
        case sampleBuffer
    }

    /// The player's hooks, kept as one value so a rebind can carry them over
    /// in one step.
    private struct Callbacks {
        var engagementEnded: (() -> Void)?
        /// Asked to put the full-screen player back when AVKit's restore
        /// button is used. An answer of `false` means nothing can come back,
        /// so the engagement has to end instead of playing on headless.
        var restoreInterface: ((@escaping (Bool) -> Void) -> Void)?
        /// AVKit reports a start that never happened only to its delegate.
        var startFailure: ((StartFailure) -> Void)?

        /// Each hook from `newer`, or this value's hook where `newer` has none.
        func overlaid(with newer: Callbacks) -> Callbacks {
            Callbacks(
                engagementEnded: newer.engagementEnded ?? engagementEnded,
                restoreInterface: newer.restoreInterface ?? restoreInterface,
                startFailure: newer.startFailure ?? startFailure
            )
        }
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "PictureInPicture"
    )

    // The bound session. Its owner is held weakly, so an idle coordinator can
    // never keep a closed player alive. `pinnedOwner` holds it strongly only
    // while AVKit is taking over or showing its picture.
    @ObservationIgnored private weak var boundEngine: VividEngine?
    @ObservationIgnored private weak var owner: AnyObject?
    @ObservationIgnored private var pinnedOwner: AnyObject?
    @ObservationIgnored private var callbacks = Callbacks()
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    // The AVKit controller and the picture it was built from.
    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var bridge: AVKitBridge?
    /// Bumped for every controller built or released, so a late
    /// possible-state callback from an old controller is dropped.
    @ObservationIgnored private var controllerToken: UInt64 = 0
    @ObservationIgnored private var possibleWatch: NSKeyValueObservation?
    @ObservationIgnored private weak var boundLayer: AVPlayerLayer?
    @ObservationIgnored private var boundSampleSource: SampleBufferPiPSource?

    // External screens: AirPlay video or a cable. Stays true through
    // AirPlay's short gap while an item reloads.
    @ObservationIgnored private weak var watchedPlayer: AVPlayer?
    @ObservationIgnored private var externalWatch: NSKeyValueObservation?
    @ObservationIgnored private var showsOnExternalScreen = false

    // How the current engagement should finish.
    /// The app confirmed the full-screen player is back for a restore.
    @ObservationIgnored private var restoreConfirmed = false
    /// The picture changed or went while PiP was engaged; read the engine
    /// again once the window has stopped.
    @ObservationIgnored private var rebindAfterStop = false
    /// The new picture needs a different controller, so the running window
    /// has to stop first.
    @ObservationIgnored private var stopForRebind = false

    private init() {}

    // MARK: - Sessions

    /// Ties the coordinator to one player. Binding the same owner and engine
    /// again only refreshes the hooks it's given; a different owner releases
    /// everything the previous one had.
    func bind(
        engine: VividEngine,
        owner: AnyObject,
        onEngagementEnded: (() -> Void)? = nil,
        onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)? = nil,
        onStartFailure: ((StartFailure) -> Void)? = nil
    ) {
        let incoming = Callbacks(
            engagementEnded: onEngagementEnded,
            restoreInterface: onRestoreUserInterface,
            startFailure: onStartFailure
        )
        let ownerUnchanged = self.owner === owner

        if ownerUnchanged, boundEngine === engine {
            callbacks = callbacks.overlaid(with: incoming)
            reconcileWithEngine()
            return
        }

        let carried = ownerUnchanged ? callbacks.overlaid(with: incoming) : incoming
        // The same owner moving to a replacement engine keeps its engagement.
        // Any other owner gets its deferred cleanup run during this teardown,
        // since the AVKit delegate that would have run it is detached there.
        endBoundSession(handingOverTo: owner)

        boundEngine = engine
        self.owner = owner
        callbacks = carried
        follow(engine)
        reconcileWithEngine()
    }

    /// Keyed by owner, so a player view on its way out can't release the
    /// controller of a newer player while SwiftUI overlaps the two.
    func endSession(owner: AnyObject) {
        if self.owner === owner {
            endBoundSession(handingOverTo: nil)
        } else {
            Self.log.info("Skipping PiP teardown; another session owns the coordinator")
        }
    }

    /// Ends the bound session whoever owns it, because the app crossed an
    /// identity boundary: sign-out, a server or profile switch, or a cleared
    /// session.
    ///
    /// A player that disappears while PiP is engaged deliberately puts its
    /// `cleanup()` off, and an identity change tears the signed-in views down
    /// along that same path. Without this, the old identity's engine, server
    /// session and PiP window would all carry on into the new one. The
    /// teardown runs the engaged owner's put-off cleanup straight away, which
    /// stops the engine and closes the server session.
    func endSessionForIdentityChange() {
        if owner == nil, pinnedOwner == nil { return }
        Self.log.info("Ending the PiP session for an identity boundary")
        endBoundSession(handingOverTo: nil)
    }

    /// For the shared sign-in code, which isn't on the main actor. Either
    /// order against the player's own disappearance is fine: whichever runs
    /// second finds nothing left to end.
    nonisolated static func endEngagedSessionForIdentityChange() {
        Task { @MainActor in
            shared.endSessionForIdentityChange()
        }
    }

    func ownsEngagedSession(_ owner: AnyObject) -> Bool {
        self.owner === owner && isEngaged
    }

    func toggle() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive || isActive {
            pipController.stopPictureInPicture()
            return
        }
        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            Self.log.info("PiP start ignored; not possible yet")
            callbacks.startFailure?(.notReady)
        }
    }

    // MARK: - Following the engine

    private func follow(_ engine: VividEngine) {
        // Every publisher replays its current value when subscribed, so this
        // order is also the order the first values arrive in.
        relay(engine.$currentAVPlayer, from: engine) { coordinator, player in
            coordinator.playerDidChange(to: player)
        }
        // A native host and its layer outlive an item swap. The item has its
        // own publisher, so the external route and subtitle hand-off can be
        // applied to the new item without building PiP again.
        relay(engine.$currentAVPlayerItem, from: engine) { coordinator, _ in
            coordinator.reconcileWithEngine()
        }
        relay(engine.$softwarePiPSource, from: engine) { coordinator, source in
            coordinator.sampleSourceDidChange(to: source)
        }
        // The track can change while the video is in PiP or on another
        // screen. Hand over again once both the pick and the native track
        // table have settled, so the receiver draws the new track rather than
        // whatever had the old number.
        relay(engine.$activeSubtitleTrackIndex, from: engine) { coordinator, _ in
            coordinator.applyNativeSubtitleOwnership()
        }
        relay(engine.$subtitleTracks, from: engine) { coordinator, _ in
            coordinator.applyNativeSubtitleOwnership()
        }
        // A load publishes the host and layer before it commits its route,
        // so the route is the last chance to hand native subtitles over after
        // the same player swaps its item.
        relay(engine.$videoRoute, from: engine) { coordinator, route in
            if route == .remoteBypass {
                coordinator.applyNativeSubtitleOwnership()
            }
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshExternalScreenState()
            }
        }
    }

    /// Delivers one engine publisher. The engine lives on the main actor and
    /// publishes synchronously, so each value arrives in the same turn as the
    /// change, and only while that engine is still the bound one.
    private func relay<Value>(
        _ publisher: Published<Value>.Publisher,
        from engine: VividEngine,
        _ deliver: @escaping (PictureInPictureCoordinator, Value) -> Void
    ) {
        let subscription = publisher.sink { [weak self, weak engine] value in
            MainActor.assumeIsolated {
                guard let coordinator = self, let engine, coordinator.boundEngine === engine else { return }
                deliver(coordinator, value)
            }
        }
        cancellables.insert(subscription)
    }

    /// Reads the engine's current picture and the external screen state again.
    private func reconcileWithEngine() {
        adoptEnginePicture()
        refreshExternalScreenState()
    }

    private func playerDidChange(to player: AVPlayer?) {
        externalWatch?.invalidate()
        externalWatch = nil
        watchedPlayer = player

        if let player {
            externalWatch = player.observe(
                \.isExternalPlaybackActive,
                options: [.initial, .new]
            ) { [weak self, weak player] _, _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, self.watchedPlayer === player else { return }
                    self.refreshExternalScreenState()
                }
            }
            if let layer = boundEngine?.nativePlayerLayer {
                attach(playerLayer: layer)
            }
        } else if backend == .playerLayer {
            pictureWentAway()
        }
        refreshExternalScreenState()
    }

    private func sampleSourceDidChange(to source: SampleBufferPiPSource?) {
        guard let source else {
            if backend == .sampleBuffer {
                pictureWentAway()
            }
            return
        }
        attach(sampleSource: source)
        refreshExternalScreenState()
    }

    /// The picture the controller was built from has gone. A running window
    /// keeps its controller until it stops; otherwise it's released now.
    private func pictureWentAway() {
        if isEngaged {
            rebindAfterStop = true
        } else {
            releaseController(stopping: false)
        }
    }

    private func adoptEnginePicture() {
        guard let engine = boundEngine else { return }
        let nativeLayer = engine.currentAVPlayer == nil ? nil : engine.nativePlayerLayer
        if let nativeLayer {
            attach(playerLayer: nativeLayer)
        } else if let sampleSource = engine.softwarePiPSource {
            attach(sampleSource: sampleSource)
        } else if !isEngaged {
            releaseController(stopping: false)
        }
    }

    // MARK: - Controllers

    private func attach(playerLayer layer: AVPlayerLayer) {
        guard isSupported else {
            hasSource = false
            return
        }
        if backend == .playerLayer, boundLayer === layer {
            markPictureCurrent()
            return
        }
        if isEngaged {
            Self.log.info("Native PiP source changed while active; stopping for a safe rebind")
            stopToRebind()
            return
        }

        releaseController(stopping: false)
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            Self.log.error("AVPictureInPictureController rejected Vivid's native player layer")
            return
        }
        install(controller, bridge: AVKitBridge(coordinator: self), backend: .playerLayer)
        boundLayer = layer
        boundSampleSource = nil
        markPictureCurrent()
        Self.log.info("PiP bound to Vivid native player layer")
    }

    private func attach(sampleSource source: SampleBufferPiPSource) {
        guard isSupported else {
            hasSource = false
            return
        }
        if backend == .sampleBuffer, let pipController, let bridge {
            if boundSampleSource === source {
                markPictureCurrent()
                return
            }
            if isEngaged {
                // A software reload brings a new display layer. Pointing the
                // running controller at it keeps the window on screen.
                boundSampleSource = source
                pipController.contentSource = Self.content(for: source, bridge: bridge)
                markPictureCurrent()
                Self.log.info("PiP swapped to Vivid's reloaded software source")
                return
            }
        }
        if isEngaged {
            Self.log.info("PiP backend class changed while active; stopping for a safe rebind")
            stopToRebind()
            return
        }

        releaseController(stopping: false)
        let newBridge = AVKitBridge(coordinator: self)
        let controller = AVPictureInPictureController(
            contentSource: Self.content(for: source, bridge: newBridge)
        )
        install(controller, bridge: newBridge, backend: .sampleBuffer)
        boundSampleSource = source
        boundLayer = nil
        markPictureCurrent()
        Self.log.info("PiP bound to Vivid software sample-buffer source")
    }

    private static func content(
        for source: SampleBufferPiPSource,
        bridge: AVKitBridge
    ) -> AVPictureInPictureController.ContentSource {
        AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: source.layer,
            playbackDelegate: bridge
        )
    }

    /// The controller already shows the engine's current picture.
    private func markPictureCurrent() {
        hasSource = true
        rebindAfterStop = false
        stopForRebind = false
    }

    /// Stops the running window so the next picture can get its own
    /// controller once AVKit reports the stop.
    private func stopToRebind() {
        rebindAfterStop = true
        stopForRebind = true
        pipController?.stopPictureInPicture()
    }

    private func install(
        _ controller: AVPictureInPictureController,
        bridge: AVKitBridge,
        backend: Backend
    ) {
        controllerToken &+= 1
        let token = controllerToken
        pipController = controller
        self.bridge = bridge
        self.backend = backend
        controller.delegate = bridge
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        possibleWatch = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] watched, _ in
            let possible = watched.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.controllerToken == token else { return }
                self.isPossible = possible
            }
        }
    }

    private func releaseController(stopping: Bool) {
        controllerToken &+= 1
        if stopping, let pipController,
           pipController.isPictureInPictureActive || isEngaged {
            pipController.stopPictureInPicture()
        }
        pipController?.delegate = nil
        possibleWatch?.invalidate()
        possibleWatch = nil
        pipController = nil
        bridge = nil
        backend = nil
        boundLayer = nil
        boundSampleSource = nil
        hasSource = false
        isPossible = false
        isActive = false
        isTransitioning = false
        restoreConfirmed = false
    }

    /// Lets go of the bound engine and controller.
    ///
    /// The controller loses its AVKit delegate in the same turn it's asked
    /// to stop, so no did-stop ever arrives for it. If PiP was engaged, that
    /// callback was the only thing that would have ended the engagement, and
    /// the engaged player has put its `cleanup()` (final progress and the
    /// server session's stop) off until then. So the engagement ends here,
    /// synchronously, instead of never.
    ///
    /// `successor` is the owner about to bind. It only matters when that's
    /// the same owner moving to a replacement engine: its session carries on,
    /// so its cleanup must not run.
    private func endBoundSession(handingOverTo successor: AnyObject?) {
        boundEngine?.pictureInPictureActive = false
        boundEngine?.setNativeSubtitleRendering(false)
        cancellables.removeAll()
        externalWatch?.invalidate()
        externalWatch = nil
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        routeObserver = nil
        releaseController(stopping: true)
        watchedPlayer = nil
        showsOnExternalScreen = false
        rebindAfterStop = false
        stopForRebind = false
        boundEngine = nil
        owner = nil

        let outgoing = pinnedOwner
        let cleanup = outgoing != nil && outgoing !== successor ? callbacks.engagementEnded : nil
        // Cleared before the cleanup runs, so a late did-stop, or the
        // `endSession(owner:)` that `cleanup()` calls back into, finds
        // nothing left to end. `outgoing` keeps the owner alive meanwhile.
        pinnedOwner = nil
        callbacks = Callbacks()

        guard let cleanup else { return }
        Self.log.info("PiP torn down while engaged; running the outgoing session's cleanup")
        withExtendedLifetime(outgoing) { cleanup() }
    }

    // MARK: - External screens and native subtitles

    private func refreshExternalScreenState() {
        let hasNativePicture = watchedPlayer != nil
            || backend == .playerLayer
            || boundEngine?.nativePlayerLayer != nil
        let isRoutedOut = AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .airPlay || output.portType == .HDMI
        }
        showsOnExternalScreen = watchedPlayer?.isExternalPlaybackActive == true
            || (hasNativePicture && isRoutedOut)
        applyNativeSubtitleOwnership()
    }

    /// Only the loopback-native route hands its subtitles to AVKit. Remote
    /// HLS already keeps them in AVPlayer's selection group (under ids the
    /// generated track table doesn't have), and software PiP draws Vivid's
    /// overlay into its own frames.
    private func applyNativeSubtitleOwnership() {
        guard let engine = boundEngine, engine.videoRoute == .remoteBypass else { return }
        engine.setNativeSubtitleRendering(engine.pictureInPictureActive || showsOnExternalScreen)
    }

    // MARK: - AVKit callbacks

    fileprivate func pictureWillStart() {
        // AVKit calls this synchronously on the main thread. The engine flag
        // goes first, so the engine's did-enter-background handler already
        // counts PiP as a reason to keep playing.
        boundEngine?.pictureInPictureActive = true
        pinnedOwner = owner
        isTransitioning = true
        restoreConfirmed = false
        applyNativeSubtitleOwnership()
    }

    fileprivate func pictureDidStart() {
        boundEngine?.pictureInPictureActive = true
        isTransitioning = false
        isActive = true
        applyNativeSubtitleOwnership()
        Self.log.info("PiP started")
        if stopForRebind {
            pipController?.stopPictureInPicture()
        }
    }

    /// AVKit is stopping because the viewer wants the full-screen player
    /// back. Answering `true` must mean it really is on screen again: the
    /// did-stop that follows reads that to decide whether the engagement, and
    /// the player's put-off `cleanup()`, ends.
    fileprivate func pictureRestoreRequested(_ completion: @escaping (Bool) -> Void) {
        restoreConfirmed = false
        guard let restore = callbacks.restoreInterface else {
            // No player presentation to bring back. Answering `true` here is
            // what once left playback running with no screen and no teardown.
            Self.log.error("PiP restore requested with no presentation owner")
            completion(false)
            return
        }
        var answered = false
        restore { [weak self] didRestore in
            // AVKit's handler may only be called once.
            if answered { return }
            answered = true
            if didRestore {
                self?.restoreConfirmed = true
            } else {
                Self.log.error("PiP restore could not re-present the player")
            }
            completion(didRestore)
        }
    }

    fileprivate func pictureDidStop() {
        boundEngine?.pictureInPictureActive = false
        isTransitioning = false
        isActive = false
        applyNativeSubtitleOwnership()
        // Only a confirmed restore keeps the engagement going. The close
        // button, a failed restore and a stop for a rebind all end it, so the
        // player's put-off cleanup runs.
        let restored = restoreConfirmed
        restoreConfirmed = false
        Self.log.info("PiP stopped restored=\(restored ? 1 : 0, privacy: .public)")
        rebindIfDeferred()
        finishEngagement(runningCleanup: !restored)
    }

    fileprivate func pictureFailedToStart(_ error: Error) {
        boundEngine?.pictureInPictureActive = false
        isTransitioning = false
        isActive = false
        applyNativeSubtitleOwnership()
        Self.log.error("PiP failed to start: \(MediaLogRedactor.sanitize(error), privacy: .public)")
        callbacks.startFailure?(.failed(error))
        rebindIfDeferred()
        finishEngagement(runningCleanup: true)
    }

    private func rebindIfDeferred() {
        guard rebindAfterStop else { return }
        rebindAfterStop = false
        stopForRebind = false
        adoptEnginePicture()
    }

    /// Unpins the owner before its cleanup runs, so the `endSession(owner:)`
    /// that `cleanup()` can call back into can't end the engagement twice.
    private func finishEngagement(runningCleanup: Bool) {
        let outgoing = pinnedOwner
        pinnedOwner = nil
        guard runningCleanup else { return }
        withExtendedLifetime(outgoing) { callbacks.engagementEnded?() }
    }

    // MARK: - Software playback controls in the window

    fileprivate func sampleSetPlaying(_ playing: Bool) {
        boundSampleSource?.setPlaying(playing)
    }

    fileprivate var sampleTimeRange: CMTimeRange {
        boundSampleSource?.timeRange() ?? .pictureInPictureUnbounded
    }

    fileprivate var isSamplePaused: Bool {
        boundSampleSource?.isPaused ?? true
    }

    fileprivate func sampleSkip(seconds: Double) {
        boundSampleSource?.skip(by: seconds)
    }
}

private extension CMTimeRange {
    /// What the window gets while no software picture is bound.
    static var pictureInPictureUnbounded: CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
}

/// The AVKit delegate for both protocols. AVKit calls them on the main
/// thread, and handing each straight to the coordinator with
/// `assumeIsolated` keeps will-start synchronous. A separate object keeps
/// the observable coordinator free of `NSObject`.
private final class AVKitBridge: NSObject,
    AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate
{
    private weak var target: PictureInPictureCoordinator?

    init(coordinator: PictureInPictureCoordinator) {
        target = coordinator
    }

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { target?.pictureWillStart() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { target?.pictureDidStart() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { target?.pictureDidStop() }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated { target?.pictureFailedToStart(error) }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            if let target {
                target.pictureRestoreRequested(completionHandler)
            } else {
                completionHandler(false)
            }
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        MainActor.assumeIsolated { target?.sampleSetPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        MainActor.assumeIsolated {
            target?.sampleTimeRange ?? .pictureInPictureUnbounded
        }
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        MainActor.assumeIsolated { target?.isSamplePaused ?? true }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            target?.sampleSkip(seconds: skipInterval.seconds)
        }
        completionHandler()
    }
}
#endif
