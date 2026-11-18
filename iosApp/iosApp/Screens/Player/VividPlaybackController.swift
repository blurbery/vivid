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
        /// Work the AirPlay video hand-off needs from the player (iPhone and
        /// iPad only).
        case airPlayHandOff(AirPlayHandOffRequest)
    }

    /// What the AirPlay hand-off asks of the player, which owns the server
    /// session and the load requests.
    enum AirPlayHandOffRequest {
        /// Prepare a receiver session; answer with `airPlayStreamArrived` or
        /// `airPlayStreamFailed` for the same request.
        case requestStream(request: Int)
        /// Commit a prepared receiver session, retiring the live session at
        /// `position`; answer with `airPlayCommitFinished`.
        case commitStream(request: Int, stream: AirPlayReceiverStream, position: Double)
        /// Bring Lucid back at this source position with a fresh load.
        case resumeLucid(at: Double)
        /// End a prepared receiver session nothing will commit.
        case releaseStream(AirPlayReceiverStream)
        /// Run the output-route check the probe held back.
        case recheckOutputRoute
        /// The receiver's clock is moving.
        case receiverStarted
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
        /// The AirPlay hand-off state last reported with them, so the player
        /// always hears when it changes.
        var reportedHandOff = false
    }

    private var load = LoadProgress()
    private var transport = Transport()
    private var airPlay = AirPlayTracking()
    #if os(iOS)
    /// The AirPlay video hand-off. While `handOffEngaged`, Lucid is paused
    /// and muted, the transport drives the receiver's player, and the
    /// engine's playback signals are held back.
    private let airPlayVideo = AirPlayVideoHandOff()
    private var handOffPolicy = AirPlayHandOffPolicy()
    private var handOffEngaged = false
    /// Prepared receiver streams by request, until they're started or
    /// released. Held in memory only: their URLs carry a credential.
    private var receiverStreams: [Int: AirPlayReceiverStream] = [:]
    /// Set by the player: the current load could be handed off at all.
    private var airPlayHandOffAvailable = false
    #endif
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
        #if os(iOS)
        airPlayVideo.onSignal = { [weak self] in self?.airPlayVideoSignal($0) }
        #endif
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
        #if os(iOS)
        handleHandOff(.loadReplaced)
        // The player says again once this load has settled.
        airPlayHandOffAvailable = false
        #endif
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
        #if os(iOS)
        if handOffEngaged {
            _ = startTransportIntent()
            airPlayVideo.play()
            return
        }
        #endif
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
        #if os(iOS)
        if handOffEngaged {
            airPlayVideo.pause()
            return
        }
        #endif
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
        #if os(iOS)
        if handOffEngaged {
            airPlayVideo.setRate(rate)
            return
        }
        #endif
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
        // A hand-off keeps Lucid silent whatever the viewer's volume, gives
        // the viewer's setting to the receiver meanwhile, and back to Lucid
        // when it ends.
        engine.volume = transport.muted || isAirPlayHandOffEngaged ? 0 : transport.volume
        #if os(iOS)
        airPlayVideo.setVolume(transport.volume, muted: transport.muted)
        #endif
    }

    var volume: Float { transport.volume }

    var isMuted: Bool { transport.muted }

    var isPaused: Bool {
        #if os(iOS)
        if handOffEngaged { return airPlayVideo.isPaused }
        #endif
        return engine.state != .playing
    }

    /// Whether a seek is still landing, on whichever player has the title.
    var isSeeking: Bool {
        #if os(iOS)
        if handOffEngaged { return airPlayVideo.isSeeking }
        #endif
        return engine.isSeeking
    }

    func seek(toSourceTime sourceSeconds: Double) async -> SeekResult {
        #if os(iOS)
        if handOffEngaged {
            // The receiver stream covers the title, so a seek stays on it and
            // never asks for a replan.
            load.endSent = false
            let target = max(0, sourceSeconds.isFinite ? sourceSeconds : 0)
            // A stream not yet on the player (or a restart waiting) starts at
            // the target instead.
            handleHandOff(.seekRequested(position: target))
            guard airPlayVideo.hasStream else { return .completed(sourceSeconds: target) }
            if airPlayVideo.needsNewStream(forSourceTime: target) {
                // Before the start of a stream that began mid-title (a Silo
                // transcode): a new stream starts at the target, now or once
                // a commit that's out lands.
                handleHandOff(.restartRequested(position: target))
                return .completed(sourceSeconds: target)
            }
            await airPlayVideo.seek(toSourceTime: target)
            let landed = handOffEngaged ? airPlayVideo.sourcePosition : max(0, sourceSeconds)
            return .completed(sourceSeconds: landed)
        }
        #endif
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
        #if os(iOS)
        handleHandOff(.loadReplaced)
        #endif
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
        #if os(iOS)
        handleHandOff(.userStopped)
        airPlayHandOffAvailable = false
        #endif
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

    /// While an AirPlay hand-off is engaged the paused, muted engine isn't
    /// what the viewer is watching: its state, clock, buffering, first frame
    /// and failures are held back, and the receiver's are sent instead.
    private func observePlaybackSignals() {
        engine.$state
            .sink { [weak self] state in self?.engineSignal { $0.engineStateChanged(state) } }
            .store(in: &engineObservers)
        engine.$playbackPhase
            .sink { [weak self] phase in self?.engineSignal { $0.emit(.phase(phase)) } }
            .store(in: &engineObservers)
        engine.clock.$currentTime
            .sink { [weak self] time in self?.engineSignal { $0.emit(.playerTime(time)) } }
            .store(in: &engineObservers)
        engine.$duration
            .sink { [weak self] in self?.emit(.duration($0)) }
            .store(in: &engineObservers)
        engine.$isBuffering
            .sink { [weak self] buffering in self?.engineSignal { $0.emit(.buffering(buffering)) } }
            .store(in: &engineObservers)
        engine.$isLoadingSubtitles
            .removeDuplicates()
            .sink { [weak self] loading in self?.engineSignal { $0.emit(.subtitleLoading(loading)) } }
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
            .sink { [weak self] ready in self?.engineSignal { $0.firstFrameReadinessChanged(ready) } }
            .store(in: &engineObservers)
        engine.$errorInfo
            .compactMap { $0 }
            .sink { [weak self] failure in self?.engineSignal { $0.emit(.failure(failure)) } }
            .store(in: &engineObservers)
    }

    /// Runs an engine playback signal unless a hand-off holds them back.
    private func engineSignal(_ forward: (VividPlaybackController) -> Void) {
        guard !isAirPlayHandOffEngaged else { return }
        forward(self)
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
        var active = playerSendsVideo
            || (engine.videoRoute.usesNativeVideoSession && Self.outputIsExternal)
        var supported = current != nil && (mayUseExternalPlayback || active)
        #if os(iOS)
        // Lucid's own picture never goes to a receiver; a video title is
        // handed to `AirPlayVideoHandOff` instead. The route button shows
        // only where that could happen: a committed video load on Lucid's
        // own route that the player says a receiver could take, outside
        // Picture in Picture. This is only the status: the engine AVPlayer's
        // AirPlay setting above stays as it was.
        let handOffPossible = airPlayHandOffAvailable && load.committed
            && activeSpec?.options.audioOnly == false && engine.videoRoute == .sampleBuffer
            && !engine.pictureInPictureActive
        supported = supported || handOffPossible || handOffEngaged
        active = active || handOffEngaged
        #endif

        supportsExternalPlayback = supported
        isExternalPlaybackActive = active
        if supported == airPlay.reportedSupport, active == airPlay.reportedActive,
           isAirPlayHandOffEngaged == airPlay.reportedHandOff { return }
        airPlay.reportedSupport = supported
        airPlay.reportedActive = active
        airPlay.reportedHandOff = isAirPlayHandOffEngaged
        onControllerEvent?(.externalPlaybackChanged(supported: supported, active: active))
    }

    private static var outputIsExternal: Bool {
        let externalPorts: Set<AVAudioSession.Port> = [.airPlay, .HDMI]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { externalPorts.contains($0.portType) }
    }

    // MARK: - AirPlay video hand-off

    /// True while an AirPlay receiver plays the title and Lucid waits paused
    /// and muted. Always false on Apple TV.
    var isAirPlayHandOffEngaged: Bool {
        #if os(iOS)
        return handOffEngaged
        #else
        return false
        #endif
    }

    /// True while the probe or the hand-off owns the output route, so a
    /// route change mustn't replan Lucid's stream.
    var airPlayHandOffOwnsOutputRoute: Bool {
        #if os(iOS)
        return handOffPolicy.ownsOutputRoute
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// The player says whether the current load could be handed to a
    /// receiver at all (a server stream with a receiver route), which is
    /// when the AirPlay button shows.
    func setAirPlayHandOffAvailable(_ available: Bool) {
        guard airPlayHandOffAvailable != available else { return }
        airPlayHandOffAvailable = available
        updateExternalPlaybackStatus()
    }

    /// Reads Picture in Picture and the load again for the AirPlay button.
    func refreshExternalPlaybackStatus() {
        updateExternalPlaybackStatus()
    }

    /// The player reports the output route: `routeID` names the AirPlay
    /// outputs, or is nil for a local route. `canHandOff` says whether the
    /// current load could be handed to a receiver right now.
    func airPlayRouteChanged(routeID: String?, canHandOff: Bool) {
        guard let routeID else {
            handleHandOff(.routeBecameLocal)
            return
        }
        guard canHandOff else { return }
        handleHandOff(.airPlayRouteAppeared(route: routeID))
    }

    /// The AirPlay route picker closed, which may have been to pick the same
    /// receiver again; the player checks the route right after.
    func airPlayRoutePickerClosed() {
        handleHandOff(.routePickerClosed)
    }

    /// Answers `requestStream` with a prepared receiver session.
    /// `lucidPosition` is where playback is now, on the source axis.
    func airPlayStreamArrived(_ stream: AirPlayReceiverStream, request: Int, lucidPosition: Double) {
        receiverStreams[request] = stream
        handleHandOff(.streamReady(request: request, position: lucidPosition))
    }

    func airPlayStreamFailed(request: Int) {
        handleHandOff(.streamFailed(request: request))
    }

    /// The player can't hand off right now after all; the route gets tried
    /// again once that clears.
    func airPlayHandOffBlocked(request: Int) {
        handleHandOff(.handOffBlocked(request: request))
    }

    /// Answers `commitStream`. The stream is let go afterwards: a first
    /// stream starts as its commit lands, a restart's was already started.
    func airPlayCommitFinished(request: Int, result: AirPlayReceiverCommit) {
        defer { receiverStreams[request] = nil }
        handleHandOff(.commitFinished(request: request, result: result))
    }

    /// Replaces the receiver stream with one for the current tracks and
    /// quality, at the current position, now or once a commit that's out
    /// lands. False when no hand-off is running, so the change is Lucid's.
    @discardableResult
    func restartAirPlayReceiverStream() -> Bool {
        handleHandOff(.restartRequested(position: nil))
        return handOffPolicy.isActive
    }

    @discardableResult
    private func handleHandOff(_ event: AirPlayHandOffPolicy.Event) -> [AirPlayHandOffPolicy.Effect] {
        let effects = handOffPolicy.handle(event)
        guard !effects.isEmpty else { return effects }
        for effect in effects { applyHandOff(effect) }
        updateExternalPlaybackStatus()
        return effects
    }

    private func applyHandOff(_ effect: AirPlayHandOffPolicy.Effect) {
        switch effect {
        case .startProbe:
            recordHandOff("probe")
            airPlayVideo.startProbe()
        case .stopProbe:
            airPlayVideo.stop()
        case .requestStream(let request):
            recordHandOff("request_stream")
            onControllerEvent?(.airPlayHandOff(.requestStream(request: request)))
        case .pauseAndMuteLucid:
            engageHandOff()
        case .commitStream(let request, let position):
            guard let stream = receiverStreams[request] else {
                handleHandOff(.commitFinished(request: request, result: .refused))
                return
            }
            onControllerEvent?(.airPlayHandOff(.commitStream(request: request, stream: stream, position: position)))
        case .startStream(let request, let position):
            guard let stream = receiverStreams[request] else { return }
            recordHandOff("start transcode=\(stream.isTranscode)")
            // The existing spinner covers the receiver's startup.
            emit(.phase(.loading))
            airPlayVideo.play(stream, atSourceTime: position, autoplay: shouldPlayWhenReady, rate: transport.rate)
            if airPlayVideo.needsNewStream(forSourceTime: position) {
                // A seek made during the commit went before this stream's
                // start (a Silo transcode), so another stream starts there.
                handleHandOff(.restartRequested(position: position))
            }
        case .resumeLucid(let position):
            onControllerEvent?(.airPlayHandOff(.resumeLucid(at: position)))
        case .resumeLucidInPlace:
            // Lucid never lost its session: it plays on where it paused, as
            // the viewer last asked. Paused, the engine's own state goes out
            // again, since its pause was held back while engaged.
            if shouldPlayWhenReady {
                play()
            } else {
                emit(.state(engine.state))
                emit(.phase(engine.playbackPhase))
            }
        case .endHandOff(let reason):
            recordHandOff("end reason=\(reason.rawValue)")
            airPlayVideo.stop()
            disengageHandOff()
        case .releaseStream(let request):
            guard let stream = receiverStreams.removeValue(forKey: request) else { return }
            onControllerEvent?(.airPlayHandOff(.releaseStream(stream)))
        case .recheckOutputRoute:
            onControllerEvent?(.airPlayHandOff(.recheckOutputRoute))
        }
    }

    /// Lucid steps aside before the receiver session is committed: paused
    /// with the engine directly, so `shouldPlayWhenReady` keeps following
    /// the viewer for the receiver and for the reload that ends the
    /// hand-off. Its picture is hidden (leaving the plain black video area),
    /// Picture in Picture is held back, and background playback is kept on
    /// so leaving the app can't tear down the audio session the receiver's
    /// player shares.
    private func engageHandOff() {
        guard !handOffEngaged else { return }
        _ = startTransportIntent()
        handOffEngaged = true
        engine.pause()
        applyVolume()
        engine.backgroundPlaybackEnabled = true
        engine.setPictureHiddenForAirPlay(true)
        PictureInPictureCoordinator.shared.setSuppressed(true, for: engine)
    }

    private func disengageHandOff() {
        guard handOffEngaged else { return }
        handOffEngaged = false
        receiverStreams.removeAll()
        applyVolume()
        syncBackgroundPlaybackSetting()
        engine.setPictureHiddenForAirPlay(false)
        PictureInPictureCoordinator.shared.setSuppressed(false, for: engine)
    }

    private func airPlayVideoSignal(_ signal: AirPlayVideoHandOff.Signal) {
        switch signal {
        case .probeExternalActive:
            handleHandOff(.probeExternalActive)
        case .probeTimedOut:
            handleHandOff(.probeTimedOut)
        case .probeFailed:
            handleHandOff(.probeFailed)
        case .prepareTimedOut:
            handleHandOff(.prepareTimedOut)
        case .playbackStarted:
            handleHandOff(.playbackStarted)
            if handOffEngaged {
                onControllerEvent?(.airPlayHandOff(.receiverStarted))
            }
        case .startTimedOut:
            handleHandOff(.startTimedOut)
        case .externalLost:
            handleHandOff(.externalLost)
        case .externalRestored:
            handleHandOff(.externalRestored)
        case .externalLostDebounced:
            handleHandOff(.externalLostDebounced(position: airPlayVideo.sourcePosition))
        case .receiverFailed:
            handleHandOff(.receiverFailed(position: airPlayVideo.sourcePosition))
        case .ended:
            guard handOffEngaged, let epoch = activeLoadEpoch else { return }
            // The receiver keeps the title paused at its end, so the normal
            // end of the item (Next Up, completion, Replay or a scrub back)
            // runs against it rather than against Lucid's retired session.
            handleHandOff(.playbackEnded)
            emit(.state(.ended), for: epoch)
            guard !load.endSent else { return }
            load.endSent = true
            emit(.ended, for: epoch)
        case .playing(let playing):
            guard handOffEngaged else { return }
            // What the receiver does doesn't change what the viewer asked
            // for: a receiver pausing as it disconnects mustn't leave Lucid
            // paused on the way back.
            emit(.state(playing ? .playing : .paused))
            emit(.phase(playing ? .playing : .paused))
        case .buffering(let buffering):
            guard handOffEngaged else { return }
            emit(.buffering(buffering))
            emit(.phase(buffering ? .rebuffering : (airPlayVideo.isPaused ? .paused : .playing)))
        case .time(let sourceSeconds):
            guard handOffEngaged, let timeline = activeSpec?.timeline else { return }
            // Unclamped, so the player's own source mapping gives exactly
            // `sourceSeconds` back, even before a re-anchored Silo
            // transport's offset.
            emit(.playerTime(sourceSeconds - timeline.timelineOffsetSeconds))
        }
    }

    /// A diagnostics breadcrumb without the stream URL or any server
    /// identity.
    private func recordHandOff(_ message: String) {
        DiagTrace.breadcrumb(.essential, category: .playback, tag: "airplay_video_handoff", message: message)
    }
    #endif
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
