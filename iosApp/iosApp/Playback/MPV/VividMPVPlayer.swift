// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if (os(tvOS) || os(iOS))
import AVFoundation
import AVKit
import Combine
import Libmpv
import MediaPlayer
import SwiftUI

/// Vivid's shell adapter; the pinned media core owns output and A/V timing.
@MainActor
final class VividMPVPlayer: NSObject, ObservableObject {
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
    private var secondarySubtitleID: Int?
    var nativePlayerLayer: AVPlayerLayer? { nil }
    var isSubtitleActive: Bool { activeSubtitleTrackIndex != nil }
    var isSecondarySubtitleActive: Bool { secondarySubtitleID != nil }
    var nativeSubtitleTracks: [TrackInfo] { subtitleTracks.filter { !$0.isExternal } }
    var currentTime: Double { clock.currentTime }
    private(set) var isSeeking = false
    private(set) var isSessionReady = false
    private(set) var sourceVideoWidth: Int32 = 0
    private(set) var sourceVideoHeight: Int32 = 0
    private(set) var sourceVideoPixelAspectRatio: Double = 1
    private(set) var sourceVideoFrameRate: Double?
    private(set) var sourceVideoBitrate: Int64 = 0
    private(set) var sourceDVProfile: Int?
    private(set) var sourceVideoFormat: VideoFormat = .sdr
    private(set) var videoFormat: VideoFormat = .sdr
    var activeDolbyProfileLabel: String? {
        guard videoFormat == .dolbyVision, let profile = sourceDVProfile else { return nil }
        if profile == 7 { return "DV Profile 8.1" }
        let compatibility = videoTrack["dolby-vision-compatibility-id"] as? Int64
        return "DV Profile \(profile)" + (compatibility.map { ".\($0)" } ?? "")
    }
    var activeVideoFormat: VideoFormat { videoFormat }
    var activeVideoDecoder: String? { videoDecoder }
    var activeAudioDecoder: String? { audioDecoder }
    var activeAudioOutputFormat: String? {
        guard isSessionReady, !audioTracks.isEmpty else { return nil }
        // Output parameters distinguish the compressed carrier from decoded PCM.
        if outputAudioFormat?.contains("spdif") == true {
            let codec: String
            switch outputAudioFormat {
            case "spdif-eac3": codec = "E-AC-3"
            case "spdif-ac3": codec = "AC-3"
            default: return "Compressed audio"
            }
            // IEC carrier channels do not describe the compressed audio layout.
            let track = audioTracks.first { $0.id == activeAudioTrackIndex }
            let layout = track.flatMap { [1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"][$0.channels] }
            var atmos = ""
            if #available(iOS 26.0, tvOS 26.0, *), AVAudioSession.sharedInstance().renderingMode == .dolbyAtmos {
                atmos = " Atmos"
            }
            return codec + atmos + (layout.map { " " + $0 } ?? "")
        }
        guard let count = outputChannels else { return "Not reported" }
        return "PCM " + ([1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"][count] ?? "\(count) ch")
    }
    private static var appleRenderingMode: Int {
        if #available(iOS 26.0, tvOS 26.0, *) { return AVAudioSession.sharedInstance().renderingMode.rawValue }
        return 0
    }
    var softwareDisplaySize: CGSize? {
        sourceVideoWidth > 0 ? CGSize(width: Int(sourceVideoWidth), height: Int(sourceVideoHeight)) : nil
    }
    var readAheadAvailableSeconds: Double? { diagnostics.liveTelemetry?.forwardBufferSeconds }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }
    var backgroundPlaybackEnabled = true
    var pictureInPictureActive = false {
        didSet {
            core?.isPipActive = pictureInPictureActive
            PlaybackSessionRecorder.shared.setPictureInPicture(pictureInPictureActive)
            core?.setPipSubtitleCompositing(pictureInPictureActive)
            core?.externalDisplayDidChange()
            core?.updateFrame()
        }
    }
    private static var audioSessionOwner: UUID?
    private var audioSessionToken: UUID?
    private static let audioTeardown = DispatchGroup()
    var deactivatesAudioSessionOnStop = false
    var ownsVideoNowPlayingSession = false
    var videoNowPlayingSession: MPNowPlayingSession? { nil }
    var volume: Float = 1 { didSet { core?.setProperty("volume", value: String(volume * 100)) } }
    var videoGravity: AVLayerVideoGravity = .resizeAspect { didSet {
        core?.sampleBufferDisplayLayer?.videoGravity = videoGravity
    } }
    var transientRecoveryBudget: VividTransientRecoveryBudget?
    var refreshSourceHeaders: (@Sendable () async -> [String: String]?)?
    var preferLosslessAudio = false
    let surface = VividMPVHostView()
    private var core: VividMPVCore?
    private var delegateProxy: VividMPVDelegate?
    private var generation: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var source: (URL, LoadOptions, Int32?)?
    /// The source Vivid reads on Lucid's behalf for this load, if any.
    private var managedSource: VividManagedStreamSource?
    private var managedSourceURL: URL?
    private var requestedRate: Float = 1
    private var rateTask: Task<Void, Never>?
    private var endConfirmationTask: Task<Void, Never>?
    private var wantsPlay = false
    private var videoTrack: [String: Any] = [:]
    private var outputChannels: Int?
    private var outputAudioFormat: String?
    private var videoDecoder: String?
    private var audioDecoder: String?
    private var externalTracks: [Int: ExternalSubtitleTrack] = [:]
    private var nextExternalID = 1_000_000
    private var nativeExternalFiles: [Int: URL] = [:]
    private var externalCues: [Int: VividSubtitleCueCursor] = [:]
    private struct CuePublication: Equatable {
        let trackID: Int?
        let offsets: [Int]
        static let empty = CuePublication(trackID: nil, offsets: [])
    }
    private var primaryCuePublication = CuePublication.empty
    private var secondaryCuePublication = CuePublication.empty
    private var subtitleTasks: [Int: Task<Void, Never>] = [:]
    private var trace: PlaybackTrialTrace?
    private var cacheSnapshot: [String: Any] = [:]
    #if VIVID_P8_TRIAL
    private var audioTraceTask: Task<Void, Never>?
    #endif

    func load(url: URL, startPosition: Double = 0, options: LoadOptions = LoadOptions(),
              audioSourceStreamIndex: Int32? = nil) async throws {
        // A reload of the same source (audio recovery, header refresh)
        // continues the latest-playback session; a different source starts
        // a new one and replaces the previous session.
        let continuesSession = source?.0 == url && PlaybackSessionRecorder.shared.isRecording
        stop(resetDisplayCriteria: false, endsSessionRecording: false)
        if continuesSession {
            PlaybackSessionRecorder.shared.reloaded()
        } else {
            PlaybackSessionRecorder.shared.end(reason: "replaced")
            PlaybackSessionRecorder.shared.begin(matchContentEnabled: options.matchContentEnabled)
        }
        let token = generation
        state = .loading; playbackPhase = .loading; isBuffering = true
        startupProgress = StartupProgress(checkpoint: "opening")
        source = (url, options, audioSourceStreamIndex)
        wantsPlay = options.autoplay
        trace = PlaybackTrialTrace()
        // Vivid presents the persistent surface before committing its source.
        for _ in 0..<100 where surface.window == nil {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == token else { throw CancellationError() }
        }
        guard let window = surface.window else {
            let error = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "The playback surface is unavailable.")
            fail(error); throw error
        }
        let session = AVAudioSession.sharedInstance()
        // Preserve the active route across episode changes and audio-output reloads.
        if session.category != .playback || session.mode != .moviePlayback
            || session.routeSharingPolicy != .longFormAudio {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        }
        try session.setActive(true)
        let sessionToken = UUID()
        audioSessionToken = sessionToken
        Self.audioSessionOwner = sessionToken
        trace?.mark("mpv_audio_session_ready")
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
        // Keep playback running through content matching. The display core
        // negotiates HDMI independently; it must not add a startup pause.
        instance.autoplay = options.autoplay
        instance.audioOnly = options.audioOnly
        instance.initialRate = requestedRate
        instance.initialVolume = volume
        instance.audioLanguages = options.preferredAudioLanguages
        instance.plannedAudio = (audioSourceStreamIndex, options.audioTrackOrdinal)
        #if os(tvOS)
        instance.airPlayPCM = session.currentRoute.outputs.contains { $0.portType == .airPlay }
        #endif
        let proxy = VividMPVDelegate(owner: self, generation: token)
        delegateProxy = proxy; instance.delegate = proxy
        core = instance
        guard instance.initialize(in: window, hostView: surface) else {
            let error = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Lucid could not initialise.")
            fail(error); throw error
        }
        applySubtitleSettings(appearance: PlayerSettings.shared.effectiveSubtitleAppearance,
                              delayMilliseconds: PlayerSettings.shared.subtitleSyncMs)
        surface.core = instance
        instance.sampleBufferDisplayLayer?.videoGravity = videoGravity
        instance.setVisible(true)
        #if os(iOS)
        if !options.audioOnly, let layer = instance.sampleBufferDisplayLayer {
            softwarePiPSource = SampleBufferPiPSource(layer: layer, engine: self)
        }
        #endif
        #if VIVID_P8_TRIAL
        instance.setLogLevel("v")
        audioTraceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.generation == token else { return }
                self.recordPipelineSnapshot()
                self.recordAudioRoute()
            }
        }
        #else
        instance.setLogLevel("warn")
        #endif
        for (name, format) in Self.observations { instance.observeProperty(name, format: format) }
        startSessionSampler(token: token)
        videoRoute = options.audioOnly ? .audio : .sampleBuffer
        trace?.event("mpv_initialised", fields: "backend=mpv compressed_sink=avplayer pcm_sink=samplebuffer")
        trace?.event("mpv_audio_policy", fields: "airplay_pcm=\(instance.airPlayPCM) layouts=\(instance.airPlayPCM ? "7.1,5.1,stereo" : "auto-safe")")
        var openURL = url
        if instance.managedStreamsRegistered {
            // Read the app's refresh hook when it is needed: it is installed
            // for each load epoch and may arrive after this point.
            let managed = VividManagedStreamSource(url: url, headers: options.httpHeaders) { [weak self] in
                await self?.refreshManagedSourceHeaders()
            }
            if let managedURL = VividManagedStreamProtocol.add(managed) {
                managedSource = managed
                managedSourceURL = managedURL
                openURL = managedURL
                trace?.event("mpv_source_reader", fields: "reader=vivid")
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            instance.commandAsync(["loadfile", openURL.absoluteString, "replace"]) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
        for _ in 0..<1200 {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            if let errorInfo { throw errorInfo }
            if isSessionReady {
                applyInitialAudioSelection()
                for track in options.externalSubtitles { _ = addExternalSubtitleTrack(track) }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let error = PlaybackErrorInfo(kind: .noPlayableTrackWithinBudget, message: "Lucid did not open the source within 60 seconds.")
        fail(error); throw error
    }

    private static let observations: [(String, String)] = [
        ("time-pos", "double"), ("duration", "double"), ("pause", "flag"),
        ("paused-for-cache", "flag"), ("seeking", "flag"), ("eof-reached", "flag"),
        ("track-list", "node"), ("chapter-list", "node"), ("aid", "string"), ("sid", "string"),
        ("secondary-sid", "string"), ("video-params", "node"), ("video-out-params", "node"),
        ("audio-out-params", "node"), ("audio-codec-name", "string"), ("hwdec-current", "string"),
        ("container-fps", "double"), ("demuxer-cache-duration", "double"),
        ("demuxer-cache-state", "node"),
        ("avsync", "double"), ("frame-drop-count", "double")
    ]
    private var rawTracks: [[String: Any]] = []
    /// The resume starts on the keyframe at or before the saved position.
    private var keyframeResumePending = false
    private var initialAudioApplied = false
    fileprivate func property(_ name: String, value: Any?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "time-pos": if let value = value as? Double, value.isFinite { clock.currentTime = value; updateExternalCues() }
        case "duration": duration = (value as? Double) ?? 0
        case "demuxer-cache-state": cacheSnapshot = value as? [String: Any] ?? [:]
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
        case "pause": wantsPlay = !(value as? Bool ?? true); updatePhase()
        case "eof-reached": observeEndOfFile(value as? Bool ?? false)
        case "track-list": rawTracks = value as? [[String: Any]] ?? []; readTracks()
        case "chapter-list":
            mediaChapters = (value as? [[String: Any]] ?? []).enumerated().map {
                MediaChapter(id: $0.offset, name: $0.element["title"] as? String ?? "Chapter \($0.offset + 1)",
                             startSeconds: $0.element["time"] as? Double ?? 0)
            }
        case "aid": activeAudioTrackIndex = sourceTrackID(mpvID: (value as? String).flatMap(Int.init), type: "audio")
        case "sid": if externalTracks[activeSubtitleTrackIndex ?? -1] == nil { activeSubtitleTrackIndex = sourceTrackID(mpvID: (value as? String).flatMap(Int.init), type: "sub") }
        case "secondary-sid": if externalTracks[secondarySubtitleID ?? -1] == nil { secondarySubtitleID = sourceTrackID(mpvID: (value as? String).flatMap(Int.init), type: "sub") }
        case "video-params":
            let info = value as? [String: Any] ?? [:]
            sourceVideoWidth = Int32(clamping: info["w"] as? Int64 ?? 0)
            sourceVideoHeight = Int32(clamping: info["h"] as? Int64 ?? 0)
            sourceVideoPixelAspectRatio = info["par"] as? Double ?? 1
            sourceVideoFormat = Self.format(info, dv: sourceDVProfile != nil)
            recordSourceVideo()
        case "video-out-params":
            let info = value as? [String: Any] ?? [:]
            videoFormat = Self.format(info, dv: sourceDVProfile != nil && core?.hdrEnabled == true)
            let output = Self.dynamicRangeToken(videoFormat)
            PlaybackSessionRecorder.shared.updateMedia { $0.outputDynamicRange = output }
        case "audio-out-params":
            let info = value as? [String: Any] ?? [:]
            outputChannels = (info["channel-count"] as? Int64).map(Int.init)
            outputAudioFormat = info["format"] as? String
            let (format, channels) = (outputAudioFormat, outputChannels)
            PlaybackSessionRecorder.shared.updateMedia {
                $0.audioOutputFormat = format.flatMap(Self.formatToken)
                $0.audioOutputChannels = channels
                $0.audioPassthrough = format.map { $0.hasPrefix("spdif") }
            }
            PlaybackSessionRecorder.shared.refreshAudioRoute()
            trace?.event("mpv_audio_output", fields: "format=\(outputAudioFormat ?? "unknown") channels=\(outputChannels ?? 0) apple_mode=\(Self.appleRenderingMode)")
        case "audio-codec-name":
            audioDecoder = value as? String
            let codec = audioDecoder.flatMap(Self.formatToken)
            PlaybackSessionRecorder.shared.updateMedia { $0.audioCodec = codec }
        case "hwdec-current":
            videoDecoder = (value as? String).map { "Lucid (\($0))" }
            let hwdec = (value as? String).flatMap(Self.formatToken)
            PlaybackSessionRecorder.shared.updateMedia { $0.hardwareDecoding = hwdec }
        case "container-fps":
            sourceVideoFrameRate = value as? Double
            let fps = sourceVideoFrameRate
            PlaybackSessionRecorder.shared.updateMedia { $0.contentFps = fps }
        case "avsync": throttleAvSyncGap((value as? Double).map { $0 * 1000 })
        case "demuxer-cache-duration", "frame-drop-count":
            var stats = diagnostics.liveTelemetry ?? LiveTelemetry()
            if name == "demuxer-cache-duration" { stats.forwardBufferSeconds = value as? Double }
            if name == "frame-drop-count" { stats.droppedFrameCount = (value as? Double).map(Int.init) }
            if let gap = pendingAvSyncGapMs { stats.avSyncGapMs = gap; pendingAvSyncGapMs = nil }
            diagnostics.liveTelemetry = stats
        default: break
        }
    }
    /// `avsync` changes on almost every presented frame but only feeds the
    /// statistics overlay, which formats about once a second. Publish it at
    /// most four times a second and always finish on the latest value, so a
    /// per-frame property no longer republishes telemetry every frame.
    private static let avSyncPublishInterval: TimeInterval = 0.25
    private var pendingAvSyncGapMs: Double??
    private var lastAvSyncPublishUptime: TimeInterval = 0
    private var avSyncPublishTask: Task<Void, Never>?
    private func throttleAvSyncGap(_ gap: Double?) {
        pendingAvSyncGapMs = .some(gap)
        let wait = lastAvSyncPublishUptime + Self.avSyncPublishInterval - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { publishPendingAvSyncGap(); return }
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
        avSyncPublishTask?.cancel(); avSyncPublishTask = nil
        guard let gap = pendingAvSyncGapMs else { return }
        pendingAvSyncGapMs = nil
        lastAvSyncPublishUptime = ProcessInfo.processInfo.systemUptime
        PlaybackSessionRecorder.shared.avSync(ms: gap)
        var stats = diagnostics.liveTelemetry ?? LiveTelemetry()
        stats.avSyncGapMs = gap
        diagnostics.liveTelemetry = stats
    }
    fileprivate func event(_ name: String, data: [String: Any]?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "display-commit-lock":
            if let transition = data?["transition"] as? String,
               ["start_file", "end_file"].contains(transition),
               let wait = data?["wait_ms"] as? Double, wait.isFinite, wait >= 0,
               let held = data?["held_ms"] as? Double, held.isFinite, held >= 0 {
                trace?.event("mpv_display_commit_lock", fields: "transition=\(transition) wait_ms=\(wait) held_ms=\(held)")
            }
        case "display-criteria-prepared":
            trace?.mark("mpv_display_criteria_prepared")
        case "display-switch-started", "display-switch-ended":
            if name == "display-switch-ended" { PlaybackSessionRecorder.shared.displaySwitched() } else { PlaybackSessionRecorder.shared.settling() }
            trace?.event(name == "display-switch-started" ? "mpv_display_switch_started" : "mpv_display_switch_ended")
            recordPipelineSnapshot()
        case "file-loaded":
            isSessionReady = true; startupProgress = nil; applyInitialAudioSelection(); updatePhase()
            trace?.mark("mpv_file_loaded")
        case "playback-restart":
            if keyframeResumePending {
                // Later seeks without an explicit precision are exact again.
                keyframeResumePending = false
                core?.setProperty("hr-seek", value: "default")
            }
            hasFirstFrameReadyForDisplay = true; isSeeking = false; isBuffering = false
            updatePhase(); trace?.mark("mpv_playback_restart")
            trace?.seekPicture()
        case "end-file":
            handleEndFile(data)
        case "log-message":
            if let fields = Self.audioDiagnostic(data) {
                if fields.hasPrefix("fault=") {
                    PlaybackSessionRecorder.shared.audioFault(String(fields.dropFirst("fault=".count)))
                }
                trace?.event("mpv_audio_diagnostic", fields: fields)
                if fields.hasPrefix("raw_s=") || fields.hasPrefix("event=audio_transport ")
                    || fields.hasPrefix("event=pcm_transport ") || fields.hasPrefix("event=audio_edge ") {
                    recordPipelineSnapshot()
                }
            }
        default: break
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
        guard reached else { cancelEndConfirmation(); updatePhase(); return }
        // The playhead stops at the end, and keep-open holds the last frame
        // under Next Up; neither is playback for the latest-playback record.
        PlaybackSessionRecorder.shared.setPlaying(false)
        guard errorInfo == nil, state != .ended, endConfirmationTask == nil else { return }
        let token = generation
        let seekToken = seekGeneration
        // keep-open retains the source for rewinding from Next Up. Its EOF
        // property can precede end-file(error), so allow queued errors to win.
        endConfirmationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == token,
                  self.seekGeneration == seekToken, self.errorInfo == nil else { return }
            self.endConfirmationTask = nil
            guard self.isSessionReady, self.hasFirstFrameReadyForDisplay else {
                self.fail(PlaybackErrorInfo(kind: .softwarePipelineFailed,
                    message: "The media stream ended before playback started."))
                return
            }
            self.isSeeking = false
            self.isBuffering = false
            self.playbackPhase = .ended
            self.state = .ended
        }
    }

    private func recordPipelineSnapshot() {
        guard trace != nil else { return }
        var fields = ["position_s=\(currentTime)", "playing=\(wantsPlay)", "buffering=\(isBuffering)", "seeking=\(isSeeking)"]
        if let gap = pendingAvSyncGapMs ?? diagnostics.liveTelemetry?.avSyncGapMs, gap.isFinite {
            fields.append("avsync_ms=\(gap)")
        }
        for key in ["fw-bytes", "total-bytes", "raw-input-rate", "reader-pts", "cache-end", "cache-duration", "eof", "underrun", "idle"] {
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
    private func recordAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        let airPlay = session.currentRoute.outputs.contains { $0.portType == .airPlay }
        let hdmi = session.currentRoute.outputs.contains { $0.portType == .HDMI }
        trace?.event("mpv_audio_route", fields:
            "airplay=\(airPlay) hdmi=\(hdmi) session_channels=\(session.outputNumberOfChannels) " +
            "sample_rate=\(session.sampleRate) latency_s=\(session.outputLatency) io_buffer_s=\(session.ioBufferDuration) " +
            "player_channels=\(outputChannels ?? 0) apple_mode=\(Self.appleRenderingMode)")
    }
    #endif
    // Raw mpv messages can contain authenticated URLs. Only fixed fault labels
    // and strictly numeric AVPlayer heartbeat/status fields may enter the device log.
    // Compiled once rather than for every matching audio log message.
    private static let pcmTransportRegex = try? NSRegularExpression(pattern: #"\Apcm: clock (-?[0-9]+\.[0-9]+), fed (-?[0-9]+\.[0-9]+), ahead (-?[0-9]+\.[0-9]+), rate (-?[0-9]+\.[0-9]+), status ([0-9]+)(?:, latency (-?[0-9]+\.[0-9]+), sufficient (-?[0-9]+))?\z"#)
    private static let audioEdgeRegex = try? NSRegularExpression(pattern: #"\Atrace edge (start|start-fresh|pause|resume|reset|restart): clock (-?[0-9]+\.[0-9]+), fed (-?[0-9]+\.[0-9]+), latency (-?[0-9]+\.[0-9]+)\z"#)
    private static let compressedEngagedRegex = try? NSRegularExpression(pattern: #"\Acompressed clock engaged after (-?[0-9]+\.[0-9]+) s, seeked ([01]), anchors ([0-9]+)\z"#)
    private static let compressedResumedRegex = try? NSRegularExpression(pattern: #"\Acompressed clock resumed after (-?[0-9]+\.[0-9]+) s, anchors ([0-9]+)\z"#)
    private static let flushTimeRegex = try? NSRegularExpression(pattern: #"\Anotification flush time (-?[0-9]+\.[0-9]+|nan), current ([01])\z"#)
    private static let heartbeatRegex = try? NSRegularExpression(pattern: #"\Aheartbeat: raw pos (-?[0-9]+\.[0-9]+)s, clamped (-?[0-9]+\.[0-9]+)s, fed (-?[0-9]+\.[0-9]+)s, status ([0-9]+), tc ([0-9]+)(?:, reader gap (-?[0-9]+) B)?\z"#)
    private static let audioStatusRegex = try? NSRegularExpression(pattern: #"\Aitem status (-?[0-9]+) -> (-?[0-9]+), time control (-?[0-9]+) -> (-?[0-9]+), pos (-?[0-9]+\.[0-9]+)s, fed (-?[0-9]+\.[0-9]+)s\z"#)
    private static func audioDiagnostic(_ data: [String: Any]?) -> String? {
        guard let prefix = data?["prefix"] as? String,
              let text = data?["text"] as? String else { return nil }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("Too many packets in the demuxer packet queues:") {
            return "fault=packet_queue_limit"
        }
        if prefix == "ao/avfoundation", message == "resuming compressed feed after audio EOF" {
            return "event=compressed_feed_resumed_after_eof"
        }
        if ["demux", "demuxer", "cplayer", "ad", "ffmpeg"].contains(prefix)
            || prefix.hasPrefix("ffmpeg/") || prefix.hasPrefix("demux/") {
            let faults = [("Too many packets", "packet_queue_limit"), ("queue overflow", "packet_queue_limit"),
                          ("EOF", "eof_message"), ("End of file", "eof_message"),
                          ("timed out", "input_timeout"), ("Connection reset", "connection_reset"),
                          ("Error decoding", "decode_error"), ("Invalid data", "invalid_data")]
            if let fault = faults.first(where: { message.contains($0.0) }) { return "fault=\(fault.1)" }
            return nil
        }
        guard prefix == "ao/avfoundation" else { return nil }
        if message == "restarting due to system notification; this will cause desync" {
            return "fault=audio_system_restart"
        }
        if message.hasPrefix("notification name: ") && message.contains("AVSampleBufferAudioRendererWasFlushedAutomatically") {
            return "event=audio_system_flush"
        }
        if message.hasPrefix("notification name: ") && message.contains("AVSampleBufferAudioRendererOutputConfigurationDidChange") {
            return "event=audio_output_configuration_changed"
        }
        if message == "pcm fresh sink after reset" {
            return "event=pcm_fresh_sink_after_reset"
        }
        if message == "pcm fresh sink failed; requesting audio reload" {
            return "fault=pcm_fresh_sink_failed"
        }
        if message == "pcm renderer failed; requesting audio reload" {
            return "fault=pcm_renderer_failed"
        }
        if let regex = Self.pcmTransportRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["clock_s", "fed_s", "ahead_s", "rate", "status", "latency_s", "sufficient"]
            return "event=pcm_transport " + names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        if let regex = Self.audioEdgeRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["edge", "clock_s", "fed_s", "latency_s"]
            return "event=audio_edge " + names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        if let regex = Self.compressedEngagedRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["after_s", "seeked", "anchors"]
            return "event=compressed_clock_engaged " + names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        if let regex = Self.compressedResumedRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["after_s", "anchors"]
            return "event=compressed_clock_resumed " + names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        if let regex = Self.flushTimeRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
           let time = Range(match.range(at: 1), in: message), let current = Range(match.range(at: 2), in: message) {
            return "event=audio_system_flush_time flush_s=\(message[time]) current=\(message[current])"
        }
        if let regex = Self.heartbeatRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["raw_s", "clock_s", "fed_s", "status", "time_control", "reader_gap_bytes"]
            return names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        if let regex = Self.audioStatusRegex,
           let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)) {
            let names = ["old_status", "status", "old_time_control", "time_control", "clock_s", "fed_s"]
            return "event=audio_transport " + names.enumerated().compactMap { index, name in
                guard let range = Range(match.range(at: index + 1), in: message) else { return nil }
                return "\(name)=\(message[range])"
            }.joined(separator: " ")
        }
        let faults = [
            ("elementary stream window overflow", "window_overflow"),
            ("discarding burst with odd payload length", "odd_payload"),
            ("discarding burst without syncframe", "missing_syncframe"),
            ("skipping unexpected IEC 61937 data type", "unexpected_burst_type"),
            ("skipping burst with invalid payload length", "invalid_payload"),
            ("no IEC 61937 sync found", "missing_iec_sync"),
            ("loader requested offset", "loader_offset"),
            ("playback did not engage", "playback_not_engaged"),
            ("native compressed playback did not start", "compressed_start_failed"),
            ("player rejected the compressed stream", "apple_rejected_stream"),
            ("falling back to PCM", "pcm_fallback")
        ]
        guard let fault = faults.first(where: { message.contains($0.0) }) else { return nil }
        return "fault=\(fault.1)"
    }
    private func updatePhase() {
        // The latest-playback session counts only time with video actually
        // on screen, so opening the file is never mistaken for playback.
        PlaybackSessionRecorder.shared.setPlaying(isSessionReady && hasFirstFrameReadyForDisplay && wantsPlay
            && !isSeeking && !isBuffering && errorInfo == nil && state != .ended && endConfirmationTask == nil)
        guard isSessionReady, errorInfo == nil, state != .ended else { return }
        if isSeeking { state = .seeking; playbackPhase = .seeking }
        else if !wantsPlay { state = .paused; playbackPhase = .paused }
        else if isBuffering { playbackPhase = .rebuffering }
        else { state = .playing; playbackPhase = .playing }
    }
    private static func format(_ info: [String: Any], dv: Bool) -> VideoFormat {
        if dv { return .dolbyVision }
        switch info["gamma"] as? String { case "pq", "smpte2084": return .hdr10; case "hlg", "arib-std-b67": return .hlg; default: return .sdr }
    }
    nonisolated static func trackInfo(_ info: [String: Any]) -> TrackInfo {
            TrackInfo(id: Int(info["ff-index"] as? Int64 ?? info["id"] as? Int64 ?? 0), name: info["title"] as? String ?? "",
                      codec: info["codec"] as? String ?? "", language: info["lang"] as? String,
                      channels: Int(info["demux-channel-count"] as? Int64 ?? 0),
                      isDefault: info["default"] as? Bool ?? false, isForced: info["forced"] as? Bool ?? false,
                      isHearingImpaired: info["hearing-impaired"] as? Bool ?? false,
                      isExternal: info["external"] as? Bool ?? false, isNativelyRenderedSubtitle: true,
                      sourceStreamIndex: (info["ff-index"] as? Int64).map(Int.init))
    }
    private func readTracks() {
        audioTracks = rawTracks.filter { $0["type"] as? String == "audio" }.map(Self.trackInfo)
        subtitleTracks = rawTracks.filter { $0["type"] as? String == "sub" && $0["external"] as? Bool != true }.map(Self.trackInfo)
        subtitleTracks += externalTracks.sorted { $0.key < $1.key }.map { id, t in
            TrackInfo(id: id, name: t.name ?? "External subtitles",
                      codec: nativeExternalFiles[id] != nil ? "ass" : "",
                      language: t.language, isForced: t.isForced,
                      isExternal: true, isNativelyRenderedSubtitle: nativeExternalFiles[id] != nil)
        }
        videoTrack = rawTracks.first { $0["type"] as? String == "video" } ?? [:]
        sourceDVProfile = (videoTrack["dolby-vision-profile"] as? Int64).flatMap { $0 > 0 ? Int($0) : nil }
        if sourceDVProfile != nil { sourceVideoFormat = .dolbyVision }
        recordSourceVideo()
        if let selected = rawTracks.first(where: { $0["type"] as? String == "audio" && $0["selected"] as? Bool == true }) {
            activeAudioTrackIndex = sourceTrackID(mpvID: (selected["id"] as? Int64).map(Int.init), type: "audio")
        }
        applyInitialAudioSelection()
        if let id = activeSubtitleTrackIndex, nativeExternalFiles[id] != nil { selectSubtitleTrack(index: id) }
        if let id = secondarySubtitleID, nativeExternalFiles[id] != nil { selectSecondarySubtitleTrack(index: id) }
    }
    private func sourceTrackID(mpvID: Int?, type: String) -> Int? {
        guard let mpvID,
              let track = rawTracks.first(where: { $0["type"] as? String == type && $0["id"] as? Int64 == Int64(mpvID) }) else { return nil }
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
    /// choice after load, where it is then already selected.
    nonisolated static func plannedAudioTrackID(in tracks: [[String: Any]], streamIndex: Int32?, ordinal: Int?) -> Int64? {
        let audio = tracks.filter { $0["type"] as? String == "audio" }
        if let streamIndex {
            return audio.first { $0["ff-index"] as? Int64 == Int64(streamIndex) }?["id"] as? Int64
        }
        guard let ordinal, audio.indices.contains(ordinal) else { return nil }
        return audio[ordinal]["id"] as? Int64
    }
    private func applyInitialAudioSelection() {
        guard isSessionReady, !initialAudioApplied, !audioTracks.isEmpty, let source else { return }
        if let streamIndex = source.2 {
            guard let track = rawTracks.first(where: { $0["type"] as? String == "audio" && $0["ff-index"] as? Int64 == Int64(streamIndex) }),
                  track["id"] as? Int64 != nil else { return }
            selectAudioTrack(index: Int(streamIndex))
        } else if let ordinal = source.1.audioTrackOrdinal, audioTracks.indices.contains(ordinal) {
            selectAudioTrack(index: audioTracks[ordinal].id)
        }
        initialAudioApplied = true
    }
    func play() { wantsPlay = true; core?.setProperty("pause", value: "no"); updatePhase() }
    func pause() { wantsPlay = false; core?.setProperty("pause", value: "yes"); updatePhase() }
    func setRate(_ rate: Float) {
        PlaybackSessionRecorder.shared.settling()
        guard rate.isFinite, rate > 0 else { return }
        trace?.event("mpv_rate_requested", fields: "rate=\(rate) previous=\(requestedRate)")
        // Crossing 1x on an AC-3 or E-AC-3 track swaps compressed output for
        // PCM, or back, which replaces the audio output.
        let codec = audioTracks.first { $0.id == activeAudioTrackIndex }?.codec ?? ""
        let swapsAudioOutput = (rate == 1) != (requestedRate == 1) && ["ac3", "eac3"].contains(codec)
        requestedRate = rate
        guard let core else { return }
        let token = generation
        let previous = rateTask
        rateTask = Task { @MainActor [weak self, weak core] in
            await previous?.value
            guard let self, let core, generation == token, !Task.isCancelled else { return }
            // Compressed packets cannot pass through a tempo filter.
            let changes = rate == 1
                ? [("speed", String(rate)), ("audio-spdif", "ac3,eac3")]
                : [("audio-spdif", ""), ("speed", String(rate))]
            do {
                for (name, value) in changes {
                    guard generation == token, !Task.isCancelled else { return }
                    if name == "audio-spdif", swapsAudioOutput {
                        // Otherwise mpv plays out the old output's queue (about seven
                        // seconds over AirPlay) with the picture held, then shows the
                        // picture silent until it reaches the audio. Seeking in place
                        // drops that queue and restarts both together. Queue the seek
                        // just before the option so mpv takes both before decoding again.
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
    func seek(to seconds: Double) async {
        guard let core, seconds.isFinite else { return }
        cancelEndConfirmation()
        let token = generation
        seekGeneration &+= 1
        let seekToken = seekGeneration
        isSeeking = true; state = .seeking; updatePhase()
        trace?.beginSeek(target: seconds)
        core.command(["seek", String(max(0, duration > 0 ? min(seconds, duration) : seconds)), "absolute+exact"])
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled || token != generation || seekToken != seekGeneration || !isSeeking || errorInfo != nil { return }
        }
        fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "The Lucid seek did not complete."))
    }
    func selectAudioTrack(index: Int) {
        guard let id = mpvTrackID(sourceID: index, type: "audio") else { return }
        PlaybackSessionRecorder.shared.settling()
        core?.setProperty("aid", value: String(id))
    }
    private var subtitleDelaySeconds: Double = 0

    func applySubtitleSettings(appearance: SubtitleAppearance, delayMilliseconds: Int) {
        subtitleDelaySeconds = Double(delayMilliseconds) / 1000
        for (name, value) in LucidSubtitleStyle.options(appearance) {
            core?.setProperty(name, value: value)
        }
        core?.setProperty("sub-delay", value: String(subtitleDelaySeconds - (externalTracks[activeSubtitleTrackIndex ?? -1]?.nativeTimelineOffsetSeconds ?? 0)))
        core?.setProperty("secondary-sub-delay", value: String(subtitleDelaySeconds - (externalTracks[secondarySubtitleID ?? -1]?.nativeTimelineOffsetSeconds ?? 0)))
        updateExternalCues()
    }

    private func subtitleMPVID(_ id: Int) -> Int? {
        if let file = nativeExternalFiles[id] {
            return rawTracks.first(where: {
                $0["type"] as? String == "sub" && $0["external-filename"] as? String == file.path
            }).flatMap { ($0["id"] as? Int64).map(Int.init) }
        }
        return externalTracks[id] == nil ? mpvTrackID(sourceID: id, type: "sub") : nil
    }

    func selectSubtitleTrack(index: Int) {
        activeSubtitleTrackIndex = index
        core?.setProperty("sid", value: subtitleMPVID(index).map(String.init) ?? "no")
        core?.setProperty("sub-delay", value: String(subtitleDelaySeconds - (externalTracks[index]?.nativeTimelineOffsetSeconds ?? 0)))
        updateExternalCues()
    }
    func selectSecondarySubtitleTrack(index: Int) {
        secondarySubtitleID = index
        core?.setProperty("secondary-sid", value: subtitleMPVID(index).map(String.init) ?? "no")
        core?.setProperty("secondary-sub-delay", value: String(subtitleDelaySeconds - (externalTracks[index]?.nativeTimelineOffsetSeconds ?? 0)))
        updateExternalCues()
    }
    func clearSubtitle() { activeSubtitleTrackIndex = nil; core?.setProperty("sid", value: "no"); updateExternalCues() }
    func clearSecondarySubtitle() { secondarySubtitleID = nil; core?.setProperty("secondary-sid", value: "no"); updateExternalCues() }
    private func updateExternalCues() {
        let time = currentTime - subtitleDelaySeconds
        let primary = externalCues[activeSubtitleTrackIndex ?? -1]?.selection(at: time) ?? .empty
        let primaryPublication = CuePublication(
            trackID: primary.offsets.isEmpty ? nil : activeSubtitleTrackIndex, offsets: primary.offsets)
        if primaryPublication != primaryCuePublication {
            primaryCuePublication = primaryPublication
            subtitleCues = primary.cues
        }
        let secondary = externalCues[secondarySubtitleID ?? -1]?.selection(at: time) ?? .empty
        let secondaryPublication = CuePublication(
            trackID: secondary.offsets.isEmpty ? nil : secondarySubtitleID, offsets: secondary.offsets)
        if secondaryPublication != secondaryCuePublication {
            secondaryCuePublication = secondaryPublication
            secondarySubtitleCues = secondary.cues
        }
    }
    #if DEBUG
    /// Exercises the same clock event as the media core without opening a source.
    func debugReceivePlaybackTime(_ seconds: Double) {
        property("time-pos", value: seconds, token: generation)
    }
    #endif
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = externalTracks.first(where: { $0.value == track })?.key ?? nextExternalID
        if externalTracks[id] == nil {
            nextExternalID += 1; externalTracks[id] = track; readTracks()
            let token = generation
            isLoadingSubtitles = true
            subtitleTasks[id] = Task { @MainActor [weak self] in
                var pendingNativeFile: URL?
                defer {
                    if let pendingNativeFile {
                        try? FileManager.default.removeItem(at: pendingNativeFile)
                    }
                }
                do {
                    let document = try await VividSubtitleLoader.load(track)
                    guard let self, generation == token, !Task.isCancelled else { return }
                    switch document {
                    case .cues(let cues): externalCues[id] = VividSubtitleCueCursor(cues)
                    case .ass(let text):
                        let file = FileManager.default.temporaryDirectory
                            .appendingPathComponent("vivid-subtitle-" + UUID().uuidString).appendingPathExtension("ass")
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
                subtitleTasks[id] = nil; isLoadingSubtitles = !subtitleTasks.isEmpty
            }
        }
        return subtitleTracks.first { $0.id == id }!
    }
    private func refreshManagedSourceHeaders() async -> [String: String]? {
        await refreshSourceHeaders?()
    }

    /// Only a Vivid-read source can take new headers live; Lucid's own HTTP
    /// reader keeps the headers it opened with.
    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool {
        guard let managedSource, managedSource.url == url else { return false }
        managedSource.update(headers)
        return true
    }
    func reloadAtCurrentPosition() async throws {
        guard let source else { return }
        var options = source.1; options.autoplay = wantsPlay
        if let fresh = await refreshSourceHeaders?() { options.httpHeaders = fresh }
        try await load(url: source.0, startPosition: currentTime, options: options, audioSourceStreamIndex: source.2)
    }
    func prepareForItemReplacement() { pause(); hasFirstFrameReadyForDisplay = false }
    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        stop(resetDisplayCriteria: resetDisplayCriteria, endsSessionRecording: true)
    }
    private func stop(resetDisplayCriteria: Bool, endsSessionRecording: Bool) {
        if endsSessionRecording {
            PlaybackSessionRecorder.shared.end(reason: state == .ended ? "ended" : "stopped")
        }
        sessionSampler?.cancel(); sessionSampler = nil
        generation &+= 1
        #if VIVID_P8_TRIAL
        audioTraceTask?.cancel(); audioTraceTask = nil
        #endif
        cancelEndConfirmation()
        rateTask?.cancel(); rateTask = nil
        softwarePiPSource = nil
        // Unblock any reader before Lucid tears down, which may be synchronous.
        managedSource?.cancel()
        core?.delegate = nil
        if let core {
            let teardown = Self.audioTeardown
            teardown.enter()
            core.dispose(preserveDisplayCriteria: !resetDisplayCriteria) { teardown.leave() }
        }
        if deactivatesAudioSessionOnStop, let sessionToRelease = audioSessionToken {
            audioSessionToken = nil
            // The session is shared, so wait for retired cores from every player instance.
            Self.audioTeardown.notify(queue: .main) {
                MainActor.assumeIsolated {
                    // Never release a newer load's session, including another player.
                    guard Self.audioSessionOwner == sessionToRelease else { return }
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    Self.audioSessionOwner = nil
                }
            }
        }
        core = nil; delegateProxy = nil; surface.core = nil; source = nil
        VividManagedStreamProtocol.remove(managedSourceURL)
        managedSource = nil; managedSourceURL = nil
        trace?.event("mpv_stopped"); trace = nil
        state = .idle; playbackPhase = .idle; videoRoute = .none
        isSessionReady = false; isSeeking = false; isBuffering = false
        hasFirstFrameReadyForDisplay = false; errorInfo = nil; startupProgress = nil
        clock.currentTime = 0; duration = 0; audioTracks = []; subtitleTracks = []; mediaChapters = []
        initialAudioApplied = false
        for file in nativeExternalFiles.values { try? FileManager.default.removeItem(at: file) }
        nativeExternalFiles = [:]
        rawTracks = []; videoTrack = [:]; externalTracks = [:]; externalCues = [:]
        for task in subtitleTasks.values { task.cancel() }; subtitleTasks = [:]
        isLoadingSubtitles = false
        activeAudioTrackIndex = nil; activeSubtitleTrackIndex = nil; secondarySubtitleID = nil
        updateExternalCues()
        sourceVideoWidth = 0; sourceVideoHeight = 0; sourceVideoBitrate = 0; sourceVideoFrameRate = nil
        sourceVideoPixelAspectRatio = 1; sourceDVProfile = nil; sourceVideoFormat = .sdr; videoFormat = .sdr
        outputChannels = nil; outputAudioFormat = nil; videoDecoder = nil; audioDecoder = nil
        diagnostics.liveTelemetry = nil
        avSyncPublishTask?.cancel(); avSyncPublishTask = nil
        pendingAvSyncGapMs = nil; lastAvSyncPublishUptime = 0
        cacheSnapshot = [:]
    }
    // MARK: Latest playback session

    private var sessionSampler: Task<Void, Never>?

    /// Reads two cumulative frame counters once a second, and bitrate and
    /// display rate every 10 seconds, off the render path, for the
    /// latest-playback report. Properties the output
    /// doesn't support come back as nil and are reported as not measured.
    private func startSessionSampler(token: UInt64) {
        sessionSampler?.cancel()
        guard PlaybackSessionRecorder.isEnabled else { return }
        sessionSampler = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.generation == token, let core = self.core else { return }
                // Bitrate and display rate change rarely; read them every 10 s.
                let slow = tick % 10 == 0
                tick &+= 1
                async let decoder = Self.readNumber(core, "decoder-frame-drop-count")
                async let delayed = Self.readNumber(core, "vo-delayed-frame-count")
                async let bitrate: Double? = slow ? await Self.readNumber(core, "video-bitrate") : nil
                async let displayFps: Double? = slow ? await Self.readNumber(core, "display-fps") : nil
                let values = await (decoder, delayed, bitrate, displayFps)
                guard !Task.isCancelled, self.generation == token else { return }
                if let bitrate = values.2, bitrate > 0 {
                    PlaybackSessionRecorder.shared.updateMedia { $0.videoBitrateKbps = Int(bitrate / 1000) }
                }
                let inputRate = (self.cacheSnapshot["raw-input-rate"] as? NSNumber)?.doubleValue
                PlaybackSessionRecorder.shared.sample(
                    dropped: self.diagnostics.liveTelemetry?.droppedFrameCount,
                    decoderDropped: values.0.map(Int.init),
                    delayed: values.1.map(Int.init),
                    networkKbps: inputRate.flatMap { $0 > 0 && $0.isFinite ? Int($0 * 8 / 1000) : nil },
                    displayFps: values.3,
                    position: self.currentTime)
            }
        }
    }

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
            if width > 0, height > 0 { $0.width = width; $0.height = height }
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

    private func fail(_ error: PlaybackErrorInfo) {
        cancelEndConfirmation()
        core?.setProperty("pause", value: "yes")
        errorInfo = error; state = .error(error.message); playbackPhase = .error(error.message)
        PlaybackSessionRecorder.shared.end(reason: "failed_\(error.kind.rawValue)")
        isBuffering = false; isSeeking = false; trace?.event("mpv_failed", fields: "kind=\(error.kind.rawValue)")
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

/// Plain text styling only; authored ASS and bitmap layout stays with Lucid.
enum LucidSubtitleStyle {
    static func options(_ value: SubtitleAppearance) -> [String: String] {
        let a = value.sanitized()
        let boxed = a.backgroundStyle == .box || a.captionWindowOpacity > 0
        let back = a.captionWindowOpacity > 0 ? a.captionWindowColor : a.backgroundColor
        let opacity = a.captionWindowOpacity > 0 ? a.captionWindowOpacity : a.backgroundOpacity
        let edge = a.systemTextEdgeStyle
        let outline = a.textOutline || edge == .uniform
        let shadow = a.backgroundStyle == .shadow || edge == .dropShadow || edge == .raised || edge == .depressed
        return [
            "sub-ass-override": "no", "secondary-sub-ass-override": "no",
            "sub-font": a.fontFamily.assFontName,
            "sub-font-size": String((a.systemRelativeFontScale.map { SubtitleAppearance.default.fontSize.pointSize * $0 } ?? a.fontSize.pointSize) * 720 / 1080),
            "sub-color": colour(a.fontColor, opacity: a.fontOpacity),
            "sub-border-style": boxed ? "background-box" : "outline-and-shadow",
            "sub-back-color": colour(back, opacity: boxed || shadow ? opacity : 0),
            "sub-outline-color": a.textOutlineColor,
            "sub-outline-size": outline ? "1.33" : "0",
            "sub-shadow-offset": boxed ? "4" : shadow ? "2" : "0",
            "sub-align-y": a.position == .top ? "top" : "bottom",
            "sub-pos": a.position == .lowerThird ? "70" : "100",
            "sub-scale-with-window": "no", "sub-use-margins": "no"
        ]
    }

    private static func colour(_ hex: String, opacity: Int) -> String {
        let alpha = Int((Double(opacity) * 255 / 100).rounded())
        return String(format: "#%02X", alpha) + hex.replacingOccurrences(of: "#", with: "")
    }
}

private final class VividMPVCore: MpvPlayerCore {
    var headers: [String: String] = [:]
    var registersManagedStreams = false
    private(set) var managedStreamsRegistered = false
    var startPosition: Double = 0
    var autoplay = true
    var audioOnly = false
    var initialRate: Float = 1
    var initialVolume: Float = 1
    var audioLanguages: [String] = []
    var plannedAudio: (streamIndex: Int32?, ordinal: Int?) = (nil, nil)
    var airPlayPCM = false
    override var selectsAudioWhilePreloading: Bool { plannedAudio.streamIndex != nil || plannedAudio.ordinal != nil }
    override func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64? {
        VividMPVPlayer.plannedAudioTrackID(in: tracks, streamIndex: plannedAudio.streamIndex, ordinal: plannedAudio.ordinal)
    }
    override func configurePlatformMpvOptions(mpv: OpaquePointer) {
        let settings = ["ao": "avfoundation", "audio-spdif": initialRate == 1 ? "ac3,eac3" : "",
                        "ao-avfoundation-manage-audio-session": "no",
                        "audio-exclusive": "yes", "audio-channels": airPlayPCM ? "7.1,5.1,stereo" : "auto-safe",
                        "config": "no", "input-default-bindings": "no", "input-vo-keyboard": "no",
                        "osd-level": "0", "pause": autoplay ? "no" : "yes",
                        "start": String(startPosition), "speed": String(initialRate),
                        // Resume on the keyframe at or before the saved position. An exact
                        // resume first downloads and decodes everything from that keyframe
                        // up to the position, about 5 MB for a 4K remux, before the first
                        // picture. Vivid's own seeks ask for exact positions explicitly.
                        "hr-seek": startPosition > 0 ? "no" : "default",
                        "volume": String(initialVolume * 100), "sid": "no", "secondary-sid": "no",
                        "cache": "yes", "demuxer-max-bytes": "268435456", "demuxer-max-back-bytes": "16777216",
                        "alang": audioLanguages.joined(separator: ","), "terminal": "no"]
        for (name, value) in settings { checkError(mpv_set_option_string(mpv, name, value), option: name) }
        #if os(tvOS)
        // Read at most a minute ahead. On a fast link the 256 MiB packet cache
        // otherwise fills over a long play, a large share of Apple TV's memory.
        checkError(mpv_set_option_string(mpv, "cache-secs", "60"))
        if airPlayPCM {
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-max-lookahead", "4"))
            // AVPlayer's clock stays parked at AirPlay startup until the driver's seek-to-start
            // recovery. Keep video anchored to the parked clock so it waits for the audio.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-anchor-start", "yes"))
            // That recovery is what starts AirPlay's clock, so run it after one
            // second rather than two. Seeks and resumes engage in about 0.6 s
            // without it, so they still don't trigger it.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-start-grace", "1"))
            // A title's first start never engages without that recovery, so
            // run it as soon as AVPlayer's item is ready rather than after the
            // full second. Later seeks and resumes keep the one-second grace.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-first-start-grace", "0.25"))
            // After a pause AirPlay's clock can stay on the paused playhead for
            // most of a second. Anchor mpv to it, as at startup, so video waits
            // for the audio instead of running ahead and then stopping to resync.
            checkError(mpv_set_option_string(mpv, "ao-avfoundation-compressed-anchor-resume", "yes"))
            // Start with 1.25 s of audio queued instead of two. While the
            // stream is still ramping up, the extra audio can take over a
            // second to arrive, and the picture holds until it does. Keep it
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
    static func apply(_ headers: [String: String], to mpv: OpaquePointer) {
        // Set a typed string list, so commas in header values are never interpreted as separators.
        var strings = headers.sorted { $0.key < $1.key }.map { strdup("\($0.key): \($0.value)") }
        defer { for string in strings { free(string) } }
        strings.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list(num: Int32(buffer.count), values: nil, keys: nil)
            var nodes = buffer.map { pointer -> mpv_node in
                var node = mpv_node(); node.format = MPV_FORMAT_STRING; node.u.string = pointer; return node
            }
            nodes.withUnsafeMutableBufferPointer { values in
                list.values = values.baseAddress
                withUnsafeMutablePointer(to: &list) { listPointer in
                    var node = mpv_node(); node.format = MPV_FORMAT_NODE_ARRAY; node.u.list = listPointer
                    _ = mpv_set_option(mpv, "http-header-fields", MPV_FORMAT_NODE, &node)
                }
            }
        }
    }
}

private final class VividMPVDelegate: MpvPlayerDelegate {
    weak var owner: VividMPVPlayer?
    let generation: UInt64
    init(owner: VividMPVPlayer, generation: UInt64) { self.owner = owner; self.generation = generation }
    func onPropertyChange(name: String, value: Any?, sourceId: Int64?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; owner?.property(name, value: value, token: generation)
        }
    }
    func onEvent(name: String, data: [String: Any]?) {
        Task { @MainActor [weak self] in
            guard let self else { return }; owner?.event(name, data: data, token: generation)
        }
    }
}

final class VividMPVHostView: UIView {
    fileprivate weak var core: MpvPlayerCore?
    override func layoutSubviews() { super.layoutSubviews(); core?.updateFrame() }
}
struct VividMPVSurface: UIViewRepresentable {
    @ObservedObject var engine: VividMPVPlayer
    func makeUIView(context: Context) -> UIView {
        engine.surface.backgroundColor = .black; engine.surface.isUserInteractionEnabled = false
        return engine.surface
    }
    func updateUIView(_ view: UIView, context: Context) { view.setNeedsLayout() }
}
typealias VividEngine = VividMPVPlayer
typealias VividPlayerSurface = VividMPVSurface
#endif
