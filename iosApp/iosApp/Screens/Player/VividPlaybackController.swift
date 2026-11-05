import AVFoundation
import Combine
import Foundation
#if os(iOS) || os(tvOS)
import MediaPlayer
#endif

/// The single owner of Vivid's video engine.
///
/// Sessions, queues and screen state belong to the player view model. This
/// type owns loading, transport and watching the engine, and stamps every
/// engine event with the load that produced it, so whatever a replaced load
/// reports late is thrown away.
@MainActor
final class VividPlaybackController {
    // MARK: - Types

    struct EmbeddedSubtitleSelectionError: LocalizedError {
        let streamIndex: Int
        var errorDescription: String? { "The selected embedded subtitle is unavailable in the opened media." }
    }

    /// A typed engine failure that ended a load, with the error that
    /// carried it.
    struct LoadFailure: LocalizedError {
        let failure: PlaybackErrorInfo
        let underlying: Error

        var errorDescription: String? { failure.message }
    }

    struct LoadEpoch: RawRepresentable, Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    enum Event {
        case state(PlaybackState)
        case phase(PlaybackPhase)
        case playerTime(Double)
        case duration(Double)
        case buffering(Bool)
        case subtitleLoading(Bool)
        case firstFrame
        case inventoryChanged
        case telemetryChanged(LiveTelemetry?)
        case ended
        case failure(PlaybackErrorInfo)
        case transportRestoreFailed(String)
    }

    struct ScopedEvent {
        let epoch: LoadEpoch
        let event: Event
    }

    /// News that isn't tied to one load, so it still arrives after a load
    /// has gone and Now Playing or the route controls can let go.
    enum ControllerEvent {
        /// Whatever owns system media (the player, its session or the
        /// route) changed.
        case systemMediaChanged
        /// Whether video can go to an external screen, and whether it is.
        case externalPlaybackChanged(supported: Bool, active: Bool)
    }

    enum SeekResult: Equatable {
        case completed(sourceSeconds: Double)
        case requiresReplan(sourceSeconds: Double)
    }

    // MARK: - Public state

    let engine: VividEngine
    var onEvent: ((ScopedEvent) -> Void)?
    var onControllerEvent: ((ControllerEvent) -> Void)?
    /// Automatic Subtitles on iOS 26 switches captions on without any API
    /// that reports it; the engine passing the request along is the only
    /// sign. By then the engine has dropped its own rendition, so the answer
    /// is to pick a matching app track. Only sent during a load, with that
    /// load's epoch.
    var onSystemCaptionRequest: ((LoadEpoch, SystemCaptionRequest) -> Void)?

    private(set) var activeSpec: VividLoadSpec?
    private(set) var activeLoadEpoch: LoadEpoch?

    /// False when there's no load, so `play()`, `pause()` and seeks would
    /// reach nothing. A system media control mustn't report success then.
    var hasActiveLoad: Bool { activeLoadEpoch != nil && activeSpec != nil }

    /// The last Play or Pause the viewer asked for, kept apart from what the
    /// engine is doing at the moment (loading, buffering, failing). A
    /// replacement load reads it when it commits, so pressing Play or Pause
    /// mid-load still counts.
    private(set) var shouldPlayWhenReady = false

    private(set) var supportsExternalPlayback = false
    private(set) var isExternalPlaybackActive = false

    // MARK: - Private state

    /// Bookkeeping for the load in progress. The spec goes in before
    /// `VividEngine.load` starts, so events the engine sends while loading
    /// already carry the new epoch, but `committed` stays false until the
    /// load returns: until then the engine can still be showing the outgoing
    /// AVPlayer, which matters for the AirPlay rules.
    private struct LoadProgress {
        var number: UInt64 = 0
        var committed = false
        var engineStarted = false
        var firstFrameSent = false
        var endSent = false
    }

    private struct Transport {
        var intent: UInt64 = 0
        var restore: Task<Void, Never>?
        var rate: Float = 1
        var volume: Float = 1
        var muted = false
    }

    private struct AirPlayTracking {
        var player: AVPlayer?
        var observation: NSKeyValueObservation?
        var deferredPolicy: Task<Void, Never>?
        /// The outgoing AVPlayer's AirPlay setting while its item is being
        /// replaced, so clearing the spec doesn't cut an active AirPlay route
        /// before the next load has done its own hand-over.
        var carriedPolicy: Bool?
        var reportedSupport = false
        var reportedActive = false
    }

    private var load = LoadProgress()
    private var transport = Transport()
    private var airPlay = AirPlayTracking()
    private var engineObservers: Set<AnyCancellable> = []
    /// External subtitles (Silo sidecars, for example) by app id, with the
    /// engine id each was registered under, in both directions.
    private var engineSubtitleIDs: [Int64: Int] = [:]
    private var appSubtitleIDs: [Int: Int64] = [:]

    init() throws {
        engine = try VividEngine()
        #if os(tvOS)
        // On Apple TV, AVPlayerViewController owns the system video session.
        engine.ownsVideoNowPlayingSession = false
        #elseif os(iOS)
        engine.ownsVideoNowPlayingSession = true
        #endif
        syncBackgroundPlaybackSetting()
        watchEngine()
    }

    /// Gives the engine the Settings choice for playing in the background.
    /// The engine only reads it when the app is backgrounded, so this runs
    /// again at every load: an edit then reaches the next playback even when
    /// this controller has outlived it.
    private func syncBackgroundPlaybackSetting() {
        engine.backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
    }

    // MARK: - Loading

    /// Installs the new load's identity at once, before `VividEngine.load`
    /// gets a chance to publish anything about the new media.
    @discardableResult
    func beginLoad(
        _ spec: VividLoadSpec,
        shouldPlayWhenReady: Bool = true
    ) -> LoadEpoch {
        advanceLoadNumber()
        self.shouldPlayWhenReady = shouldPlayWhenReady
        let epoch = LoadEpoch(rawValue: load.number)
        syncBackgroundPlaybackSetting()
        activeLoadEpoch = epoch
        load.committed = false
        activeSpec = spec
        applyAirPlayRules()
        updateExternalPlaybackStatus()
        forgetSubtitleAliases()
        load.firstFrameSent = false
        load.endSent = false
        return epoch
    }

    /// Opens what `beginLoad` installed. Throws `CancellationError` once a
    /// newer load or a stop has taken over, and `LoadFailure` when the
    /// engine reported a typed failure.
    func finishLoad(_ epoch: LoadEpoch) async throws {
        guard epoch == activeLoadEpoch, let spec = activeSpec else { throw CancellationError() }
        do {
            load.engineStarted = true
            try await engine.load(
                url: spec.sourceURL,
                startPosition: spec.vividStartPosition,
                options: spec.options,
                audioSourceStreamIndex: spec.audioSourceStreamIndex
            )
        } catch {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            if error is CancellationError {
                dropFailedLoad()
                throw error
            }
            // Read the engine's own failure before the load is cleared.
            let engineFailure = engine.errorInfo
            dropFailedLoad()
            if let engineFailure {
                throw LoadFailure(failure: engineFailure, underlying: error)
            }
            throw error
        }
        guard epoch == activeLoadEpoch else { throw CancellationError() }
        load.committed = true
        airPlay.carriedPolicy = nil
        applyAirPlayRules()
        updateExternalPlaybackStatus()
        announceSystemMediaChange()
    }

    /// Clears a load that failed or was cancelled.
    private func dropFailedLoad() {
        activeLoadEpoch = nil
        activeSpec = nil
        airPlay.carriedPolicy = nil
        forgetSubtitleAliases()
        applyAirPlayRules()
        updateExternalPlaybackStatus()
        announceSystemMediaChange()
    }

    /// Hands the playing source new request headers in place. False when the
    /// load, URL or expected headers no longer match, for native remote HLS,
    /// or when the engine can't swap them on the open source.
    @discardableResult
    func updateSourceHeaders(_ headers: [String: String], for epoch: LoadEpoch,
                             expectedHeaders: [String: String], sourceURL: URL) -> Bool {
        guard epoch == activeLoadEpoch, var spec = activeSpec,
              sourceURL == spec.sourceURL, expectedHeaders == spec.options.httpHeaders,
              !spec.options.nativeRemoteHLS,
              engine.updateSourceHeaders(headers, for: sourceURL) else {
            return false
        }
        spec.updateHTTPHeaders(headers)
        activeSpec = spec
        return true
    }

    // MARK: - Transport

    func play() {
        shouldPlayWhenReady = true
        // Between `beginLoad` and the end of `engine.load` the controller
        // looks exactly like a load torn down in the background (no route,
        // no ready session). Restoring then would start a second
        // `engine.load` and cancel the startup in flight, which is what
        // Play/Pause on the Siri Remote used to do over the loading spinner.
        let action = VividPlayIntent.action(
            hasCommittedActiveLoad: load.committed,
            sessionRequiresRestore: sessionNeedsRestore
        )
        guard action != .ignore else { return }

        let intent = startTransportIntent()
        transport.restore = Task { @MainActor [weak self] in
            guard let self, let epoch = self.activeLoadEpoch, self.activeSpec != nil else { return }
            if self.load.committed, self.sessionNeedsRestore {
                do {
                    try await self.engine.reloadAtCurrentPosition()
                } catch is CancellationError {
                    return
                } catch {
                    if intent == self.transport.intent, epoch == self.activeLoadEpoch {
                        self.emit(.transportRestoreFailed(error.localizedDescription), for: epoch)
                    }
                    return
                }
            }
            let stillWanted = !Task.isCancelled
                && intent == self.transport.intent
                && epoch == self.activeLoadEpoch
                && self.activeSpec != nil
                && self.engine.videoRoute != .none
            guard stillWanted else { return }
            self.engine.play()
            self.engine.setRate(self.transport.rate)
            self.transport.restore = nil
        }
    }

    /// True when the active load's session is gone and only a reload brings
    /// it back, which is how Vivid's wedge-safe background teardown leaves
    /// it.
    ///
    /// `videoRoute` is the supported way to ask which pipeline is serving,
    /// and `.none` means torn down (`playbackBackend` says the same, but
    /// hosts mustn't branch on it). Also requiring `isSessionReady` to be
    /// false, the flag hosts gate corrective actions on, keeps a short
    /// reroute (the route changes while a session still exists) from looking
    /// like a teardown.
    private var sessionNeedsRestore: Bool {
        engine.videoRoute == .none && !engine.isSessionReady
    }

    func pause() {
        shouldPlayWhenReady = false
        _ = startTransportIntent()
        engine.pause()
    }

    /// Supersedes any earlier Play or Pause and its restore.
    private func startTransportIntent() -> UInt64 {
        transport.intent &+= 1
        transport.restore?.cancel()
        transport.restore = nil
        return transport.intent
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0 else { return }
        guard rate > 0 else {
            pause()
            return
        }
        transport.rate = rate
        // Any non-zero AVPlayer rate also means play, so a speed change made
        // while paused waits for the next Play.
        if shouldPlayWhenReady {
            engine.setRate(rate)
        }
    }

    func setSpeed(_ rate: Double) { setRate(Float(rate)) }

    func setVolume(_ volume: Float) {
        transport.volume = min(max(volume, 0), 1)
        applyVolume()
    }

    func setMuted(_ value: Bool) {
        transport.muted = value
        applyVolume()
    }

    private func applyVolume() {
        engine.volume = transport.muted ? 0 : transport.volume
    }

    var volume: Float { transport.volume }

    var isMuted: Bool { transport.muted }

    var isPaused: Bool { engine.state != .playing }

    func seek(toSourceTime sourceSeconds: Double) async -> SeekResult {
        guard let timeline = activeSpec?.timeline else {
            return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
        }
        switch timeline.seekDisposition(forSourceTime: sourceSeconds) {
        case .replan(let target):
            return .requiresReplan(sourceSeconds: target)
        case .local(let playerSeconds):
            // Rewinding from the end-of-playback Next Up keeps this load, so
            // its next genuine end must be able to publish again.
            load.endSent = false
            let loadAtSeek = load.number
            await engine.seek(to: playerSeconds)
            guard load.number == loadAtSeek else {
                return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
            }
            return .completed(sourceSeconds: timeline.sourcePosition(forPlayerTime: engine.clock.currentTime))
        }
    }

    // MARK: - Replacement and teardown

    /// Pauses the outgoing item while leaving Vivid's native host in place
    /// for the next load, which then does the teardown itself. That lets one
    /// native item hand over to the next without resetting Apple TV's display
    /// criteria, swapping the player layer or giving up the shared audio
    /// session between episodes.
    func prepareForReplacement() {
        invalidateActiveLoad(keepingAirPlayPolicy: true)
        engine.deactivatesAudioSessionOnStop = false
        // Without this the engine unloads the outgoing AVPlayerItem as `load`
        // begins, and the shared player layer sits empty while Next Up grows
        // back to full screen. On Apple TV the layer can stay black while the
        // next item's audio and clock run. The one-shot item swap has to be
        // armed before the old item is paused.
        engine.prepareForItemReplacement()
        engine.pause()
        updateExternalPlaybackStatus()
        announceSystemMediaChange()
    }

    func dispose() { stop() }

    func stop() {
        invalidateActiveLoad()
        shouldPlayWhenReady = false
        // SwiftUI may build a model eagerly and throw it away unused. Its
        // clean-up must leave another engine's audio session and the active
        // player's display criteria alone.
        guard load.engineStarted else { return }
        load.engineStarted = false
        // Video is the app's only playback owner, so the final teardown hands
        // the shared audio session back and other apps can carry on.
        engine.deactivatesAudioSessionOnStop = true
        engine.stop(finalTeardown: true)
        updateExternalPlaybackStatus()
        announceSystemMediaChange()
    }

    private func invalidateActiveLoad(keepingAirPlayPolicy: Bool = false) {
        airPlay.carriedPolicy = keepingAirPlayPolicy ? airPlay.player?.allowsExternalPlayback : nil
        advanceLoadNumber()
        activeLoadEpoch = nil
        load.committed = false
        activeSpec = nil
        applyAirPlayRules()
        forgetSubtitleAliases()
        load.firstFrameSent = false
        load.endSent = false
    }

    /// Moves to a new load number, which also retires any pending Play or
    /// Pause.
    private func advanceLoadNumber() {
        load.number &+= 1
        _ = startTransportIntent()
    }

    // MARK: - System media

    #if os(iOS) || os(tvOS)
    /// The engine's native video session, once a native host exists. The
    /// software route has none.
    var videoNowPlayingSession: MPNowPlayingSession? {
        engine.videoRoute.usesNativeVideoSession ? engine.videoNowPlayingSession : nil
    }
    #endif

    /// Only routes without an `MPNowPlayingSession` fall back on the
    /// app-wide Now Playing centres.
    var shouldUseSharedVideoNowPlayingFallback: Bool {
        engine.videoRoute == .sampleBuffer
    }

    // MARK: - Tracks

    func validateEmbeddedSubtitleSelection(_ streamIndex: Int) throws {
        let present = engine.subtitleTracks.contains { $0.id == streamIndex && !$0.isExternal }
        if !present {
            throw EmbeddedSubtitleSelectionError(streamIndex: streamIndex)
        }
    }

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    func selectSubtitleTrack(id: Int64?) {
        guard let engineID = id.flatMap(vividSubtitleID(forAppID:)) else {
            engine.clearSubtitle()
            return
        }
        engine.selectSubtitleTrack(index: engineID)
    }

    func selectSecondarySubtitleTrack(id: Int64?) {
        guard let engineID = id.flatMap(vividSubtitleID(forAppID:)) else {
            engine.clearSecondarySubtitle()
            return
        }
        engine.selectSecondarySubtitleTrack(index: engineID)
    }

    func appSubtitleID(forVividID id: Int) -> Int64 {
        appSubtitleIDs[id] ?? Int64(id)
    }

    /// Reverses `appSubtitleID(forVividID:)`. Internal so the boundary tests
    /// can check the round trip.
    func vividSubtitleID(forAppID id: Int64) -> Int? {
        if let registered = engineSubtitleIDs[id] { return registered }
        // A Silo sidecar id means nothing to the engine. Sent through as it
        // is, the engine would quietly ignore it as an unknown external id
        // and leave the old subtitle showing.
        if SubtitleTrackIdSpace.isSidecar(id) { return nil }
        return Int(exactly: id)
    }

    /// True when the subtitle follows the movie's clock (an external file)
    /// rather than the stream's. With no track id only the primary slot has
    /// an answer, read from the engine's active track.
    func subtitleUsesMovieTimeline(appTrackID: Int64?, slot: SubtitleSlot) -> Bool {
        let engineID: Int? = if let appTrackID {
            vividSubtitleID(forAppID: appTrackID)
        } else if slot == .primary {
            engine.activeSubtitleTrackIndex
        } else {
            nil
        }
        return engine.subtitleTracks.contains { $0.isExternal && $0.id == engineID }
    }

    func containsSubtitle(appTrackID: Int64) -> Bool {
        if engineSubtitleIDs[appTrackID] != nil { return true }
        return engine.subtitleTracks.contains { !$0.isExternal && Int64($0.id) == appTrackID }
    }

    /// Registers an external subtitle with the engine under `appTrackID`,
    /// at most once per load.
    @discardableResult
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack, appTrackID: Int64) -> Int64 {
        guard engineSubtitleIDs[appTrackID] == nil else { return appTrackID }
        var timed = track
        // Sidecar cues are in movie time; native ASS draws on the stream clock.
        timed.nativeTimelineOffsetSeconds = activeSpec?.timeline.timelineOffsetSeconds ?? 0
        let engineID = engine.addExternalSubtitleTrack(timed).id
        engineSubtitleIDs[appTrackID] = engineID
        appSubtitleIDs[engineID] = appTrackID
        return appTrackID
    }

    private func forgetSubtitleAliases() {
        engineSubtitleIDs.removeAll()
        appSubtitleIDs.removeAll()
    }

    // MARK: - Engine events

    /// The subscriptions fire with their current values as they're made, so
    /// their order is kept stable.
    private func watchEngine() {
        observePlaybackSignals()
        observeInventoryAndTelemetry()
        observeRouteChanges()
    }

    private func observePlaybackSignals() {
        engine.$state
            .sink { [weak self] state in self?.engineStateChanged(state) }
            .store(in: &engineObservers)
        engine.$playbackPhase
            .sink { [weak self] in self?.emit(.phase($0)) }
            .store(in: &engineObservers)
        engine.clock.$currentTime
            .sink { [weak self] in self?.emit(.playerTime($0)) }
            .store(in: &engineObservers)
        engine.$duration
            .sink { [weak self] in self?.emit(.duration($0)) }
            .store(in: &engineObservers)
        engine.$isBuffering
            .sink { [weak self] in self?.emit(.buffering($0)) }
            .store(in: &engineObservers)
        engine.$isLoadingSubtitles
            .removeDuplicates()
            .sink { [weak self] in self?.emit(.subtitleLoading($0)) }
            .store(in: &engineObservers)
        #if DEBUG && (os(iOS) || os(tvOS))
        engine.$startupProgress
            .compactMap { $0?.checkpoint }
            .removeDuplicates()
            .sink { checkpoint in
                DiagTrace.breadcrumb(.essential, category: .playback, tag: "StartupTiming", message: "engine \(checkpoint)")
            }
            .store(in: &engineObservers)
        #endif
        engine.$hasFirstFrameReadyForDisplay
            .sink { [weak self] in self?.firstFrameReadinessChanged($0) }
            .store(in: &engineObservers)
        engine.$errorInfo
            .compactMap { $0 }
            .sink { [weak self] in self?.emit(.failure($0)) }
            .store(in: &engineObservers)
    }

    private func observeInventoryAndTelemetry() {
        let inventory = Publishers.Merge3(
            engine.$audioTracks.map { _ in () },
            engine.$subtitleTracks.map { _ in () },
            engine.$mediaChapters.map { _ in () }
        )
        // @Published sends before it stores the new value, and listeners
        // read the engine's lists, so the event is delivered once the
        // current assignments are done, tagged with the load it began under.
        inventory
            .compactMap { [weak self] _ in self?.activeLoadEpoch }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.emit(.inventoryChanged, for: $0) }
            .store(in: &engineObservers)
        // Forward the sample that was sent: reading the property here would
        // still give the previous one, for the same @Published reason.
        engine.diagnostics.$liveTelemetry
            .sink { [weak self] in self?.emit(.telemetryChanged($0)) }
            .store(in: &engineObservers)
        engine.systemCaptionRequest
            .sink { [weak self] request in
                guard let self, let epoch = self.activeLoadEpoch else { return }
                self.onSystemCaptionRequest?(epoch, request)
            }
            .store(in: &engineObservers)
    }

    private func observeRouteChanges() {
        engine.$currentAVPlayer
            .sink { [weak self] player in
                guard let self else { return }
                self.watchExternalPlayback(of: player)
                self.announceSystemMediaChange()
            }
            .store(in: &engineObservers)
        // A native host can keep its AVPlayer and swap only the item, so the
        // AirPlay rules and session binding are applied again then too.
        engine.$currentAVPlayerItem
            .sink { [weak self] _ in self?.routeMayHaveChanged() }
            .store(in: &engineObservers)
        engine.$videoRoute
            .sink { [weak self] _ in self?.routeMayHaveChanged() }
            .store(in: &engineObservers)
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in self?.updateExternalPlaybackStatus() }
            .store(in: &engineObservers)
        #endif
    }

    private func engineStateChanged(_ state: PlaybackState) {
        emit(.state(state))
        guard state == .ended, !load.endSent else { return }
        load.endSent = true
        emit(.ended)
    }

    private func firstFrameReadinessChanged(_ ready: Bool) {
        guard ready, !load.firstFrameSent else { return }
        load.firstFrameSent = true
        emit(.firstFrame)
    }

    private func announceSystemMediaChange() {
        onControllerEvent?(.systemMediaChanged)
    }

    /// Sends an engine event stamped with the active load. An event meant
    /// for a particular `epoch` is dropped once a different load is active.
    private func emit(_ event: Event, for epoch: LoadEpoch? = nil) {
        guard let current = activeLoadEpoch else { return }
        if let epoch, epoch != current { return }
        onEvent?(ScopedEvent(epoch: current, event: event))
    }

    // MARK: - AirPlay and external playback

    private func routeMayHaveChanged() {
        applyAirPlayRules()
        updateExternalPlaybackStatus()
        announceSystemMediaChange()
    }

    private func watchExternalPlayback(of player: AVPlayer?) {
        airPlay.deferredPolicy?.cancel()
        airPlay.deferredPolicy = nil
        airPlay.observation?.invalidate()
        airPlay.observation = nil
        airPlay.player = player
        applyAirPlayRules()

        guard let player else {
            updateExternalPlaybackStatus()
            return
        }
        airPlay.observation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.isWatching(player) else { return }
                self.updateExternalPlaybackStatus()
            }
        }
    }

    /// True while `player` is both the one being watched and the engine's
    /// current AVPlayer.
    private func isWatching(_ player: AVPlayer) -> Bool {
        airPlay.player === player && engine.currentAVPlayer === player
    }

    private func applyAirPlayRules() {
        guard let player = airPlay.player, engine.currentAVPlayer === player else { return }
        applyAirPlayPolicy(to: player)

        // Other custom player screens bind to the same published AVPlayer
        // during this same update. Apply the rule once more after they've
        // all run, so a generic PiP host can't hand a credentialed remote HLS
        // URL to an AirPlay receiver that can't send its headers.
        airPlay.deferredPolicy?.cancel()
        airPlay.deferredPolicy = Task { @MainActor [weak self, weak player] in
            await Task.yield()
            guard !Task.isCancelled, let self, let player, self.isWatching(player) else { return }
            self.applyAirPlayPolicy(to: player)
            self.updateExternalPlaybackStatus()
            self.airPlay.deferredPolicy = nil
        }
    }

    private func applyAirPlayPolicy(to player: AVPlayer) {
        let allowed = mayUseExternalPlayback
        player.allowsExternalPlayback = allowed
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        #endif
    }

    /// Whether video may go to an AirPlay receiver at the moment.
    private var mayUseExternalPlayback: Bool {
        Self.externalPlaybackAllowed(
            activePolicy: receiverCanFetchActiveSource,
            preservedReplacementPolicy: airPlay.carriedPolicy,
            preservedPolicyIsReceiverSafe: carriedPolicyIsSafeForNextLoad
        )
    }

    /// A loopback route reaches the receiver through Vivid's AirPlay host
    /// rewrite. A remote HLS bypass only does when it has no custom request
    /// headers: AVURLAsset keeps those on the sending device, and a receiver
    /// can't repeat them.
    private var receiverCanFetchActiveSource: Bool {
        engine.videoRoute.isReceiverFetchable(
            hasCommittedLoad: load.committed && activeSpec != nil,
            hasCustomHeaders: activeSpec?.options.httpHeaders.isEmpty != true
        )
    }

    /// The outgoing player's setting only carries over when the next load
    /// can use the same receiver route, which header-authenticated remote
    /// HLS can't (its headers stay on the sender). This is checked as soon
    /// as `beginLoad` installs the next spec, before the engine swaps the
    /// item.
    private var carriedPolicyIsSafeForNextLoad: Bool {
        guard let options = activeSpec?.options, options.nativeRemoteHLS else { return true }
        return options.httpHeaders.isEmpty
    }

    nonisolated static func externalPlaybackAllowed(
        activePolicy: Bool,
        preservedReplacementPolicy: Bool?,
        preservedPolicyIsReceiverSafe: Bool
    ) -> Bool {
        preservedPolicyIsReceiverSafe ? (preservedReplacementPolicy ?? activePolicy) : activePolicy
    }

    private func updateExternalPlaybackStatus() {
        let current = engine.currentAVPlayer
        let playerSendsVideo = current?.isExternalPlaybackActive == true
        #if os(tvOS)
        // HDMI is how Apple TV normally plays. Captions move from Vivid's
        // overlay to the system only when AVPlayer itself sends video out.
        engine.setNativeSubtitleRendering(playerSendsVideo)
        #endif
        let active = playerSendsVideo
            || (engine.videoRoute.usesNativeVideoSession && Self.outputIsExternal)
        let supported = current != nil && (mayUseExternalPlayback || active)

        supportsExternalPlayback = supported
        isExternalPlaybackActive = active
        if supported == airPlay.reportedSupport, active == airPlay.reportedActive { return }
        airPlay.reportedSupport = supported
        airPlay.reportedActive = active
        onControllerEvent?(.externalPlaybackChanged(supported: supported, active: active))
    }

    private static var outputIsExternal: Bool {
        let externalPorts: Set<AVAudioSession.Port> = [.airPlay, .HDMI]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { externalPorts.contains($0.portType) }
    }
}

/// Whether `play()` may rebuild a torn-down session, or must leave the load
/// in flight to finish.
///
/// It's a separate, pure rule because the danger never shows on the normal
/// path: between `beginLoad` and the end of `VividEngine.load` the
/// controller passes the background-teardown test, and restoring then calls
/// `reloadAtCurrentPosition()`, a second `load` that replaces the startup
/// still running.
enum VividPlayIntent {
    enum Action: Equatable {
        /// Nothing has committed yet; the `engine.load` in flight owns the
        /// startup and plays when it finishes.
        case ignore
        /// The session is up, so just play.
        case play
        /// A committed load was torn down in the background: rebuild it,
        /// then play.
        case restoreThenPlay
    }

    static func action(
        hasCommittedActiveLoad: Bool,
        sessionRequiresRestore: Bool
    ) -> Action {
        switch (hasCommittedActiveLoad, sessionRequiresRestore) {
        case (false, _): .ignore
        case (true, true): .restoreThenPlay
        case (true, false): .play
        }
    }
}
