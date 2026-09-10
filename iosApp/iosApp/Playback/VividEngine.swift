// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit
import VividKit
import OSLog

@MainActor
final class VividEngine: ObservableObject {
    static let externalSubtitleTrackIDBase = 1_000_000
    let player = VividPlayer()
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
    var nativePlayerLayer: AVPlayerLayer? { nativeLayer }
    var activeAudioTrackIndex: Int?
    @Published var activeSubtitleTrackIndex: Int?
    private var secondarySubtitleTrackIndex: Int?
    var isSubtitleActive: Bool { activeSubtitleTrackIndex != nil }
    var isSecondarySubtitleActive: Bool { secondarySubtitleTrackIndex != nil }
    var nativeSubtitleTracks: [TrackInfo] { subtitleTracks.filter { !$0.isExternal } }
    var currentTime: Double { clock.currentTime }
    var isSeeking = false
    var isSessionReady: Bool { videoRoute != .none && state != .idle }
    var sourceVideoWidth: Int32 = 0
    var sourceVideoHeight: Int32 = 0
    var sourceVideoPixelAspectRatio: Double = 1
    var sourceVideoFrameRate: Double?
    var sourceVideoBitrate: Int64 = 0
    var sourceDVProfile: Int?
    var sourceVideoFormat: VideoFormat = .sdr
    var videoFormat: VideoFormat = .sdr
    var activeVideoDecoder: String? {
        if currentAVPlayer != nil { return "Apple AVFoundation" }
        guard sourceVideoWidth > 0 else { return nil }
        return player.hardwareVideoDecode ? "VideoToolbox hardware" : "FFmpeg software"
    }
    var activeAudioDecoder: String? { audioTracks.isEmpty ? nil : (currentAVPlayer != nil || player.nativeAudioDecode ? "Apple native" : "FFmpeg PCM → Apple audio") }
    var softwareDisplaySize: CGSize? {
        guard sourceVideoWidth > 0, sourceVideoHeight > 0 else { return nil }
        return CGSize(width: Double(sourceVideoWidth) * sourceVideoPixelAspectRatio, height: Double(sourceVideoHeight))
    }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }
    var backgroundPlaybackEnabled = true
    var pictureInPictureActive = false
    var deactivatesAudioSessionOnStop = false
    var ownsVideoNowPlayingSession = false
    private(set) var videoNowPlayingSession: MPNowPlayingSession?
    var volume: Float = 1 { didSet { player.volume = volume; currentAVPlayer?.volume = volume } }
    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { player.videoGravity = videoGravity; nativeLayer?.videoGravity = videoGravity }
    }
    #if os(tvOS)
    private let tvDisplayCriteria = TVPlaybackDisplayCriteria()
    private var tvDisplayTask: Task<Void, Never>?
    private var dtsNativeBridge: VividDTSNativeBridge?
    private let pcmAudioSession = TVPCMAudioSession()
    private static let audioSessionLog = Logger(subsystem: "com.blurbery.vivid", category: "AudioSession")
    #endif
    private var nativeLayer: AVPlayerLayer?
    private var subscriptions = Set<AnyCancellable>()
    private var nativeTimer: Any?
    private var nativeEndObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var source: URL?
    private var options = LoadOptions()
    var transientRecoveryBudget: VividTransientRecoveryBudget?
    var refreshSourceHeaders: (@Sendable () async -> [String: String]?)?
    private var generation: UInt64 = 0
    private var transportRate: Float = 1
    private var wantsPlayback = false
    private var resumeAfterInterruption = false
    private var externalSubtitles: [Int: ExternalSubtitleTrack] = [:]
    private var assRenderers: [Bool: (VividASSRenderer, Double)] = [:]
    private var subtitleRenderPending = false
    private var subtitleGeneration: UInt64 = 0
    private var subtitleTasks: [Bool: Task<Void, Never>] = [:]
    private var nativeAudioOptions: [Int: AVMediaSelectionOption] = [:]
    private var nativeSubtitleOptions: [Int: AVMediaSelectionOption] = [:]
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    /// Software/sample-buffer audio changes rebuild the demux/decode session.
    /// Keep that work serialized and retain the latest tap so reopening the
    /// picker while a change is settling can always switch back again.
    private var pendingAudioTrackIndex: Int?
    private var audioTrackSelectionTask: Task<Void, Never>?

    init() throws {
        #if os(tvOS)
        player.nativeDTSBridgeEnabled = false
        AVAudioSession.sharedInstance().publisher(for: \.outputNumberOfChannels)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.observePCMAudioSession(phase: "outputChanged") }
            .store(in: &subscriptions)
        player.$displayFormatDescription.sink { [weak self] format in
            guard let self, self.currentAVPlayer == nil, !self.options.audioOnly,
                  let format, let video = self.player.tracks.first(where: { $0.kind == .video }) else { return }
            self.tvDisplayCriteria.apply(formatDescription: format, frameRate: Float(video.frameRate))
        }.store(in: &subscriptions)
        #endif
        player.$currentTime.sink { [weak self] time in
            guard let self, self.currentAVPlayer == nil else { return }
            self.clock.currentTime = time
            self.renderExternalSubtitles(at: time)
        }.store(in: &subscriptions)
        player.$state.sink { [weak self] state in
            guard let self, self.currentAVPlayer == nil, self.videoRoute != .none, !self.isSeeking else { return }
            #if os(tvOS)
            if case .some(.nativeDTSRequired) = self.player.error { return }
            #endif
            self.receive(state)
        }.store(in: &subscriptions)
        player.$hasPresentedVideo.sink { [weak self] ready in
            if ready { self?.hasFirstFrameReadyForDisplay = true }
        }.store(in: &subscriptions)
        player.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            func converted(_ cue: VividSubtitleCue) -> SubtitleCue {
                let body: SubtitleCue.Body
                if let image = cue.image { body = .image(SubtitleImage(cgImage: image, position: cue.rectangle, canvasSize: cue.canvas)) }
                else { body = .text(cue.text ?? "") }
                return SubtitleCue(id: cue.id, startTime: cue.start, endTime: cue.end, body: body)
            }
            if self.activeSubtitleTrackIndex.map({ self.externalSubtitles[$0] == nil }) == true {
                self.subtitleCues = cues.filter { $0.track == self.activeSubtitleTrackIndex }.map(converted)
            }
            if self.secondarySubtitleTrackIndex.map({ self.externalSubtitles[$0] == nil }) == true {
                self.secondarySubtitleCues = cues.filter { $0.track == self.secondarySubtitleTrackIndex }.map(converted)
            }
        }.store(in: &subscriptions)
        player.$bufferedAhead.sink { [weak self] value in
            guard let self, self.currentAVPlayer == nil else { return }
            self.diagnostics.liveTelemetry = LiveTelemetry(forwardBufferSeconds: value, displayCushionSeconds: self.player.decodedAhead)
        }.store(in: &subscriptions)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let flags = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            #if os(tvOS) && DEBUG
            if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") { print("[VividTVProbe] interruption=\(type ?? 999) flags=\(flags)") }
            #endif
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.wantsPlayback; self.pause()
                } else if self.resumeAfterInterruption && flags & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
                    self.play(); self.resumeAfterInterruption = false
                }
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.backgroundPlaybackEnabled && !self.pictureInPictureActive { self.pause() }
                else if !self.pictureInPictureActive { self.player.displayLayer.removeFromSuperlayer() }
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            #if os(tvOS) && DEBUG
            if ProcessInfo.processInfo.arguments.contains("-VividTVProbe") { print("[VividTVProbe] routeChange=\(reason ?? 999)") }
            #endif
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
            #if os(tvOS)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if reason != AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue,
                   reason != AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                    self.configurePCMAudioSession()
                }
                self.observePCMAudioSession(phase: "routeChanged")
            }
            #endif
        }
    }
    #if os(tvOS)
    private var usesPCMAudioSession: Bool {
        videoRoute == .sampleBuffer && currentAVPlayer == nil && !options.audioOnly && !player.nativeAudioDecode
    }

    private func configurePCMAudioSession() {
        let channels = audioTracks.first { $0.id == activeAudioTrackIndex }?.channels ?? 0
        pcmAudioSession.configure(AVAudioSession.sharedInstance(), sourceChannels: channels,
                                  eligible: usesPCMAudioSession, log: Self.logAudioSession)
    }

    private func observePCMAudioSession(phase: String) {
        guard usesPCMAudioSession else { return }
        let channels = audioTracks.first { $0.id == activeAudioTrackIndex }?.channels ?? 0
        pcmAudioSession.observe(AVAudioSession.sharedInstance(), sourceChannels: channels,
                                phase: phase, log: Self.logAudioSession)
    }

    private static func logAudioSession(_ message: String) {
        audioSessionLog.info("[VividAudioSession] \(message, privacy: .public)")
    }
    #endif

    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool {
        guard source == url, currentAVPlayer == nil, !options.nativeRemoteHLS,
              player.updateSourceHeaders(headers, for: url) else { return false }
        options.httpHeaders = headers
        return true
    }

    func load(url: URL, startPosition: Double = 0, options: LoadOptions = LoadOptions(), audioSourceStreamIndex: Int32? = nil) async throws {
        #if os(tvOS)
        stop(resetDisplayCriteria: options.audioOnly)
        #else
        stop()
        #endif
        generation &+= 1
        let epoch = generation
        self.source = url; self.options = options
        wantsPlayback = options.autoplay
        state = .loading; playbackPhase = .loading
        startupProgress = StartupProgress(checkpoint: "Opening source")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: options.audioOnly ? .default : .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            for track in options.externalSubtitles { _ = addExternalSubtitleTrack(track) }
            if options.nativeRemoteHLS || url.pathExtension.lowercased() == "m3u8" {
                try await loadHLS(url, at: startPosition, epoch: epoch)
            } else {
                videoRoute = options.audioOnly ? .audio : .sampleBuffer
                softwarePiPSource = options.audioOnly ? nil : SampleBufferPiPSource(layer: player.displayLayer, engine: self)
                player.bufferAheadTarget = min(40, max(2, Double(options.forwardBufferSegments ?? 10) * 2))
                do {
                    try await player.load(VividSource(url: url, headers: options.httpHeaders,
                        recoveryBudget: transientRecoveryBudget, refreshHeaders: refreshSourceHeaders), at: startPosition,
                    autoplay: wantsPlayback, audioTrack: audioSourceStreamIndex.map(Int.init),
                    audioTrackOrdinal: options.audioTrackOrdinal, audioOnly: options.audioOnly,
                    preferredAudioLanguages: options.preferredAudioLanguages)
                } catch {
                    #if os(tvOS)
                    if case VividPlaybackError.nativeDTSRequired(let audio) = error {
                        guard epoch == generation else { throw CancellationError() }
                        try await loadNativeDTS(url, audio: audio, at: startPosition, epoch: epoch)
                        return
                    }
                    #endif
                    throw error
                }
                guard epoch == generation else { throw CancellationError() }
                audioTracks = player.tracks.filter { $0.kind == .audio }.map(TrackInfo.init)
                subtitleTracks = player.tracks.filter { $0.kind == .subtitle }.map(TrackInfo.init) + subtitleTracks.filter(\.isExternal)
                mediaChapters = player.chapters.map { MediaChapter(id: $0.id, name: $0.name, startSeconds: $0.startSeconds) }
                activeAudioTrackIndex = player.selectedAudioTrack
                #if os(tvOS)
                configurePCMAudioSession()
                #endif
                duration = player.duration
                if let video = player.tracks.first(where: { $0.kind == .video }) {
                    sourceVideoWidth = Int32(video.width); sourceVideoHeight = Int32(video.height)
                    sourceVideoFrameRate = video.frameRate.isFinite && video.frameRate > 0 ? video.frameRate : nil
                    sourceVideoPixelAspectRatio = video.pixelAspectRatio
                    sourceVideoBitrate = video.bitrate
                    sourceDVProfile = video.dolbyVisionProfile
                    videoFormat = video.dynamicRange == "hdr10" ? .hdr10 : video.dynamicRange == "hlg" ? .hlg : .sdr
                    sourceVideoFormat = video.dolbyVisionProfile != nil ? .dolbyVision : videoFormat
                }
                receive(player.state)
            }
            guard epoch == generation else { throw CancellationError() }
            startupProgress = StartupProgress(checkpoint: "Decoder ready")
            if let selected = options.preferredSubtitleLanguages.lazy.compactMap({ language in
                self.subtitleTracks.first { $0.language?.caseInsensitiveCompare(language) == .orderedSame }
            }).first { selectSubtitleTrack(index: selected.id) }
        } catch {
            guard epoch == generation else { throw CancellationError() }
            if error is CancellationError { throw error }
            report(error); throw error
        }
    }
    #if os(tvOS)
    private func loadNativeDTS(_ url: URL, audio: Int, at time: Double, epoch: UInt64) async throws {
        videoRoute = .none; player.stop(); softwarePiPSource = nil
        errorInfo = nil; state = .loading; playbackPhase = .loading
        startupProgress = StartupProgress(checkpoint: "Preparing DTS audio")
        let bridge = try VividDTSNativeBridge(source: VividSource(url: url, headers: options.httpHeaders), audioTrack: audio, at: time)
        dtsNativeBridge = bridge
        let started = Date()
        let localURL = try await bridge.start()
        guard epoch == generation, dtsNativeBridge === bridge else { bridge.stop(); throw CancellationError() }
        try await loadHLS(localURL, at: max(0, time - bridge.timelineOffset), epoch: epoch)
        guard epoch == generation, let inventory = bridge.inventory else { throw CancellationError() }
        audioTracks = inventory.tracks.filter { $0.kind == .audio }.map(TrackInfo.init)
        subtitleTracks = inventory.tracks.filter { $0.kind == .subtitle }.map(TrackInfo.init) + subtitleTracks.filter(\.isExternal)
        mediaChapters = inventory.chapters.map { MediaChapter(id: $0.id, name: $0.name, startSeconds: $0.startSeconds) }
        duration = inventory.duration; activeAudioTrackIndex = audio
        if let video = inventory.tracks.first(where: { $0.kind == .video }) {
            sourceVideoWidth = Int32(video.width); sourceVideoHeight = Int32(video.height)
            sourceVideoFrameRate = video.frameRate; sourceVideoPixelAspectRatio = video.pixelAspectRatio
            sourceVideoBitrate = video.bitrate; sourceDVProfile = video.dolbyVisionProfile
            videoFormat = video.dynamicRange == "hdr10" ? .hdr10 : video.dynamicRange == "hlg" ? .hlg : .sdr
            sourceVideoFormat = videoFormat
        }
        startupProgress = StartupProgress(checkpoint: "Decoder ready")
        if let selected = options.preferredSubtitleLanguages.lazy.compactMap({ language in
            self.subtitleTracks.first { $0.language?.caseInsensitiveCompare(language) == .orderedSame }
        }).first { selectSubtitleTrack(index: selected.id) }
        #if DEBUG
        print("[VividNativeDTS] ready seconds=\(Date().timeIntervalSince(started)) audio=compatible-surround video=copy")
        #endif
    }

    private func updateNativeDTSSubtitles(_ cues: [VividSubtitleCue]) {
        func convert(_ cue: VividSubtitleCue) -> SubtitleCue {
            let body: SubtitleCue.Body = cue.image.map {
                .image(SubtitleImage(cgImage: $0, position: cue.rectangle, canvasSize: cue.canvas))
            } ?? .text(cue.text ?? "")
            return SubtitleCue(id: cue.id, startTime: cue.start, endTime: cue.end, body: body)
        }
        if let id = activeSubtitleTrackIndex, externalSubtitles[id] == nil { subtitleCues = cues.filter { $0.track == id }.map(convert) }
        if let id = secondarySubtitleTrackIndex, externalSubtitles[id] == nil { secondarySubtitleCues = cues.filter { $0.track == id }.map(convert) }
    }
    #endif

    private func loadHLS(_ url: URL, at time: Double, epoch: UInt64) async throws {
        #if os(tvOS)
        let localBridge = dtsNativeBridge != nil
        #else
        let localBridge = false
        #endif
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": localBridge ? [:] : options.httpHeaders])
        let item = AVPlayerItem(asset: asset)
        let native = AVPlayer(playerItem: item)
        native.volume = volume
        native.allowsExternalPlayback = !localBridge && options.httpHeaders.isEmpty
        currentAVPlayer = native; currentAVPlayerItem = item
        nativeLayer = AVPlayerLayer(player: native); nativeLayer?.videoGravity = videoGravity
        #if os(tvOS)
        if !options.audioOnly {
            tvDisplayTask = Task { [weak self] in
                do {
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
                    let (rate, formats) = try await track.load(.nominalFrameRate, .formatDescriptions)
                    guard !Task.isCancelled, let self, self.generation == epoch,
                          let format = formats.first else { return }
                    self.tvDisplayCriteria.apply(formatDescription: format, frameRate: rate)
                } catch { /* A missing display hint must not interrupt playback. */ }
            }
        }
        #endif
        videoRoute = options.audioOnly ? .audio : .remoteBypass
        videoNowPlayingSession = MPNowPlayingSession(players: [native])
        let playable = try await asset.load(.isPlayable)
        guard epoch == generation else { throw CancellationError() }
        guard playable else { throw VividPlaybackError.unsupportedTrack }
        let total = try await asset.load(.duration).seconds
        duration = total.isFinite ? total : 0
        if let group = try await asset.loadMediaSelectionGroup(for: .audible) {
            audioGroup = group
            nativeAudioOptions = Dictionary(uniqueKeysWithValues: group.options.enumerated().map { ($0.offset, $0.element) })
            audioTracks = group.options.enumerated().map { TrackInfo(id: $0.offset, name: $0.element.displayName, codec: "Apple native", language: $0.element.extendedLanguageTag) }
            activeAudioTrackIndex = group.options.firstIndex(where: { $0 === item.currentMediaSelection.selectedMediaOption(in: group) })
        }
        if let group = try await asset.loadMediaSelectionGroup(for: .legible) {
            subtitleGroup = group
            // HLS subtitle renditions are separate resources. Only in-band
            // closed captions belong in the embedded-only player inventory.
            let embeddedOptions = group.options.enumerated().filter { $0.element.mediaType == .closedCaption }
            nativeSubtitleOptions = Dictionary(uniqueKeysWithValues: embeddedOptions.map { ($0.offset, $0.element) })
            subtitleTracks += embeddedOptions.map { TrackInfo(id: $0.offset, name: $0.element.displayName, codec: "Closed captions", language: $0.element.extendedLanguageTag, isNativelyRenderedSubtitle: true) }
            item.select(nil, in: group)
        }
        guard epoch == generation else { throw CancellationError() }
        if time > 0 { await native.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        nativeTimer = native.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.generation == epoch else { return }
                var sourceTime = time.seconds.isFinite ? time.seconds : 0
                #if os(tvOS)
                if let bridge = self.dtsNativeBridge {
                    sourceTime += bridge.timelineOffset
                    bridge.updatePlayhead(sourceTime)
                    if let error = bridge.error { native.pause(); self.report(error); return }
                    self.updateNativeDTSSubtitles(bridge.subtitles(at: sourceTime))
                }
                #endif
                self.clock.currentTime = max(0, sourceTime)
                self.renderExternalSubtitles(at: self.clock.currentTime)
                if item.status == .failed { self.report(item.error ?? VividPlaybackError.invalidSource); return }
                self.hasFirstFrameReadyForDisplay = self.nativeLayer?.isReadyForDisplay == true
                if self.state == .ended || self.isSeeking { return }
                self.isBuffering = self.wantsPlayback && native.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.state = self.isBuffering ? .loading : (self.wantsPlayback ? .playing : .paused)
                self.playbackPhase = self.isBuffering ? .rebuffering : (self.wantsPlayback ? .playing : .paused)
            }
        }
        nativeEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.generation == epoch else { return }; self.state = .ended; self.playbackPhase = .ended }
        }
        if wantsPlayback { native.playImmediately(atRate: transportRate) }
        else { state = .paused; playbackPhase = .paused }
    }
    private func receive(_ value: VividPlayer.State) {
        #if os(tvOS)
        if value == .playing { observePCMAudioSession(phase: "playing") }
        #endif
        isBuffering = value == .buffering || value == .opening
        switch value {
        case .idle: state = .idle; playbackPhase = .idle
        case .opening: state = .loading; playbackPhase = .loading
        case .paused: state = .paused; playbackPhase = .paused
        case .playing: state = .playing; playbackPhase = .playing
        case .buffering: state = .loading; playbackPhase = .rebuffering
        case .ended: state = .ended; playbackPhase = .ended
        case .failed: report(player.error ?? .invalidSource)
        }
    }
    private func report(_ error: Error) {
        #if os(tvOS)
        tvDisplayTask?.cancel(); tvDisplayTask = nil
        tvDisplayCriteria.reset()
        #endif
        let native = error as NSError
        let failure: PlaybackErrorInfo
        if PlaybackErrorInfo.isHTTPAuthenticationFailure(error) {
            failure = PlaybackErrorInfo(kind: .sourceRefused,
                message: "The media source requires renewed authentication (401).",
                underlyingDomain: NSURLErrorDomain, underlyingCode: 401)
        } else if let typed = error as? VividPlaybackError, case let .network(code) = typed {
            failure = PlaybackErrorInfo(kind: code == 429 ? .sourceRateLimited : .sourceRefused,
                message: "The media source could not be read (\(code)).", underlyingDomain: NSURLErrorDomain, underlyingCode: code)
        } else {
            failure = PlaybackErrorInfo(kind: currentAVPlayer == nil ? .softwarePipelineFailed : .nativeItemFailed,
                message: "Vivid could not play this media: \(error.localizedDescription)", underlyingDomain: native.domain, underlyingCode: native.code)
        }
        errorInfo = failure; state = .error(failure.message); playbackPhase = .error(failure.message)
        isBuffering = false
    }
    func play() {
        wantsPlayback = true
        do { try AVAudioSession.sharedInstance().setActive(true) } catch { report(error); return }
        #if os(tvOS)
        configurePCMAudioSession()
        #endif
        if let currentAVPlayer { currentAVPlayer.playImmediately(atRate: transportRate) } else { player.play() }
    }
    func pause() { wantsPlayback = false; currentAVPlayer?.pause(); player.pause(); if videoRoute != .none { state = .paused; playbackPhase = .paused } }
    func setRate(_ rate: Float) { transportRate = min(3, max(0.25, rate)); player.setRate(transportRate); if wantsPlayback { currentAVPlayer?.rate = transportRate } }
    func seek(to time: Double) async {
        #if os(tvOS)
        if dtsNativeBridge != nil, let source, let audio = activeAudioTrackIndex {
            var reloadOptions = options; reloadOptions.autoplay = wantsPlayback
            do { try await load(url: source, startPosition: time, options: reloadOptions, audioSourceStreamIndex: Int32(audio)) }
            catch { if !(error is CancellationError) { report(error) } }
            return
        }
        #endif
        let epoch = generation
        isSeeking = true; state = .seeking; playbackPhase = .seeking
        defer { if epoch == generation { isSeeking = false } }
        do {
            if let currentAVPlayer { await currentAVPlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); clock.currentTime = time }
            else { try await player.seek(to: time); clock.currentTime = player.currentTime }
            guard epoch == generation else { return }
            if wantsPlayback { play() } else { pause() }
        } catch { if epoch == generation { report(error) } }
    }
    func selectAudioTrack(index: Int) {
        #if os(tvOS)
        if player.nativeDTSBridgeEnabled,
           dtsNativeBridge != nil || audioTracks.contains(where: { $0.id == index && $0.codec == "dts" }),
           let source {
            let position = currentTime
            var reloadOptions = options; reloadOptions.autoplay = wantsPlayback
            audioTrackSelectionTask?.cancel()
            audioTrackSelectionTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.audioTrackSelectionTask = nil
                do { try await self.load(url: source, startPosition: position, options: reloadOptions, audioSourceStreamIndex: Int32(index)) }
                catch { if !(error is CancellationError) { self.report(error) } }
            }
            return
        }
        #endif
        if let group = audioGroup, let option = nativeAudioOptions[index] { currentAVPlayerItem?.select(option, in: group); activeAudioTrackIndex = index; return }
        pendingAudioTrackIndex = index
        guard audioTrackSelectionTask == nil else { return }
        let epoch = generation
        audioTrackSelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.audioTrackSelectionTask = nil }
            while !Task.isCancelled,
                  self.generation == epoch,
                  let requestedIndex = self.pendingAudioTrackIndex {
                self.pendingAudioTrackIndex = nil
                do {
                    try await self.player.selectAudioTrack(requestedIndex)
                    guard !Task.isCancelled, self.generation == epoch else { return }
                    self.audioTracks = self.player.tracks
                        .filter { $0.kind == .audio }
                        .map(TrackInfo.init)
                    self.activeAudioTrackIndex = requestedIndex
                    #if os(tvOS)
                    self.configurePCMAudioSession()
                    #endif
                } catch is CancellationError {
                    return
                } catch {
                    guard self.generation == epoch else { return }
                    self.pendingAudioTrackIndex = nil
                    self.report(error)
                    return
                }
            }
        }
    }
    func reloadAtCurrentPosition() async throws {
        guard let source else { throw VividPlaybackError.invalidSource }
        let time = currentTime; var options = options; options.autoplay = wantsPlayback
        try await load(url: source, startPosition: time, options: options, audioSourceStreamIndex: activeAudioTrackIndex.map(Int32.init))
    }
    func prepareForItemReplacement() { pause() }
    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        #if os(tvOS)
        dtsNativeBridge?.stop(); dtsNativeBridge = nil
        tvDisplayTask?.cancel(); tvDisplayTask = nil
        if resetDisplayCriteria { tvDisplayCriteria.reset() }
        #endif
        generation &+= 1
        audioTrackSelectionTask?.cancel(); audioTrackSelectionTask = nil
        pendingAudioTrackIndex = nil
        for task in subtitleTasks.values { task.cancel() }; subtitleTasks.removeAll()
        if let nativeTimer { currentAVPlayer?.removeTimeObserver(nativeTimer) }; nativeTimer = nil
        if let nativeEndObserver { NotificationCenter.default.removeObserver(nativeEndObserver) }; nativeEndObserver = nil
        currentAVPlayer?.pause(); currentAVPlayer?.replaceCurrentItem(with: nil)
        currentAVPlayer = nil; currentAVPlayerItem = nil; nativeLayer = nil; videoNowPlayingSession = nil
        softwarePiPSource = nil; videoRoute = .none; player.stop()
        #if os(tvOS)
        pcmAudioSession.restore(AVAudioSession.sharedInstance(), log: Self.logAudioSession)
        #endif
        audioTracks = []; subtitleTracks = []; mediaChapters = []; externalSubtitles = [:]
        nativeAudioOptions = [:]; nativeSubtitleOptions = [:]; audioGroup = nil; subtitleGroup = nil
        assRenderers = [:]; subtitleGeneration &+= 1
        subtitleCues = []; secondarySubtitleCues = []; activeAudioTrackIndex = nil
        activeSubtitleTrackIndex = nil; secondarySubtitleTrackIndex = nil
        state = .idle; playbackPhase = .idle; duration = 0; clock.currentTime = 0; errorInfo = nil
        sourceVideoWidth = 0; sourceVideoHeight = 0; hasFirstFrameReadyForDisplay = false; isSeeking = false
        sourceVideoBitrate = 0; sourceVideoFrameRate = nil; sourceVideoPixelAspectRatio = 1
        sourceDVProfile = nil; sourceVideoFormat = .sdr; videoFormat = .sdr
        wantsPlayback = false; isBuffering = false; isLoadingSubtitles = false
        if deactivatesAudioSessionOnStop { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    @discardableResult func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = Self.externalSubtitleTrackIDBase + externalSubtitles.count
        externalSubtitles[id] = track
        let info = TrackInfo(id: id, name: track.name ?? track.language ?? "Subtitles", codec: track.formatHint ?? track.url.pathExtension,
            language: track.language, isDefault: track.isDefault, isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired, isExternal: true)
        subtitleTracks.append(info); return info
    }
    func clearSubtitle() { selectSubtitle(nil, secondary: false) }
    func clearSecondarySubtitle() { selectSubtitle(nil, secondary: true) }
    func selectSubtitleTrack(index: Int) { selectSubtitle(index, secondary: false) }
    func selectSecondarySubtitleTrack(index: Int) { selectSubtitle(index, secondary: true) }
    func setNativeSubtitleRendering(_ enabled: Bool) {
        if let group = subtitleGroup { currentAVPlayerItem?.select(enabled ? activeSubtitleTrackIndex.flatMap { nativeSubtitleOptions[$0] } : nil, in: group) }
    }
    private func selectSubtitle(_ id: Int?, secondary: Bool) {
        subtitleGeneration &+= 1
        assRenderers[secondary] = nil
        subtitleTasks[secondary]?.cancel()
        if secondary { secondarySubtitleTrackIndex = id; secondarySubtitleCues = [] }
        else { activeSubtitleTrackIndex = id; subtitleCues = [] }
        if !secondary, let group = subtitleGroup { currentAVPlayerItem?.select(id.flatMap { nativeSubtitleOptions[$0] }, in: group) }
        #if os(tvOS)
        dtsNativeBridge?.selectSubtitles(Set([activeSubtitleTrackIndex, secondarySubtitleTrackIndex].compactMap { $0 }.filter { externalSubtitles[$0] == nil }))
        #endif
        if currentAVPlayer == nil {
            let selected = Set([activeSubtitleTrackIndex, secondarySubtitleTrackIndex].compactMap { $0 }.filter { externalSubtitles[$0] == nil })
            let epoch = generation
            Task {
                guard epoch == generation else { return }
                do { try await player.selectSubtitles(selected) }
                catch { if epoch == generation && !(error is CancellationError) { report(error) } }
            }
        }
        guard let id, let track = externalSubtitles[id] else { return }
        let epoch = generation
        isLoadingSubtitles = true
        subtitleTasks[secondary] = Task { [weak self] in
            do {
                let document = try await VividSubtitleLoader.load(track)
                guard let self, !Task.isCancelled, self.generation == epoch else { return }
                switch document {
                case .cues(let cues):
                    if secondary { self.secondarySubtitleCues = cues } else { self.subtitleCues = cues }
                case .ass(let renderer): self.assRenderers[secondary] = (renderer, track.nativeTimelineOffsetSeconds)
                }
                self.isLoadingSubtitles = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == epoch else { return }
                self.isLoadingSubtitles = false
                self.errorInfo = PlaybackErrorInfo(kind: .sourceRefused, message: "The selected subtitle could not be loaded.")
            }
        }
    }
    private func renderExternalSubtitles(at time: Double) {
        guard !subtitleRenderPending, !assRenderers.isEmpty else { return }
        subtitleRenderPending = true
        let epoch = subtitleGeneration, renderers = assRenderers
        Task { [weak self] in
            for (secondary, entry) in renderers {
                let image = await entry.0.image(at: time + entry.1)
                guard let self, self.subtitleGeneration == epoch else { continue }
                let cues = image.map { [SubtitleCue(id: -1, startTime: max(0, time + entry.1 - 1), endTime: time + entry.1 + 1,
                    body: .image(SubtitleImage(cgImage: $0, position: CGRect(x: 0, y: 0, width: 1, height: 1), canvasSize: CGSize(width: 1920, height: 1080))))] } ?? []
                if secondary { self.secondarySubtitleCues = cues } else { self.subtitleCues = cues }
            }
            self?.subtitleRenderPending = false
        }
    }
    func makeFrameExtractor(url: URL, httpHeaders: [String: String]) -> FrameExtractor? { FrameExtractor(url: url, headers: httpHeaders) }
    deinit {
        for observer in [interruptionObserver, backgroundObserver, foregroundObserver, routeObserver, nativeEndObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }
}

struct VividPlayerSurface: UIViewRepresentable {
    @ObservedObject var engine: VividEngine
    func makeUIView(context: Context) -> VividSurfaceView { VividSurfaceView() }
    func updateUIView(_ view: VividSurfaceView, context: Context) {
        view.mount(engine.nativePlayerLayer ?? engine.player.displayLayer)
    }
}
final class VividSurfaceView: UIView {
    private weak var mounted: CALayer?
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func mount(_ next: CALayer) {
        if mounted !== next { mounted?.removeFromSuperlayer(); mounted = next }
        if next.superlayer !== layer { layer.addSublayer(next) }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true); mounted?.frame = bounds; CATransaction.commit()
    }
}
