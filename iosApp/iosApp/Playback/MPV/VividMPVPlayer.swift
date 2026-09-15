// SPDX-License-Identifier: GPL-3.0-only
// Additional permission applies to Vivid's adapter only: LICENSE-APPLE-EXCEPTION.
#if os(tvOS) && VIVID_MPV_EXPERIMENT
import AVFoundation
import AVKit
import Combine
import Libmpv
import MediaPlayer
import SwiftUI

/// Vivid's shell adapter; the pinned Plezy/mpv build owns output and A/V timing.
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
            switch AVAudioSession.sharedInstance().renderingMode {
            case .dolbyAtmos: return "Dolby Atmos"
            case .dolbyAudio: return "Dolby Audio"
            case .spatialAudio: return "Spatial Audio"
            case .surround: return "Surround"
            case .monoStereo: return "Mono/Stereo"
            default: return "Not reported"
            }
        }
        guard let count = outputChannels else { return "Not reported" }
        return "PCM " + ([1: "1.0", 2: "2.0", 6: "5.1", 8: "7.1"][count] ?? "\(count) ch")
    }
    var softwareDisplaySize: CGSize? {
        sourceVideoWidth > 0 ? CGSize(width: Int(sourceVideoWidth), height: Int(sourceVideoHeight)) : nil
    }
    var readAheadAvailableSeconds: Double? { diagnostics.liveTelemetry?.forwardBufferSeconds }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }
    var backgroundPlaybackEnabled = true
    var pictureInPictureActive = false
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
    private var source: (URL, LoadOptions, Int32?)?
    private var requestedRate: Float = 1
    private var wantsPlay = false
    private var videoTrack: [String: Any] = [:]
    private var outputChannels: Int?
    private var outputAudioFormat: String?
    private var videoDecoder: String?
    private var audioDecoder: String?
    private var externalTracks: [Int: ExternalSubtitleTrack] = [:]
    private var nextExternalID = 1_000_000
    private var externalCues: [Int: [SubtitleCue]] = [:]
    private var subtitleTasks: [Int: Task<Void, Never>] = [:]
    private var trace: PlaybackTrialTrace?

    func load(url: URL, startPosition: Double = 0, options: LoadOptions = LoadOptions(),
              audioSourceStreamIndex: Int32? = nil) async throws {
        stop(resetDisplayCriteria: false)
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
        try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        try session.setActive(true)
        let instance = VividMPVCore()
        instance.matchContentEnabled = options.matchContentEnabled
        instance.headers = options.httpHeaders
        instance.startPosition = max(0, startPosition)
        instance.autoplay = options.autoplay
        instance.audioOnly = options.audioOnly
        instance.initialRate = requestedRate
        instance.initialVolume = volume
        instance.audioLanguages = options.preferredAudioLanguages
        let proxy = VividMPVDelegate(owner: self, generation: token)
        delegateProxy = proxy; instance.delegate = proxy
        core = instance
        guard instance.initialize(in: window, hostView: surface) else {
            let error = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "The mpv experiment could not initialise.")
            fail(error); throw error
        }
        surface.core = instance
        instance.sampleBufferDisplayLayer?.videoGravity = videoGravity
        instance.setVisible(true)
        instance.setLogLevel("warn")
        for (name, format) in Self.observations { instance.observeProperty(name, format: format) }
        videoRoute = options.audioOnly ? .audio : .sampleBuffer
        trace?.event("mpv_initialised", fields: "backend=plezy_mpv compressed_sink=avplayer pcm_sink=samplebuffer")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            instance.commandAsync(["loadfile", url.absoluteString, "replace"]) { result in
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
        let error = PlaybackErrorInfo(kind: .noPlayableTrackWithinBudget, message: "mpv did not open the source within 60 seconds.")
        fail(error); throw error
    }

    private static let observations: [(String, String)] = [
        ("time-pos", "double"), ("duration", "double"), ("pause", "flag"),
        ("paused-for-cache", "flag"), ("seeking", "flag"), ("eof-reached", "flag"),
        ("track-list", "node"), ("chapter-list", "node"), ("aid", "string"), ("sid", "string"),
        ("secondary-sid", "string"), ("video-params", "node"), ("video-out-params", "node"),
        ("audio-out-params", "node"), ("audio-codec-name", "string"), ("hwdec-current", "string"),
        ("container-fps", "double"), ("demuxer-cache-duration", "double"),
        ("avsync", "double"), ("frame-drop-count", "double")
    ]
    private var rawTracks: [[String: Any]] = []
    private var initialAudioApplied = false
    fileprivate func property(_ name: String, value: Any?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "time-pos": if let value = value as? Double, value.isFinite { clock.currentTime = value; updateExternalCues() }
        case "duration": duration = (value as? Double) ?? 0
        case "paused-for-cache": isBuffering = value as? Bool ?? false; updatePhase()
        case "seeking": isSeeking = value as? Bool ?? false; updatePhase()
        case "pause": wantsPlay = !(value as? Bool ?? true); updatePhase()
        case "eof-reached": if value as? Bool == true { state = .ended; playbackPhase = .ended; isBuffering = false }
        case "track-list": rawTracks = value as? [[String: Any]] ?? []; readTracks()
        case "chapter-list":
            mediaChapters = (value as? [[String: Any]] ?? []).enumerated().map {
                MediaChapter(id: $0.offset, name: $0.element["title"] as? String ?? "Chapter \($0.offset + 1)",
                             startSeconds: $0.element["time"] as? Double ?? 0)
            }
        case "aid": activeAudioTrackIndex = (value as? String).flatMap(Int.init)
        case "sid": if externalTracks[activeSubtitleTrackIndex ?? -1] == nil { activeSubtitleTrackIndex = (value as? String).flatMap(Int.init) }
        case "secondary-sid": if externalTracks[secondarySubtitleID ?? -1] == nil { secondarySubtitleID = (value as? String).flatMap(Int.init) }
        case "video-params":
            let info = value as? [String: Any] ?? [:]
            sourceVideoWidth = Int32(clamping: info["w"] as? Int64 ?? 0)
            sourceVideoHeight = Int32(clamping: info["h"] as? Int64 ?? 0)
            sourceVideoPixelAspectRatio = info["par"] as? Double ?? 1
            sourceVideoFormat = Self.format(info, dv: sourceDVProfile != nil)
        case "video-out-params":
            let info = value as? [String: Any] ?? [:]
            videoFormat = Self.format(info, dv: sourceDVProfile != nil && core?.hdrEnabled == true)
        case "audio-out-params":
            let info = value as? [String: Any] ?? [:]
            outputChannels = (info["channel-count"] as? Int64).map(Int.init)
            outputAudioFormat = info["format"] as? String
            trace?.event("mpv_audio_output", fields: "format=\(outputAudioFormat ?? "unknown") channels=\(outputChannels ?? 0) apple_mode=\(AVAudioSession.sharedInstance().renderingMode.rawValue)")
        case "audio-codec-name": audioDecoder = value as? String
        case "hwdec-current": videoDecoder = (value as? String).map { "mpv (\($0))" }
        case "container-fps": sourceVideoFrameRate = value as? Double
        case "demuxer-cache-duration", "avsync", "frame-drop-count":
            var stats = diagnostics.liveTelemetry ?? LiveTelemetry()
            if name == "demuxer-cache-duration" { stats.forwardBufferSeconds = value as? Double }
            if name == "avsync" { stats.avSyncGapMs = (value as? Double).map { $0 * 1000 } }
            if name == "frame-drop-count" { stats.droppedFrameCount = (value as? Double).map(Int.init) }
            diagnostics.liveTelemetry = stats
        default: break
        }
    }
    fileprivate func event(_ name: String, data: [String: Any]?, token: UInt64) {
        guard token == generation else { return }
        switch name {
        case "file-loaded": isSessionReady = true; startupProgress = nil; applyInitialAudioSelection(); updatePhase(); trace?.mark("mpv_file_loaded")
        case "playback-restart":
            hasFirstFrameReadyForDisplay = true; isSeeking = false; isBuffering = false
            updatePhase(); trace?.mark("mpv_playback_restart")
        case "end-file":
            if let code = data?["error"] as? Int {
                fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "mpv playback failed (\(code))."))
            } else if data?["reason"] as? Int == 0 { state = .ended; playbackPhase = .ended; isBuffering = false }
        // Raw mpv logs can contain authenticated URLs. Only structured, allowlisted diagnostics are persisted.
        default: break
        }
    }
    private func updatePhase() {
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
    private func readTracks() {
        func track(_ info: [String: Any]) -> TrackInfo {
            TrackInfo(id: Int(info["id"] as? Int64 ?? 0), name: info["title"] as? String ?? "",
                      codec: info["codec"] as? String ?? "", language: info["lang"] as? String,
                      channels: Int(info["demux-channel-count"] as? Int64 ?? 0),
                      isDefault: info["default"] as? Bool ?? false, isForced: info["forced"] as? Bool ?? false,
                      isExternal: info["external"] as? Bool ?? false, isNativelyRenderedSubtitle: true)
        }
        audioTracks = rawTracks.filter { $0["type"] as? String == "audio" }.map(track)
        subtitleTracks = rawTracks.filter { $0["type"] as? String == "sub" && $0["external"] as? Bool != true }.map(track)
        subtitleTracks += externalTracks.sorted { $0.key < $1.key }.map { id, t in
            TrackInfo(id: id, name: t.name ?? "External subtitles", language: t.language, isForced: t.isForced,
                      isExternal: true, isNativelyRenderedSubtitle: false)
        }
        videoTrack = rawTracks.first { $0["type"] as? String == "video" } ?? [:]
        sourceDVProfile = (videoTrack["dolby-vision-profile"] as? Int64).flatMap { $0 > 0 ? Int($0) : nil }
        if sourceDVProfile != nil { sourceVideoFormat = .dolbyVision }
        applyInitialAudioSelection()
    }
    private func applyInitialAudioSelection() {
        guard isSessionReady, !initialAudioApplied, !audioTracks.isEmpty, let source else { return }
        if let streamIndex = source.2 {
            guard let track = rawTracks.first(where: { $0["type"] as? String == "audio" && $0["ff-index"] as? Int64 == Int64(streamIndex) }),
                  let id = track["id"] as? Int64 else { return }
            selectAudioTrack(index: Int(id))
        } else if let ordinal = source.1.audioTrackOrdinal, audioTracks.indices.contains(ordinal) {
            selectAudioTrack(index: audioTracks[ordinal].id)
        }
        initialAudioApplied = true
    }
    func play() { wantsPlay = true; core?.setProperty("pause", value: "no"); updatePhase() }
    func pause() { wantsPlay = false; core?.setProperty("pause", value: "yes"); updatePhase() }
    func setRate(_ rate: Float) {
        requestedRate = rate
        core?.setProperty("speed", value: String(rate))
    }
    func seek(to seconds: Double) async {
        guard let core, seconds.isFinite else { return }
        let token = generation
        isSeeking = true; state = .seeking; updatePhase()
        core.command(["seek", String(max(0, duration > 0 ? min(seconds, duration) : seconds)), "absolute+exact"])
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled || token != generation || !isSeeking || errorInfo != nil { return }
        }
        fail(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "The mpv seek did not complete."))
    }
    func selectAudioTrack(index: Int) { core?.setProperty("aid", value: String(index)) }
    func selectSubtitleTrack(index: Int) {
        activeSubtitleTrackIndex = index
        core?.setProperty("sid", value: externalTracks[index] == nil ? String(index) : "no")
        updateExternalCues()
    }
    func selectSecondarySubtitleTrack(index: Int) {
        secondarySubtitleID = index
        core?.setProperty("secondary-sid", value: externalTracks[index] == nil ? String(index) : "no")
        updateExternalCues()
    }
    func clearSubtitle() { activeSubtitleTrackIndex = nil; core?.setProperty("sid", value: "no"); subtitleCues = [] }
    func clearSecondarySubtitle() { secondarySubtitleID = nil; core?.setProperty("secondary-sid", value: "no"); secondarySubtitleCues = [] }
    private func updateExternalCues() {
        subtitleCues = (externalCues[activeSubtitleTrackIndex ?? -1] ?? []).filter { $0.startTime <= currentTime && currentTime < $0.endTime }
        secondarySubtitleCues = (externalCues[secondarySubtitleID ?? -1] ?? []).filter { $0.startTime <= currentTime && currentTime < $0.endTime }
    }
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = externalTracks.first(where: { $0.value == track })?.key ?? nextExternalID
        if externalTracks[id] == nil {
            nextExternalID += 1; externalTracks[id] = track; readTracks()
            let token = generation
            isLoadingSubtitles = true
            subtitleTasks[id] = Task { @MainActor [weak self] in
                do {
                    let document = try await VividSubtitleLoader.load(track)
                    guard let self, generation == token, !Task.isCancelled else { return }
                    if case .cues(let cues) = document { externalCues[id] = cues }
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
    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool { false }
    func reloadAtCurrentPosition() async throws {
        guard let source else { return }
        var options = source.1; options.autoplay = wantsPlay
        if let fresh = await refreshSourceHeaders?() { options.httpHeaders = fresh }
        try await load(url: source.0, startPosition: currentTime, options: options, audioSourceStreamIndex: source.2)
    }
    func prepareForItemReplacement() { pause(); hasFirstFrameReadyForDisplay = false }
    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        generation &+= 1
        core?.delegate = nil; core?.dispose(preserveDisplayCriteria: !resetDisplayCriteria)
        core = nil; delegateProxy = nil; surface.core = nil; source = nil
        trace?.event("mpv_stopped"); trace = nil
        state = .idle; playbackPhase = .idle; videoRoute = .none
        isSessionReady = false; isSeeking = false; isBuffering = false
        hasFirstFrameReadyForDisplay = false; errorInfo = nil; startupProgress = nil
        clock.currentTime = 0; duration = 0; audioTracks = []; subtitleTracks = []; mediaChapters = []
        initialAudioApplied = false
        rawTracks = []; videoTrack = [:]; externalTracks = [:]; externalCues = [:]
        for task in subtitleTasks.values { task.cancel() }; subtitleTasks = [:]
        isLoadingSubtitles = false; subtitleCues = []; secondarySubtitleCues = []
        activeAudioTrackIndex = nil; activeSubtitleTrackIndex = nil; secondarySubtitleID = nil
        sourceVideoWidth = 0; sourceVideoHeight = 0; sourceVideoBitrate = 0; sourceVideoFrameRate = nil
        sourceVideoPixelAspectRatio = 1; sourceDVProfile = nil; sourceVideoFormat = .sdr; videoFormat = .sdr
        outputChannels = nil; outputAudioFormat = nil; videoDecoder = nil; audioDecoder = nil
        diagnostics.liveTelemetry = nil
        if deactivatesAudioSessionOnStop { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func fail(_ error: PlaybackErrorInfo) {
        core?.setProperty("pause", value: "yes")
        errorInfo = error; state = .error(error.message); playbackPhase = .error(error.message)
        isBuffering = false; isSeeking = false; trace?.event("mpv_failed", fields: "kind=\(error.kind.rawValue)")
    }
    func setNativeSubtitleRendering(_ active: Bool) {}
    func updateNativeMetadata(title: String, artwork: MPMediaItemArtwork?) {}
    func makeFrameExtractor(url: URL, httpHeaders: [String: String]) -> FrameExtractor? { nil }
}

private final class VividMPVCore: MpvPlayerCore {
    var headers: [String: String] = [:]
    var startPosition: Double = 0
    var autoplay = true
    var audioOnly = false
    var initialRate: Float = 1
    var initialVolume: Float = 1
    var audioLanguages: [String] = []
    override func configurePlatformMpvOptions(mpv: OpaquePointer) {
        let settings = ["ao": "avfoundation", "audio-spdif": "ac3,eac3",
                        "audio-exclusive": "yes", "audio-channels": "auto-safe",
                        "config": "no", "input-default-bindings": "no", "input-vo-keyboard": "no",
                        "osc": "no", "osd-level": "0", "pause": autoplay ? "no" : "yes",
                        "start": String(startPosition), "speed": String(initialRate),
                        "volume": String(initialVolume * 100), "sid": "no", "secondary-sid": "no",
                        "cache": "yes", "demuxer-max-bytes": "67108864", "demuxer-max-back-bytes": "16777216",
                        "alang": audioLanguages.joined(separator: ","), "terminal": "no"]
        for (name, value) in settings { checkError(mpv_set_option_string(mpv, name, value)) }
        if audioOnly { checkError(mpv_set_option_string(mpv, "vid", "no")) }
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
                    checkError(mpv_set_option(mpv, "http-header-fields", MPV_FORMAT_NODE, &node))
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
