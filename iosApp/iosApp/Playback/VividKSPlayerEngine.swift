// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(tvOS)
import AVFoundation
import AVKit
import Combine
import KSPlayer
import MediaPlayer
import SwiftUI

/// Trial adapter for the public GPL player. Vivid owns controls and source credentials;
/// KSPlayer owns demuxing, decoding, its buffer, PCM output and the video surface.
@MainActor
final class VividEngine: NSObject, ObservableObject, MediaPlayerDelegate {
    static let externalSubtitleTrackIDBase = 1_000_000
    let clock = PlaybackClock()
    let diagnostics = VividDiagnostics()
    let systemCaptionRequest = PassthroughSubject<SystemCaptionRequest, Never>()
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var playbackPhase: PlaybackPhase = .idle
    @Published private(set) var duration: Double = 0
    @Published private(set) var isBuffering = false
    @Published private(set) var isLoadingSubtitles = false
    @Published private(set) var hasFirstFrameReadyForDisplay = false
    @Published private(set) var errorInfo: PlaybackErrorInfo?
    @Published private(set) var startupProgress: StartupProgress?
    @Published private(set) var audioTracks: [TrackInfo] = []
    @Published private(set) var subtitleTracks: [TrackInfo] = []
    @Published private(set) var mediaChapters: [MediaChapter] = []
    @Published private(set) var subtitleCues: [SubtitleCue] = []
    @Published private(set) var secondarySubtitleCues: [SubtitleCue] = []
    @Published private(set) var currentAVPlayer: AVPlayer?
    @Published private(set) var currentAVPlayerItem: AVPlayerItem?
    @Published private(set) var videoRoute: VideoRoute = .none
    @Published private(set) var softwarePiPSource: SampleBufferPiPSource?
    @Published private(set) var activeSubtitleTrackIndex: Int?
    @Published private(set) var player: KSMEPlayer?
    private(set) var activeAudioTrackIndex: Int?
    private var secondarySubtitleID: Int?
    var nativePlayerLayer: AVPlayerLayer? { nil }
    var isSubtitleActive: Bool { activeSubtitleTrackIndex != nil }
    var isSecondarySubtitleActive: Bool { secondarySubtitleID != nil }
    var nativeSubtitleTracks: [TrackInfo] { subtitleTracks.filter { !$0.isExternal } }
    var currentTime: Double { clock.currentTime }
    private(set) var isSeeking = false
    var isSessionReady: Bool { player?.isReadyToPlay == true && errorInfo == nil }
    private(set) var sourceVideoWidth: Int32 = 0
    private(set) var sourceVideoHeight: Int32 = 0
    private(set) var sourceVideoPixelAspectRatio: Double = 1
    private(set) var sourceVideoFrameRate: Double?
    private(set) var sourceVideoBitrate: Int64 = 0
    private(set) var sourceDVProfile: Int?
    private(set) var sourceVideoFormat: VideoFormat = .sdr
    private(set) var videoFormat: VideoFormat = .sdr
    var activeVideoDecoder: String? { sourceVideoWidth > 0 ? "KSPlayer (VideoToolbox preferred)" : nil }
    var activeAudioDecoder: String? { audioTracks.isEmpty ? nil : "FFmpeg PCM → AVAudioEngine" }
    var softwareDisplaySize: CGSize? { player?.naturalSize }
    var readAheadAvailableSeconds: Double? { nil }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }
    var backgroundPlaybackEnabled = true
    var pictureInPictureActive = false
    var deactivatesAudioSessionOnStop = false
    var ownsVideoNowPlayingSession = false
    var videoNowPlayingSession: MPNowPlayingSession? { nil }
    var volume: Float = 1 { didSet { player?.playbackVolume = volume } }
    var videoGravity: AVLayerVideoGravity = .resizeAspect { didSet { applyGravity() } }
    var transientRecoveryBudget: VividTransientRecoveryBudget?
    var refreshSourceHeaders: (@Sendable () async -> [String: String]?)?
    var preferLosslessAudio = false

    private var options: VividKSOptions?
    private var source: (url: URL, start: Double, options: LoadOptions, audio: Int32?)?
    private var trace: PlaybackTrialTrace?
    private var generation: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var wantsPlay = false
    private var requestedRate: Float = 1
    private var ticker: Task<Void, Never>?
    private var lastSample = 0.0
    private var lastBytes: Int64 = 0
    private var sampleTime = 0.0
    private var stallCount = 0
    private var audioProbe: VividKSAudioProbe?
    private var routeObserver: NSObjectProtocol?
    private var externalTracks: [Int: ExternalSubtitleTrack] = [:]
    private var externalCues: [Int: [SubtitleCue]] = [:]
    private var subtitleTasks: [Int: Task<Void, Never>] = [:]
    private var seekPicturePending = false
    private var seekTarget = 0.0
    private var seekDeadline = 0.0

    override init() {
        super.init()
        // Use the GPL player's ordinary decoded-PCM path, including E-AC-3 JOC.
        KSOptions.audioPlayerType = AudioEnginePlayer.self
    }

    func load(url: URL, startPosition: Double = 0, options loadOptions: LoadOptions = LoadOptions(),
              audioSourceStreamIndex: Int32? = nil) async throws {
        stop(resetDisplayCriteria: false)
        let token = generation
        source = (url, startPosition, loadOptions, audioSourceStreamIndex)
        trace = PlaybackTrialTrace()
        trace?.mark("engine_load")
        let prepared = VividKSOptions(load: loadOptions, start: startPosition, audioIndex: audioSourceStreamIndex) { [weak self, weak trace = trace] name, time in
            Task { @MainActor in
                guard self?.generation == token else { return }
                trace?.mark(name, at: time)
            }
        }
        options = prepared
        wantsPlay = loadOptions.autoplay
        state = .loading
        playbackPhase = .loading
        startupProgress = StartupProgress(checkpoint: "opening")
        let instance = KSMEPlayer(url: url, options: prepared)
        instance.delegate = self
        instance.playbackVolume = volume
        instance.playbackRate = requestedRate
        player = instance
        applyGravity()
        videoRoute = loadOptions.audioOnly ? .audio : .sampleBuffer
        if let renderSource = instance.audioOutput.renderSource, let trace {
            let probe = VividKSAudioProbe(source: renderSource, available: { [weak self, weak trace] name, time in
                Task { @MainActor in
                    guard self?.generation == token else { return }
                    trace?.mark(name, at: time)
                }
            }) { [weak self, weak trace] time in
                Task { @MainActor in
                    guard self?.generation == token else { return }
                    trace?.mark("audio_render_callback", at: time)
                }
            }
            audioProbe = probe
            instance.audioOutput.renderSource = probe
            if instance.videoOutput?.renderSource === renderSource { instance.videoOutput?.renderSource = probe }
        }
        for track in loadOptions.externalSubtitles { addExternalSubtitleTrack(track) }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.logAudioRoute(event: "audio_route_changed")
            }
        }
        trace?.mark("prepare_requested")
        instance.prepareToPlay()
        startTicker(token: token)
        let deadline = CACurrentMediaTime() + 60
        do {
            while !instance.isReadyToPlay {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                if let errorInfo { throw errorInfo }
                guard CACurrentMediaTime() < deadline else {
                    throw PlaybackErrorInfo(kind: .noPlayableTrackWithinBudget, message: "KSPlayer did not open the source within 60 seconds.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            // KSPlayer's ready callback is dispatched to the main actor. Wait for its
            // metadata/safety checks as well, not just the worker's readiness flag.
            while startupProgress?.checkpoint != "ready" && errorInfo == nil {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(10))
            }
            if let errorInfo { throw errorInfo }
        } catch {
            if generation == token {
                if error is CancellationError { stop() }
                else { fail(error) }
            }
            throw error
        }
    }

    func readyToPlay(player incoming: some MediaPlayerProtocol) {
        guard let player, incoming === player else { return }
        duration = player.duration.isFinite ? max(0, player.duration) : 0
        readTracks()
        harvestTimings()
        trace?.mark("player_ready")
        if let track = player.tracks(mediaType: .video).first(where: { $0.isEnabled }) {
            let size = track.naturalSize
            sourceVideoWidth = size.width.isFinite ? Int32(clamping: Int(max(0, min(size.width, 100_000)))) : 0
            sourceVideoHeight = size.height.isFinite ? Int32(clamping: Int(max(0, min(size.height, 100_000)))) : 0
            sourceVideoFrameRate = Double(track.nominalFrameRate)
            sourceVideoBitrate = track.bitRate
            sourceDVProfile = track.dovi.map { Int($0.dv_profile) }
            sourceVideoFormat = Self.videoFormat(track.dynamicRange)
            videoFormat = Self.videoFormat(track.formatDescription?.dynamicRange)
            if let dv = track.dovi {
                trace?.event("dolby_metadata", fields: "profile=\(dv.dv_profile) level=\(dv.dv_level) compatibility=\(dv.dv_bl_signal_compatibility_id) bl=\(dv.bl_present_flag) el=\(dv.el_present_flag) native_dv_verified=false")
                // No custom Dolby subsystem in the baseline. Never send IPT-only P5
                // through the GPL player's ordinary HDR output and call it correct DV.
                let validBase = dv.bl_present_flag != 0 &&
                    ((dv.dv_profile == 7 && dv.dv_bl_signal_compatibility_id == 6) ||
                     (dv.dv_profile == 8 && [UInt8(1), 2, 4].contains(dv.dv_bl_signal_compatibility_id)))
                guard validBase else {
                    fail(PlaybackErrorInfo(kind: .dolbyVisionRequiresHardware,
                        message: "This Dolby Vision profile needs the later Vivid Dolby experiment. Playback is stopped to avoid incorrect colours."))
                    return
                }
                trace?.event("dolby_base_layer_trial", fields: "profile=\(dv.dv_profile) output_verification=pending")
            }
            options?.updateVideo(refreshRate: track.nominalFrameRate, isDovi: track.dovi != nil,
                                 formatDescription: track.formatDescription)
        }
        mediaChapters = player.chapters.enumerated().map { MediaChapter(id: $0.offset, name: $0.element.title, startSeconds: $0.element.start) }
        startupProgress = StartupProgress(checkpoint: "ready")
        if let preferred = source?.options.preferredSubtitleLanguages,
           let track = subtitleTracks.first(where: { preferred.contains($0.language ?? "") }) {
            selectSubtitleTrack(index: track.id)
        }
        logAudioRoute(event: "audio_ready")
        if wantsPlay { play() } else { pause() }
    }

    func changeLoadState(player incoming: some MediaPlayerProtocol) {
        guard let player, incoming === player, errorInfo == nil else { return }
        guard !isSeeking else { return }
        let buffering = wantsPlay && player.isReadyToPlay && player.loadState != .playable
        if buffering && !isBuffering && hasFirstFrameReadyForDisplay {
            stallCount += 1
            sample(event: "stall")
        }
        isBuffering = buffering
        if !wantsPlay { state = .paused; playbackPhase = .paused }
        else if player.loadState == .playable {
            state = .playing; playbackPhase = .playing
            trace?.mark("playing")
        } else if hasFirstFrameReadyForDisplay {
            state = .playing; playbackPhase = .rebuffering
        } else { state = .loading; playbackPhase = .loading }
    }
    func changeBuffering(player: some MediaPlayerProtocol, progress: Int) {}
    func playBack(player: some MediaPlayerProtocol, loopCount: Int) {}
    func finish(player incoming: some MediaPlayerProtocol, error: Error?) {
        guard let player, incoming === player else { return }
        if let error { fail(error) }
        else {
            wantsPlay = false
            isBuffering = false
            state = .ended; playbackPhase = .ended
            trace?.event("ended")
            ticker?.cancel(); ticker = nil
        }
    }

    func play() {
        guard errorInfo == nil else { return }
        wantsPlay = true
        guard let player, startupProgress?.checkpoint == "ready" else { return }
        player.playbackRate = requestedRate
        player.play()
    }
    func pause() { wantsPlay = false; player?.pause(); state = .paused; playbackPhase = .paused; isBuffering = false }
    func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        requestedRate = rate; player?.playbackRate = rate
    }
    func seek(to seconds: Double) async {
        guard let player, player.seekable, seconds.isFinite, errorInfo == nil else { return }
        seekGeneration &+= 1
        let seekToken = seekGeneration
        let token = generation
        let target = min(max(0, seconds), duration > 0 ? duration : max(0, seconds))
        trace?.beginSeek(target: target)
        seekPicturePending = false
        isSeeking = true; state = .seeking; playbackPhase = .seeking
        player.pause()
        let result = VividKSSeekResult()
        let deadline = CACurrentMediaTime() + 30
        player.seek(time: target) { result.complete($0) }
        while result.read() == nil, CACurrentMediaTime() < deadline, !Task.isCancelled,
              generation == token, seekGeneration == seekToken {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard generation == token, seekGeneration == seekToken, self.player === player else { return }
        let succeeded = result.read() == true && !Task.isCancelled
        isSeeking = false
        if succeeded {
            player.videoOutput?.flush()
            subtitleCues = []; secondarySubtitleCues = []
            seekTarget = target
            seekDeadline = CACurrentMediaTime() + 30
            seekPicturePending = source?.options.audioOnly == false
            trace?.event("seek_completed", fields: "target=\(target)")
            if !wantsPlay { player.videoOutput?.readNextFrame() }
        } else { trace?.endSeek("seek_failed") }
        if wantsPlay { player.play() } else { player.pause() }
        changeLoadState(player: player)
    }
    func selectAudioTrack(index: Int) {
        guard let player, let track = player.tracks(mediaType: .audio).first(where: { Int($0.trackID) == index }) else { return }
        player.select(track: track)
        activeAudioTrackIndex = index
        if var source { source.audio = track.trackID; self.source = source }
        logAudioRoute(event: "audio_track_changed")
    }
    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool { false }
    func reloadAtCurrentPosition() async throws {
        guard var source else { return }
        let token = generation
        let position = currentTime
        source.options.autoplay = wantsPlay
        if let headers = await refreshSourceHeaders?() { source.options.httpHeaders = headers }
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        try await load(url: source.url, startPosition: position, options: source.options, audioSourceStreamIndex: source.audio)
    }
    func prepareForItemReplacement() { pause(); hasFirstFrameReadyForDisplay = false }
    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        generation &+= 1; seekGeneration &+= 1
        trace?.endSeek("seek_cancelled")
        trace?.event("stopped")
        ticker?.cancel(); ticker = nil
        for task in subtitleTasks.values { task.cancel() }
        subtitleTasks.removeAll()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        player?.delegate = nil
        player?.shutdown(); player = nil; audioProbe = nil
        source = nil; options = nil; trace = nil
        state = .idle; playbackPhase = .idle; videoRoute = .none
        isBuffering = false; isSeeking = false; isLoadingSubtitles = false
        hasFirstFrameReadyForDisplay = false; seekPicturePending = false
        errorInfo = nil; startupProgress = nil
        duration = 0; clock.currentTime = 0
        audioTracks = []; subtitleTracks = []; mediaChapters = []
        subtitleCues = []; secondarySubtitleCues = []
        activeAudioTrackIndex = nil; activeSubtitleTrackIndex = nil; secondarySubtitleID = nil
        externalTracks = [:]; externalCues = [:]
        sourceVideoWidth = 0; sourceVideoHeight = 0; sourceDVProfile = nil
        sourceVideoFrameRate = nil; sourceVideoBitrate = 0
        sourceVideoFormat = .sdr; videoFormat = .sdr
        lastSample = 0; sampleTime = 0; lastBytes = 0; stallCount = 0
        diagnostics.liveTelemetry = nil
        if resetDisplayCriteria {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows { window.avDisplayManager.preferredDisplayCriteria = nil }
            }
        }
        if deactivatesAudioSessionOnStop { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func fail(_ error: Error) {
        let native = error as NSError
        let failure = error as? PlaybackErrorInfo ?? PlaybackErrorInfo(kind: .softwarePipelineFailed,
            message: "KSPlayer could not play this source.", underlyingDomain: native.domain, underlyingCode: native.code)
        guard errorInfo == nil else { return }
        harvestTimings()
        trace?.event("failed", fields: "code=\(native.code)")
        trace?.endSeek("seek_failed")
        wantsPlay = false; player?.pause()
        isSeeking = false; isBuffering = false
        errorInfo = failure; state = .error(failure.message); playbackPhase = .error(failure.message)
        ticker?.cancel(); ticker = nil
    }

    private func readTracks() {
        guard let player else { return }
        audioTracks = player.tracks(mediaType: .audio).map(Self.track)
        activeAudioTrackIndex = player.tracks(mediaType: .audio).first(where: { $0.isEnabled }).map { Int($0.trackID) }
        subtitleTracks = player.tracks(mediaType: .subtitle).map(Self.track) + subtitleTracks.filter(\.isExternal)
    }
    private static func track(_ track: MediaPlayerTrack) -> TrackInfo {
        TrackInfo(id: Int(track.trackID), name: track.name, codec: (track as? FFmpegAssetTrack)?.codecName ?? "unknown",
                  language: track.languageCode, channels: Int(track.audioStreamBasicDescription?.mChannelsPerFrame ?? 0),
                  bitrate: track.bitRate, isDefault: track.isEnabled)
    }
    private static func videoFormat(_ range: DynamicRange?) -> VideoFormat {
        switch range { case .dolbyVision: return .dolbyVision; case .hdr10: return .hdr10; case .hlg: return .hlg; default: return .sdr }
    }
    private func applyGravity() {
        player?.contentMode = videoGravity == .resizeAspectFill ? .scaleAspectFill : videoGravity == .resize ? .scaleToFill : .scaleAspectFit
    }

    private func startTicker(token: UInt64) {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.tick(token: token) else { return }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }
    private func tick(token: UInt64) -> Int? {
        guard generation == token, let player else { return nil }
        harvestTimings()
        let now = player.currentPlaybackTime
        if now.isFinite { clock.currentTime = max(0, now) }
        pictureReady()
        if seekPicturePending && CACurrentMediaTime() >= seekDeadline {
            trace?.endSeek("seek_picture_timeout"); seekPicturePending = false
        }
        updateSubtitles()
        if CACurrentMediaTime() - lastSample >= 1 { sample(event: "sample") }
        return hasFirstFrameReadyForDisplay && !seekPicturePending ? 100 : 50
    }

    /// Requires an attached, visible layer. Readiness is an Apple presentation signal,
    /// not proof that the television has completed its HDMI mode switch.
    func pictureReady() {
        guard let player, let output = player.videoOutput,
              output.window != nil, !output.isHidden, output.alpha > 0, errorInfo == nil else { return }
        if output.pixelBuffer != nil && output.pixelBuffer?.cvPixelBuffer == nil {
            // Software frames can use KSPlayer's Metal surface. It has no public
            // presentation completion hook. Let the UI show the submitted picture,
            // but leave the benchmark's first_picture_ready measurement unavailable.
            if !hasFirstFrameReadyForDisplay {
                hasFirstFrameReadyForDisplay = true
                trace?.mark("metal_frame_submitted")
                trace?.event("first_picture_measurement_unavailable", fields: "renderer=metal")
            }
            return
        }
        guard output.displayLayer.isReadyForDisplay else { return }
        if !hasFirstFrameReadyForDisplay {
            hasFirstFrameReadyForDisplay = true
            trace?.mark("first_picture_ready")
        }
        if seekPicturePending, abs(player.displayedVideoTime - seekTarget) <= 1 {
            seekPicturePending = false; trace?.seekPicture()
        }
    }
    private func harvestTimings() {
        guard let options else { return }
        for (name, time) in [("source_open_completed", options.openTime), ("probe_completed", options.findTime),
                             ("first_audio_packet", options.readAudioTime), ("first_video_packet", options.readVideoTime),
                             ("first_audio_decode_submitted", options.decodeAudioTime), ("first_video_decode_submitted", options.decodeVideoTime)] where time > 0 {
            trace?.mark(name, at: time)
        }
        // Upstream exposes no exact decoder-created timestamp. player_ready is
        // labelled separately and never substituted for decoder or frame completion.
    }
    private func sample(event: String) {
        guard let player else { return }
        let now = CACurrentMediaTime()
        let info = player.dynamicInfo
        let bytes = info?.bytesRead ?? 0
        let elapsed = now - sampleTime
        let mbps = sampleTime > 0 && elapsed > 0 ? Double(max(0, bytes - lastBytes)) * 8 / elapsed / 1_000_000 : nil
        sampleTime = now; lastBytes = bytes; lastSample = now
        let ahead = max(0, player.playableTime - player.currentPlaybackTime)
        diagnostics.liveTelemetry = LiveTelemetry(forwardBufferSeconds: ahead, observedFps: info?.displayFPS,
            droppedFrameCount: info.map { Int($0.droppedVideoFrameCount) }, avSyncGapMs: info.map { $0.audioVideoSyncDiff * 1000 },
            instantBitrateMbps: mbps, networkThroughputMbps: mbps, networkTransferredBytes: bytes, demuxerBytesFetched: bytes)
        trace?.event(event, fields: "playhead=\(currentTime) buffer_s=\(ahead) source_bytes=\(bytes) throughput_mbps=\(mbps ?? -1) stalls=\(stallCount) load=\(player.loadState.rawValue) rate=\(player.playbackRate)")
    }
    private func logAudioRoute(event: String) {
        let session = AVAudioSession.sharedInstance()
        let selected = audioTracks.first { $0.id == activeAudioTrackIndex }
        trace?.event(event, fields: "codec=\(selected?.codec ?? "unknown") source_channels=\(selected?.channels ?? 0) output_channels=\(session.outputNumberOfChannels) maximum_channels=\(session.maximumOutputNumberOfChannels) output=decoded_pcm joc=unconfirmed route=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
    }

    @discardableResult
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = Self.externalSubtitleTrackIDBase + externalTracks.count
        externalTracks[id] = track
        let info = TrackInfo(id: id, name: track.name ?? "External subtitles", codec: track.formatHint ?? "text", language: track.language, isDefault: track.isDefault, isForced: track.isForced, isExternal: true)
        subtitleTracks.append(info)
        return info
    }
    func clearSubtitle() { activeSubtitleTrackIndex = nil; subtitleCues = []; synchroniseSubtitleSelection() }
    func clearSecondarySubtitle() { secondarySubtitleID = nil; secondarySubtitleCues = []; synchroniseSubtitleSelection() }
    func selectSubtitleTrack(index: Int) { guard subtitleTracks.contains(where: { $0.id == index }) else { return }; activeSubtitleTrackIndex = index; synchroniseSubtitleSelection() }
    func selectSecondarySubtitleTrack(index: Int) { guard subtitleTracks.contains(where: { $0.id == index }) else { return }; secondarySubtitleID = index; synchroniseSubtitleSelection() }
    private func synchroniseSubtitleSelection() {
        // Enable both slots directly. KSMEPlayer.select deliberately deselects every
        // sibling track, which would silently disable Vivid's second subtitle slot.
        for track in player?.tracks(mediaType: .subtitle) ?? [] {
            track.isEnabled = Int(track.trackID) == activeSubtitleTrackIndex || Int(track.trackID) == secondarySubtitleID
        }
        for id in [activeSubtitleTrackIndex, secondarySubtitleID].compactMap({ $0 }) {
            guard let external = externalTracks[id], externalCues[id] == nil, subtitleTasks[id] == nil else { continue }
            let token = generation
            isLoadingSubtitles = true
            subtitleTasks[id] = Task { @MainActor [weak self] in
                do {
                    let document = try await VividSubtitleLoader.load(external)
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    if case .cues(let cues) = document { self.externalCues[id] = cues }
                } catch {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.trace?.event("subtitle_load_failed")
                }
                guard let self, self.generation == token else { return }
                self.subtitleTasks[id] = nil; self.isLoadingSubtitles = !self.subtitleTasks.isEmpty
            }
        }
        updateSubtitles()
    }
    private func updateSubtitles() {
        subtitleCues = cues(for: activeSubtitleTrackIndex)
        secondarySubtitleCues = cues(for: secondarySubtitleID)
    }
    private func cues(for id: Int?) -> [SubtitleCue] {
        guard let id else { return [] }
        let time = player?.displayedVideoTime ?? currentTime
        if let external = externalTracks[id] {
            let offset = external.nativeTimelineOffsetSeconds
            return (externalCues[id] ?? []).filter { $0.startTime <= time + offset && time + offset < $0.endTime }.map {
                SubtitleCue(id: $0.id, startTime: $0.startTime - offset, endTime: $0.endTime - offset, body: $0.body, placement: $0.placement)
            }
        }
        guard let info = player?.subtitleDataSouce?.infos.first(where: { $0.subtitleID == String(id) }) else { return [] }
        return info.search(for: time).enumerated().compactMap { index, part in
            if let image = part.image?.cgImage {
                return SubtitleCue(id: index, startTime: part.start, endTime: part.end,
                    body: .image(SubtitleImage(cgImage: image, position: CGRect(origin: part.origin, size: CGSize(width: image.width, height: image.height)), canvasSize: softwareDisplaySize ?? .zero)))
            }
            guard let text = part.text else { return nil }
            var runs: [SubtitleTextRun] = []
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
                var run = SubtitleTextRun(text: text.attributedSubstring(from: range).string)
                if let font = attributes[.font] as? UIFont {
                    run.isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)
                    run.isItalic = font.fontDescriptor.symbolicTraits.contains(.traitItalic)
                    run.fontName = font.familyName
                    run.fontSize = Double(font.pointSize)
                }
                run.isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
                run.isStruckThrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                if let colour = attributes[.foregroundColor] as? UIColor {
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    if colour.getRed(&r, green: &g, blue: &b, alpha: &a) {
                        run.color = SubtitleColor(r: UInt8(clamping: Int(r * 255)), g: UInt8(clamping: Int(g * 255)), b: UInt8(clamping: Int(b * 255)))
                    }
                }
                runs.append(run)
            }
            return SubtitleCue(id: index, startTime: part.start, endTime: part.end, body: .richText(runs))
        }
    }
    func setNativeSubtitleRendering(_ active: Bool) {}
    func updateNativeMetadata(title: String, artwork: MPMediaItemArtwork?) {}
    func makeFrameExtractor(url: URL, httpHeaders: [String: String]) -> FrameExtractor? { nil }
}

/// Uses the same persistent SwiftUI surface slot without introducing another control layer.
struct VividPlayerSurface: UIViewRepresentable {
    @ObservedObject var engine: VividEngine
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let output = engine.player?.view
        for child in view.subviews where child !== output { child.removeFromSuperview() }
        if let output, output.superview !== view {
            output.frame = view.bounds; output.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            output.isUserInteractionEnabled = false
            view.addSubview(output)
        }
        engine.pictureReady()
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) {
        for child in view.subviews { child.removeFromSuperview() }
    }
}
#endif
