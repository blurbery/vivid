// SPDX-License-Identifier: Apache-2.0
#if os(tvOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
import CoreMedia
import MediaPlayer
import OSLog
import SwiftUI
import VividKit

/// The experimental tvOS backend. Vivid retains its session and reporting boundary;
/// one Aether session owns decoding, rendering, audio and transport.
@MainActor
final class VividEngine: ObservableObject {
    static let externalSubtitleTrackIDBase = 1_000_000
    let backend: AetherEngine
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
    var nativePlayerLayer: AVPlayerLayer? { backend.nativePlayerLayer }
    var activeAudioTrackIndex: Int? { backend.activeAudioTrackIndex }
    var isSubtitleActive: Bool { backend.isSubtitleActive }
    var isSecondarySubtitleActive: Bool { backend.isSecondarySubtitleActive }
    var nativeSubtitleTracks: [TrackInfo] { subtitleTracks.filter { !$0.isExternal } }
    var currentTime: Double { clock.currentTime }
    var isSeeking: Bool { backend.isSeeking }
    var isSessionReady: Bool { backend.isSessionReady }
    var sourceVideoWidth: Int32 { backend.sourceVideoWidth }
    var sourceVideoHeight: Int32 { backend.sourceVideoHeight }
    var sourceVideoPixelAspectRatio: Double { backend.sourceVideoPixelAspectRatio }
    var sourceVideoFrameRate: Double? { backend.sourceVideoFrameRate }
    var sourceVideoBitrate: Int64 { backend.sourceVideoBitrate }
    var sourceDVProfile: Int? { backend.sourceDVProfile }
    var sourceVideoFormat: VideoFormat { Self.format(backend.sourceVideoFormat) }
    var videoFormat: VideoFormat { Self.format(backend.videoFormat) }
    var activeVideoDecoder: String? { backend.activeVideoDecoder }
    var activeAudioDecoder: String? { backend.activeAudioDecoder }
    var softwareDisplaySize: CGSize? { backend.softwareDisplaySize }
    var readAheadAvailableSeconds: Double? {
        guard videoRoute == .loopback, backend.isSessionReady, !backend.isLive, !backend.isSeeking else { return nil }
        let frontier = backend.clock.bufferedPosition
        let position = backend.clock.currentTime
        guard frontier.isFinite, position.isFinite else { return nil }
        return max(0, frontier - position)
    }
    var liveTelemetry: LiveTelemetry? { diagnostics.liveTelemetry }
    var backgroundPlaybackEnabled: Bool {
        get { backend.backgroundPlaybackEnabled }
        set { backend.backgroundPlaybackEnabled = newValue }
    }
    var pictureInPictureActive: Bool {
        get { backend.pictureInPictureActive }
        set { backend.pictureInPictureActive = newValue; scheduleSubtitleHandoff() }
    }
    var deactivatesAudioSessionOnStop: Bool {
        get { backend.deactivatesAudioSessionOnStop }
        set { backend.deactivatesAudioSessionOnStop = newValue }
    }
    var ownsVideoNowPlayingSession: Bool {
        get { backend.ownsVideoNowPlayingSession }
        set { backend.ownsVideoNowPlayingSession = newValue }
    }
    var videoNowPlayingSession: MPNowPlayingSession? { backend.videoNowPlayingSession }
    var volume: Float {
        get { backend.volume }
        set { backend.volume = newValue }
    }
    var videoGravity: AVLayerVideoGravity {
        get { backend.videoGravity }
        set { backend.videoGravity = newValue; surfaceController?.refreshGravity() }
    }
    // Credential renewal remains with Vivid's existing generation-fenced reload.
    var transientRecoveryBudget: VividTransientRecoveryBudget?
    var refreshSourceHeaders: (@Sendable () async -> [String: String]?)?
    weak var surfaceController: VividAetherPlayerController?
    private var metadataTitle: String?
    private var metadataArtwork: MPMediaItemArtwork?
    private weak var outgoingNativeItem: AVPlayerItem?
    private var subscriptions = Set<AnyCancellable>()
    private var externalOffsets: [Int: Double] = [:]
    private var secondarySubtitleID: Int?
    private var externalVideoPlaybackActive = false
    private var nativeSubtitleRenderingActive = false
    private var subtitleHandoffTask: Task<Void, Never>?
    private var subtitleHandoff = VividNativeSubtitleHandoff()
    private var startedAt: ContinuousClock.Instant?
    private static let log = Logger(subsystem: "com.blurbery.vivid", category: "PlaybackStartup")

    init() throws {
        backend = try AetherEngine()
        backend.$state.sink { [weak self] value in
            guard let self else { return }
            switch value {
            case .idle: self.state = .idle
            case .loading: self.state = .loading
            case .playing: self.state = .playing
            case .paused: self.state = .paused
            case .seeking: self.state = .seeking
            case .ended: self.state = .ended
            case .error(let message): self.state = .error(message)
            }
        }.store(in: &subscriptions)
        backend.$playbackPhase.sink { [weak self] value in
            guard let self else { return }
            switch value {
            case .idle: self.playbackPhase = .idle
            case .loading: self.playbackPhase = .loading
            case .playing: self.playbackPhase = .playing
            case .paused: self.playbackPhase = .paused
            case .seeking: self.playbackPhase = .seeking
            case .rebuffering: self.playbackPhase = .rebuffering
            case .stalled(let reconnecting): self.playbackPhase = .stalled(reconnecting: reconnecting)
            case .ended: self.playbackPhase = .ended
            case .error(let message): self.playbackPhase = .error(message)
            }
        }.store(in: &subscriptions)
        backend.clock.$currentTime.sink { [weak self] in self?.clock.currentTime = $0 }.store(in: &subscriptions)
        backend.$duration.sink { [weak self] in self?.duration = $0 }.store(in: &subscriptions)
        backend.$isBuffering.sink { [weak self] in self?.isBuffering = $0 }.store(in: &subscriptions)
        backend.$isLoadingSubtitles.sink { [weak self] in self?.isLoadingSubtitles = $0 }.store(in: &subscriptions)
        backend.$hasFirstFrameReadyForDisplay.sink { [weak self] ready in
            guard let self else { return }
            // AVKit owns the native render layer. Aether's software renderer
            // remains authoritative only when there is no native AVPlayer.
            if !ready { self.hasFirstFrameReadyForDisplay = false }
            else if self.backend.currentAVPlayer == nil { self.hasFirstFrameReadyForDisplay = true }
        }.store(in: &subscriptions)
        backend.$errorInfo.sink { [weak self] value in
            self?.errorInfo = value.map { error in
                let kind = PlaybackErrorInfo.Kind(rawValue: error.kind.rawValue)
                    ?? (["sourceOpenFailed", "sourceCertificateRejected", "customSourceProbeFailed"].contains(error.kind.rawValue)
                        ? .sourceRefused : .softwarePipelineFailed)
                return PlaybackErrorInfo(kind: kind, message: error.message,
                    underlyingDomain: error.underlyingDomain, underlyingCode: error.underlyingCode)
            }
        }.store(in: &subscriptions)
        backend.$startupProgress.sink { [weak self] value in
            guard let self else { return }
            self.startupProgress = value.map { StartupProgress(checkpoint: String(describing: $0.checkpoint)) }
            if let value, let startedAt = self.startedAt {
                let elapsed = startedAt.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                Self.log.info("Aether startup checkpoint=\(String(describing: value.checkpoint), privacy: .public) elapsed=\(seconds, privacy: .public)s")
            }
        }.store(in: &subscriptions)
        backend.$audioTracks.sink { [weak self] in self?.audioTracks = $0.map(Self.track) }.store(in: &subscriptions)
        backend.$subtitleTracks.sink { [weak self] in self?.subtitleTracks = $0.map(Self.track) }.store(in: &subscriptions)
        backend.$mediaChapters.sink { [weak self] in
            self?.mediaChapters = $0.map { MediaChapter(id: $0.id, name: $0.name, startSeconds: $0.startSeconds) }
        }.store(in: &subscriptions)
        backend.$subtitleCues.sink { [weak self] cues in
            guard let self else { return }
            self.subtitleCues = self.nativeSubtitleRenderingActive ? [] : cues.map { self.convertCue($0, trackID: self.backend.activeSubtitleTrackIndex) }
        }.store(in: &subscriptions)
        backend.$secondarySubtitleCues.sink { [weak self] cues in
            guard let self else { return }
            self.secondarySubtitleCues = self.nativeSubtitleRenderingActive ? [] : cues.map { self.convertCue($0, trackID: self.secondarySubtitleID) }
        }.store(in: &subscriptions)
        backend.$activeSubtitleTrackIndex.sink { [weak self] in self?.activeSubtitleTrackIndex = $0; self?.scheduleSubtitleHandoff() }.store(in: &subscriptions)
        backend.$currentAVPlayer.sink { [weak self] in self?.currentAVPlayer = $0 }.store(in: &subscriptions)
        backend.$currentAVPlayerItem.sink { [weak self] in self?.currentAVPlayerItem = $0; self?.scheduleSubtitleHandoff() }.store(in: &subscriptions)
        backend.$videoRoute.sink { [weak self] value in
            switch value {
            case .none: self?.videoRoute = .none
            case .remoteBypass: self?.videoRoute = .remoteBypass
            case .loopback: self?.videoRoute = .loopback
            case .software: self?.videoRoute = .sampleBuffer
            case .audio: self?.videoRoute = .audio
            }
        }.store(in: &subscriptions)
        backend.$isSessionReady.sink { [weak self] _ in self?.scheduleSubtitleHandoff() }.store(in: &subscriptions)
        backend.$nativeSubtitleRenditionsServed.sink { [weak self] _ in self?.scheduleSubtitleHandoff() }.store(in: &subscriptions)
        backend.$softwarePiPSource.sink { [weak self] source in
            guard let self else { return }
            self.softwarePiPSource = source.map { SampleBufferPiPSource(layer: $0.layer, engine: self) }
        }.store(in: &subscriptions)
        backend.systemCaptionRequest.sink { [weak self] in
            self?.systemCaptionRequest.send(SystemCaptionRequest(language: $0.language))
        }.store(in: &subscriptions)
        backend.diagnostics.$liveTelemetry.sink { [weak self] in
            self?.diagnostics.liveTelemetry = $0.map(Self.telemetry)
        }.store(in: &subscriptions)
    }

    func updateNativeMetadata(title: String, artwork: MPMediaItemArtwork?) {
        guard metadataTitle != title || metadataArtwork !== artwork else { return }
        metadataTitle = title
        metadataArtwork = artwork
        let name = AVMutableMetadataItem()
        name.identifier = .commonIdentifierTitle
        name.value = title as NSString
        name.extendedLanguageTag = "und"
        var items: [AVMetadataItem] = [name]
        if let data = artwork?.image(at: CGSize(width: 600, height: 600))?.jpegData(compressionQuality: 0.85) {
            let cover = AVMutableMetadataItem()
            cover.identifier = .commonIdentifierArtwork
            cover.value = data as NSData
            cover.extendedLanguageTag = "und"
            items.append(cover)
        }
        backend.setExternalMetadata(items)
    }

    func nativePictureReady(item: AVPlayerItem) {
        guard backend.currentAVPlayer?.currentItem === item,
              VividNativeFrameReadiness.accepts(item: item, current: backend.currentAVPlayerItem,
                                               outgoing: outgoingNativeItem,
                                               alreadyPresented: hasFirstFrameReadyForDisplay) else { return }
        hasFirstFrameReadyForDisplay = true
        if let startedAt {
            let elapsed = startedAt.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            Self.log.info("AVKit first picture elapsed=\(seconds, privacy: .public)s")
        }
    }

    func updateSourceHeaders(_ headers: [String: String], for url: URL) -> Bool { false }

    var preferLosslessAudio = false

    func load(url: URL, startPosition: Double = 0, options: LoadOptions = LoadOptions(),
              audioSourceStreamIndex: Int32? = nil) async throws {
        outgoingNativeItem = backend.currentAVPlayerItem
        hasFirstFrameReadyForDisplay = false
        externalOffsets = Dictionary(uniqueKeysWithValues: options.externalSubtitles.enumerated().map {
            (Self.externalSubtitleTrackIDBase + $0.offset, $0.element.nativeTimelineOffsetSeconds)
        })
        subtitleHandoff.reset()
        nativeSubtitleRenderingActive = false
        secondarySubtitleID = nil
        startedAt = .now
        var prepared = VividAetherTypes.Options()
        prepared.httpHeaders = options.httpHeaders
        prepared.audioBridgeMode = preferLosslessAudio ? .lossless : .surroundCompat
        prepared.matchContentEnabled = options.matchContentEnabled
        prepared.panelIsInHDRMode = options.panelIsInHDRMode
        prepared.audioOnly = options.audioOnly
        prepared.nativeRemoteHLS = options.nativeRemoteHLS || url.pathExtension.lowercased() == "m3u8"
        prepared.preserveASSMarkup = options.preserveASSMarkup
        // Offset sidecars use Vivid's overlay axis; do not advertise unshifted native renditions.
        prepared.prepareNativeSubtitles = options.prepareNativeSubtitles && externalOffsets.values.allSatisfy { $0 == 0 }
        // Prepare receiver-readable captions alongside the fullscreen overlay.
        prepared.eagerNativeSubtitleReaders = prepared.prepareNativeSubtitles
        prepared.nativeSubtitlePreferredLanguages = options.nativeSubtitlePreferredLanguages
        prepared.preferredAudioLanguages = options.preferredAudioLanguages
        prepared.preferredSubtitleLanguages = options.preferredSubtitleLanguages
        prepared.externalSubtitles = options.externalSubtitles.map(Self.external)
        prepared.forwardBufferSegments = options.forwardBufferSegments
        prepared.autoplay = options.autoplay
        prepared.audioTrackOrdinal = options.audioTrackOrdinal
        // Match Vivid's existing probe budget. These limit media analysis, not wall-clock waits.
        prepared.probesize = 2 * 1024 * 1024
        prepared.maxAnalyzeDuration = 2 * 1_000_000
        do {
            try await backend.load(url: url, startPosition: startPosition, options: prepared,
                                   audioSourceStreamIndex: audioSourceStreamIndex)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let errorInfo { throw errorInfo }
            throw error
        }
    }

    func play() { backend.play() }
    func pause() { backend.pause() }
    func setRate(_ rate: Float) { backend.setRate(rate) }
    func seek(to seconds: Double) async { await backend.seek(to: seconds) }
    func selectAudioTrack(index: Int) { backend.selectAudioTrack(index: index) }
    func reloadAtCurrentPosition() async throws { try await backend.reloadAtCurrentPosition() }
    func prepareForItemReplacement() {
        outgoingNativeItem = backend.currentAVPlayerItem
        hasFirstFrameReadyForDisplay = false
        backend.prepareForItemReplacement()
    }
    func stop(resetDisplayCriteria: Bool = true, finalTeardown: Bool? = nil) {
        startedAt = nil
        subtitleHandoffTask?.cancel()
        subtitleHandoffTask = nil
        subtitleHandoff.reset()
        externalVideoPlaybackActive = false
        nativeSubtitleRenderingActive = false
        backend.stop(resetDisplayCriteria: resetDisplayCriteria, finalTeardown: finalTeardown)
    }
    @discardableResult
    func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let result = Self.track(backend.addExternalSubtitleTrack(Self.external(track)))
        externalOffsets[result.id] = track.nativeTimelineOffsetSeconds
        return result
    }
    func clearSubtitle() { backend.clearSubtitle() }
    func clearSecondarySubtitle() { secondarySubtitleID = nil; backend.clearSecondarySubtitle() }
    func selectSubtitleTrack(index: Int) { backend.selectSubtitleTrack(index: index) }
    func selectSecondarySubtitleTrack(index: Int) { secondarySubtitleID = index; backend.selectSecondarySubtitleTrack(index: index) }
    func setNativeSubtitleRendering(_ active: Bool) {
        externalVideoPlaybackActive = active
        scheduleSubtitleHandoff()
    }

    private func scheduleSubtitleHandoff() {
        subtitleHandoffTask?.cancel()
        // Published values arrive before their properties change. Read the settled
        // item and track together, also coalescing internal reload publications.
        subtitleHandoffTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.syncSubtitleHandoff()
        }
    }

    private func syncSubtitleHandoff() {
        guard backend.isSessionReady, let item = backend.currentAVPlayerItem else { return }
        // Remote HLS owns its own legible group. Only generated renditions
        // participate in this handoff; shifted sidecars remain overlay-only.
        guard videoRoute == .loopback, backend.nativeSubtitleRenditionsServed else {
            subtitleHandoff.reset()
            restoreSubtitleOverlay()
            return
        }
        let active = externalVideoPlaybackActive || backend.pictureInPictureActive
        guard subtitleHandoff.needsUpdate(item: item, track: backend.activeSubtitleTrackIndex,
                                          active: active) else { return }
        if active {
            item.textStyleRules = nil
        } else if let transparent = AVTextStyleRule(textMarkupAttributes: [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_BackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0],
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.0, 0.0, 0.0, 0.0]
        ]) {
            item.textStyleRules = [transparent]
        }
        backend.setNativeSubtitleRendering(active)
        nativeSubtitleRenderingActive = active
        if active {
            subtitleCues = []
            secondarySubtitleCues = []
        } else {
            restoreSubtitleOverlay()
        }
    }

    private func restoreSubtitleOverlay() {
        nativeSubtitleRenderingActive = false
        subtitleCues = backend.subtitleCues.map { convertCue($0, trackID: backend.activeSubtitleTrackIndex) }
        secondarySubtitleCues = backend.secondarySubtitleCues.map { convertCue($0, trackID: secondarySubtitleID) }
    }
    func makeFrameExtractor(url: URL, httpHeaders: [String: String]) -> FrameExtractor? {
        FrameExtractor(url: url, headers: httpHeaders)
    }

    private static func format(_ value: VividAetherTypes.Video) -> VideoFormat {
        switch value {
        case .sdr: return .sdr
        case .hdr10: return .hdr10
        case .hdr10Plus: return .hdr10Plus
        case .dolbyVision: return .dolbyVision
        case .hlg: return .hlg
        }
    }
    private static func track(_ value: VividAetherTypes.Track) -> TrackInfo {
        TrackInfo(id: value.id, name: value.name, codec: value.codec, language: value.language,
                  channels: value.channels, bitrate: value.bitrate, isDefault: value.isDefault,
                  isForced: value.isForced, isHearingImpaired: value.isHearingImpaired,
                  isCommentary: value.isCommentary, isAtmos: value.isAtmos, assHeader: value.assHeader,
                  isExternal: value.isExternal, isNativelyRenderedSubtitle: value.isNativelyRenderedSubtitle)
    }
    private static func external(_ value: ExternalSubtitleTrack) -> VividAetherTypes.External {
        VividAetherTypes.External(url: value.url, name: value.name, language: value.language,
            isForced: value.isForced, isHearingImpaired: value.isHearingImpaired, isDefault: value.isDefault,
            httpHeaders: value.httpHeaders, formatHint: value.formatHint, sourceStreamIndex: value.sourceStreamIndex)
    }
    private func convertCue(_ value: VividAetherTypes.Cue, trackID: Int?) -> SubtitleCue {
        let converted = Self.cue(value)
        let offset = trackID.flatMap { externalOffsets[$0] } ?? 0
        return SubtitleCue(id: converted.id, startTime: converted.startTime - offset,
            endTime: converted.endTime - offset, body: converted.body, placement: converted.placement)
    }
    private static func cue(_ value: VividAetherTypes.Cue) -> SubtitleCue {
        let body: SubtitleCue.Body
        switch value.body {
        case .text(let text): body = .text(text)
        case .image(let image): body = .image(SubtitleImage(cgImage: image.cgImage, position: image.position, canvasSize: image.canvasSize))
        case .richText(let runs): body = .richText(runs.map {
            SubtitleTextRun(text: $0.text, color: $0.color.map { SubtitleColor(r: $0.r, g: $0.g, b: $0.b) },
                isBold: $0.isBold, isItalic: $0.isItalic, isUnderlined: $0.isUnderlined,
                isStruckThrough: $0.isStruckThrough, fontName: $0.fontName, fontSize: $0.fontSize.map(Double.init))
        })
        }
        return SubtitleCue(id: value.id, startTime: value.startTime, endTime: value.endTime, body: body,
            placement: value.placement.map { SubtitleTextPlacement(alignment: $0.alignment, position: $0.position) })
    }
    private static func telemetry(_ value: VividAetherTypes.Telemetry) -> LiveTelemetry {
        LiveTelemetry(forwardBufferSeconds: value.forwardBufferSeconds, displayCushionSeconds: value.displayCushionSeconds,
            readerWindowAheadBytes: value.readerWindowAheadBytes, observedFps: value.observedFps,
            droppedFrameCount: value.droppedFrameCount, accumulatedFrameDelaySeconds: value.accumulatedFrameDelaySeconds,
            avSyncGapMs: value.avSyncGapMs, instantBitrateMbps: value.instantBitrateMbps,
            averageBitrateMbps: value.averageBitrateMbps, audioBridgeBitrateMbps: value.audioBridgeBitrateMbps,
            networkThroughputMbps: value.networkThroughputMbps, networkTransferredBytes: value.networkTransferredBytes,
            cachedBytes: value.cachedBytes, demuxerBytesFetched: value.demuxerBytesFetched,
            producerRestartCount: value.producerRestartCount, rssMb: value.rssMb)
    }
}

/// Vivid owns loading presentation. Suppress only UIKit activity indicators
/// within this native host, retaining AVKit's playback and system integration.
@MainActor
final class VividNativePlayerViewController: AVPlayerViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Scope appearance to this host; other app progress indicators keep
        // their normal appearance. Layout also covers late-created indicators.
        UIActivityIndicatorView.appearance(whenContainedInInstancesOf: [VividNativePlayerViewController.self]).color = .clear
        suppressActivityIndicators(in: view)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        suppressActivityIndicators(in: view)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        suppressActivityIndicators(in: view)
    }

    private func suppressActivityIndicators(in container: UIView) {
        for child in container.subviews {
            if let indicator = child as? UIActivityIndicatorView {
                indicator.alpha = 0
                indicator.isAccessibilityElement = false
            } else {
                suppressActivityIndicators(in: child)
            }
        }
    }
}

/// One persistent controller survives fullscreen, countdown preview and the
/// next-episode swap. Native and software pictures have separate render hosts.
@MainActor
final class VividAetherPlayerController: UIViewController {
    private let native = VividNativePlayerViewController()
    private let software = AetherPlayerView(frame: .zero)
    private weak var engine: VividEngine?
    private var subscriptions = Set<AnyCancellable>()
    private var readyObservation: NSKeyValueObservation?
    private var softwareBound = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        native.showsPlaybackControls = true
        native.playbackControlsIncludeTransportBar = false
        native.playbackControlsIncludeInfoViews = false
        native.contextualActions = []
        native.appliesPreferredDisplayCriteriaAutomatically = false
        native.allowsPictureInPicturePlayback = false
        addChild(native)
        native.view.frame = view.bounds
        native.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Vivid's existing SwiftUI controls remain the sole focus/input owner.
        native.view.isUserInteractionEnabled = false
        view.addSubview(native.view)
        native.didMove(toParent: self)
        software.frame = view.bounds
        software.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        software.isUserInteractionEnabled = false
        view.addSubview(software)
        software.isHidden = true
        readyObservation = native.observe(\.isReadyForDisplay, options: [.new]) { [weak self] controller, _ in
            guard controller.isReadyForDisplay, let item = controller.player?.currentItem else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.native.player?.currentItem === item else { return }
                self.engine?.nativePictureReady(item: item)
            }
        }
    }

    func bind(engine: VividEngine) {
        loadViewIfNeeded()
        guard self.engine !== engine else { refreshGravity(); return }
        unbind()
        self.engine = engine
        engine.surfaceController = self
        // Deliver after @Published stores the new value. Nil must clear AVKit
        // on software fallback, including a retained player's item replacement.
        Publishers.Merge3(engine.$currentAVPlayer.map { _ in () },
                          engine.$currentAVPlayerItem.map { _ in () },
                          engine.$videoRoute.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshPlayer() }
            .store(in: &subscriptions)
        engine.$isBuffering
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPlayer() }
            .store(in: &subscriptions)
        refreshPlayer()
    }

    private func refreshPlayer() {
        guard let engine else { return }
        let player = engine.currentAVPlayer
        if native.player !== player { native.player = player }
        let useSoftware = engine.videoRoute == .sampleBuffer
        if useSoftware && !softwareBound {
            engine.backend.bind(view: software)
            softwareBound = true
        } else if !useSoftware && softwareBound {
            engine.backend.unbind(view: software)
            softwareBound = false
        }
        software.isHidden = !useSoftware
        native.view.isHidden = useSoftware
        refreshGravity()
        if let player, let item = player.currentItem,
           player.isExternalPlaybackActive && item.status == .readyToPlay {
            engine.nativePictureReady(item: item)
        }
    }

    func refreshGravity() {
        if let engine { native.videoGravity = engine.videoGravity }
    }

    func unbind() {
        subscriptions.removeAll()
        if softwareBound { engine?.backend.unbind(view: software) }
        softwareBound = false
        if engine?.surfaceController === self { engine?.surfaceController = nil }
        engine = nil
        native.player = nil
    }
}

struct VividPlayerSurface: UIViewControllerRepresentable {
    @ObservedObject var engine: VividEngine
    func makeUIViewController(context: Context) -> VividAetherPlayerController {
        let controller = VividAetherPlayerController()
        controller.bind(engine: engine)
        return controller
    }
    func updateUIViewController(_ controller: VividAetherPlayerController, context: Context) {
        controller.bind(engine: engine)
    }
    static func dismantleUIViewController(_ controller: VividAetherPlayerController, coordinator: ()) {
        controller.unbind()
    }
}
#endif
