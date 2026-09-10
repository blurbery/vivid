// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine
import Foundation

@MainActor
public final class VividPlayer: ObservableObject {
    #if os(tvOS)
    public var nativeDTSBridgeEnabled = false
    #endif
    public enum State: Equatable { case idle, opening, paused, playing, buffering, ended, failed }
    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var subtitleCues: [VividSubtitleCue] = []
    @Published public private(set) var chapters: [VividChapter] = []
    @Published public private(set) var tracks: [VividTrack] = []
    @Published public private(set) var error: VividPlaybackError?
    @Published public private(set) var bufferedAhead: Double = 0
    @Published public private(set) var decodedAhead: Double = 0
    @Published public private(set) var nativeAudioDecode = false
    @Published public private(set) var hardwareVideoDecode = false
    @Published public private(set) var selectedAudioTrack: Int?
    @Published public private(set) var hasPresentedVideo = false
    #if os(tvOS)
    @Published public private(set) var displayFormatDescription: CMVideoFormatDescription?
    #endif
    public let displayLayer = AVSampleBufferDisplayLayer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public var volume: Float = 1 { didSet { audioRenderer.volume = max(0, min(volume, 1)) } }
    public var videoGravity: AVLayerVideoGravity = .resizeAspect { didSet { displayLayer.videoGravity = videoGravity } }
    public var bufferAheadTarget: Double = 10 {
        didSet { session?.setBufferTarget(seconds: bufferAheadTarget) }
    }

    private var session: VividMediaSession?
    private var source: VividSource?
    private var generation: UInt64 = 0
    private var wantsPlayback = false
    #if os(tvOS)
    private var hasStartedPlayback = false
    private var audioOutputObservers: [NSObjectProtocol] = []
    private var audioRecoveryTask: Task<Void, Never>?
    private var audioRecoveryBudget = VividAudioRecoveryBudget()
    private var airPlayRecovery = VividAirPlayRecovery()
    private var clockStall = VividClockStallDetector()
    private var hdmiAudio = VividHDMIAudioCore()
    private var hdmiRouteActive = false
    #if DEBUG
    private let hdmiAudioEnabled = VividHDMIAudioCore.enabled(
        debugBuild: true, arguments: ProcessInfo.processInfo.arguments
    )
    #else
    private let hdmiAudioEnabled = VividHDMIAudioCore.enabled(debugBuild: false, arguments: [])
    #endif
    #endif
    private var audioOnly = false
    private var softwareAudio = false
    private var selectedSubtitles: Set<Int> = []
    private var preferredAudioLanguages: [String] = []
    private var rate: Float = 1
    private var timer: Timer?
    private var startPosition: Double = 0
    private var flushTask: Task<Void, Never>?
    private var seekGeneration: UInt64 = 0
    #if os(tvOS) && DEBUG
    private var lastTVProbe = Date.distantPast
    #endif

    public init() {
        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
        #if os(tvOS)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        #else
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        #endif
        #if os(tvOS)
        for name in [NSNotification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
                     NSNotification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange] {
            audioOutputObservers.append(NotificationCenter.default.addObserver(forName: name, object: audioRenderer, queue: nil) { [weak self] note in
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                    print("[VividTVProbe] rendererNotification=\(note.name.rawValue)")
                }
                #endif
                Task { @MainActor [weak self] in self?.recoverAudioOutput() }
            })
        }
        #endif
    }

    public func load(_ source: VividSource, at seconds: Double = 0, autoplay: Bool = true,
                     audioTrack: Int? = nil, audioTrackOrdinal: Int? = nil, audioOnly: Bool = false, preferredAudioLanguages: [String] = [], forceSoftwareAudio: Bool = false) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw VividPlaybackError.invalidSource }
        stop()
        let epoch = generation
        await flushTask?.value
        guard generation == epoch else { throw CancellationError() }
        self.source = source
        self.audioOnly = audioOnly
        self.softwareAudio = forceSoftwareAudio
        self.preferredAudioLanguages = preferredAudioLanguages
        startPosition = seconds
        currentTime = seconds
        selectedAudioTrack = audioTrack
        wantsPlayback = autoplay
        state = .opening
        error = nil
        let input = try VividNetwork(source)
        let next = VividMediaSession(source: input, video: displayLayer.sampleBufferRenderer, audio: audioRenderer,
                                    synchronizer: synchronizer, start: seconds, audioTrack: audioTrack, audioTrackOrdinal: audioTrackOrdinal, audioOnly: audioOnly, preferredAudioLanguages: preferredAudioLanguages, forceSoftwareAudio: forceSoftwareAudio)
        session = next
        #if os(tvOS)
        next.nativeDTSBridgeEnabled = nativeDTSBridgeEnabled && !audioOnly
        next.setAudioOutputLatency(AVAudioSession.sharedInstance().outputLatency)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = true
        #endif
        next.setBufferTarget(seconds: bufferAheadTarget)
        do {
            let inventory = try await withTaskCancellationHandler {
                try await next.open()
            } onCancel: { next.cancel() }
            try Task.checkCancellation()
            guard generation == epoch else { next.cancel(); throw CancellationError() }
            nativeAudioDecode = next.snapshot().nativeAudio
            tracks = inventory.tracks
            chapters = inventory.chapters
            duration = inventory.duration
            selectedAudioTrack = inventory.audio
            synchronizer.setRate(0, time: CMTime(seconds: seconds, preferredTimescale: 1_000_000))
            next.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch {
            next.cancel()
            if generation == epoch {
                self.error = (error as? VividPlaybackError) ?? .cancelled
                state = error is CancellationError ? .idle : .failed
            }
            throw error
        }
    }

    public func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool {
        guard let source, source.url == url, state != .idle, state != .failed, state != .ended,
              session?.updateSourceHeaders(headers) == true else { return false }
        self.source = VividSource(url: source.url, headers: headers, recoveryBudget: source.recoveryBudget,
                                  refreshHeaders: source.refreshHeaders)
        return true
    }

    public func play() { wantsPlayback = true; poll() }
    public func pause() {
        #if os(tvOS)
        hdmiAudio.suspend()
        clockStall = VividClockStallDetector()
        #endif
        wantsPlayback = false
        synchronizer.rate = 0
        if state != .idle && state != .failed && state != .ended { state = .paused }
    }
    public func setRate(_ value: Float) {
        guard value.isFinite, value > 0, value <= 3 else { return }
        rate = value
        if state == .playing { synchronizer.rate = value }
    }
    public func seek(to seconds: Double) async throws {
        guard let session else { return }
        guard seconds.isFinite, seconds >= 0 else { throw VividPlaybackError.invalidSource }
        let target = duration > 0 ? min(seconds, duration) : seconds
        #if os(tvOS)
        hdmiAudio.suspend()
        clockStall = VividClockStallDetector()
        #endif
        seekGeneration &+= 1
        let epoch = seekGeneration
        let loadEpoch = generation
        timer?.invalidate(); timer = nil
        synchronizer.rate = 0
        state = .opening
        do { try await session.seek(to: target) }
        catch {
            if generation == loadEpoch, seekGeneration == epoch {
                self.error = (error as? VividPlaybackError) ?? .cancelled
                state = .failed
                session.cancel()
            }
            throw error
        }
        guard generation == loadEpoch, seekGeneration == epoch else { throw CancellationError() }
        startPosition = target
        currentTime = target
        synchronizer.setRate(0, time: CMTime(seconds: target, preferredTimescale: 1_000_000))
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }
    public func selectAudioTrack(_ id: Int) async throws {
        guard let source, tracks.contains(where: { $0.id == id && $0.kind == .audio }) else {
            throw VividPlaybackError.unsupportedTrack
        }
        let subtitles = selectedSubtitles
        try await load(source, at: currentTime, autoplay: wantsPlayback, audioTrack: id, audioOnly: audioOnly, preferredAudioLanguages: preferredAudioLanguages, forceSoftwareAudio: softwareAudio)
        try await selectSubtitles(subtitles)
    }
    public func selectSubtitles(_ ids: Set<Int>) async throws {
        guard let session, ids != selectedSubtitles else { return }
        selectedSubtitles = ids
        session.selectSubtitles(ids)
        try await seek(to: currentTime)
    }
    public func stop() {
        #if os(tvOS)
        audioRecoveryTask?.cancel(); audioRecoveryTask = nil
        audioRecoveryBudget = VividAudioRecoveryBudget()
        airPlayRecovery = VividAirPlayRecovery()
        hdmiAudio = VividHDMIAudioCore()
        hdmiRouteActive = false
        clockStall = VividClockStallDetector()
        displayFormatDescription = nil
        hasStartedPlayback = false
        #endif
        generation &+= 1
        timer?.invalidate(); timer = nil
        session?.cancel(); session = nil
        synchronizer.rate = 0
        let previousFlush = flushTask
        let renderer = displayLayer.sampleBufferRenderer
        flushTask = Task {
            await previousFlush?.value
            await withCheckedContinuation { continuation in
                renderer.flush(removingDisplayedImage: true) { continuation.resume() }
            }
        }
        audioRenderer.flush()
        wantsPlayback = false
        state = .idle
        currentTime = 0
        duration = 0
        tracks = []
        selectedSubtitles = []
        subtitleCues = []
        chapters = []
        error = nil
        bufferedAhead = 0
        decodedAhead = 0
        hardwareVideoDecode = false
        hasPresentedVideo = false
    }

    #if os(tvOS)
    private func recoverAudioOutput(replayFirst: Bool = true) {
        guard let session, state != .idle, state != .failed, state != .ended else { return }
        let isAirPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        if audioRecoveryTask != nil {
            if isAirPlay && replayFirst { airPlayRecovery.recordFlush() }
            return
        }
        guard session.snapshot().started else { return }
        airPlayRecovery = VividAirPlayRecovery()
        guard audioRecoveryBudget.consume(at: ProcessInfo.processInfo.systemUptime) else {
            error = .renderer(-11819); state = .failed
            synchronizer.rate = 0; session.cancel(); timer?.invalidate()
            return
        }
        let position = synchronizer.currentTime().seconds
        let replayed = replayFirst && session.recoverAudioOutput()
        if replayed {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                print("[VividTVProbe] audioOutputRecovery replayed audio without seeking")
            }
            #endif
        }
        guard wantsPlayback else { return }
        let epoch = generation
        var expectedSeek = seekGeneration
        audioRecoveryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.generation == epoch else { return }
            defer {
                if self.generation == epoch {
                    self.audioRecoveryTask = nil
                    self.airPlayRecovery = VividAirPlayRecovery()
                }
            }
            do {
                if replayed, try await self.confirmAudioRecovery(
                    from: position, generation: epoch, seek: expectedSeek, airPlay: isAirPlay
                ) { return }
                guard !Task.isCancelled, self.generation == epoch,
                      self.seekGeneration == expectedSeek, self.wantsPlayback else { return }
                expectedSeek &+= 1
                // Seeking cancels both enqueue workers before flushing and
                // refills the lost audio from the same source/track/position.
                try await self.seek(to: position)
                guard try await self.confirmAudioRecovery(
                    from: position, generation: epoch, seek: expectedSeek, airPlay: isAirPlay
                ) else { throw VividPlaybackError.renderer(-11819) }
                #if DEBUG
                if self.generation == epoch, ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                    print("[VividTVProbe] audioOutputRecovery completed position=\(position)")
                }
                #endif
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == epoch, self.seekGeneration == expectedSeek,
                      self.wantsPlayback, !Task.isCancelled else { return }
                self.error = (error as? VividPlaybackError) ?? .renderer(-11819)
                self.state = .failed
                self.synchronizer.rate = 0
                self.session?.cancel()
                self.timer?.invalidate()
            }
        }
    }

    private func confirmAudioRecovery(from position: Double, generation epoch: UInt64,
                                      seek expectedSeek: UInt64, airPlay: Bool) async throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        var audioBaseline = session?.audioRecoveryState().end ?? position
        while true {
            if airPlay {
                guard !Task.isCancelled, generation == epoch, seekGeneration == expectedSeek,
                      wantsPlayback, state != .ended, state != .idle,
                      AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .airPlay })
                else { throw CancellationError() }
                if let error { throw error }
                if airPlayRecovery.takeFlush() {
                    guard audioRecoveryBudget.consume(at: ProcessInfo.processInfo.systemUptime) else {
                        throw VividPlaybackError.renderer(-11819)
                    }
                    guard let session, session.recoverAudioOutput() else { return false }
                    audioBaseline = session.audioRecoveryState().end ?? synchronizer.currentTime().seconds
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                        print("[VividTVProbe] audioOutputRecovery AirPlay replayed pending flush")
                    }
                    #endif
                }
            }
            let decision = VividAudioRecoveryProgress.evaluate(
                position: position, currentTime: synchronizer.currentTime().seconds,
                elapsed: ProcessInfo.processInfo.systemUptime - started,
                isCurrent: !Task.isCancelled && generation == epoch && seekGeneration == expectedSeek,
                wantsPlayback: wantsPlayback && state != .ended && state != .idle
            )
            switch decision {
            case .cancelled: throw CancellationError()
            case .recovered:
                if !airPlay { return true }
                let audio = session?.audioRecoveryState()
                if VividAirPlayRecovery.audioAdvanced(from: audioBaseline, end: audio?.end,
                    clock: synchronizer.currentTime().seconds, finished: audio?.finished ?? false) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                        print("[VividTVProbe] audioOutputRecovery AirPlay confirmed audio progress")
                    }
                    #endif
                    return true
                }
                if ProcessInfo.processInfo.systemUptime - started >= 6 { return false }
            case .timedOut: return false
            case .waiting: break
            }
            if let error { throw error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    #endif

    private func poll() {
        guard let session, state != .failed, state != .ended else { return }
        #if os(tvOS)
        session.setAudioOutputLatency(AVAudioSession.sharedInstance().outputLatency)
        #endif
        let snapshot = session.snapshot()
        #if os(tvOS)
        if snapshot.finished { synchronizer.delaysRateChangeUntilHasSufficientMediaData = false }
        #endif
        #if os(tvOS) && DEBUG
        if ProcessInfo.processInfo.arguments.contains("-VividTVProbe"), Date().timeIntervalSince(lastTVProbe) >= 1 {
            lastTVProbe = Date()
            let route = AVAudioSession.sharedInstance()
            print("[VividTVProbe] state=\(state) wants=\(wantsPlayback) clock=\(synchronizer.currentTime().seconds) rate=\(synchronizer.rate) frontier=\(snapshot.frontier) readAhead=\(snapshot.readAheadSeconds) started=\(snapshot.started) full=\(snapshot.renderersFull) native=\(snapshot.nativeAudio) audioReady=\(audioRenderer.isReadyForMoreMediaData) audioStatus=\(audioRenderer.status.rawValue) videoReady=\(displayLayer.sampleBufferRenderer.isReadyForMoreMediaData) videoStatus=\(displayLayer.sampleBufferRenderer.status.rawValue) route=\(route.currentRoute.outputs.map { $0.portType.rawValue }) latency=\(route.outputLatency) channels=\(route.outputNumberOfChannels) codec=\(tracks.first { $0.id == selectedAudioTrack }?.codec ?? "none")")
        }
        #endif
        #if os(tvOS)
        if let format = session.displayFormatDescription,
           displayFormatDescription.map({ !CFEqual($0, format) }) ?? true {
            displayFormatDescription = format
        }
        #endif
        subtitleCues = snapshot.subtitles
        if let failure = snapshot.failure {
            if snapshot.nativeAudio, !softwareAudio, let source, case .renderer = failure {
                let time = currentTime, autoplay = wantsPlayback, audioTrack = selectedAudioTrack
                let audioOnly = audioOnly, languages = preferredAudioLanguages
                softwareAudio = true
                timer?.invalidate(); timer = nil; synchronizer.rate = 0; state = .opening
                let epoch = generation
                Task { [weak self] in
                    guard let self, self.generation == epoch else { return }
                    try? await self.load(source, at: time, autoplay: autoplay, audioTrack: audioTrack,
                        audioOnly: audioOnly, preferredAudioLanguages: languages, forceSoftwareAudio: true)
                }
                return
            }
            error = failure
            state = .failed
            synchronizer.rate = 0
            session.cancel()
            timer?.invalidate()
            return
        }
        let now = synchronizer.currentTime().seconds
        guard now.isFinite else { return }
        currentTime = max(startPosition, now)
        decodedAhead = max(0, snapshot.frontier - now)
        bufferedAhead = decodedAhead + snapshot.readAheadSeconds
        session.observeDelivery(headroom: bufferedAhead,
            active: wantsPlayback && snapshot.started && flushTask == nil && (state == .playing || state == .buffering))
        hardwareVideoDecode = snapshot.hardware
        nativeAudioDecode = snapshot.nativeAudio
        hasPresentedVideo = hasPresentedVideo || displayLayer.isReadyForDisplay
        if snapshot.finished && now >= snapshot.end - 0.02 {
            synchronizer.rate = 0
            currentTime = snapshot.end
            state = .ended
            timer?.invalidate()
            return
        }
        guard wantsPlayback else {
            if snapshot.started { state = .paused }
            return
        }
        #if os(tvOS)
        // A small first-start runway lets decode/read-ahead settle before the
        // clock advances. Seeking and pause/resume retain their fast threshold.
        // Full renderers and EOF still bypass this to avoid waiting for media
        // that cannot be enqueued (or a clip shorter than the runway).
        let readyAhead = hasStartedPlayback ? (state == .playing ? 0.04 : 0.08) : 0.20
        #else
        let readyAhead = state == .playing ? 0.04 : 0.08
        #endif
        if !snapshot.started || (decodedAhead < 0.04 && !snapshot.renderersFull && !snapshot.finished) {
            synchronizer.rate = 0
            state = snapshot.started ? .buffering : .opening
        } else if decodedAhead >= readyAhead || snapshot.renderersFull || snapshot.finished {
            #if os(tvOS)
            if synchronizer.rate != rate { synchronizer.rate = rate }
            #else
            synchronizer.rate = rate
            #endif
            #if os(tvOS)
            hasStartedPlayback = true
            #endif
            state = .playing
        }
        #if os(tvOS)
        let hdmiRoute = hdmiAudioEnabled && VividHDMIAudioCore.accepts(routeTypes:
            AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue })
        #if DEBUG
        if hdmiRoute != hdmiRouteActive { session.setHDMIProbeEnabled(hdmiRoute) }
        #endif
        if hdmiRouteActive && !hdmiRoute {
            hdmiAudio.suspend()
            session.clearHDMIRecovery()
        }
        hdmiRouteActive = hdmiRoute
        if hdmiRoute {
            let audio = session.hdmiAudioState()
            let action = hdmiAudio.observe(clock: now, audioEnd: audio.end,
                ready: audioRenderer.isReadyForMoreMediaData,
                uptime: ProcessInfo.processInfo.systemUptime,
                eligible: (state == .playing || state == .buffering) && wantsPlayback && snapshot.started
                    && !audio.finished && audioRecoveryTask == nil,
                buffering: state == .buffering,
                sufficient: audioRenderer.hasSufficientMediaDataForReliablePlaybackStart)
            if action == .flushAudio { session.resetHDMIAudio(at: now) }
            if action == .failed {
                error = .renderer(-11819); state = .failed
                synchronizer.rate = 0; session.cancel(); timer?.invalidate()
            }
            #if DEBUG
            if action != .none, ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                print("[VividTVProbe] audioOutputRecovery HDMI action=\(action) position=\(now)")
            }
            #endif
        }
        if clockStall.observe(time: now, uptime: ProcessInfo.processInfo.systemUptime,
            eligible: state == .playing && wantsPlayback && snapshot.started
                && !snapshot.finished && !audioOnly && selectedAudioTrack != nil
                && !(hdmiRoute && hdmiAudio.isRecovering)
                && decodedAhead >= 0.08 && bufferedAhead >= 1 && audioRecoveryTask == nil) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") {
                print("[VividTVProbe] audioOutputRecovery clockStall position=\(now)")
            }
            #endif
            recoverAudioOutput(replayFirst: false)
        }
        #endif
    }

    deinit {
        timer?.invalidate(); session?.cancel()
        #if os(tvOS)
        audioRecoveryTask?.cancel()
        audioOutputObservers.forEach(NotificationCenter.default.removeObserver)
        #endif
    }
}

struct VividClockStallDetector {
    private var position: Double?
    private var lastProgress: TimeInterval = 0
    private var fired = false

    mutating func observe(time: Double, uptime: TimeInterval, eligible: Bool) -> Bool {
        guard eligible, time.isFinite, uptime.isFinite else {
            self = Self()
            return false
        }
        guard let position, abs(time - position) < 0.001, uptime >= lastProgress else {
            self.position = time
            lastProgress = uptime
            fired = false
            return false
        }
        guard !fired, uptime - lastProgress >= 6 else { return false }
        fired = true
        return true
    }
}

enum VividAudioRecoveryProgress {
    enum Decision { case waiting, recovered, timedOut, cancelled }

    static func evaluate(position: Double, currentTime: Double, elapsed: TimeInterval,
                         isCurrent: Bool, wantsPlayback: Bool) -> Decision {
        guard isCurrent, wantsPlayback else { return .cancelled }
        if position.isFinite, currentTime.isFinite, currentTime - position >= 0.1 { return .recovered }
        return elapsed >= 6 ? .timedOut : .waiting
    }
}

struct VividAudioRecoveryBudget {
    private var attempts: [TimeInterval] = []

    mutating func consume(at time: TimeInterval) -> Bool {
        guard time.isFinite else { return false }
        attempts.removeAll { time - $0 >= 30 }
        guard attempts.count < 3 else { return false }
        attempts.append(time)
        return true
    }
}
