// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine
import Foundation

@MainActor
public final class VividPlayer: ObservableObject {
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

    public init() {
        synchronizer.addRenderer(displayLayer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
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
        next.setBufferTarget(seconds: bufferAheadTarget)
        do {
            let inventory = try await withTaskCancellationHandler {
                try await next.open()
            } onCancel: { next.cancel() }
            try Task.checkCancellation()
            guard generation == epoch else { next.cancel(); throw CancellationError() }
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

    public func play() { wantsPlayback = true; poll() }
    public func pause() {
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

    private func poll() {
        guard let session, state != .failed, state != .ended else { return }
        let snapshot = session.snapshot()
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
            synchronizer.rate = rate
            #if os(tvOS)
            hasStartedPlayback = true
            #endif
            state = .playing
        }
    }

    deinit { timer?.invalidate(); session?.cancel() }
}
