#if os(iOS)
import AVFoundation
import OSLog

/// The `AVPlayer` that carries a title to an AirPlay video receiver.
///
/// One player lives from the probe to the end of the hand-off. The probe is
/// a short silent black video, looped and muted; if the player goes external
/// while it plays, the receiver shows video. The receiver stream then
/// replaces the probe on the same player, so external playback stays up
/// through the swap, and a later stream (new tracks, quality or a seek the
/// stream can't reach) replaces it the same way. The player has no layer:
/// the receiver draws the picture and the phone keeps its black video area.
///
/// The player stays muted whenever it isn't external, so a receiver that
/// drops the stream never leaves its sound on the phone's speaker.
///
/// The receiver stream's URL carries its own credential. It is never logged,
/// and neither is anything that can repeat it (item errors, access and error
/// logs): failures are reported by domain and code only.
@MainActor
final class AirPlayVideoHandOff {
    enum Signal: Equatable {
        case probeExternalActive
        case probeTimedOut
        /// The probe couldn't run (its asset couldn't be written or never
        /// played), so there's no answer about the receiver.
        case probeFailed
        /// The receiver session took too long to arrive and be committed.
        case prepareTimedOut
        /// The receiver's clock moved after the start (or, paused, the start
        /// position was reached), with the receiver showing it.
        case playbackStarted
        case startTimedOut
        case externalLost
        case externalRestored
        /// External playback stayed off past the debounce, or went off
        /// before the stream started with the route no longer on AirPlay.
        case externalLostDebounced
        case receiverFailed
        case ended
        case playing(Bool)
        case buffering(Bool)
        case time(sourceSeconds: Double)
    }

    var onSignal: ((Signal) -> Void)?

    /// The probe window, from the moment the probe starts.
    static let probeTimeout: Duration = .seconds(4)
    /// How long the probe must have actually played for a "speaker" answer,
    /// and how long the probe gets to start playing at all.
    private static let probeMinimumPlay: TimeInterval = 2.5
    private static let probeStartLimit: Duration = .seconds(8)
    /// From the receiver showing video until the stream is committed.
    static let prepareTimeout: Duration = .seconds(30)
    static let startTimeout: Duration = .seconds(20)
    /// `isExternalPlaybackActive` drops for a moment while an item is
    /// swapped, so a loss only counts once it has lasted this long.
    static let externalLossDebounce: Duration = .milliseconds(1500)
    private static let tickInterval = CMTime(value: 1, timescale: 4)
    /// How far the clock must move past the start before the receiver
    /// counts as playing.
    private static let startedProgressSeconds = 0.3

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "AirPlayHandOff"
    )

    private enum Phase: Equatable {
        case idle
        case probing
        /// The probe went external and keeps the receiver while the stream
        /// is prepared and committed.
        case holding
        case starting
        case playing
    }

    private var phase = Phase.idle
    private var player: AVPlayer?
    /// Bumped by `stop()`; every callback checks it.
    private var generation: UInt64 = 0
    /// Bumped for each item put on the player.
    private var itemGeneration: UInt64 = 0
    /// Bumped for each seek, so only the latest one clears `isSeeking`.
    private var seekGeneration: UInt64 = 0
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var probeTimer: Task<Void, Never>?
    private var prepareTimer: Task<Void, Never>?
    private var startTimer: Task<Void, Never>?
    private var lossTimer: Task<Void, Never>?
    /// Tells a finishing loss timer whether it's still the current one.
    private var lossTimerToken: UInt64 = 0
    private var probeAssetTask: Task<Void, Never>?
    /// When the probe item started playing, for the probe window.
    private var probePlayingSince: Date?

    private(set) var sourceOffset: Double = 0
    /// Source-axis position the receiver starts at, kept up to date by seeks
    /// made before it's ready.
    private var startTarget: Double = 0
    private var initialSeekDone = false
    /// What the viewer asked for. The receiver's own pauses (its remote, or
    /// pausing as it disconnects) don't change it.
    private var wantsPlay = false
    private var rate: Float = 1
    private var volume: Float = 1
    private var viewerMuted = false
    private var reportedPlaying: Bool?
    private var reportedBuffering: Bool?
    private var lastSourcePosition: Double = 0
    private(set) var isSeeking = false

    var isRunning: Bool { phase != .idle }
    /// True once a receiver stream is on the player.
    var hasStream: Bool { phase == .starting || phase == .playing }
    var isExternal: Bool { player?.isExternalPlaybackActive == true }

    /// Whether the receiver is paused (by the viewer or by itself).
    var isPaused: Bool {
        guard phase == .playing, let player else { return !wantsPlay }
        return player.timeControlStatus == .paused
    }

    /// The receiver's position on the source axis.
    var sourcePosition: Double {
        guard hasStream, initialSeekDone, let player else { return lastSourcePosition }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return lastSourcePosition }
        return max(0, seconds + sourceOffset)
    }

    // MARK: - Probe

    /// Plays the probe on a fresh external-capable player.
    /// `probeExternalActive`, `probeTimedOut` or `probeFailed` follows.
    func startProbe() {
        stop()
        let token = generation
        phase = .probing
        let player = makePlayer()
        self.player = player
        watchPlayer(player, token: token)
        startProbeDeadline(token: token)
        probeAssetTask = Task { @MainActor [weak self] in
            let url: URL
            do {
                url = try await AirPlayProbeAsset.url()
            } catch {
                Self.logger.error("AirPlay probe asset unavailable: \(Self.describe(error), privacy: .public)")
                guard let self, self.generation == token, self.phase == .probing else { return }
                self.stop()
                self.onSignal?(.probeFailed)
                return
            }
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .probing else { return }
            self.putProbe(url: url, on: player)
        }
    }

    /// The probe window runs from the start, but a speaker answer also needs
    /// the probe to have played for a moment: a slow first write of the asset
    /// mustn't make a video receiver look like a speaker. A probe that never
    /// plays gives no answer at all.
    private func startProbeDeadline(token: UInt64) {
        let began = Date()
        probeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.probeTimeout)
            while !Task.isCancelled {
                guard let self, self.generation == token, self.phase == .probing else { return }
                if let since = self.probePlayingSince {
                    if Date().timeIntervalSince(since) >= Self.probeMinimumPlay { break }
                } else if Date().timeIntervalSince(began) >= Self.probeStartLimit.timeInterval {
                    Self.logger.error("AirPlay probe never played")
                    self.stop()
                    self.onSignal?(.probeFailed)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .probing else { return }
            Self.logger.info("AirPlay probe timed out; the receiver is audio only")
            self.stop()
            self.onSignal?(.probeTimedOut)
        }
    }

    private func putProbe(url: URL, on player: AVPlayer) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let token = beginItem()
        // The probe loops until the stream replaces it.
        observe(item, notification: .AVPlayerItemDidPlayToEndTime, token: token) { [weak self, weak player] in
            guard let self, self.phase == .probing || self.phase == .holding else { return }
            player?.seek(to: .zero)
            player?.play()
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    // MARK: - Receiver stream

    /// Puts a receiver stream on the player, starting at `sourceSeconds`:
    /// in place of the probe, or of an earlier stream. Plays when `autoplay`
    /// is true, and selects the stream's own subtitle rendition when it has
    /// one.
    func play(_ stream: AirPlayReceiverStream, atSourceTime sourceSeconds: Double, autoplay: Bool, rate: Float) {
        guard let player, phase != .idle else { return }
        probeTimer?.cancel()
        probeTimer = nil
        prepareTimer?.cancel()
        prepareTimer = nil
        probeAssetTask?.cancel()
        probeAssetTask = nil
        startTimer?.cancel()
        startTimer = nil
        // A loss seen before belongs to the probe or the previous stream.
        cancelLossTimer()
        phase = .starting
        sourceOffset = stream.sourceOffset
        startTarget = max(sourceSeconds, stream.sourceOffset)
        lastSourcePosition = startTarget
        initialSeekDone = false
        isSeeking = false
        seekGeneration &+= 1
        wantsPlay = autoplay
        self.rate = rate > 0 ? rate : 1
        reportedPlaying = nil
        reportedBuffering = nil

        // No custom headers: the receiver couldn't repeat them, so the URL
        // carries its own credential.
        let item = AVPlayerItem(asset: AVURLAsset(url: stream.url))
        let token = beginItem()
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self, self.itemGeneration == token else { return }
                self.itemStatusChanged(status, error: error, token: token)
            }
        })
        observe(item, notification: .AVPlayerItemDidPlayToEndTime, token: token) { [weak self] in
            guard let self, self.phase == .playing else { return }
            self.lastSourcePosition = self.sourcePosition
            self.onSignal?(.ended)
        }
        observe(item, notification: .AVPlayerItemFailedToPlayToEndTime, token: token) { [weak self] in
            self?.receiverFailed(nil)
        }

        player.pause()
        player.actionAtItemEnd = .pause
        player.defaultRate = self.rate
        player.replaceCurrentItem(with: item)
        applyAudio()
        selectSubtitles(stream.showsSubtitleRendition, on: item, token: token)

        let generationToken = generation
        startTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.generation == generationToken,
                  self.itemGeneration == token, self.phase == .starting else { return }
            Self.logger.error("AirPlay receiver never started the stream")
            self.onSignal?(.startTimedOut)
        }
    }

    /// A server's text subtitles arrive as an HLS WebVTT rendition, which
    /// stays hidden unless it's selected. Bitmap subtitles are drawn into the
    /// video by the server and need nothing here.
    private func selectSubtitles(_ shows: Bool, on item: AVPlayerItem, token: UInt64) {
        Task { @MainActor [weak self, weak item] in
            guard let asset = item?.asset,
                  let group = try? await asset.loadMediaSelectionGroup(for: .legible),
                  let self, let item, self.itemGeneration == token else { return }
            let option = shows
                ? group.defaultOption ?? group.options.first {
                    !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                }
                : nil
            item.select(option, in: group)
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?, token: UInt64) {
        switch status {
        case .readyToPlay:
            guard phase == .starting, !initialSeekDone, let player else { return }
            let target = CMTime(seconds: max(0, startTarget - sourceOffset), preferredTimescale: 600)
            isSeeking = true
            seekGeneration &+= 1
            let seekToken = seekGeneration
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.itemGeneration == token, self.phase == .starting else { return }
                    if self.seekGeneration == seekToken { self.isSeeking = false }
                    self.initialSeekDone = true
                    self.applyIntent()
                    self.checkStarted()
                }
            }
        case .failed:
            receiverFailed(error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func receiverFailed(_ error: Error?) {
        guard hasStream else { return }
        Self.logger.error("AirPlay receiver item failed: \(error.map(Self.describe) ?? "no error", privacy: .public)")
        lastSourcePosition = sourcePosition
        onSignal?(.receiverFailed)
    }

    // MARK: - Transport

    func play() {
        wantsPlay = true
        applyIntent()
    }

    func pause() {
        wantsPlay = false
        applyIntent()
        checkStarted()
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        self.rate = rate
        player?.defaultRate = rate
        if wantsPlay { applyIntent() }
    }

    func setVolume(_ volume: Float, muted: Bool) {
        self.volume = min(max(volume, 0), 1)
        viewerMuted = muted
        applyAudio()
    }

    private func applyIntent() {
        guard let player, hasStream, initialSeekDone else { return }
        if wantsPlay {
            player.defaultRate = rate
            player.rate = rate
        } else {
            player.pause()
        }
        reportPlaying()
    }

    /// The probe is always silent, and a stream only sounds while the
    /// receiver has it.
    private func applyAudio() {
        guard let player else { return }
        player.volume = volume
        player.isMuted = !hasStream || viewerMuted || !player.isExternalPlaybackActive
    }

    /// Seeks on the stream's own axis. Before the receiver is ready the
    /// target just moves the start. Only the latest of overlapping seeks
    /// clears `isSeeking`.
    func seek(toSourceTime sourceSeconds: Double) async {
        guard let player, hasStream else { return }
        let target = max(sourceSeconds.isFinite ? sourceSeconds : 0, sourceOffset)
        lastSourcePosition = target
        guard initialSeekDone else {
            startTarget = target
            return
        }
        let token = itemGeneration
        seekGeneration &+= 1
        let seekToken = seekGeneration
        isSeeking = true
        _ = await player.seek(
            to: CMTime(seconds: target - sourceOffset, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard itemGeneration == token, seekGeneration == seekToken else { return }
        isSeeking = false
    }

    /// Whether `sourceSeconds` is before the start of the stream on the
    /// player, which only a new stream can reach.
    func needsNewStream(forSourceTime sourceSeconds: Double) -> Bool {
        hasStream && sourceSeconds.isFinite && sourceSeconds < sourceOffset - 0.5
    }

    // MARK: - Teardown

    /// Releases the player and everything watching it. Safe to call twice.
    func stop() {
        generation &+= 1
        itemGeneration &+= 1
        seekGeneration &+= 1
        probeTimer?.cancel()
        probeTimer = nil
        prepareTimer?.cancel()
        prepareTimer = nil
        startTimer?.cancel()
        startTimer = nil
        cancelLossTimer()
        probeAssetTask?.cancel()
        probeAssetTask = nil
        clearItemWatchers()
        playerObservations.forEach { $0.invalidate() }
        playerObservations.removeAll()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        phase = .idle
        probePlayingSince = nil
        isSeeking = false
        initialSeekDone = false
        wantsPlay = false
        reportedPlaying = nil
        reportedBuffering = nil
    }

    // MARK: - Watching

    private func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.isMuted = true
        // The probe loops by seeking back from its end; pausing there first
        // would let external playback flicker while it holds the receiver.
        player.actionAtItemEnd = .none
        return player
    }

    private func watchPlayer(_ player: AVPlayer, token: UInt64) {
        playerObservations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let external = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.externalChanged(external, token: token)
            }
        })
        playerObservations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if self.phase == .probing, self.probePlayingSince == nil,
                   self.player?.timeControlStatus == .playing {
                    self.probePlayingSince = Date()
                }
                self.reportPlaying()
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: Self.tickInterval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.tick()
            }
        }
    }

    private func externalChanged(_ external: Bool, token: UInt64) {
        applyAudio()
        switch phase {
        case .probing:
            guard external else { return }
            probeTimer?.cancel()
            probeTimer = nil
            phase = .holding
            Self.logger.info("AirPlay probe went external; the receiver shows video")
            startPrepareDeadline(token: token)
            onSignal?(.probeExternalActive)
        case .holding, .playing:
            if external {
                guard lossTimer != nil else { return }
                cancelLossTimer()
                onSignal?(.externalRestored)
            } else {
                guard lossTimer == nil else { return }
                onSignal?(.externalLost)
                startLossTimer(token: token)
            }
        case .starting:
            // An item swap drops external playback for a moment, which the
            // start timeout covers. A drop the route confirms (the viewer
            // chose another output) ends it straight away.
            guard !external, !Self.routeHasAirPlay else { return }
            lastSourcePosition = startTarget
            Self.logger.info("AirPlay receiver left before the stream started")
            onSignal?(.externalLostDebounced)
        case .idle:
            break
        }
    }

    private func startPrepareDeadline(token: UInt64) {
        prepareTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.prepareTimeout)
            guard !Task.isCancelled, let self, self.generation == token, self.phase == .holding else { return }
            Self.logger.error("AirPlay receiver session took too long to prepare")
            self.onSignal?(.prepareTimedOut)
        }
    }

    /// Waits out the debounce, then once more if the audio route still says
    /// AirPlay (a receiver reloading an item can take a little longer).
    private func startLossTimer(token: UInt64) {
        lossTimerToken &+= 1
        let timerToken = lossTimerToken
        lossTimer = Task { @MainActor [weak self] in
            // Every way out leaves room for the next loss to be timed.
            defer {
                if let self, self.lossTimerToken == timerToken { self.lossTimer = nil }
            }
            for round in 0..<2 {
                try? await Task.sleep(for: Self.externalLossDebounce)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if self.isExternal { return }
                if round == 0, Self.routeHasAirPlay { continue }
                break
            }
            guard !Task.isCancelled, let self, self.generation == token, !self.isExternal else { return }
            self.lastSourcePosition = self.sourcePosition
            Self.logger.info("AirPlay receiver stopped external playback")
            self.onSignal?(.externalLostDebounced)
        }
    }

    private func cancelLossTimer() {
        lossTimerToken &+= 1
        lossTimer?.cancel()
        lossTimer = nil
    }

    private func tick() {
        switch phase {
        case .starting:
            checkStarted()
        case .playing:
            guard !isSeeking else { return }
            let position = sourcePosition
            lastSourcePosition = position
            onSignal?(.time(sourceSeconds: position))
        case .idle, .probing, .holding:
            break
        }
    }

    /// The stream counts as started once the clock has moved past the start
    /// while playing, or once the start position is reached while paused,
    /// and only while the receiver has it: a receiver that dropped the
    /// stream would otherwise let it start on the phone, unseen. That case
    /// reaches the start timeout instead.
    private func checkStarted() {
        guard phase == .starting, initialSeekDone, isExternal, let player else { return }
        if wantsPlay {
            guard player.timeControlStatus == .playing,
                  sourcePosition >= startTarget + Self.startedProgressSeconds else { return }
        }
        phase = .playing
        startTimer?.cancel()
        startTimer = nil
        Self.logger.info("AirPlay receiver started the stream")
        onSignal?(.playbackStarted)
        reportPlaying()
        onSignal?(.time(sourceSeconds: sourcePosition))
    }

    /// Reports what the receiver is doing, which can differ from what the
    /// viewer asked for (its own remote, or pausing as it disconnects).
    private func reportPlaying() {
        guard phase == .playing, let player else { return }
        let status = player.timeControlStatus
        let playing = status != .paused
        let buffering = status == .waitingToPlayAtSpecifiedRate
        if playing != reportedPlaying {
            reportedPlaying = playing
            onSignal?(.playing(playing))
        }
        if buffering != reportedBuffering {
            reportedBuffering = buffering
            onSignal?(.buffering(buffering))
        }
    }

    // MARK: - Items

    private func beginItem() -> UInt64 {
        clearItemWatchers()
        itemGeneration &+= 1
        return itemGeneration
    }

    private func clearItemWatchers() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
    }

    /// Watches one notification from exactly this item, on the main queue.
    private func observe(
        _ item: AVPlayerItem,
        notification: Notification.Name,
        token: UInt64,
        _ handler: @escaping @MainActor () -> Void
    ) {
        itemNotifications.append(NotificationCenter.default.addObserver(
            forName: notification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.itemGeneration == token else { return }
                handler()
            }
        })
    }

    private static var routeHasAirPlay: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// Domain and code only: an AVFoundation error's description and user
    /// info can carry the failing URL, and with it the stream's credential.
    nonisolated static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// The probe: about two seconds of silent black H.264 at 320x180, written
/// once into Caches with AVAssetWriter, so no media ships in the app.
@MainActor
enum AirPlayProbeAsset {
    private static let fileName = "Vivid-AirPlayProbe.mp4"
    nonisolated private static let width = 320
    nonisolated private static let height = 180
    nonisolated private static let framesPerSecond: Int32 = 2
    nonisolated private static let frameCount = 4

    /// One write at a time, shared by every probe waiting for it.
    private static var writing: Task<Void, Error>?

    static func url() async throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = caches.appendingPathComponent(fileName)
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            return destination
        }
        let write = writing ?? Task.detached(priority: .userInitiated) {
            try await Self.write(to: destination)
        }
        writing = write
        defer { if writing == write { writing = nil } }
        try await write.value
        return destination
    }

    nonisolated private static func write(to destination: URL) async throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("Vivid-AirPlayProbe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ProbeError.writerRefused }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ProbeError.writerRefused }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            // A writer that never asks for more gives up after two seconds.
            var waits = 0
            while !input.isReadyForMoreMediaData {
                waits += 1
                guard waits <= 200 else {
                    writer.cancelWriting()
                    throw ProbeError.writerRefused
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let buffer = blackFrame(from: adaptor.pixelBufferPool),
                  adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
                writer.cancelWriting()
                throw writer.error ?? ProbeError.writerRefused
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: framesPerSecond))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ProbeError.writerRefused }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    nonisolated private static func blackFrame(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private enum ProbeError: Error {
        case writerRefused
    }
}
#endif
