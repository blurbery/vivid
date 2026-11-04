// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if os(iOS) || os(tvOS)
import AVFoundation
import AVKit
import Combine
import Libmpv
import MediaPlayer
import SwiftUI

/// Vivid's Lucid Engine adapter. It turns Vivid's load options into one
/// engine session per load and the engine's properties and events into the
/// state the player shows. Lucid owns output and audio and video timing.
@MainActor
final class VividMPVPlayer: NSObject, ObservableObject {
    // MARK: State the player shows

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
    private(set) var activeAudioTrackIndex: Int?
    private(set) var isSeeking = false
    private(set) var isSessionReady = false

    // MARK: The source as Lucid reports it

    private(set) var sourceVideoWidth: Int32 = 0
    private(set) var sourceVideoHeight: Int32 = 0
    private(set) var sourceVideoPixelAspectRatio: Double = 1
    private(set) var sourceVideoFrameRate: Double?
    private(set) var sourceVideoBitrate: Int64 = 0
    private(set) var sourceDVProfile: Int?
    private(set) var sourceVideoFormat: VideoFormat = .sdr
    private(set) var videoFormat: VideoFormat = .sdr
    /// The picture's size with its pixel aspect ratio applied (mpv's `dw`
    /// and `dh`), so an anamorphic video has its shown shape.
    private var sourceDisplaySize: CGSize?

    // MARK: Settings the controller sets

    var backgroundPlaybackEnabled = true
    var pictureInPictureActive = false {
        didSet { pictureInPictureDidChange() }
    }
    var deactivatesAudioSessionOnStop = false
    var ownsVideoNowPlayingSession = false
    var volume: Float = 1 {
        didSet { core?.setProperty("volume", value: String(volume * 100)) }
    }
    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { core?.sampleBufferDisplayLayer?.videoGravity = videoGravity }
    }
    var transientRecoveryBudget: VividTransientRecoveryBudget?
    var refreshSourceHeaders: (@Sendable () async -> [String: String]?)?
    var preferLosslessAudio = false
    /// The persistent host view, kept across loads.
    let surface = VividMPVHostView()

    // MARK: One load

    private struct LoadedSource {
        let url: URL
        let options: LoadOptions
        let audioSourceStreamIndex: Int32?
    }

    private var core: VividMPVCore?
    private var delegateProxy: VividMPVDelegate?
    /// Bumped by every stop, so work started for an earlier load finds itself stale.
    private var generation: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var source: LoadedSource?
    /// The source Vivid reads on Lucid's behalf for this load, if any.
    private var managedSource: VividManagedStreamSource?
    private var managedSourceURL: URL?
    private var requestedRate: Float = 1
    /// Read from Settings at each load, so a change applies from the next one.
    private var audioEnhancement = VividAudioEnhancement.off
    private var rateTask: Task<Void, Never>?
    private var endConfirmationTask: Task<Void, Never>?
    private var wantsPlay = false
    private var rawTracks: [[String: Any]] = []
    private var videoTrack: [String: Any] = [:]
    /// The resume starts on the keyframe at or before the saved position.
    private var keyframeResumePending = false
    private var initialAudioApplied = false
    private var outputChannels: Int?
    private var outputAudioFormat: String?
    private var videoDecoder: String?
    private var audioDecoder: String?
    private var cacheSnapshot: [String: Any] = [:]
    private var trace: PlaybackTrialTrace?
    private var sessionSampler: Task<Void, Never>?
    #if VIVID_P8_TRIAL
    private var audioTraceTask: Task<Void, Never>?
    #endif

    /// `avsync` changes on almost every presented frame but only feeds the
    /// statistics overlay, which formats about once a second. It's published
    /// at most four times a second, always finishing on the latest value.
    private static let avSyncPublishInterval: TimeInterval = 0.25
    private var pendingAvSyncGapMs: Double??
    private var lastAvSyncPublishUptime: TimeInterval = 0
    private var avSyncPublishTask: Task<Void, Never>?

    // MARK: Subtitles

    private var secondarySubtitleID: Int?
    private var externalTracks: [Int: ExternalSubtitleTrack] = [:]
    private var nextExternalID = 1_000_000
    /// ASS files Lucid draws, by external track id.
    private var nativeExternalFiles: [Int: URL] = [:]
    /// Picture in Picture shows only Lucid's pictures, so a text file the
    /// overlay draws is also given to Lucid, unselected, once it's chosen,
    /// and drawn by libass while Picture in Picture runs (iOS).
    private var pictureInPictureFiles: [Int: URL] = [:]
    private var pictureInPictureTexts: [Int: String] = [:]
    private var pictureInPictureCopying: Set<Int> = []
    private var externalCues: [Int: VividSubtitleCueCursor] = [:]
    private var subtitleTasks: [Int: Task<Void, Never>] = [:]

    /// What the overlay was last given, so a clock tick that changes no cue
    /// publishes nothing.
    private struct CuePublication: Equatable {
        let trackID: Int?
        let offsets: [Int]
        static let empty = CuePublication(trackID: nil, offsets: [])
    }

    private var primaryCuePublication = CuePublication.empty
    private var secondaryCuePublication = CuePublication.empty
    private var subtitleDelaySeconds: Double = 0
    /// The secondary track keeps its own delay, so an OpenSubtitles file's
    /// offset on the main subtitle doesn't shift the other one.
    private var secondarySubtitleDelaySeconds: Double = 0
    /// The style last sent to Lucid, so a layout pass that changes nothing
    /// sends nothing.
    private var subtitleAppearance: SubtitleAppearance?
    private var subtitleGeometry: LucidSubtitleStyle.Geometry?
    private var subtitleStyleOptions: [String: String] = [:]

    // MARK: The shared audio session

    /// The load that activated the session most recently, across every player.
    private static var audioSessionOwner: UUID?
    private var audioSessionToken: UUID?
    /// Entered for each retired core until its disposal completes.
    private static let audioTeardown = DispatchGroup()

    // MARK: Derived state

    var nativePlayerLayer: AVPlayerLayer? { nil }
    var videoNowPlayingSession: MPNowPlayingSession? { nil }
    var isSubtitleActive: Bool { activeSubtitleTrackIndex != nil }
    var isSecondarySubtitleActive: Bool { secondarySubtitleID != nil }
    var nativeSubtitleTracks: [TrackInfo] { subtitleTracks.filter { !$0.isExternal } }
    var currentTime: Double { clock.currentTime }
    var activeVideoFormat: VideoFormat { videoFormat }
    var activeVideoDecoder: String? { videoDecoder }
    var activeAudioDecoder: String? { audioDecoder }
    var readAheadAvailableSeconds: Double? { diagnostics.liveTelemetry?.forwardBufferSeconds }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }

    /// Lucid outputs profile 8.1 for profile 7.
    var activeDolbyProfileLabel: String? {
        guard videoFormat == .dolbyVision, let profile = sourceDVProfile else { return nil }
        if profile == 7 { return "DV Profile 8.1" }
        let compatibility = videoTrack["dolby-vision-compatibility-id"] as? Int64
        return "DV Profile \(profile)" + (compatibility.map { ".\($0)" } ?? "")
    }

    var activeAudioOutputFormat: String? {
        guard isSessionReady, !audioTracks.isEmpty else { return nil }
        // Output parameters tell the compressed carrier from decoded PCM.
        guard outputAudioFormat?.contains("spdif") == true else {
            guard let count = outputChannels else { return "Not reported" }
            return "PCM " + (Self.channelLayouts[count] ?? "\(count) ch")
        }
        let codec: String
        switch outputAudioFormat {
        case "spdif-eac3": codec = "E-AC-3"
        case "spdif-ac3": codec = "AC-3"
        default: return "Compressed audio"
        }
        // IEC carrier channels don't describe the compressed audio's layout.
        let track = audioTracks.first { $0.id == activeAudioTrackIndex }
        let layout = track.flatMap { Self.channelLayouts[$0.channels] }
        var atmos = ""
        if #available(iOS 26.0, tvOS 26.0, *), AVAudioSession.sharedInstance().renderingMode == .dolbyAtmos {
            atmos = " Atmos"
        }
        return codec + atmos + (layout.map { " " + $0 } ?? "")
    }

    var softwareDisplaySize: CGSize? {
        guard sourceVideoWidth > 0 else { return nil }
        return sourceDisplaySize ?? CGSize(width: Int(sourceVideoWidth), height: Int(sourceVideoHeight))
    }

    private static let channelLayouts = [1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"]

    private static var appleRenderingMode: Int {
        if #available(iOS 26.0, tvOS 26.0, *) { return AVAudioSession.sharedInstance().renderingMode.rawValue }
        return 0
    }

    private func pictureInPictureDidChange() {
        core?.isPipActive = pictureInPictureActive
        PlaybackSessionRecorder.shared.setPictureInPicture(pictureInPictureActive)
        core?.setPipSubtitleCompositing(pictureInPictureActive)
        core?.externalDisplayDidChange()
        core?.updateFrame()
        refreshSubtitleGeometry()
        // A chosen text file switches between the overlay and Lucid's copy.
        guard !pictureInPictureFiles.isEmpty else { return }
        if let id = activeSubtitleTrackIndex, pictureInPictureFiles[id] != nil { selectSubtitleTrack(index: id) }
        if let id = secondarySubtitleID, pictureInPictureFiles[id] != nil { selectSecondarySubtitleTrack(index: id) }
    }
}

// MARK: - Loading

extension VividMPVPlayer {
    /// Waits between audio session activation attempts on one load. Activation
    /// can be refused for a moment while a new output route settles (HDMI or
    /// eARC renegotiation, a soundbar or headphones switching).
    nonisolated static let audioSessionActivationRetryDelays: [Duration] = [
        .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
    ]

    /// Bad parameters, a missing entitlement or an incompatible category fail
    /// the same way every time, so only other refusals are retried.
    nonisolated static func isRetryableAudioSessionActivationError(_ error: Error) -> Bool {
        let code = (error as NSError).code
        return ![
            AVAudioSession.ErrorCode.badParam,
            .missingEntitlement,
            .incompatibleCategory,
        ].contains { $0.rawValue == code }
    }

    /// Every property the adapter observes, in registration order.
    private static let observations: [(name: String, format: String)] = [
        ("time-pos", "double"), ("duration", "double"), ("pause", "flag"),
        ("paused-for-cache", "flag"), ("seeking", "flag"), ("eof-reached", "flag"),
        ("track-list", "node"), ("chapter-list", "node"), ("aid", "string"), ("sid", "string"),
        ("secondary-sid", "string"), ("video-params", "node"), ("video-out-params", "node"),
        ("audio-out-params", "node"), ("audio-codec-name", "string"), ("hwdec-current", "string"),
        ("container-fps", "double"), ("demuxer-cache-duration", "double"),
        ("demuxer-cache-state", "node"),
        ("avsync", "double"), ("frame-drop-count", "double"),
    ]

    func load(url: URL, startPosition: Double = 0, options: LoadOptions = LoadOptions(),
              audioSourceStreamIndex: Int32? = nil) async throws {
        // A reload of the same source (audio recovery, header refresh)
        // continues the latest-playback session; a different source starts
        // a new one and replaces the previous session.
        let continuesSession = source?.url == url && PlaybackSessionRecorder.shared.isRecording
        stop(resetDisplayCriteria: false, endsSessionRecording: false)
        if continuesSession {
            PlaybackSessionRecorder.shared.reloaded()
        } else {
            PlaybackSessionRecorder.shared.end(reason: "replaced")
            PlaybackSessionRecorder.shared.begin(matchContentEnabled: options.matchContentEnabled)
        }
        let token = generation
        state = .loading
        playbackPhase = .loading
        isBuffering = true
        startupProgress = StartupProgress(checkpoint: "opening")
        source = LoadedSource(url: url, options: options, audioSourceStreamIndex: audioSourceStreamIndex)
        wantsPlay = options.autoplay
        trace = PlaybackTrialTrace()

        // Vivid presents the persistent surface before committing its source.
        for _ in 0..<100 where surface.window == nil {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == token else { throw CancellationError() }
        }
        guard let window = surface.window else {
            throw failure(PlaybackErrorInfo(kind: .softwarePipelineFailed,
                                            message: "The playback surface is unavailable."))
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try await activateAudioSession(session, token: token)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Typed apart from media failures: a refused audio session fails
            // the same way on every route, so recovery must not step down.
            let native = error as NSError
            throw failure(PlaybackErrorInfo(kind: .audioSessionUnavailable,
                                            message: "Audio output isn't available right now. Try again in a moment.",
                                            underlyingDomain: native.domain, underlyingCode: native.code))
        }
        let sessionToken = UUID()
        audioSessionToken = sessionToken
        Self.audioSessionOwner = sessionToken
        trace?.mark("mpv_audio_session_ready")

        let instance = makeCore(url: url, startPosition: startPosition, options: options,
                                audioSourceStreamIndex: audioSourceStreamIndex, session: session)
        let proxy = VividMPVDelegate(owner: self, generation: token)
        delegateProxy = proxy
        instance.delegate = proxy
        core = instance
        guard instance.initialize(in: window, hostView: surface) else {
            throw failure(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Lucid could not initialise."))
        }
        applySubtitleSettings(appearance: PlayerSettings.shared.effectiveSubtitleAppearance,
                              delayMilliseconds: PlayerSettings.shared.subtitleSyncMs)
        surface.core = instance
        surface.didLayout = { [weak self] in self?.refreshSubtitleGeometry() }
        instance.sampleBufferDisplayLayer?.videoGravity = videoGravity
        instance.setVisible(true)
        #if os(iOS)
        if !options.audioOnly, let layer = instance.sampleBufferDisplayLayer {
            softwarePiPSource = SampleBufferPiPSource(layer: layer, engine: self)
        }
        #endif
        #if VIVID_P8_TRIAL
        instance.setLogLevel("v")
        startAudioTrace(token: token)
        #else
        instance.setLogLevel("warn")
        #endif
        for observation in Self.observations {
            instance.observeProperty(observation.name, format: observation.format)
        }
        startSessionSampler(token: token)
        videoRoute = options.audioOnly ? .audio : .sampleBuffer
        trace?.event("mpv_initialised", fields: "backend=mpv compressed_sink=avplayer pcm_sink=samplebuffer")
        let layouts = instance.airPlayPCM ? "7.1,5.1,stereo" : "auto-safe"
        trace?.event("mpv_audio_policy", fields: "airplay_pcm=\(instance.airPlayPCM) layouts=\(layouts) "
            + "boost=\(audioEnhancement.boostPercent) dialogue=\(audioEnhancement.enhancedDialogue)")

        let openURL = registerManagedSource(url: url, headers: options.httpHeaders, core: instance) ?? url
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            instance.commandAsync(["loadfile", openURL.absoluteString, "replace"]) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
        try await waitUntilReady(token: token, externalSubtitles: options.externalSubtitles)
    }

    /// The load's core with every option it starts with.
    private func makeCore(url: URL, startPosition: Double, options: LoadOptions, audioSourceStreamIndex: Int32?,
                          session: AVAudioSession) -> VividMPVCore {
        let instance = VividMPVCore()
        #if os(iOS)
        instance.onEnterBackground = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.backgroundPlaybackEnabled, !self.pictureInPictureActive else { return }
                self.pause()
            }
        }
        #endif
        instance.matchContentEnabled = options.matchContentEnabled
        instance.headers = options.httpHeaders
        instance.registersManagedStreams = options.managedHTTPReader && VividManagedStreamProtocol.isEnabled
            && VividManagedStreamSource.isEligible(url)
        instance.startPosition = max(0, startPosition)
        keyframeResumePending = startPosition > 0
        // Playback keeps running through content matching. The display core
        // negotiates HDMI on its own; it must not add a startup pause.
        instance.autoplay = options.autoplay
        instance.audioOnly = options.audioOnly
        instance.initialRate = requestedRate
        instance.initialVolume = volume
        audioEnhancement = PlayerSettings.shared.audioEnhancement
        instance.audioEnhancement = audioEnhancement
        instance.audioLanguages = options.preferredAudioLanguages
        instance.plannedAudio = (audioSourceStreamIndex, options.audioTrackOrdinal)
        #if os(tvOS)
        instance.airPlayPCM = session.currentRoute.outputs.contains { $0.portType == .airPlay }
        #endif
        return instance
    }

    /// Hands the source to Vivid's own reader when the core registered it.
    /// Returns the `vividstream` URL to open, or nil to open `url` itself.
    private func registerManagedSource(url: URL, headers: [String: String], core: VividMPVCore) -> URL? {
        guard core.managedStreamsRegistered else { return nil }
        // The app's refresh hook is read when it's needed: it's installed
        // for each load epoch and may arrive after this point.
        let managed = VividManagedStreamSource(url: url, headers: headers) { [weak self] in
            await self?.refreshManagedSourceHeaders()
        }
        guard let managedURL = VividManagedStreamProtocol.add(managed) else { return nil }
        managedSource = managed
        managedSourceURL = managedURL
        trace?.event("mpv_source_reader", fields: "reader=vivid")
        return managedURL
    }

    private func refreshManagedSourceHeaders() async -> [String: String]? {
        await refreshSourceHeaders?()
    }

    /// Waits up to 60 seconds for `file-loaded`, then applies the planned
    /// audio track and adds the external subtitles.
    private func waitUntilReady(token: UInt64, externalSubtitles: [ExternalSubtitleTrack]) async throws {
        for _ in 0..<1200 {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if let errorInfo { throw errorInfo }
            if isSessionReady {
                applyInitialAudioSelection()
                for track in externalSubtitles { _ = addExternalSubtitleTrack(track) }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failure(PlaybackErrorInfo(kind: .noPlayableTrackWithinBudget,
                                        message: "Lucid did not open the source within 60 seconds."))
    }

    private func activateAudioSession(_ session: AVAudioSession, token: UInt64) async throws {
        var delays = Self.audioSessionActivationRetryDelays[...]
        while true {
            do {
                // The active route is kept across episode changes and audio-output reloads.
                if session.category != .playback || session.mode != .moviePlayback
                    || session.routeSharingPolicy != .longFormAudio {
                    try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
                }
                try session.setActive(true)
                return
            } catch {
                guard Self.isRetryableAudioSessionActivationError(error),
                      let delay = delays.popFirst() else { throw error }
                trace?.event("mpv_audio_session_retry", fields: "code=\((error as NSError).code)")
                try await Task.sleep(for: delay)
                guard generation == token else { throw CancellationError() }
            }
        }
    }
}

// MARK: - Property changes

extension VividMPVPlayer {
    fileprivate func property(_ name: String, value: Any?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "time-pos":
            guard let seconds = value as? Double, seconds.isFinite else { return }
            clock.currentTime = seconds
            updateExternalCues()
        case "duration":
            duration = value as? Double ?? 0
        case "demuxer-cache-state":
            cacheSnapshot = value as? [String: Any] ?? [:]
        case "paused-for-cache":
            isBuffering = value as? Bool ?? false
            PlaybackSessionRecorder.shared.setBuffering(isBuffering)
            trace?.event("mpv_buffering", fields: "active=\(isBuffering)")
            recordPipelineSnapshot()
            updatePhase()
        case "seeking":
            isSeeking = value as? Bool ?? false
            if isSeeking { PlaybackSessionRecorder.shared.seeked() }
            updatePhase()
        case "pause":
            wantsPlay = !(value as? Bool ?? true)
            updatePhase()
        case "eof-reached":
            observeEndOfFile(value as? Bool ?? false)
        case "track-list":
            rawTracks = value as? [[String: Any]] ?? []
            readTracks()
        case "chapter-list":
            readChapters(value as? [[String: Any]] ?? [])
        case "aid":
            activeAudioTrackIndex = sourceTrackID(mpvID: Self.trackNumber(value), type: "audio")
        case "sid":
            // An external track the overlay draws keeps its own id.
            if externalTracks[activeSubtitleTrackIndex ?? -1] == nil {
                activeSubtitleTrackIndex = sourceTrackID(mpvID: Self.trackNumber(value), type: "sub")
            }
        case "secondary-sid":
            if externalTracks[secondarySubtitleID ?? -1] == nil {
                secondarySubtitleID = sourceTrackID(mpvID: Self.trackNumber(value), type: "sub")
            }
        case "video-params":
            readVideoParams(value as? [String: Any] ?? [:])
        case "video-out-params":
            let info = value as? [String: Any] ?? [:]
            videoFormat = Self.format(info, dolbyVision: sourceDVProfile != nil && core?.hdrEnabled == true)
            let output = Self.dynamicRangeToken(videoFormat)
            PlaybackSessionRecorder.shared.updateMedia { $0.outputDynamicRange = output }
        case "audio-out-params":
            readAudioOutput(value as? [String: Any] ?? [:])
        case "audio-codec-name":
            audioDecoder = value as? String
            let codec = audioDecoder.flatMap(Self.formatToken)
            PlaybackSessionRecorder.shared.updateMedia { $0.audioCodec = codec }
        case "hwdec-current":
            let hwdec = value as? String
            videoDecoder = hwdec.map { "Lucid (\($0))" }
            let decoderToken = hwdec.flatMap(Self.formatToken)
            PlaybackSessionRecorder.shared.updateMedia { $0.hardwareDecoding = decoderToken }
        case "container-fps":
            sourceVideoFrameRate = value as? Double
            let fps = sourceVideoFrameRate
            PlaybackSessionRecorder.shared.updateMedia { $0.contentFps = fps }
        case "avsync":
            throttleAvSyncGap((value as? Double).map { $0 * 1000 })
        case "demuxer-cache-duration", "frame-drop-count":
            var stats = diagnostics.liveTelemetry ?? LiveTelemetry()
            if name == "demuxer-cache-duration" { stats.forwardBufferSeconds = value as? Double }
            if name == "frame-drop-count" { stats.droppedFrameCount = (value as? Double).map(Int.init) }
            // A held A/V sync value rides along with this update.
            if let gap = pendingAvSyncGapMs {
                stats.avSyncGapMs = gap
                pendingAvSyncGapMs = nil
            }
            diagnostics.liveTelemetry = stats
        default:
            break
        }
    }

    /// mpv reports track ids as strings, or `no` and `auto`.
    private static func trackNumber(_ value: Any?) -> Int? {
        (value as? String).flatMap(Int.init)
    }

    private func readChapters(_ chapters: [[String: Any]]) {
        mediaChapters = chapters.enumerated().map { index, chapter in
            let number = index + 1
            let name = chapter["title"] as? String
                ?? String(localized: "Chapter \(number)", comment: "Fallback name for an untitled chapter")
            return MediaChapter(id: index, name: name, startSeconds: chapter["time"] as? Double ?? 0)
        }
    }

    private func readVideoParams(_ info: [String: Any]) {
        sourceVideoWidth = Int32(clamping: info["w"] as? Int64 ?? 0)
        sourceVideoHeight = Int32(clamping: info["h"] as? Int64 ?? 0)
        sourceVideoPixelAspectRatio = info["par"] as? Double ?? 1
        if let width = info["dw"] as? Int64, let height = info["dh"] as? Int64, width > 0, height > 0 {
            sourceDisplaySize = CGSize(width: Int(width), height: Int(height))
        } else {
            sourceDisplaySize = nil
        }
        refreshSubtitleGeometry()
        sourceVideoFormat = Self.format(info, dolbyVision: sourceDVProfile != nil)
        recordSourceVideo()
    }

    private func readAudioOutput(_ info: [String: Any]) {
        outputChannels = (info["channel-count"] as? Int64).map(Int.init)
        outputAudioFormat = info["format"] as? String
        let (format, channels) = (outputAudioFormat, outputChannels)
        PlaybackSessionRecorder.shared.updateMedia {
            $0.audioOutputFormat = format.flatMap(Self.formatToken)
            $0.audioOutputChannels = channels
            $0.audioPassthrough = format.map { $0.hasPrefix("spdif") }
        }
        PlaybackSessionRecorder.shared.refreshAudioRoute()
        trace?.event("mpv_audio_output", fields: "format=\(outputAudioFormat ?? "unknown") "
            + "channels=\(outputChannels ?? 0) apple_mode=\(Self.appleRenderingMode)")
    }

    private static func format(_ info: [String: Any], dolbyVision: Bool) -> VideoFormat {
        if dolbyVision { return .dolbyVision }
        switch info["gamma"] as? String {
        case "pq", "smpte2084": return .hdr10
        case "hlg", "arib-std-b67": return .hlg
        default: return .sdr
        }
    }

    private func throttleAvSyncGap(_ gap: Double?) {
        pendingAvSyncGapMs = .some(gap)
        let wait = lastAvSyncPublishUptime + Self.avSyncPublishInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else {
            publishPendingAvSyncGap()
            return
        }
        guard avSyncPublishTask == nil else { return }
        let token = generation
        avSyncPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, token == generation else { return }
            avSyncPublishTask = nil
            publishPendingAvSyncGap()
        }
    }

    private func publishPendingAvSyncGap() {
        avSyncPublishTask?.cancel()
        avSyncPublishTask = nil
        guard let gap = pendingAvSyncGapMs else { return }
        pendingAvSyncGapMs = nil
        lastAvSyncPublishUptime = ProcessInfo.processInfo.systemUptime
        PlaybackSessionRecorder.shared.avSync(ms: gap)
        var stats = diagnostics.liveTelemetry ?? LiveTelemetry()
        stats.avSyncGapMs = gap
        diagnostics.liveTelemetry = stats
    }
}

// MARK: - Events

extension VividMPVPlayer {
    fileprivate func event(_ name: String, data: [String: Any]?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "display-commit-lock":
            guard let transition = data?["transition"] as? String, ["start_file", "end_file"].contains(transition),
                  let wait = data?["wait_ms"] as? Double, wait.isFinite, wait >= 0,
                  let held = data?["held_ms"] as? Double, held.isFinite, held >= 0 else { return }
            trace?.event("mpv_display_commit_lock", fields: "transition=\(transition) wait_ms=\(wait) held_ms=\(held)")
        case "display-criteria-prepared":
            trace?.mark("mpv_display_criteria_prepared")
        case "display-switch-started":
            PlaybackSessionRecorder.shared.settling()
            trace?.event("mpv_display_switch_started")
            recordPipelineSnapshot()
        case "display-switch-ended":
            PlaybackSessionRecorder.shared.displaySwitched()
            trace?.event("mpv_display_switch_ended")
            recordPipelineSnapshot()
        case "file-loaded":
            isSessionReady = true
            startupProgress = nil
            applyInitialAudioSelection()
            updatePhase()
            trace?.mark("mpv_file_loaded")
        case "playback-restart":
            if keyframeResumePending {
                // Later seeks without an explicit precision are exact again.
                keyframeResumePending = false
                core?.setProperty("hr-seek", value: "default")
            }
            hasFirstFrameReadyForDisplay = true
            isSeeking = false
            isBuffering = false
            updatePhase()
            trace?.mark("mpv_playback_restart")
            trace?.seekPicture()
        case "end-file":
            handleEndFile(data)
        case "log-message":
            recordLogMessage(data)
        default:
            break
        }
    }

    private func recordLogMessage(_ data: [String: Any]?) {
        guard let fields = LucidLogDiagnostics.fields(from: data) else { return }
        if fields.hasPrefix("fault=") {
            PlaybackSessionRecorder.shared.audioFault(String(fields.dropFirst("fault=".count)))
        }
        trace?.event("mpv_audio_diagnostic", fields: fields)
        let snapshotEvents = ["raw_s=", "event=audio_transport ", "event=pcm_transport ", "event=audio_edge "]
        if snapshotEvents.contains(where: { fields.hasPrefix($0) }) {
            recordPipelineSnapshot()
        }
    }

    private func handleEndFile(_ data: [String: Any]?) {
        if let code = data?["error"] as? Int {
            fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Lucid playback failed (\(code))."))
        } else if data?["reason"] as? Int == 0 {
            observeEndOfFile(true)
        } else {
            cancelEndConfirmation()
        }
    }

    private func cancelEndConfirmation() {
        endConfirmationTask?.cancel()
        endConfirmationTask = nil
    }

    private func observeEndOfFile(_ reached: Bool) {
        guard reached else {
            cancelEndConfirmation()
            updatePhase()
            return
        }
        // The playhead stops at the end, and keep-open holds the last frame
        // under Next Up; neither is playback for the latest-playback record.
        PlaybackSessionRecorder.shared.setPlaying(false)
        guard errorInfo == nil, state != .ended, endConfirmationTask == nil else { return }
        let token = generation
        let seekToken = seekGeneration
        // keep-open keeps the source for rewinding from Next Up. Its EOF
        // property can arrive before end-file(error), so queued errors win.
        endConfirmationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, generation == token,
                  seekGeneration == seekToken, errorInfo == nil else { return }
            endConfirmationTask = nil
            guard isSessionReady, hasFirstFrameReadyForDisplay else {
                fail(PlaybackErrorInfo(kind: .softwarePipelineFailed,
                                       message: "The media stream ended before playback started."))
                return
            }
            isSeeking = false
            isBuffering = false
            playbackPhase = .ended
            state = .ended
        }
    }

    /// Trace fields for the playback pipeline: position, state, A/V sync and
    /// mpv's numeric cache fields, overall and for each stream.
    private func recordPipelineSnapshot() {
        guard trace != nil else { return }
        var fields = ["position_s=\(currentTime)", "playing=\(wantsPlay)", "buffering=\(isBuffering)",
                      "seeking=\(isSeeking)"]
        if let gap = pendingAvSyncGapMs ?? diagnostics.liveTelemetry?.avSyncGapMs, gap.isFinite {
            fields.append("avsync_ms=\(gap)")
        }
        let cacheKeys = ["fw-bytes", "total-bytes", "raw-input-rate", "reader-pts", "cache-end", "cache-duration",
                         "eof", "underrun", "idle"]
        for key in cacheKeys {
            if let number = cacheSnapshot[key] as? NSNumber, number.doubleValue.isFinite {
                fields.append("\(key)=\(number)")
            }
        }
        for stream in cacheSnapshot["ts-per-stream"] as? [[String: Any]] ?? [] {
            guard let type = stream["type"] as? String, ["audio", "video", "sub"].contains(type) else { continue }
            for key in ["reader-pts", "cache-end", "cache-duration"] {
                if let number = stream[key] as? NSNumber, number.doubleValue.isFinite {
                    fields.append("\(type)_\(key)=\(number)")
                }
            }
        }
        trace?.event("mpv_pipeline", fields: fields.joined(separator: " "))
    }

    #if VIVID_P8_TRIAL
    /// Trial builds trace the pipeline and the audio route every 2 seconds.
    private func startAudioTrace(token: UInt64) {
        audioTraceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, generation == token else { return }
                recordPipelineSnapshot()
                recordAudioRoute()
            }
        }
    }

    private func recordAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        let airPlay = session.currentRoute.outputs.contains { $0.portType == .airPlay }
        let hdmi = session.currentRoute.outputs.contains { $0.portType == .HDMI }
        trace?.event("mpv_audio_route", fields:
            "airplay=\(airPlay) hdmi=\(hdmi) session_channels=\(session.outputNumberOfChannels) "
            + "sample_rate=\(session.sampleRate) latency_s=\(session.outputLatency) io_buffer_s=\(session.ioBufferDuration) "
            + "player_channels=\(outputChannels ?? 0) apple_mode=\(Self.appleRenderingMode)")
    }
    #endif
}

// MARK: - Transport

extension VividMPVPlayer {
    func play() {
        wantsPlay = true
        core?.setProperty("pause", value: "no")
        updatePhase()
    }

    func pause() {
        wantsPlay = false
        core?.setProperty("pause", value: "yes")
        updatePhase()
    }

    func setRate(_ rate: Float) {
        PlaybackSessionRecorder.shared.settling()
        guard rate.isFinite, rate > 0 else { return }
        trace?.event("mpv_rate_requested", fields: "rate=\(rate) previous=\(requestedRate)")
        // Crossing 1x on an AC-3 or E-AC-3 track swaps compressed output for
        // PCM, or back, which replaces the audio output. With Volume Boost or
        // Enhanced Dialogue on, those tracks are decoded at every speed.
        let codec = audioTracks.first { $0.id == activeAudioTrackIndex }?.codec ?? ""
        let swapsAudioOutput = (rate == 1) != (requestedRate == 1) && ["ac3", "eac3"].contains(codec)
            && !audioEnhancement.isActive
        requestedRate = rate
        guard let core else { return }
        let token = generation
        let previous = rateTask
        let spdif = VividMPVAudio.spdifCodecs(rate: rate, enhancement: audioEnhancement)
        // Compressed packets can't pass through a tempo filter, so passthrough
        // ends before the speed leaves 1x and starts again after it returns.
        let changes = rate == 1
            ? [("speed", String(rate)), ("audio-spdif", spdif)]
            : [("audio-spdif", spdif), ("speed", String(rate))]
        rateTask = Task { @MainActor [weak self, weak core] in
            await previous?.value
            guard let self, let core, generation == token, !Task.isCancelled else { return }
            do {
                for (name, value) in changes {
                    guard generation == token, !Task.isCancelled else { return }
                    if name == "audio-spdif", swapsAudioOutput {
                        // Otherwise mpv plays out the old output's queue (about seven
                        // seconds over AirPlay) with the picture held, then shows the
                        // picture silent until it reaches the audio. Seeking in place
                        // drops that queue and restarts both together. The seek is
                        // queued just before the option so mpv takes both before
                        // decoding again.
                        core.command(["seek", "0", "relative+exact"])
                    }
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        core.setPropertyAsync(name, value: value) { continuation.resume(with: $0) }
                    }
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Lucid could not change playback speed."))
            }
        }
    }

    /// Seeks exactly, within the duration once it's known, and fails playback
    /// if the seek hasn't finished after 15 seconds.
    func seek(to seconds: Double) async {
        guard let core, seconds.isFinite else { return }
        cancelEndConfirmation()
        let token = generation
        seekGeneration &+= 1
        let seekToken = seekGeneration
        isSeeking = true
        state = .seeking
        updatePhase()
        trace?.beginSeek(target: seconds)
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        core.command(["seek", String(target), "absolute+exact"])
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled || token != generation || seekToken != seekGeneration || !isSeeking || errorInfo != nil {
                return
            }
        }
        fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "The Lucid seek did not complete."))
    }

    func prepareForItemReplacement() {
        pause()
        hasFirstFrameReadyForDisplay = false
    }

    private func updatePhase() {
        // The latest-playback session counts only time with video actually
        // on screen, so opening the file is never mistaken for playback.
        PlaybackSessionRecorder.shared.setPlaying(isSessionReady && hasFirstFrameReadyForDisplay && wantsPlay
            && !isSeeking && !isBuffering && errorInfo == nil && state != .ended && endConfirmationTask == nil)
        // A seek the viewer is waiting on counts as loading, not as a pause.
        PlaybackSessionRecorder.shared.setSeeking(isSessionReady && wantsPlay && isSeeking
            && errorInfo == nil && state != .ended)
        guard isSessionReady, errorInfo == nil, state != .ended else { return }
        if isSeeking {
            state = .seeking
            playbackPhase = .seeking
        } else if !wantsPlay {
            state = .paused
            playbackPhase = .paused
        } else if isBuffering {
            playbackPhase = .rebuffering
        } else {
            state = .playing
            playbackPhase = .playing
        }
    }

    private func fail(_ error: PlaybackErrorInfo) {
        cancelEndConfirmation()
        core?.setProperty("pause", value: "yes")
        errorInfo = error
        state = .error(error.message)
        playbackPhase = .error(error.message)
        PlaybackSessionRecorder.shared.end(reason: "failed_\(error.kind.rawValue)")
        isBuffering = false
        isSeeking = false
        trace?.event("mpv_failed", fields: "kind=\(error.kind.rawValue)")
    }

    /// Fails the load and returns the error for the caller to throw.
    private func failure(_ error: PlaybackErrorInfo) -> PlaybackErrorInfo {
        fail(error)
        return error
    }
}

// MARK: - Tracks

extension VividMPVPlayer {
    /// A track as the player lists it. Its id is the source stream index
    /// when mpv knows it, otherwise mpv's own id.
    nonisolated static func trackInfo(_ info: [String: Any]) -> TrackInfo {
        TrackInfo(id: Int(info["ff-index"] as? Int64 ?? info["id"] as? Int64 ?? 0),
                  name: info["title"] as? String ?? "",
                  codec: info["codec"] as? String ?? "",
                  language: info["lang"] as? String,
                  channels: Int(info["demux-channel-count"] as? Int64 ?? 0),
                  isDefault: info["default"] as? Bool ?? false,
                  isForced: info["forced"] as? Bool ?? false,
                  isHearingImpaired: info["hearing-impaired"] as? Bool ?? false,
                  isExternal: info["external"] as? Bool ?? false,
                  isNativelyRenderedSubtitle: true,
                  sourceStreamIndex: (info["ff-index"] as? Int64).map(Int.init))
    }

    private func readTracks() {
        audioTracks = rawTracks.filter { $0["type"] as? String == "audio" }.map(Self.trackInfo)
        subtitleTracks = rawTracks.filter { $0["type"] as? String == "sub" && $0["external"] as? Bool != true }
            .map(Self.trackInfo)
        subtitleTracks += externalTracks.sorted { $0.key < $1.key }.map { id, track in
            let drawnByLucid = nativeExternalFiles[id] != nil
            return TrackInfo(id: id, name: track.name ?? String(localized: "External subtitles"),
                             codec: drawnByLucid ? "ass" : "", language: track.language, isForced: track.isForced,
                             isExternal: true, isNativelyRenderedSubtitle: drawnByLucid)
        }
        videoTrack = rawTracks.first { $0["type"] as? String == "video" } ?? [:]
        sourceDVProfile = (videoTrack["dolby-vision-profile"] as? Int64).flatMap { $0 > 0 ? Int($0) : nil }
        if sourceDVProfile != nil { sourceVideoFormat = .dolbyVision }
        recordSourceVideo()
        if let selected = rawTracks.first(where: { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }) {
            activeAudioTrackIndex = sourceTrackID(mpvID: (selected["id"] as? Int64).map(Int.init), type: "audio")
        }
        applyInitialAudioSelection()
        // A file Lucid draws gets a new mpv id once it's added, so it's selected again.
        let drawnByLucid = { (id: Int) in
            self.nativeExternalFiles[id] != nil || (self.pictureInPictureActive && self.pictureInPictureFiles[id] != nil)
        }
        if let id = activeSubtitleTrackIndex, drawnByLucid(id) { selectSubtitleTrack(index: id) }
        if let id = secondarySubtitleID, drawnByLucid(id) { selectSecondarySubtitleTrack(index: id) }
    }

    private func sourceTrackID(mpvID: Int?, type: String) -> Int? {
        guard let mpvID,
              let track = rawTracks.first(where: { $0["type"] as? String == type && $0["id"] as? Int64 == Int64(mpvID) })
        else { return nil }
        return Int(track["ff-index"] as? Int64 ?? Int64(mpvID))
    }

    private func mpvTrackID(sourceID: Int, type: String) -> Int? {
        guard let track = rawTracks.first(where: {
            $0["type"] as? String == type && Int($0["ff-index"] as? Int64 ?? $0["id"] as? Int64 ?? -1) == sourceID
        }) else { return nil }
        return (track["id"] as? Int64).map(Int.init)
    }

    /// The mpv id of the audio track the plan chose (usually the one this
    /// device can play or pass through): by source stream index when known,
    /// otherwise by position among the file's audio tracks. The core selects
    /// it before mpv starts; `applyInitialAudioSelection` makes the same
    /// choice after load, where it's then already selected.
    nonisolated static func plannedAudioTrackID(in tracks: [[String: Any]], streamIndex: Int32?, ordinal: Int?) -> Int64? {
        let audio = tracks.filter { $0["type"] as? String == "audio" }
        if let streamIndex {
            return audio.first { $0["ff-index"] as? Int64 == Int64(streamIndex) }?["id"] as? Int64
        }
        guard let ordinal, audio.indices.contains(ordinal) else { return nil }
        return audio[ordinal]["id"] as? Int64
    }

    /// Selects the planned audio track once per load, after `file-loaded`.
    private func applyInitialAudioSelection() {
        guard isSessionReady, !initialAudioApplied, !audioTracks.isEmpty, let source else { return }
        if let streamIndex = source.audioSourceStreamIndex {
            // Waits for a track list that has the planned stream.
            guard let track = rawTracks.first(where: {
                $0["type"] as? String == "audio" && $0["ff-index"] as? Int64 == Int64(streamIndex)
            }), track["id"] as? Int64 != nil else { return }
            selectAudioTrack(index: Int(streamIndex))
        } else if let ordinal = source.options.audioTrackOrdinal, audioTracks.indices.contains(ordinal) {
            selectAudioTrack(index: audioTracks[ordinal].id)
        }
        initialAudioApplied = true
    }

    func selectAudioTrack(index: Int) {
        guard let id = mpvTrackID(sourceID: index, type: "audio") else { return }
        PlaybackSessionRecorder.shared.settling()
        core?.setProperty("aid", value: String(id))
    }
}

// MARK: - Subtitles

extension VividMPVPlayer {
    func applySubtitleSettings(appearance: SubtitleAppearance, delayMilliseconds: Int,
                               secondaryDelayMilliseconds: Int? = nil) {
        subtitleDelaySeconds = Double(delayMilliseconds) / 1000
        secondarySubtitleDelaySeconds = Double(secondaryDelayMilliseconds ?? delayMilliseconds) / 1000
        subtitleAppearance = appearance
        subtitleGeometry = currentSubtitleGeometry
        subtitleStyleOptions = LucidSubtitleStyle.options(appearance, geometry: subtitleGeometry)
        for (name, value) in subtitleStyleOptions {
            core?.setProperty(name, value: value)
        }
        core?.setProperty("sub-delay", value: lucidDelay(subtitleDelaySeconds, track: activeSubtitleTrackIndex))
        core?.setProperty("secondary-sub-delay",
                          value: lucidDelay(secondarySubtitleDelaySeconds, track: secondarySubtitleID))
        updateExternalCues()
    }

    func selectSubtitleTrack(index: Int) {
        activeSubtitleTrackIndex = index
        addPictureInPictureCopy(index)
        core?.setProperty("sid", value: subtitleMPVID(index).map(String.init) ?? "no")
        core?.setProperty("sub-delay", value: lucidDelay(subtitleDelaySeconds, track: index))
        updateExternalCues()
    }

    func selectSecondarySubtitleTrack(index: Int) {
        secondarySubtitleID = index
        addPictureInPictureCopy(index)
        core?.setProperty("secondary-sid", value: subtitleMPVID(index).map(String.init) ?? "no")
        core?.setProperty("secondary-sub-delay", value: lucidDelay(secondarySubtitleDelaySeconds, track: index))
        updateExternalCues()
    }

    func clearSubtitle() {
        activeSubtitleTrackIndex = nil
        core?.setProperty("sid", value: "no")
        updateExternalCues()
    }

    func clearSecondarySubtitle() {
        secondarySubtitleID = nil
        core?.setProperty("secondary-sid", value: "no")
        updateExternalCues()
    }

    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = externalTracks.first { $0.value == track }?.key ?? nextExternalID
        if externalTracks[id] == nil {
            nextExternalID += 1
            externalTracks[id] = track
            readTracks()
            isLoadingSubtitles = true
            subtitleTasks[id] = loadExternalSubtitle(track, id: id, token: generation)
        }
        // readTracks lists every external track, so this one is always there.
        return subtitleTracks.first { $0.id == id }!
    }

    /// Text files become cues the overlay draws; ASS files are given to Lucid.
    private func loadExternalSubtitle(_ track: ExternalSubtitleTrack, id: Int, token: UInt64) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            var pendingNativeFile: URL?
            defer {
                if let pendingNativeFile { try? FileManager.default.removeItem(at: pendingNativeFile) }
            }
            do {
                let text = try await VividSubtitleLoader.text(of: track)
                guard let self, generation == token, !Task.isCancelled else { return }
                switch VividSubtitleLoader.document(text, track: track) {
                case .cues(let cues):
                    externalCues[id] = VividSubtitleCueCursor(cues)
                    #if os(iOS)
                    pictureInPictureTexts[id] = text
                    if id == activeSubtitleTrackIndex || id == secondarySubtitleID { addPictureInPictureCopy(id) }
                    #endif
                case .ass(let text):
                    let file = Self.temporarySubtitleFile(extension: "ass")
                    try text.write(to: file, atomically: true, encoding: .utf8)
                    pendingNativeFile = file
                    guard let core else { throw CancellationError() }
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        core.commandAsync(["sub-add", file.path, "auto"]) { result in
                            continuation.resume(with: result.map { _ in () })
                        }
                    }
                    guard generation == token, !Task.isCancelled else { return }
                    nativeExternalFiles[id] = file
                    pendingNativeFile = nil
                    readTracks()
                }
                updateExternalCues()
            } catch {
                guard let self, generation == token else { return }
                trace?.event("mpv_external_subtitle_failed")
            }
            guard let self, generation == token else { return }
            subtitleTasks[id] = nil
            isLoadingSubtitles = !subtitleTasks.isEmpty
        }
    }

    private static func temporarySubtitleFile(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vivid-subtitle-" + UUID().uuidString)
            .appendingPathExtension(pathExtension)
    }

    /// Lucid's delay for a track: the setting, less the offset an external
    /// file's timeline is known to have.
    private func lucidDelay(_ seconds: Double, track id: Int?) -> String {
        String(seconds - (externalTracks[id ?? -1]?.nativeTimelineOffsetSeconds ?? 0))
    }

    /// The mpv id to select for a track: the file Lucid draws for an external
    /// track (its Picture in Picture copy only while that runs), nothing for an
    /// external track the overlay draws, otherwise the embedded track.
    private func subtitleMPVID(_ id: Int) -> Int? {
        if let file = nativeExternalFiles[id] ?? (pictureInPictureActive ? pictureInPictureFiles[id] : nil) {
            return rawTracks.first {
                $0["type"] as? String == "sub" && $0["external-filename"] as? String == file.path
            }.flatMap { ($0["id"] as? Int64).map(Int.init) }
        }
        return externalTracks[id] == nil ? mpvTrackID(sourceID: id, type: "sub") : nil
    }

    /// Gives Lucid a copy of a chosen text file the overlay draws, without
    /// selecting it, so libass can draw it into Picture in Picture. Only
    /// chosen files, so a title with many server subtitle files doesn't open
    /// them all. The text is kept until the copy is added, so a failed copy
    /// is tried again the next time the file is chosen.
    private func addPictureInPictureCopy(_ id: Int) {
        #if os(iOS)
        guard let core, !core.audioOnly, let text = pictureInPictureTexts[id], let track = externalTracks[id],
              pictureInPictureCopying.insert(id).inserted else { return }
        let hint = track.formatHint?.lowercased() ?? track.url.pathExtension.lowercased()
        let file = Self.temporarySubtitleFile(extension: ["vtt", "webvtt"].contains(hint) ? "vtt" : "srt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else {
            pictureInPictureCopying.remove(id)
            trace?.event("mpv_pip_subtitle_copy_failed")
            return
        }
        let token = generation
        core.commandAsync(["sub-add", file.path, "auto"]) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == token else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                pictureInPictureCopying.remove(id)
                guard case .success = result else {
                    try? FileManager.default.removeItem(at: file)
                    trace?.event("mpv_pip_subtitle_copy_failed")
                    return
                }
                pictureInPictureTexts[id] = nil
                pictureInPictureFiles[id] = file
                readTracks()
            }
        }
        #endif
    }

    /// Publishes the cues the overlay draws, only when they change.
    private func updateExternalCues() {
        let primary = externalCues[activeSubtitleTrackIndex ?? -1]?
            .selection(at: currentTime - subtitleDelaySeconds) ?? .empty
        let primaryPublication = CuePublication(
            trackID: primary.offsets.isEmpty ? nil : activeSubtitleTrackIndex, offsets: primary.offsets)
        if primaryPublication != primaryCuePublication {
            primaryCuePublication = primaryPublication
            subtitleCues = primary.cues
        }
        let secondary = externalCues[secondarySubtitleID ?? -1]?
            .selection(at: currentTime - secondarySubtitleDelaySeconds) ?? .empty
        let secondaryPublication = CuePublication(
            trackID: secondary.offsets.isEmpty ? nil : secondarySubtitleID, offsets: secondary.offsets)
        if secondaryPublication != secondaryCuePublication {
            secondaryCuePublication = secondaryPublication
            secondarySubtitleCues = secondary.cues
        }
    }

    /// The shown video, which libass sizes and places subtitles against.
    private var currentSubtitleGeometry: LucidSubtitleStyle.Geometry? {
        guard let layer = core?.sampleBufferDisplayLayer else { return nil }
        return LucidSubtitleStyle.Geometry(layer: layer.bounds.size, picture: softwareDisplaySize)
    }

    /// Sends the style keys a new video size or shape changes. The overlay's
    /// minimum sizes are points on screen, so on a small picture the same
    /// appearance needs larger values.
    private func refreshSubtitleGeometry() {
        guard let appearance = subtitleAppearance else { return }
        let geometry = currentSubtitleGeometry
        guard geometry != subtitleGeometry else { return }
        subtitleGeometry = geometry
        let options = LucidSubtitleStyle.options(appearance, geometry: geometry)
        for (name, value) in options where subtitleStyleOptions[name] != value {
            core?.setProperty(name, value: value)
        }
        subtitleStyleOptions = options
    }

    #if DEBUG
    /// Exercises the same clock event as the media core without opening a source.
    func debugReceivePlaybackTime(_ seconds: Double) {
        property("time-pos", value: seconds, token: generation)
    }

    /// Delivers a media-core property change to the current load, as the
    /// core's delegate does, without opening a source.
    func debugReceiveProperty(_ name: String, value: Any?) {
        property(name, value: value, token: generation)
    }

    /// Delivers a media-core event to the current load, as the core's
    /// delegate does, without opening a source.
    func debugReceiveEvent(_ name: String, data: [String: Any]? = nil) {
        event(name, data: data, token: generation)
    }
    #endif
}

// MARK: - Headers, reloads and stopping

extension VividMPVPlayer {
    /// Only a Vivid-read source can take new headers live; Lucid's own HTTP
    /// reader keeps the headers it opened with.
    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool {
        guard let managedSource, managedSource.url == url else { return false }
        managedSource.update(headers)
        return true
    }

    func reloadAtCurrentPosition() async throws {
        guard let source else { return }
        var options = source.options
        options.autoplay = wantsPlay
        if let fresh = await refreshSourceHeaders?() { options.httpHeaders = fresh }
        try await load(url: source.url, startPosition: currentTime, options: options,
                       audioSourceStreamIndex: source.audioSourceStreamIndex)
    }

    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        stop(resetDisplayCriteria: resetDisplayCriteria, endsSessionRecording: true)
    }

    private func stop(resetDisplayCriteria: Bool, endsSessionRecording: Bool) {
        if endsSessionRecording {
            PlaybackSessionRecorder.shared.end(reason: state == .ended ? "ended" : "stopped")
        }
        sessionSampler?.cancel()
        sessionSampler = nil
        generation &+= 1
        #if VIVID_P8_TRIAL
        audioTraceTask?.cancel()
        audioTraceTask = nil
        #endif
        cancelEndConfirmation()
        rateTask?.cancel()
        rateTask = nil
        softwarePiPSource = nil
        // Unblock any reader before Lucid tears down, which may be synchronous.
        managedSource?.cancel()
        retireCore(resetDisplayCriteria: resetDisplayCriteria)
        core = nil
        delegateProxy = nil
        surface.core = nil
        source = nil
        VividManagedStreamProtocol.remove(managedSourceURL)
        managedSource = nil
        managedSourceURL = nil
        trace?.event("mpv_stopped")
        trace = nil
        resetLoadState()
    }

    /// Disposes the core and, on a final stop, releases the shared audio
    /// session once every retired core, from any player, has finished.
    private func retireCore(resetDisplayCriteria: Bool) {
        core?.delegate = nil
        if let core {
            let teardown = Self.audioTeardown
            teardown.enter()
            core.dispose(preserveDisplayCriteria: !resetDisplayCriteria) { teardown.leave() }
        }
        guard deactivatesAudioSessionOnStop, let sessionToRelease = audioSessionToken else { return }
        audioSessionToken = nil
        Self.audioTeardown.notify(queue: .main) {
            MainActor.assumeIsolated {
                // Never release a newer load's session, including another player's.
                guard Self.audioSessionOwner == sessionToRelease else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                Self.audioSessionOwner = nil
            }
        }
    }

    private func resetLoadState() {
        state = .idle
        playbackPhase = .idle
        videoRoute = .none
        isSessionReady = false
        isSeeking = false
        isBuffering = false
        hasFirstFrameReadyForDisplay = false
        errorInfo = nil
        startupProgress = nil
        clock.currentTime = 0
        duration = 0
        audioTracks = []
        subtitleTracks = []
        mediaChapters = []
        initialAudioApplied = false
        for file in nativeExternalFiles.values { try? FileManager.default.removeItem(at: file) }
        for file in pictureInPictureFiles.values { try? FileManager.default.removeItem(at: file) }
        nativeExternalFiles = [:]
        pictureInPictureFiles = [:]
        pictureInPictureTexts = [:]
        pictureInPictureCopying = []
        rawTracks = []
        videoTrack = [:]
        externalTracks = [:]
        externalCues = [:]
        for task in subtitleTasks.values { task.cancel() }
        subtitleTasks = [:]
        isLoadingSubtitles = false
        activeAudioTrackIndex = nil
        activeSubtitleTrackIndex = nil
        secondarySubtitleID = nil
        updateExternalCues()
        sourceVideoWidth = 0
        sourceVideoHeight = 0
        sourceVideoBitrate = 0
        sourceVideoFrameRate = nil
        sourceVideoPixelAspectRatio = 1
        sourceDisplaySize = nil
        sourceDVProfile = nil
        sourceVideoFormat = .sdr
        videoFormat = .sdr
        outputChannels = nil
        outputAudioFormat = nil
        videoDecoder = nil
        audioDecoder = nil
        diagnostics.liveTelemetry = nil
        avSyncPublishTask?.cancel()
        avSyncPublishTask = nil
        pendingAvSyncGapMs = nil
        lastAvSyncPublishUptime = 0
        cacheSnapshot = [:]
    }

    func setNativeSubtitleRendering(_ active: Bool) {}

    func updateNativeMetadata(title: String, artwork: MPMediaItemArtwork?) {}

    func makeFrameExtractor(url: URL, httpHeaders: [String: String]) -> FrameExtractor? {
        #if os(iOS)
        return FrameExtractor(url: url, headers: httpHeaders)
        #else
        return nil
        #endif
    }
}

// MARK: - Latest playback report

extension VividMPVPlayer {
    /// Reads two cumulative frame counters once a second, and bitrate and
    /// display rate every 10 seconds, off the render path, for the
    /// latest-playback report. Properties the output doesn't support come
    /// back as nil and are reported as not measured.
    private func startSessionSampler(token: UInt64) {
        sessionSampler?.cancel()
        guard PlaybackSessionRecorder.isEnabled else { return }
        sessionSampler = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, generation == token, let core = self.core else { return }
                let slow = tick % 10 == 0
                tick &+= 1
                async let decoder = Self.readNumber(core, "decoder-frame-drop-count")
                async let delayed = Self.readNumber(core, "vo-delayed-frame-count")
                async let bitrate: Double? = slow ? await Self.readNumber(core, "video-bitrate") : nil
                async let displayFps: Double? = slow ? await Self.readNumber(core, "display-fps") : nil
                let values = await (decoder: decoder, delayed: delayed, bitrate: bitrate, displayFps: displayFps)
                guard !Task.isCancelled, generation == token else { return }
                if let bitrate = values.bitrate, bitrate > 0 {
                    PlaybackSessionRecorder.shared.updateMedia { $0.videoBitrateKbps = Int(bitrate / 1000) }
                }
                let inputRate = (cacheSnapshot["raw-input-rate"] as? NSNumber)?.doubleValue
                PlaybackSessionRecorder.shared.sample(
                    dropped: diagnostics.liveTelemetry?.droppedFrameCount,
                    decoderDropped: values.decoder.map(Int.init),
                    delayed: values.delayed.map(Int.init),
                    networkKbps: inputRate.flatMap { $0 > 0 && $0.isFinite ? Int($0 * 8 / 1000) : nil },
                    displayFps: values.displayFps,
                    position: currentTime)
            }
        }
    }

    /// A finite, non-negative number, or nil.
    private static func readNumber(_ core: VividMPVCore, _ name: String) async -> Double? {
        await withCheckedContinuation { continuation in
            core.getPropertyAsync(name) { result in
                let value = (try? result.get()).flatMap { $0 }.flatMap(Double.init)
                continuation.resume(returning: value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
            }
        }
    }

    private func recordSourceVideo() {
        let codec = (videoTrack["codec"] as? String).flatMap(Self.formatToken)
        let (width, height) = (Int(sourceVideoWidth), Int(sourceVideoHeight))
        let range = Self.dynamicRangeToken(sourceVideoFormat)
        let profile = sourceDVProfile
        let selectedAudio = rawTracks.first { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }
        let audioChannels = (selectedAudio?["demux-channel-count"] as? Int64).map(Int.init)
        PlaybackSessionRecorder.shared.updateMedia {
            if let codec { $0.videoCodec = codec }
            if width > 0, height > 0 {
                $0.width = width
                $0.height = height
            }
            $0.sourceDynamicRange = range
            $0.dolbyVisionProfile = profile
            if let audioChannels, audioChannels > 0 { $0.audioSourceChannels = audioChannels }
        }
    }

    private static func dynamicRangeToken(_ format: VideoFormat) -> String {
        switch format {
        case .dolbyVision: "dolby_vision"
        case .hdr10: "hdr10"
        case .hdr10Plus: "hdr10_plus"
        case .hlg: "hlg"
        case .sdr: "sdr"
        }
    }

    /// Codec and format names from mpv are short identifiers. Anything else,
    /// including dotted values that could be an address or hostname, is
    /// dropped so free text can never reach a report.
    nonisolated static func formatToken(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 24, trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed.lowercased()
    }
}

// MARK: - The load's core

/// The bridge's core with the options one load starts with.
private final class VividMPVCore: VividPlayerCore {
    var headers: [String: String] = [:]
    var registersManagedStreams = false
    private(set) var managedStreamsRegistered = false
    var startPosition: Double = 0
    var autoplay = true
    var audioOnly = false
    var initialRate: Float = 1
    var initialVolume: Float = 1
    var audioEnhancement = VividAudioEnhancement.off
    var audioLanguages: [String] = []
    var plannedAudio: (streamIndex: Int32?, ordinal: Int?) = (nil, nil)
    var airPlayPCM = false

    override var selectsAudioWhilePreloading: Bool {
        plannedAudio.streamIndex != nil || plannedAudio.ordinal != nil
    }

    override func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64? {
        VividMPVPlayer.plannedAudioTrackID(in: tracks, streamIndex: plannedAudio.streamIndex,
                                           ordinal: plannedAudio.ordinal)
    }

    /// The options every load sets, each reported by name if Lucid refuses it.
    private var loadOptions: [(name: String, value: String)] {
        [("ao", "avfoundation"),
         ("audio-spdif", VividMPVAudio.spdifCodecs(rate: initialRate, enhancement: audioEnhancement)),
         ("ao-avfoundation-manage-audio-session", "no"),
         ("audio-exclusive", "yes"),
         ("audio-channels", airPlayPCM ? "7.1,5.1,stereo" : "auto-safe"),
         ("config", "no"),
         ("load-scripts", "no"),
         ("input-default-bindings", "no"),
         ("input-vo-keyboard", "no"),
         ("osd-level", "0"),
         ("pause", autoplay ? "no" : "yes"),
         ("start", String(startPosition)),
         ("speed", String(initialRate)),
         // A resume starts on the keyframe at or before the saved position.
         // An exact resume first downloads and decodes everything from that
         // keyframe up to the position, about 5 MB for a 4K remux, before the
         // first picture. Vivid's own seeks ask for exact positions.
         ("hr-seek", startPosition > 0 ? "no" : "default"),
         ("volume", String(initialVolume * 100)),
         ("sid", "no"),
         ("secondary-sid", "no"),
         ("cache", "yes"),
         ("demuxer-max-bytes", "268435456"),
         ("demuxer-max-back-bytes", "16777216"),
         ("alang", audioLanguages.joined(separator: ",")),
         ("terminal", "no")]
    }

    override func configurePlatformMpvOptions(mpv: OpaquePointer) {
        for option in loadOptions {
            checkError(mpv_set_option_string(mpv, option.name, option.value), option: option.name)
        }
        for (name, value) in VividMPVAudio.enhancementOptions(audioEnhancement) {
            checkError(mpv_set_option_string(mpv, name, value), option: name)
        }
        // Checks HTTPS certificates when the linked FFmpeg uses Secure Transport.
        // An FFmpeg built with OpenSSL has no trust store on Apple platforms.
        checkError(LucidTLS.apply(to: mpv), option: "tls-verify")
        #if os(tvOS)
        // Reads at most a minute ahead. On a fast link the 256 MiB packet cache
        // otherwise fills over a long play, a large share of Apple TV's memory.
        checkError(mpv_set_option_string(mpv, "cache-secs", "60"))
        if airPlayPCM {
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-max-lookahead", "4"))
            // AVPlayer's clock stays parked at AirPlay startup until the driver's
            // seek-to-start recovery. Video stays anchored to the parked clock,
            // so it waits for the audio.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-anchor-start", "yes"))
            // That recovery is what starts AirPlay's clock, so it runs after one
            // second rather than two. Seeks and resumes engage in about 0.6 s
            // without it, so they still don't trigger it.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-start-grace", "1"))
            // A title's first start never engages without that recovery, so it
            // runs as soon as AVPlayer's item is ready rather than after the
            // full second. Later seeks and resumes keep the one-second grace.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-first-start-grace", "0.25"))
            // After a pause AirPlay's clock can stay on the paused playhead for
            // most of a second. mpv is anchored to it, as at startup, so video
            // waits for the audio instead of running ahead and stopping to resync.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-anchor-resume", "yes"))
            // Starts with 1.25 s of audio queued instead of two. While the
            // stream is still ramping up, the extra audio can take over a
            // second to arrive, and the picture holds until it does. It stays
            // above the driver's one-second priming reserve: at exactly one
            // second, the driver's next read can come up short and mpv
            // rebuffers straight after starting.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-buffer", "1.25"))
        }
        #endif
        if audioOnly { checkError(mpv_set_option_string(mpv, "vid", "no")) }
        VividMPVHeaders.apply(headers, to: mpv)
        if registersManagedStreams { managedStreamsRegistered = VividManagedStreamProtocol.register(on: mpv) }
    }
}

enum VividMPVHeaders {
    /// Sets the headers as a typed string list, so commas in header values
    /// are never read as separators.
    static func apply(_ headers: [String: String], to mpv: OpaquePointer) {
        var strings = headers.sorted { $0.key < $1.key }.map { strdup("\($0.key): \($0.value)") }
        defer { for string in strings { free(string) } }
        strings.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list(num: Int32(buffer.count), values: nil, keys: nil)
            var nodes = buffer.map { pointer -> mpv_node in
                var node = mpv_node()
                node.format = MPV_FORMAT_STRING
                node.u.string = pointer
                return node
            }
            nodes.withUnsafeMutableBufferPointer { values in
                list.values = values.baseAddress
                withUnsafeMutablePointer(to: &list) { listPointer in
                    var node = mpv_node()
                    node.format = MPV_FORMAT_NODE_ARRAY
                    node.u.list = listPointer
                    _ = mpv_set_option(mpv, "http-header-fields", MPV_FORMAT_NODE, &node)
                }
            }
        }
    }
}

/// Volume Boost and Enhanced Dialogue as Lucid options.
enum VividMPVAudio {
    /// The codecs Lucid may pass through compressed: AC-3 and E-AC-3 at 1x,
    /// unless an enhancement is on. mpv's gain and filters leave a bitstream
    /// untouched, so those tracks are then decoded and Dolby Atmos plays as
    /// its surround bed.
    static func spdifCodecs(rate: Float, enhancement: VividAudioEnhancement) -> String {
        rate == 1 && !enhancement.isActive ? "ac3,eac3" : ""
    }

    /// Set only while an enhancement is on, so the default options are unchanged.
    static func enhancementOptions(_ enhancement: VividAudioEnhancement) -> [(String, String)] {
        var options: [(String, String)] = []
        // mpv's `volume` is cubic, so the boost uses its gain in decibels,
        // applied to decoded audio after the filters. 200% is +6.02 dB,
        // inside mpv's default 12 dB limit.
        if enhancement.boostPercent > 100 {
            options.append(("volume-gain", String(format: "%.2f", enhancement.boostDecibels)))
        }
        if enhancement.enhancedDialogue {
            options.append(("af", dialogueFilter))
        }
        return options
    }

    /// Enhanced Dialogue as one FIR equaliser. It handles every channel
    /// layout and never adds gain, so it can't push a peak over full scale:
    /// - With a centre channel (3.0 and up, in native order), the centre
    ///   keeps its level and every other channel drops 6 dB. `chid` 2 is
    ///   FFmpeg's front centre, and bit 2 of `chlayout` is its mask bit.
    /// - Otherwise (mono, stereo, quad and the rest), the 1.5 to 4 kHz speech
    ///   band keeps its level, bass below 120 Hz drops 8 dB and the rest
    ///   drops 2 to 3 dB.
    ///
    /// It runs before mpv mixes down to the route, so a stereo route still
    /// hears the louder centre. Zero-phase mode moves the timestamps back by
    /// the filter's 10 ms delay, which keeps the audio in sync.
    static let dialogueFilter = "lavfi=[firequalizer=multi=on:zero_phase=on"
        + ":gain_entry='entry(0,-8);entry(120,-8);entry(300,-3);entry(1000,-2);"
        + "entry(1500,0);entry(4000,0);entry(6000,-3);entry(24000,-3)'"
        + ":gain='if(gte(chs,3)*mod(floor(chlayout/4),2),if(eq(chid,2),0,-6),gain_interpolate(f))']"
}

// MARK: - Delivery and surface

/// Passes the core's deliveries to the adapter through a main-actor task,
/// tagged with the load they belong to, so a stopped load's arrive stale.
private final class VividMPVDelegate: VividPlayerCoreDelegate {
    weak var owner: VividMPVPlayer?
    let generation: UInt64

    init(owner: VividMPVPlayer, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            owner?.property(name, value: value, token: generation)
        }
    }

    func onEvent(name: String, data: [String: Any]?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            owner?.event(name, data: data, token: generation)
        }
    }
}

/// The adapter's persistent host view. Every layout pass updates the core's
/// geometry and the subtitle style that depends on it.
final class VividMPVHostView: UIView {
    fileprivate weak var core: VividPlayerCore?
    fileprivate var didLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        core?.updateFrame()
        didLayout?()
    }
}

struct VividMPVSurface: UIViewRepresentable {
    @ObservedObject var engine: VividMPVPlayer

    func makeUIView(context: Context) -> UIView {
        engine.surface.backgroundColor = .black
        engine.surface.isUserInteractionEnabled = false
        return engine.surface
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.setNeedsLayout()
    }
}

typealias VividEngine = VividMPVPlayer
typealias VividPlayerSurface = VividMPVSurface
#endif
