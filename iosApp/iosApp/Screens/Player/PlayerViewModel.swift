import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// The player's state, shared by the iPhone, iPad and Apple TV player screens.
///
/// This file holds the stored state, `init` and teardown. Behaviour lives in
/// the `PlayerViewModel+<Area>.swift` extensions beside it: loading
/// (`+SessionLoad`, `+VividLoad`), engine events (`+EngineEvents`), recovery
/// (`+Recovery`), the end of an item (`+PlaybackEnd`), progress
/// (`+Progress`), and the controls, tracks, Next Up and other areas.
@MainActor
@Observable
class PlayerViewModel {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Player"
    )

    // MARK: Engine and load epochs

    @ObservationIgnored
    var vividPlaybackController: VividPlaybackController!
    /// The load whose events the player accepts. Cleared the moment a new
    /// load starts, so nothing late from the outgoing item lands on it.
    @ObservationIgnored
    var activeVividLoadEpoch: VividPlaybackController.LoadEpoch?
    /// The epoch whose `finishLoad` has returned, so its engine startup ran to
    /// completion and its decode route is settled.
    ///
    /// The engine publishes its track inventory during startup, several
    /// steps before it puts the source on a backend. Applying a deferred
    /// track pick then makes the engine rebuild its pipeline against a route
    /// it hasn't chosen yet: on a software-decoded source (VC-1, AV1) the
    /// rebuild lands on the native path, which refuses the codec, kills the
    /// load and leaves a spinner. Nothing that drives the engine off a
    /// pending selection may run before this is set for the current epoch.
    @ObservationIgnored
    var establishedVividLoadEpoch: VividPlaybackController.LoadEpoch?
    /// The epoch whose Silo plan transition has committed.
    @ObservationIgnored
    var committedProtocolV3LoadEpoch: VividPlaybackController.LoadEpoch?
    /// A first frame seen before its Silo plan committed, reported once it does.
    @ObservationIgnored
    var pendingProtocolV3FirstFrameEpoch: VividPlaybackController.LoadEpoch?
    /// The latest seek reanchor asked for while a replan was running.
    @ObservationIgnored
    var pendingProtocolV3SeekReanchorPosition: Double?
    /// The load epoch whose startup milestone has run. Video loads reach it
    /// on the first frame; audio-only loads have no picture and reach it when
    /// the audio route starts playing. Both go through one latch per epoch,
    /// so a load can never take the milestone twice.
    @ObservationIgnored
    var startedVividLoadEpoch: VividPlaybackController.LoadEpoch?
    /// Next Up and On Deck for the current item are fetched at its startup
    /// milestone, not while the stream is still opening.
    @ObservationIgnored
    var nextUpPrefetchPending = false
    /// A track change the viewer made while a replan was already running.
    /// Sent once that replan settles, so the selection the UI already shows
    /// is applied by the server. The position is read when it's sent, since
    /// playback moved on meanwhile.
    @ObservationIgnored
    var pendingProtocolV3TrackChange: QueuedProtocolV3TrackChange?
    @ObservationIgnored
    var scrubPreviewProvider: VividScrubPreviewProvider!
    @MainActor var vividEngine: VividEngine { vividPlaybackController.engine }
    var hasActiveVividSession: Bool {
        vividPlaybackController.activeSpec != nil
    }

    /// Tears the engine load down. The scrub preview reader shares its
    /// lifetime, and the returned task finishes once that reader has shut
    /// down, for callers that own the final teardown. A replacement keeps the
    /// engine's display and audio hand-off and this item's OpenSubtitles files.
    @discardableResult
    func disposeVividPlayback(forReplacement: Bool = false) -> Task<Void, Never>? {
        let previewShutdown = scrubPreviewProvider.endSession()
        isLoadingSubtitles = false
        activeVividLoadEpoch = nil
        establishedVividLoadEpoch = nil
        committedProtocolV3LoadEpoch = nil
        pendingProtocolV3FirstFrameEpoch = nil
        pendingProtocolV3SeekReanchorPosition = nil
        pendingProtocolV3TrackChange = nil
        if forReplacement {
            vividPlaybackController.prepareForReplacement()
        } else {
            vividPlaybackController.dispose()
        }
        #if os(iOS) || os(tvOS)
        if !forReplacement { removeOpenSubtitleFiles(openSubtitleFiles.clear()) }
        #endif
        return previewShutdown
    }

    // MARK: Playback state

    var isPlaying = false
    var currentTime: Double = 0 {
        didSet {
            guard currentTime != oldValue else { return }
            refreshSkipWindow()
            refreshCurrentChapter()
        }
    }
    var duration: Double = 0 {
        didSet {
            if duration != oldValue { applyLoadedIntroDBSegments() }
        }
    }
    var title: String = ""
    var isLoading = true
    var isBuffering = false
    var isLoadingSubtitles = false
    /// Fill progress (0 to 100) towards the point buffering resumes; nil when
    /// not buffering or when the engine doesn't report it.
    var bufferingProgress: Double?
    var error: String?
    var showControls = false {
        didSet {
            #if os(iOS)
            // The player shows the controls itself when a video ends, and
            // Next Up hides them straight away. That isn't the viewer's
            // doing, so it isn't recorded.
            let cause = pendingControlsCause ?? .other
            if showControls != oldValue, cause != .playbackEnded {
                PlaybackSessionRecorder.shared.controlsChanged(visible: showControls, cause: cause.rawValue)
            }
            if showControls && !oldValue {
                controlsAppearedAt = ProcessInfo.processInfo.systemUptime
            }
            #endif
            pendingControlsCause = nil
        }
    }
    /// What is about to change `showControls`, for the Latest Playback
    /// report. Set only by `setControlsVisible` and cleared on every set.
    @ObservationIgnored var pendingControlsCause: PlayerControlsCause?
    #if os(iOS)
    /// System uptime when the controls last went from hidden to visible.
    /// Presses while they're already up don't move it.
    @ObservationIgnored var controlsAppearedAt: TimeInterval?
    var shouldShowMobilePlayerChrome: Bool {
        // Loading and Next Up must not reveal the player chrome on their own.
        // Close and rotation follow the same tap and auto-hide state as the
        // transport.
        showControls
    }
    #endif
    var activeNotice: PlayerNotice?
    var remoteDismissToken: UUID?

    // MARK: Tracks, chapters and markers

    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    /// The preferred subtitle language for the current item, read when it
    /// loads. Used only to float that language's group to the top of the
    /// track lists.
    var subtitleOrderingLanguage: String?
    var chapters: [PlayerChapterInfo] = [] { didSet { refreshCurrentChapter() } }
    /// Index of the chapter containing the playhead. Stored, and only written
    /// when playback crosses into another chapter, so chapter lists don't
    /// redraw on every time tick.
    private(set) var currentChapterIndex: Int?
    var recapRange: TimeRange? { didSet { refreshSkipWindow() } }
    var introRange: TimeRange? { didSet { refreshSkipWindow() } }
    var creditsRange: TimeRange? { didSet { refreshSkipWindow() } }
    /// Which marker range contains the playhead. Stored, and only written
    /// when playback crosses a range edge, so views showing the skip buttons
    /// don't depend on `currentTime` and redraw on every time tick.
    private(set) var skipWindow = PlayerSkipWindow()
    var introAutoSkipCountdownSeconds: Int?
    var selectedAudioId: Int64? {
        didSet { if selectedAudioId != oldValue { reportPlayingTracksToServer() } }
    }
    var selectedSubtitleId: Int64? {
        didSet { if selectedSubtitleId != oldValue { reportPlayingTracksToServer() } }
    }
    var selectedSecondarySubtitleId: Int64?

    // MARK: Quality

    var qualityOptions: [ApplePlaybackQualityOption] = [ApplePlaybackQuality.auto]
    var selectableQualityOptions: [ApplePlaybackQualityOption] {
        guard lastLoadRequest?.offlineDownloadId == nil, !isAudioOnlyVividLoad else { return [] }
        let base = [ApplePlaybackQuality.auto, ApplePlaybackQuality.original]
        guard qualityOptions.contains(where: { !$0.isAuto && !$0.isOriginal }) else { return base }
        return base + PlaybackFallbackMode.allCases.map(\.option)
    }
    var selectedQualityChoiceID: String {
        PlaybackFallbackMode.matching(activeQualityId)?.rawValue ?? activeQualityId
    }
    var playbackFallbackMode: PlaybackFallbackMode?
    var playbackFallbackGate = PlaybackFallbackGate()
    var qualityFallbackTask: Task<Void, Never>?
    var activeQualityId: String = ApplePlaybackQuality.autoId
    /// The cap the current playback was asked for with. It moves in step with
    /// `activeQualityId`, so a load that carries that quality forward repeats
    /// the same cap.
    @ObservationIgnored
    var activeBandwidthCap: CarriedBandwidthCap = .savedSetting
    var isQualitySwitching = false
    var qualitySwitchError: String?

    // MARK: Scrubbing and buffer

    var isScrubbing = false
    var scrubPreviewTime: Double = 0
    /// The latest still for the scrub target, fenced to its load. Nil is a
    /// normal state: a cache miss, or a source that can't open a second
    /// reader, keeps the time-only preview.
    var scrubPreviewImage: CGImage?
    var scrubPreviewImageSourceTime: Double?
    /// True while the iOS touch-and-hold fast-forward gesture is engaged.
    /// The temporary rate goes straight to the engine and is never saved, so
    /// letting go always restores `settings.playbackSpeed`.
    var isHoldFastForwarding = false
    /// The ready-to-play buffer playback recovery reads. Kept separate from
    /// the deeper read-ahead cache the Apple TV timeline shows.
    var bufferedAheadSeconds: Double = 0
    var playbackStats: PlaybackStats = .empty
    var playbackReadAheadSeconds: Double?
    @ObservationIgnored var playbackStatsCadence = VividPlaybackStatsCadence()
    @ObservationIgnored var playbackStatsEpoch: VividPlaybackController.LoadEpoch?
    @ObservationIgnored var playbackStatsRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingPlaybackStatsTelemetry: LiveTelemetry?
    #if DEBUG
    @ObservationIgnored var debugPlaybackStatsUptime: TimeInterval?
    /// Test-only. Nil in the app, where nothing is recorded.
    @ObservationIgnored var testRecorder: PlayerTestRecorder?
    #endif
    #if os(tvOS)
    /// Presentation only: the measured read-ahead, falling back to the
    /// ready-to-play buffer on routes that don't measure it.
    var timelineBufferedAheadSeconds: Double {
        if let available = playbackReadAheadSeconds, available.isFinite {
            return max(0, available)
        }
        return bufferedAheadSeconds.isFinite ? max(0, bufferedAheadSeconds) : 0
    }
    #endif

    // MARK: Next Up

    var showNextUpScreen = false
    /// A Next Up load keeps its preview until the next item's own startup
    /// milestone. Repeated actions can't reload it or expand a frame that
    /// isn't ready.
    var isNextUpTransitioning = false
    var nextUpEpisode: PlayerNextUpEpisode?
    /// The shuffle order this viewing plays through, when it started from
    /// Shuffle. Next Up follows it instead of the series order, and every
    /// episode in it starts from the beginning.
    var shuffleQueue: EpisodeShuffleQueue?
    var nextUpOnDeckItems: [PlayerOnDeckItem] = []
    var isLoadingNextUpEpisode = false
    var isLoadingNextUpOnDeck = false
    var nextUpLookupError: String?
    /// Set when an autoplay load fails (a timeout or any other error while
    /// starting). Shown as a recoverable message on the Next Up screen
    /// instead of taking over the player with `error`. Cleared by
    /// `resetPublishedLoadState` on the next load.
    var nextUpStartError: String?
    var nextUpCountdownSeconds: Int?
    var nextUpCountdownTotalSeconds: Int = 10
    var nextUpScreenVideoEnded = false
    enum NextUpPresentationSource {
        case automatic
        case hud
    }
    var nextUpPresentationSource: NextUpPresentationSource = .automatic

    // MARK: Metadata and HUD

    /// Secondary metadata for the player overlay, from the `WatchDetail` and
    /// `FileVersion` the session started with. Empty until then; the overlay
    /// hides the matching rows.
    var metadata: PlayerMetadata = .empty

    /// The Info panel's Stream pills. The audio pill reads the selected
    /// track, so it changes with the Audio row when the viewer switches audio.
    var streamBadges: [String] {
        metadata.streamBadges(playingAudio: audioTracks.first { $0.trackId == selectedAudioId })
    }

    /// True while the Apple TV options HUD is open. The one source of truth,
    /// so `TVPlayerControls` (presentation) and `PlayerView` (Menu and exit
    /// handling) agree. Driven by `openHUD()` and `closeHUD()`.
    var isHUDPresented = false

    var isRecapSkipActive: Bool { skipWindow.inRecap }

    var introSkipLabel: String {
        isRecapSkipActive ? String(localized: "Skip Recap") : String(localized: "Skip Intro")
    }
    /// The skip button while its auto-skip countdown runs.
    var introSkipNowLabel: String {
        isRecapSkipActive ? String(localized: "Skip Recap Now") : String(localized: "Skip Intro Now")
    }
    /// Accessibility label for cancelling the auto-skip countdown.
    var introSkipCancelLabel: String {
        isRecapSkipActive ? String(localized: "Cancel Skip Recap") : String(localized: "Cancel Skip Intro")
    }
    var activeIntroSkipRange: TimeRange? { isRecapSkipActive ? recapRange : introRange }
    var openingSkipRanges: [TimeRange] { [recapRange, introRange].compactMap { $0 } }

    var showIntroSkip: Bool {
        settings.introDBEnabled && (skipWindow.inRecap || skipWindow.inIntro)
    }

    var showCreditsSkip: Bool {
        settings.introDBEnabled && skipWindow.inCredits
    }

    private func refreshCurrentChapter() {
        let index = chapters.lastIndex { $0.time <= currentTime }
        if index != currentChapterIndex { currentChapterIndex = index }
    }

    private func refreshSkipWindow() {
        let window = PlayerSkipWindow(time: currentTime, recap: recapRange, intro: introRange, credits: creditsRange)
        if window != skipWindow { skipWindow = window }
    }

    // MARK: Hold seeking

    /// Signed rate of a hold-to-seek session; zero when not seeking. Positive
    /// is forward. Magnitudes come from `Self.seekRates`. Entered by holding
    /// an arrow past the tap threshold and left with Select (commit) or Menu
    /// (cancel). Left and Right step the rate along the ladder meanwhile.
    ///
    /// The Apple TV shell watches it to draw the rate chip and to keep the
    /// focus sink alive, so presses aren't lost to the scrubber.
    var holdSeekRate: Int = 0
    /// Any non-zero rate means a seek session is running.
    var isHoldSeeking: Bool { holdSeekRate != 0 }

    #if os(tvOS)
    enum TVHUDEntryPoint: Equatable {
        case settings
        case playback
    }

    var requestedTVHUDEntryPoint: TVHUDEntryPoint?
    #endif

    /// The signed speed ladder Left and Right step through during a seek
    /// session. No zero: pausing is Select or Menu. It tops out at 32x so a
    /// long file can be crossed in a few seconds of tapping; the ramp on
    /// entry only reaches 8x, so the faster rates take deliberate steering.
    static let seekRates: [Int] = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]

    // MARK: Volume, routes and capabilities

    /// The viewer's volume and mute, owned here. A fresh load can replace the
    /// engine's audio route, so these are applied again after every load.
    var userVolume: Float = 1.0
    var userMuted = false
    /// Moves on with every load, replan and same-route reload. Work started
    /// for an older value is stale (see `requireCurrentStreamLoad`).
    var streamLoadGeneration: UInt64 = 0
    var backendCapabilities: PlayerBackendCapabilities {
        let engine = vividPlaybackController.engine
        let selected = engine.activeSubtitleTrackIndex.flatMap { selectedID in
            engine.subtitleTracks.first { $0.id == selectedID }
        }
        let codec = selected?.codec.lowercased() ?? ""
        let authored = selected?.isNativelyRenderedSubtitle == true &&
            (SubtitleCodecClassifier.isBitmap(codec) || codec == "ass" || codec == "ssa")
        // A subtitle the server draws into the video takes no styling either.
        let burnedIn = isServerBurnedInSubtitle(selectedSubtitleId)
        return .vivid(
            subtitleOverlayControls: !authored && !burnedIn,
            hasTextSubtitleTrack: subtitleTracks.contains {
                !SubtitleCodecClassifier.isBitmap($0.codec)
            }
        )
    }
    /// The route's English label, for logs and diagnostics.
    var activeRouteLabel: String {
        guard let delivery = vividPlaybackController.activeSpec?.delivery else {
            return VividPlaybackEngineIdentity.name
        }
        switch delivery {
        case PlaybackProtocolV3.PlanDelivery.originalHTTP: return "Original"
        case PlaybackProtocolV3.PlanDelivery.remuxProgressive: return "Server Remux"
        case PlaybackProtocolV3.PlanDelivery.remuxHLS: return "Server Remux HLS"
        case PlaybackProtocolV3.PlanDelivery.transcodeHLS: return "Server Transcode HLS"
        default: return delivery.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    /// `activeRouteLabel` in the app's language.
    var activeRouteDisplayLabel: String {
        guard let delivery = vividPlaybackController.activeSpec?.delivery else {
            return VividPlaybackEngineIdentity.name
        }
        switch delivery {
        case PlaybackProtocolV3.PlanDelivery.originalHTTP:
            return String(localized: "route.original", defaultValue: "Original", comment: "Playback route: the original file, played as it is")
        case PlaybackProtocolV3.PlanDelivery.remuxProgressive: return String(localized: "Server Remux", comment: "Playback route")
        case PlaybackProtocolV3.PlanDelivery.remuxHLS: return String(localized: "Server Remux HLS", comment: "Playback route")
        case PlaybackProtocolV3.PlanDelivery.transcodeHLS: return String(localized: "Server Transcode HLS", comment: "Playback route")
        default: return activeRouteLabel
        }
    }
    /// One line describing the route, for the player HUD.
    var playbackRouteDisplay: String {
        "\(VividPlaybackEngineIdentity.name) · \(activeRouteDisplayLabel)"
    }
    var routeStatusRows: [PlayerRouteStatusRow] {
        [
            PlayerRouteStatusRow(label: String(localized: "Playback", comment: "Route row: how the title is being played"), value: activeRouteDisplayLabel),
            PlayerRouteStatusRow(label: String(localized: "Engine", comment: "Route row: the playback engine"), value: VividPlaybackEngineIdentity.name),
            PlayerRouteStatusRow(
                label: String(localized: "Route", comment: "Route row: the engine's video route"),
                value: vividPlaybackController.engine.videoRoute.rawValue
            ),
        ]
    }
    var routeDecisionSummary: String? {
        activePreparedProtocolV3?.plan.decisionReason
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    var routeWarnings: [String] {
        activePreparedProtocolV3?.plan.degradationWarnings.map(\.message) ?? []
    }
    var supportsSecondarySubtitles: Bool { backendCapabilities.supportsSecondarySubtitles }
    /// `subtitleTracks` grouped by language and sorted by preferred format,
    /// for display. The stored array stays in source order, which the
    /// selection and track replacement code relies on. The two pickers in
    /// the player list this.
    var orderedSubtitleTracks: [PlayerTrack] {
        orderedSubtitles(subtitleTracks)
    }
    var availableSecondarySubtitleTracks: [PlayerTrack] {
        guard backendCapabilities.supportsSecondarySubtitles else { return [] }
        return orderedSubtitles(subtitleTracks.filter {
            !SubtitleCodecClassifier.isBitmap($0.codec) && canRenderAsSecondarySubtitle($0)
        })
    }
    private func orderedSubtitles(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        LucidSubtitleInventory.ordered(tracks)
    }

    // MARK: Lifecycle and presentation

    /// Set by `cleanup()` and `deinit`. Every async callback checks it, so a
    /// late hand-off can't start a new pipeline on a view that's gone.
    var isDisposed = false
    var needsReplacementForPresentation: Bool { isDisposed }
    /// Whether the engine has a native video route a receiver can fetch.
    /// Header-authenticated remote HLS stays false, because the receiver
    /// can't repeat the sender's request headers.
    var supportsExternalPlayback = false
    /// Follows the active AVPlayer route, with the AirPlay or HDMI audio
    /// route used only to bridge the engine's brief native item replacement.
    var isExternalPlaybackActive = false
    #if os(iOS)
    var isPlayerPresentationVisible = false
    /// AVKit's restore completion handler, held while the re-presented cover
    /// is still on its way to `PlayerView.onAppear`. See
    /// `restorePictureInPictureUserInterface`.
    var pendingRestoreCompletion: ((Bool) -> Void)?
    var pendingRestoreTimeoutTask: Task<Void, Never>?
    /// How long the re-presented cover gets to actually mount before the
    /// restore counts as failed. Generous next to a SwiftUI presentation,
    /// short next to a session that would otherwise play on forever.
    static let pictureInPictureRestoreTimeoutNanoseconds: UInt64 = 3_000_000_000
    #endif
    /// True after a confirmed end of stream. Keeps the UI paused at the end
    /// without late callbacks overwriting it or showing a false decode error.
    var hasReachedEndOfFile = false
    /// An early end held while a load or replan owned failures.
    var pendingUnexpectedEndEpoch: VividPlaybackController.LoadEpoch?
    let settings = PlayerSettings.shared
    let sleepTimer = SleepTimer()
    let nowPlaying = VividVideoNowPlayingCoordinator()
    /// Poster and backdrop URLs the presenter supplies, so Now Playing can
    /// show artwork without fetching the catalogue item just for them. Set
    /// through `applyArtworkURLHints`. Nil falls back to a fetch in
    /// `pushNowPlayingArtwork`.
    var artworkPosterURLHint: String?
    var artworkBackdropURLHint: String?

    /// Limits Now Playing updates. The system animates the scrubber between
    /// updates from `playbackRate`, so the elapsed time only needs pushing
    /// every couple of seconds.
    var lastNowPlayingPush: Date = .distantPast

    let sessionBridge = PlaybackSessionBridge()
    @ObservationIgnored
    var realtimeClient: PlaybackRealtimeClient!
    /// The IntroDB and TheIntroDB lookup for the current item, and its raw
    /// result kept until a finite duration arrives.
    var introDBLookupTask: Task<Void, Never>?
    var loadedIntroDBSegments: VividIntroDBClient.Segments?

    private var cleanupCompletionTask: Task<Void, Never>?
    /// The immediate progress write at a natural end, so teardown and
    /// autoplay can wait for it before stopping or replacing the session,
    /// rather than waiting for the ten-second report.
    var naturalEndProgressTask: Task<Void, Never>?

    // MARK: Tasks

    var hideControlsTask: Task<Void, Never>?
    #if os(iOS)
    var touchControlsPinned = false
    var touchControlPressed = false
    #endif
    var noticeDismissTask: Task<Void, Never>?
    var remoteDismissTask: Task<Void, Never>?
    var progressTask: Task<Void, Never>?
    var staleSessionRecoveryTask: Task<Void, Never>?
    /// The device settings fetch `init` starts, held so `cleanup()` can
    /// cancel it and loads can wait for it.
    var settingsRefreshTask: Task<Void, Never>?
    var freshLoadTask: Task<Void, Never>?
    var freshLoadGeneration: UInt64 = 0
    /// True while `freshLoadTask` is the only owner of a load failure. The
    /// engine publishes its typed failure before the load throws, so without
    /// this a direct-play or offline failure would be handled twice: by
    /// `handleVividFailure` and by the load's own catch.
    var freshLoadOwnsFailureHandling = false
    /// The latest `audioTrackSwitchFailed` the engine published while a load
    /// owned failures. The engine kills the load in the same rebuild, so the
    /// load's catch sees only a cancellation and wouldn't know why.
    @ObservationIgnored
    var lastVividAudioTrackSwitchFailure: PlaybackErrorInfo?
    /// Runs every Silo source replacement one at a time, including a reload of
    /// the same plan whose only change is a refreshed bearer, so credential
    /// recovery can't race route replans, seeks or track changes.
    var protocolV3ReplanTask: Task<Void, Never>?
    var authenticationRecoveryBudget = VividAuthenticationRecoveryBudget()
    var transientRecoveryBudget = VividTransientRecoveryBudget()
    @ObservationIgnored var prematureEndRecoveryGate = VividPrematureEndRecoveryGate()
    /// The stream generation of a credential or connection reload in flight.
    var authenticationReloadGeneration: UInt64?
    var nextUpLookupTask: Task<Void, Never>?
    var nextUpOnDeckTask: Task<Void, Never>?
    var nextUpCountdownTask: Task<Void, Never>?
    /// Debounces skip taps on the trailing edge: each tap moves the preview
    /// and restarts this timer, and the seek runs once after
    /// `skipDebounceNanos` of quiet. Seeking on the first tap stuttered on
    /// bursts, jumping to tap one, playing briefly, then jumping again.
    var skipDebounceTask: Task<Void, Never>?
    /// Button skips share the seek preview, but mustn't fade touch controls.
    var isTimelineScrubbing: Bool { isScrubbing && skipDebounceTask == nil }
    let skipDebounceNanos: UInt64 = 200_000_000 // 200ms

    /// Moves the preview during a hold-to-seek session, every
    /// `holdSeekTickNanos`, by `holdSeekBaseStep * holdSeekRate` seconds,
    /// until `commitHoldSeek` or `cancelHoldSeek`.
    var holdSeekTask: Task<Void, Never>?
    /// Ramps the rate 1, 2, 4, 8 over the first four seconds or so of a hold,
    /// and stops as soon as the viewer changes the rate themselves.
    var holdSeekAutoRampTask: Task<Void, Never>?
    static let holdSeekBaseStep: Double = 2.0 // seconds per tick at 1x
    static let holdSeekTickNanos: UInt64 = 100_000_000 // 100ms (10Hz)

    /// Seek filter: the playhead before the seek and the target asked for.
    /// Time reports nearer the origin than the target are stale and dropped,
    /// in either direction and across back-to-back seeks. The filter lifts as
    /// soon as a report crosses the midpoint. A timeout lifts it if no
    /// report arrives (for example a transport error on a transcode), since
    /// a stuck filter would pin the scrubber to the target for good.
    var seekOriginTime: Double?
    var seekTargetTime: Double?
    var seekFilterTimeoutTask: Task<Void, Never>?
    /// The running `commitSeek` wait, held so a new load can cancel a seek
    /// whose replan answer would otherwise arrive after its item has gone.
    var seekReplanTask: Task<Void, Never>?
    static let seekFilterNanos: UInt64 = 5_000_000_000 // 5s

    // MARK: Load request and track intent

    /// The download being played locally, with no server session. While set,
    /// progress goes to `DownloadManager.recordOfflineProgress`, which queues
    /// it for the next sync, so nothing on this path reaches a server session
    /// or progress endpoint.
    struct OfflinePlaybackContext {
        let downloadId: String
        let mediaItemId: String
    }
    var offlinePlaybackContext: OfflinePlaybackContext?
    /// Track picks held for this load (FFmpeg stream indexes; -1 for subtitles
    /// is Off), until the engine lists a matching track and the pick is
    /// applied, or the viewer picks something else.
    var pendingAudioFfIndex: Int?
    var pendingSubtitleFfIndex: Int?
    /// True when the load came with an explicit subtitle pick (a route
    /// argument or the detail page). Auto stands aside then.
    var hasExplicitSubtitleChoice: Bool = false
    /// External subtitle picks have no FFmpeg index, so a reload remembers
    /// the sidecar `trackId` and re-applies it once the files are mounted again.
    var pendingSidecarSubtitleTrackId: Int64?
    /// A Silo subtitle can keep its sidecar picker row even when the new plan
    /// renders it on the server (for example a PGS subtitle burned into HLS).
    /// This keeps that row selected across a reload without also opening the
    /// sidecar locally.
    var pendingServerRenderedSubtitleTrackId: Int64?
    /// Auto's inputs for the current item, applied once the engine lists its
    /// embedded tracks and cleared when the next load starts.
    var prefsForCurrentItem: PrefsSnapshot?
    struct PrefsSnapshot {
        let preferredLanguage: String?
        let additionalPreferredLanguages: [String]
        let mode: SubtitleMode?
        let showForced: Bool
        let forcedOnly: Bool
        let preferAccessibilityTracks: Bool
        let disableWhenNoLanguageMatch: Bool
        let trackSignature: SubtitleTrackSignature?
        /// Settings > Subtitles > Backup Language: tried only when no track
        /// is in a preferred language.
        var fallbackLanguages: [String] = []
        /// Apple's Forced Only: the forced track follows the audio's language.
        var forcedFollowsAudio = false
    }
    /// A subtitle pick, or Off, made in the player. It holds for the rest of
    /// this viewing, including next episodes that play on from here, while
    /// Settings > Subtitles stays the default for anything started afresh.
    var viewingSubtitlePrefs: PrefsSnapshot?
    /// The language of an audio pick made in this viewing, in the player or
    /// on the detail page. Next episodes that play on start in it when they
    /// have it; anything started afresh goes back to Settings > Playback >
    /// Audio Language.
    var viewingAudioLanguage: String?
    /// A detail-page audio pick whose language is read once its file is
    /// known, at the start of the load.
    var viewingAudioSeedOrdinal: Int?
    /// The viewer switched audio during the current item, so the load's own
    /// audio ordinal no longer says which track is playing.
    var audioPickedForCurrentItem = false
    /// The catalogue ordinal of the audio the current load asked for: the
    /// track sent to Emby or Jellyfin, or chosen for a download. Silo's plan
    /// says the same through `activePreparedProtocolV3`.
    var loadAudioOrdinal: Int?
    /// Orders the playing-track updates handed to an Emby or Jellyfin session.
    var playingTracksGeneration: UInt64 = 0
    /// Set once Auto has run for the current item, so later track list
    /// updates don't run it again and override the viewer.
    var prefsResolvedForCurrentItem: Bool = false
    var resolvedServerUrl: String = ""
    var currentWatchDetail: WatchDetail?
    var currentSelectedVersion: FileVersion?
    var activePreparedProtocolV3: PreparedPlaybackV3?
    var activePlaybackSessionId: String?
    var autoSkippedIntroKey: String?
    var autoSkippedCreditsKey: String?
    var autoSkipIntroCancelledKey: String?
    var pendingAutoSkipIntroKey: String?
    var autoSkipIntroCountdownTask: Task<Void, Never>?
    /// The lost session a renewal has already started for.
    var staleSessionRecoverySessionId: String?

    static let autoplayStartSessionTimeout: TimeInterval = 15
    /// Latched at the current item's first startup milestone and kept across
    /// recovery reloads of it; a new item or Play from Beginning clears it.
    /// Until then `currentTime` is only the requested start, not a position
    /// anyone watched. A failed or abandoned load reports nothing, so Emby
    /// and Jellyfin can't reset a saved resume point to a Play from
    /// Beginning start of zero.
    @ObservationIgnored var hasStartedPlayback = false
    var completedPlaybackContentId: String?
    var progressIsEligible: Bool { hasStartedPlayback || completedPlaybackContentId != nil }
    var lastLoadRequest: LoadRequest?
    static let nextUpCountdownDefaultSeconds = 10
    static let nextUpHUDCountdownThresholdSeconds: Double = 100
    static let introAutoSkipCountdownDefaultSeconds = 5
    var nextUpAutoplayCancelled = false
    /// Set when the viewer taps Keep Watching. Stops the pre-end Next Up
    /// prompt coming back while the playhead stays inside its window.
    /// Cleared when the playhead leaves the window (a seek back) or a new
    /// item loads, so the prompt can appear again. Doesn't apply to the
    /// end-of-playback screen.
    @ObservationIgnored var nextUpPromptDismissed = false
    var contentIdsNeedingDetailRefresh: Set<String> = []
    #if os(iOS) || os(tvOS)
    @ObservationIgnored
    var refreshHomeAfterPlaybackWrite: (@MainActor () -> Void)?
    #endif
    /// Items that crossed the completion point used by the final progress
    /// report. The Apple TV detail page reads this only after that report
    /// has finished, so it can move to the next unwatched episode without
    /// racing old catalogue data.
    var completedContentIdsNeedingDetailAdvance: Set<String> = []
    var nextUpCarouselItems: [PlayerOnDeckItem] {
        let hiddenIds = Set([lastLoadRequest?.contentId, nextUpEpisode?.contentId].compactMap { $0 })
        return nextUpOnDeckItems.filter { !hiddenIds.contains($0.contentId) }
    }

    var canShowNextUpScreen: Bool {
        nextUpEpisode != nil
            || !nextUpCarouselItems.isEmpty
            || isLoadingNextUpEpisode
            || isLoadingNextUpOnDeck
    }

    // MARK: System observers

    /// Re-applies subtitle styling when the viewer changes the system's
    /// Subtitles & Captioning settings during playback.
    private var systemCaptionObserverToken: NSObjectProtocol?
    private var systemCaptionForegroundObserverToken: NSObjectProtocol?
    /// Asks Silo for a new plan when the audio route the session was planned
    /// for changes.
    private var outputRouteObserverToken: NSObjectProtocol?
    /// Saves the resume point when the app is about to lose foreground time.
    /// The periodic report runs every ten seconds, so without this a
    /// backgrounded (or terminated) player loses up to that much progress.
    /// It doesn't stop the session: Picture in Picture and background audio
    /// carry on.
    private var foregroundExitObserverToken: NSObjectProtocol?

    // MARK: Subtitle files

    #if os(iOS) || os(tvOS)
    var openSubtitleFiles = OpenSubtitleSessionFiles()
    #endif
    /// Silo subtitle files for the current load, by sidecar track ID: text
    /// files beside the media, and text subtitles Silo stores (downloaded,
    /// uploaded or AI-made). They're fetched only when chosen, because each
    /// fetch can start a server subtitle sync job.
    var lazySubtitleSidecars: [Int64: ExternalSubtitleTrack] = [:]
    /// The request the current load's Silo subtitle files resolve against, so
    /// a subtitle Silo finishes making mid-playback can be offered too.
    var lazySubtitleSidecarRequest: StreamRequest?
    /// A Silo subtitle file picked on this device. Silo never sees it, so
    /// replacement loads of the same file re-apply it here. `storedID` names a
    /// stored subtitle, which another plan can list at a different index.
    var localExternalSubtitlePick: (trackID: Int64, contentID: String, fileID: Int?, storedID: Int?)?
    /// Emby and Jellyfin transcodes: what the server does with bitmap
    /// subtitles for the current load. Nil on direct play, Silo and offline.
    var serverTranscodeSubtitles: ServerTranscodeSubtitles?
    /// Bitmap tracks the server can draw into the current transcode, listed
    /// after the subtitles Vivid plays itself. Views read `subtitleTracks`.
    @ObservationIgnored var serverBurnInRows: [PlayerTrack] = []
    struct ServerBurnInFailure: Hashable {
        let contentId: String
        let fileId: Int
        let index: Int
    }
    /// Burn-ins the server didn't confirm or couldn't play. Those rows are
    /// dropped for the rest of the item, so no pick asks for them again.
    @ObservationIgnored var failedServerBurnIns: Set<ServerBurnInFailure> = []

    // MARK: Init and teardown

    init() {
        do {
            vividPlaybackController = try VividPlaybackController()
        } catch {
            fatalError("VividEngine initialization failed: \(error)")
        }
        scrubPreviewProvider = VividScrubPreviewProvider(engine: vividPlaybackController.engine)
        scrubPreviewProvider.onPreview = { [weak self] preview in
            guard let self else { return }
            self.scrubPreviewImage = preview?.image
            self.scrubPreviewImageSourceTime = preview?.sourceTime
        }
        vividPlaybackController.onEvent = { [weak self] event in
            self?.handleVividEvent(event)
        }
        vividPlaybackController.onControllerEvent = { [weak self] event in
            self?.handleVividControllerEvent(event)
        }
        vividPlaybackController.onSystemCaptionRequest = { [weak self] epoch, request in
            self?.handleSystemCaptionRequest(epoch: epoch, request: request)
        }
        realtimeClient = PlaybackRealtimeClient(
            commandHandler: { [weak self] command in
                guard let self else {
                    throw PlaybackRealtimeCommandExecutionError.commandFailed
                }
                try await self.handleRealtimeCommand(command)
            },
            eventHandler: { [weak self] event in
                guard let self else { return }
                await self.handleRealtimeEvent(event)
            }
        )
        sleepTimer.configure { [weak self] in
            MainActor.assumeIsolated {
                self?.vividPlaybackController.pause()
            }
        }
        observeSystemNotifications()
        settingsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshSettingsFromServer()
        }
    }

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        systemCaptionObserverToken = center.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemCaptionSettingsDidChange() }
        }
        #if os(iOS) || os(tvOS)
        // Caption settings only change outside Vivid. Catch up on the way
        // back in too, in case the change notification didn't arrive.
        systemCaptionForegroundObserverToken = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemCaptionSettingsDidChange() }
        }
        #endif
        outputRouteObserverToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.audioOutputRouteDidChange() }
        }
        #if os(iOS) || os(tvOS)
        foregroundExitObserverToken = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPlaybackProgressNow(reason: "foreground_exit")
            }
        }
        #endif
    }

    /// Asks Silo for a new plan when the audio output the session was planned
    /// for has really changed (not just a notification for the same output).
    private func audioOutputRouteDidChange() {
        guard let activeProtocolV3 = activePreparedProtocolV3, !isDisposed, !isLoading else { return }
        let observedSnapshot = ApplePlaybackV3Capabilities.snapshot()
        guard PlaybackSessionBridge.isMaterialOutputRouteChange(
            activeOutputContextId: activeProtocolV3.outputContextId,
            observedOutputContextId: observedSnapshot.outputContextId
        ) else {
            Self.logger.debug("Ignoring AVAudioSession route notification with unchanged Playback V3 output context")
            return
        }
        attemptProtocolV3Replan(
            position: currentTime,
            classification: "output_route_changed",
            message: "The Apple audio output route changed.",
            outputRouteSnapshot: observedSnapshot
        )
    }

    private func removeSystemObservers() {
        let center = NotificationCenter.default
        for token in [
            outputRouteObserverToken,
            systemCaptionObserverToken,
            systemCaptionForegroundObserverToken,
            foregroundExitObserverToken,
        ] {
            if let token { center.removeObserver(token) }
        }
        outputRouteObserverToken = nil
        systemCaptionObserverToken = nil
        systemCaptionForegroundObserverToken = nil
        foregroundExitObserverToken = nil
    }

    /// Final teardown, from `PlayerView.onDisappear` (deferred while Picture
    /// in Picture is engaged) or an identity change. Runs once.
    ///
    /// Everything synchronous stops here. The final writes then run in
    /// `cleanupCompletionTask`, in order: the natural-end progress write if
    /// one is running, the final progress report, Home's refresh signal, the
    /// session stop, the scrub preview shutdown and the realtime unbind. A
    /// download records its final position in its offline queue instead and
    /// stops no server session.
    func cleanup() {
        guard !isDisposed else { return }
        shuffleQueue = nil
        #if os(iOS) || os(tvOS)
        AppHealthMonitor.playerClosed()
        #endif
        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        Self.logger.info("PlayerViewModel.cleanup()")
        recordCurrentPlaybackMutation(markedCompleted: completedPlaybackContentId != nil)
        let pendingNaturalEndProgressTask = naturalEndProgressTask
        naturalEndProgressTask = nil
        isDisposed = true
        transientRecoveryBudget.cancel()
        #if os(iOS)
        // A restore waiting on a cover that will now never mount has to be
        // answered, or AVKit is left holding a handler for a dead session.
        resolvePendingPictureInPictureRestore(false)
        // The PiP coordinator is a singleton whose controller holds the
        // player layer, the player and everything hanging off them. SwiftUI's
        // `dismantleUIView` normally releases it, but not in a guaranteed
        // order with this teardown, so it's dropped here too. Keyed by owner,
        // so a late teardown can't unbind a newer session's PiP.
        PictureInPictureCoordinator.shared.endSession(owner: self)
        // A restore that staged this view model but never reached SwiftUI
        // would otherwise hold the whole playback graph on a static.
        PlayerPresentationRestoration.discardAdoption(for: self)
        #endif
        activePlaybackSessionId = nil
        staleSessionRecoverySessionId = nil
        currentWatchDetail = nil
        currentSelectedVersion = nil
        bufferedAheadSeconds = 0
        playbackReadAheadSeconds = nil
        cancelPlaybackStatsRefresh()
        playbackStatsCadence.reset()
        playbackStatsEpoch = nil
        playbackStats = .empty
        loadedIntroDBSegments = nil
        introRange = nil
        recapRange = nil
        creditsRange = nil
        introDBLookupTask?.cancel()
        introDBLookupTask = nil
        cancelPendingIntroAutoSkip()
        autoSkippedIntroKey = nil
        autoSkippedCreditsKey = nil
        autoSkipIntroCancelledKey = nil
        pendingServerRenderedSubtitleTrackId = nil
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        remoteDismissTask?.cancel()
        remoteDismissTask = nil
        activeNotice = nil
        tearDownHoldSeek()
        hideControlsTask?.cancel()
        progressTask?.cancel()
        staleSessionRecoveryTask?.cancel()
        staleSessionRecoveryTask = nil
        settingsRefreshTask?.cancel()
        settingsRefreshTask = nil
        freshLoadTask?.cancel()
        freshLoadOwnsFailureHandling = false
        streamLoadGeneration &+= 1
        protocolV3ReplanTask?.cancel()
        protocolV3ReplanTask = nil
        seekReplanTask?.cancel()
        seekReplanTask = nil
        removeSystemObservers()
        nextUpLookupTask?.cancel()
        nextUpOnDeckTask?.cancel()
        nextUpCountdownTask?.cancel()
        autoSkipIntroCountdownTask?.cancel()
        autoSkipIntroCountdownTask = nil
        skipDebounceTask?.cancel()
        seekFilterTimeoutTask?.cancel()
        holdSeekTask?.cancel()
        holdSeekAutoRampTask?.cancel()
        sleepTimer.cancel()
        nowPlaying.detach()

        // A download has no server session of its own (its load stopped any
        // earlier one), so it saves its final position to the offline queue
        // and skips the server stop below, which would report against an old
        // session. The values are read now so the task doesn't read state
        // that's being torn down.
        let stopsServerSession = offlinePlaybackContext == nil
        if let offline = offlinePlaybackContext {
            let finalOfflinePosition = completionProgressPositionForCurrentItem()
            let endedNaturally = completedPlaybackContentId != nil
            // Holds `self` on purpose: this is the last write of the resume
            // point and mustn't be lost because the view model was released
            // between the dismissal and the hop to the main actor.
            Task { @MainActor in
                self.recordOfflineProgress(
                    context: offline,
                    position: finalOfflinePosition,
                    markCompleted: endedNaturally
                )
            }
        }

        // The real position is reported. Watched state is sent separately
        // after progress and Stop, with the same rule as offline playback.
        let finalPosition = completionProgressPositionForCurrentItem()
        let finalProgressEligible = progressIsEligible
        let finalCompletedContentId = completedPlaybackContentId
        let playbackMutationContentIds = contentIdsNeedingDetailRefresh
        let completedPlaybackContentIds = completedContentIdsNeedingDetailAdvance
        #if os(iOS) || os(tvOS)
        let refreshHome = refreshHomeAfterPlaybackWrite
        #endif
        let scrubPreviewShutdown = disposeVividPlayback()

        cleanupCompletionTask = Task {
            await pendingNaturalEndProgressTask?.value
            if stopsServerSession {
                // The resume point goes first. Session bookkeeping and the
                // DELETE can finish afterwards; neither changes Continue
                // Watching, so making Home wait for them would only leave old
                // progress showing after the player has closed.
                let progressResult = await sessionBridge.reportProgress(
                    position: finalPosition,
                    isPaused: true,
                    eligible: finalProgressEligible,
                    completedContentId: finalCompletedContentId
                )
                #if os(iOS) || os(tvOS)
                if progressResult == .success {
                    refreshHome?()
                    NotificationCenter.default.post(
                        name: .playbackProgressDidCommit,
                        object: PlaybackProgressCommittedEvent(
                            contentIds: playbackMutationContentIds,
                            completedContentIds: completedPlaybackContentIds
                        )
                    )
                }
                #endif
                let stopProgressResult = await sessionBridge.stopSession(
                    position: finalPosition,
                    isPaused: true,
                    eligible: finalProgressEligible,
                    completedContentId: finalCompletedContentId,
                    finalProgressAlreadyReported: progressResult == .success
                )
                #if os(iOS) || os(tvOS)
                if progressResult != .success {
                    refreshHome?()
                    NotificationCenter.default.post(
                        name: .playbackProgressDidCommit,
                        object: PlaybackProgressCommittedEvent(
                            contentIds: playbackMutationContentIds,
                            completedContentIds: PlaybackProgressCommitPolicy.confirmedCompletedContentIds(
                                completedPlaybackContentIds,
                                initialResult: progressResult,
                                stopResult: stopProgressResult
                            )
                        )
                    )
                }
                #endif
            }
            await scrubPreviewShutdown?.value
            await realtimeClient.unbind()
        }
    }

    func waitForCleanupCompletion() async {
        // `onDisappear` calls `cleanup()` just before the Apple TV receiver
        // is unregistered. Yield briefly if teardown hasn't installed the
        // final progress task yet.
        for _ in 0..<100 where cleanupCompletionTask == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await cleanupCompletionTask?.value
    }

    /// A safety net. SwiftUI normally calls `cleanup()` from
    /// `PlayerView.onDisappear`, but if that's missed in an edge case of sheet
    /// or navigation teardown the engine still has to go, so audio can't
    /// outlive the view. Disposing twice is harmless.
    deinit {
        print("[CMP-LIFE] deinit PlayerViewModel")
        MainActor.assumeIsolated {
            Self.logger.info("PlayerViewModel.deinit")
            isDisposed = true
            playbackStatsRefreshTask?.cancel()
            transientRecoveryBudget.cancel()
            removeSystemObservers()
            freshLoadTask?.cancel()
            introDBLookupTask?.cancel()
            streamLoadGeneration &+= 1
            protocolV3ReplanTask?.cancel()
            seekReplanTask?.cancel()
            staleSessionRecoveryTask?.cancel()
            autoSkipIntroCountdownTask?.cancel()
            disposeVividPlayback()
            let realtimeClient = self.realtimeClient
            Task {
                await realtimeClient?.unbind()
            }
        }
    }
}
