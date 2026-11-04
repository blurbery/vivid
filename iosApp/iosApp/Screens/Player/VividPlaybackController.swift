import AVFoundation
import Combine
import Foundation
#if os(iOS) || os(tvOS)
import MediaPlayer
#endif

/// Vivid's one owner of the video engine.
///
/// Product and session state live elsewhere. Loads, transport and engine
/// observation all go through this type, and every engine event is tagged
/// with the load it belongs to, so a replaced load's late events are dropped.
@MainActor
final class VividPlaybackController {
    // MARK: - Types

    struct EmbeddedSubtitleSelectionError: LocalizedError {
        let streamIndex: Int
        var errorDescription: String? { "The selected embedded subtitle is unavailable in the opened media." }
    }

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

    /// Changes that don't belong to one load. They still reach the player
    /// after a load is invalidated, so Now Playing and route UI can detach.
    enum ControllerEvent {
        /// The player, session or route that owns system media changed.
        case systemMediaChanged
        /// Whether external video is possible, and whether it's in use.
        case externalPlaybackChanged(supported: Bool, active: Bool)
    }

    enum SeekResult: Equatable {
        case completed(sourceSeconds: Double)
        case requiresReplan(sourceSeconds: Double)
    }

    // MARK: - State

    let engine: VividEngine
    var onEvent: ((ScopedEvent) -> Void)?
    var onControllerEvent: ((ControllerEvent) -> Void)?
    /// iOS 26's Automatic Subtitles turn captions on with no API to read
    /// them, so the engine forwarding the request is the only signal. The
    /// engine has already turned its own rendition off by then; answering
    /// means selecting a matching app track. Only sent while a load is
    /// active, tagged with its epoch.
    var onSystemCaptionRequest: ((LoadEpoch, SystemCaptionRequest) -> Void)?

    private(set) var activeSpec: VividLoadSpec?
    private(set) var activeLoadEpoch: LoadEpoch?

    /// Whether a transport call can reach anything. `play()`, `pause()` and
    /// `seek` do nothing without a load, so a system media control that
    /// reports success anyway tells the system something untrue.
    var hasActiveLoad: Bool { activeLoadEpoch != nil && activeSpec != nil }

    /// The user's latest Play or Pause, independent of passing engine states
    /// such as loading, buffering and errors. A replacement load reads it
    /// once it commits, so a Play or Pause pressed while loading wins.
    private(set) var shouldPlayWhenReady = false

    private(set) var supportsExternalPlayback = false
    private(set) var isExternalPlaybackActive = false

    /// The active spec is installed before `VividEngine.load`, so events
    /// published synchronously during the load carry the new epoch. It isn't
    /// safe for AirPlay policy until the load commits, because the engine may
    /// still be showing the outgoing AVPlayer in between.
    private var hasCommittedActiveLoad = false
    private var hasStartedEngineLoad = false
    private var generation: UInt64 = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var didPublishFirstFrame = false
    private var didPublishEnd = false
    private var lastHealthBreadcrumbAt: TimeInterval = 0
    private var transportIntentGeneration: UInt64 = 0
    private var transportRestoreTask: Task<Void, Never>?
    private var desiredPlaybackRate: Float = 1
    private var desiredVolume: Float = 1
    private var muted = false
    /// App subtitle ids (Silo sidecars, for example) and the engine ids their
    /// tracks were registered under.
    private var vividSubtitleIDByAppID: [Int64: Int] = [:]
    private var appSubtitleIDByVividID: [Int: Int64] = [:]
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var observedExternalPlaybackPlayer: AVPlayer?
    private var externalPlaybackPolicyTask: Task<Void, Never>?
    /// The outgoing native player's AirPlay policy while Vivid replaces its
    /// item. Clearing the active spec mustn't briefly revoke an active AirPlay
    /// route before the next load completes its own handoff.
    private var replacementExternalPlaybackPolicy: Bool?
    private var lastExternalPlaybackSupport = false
    private var lastExternalPlaybackActive = false

    init() throws {
        engine = try VividEngine()
        #if os(tvOS)
        // AVPlayerViewController owns the system's native video session.
        engine.ownsVideoNowPlayingSession = false
        #elseif os(iOS)
        engine.ownsVideoNowPlayingSession = true
        #endif
        applyBackgroundPlaybackPreference()
        observeEngine()
    }

    /// Hands the device's background playback choice to the engine. The engine
    /// reads it when the app goes to the background, not at load time, so
    /// reading it again at every load makes a Settings change apply to the
    /// next playback even when this controller outlives the edit.
    private func applyBackgroundPlaybackPreference() {
        engine.backgroundPlaybackEnabled = PlayerSettings.shared.backgroundPlaybackEnabled
    }

    // MARK: - Loading

    /// Sets up the load's identity synchronously, before `VividEngine.load`
    /// can publish anything for the new media.
    @discardableResult
    func beginLoad(
        _ spec: VividLoadSpec,
        shouldPlayWhenReady: Bool = true
    ) -> LoadEpoch {
        generation &+= 1
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        self.shouldPlayWhenReady = shouldPlayWhenReady
        let epoch = LoadEpoch(rawValue: generation)
        applyBackgroundPlaybackPreference()
        activeLoadEpoch = epoch
        hasCommittedActiveLoad = false
        activeSpec = spec
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        clearSubtitleAliases()
        didPublishFirstFrame = false
        didPublishEnd = false
        lastHealthBreadcrumbAt = 0
        return epoch
    }

    /// Opens the media `beginLoad` set up. Throws `CancellationError` when a
    /// newer load or a stop replaced it, and `LoadFailure` when the engine
    /// reported a typed failure.
    func finishLoad(_ epoch: LoadEpoch) async throws {
        guard epoch == activeLoadEpoch, let spec = activeSpec else {
            throw CancellationError()
        }
        do {
            hasStartedEngineLoad = true
            try await engine.load(
                url: spec.sourceURL,
                startPosition: spec.vividStartPosition,
                options: spec.options,
                audioSourceStreamIndex: spec.audioSourceStreamIndex
            )
        } catch is CancellationError {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            abandonActiveLoad()
            throw CancellationError()
        } catch {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            // The engine's typed failure, read before the load is cleared.
            let typedFailure = engine.errorInfo
            abandonActiveLoad()
            if let typedFailure {
                throw LoadFailure(failure: typedFailure, underlying: error)
            }
            throw error
        }
        guard epoch == activeLoadEpoch else {
            throw CancellationError()
        }
        hasCommittedActiveLoad = true
        replacementExternalPlaybackPolicy = nil
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    /// Forgets a load that failed or was cancelled.
    private func abandonActiveLoad() {
        activeLoadEpoch = nil
        activeSpec = nil
        replacementExternalPlaybackPolicy = nil
        clearSubtitleAliases()
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    /// Gives the active source new request headers without reloading. False
    /// when the load, URL or headers have moved on, for native remote HLS, or
    /// when the engine can't update the source in place.
    @discardableResult
    func updateSourceHeaders(_ headers: [String: String], for epoch: LoadEpoch,
                             expectedHeaders: [String: String], sourceURL: URL) -> Bool {
        guard activeLoadEpoch == epoch, var spec = activeSpec,
              spec.sourceURL == sourceURL, spec.options.httpHeaders == expectedHeaders,
              !spec.options.nativeRemoteHLS,
              engine.updateSourceHeaders(headers, for: sourceURL) else { return false }
        spec.updateHTTPHeaders(headers)
        activeSpec = spec
        return true
    }

    // MARK: - Transport

    func play() {
        shouldPlayWhenReady = true
        // `beginLoad` installs the spec and epoch before `engine.load`
        // returns, and that window looks just like a background teardown
        // (route `.none`, session not ready). Reloading here would start a
        // second `engine.load` and cancel the startup in flight, which is
        // what the Siri Remote's Play/Pause did during the loading spinner.
        switch VividPlayIntent.action(
            hasCommittedActiveLoad: hasCommittedActiveLoad,
            sessionRequiresRestore: sessionRequiresRestore
        ) {
        case .ignore:
            return
        case .play, .restoreThenPlay:
            break
        }

        transportIntentGeneration &+= 1
        let intentGeneration = transportIntentGeneration
        transportRestoreTask?.cancel()
        transportRestoreTask = Task { @MainActor [weak self] in
            guard let self,
                  let loadEpoch = self.activeLoadEpoch,
                  self.activeSpec != nil else { return }
            if self.hasCommittedActiveLoad, self.sessionRequiresRestore {
                do {
                    try await self.engine.reloadAtCurrentPosition()
                } catch is CancellationError {
                    return
                } catch {
                    guard intentGeneration == self.transportIntentGeneration,
                          loadEpoch == self.activeLoadEpoch else { return }
                    self.publish(.transportRestoreFailed(error.localizedDescription), for: loadEpoch)
                    return
                }
            }
            guard !Task.isCancelled,
                  intentGeneration == self.transportIntentGeneration,
                  loadEpoch == self.activeLoadEpoch,
                  self.activeSpec != nil,
                  self.engine.videoRoute != .none else { return }
            self.engine.play()
            self.engine.setRate(self.desiredPlaybackRate)
            self.transportRestoreTask = nil
        }
    }

    /// The session behind an active load is gone and only a reload brings it
    /// back: the state a backgrounded app returns to after Vivid's
    /// wedge-safe teardown.
    ///
    /// `videoRoute` is the supported way to ask which pipeline is serving,
    /// and `.none` means teardown (`playbackBackend` answers the same
    /// question, but hosts mustn't branch on it). Pairing it with
    /// `isSessionReady`, the flag hosts gate corrective actions on, keeps a
    /// brief reroute, where the route changes but a session still exists,
    /// from passing for a teardown.
    private var sessionRequiresRestore: Bool {
        engine.videoRoute == .none && !engine.isSessionReady
    }

    func pause() {
        shouldPlayWhenReady = false
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        engine.pause()
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0 else { return }
        guard rate > 0 else { pause(); return }
        desiredPlaybackRate = rate
        // A non-zero AVPlayer rate is also a play command. A speed change
        // mustn't undo an explicit pause; Play applies the pending speed.
        if shouldPlayWhenReady { engine.setRate(rate) }
    }

    func setSpeed(_ rate: Double) { setRate(Float(rate)) }

    func setVolume(_ volume: Float) {
        desiredVolume = min(max(volume, 0), 1)
        engine.volume = muted ? 0 : desiredVolume
    }

    func setMuted(_ value: Bool) {
        muted = value
        engine.volume = value ? 0 : desiredVolume
    }

    var volume: Float { desiredVolume }

    var isMuted: Bool { muted }

    var isPaused: Bool { engine.state != .playing }

    func seek(toSourceTime sourceSeconds: Double) async -> SeekResult {
        guard let timeline = activeSpec?.timeline else {
            return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
        }
        switch timeline.seekDisposition(forSourceTime: sourceSeconds) {
        case .local(let playerSeconds):
            // Coming back from the end-of-playback Next Up keeps this load,
            // so its next real end has to be publishable after the rewind.
            didPublishEnd = false
            let seekGeneration = generation
            await engine.seek(to: playerSeconds)
            guard seekGeneration == generation else {
                return .requiresReplan(sourceSeconds: max(0, sourceSeconds))
            }
            return .completed(sourceSeconds: timeline.sourcePosition(forPlayerTime: engine.clock.currentTime))
        case .replan(let sourceSeconds):
            return .requiresReplan(sourceSeconds: sourceSeconds)
        }
    }

    // MARK: - Replacement and teardown

    /// Pauses the outgoing item but keeps Vivid's native host mounted for the
    /// next load. That load then owns the teardown and can hand over from
    /// one native item to the next without resetting the Apple TV display
    /// criteria, replacing the player layer or releasing the shared audio
    /// session between episodes.
    func prepareForReplacement() {
        invalidateActiveLoad(preservingExternalPlaybackPolicy: true)
        engine.deactivatesAudioSessionOnStop = false
        // Otherwise the engine unloads the outgoing AVPlayerItem at the start
        // of `load`, leaving the shared player layer empty during the Next Up
        // mini player to full screen transition. On Apple TV that gap can
        // leave the layer black while the next item's audio and clock run.
        // Arm the engine's one-shot item swap before pausing the old item.
        engine.prepareForItemReplacement()
        engine.pause()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    func dispose() { stop() }

    func stop() {
        invalidateActiveLoad()
        shouldPlayWhenReady = false
        // SwiftUI can throw away an eagerly created model that never played.
        // Its clean-up mustn't deactivate another engine's shared audio
        // session or reset the active player's display criteria.
        guard hasStartedEngineLoad else {
            return
        }
        hasStartedEngineLoad = false
        // Video is the app's only playback owner, so the final teardown
        // releases the shared audio session and other apps' audio can resume.
        engine.deactivatesAudioSessionOnStop = true
        engine.stop(finalTeardown: true)
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    private func invalidateActiveLoad(preservingExternalPlaybackPolicy: Bool = false) {
        replacementExternalPlaybackPolicy = preservingExternalPlaybackPolicy
            ? observedExternalPlaybackPlayer?.allowsExternalPlayback
            : nil
        generation &+= 1
        transportIntentGeneration &+= 1
        transportRestoreTask?.cancel()
        transportRestoreTask = nil
        activeLoadEpoch = nil
        hasCommittedActiveLoad = false
        activeSpec = nil
        configureExternalPlaybackPolicy()
        clearSubtitleAliases()
        didPublishFirstFrame = false
        didPublishEnd = false
    }

    // MARK: - System media

    #if os(iOS) || os(tvOS)
    /// The player's native video session. It exists only once a native host
    /// has been built, and is nil on the software route.
    var videoNowPlayingSession: MPNowPlayingSession? {
        guard engine.videoRoute.usesNativeVideoSession else {
            return nil
        }
        return engine.videoNowPlayingSession
    }
    #endif

    /// The app-wide Now Playing centres are only a fallback, for video routes
    /// without an `MPNowPlayingSession`.
    var shouldUseSharedVideoNowPlayingFallback: Bool {
        engine.videoRoute == .sampleBuffer
    }

    // MARK: - Tracks

    func validateEmbeddedSubtitleSelection(_ streamIndex: Int) throws {
        guard engine.subtitleTracks.contains(where: { !$0.isExternal && $0.id == streamIndex }) else {
            throw EmbeddedSubtitleSelectionError(streamIndex: streamIndex)
        }
    }

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    func selectSubtitleTrack(id: Int64?) {
        if let id, let vividID = vividSubtitleID(forAppID: id) {
            engine.selectSubtitleTrack(index: vividID)
        } else {
            engine.clearSubtitle()
        }
    }

    func selectSecondarySubtitleTrack(id: Int64?) {
        if let id, let vividID = vividSubtitleID(forAppID: id) {
            engine.selectSecondarySubtitleTrack(index: vividID)
        } else {
            engine.clearSecondarySubtitle()
        }
    }

    func appSubtitleID(forVividID id: Int) -> Int64 {
        appSubtitleIDByVividID[id] ?? Int64(id)
    }

    /// The inverse of `appSubtitleID(forVividID:)`. Internal so the boundary
    /// tests can check the two round-trip.
    func vividSubtitleID(forAppID id: Int64) -> Int? {
        if let translated = vividSubtitleIDByAppID[id] {
            return translated
        }
        // A Silo sidecar id isn't an engine id. Passed through unaliased, it
        // reaches the engine as an unknown external id and is quietly
        // ignored, leaving the previous subtitle on screen.
        guard !SubtitleTrackIdSpace.isSidecar(id) else { return nil }
        return Int(exactly: id)
    }

    /// Whether the subtitle runs on the movie's timeline (an external file)
    /// rather than the stream's. Without a track id, only the primary slot
    /// can answer, from the engine's active track.
    func subtitleUsesMovieTimeline(appTrackID: Int64?, slot: SubtitleSlot) -> Bool {
        let engineID: Int?
        if let appTrackID {
            engineID = vividSubtitleID(forAppID: appTrackID)
        } else {
            engineID = slot == .primary ? engine.activeSubtitleTrackIndex : nil
        }
        return engine.subtitleTracks.contains { $0.id == engineID && $0.isExternal }
    }

    func containsSubtitle(appTrackID: Int64) -> Bool {
        vividSubtitleIDByAppID[appTrackID] != nil
            || engine.subtitleTracks.contains { !$0.isExternal && Int64($0.id) == appTrackID }
    }

    /// Registers an external subtitle with the engine under `appTrackID`,
    /// once per load.
    @discardableResult
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack, appTrackID: Int64) -> Int64 {
        if vividSubtitleIDByAppID[appTrackID] != nil { return appTrackID }
        var track = track
        // Sidecars use movie timestamps; native ASS renders on the stream clock.
        track.nativeTimelineOffsetSeconds = activeSpec?.timeline.timelineOffsetSeconds ?? 0
        let registered = engine.addExternalSubtitleTrack(track)
        vividSubtitleIDByAppID[appTrackID] = registered.id
        appSubtitleIDByVividID[registered.id] = appTrackID
        return appTrackID
    }

    private func clearSubtitleAliases() {
        vividSubtitleIDByAppID = [:]
        appSubtitleIDByVividID = [:]
    }

    // MARK: - Engine events

    private func observeEngine() {
        engine.$state
            .sink { [weak self] state in
                guard let self else { return }
                publish(.state(state))
                if state == .ended, !didPublishEnd {
                    didPublishEnd = true
                    publish(.ended)
                }
            }
            .store(in: &subscriptions)

        engine.$playbackPhase
            .sink { [weak self] phase in self?.publish(.phase(phase)) }
            .store(in: &subscriptions)

        engine.clock.$currentTime
            .sink { [weak self] time in self?.publish(.playerTime(time)) }
            .store(in: &subscriptions)

        engine.$duration
            .sink { [weak self] duration in self?.publish(.duration(duration)) }
            .store(in: &subscriptions)

        engine.$isBuffering
            .sink { [weak self] buffering in self?.publish(.buffering(buffering)) }
            .store(in: &subscriptions)

        engine.$isLoadingSubtitles
            .removeDuplicates()
            .sink { [weak self] loading in self?.publish(.subtitleLoading(loading)) }
            .store(in: &subscriptions)

        #if DEBUG && (os(iOS) || os(tvOS))
        engine.$startupProgress
            .compactMap { $0?.checkpoint }
            .removeDuplicates()
            .sink { checkpoint in
                DiagTrace.breadcrumb(.essential,
                    category: .playback,
                    tag: "StartupTiming",
                    message: "engine \(checkpoint)"
                )
            }
            .store(in: &subscriptions)
        #endif

        engine.$hasFirstFrameReadyForDisplay
            .sink { [weak self] ready in
                guard let self, ready, !didPublishFirstFrame else { return }
                didPublishFirstFrame = true
                publish(.firstFrame)
            }
            .store(in: &subscriptions)

        engine.$errorInfo
            .compactMap { $0 }
            .sink { [weak self] error in self?.publish(.failure(error)) }
            .store(in: &subscriptions)

        Publishers.Merge3(
            engine.$audioTracks.map { _ in () },
            engine.$subtitleTracks.map { _ in () },
            engine.$mediaChapters.map { _ in () }
        )
        // @Published sends before the new value is stored, and the inventory
        // event reads the engine, so it's delivered once the current
        // assignments have finished.
        .compactMap { [weak self] _ in self?.activeLoadEpoch }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] epoch in self?.publish(.inventoryChanged, for: epoch) }
        .store(in: &subscriptions)

        engine.diagnostics.$liveTelemetry
            // @Published sends before the value is stored. Forward the value
            // sent, so recovery and statistics never read the previous sample.
            .sink { [weak self] telemetry in self?.publish(.telemetryChanged(telemetry)) }
            .store(in: &subscriptions)

        engine.systemCaptionRequest
            .sink { [weak self] request in
                guard let self, let epoch = activeLoadEpoch else { return }
                onSystemCaptionRequest?(epoch, request)
            }
            .store(in: &subscriptions)

        engine.$currentAVPlayer
            .sink { [weak self] player in
                guard let self else { return }
                bindExternalPlayback(to: player)
                publishSystemMediaChanged()
            }
            .store(in: &subscriptions)

        // A native host can keep its AVPlayer while replacing the item, so the
        // AirPlay policy and session binding are applied again at that point.
        engine.$currentAVPlayerItem
            .sink { [weak self] _ in self?.externalRouteMayHaveChanged() }
            .store(in: &subscriptions)

        engine.$videoRoute
            .sink { [weak self] _ in self?.externalRouteMayHaveChanged() }
            .store(in: &subscriptions)

        #if os(iOS) || os(tvOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in self?.refreshExternalPlaybackState() }
            .store(in: &subscriptions)
        #endif
    }

    private func publishSystemMediaChanged() {
        onControllerEvent?(.systemMediaChanged)
    }

    /// Sends an engine event tagged with the active load. An event meant for
    /// a specific `epoch` is dropped once another load is active.
    private func publish(_ event: Event, for epoch: LoadEpoch? = nil) {
        guard let activeLoadEpoch,
              epoch == nil || epoch == activeLoadEpoch else { return }
        onEvent?(ScopedEvent(epoch: activeLoadEpoch, event: event))
    }

    // MARK: - AirPlay and external playback

    private func externalRouteMayHaveChanged() {
        configureExternalPlaybackPolicy()
        refreshExternalPlaybackState()
        publishSystemMediaChanged()
    }

    private func bindExternalPlayback(to player: AVPlayer?) {
        externalPlaybackPolicyTask?.cancel()
        externalPlaybackPolicyTask = nil
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        observedExternalPlaybackPlayer = player
        configureExternalPlaybackPolicy()

        guard let player else {
            refreshExternalPlaybackState()
            return
        }
        externalPlaybackObservation = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player,
                      self.observedExternalPlaybackPlayer === player,
                      self.engine.currentAVPlayer === player else { return }
                self.refreshExternalPlaybackState()
            }
        }
    }

    private func configureExternalPlaybackPolicy() {
        guard let player = observedExternalPlaybackPlayer,
              engine.currentAVPlayer === player else { return }
        applyExternalPlaybackPolicy(to: player)

        // Other custom player UIs bind to the same published AVPlayer. Apply
        // the policy again once that synchronous fan-out has finished, so a
        // generic PiP host can't reopen a credentialed remote HLS URL to an
        // AirPlay receiver that can't send its headers.
        externalPlaybackPolicyTask?.cancel()
        externalPlaybackPolicyTask = Task { @MainActor [weak self, weak player] in
            await Task.yield()
            guard !Task.isCancelled,
                  let self, let player,
                  self.observedExternalPlaybackPlayer === player,
                  self.engine.currentAVPlayer === player else { return }
            self.applyExternalPlaybackPolicy(to: player)
            self.refreshExternalPlaybackState()
            self.externalPlaybackPolicyTask = nil
        }
    }

    private func applyExternalPlaybackPolicy(to player: AVPlayer) {
        let allowed = allowsExternalPlayback
        player.allowsExternalPlayback = allowed
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        #endif
    }

    /// Whether the player may send video to an AirPlay receiver right now.
    private var allowsExternalPlayback: Bool {
        Self.externalPlaybackAllowed(
            activePolicy: externalPlaybackIsReceiverFetchable,
            preservedReplacementPolicy: replacementExternalPlaybackPolicy,
            preservedPolicyIsReceiverSafe: preservedReplacementPolicyIsReceiverSafe
        )
    }

    /// A loopback route reaches a receiver through Vivid's AirPlay host
    /// rewrite. A remote HLS bypass only does without custom request headers:
    /// AVURLAsset headers stay on the sending device and aren't credentials an
    /// AirPlay receiver can repeat.
    private var externalPlaybackIsReceiverFetchable: Bool {
        engine.videoRoute.isReceiverFetchable(
            hasCommittedLoad: hasCommittedActiveLoad && activeSpec != nil,
            hasCustomHeaders: activeSpec?.options.httpHeaders.isEmpty != true
        )
    }

    /// The outgoing player's policy can only carry over when the next load
    /// can use the same receiver route. Header-authenticated remote HLS
    /// can't, because its AVURLAsset headers stay on the sender. This is
    /// checked as soon as `beginLoad` installs the next spec, before the
    /// engine swaps the item on its AVPlayer.
    private var preservedReplacementPolicyIsReceiverSafe: Bool {
        guard activeSpec?.options.nativeRemoteHLS == true else { return true }
        return activeSpec?.options.httpHeaders.isEmpty == true
    }

    nonisolated static func externalPlaybackAllowed(
        activePolicy: Bool,
        preservedReplacementPolicy: Bool?,
        preservedPolicyIsReceiverSafe: Bool
    ) -> Bool {
        guard preservedPolicyIsReceiverSafe else { return activePolicy }
        return preservedReplacementPolicy ?? activePolicy
    }

    private func refreshExternalPlaybackState() {
        let player = engine.currentAVPlayer
        let playerIsActive = player?.isExternalPlaybackActive == true
        #if os(tvOS)
        // HDMI is Apple TV's normal output. Only AVPlayer's own external video
        // state hands captions from Vivid's overlay to the system.
        engine.setNativeSubtitleRendering(playerIsActive)
        #endif
        let routeIsActive = playerIsActive
            || (engine.videoRoute.usesNativeVideoSession && Self.isExternalOutputRoute)
        let supported = player != nil && (allowsExternalPlayback || routeIsActive)

        supportsExternalPlayback = supported
        isExternalPlaybackActive = routeIsActive
        guard supported != lastExternalPlaybackSupport
                || routeIsActive != lastExternalPlaybackActive else { return }
        lastExternalPlaybackSupport = supported
        lastExternalPlaybackActive = routeIsActive
        onControllerEvent?(.externalPlaybackChanged(supported: supported, active: routeIsActive))
    }

    private static var isExternalOutputRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay || $0.portType == .HDMI
        }
    }
}

/// Whether `play()` may restore a torn-down session or has to wait for the
/// load in flight to commit.
///
/// A separate pure decision, because the hazard never shows on the happy
/// path: `beginLoad` installs the spec and epoch before `VividEngine.load`
/// returns, and that window matches the background teardown test. A Play
/// then would call `reloadAtCurrentPosition()`, another `load` that replaces
/// the startup in flight.
enum VividPlayIntent {
    enum Action: Equatable {
        /// No committed load yet. The `engine.load` in flight still owns
        /// startup and plays when it commits.
        case ignore
        /// The session is live; start playing.
        case play
        /// A committed load was torn down in the background; rebuild, then play.
        case restoreThenPlay
    }

    static func action(
        hasCommittedActiveLoad: Bool,
        sessionRequiresRestore: Bool
    ) -> Action {
        guard hasCommittedActiveLoad else { return .ignore }
        return sessionRequiresRestore ? .restoreThenPlay : .play
    }
}
