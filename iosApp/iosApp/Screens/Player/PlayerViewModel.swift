
import AVFoundation
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

/// Chapters read from the media by Lucid Engine.
struct PlayerChapterInfo: Equatable, Identifiable, Sendable {
    let index: Int
    let title: String?
    let time: Double
    var id: Int { index }
}

/// Pure decision boundary for the credits setting's playback behavior.
///
/// Keeping the range/key checks outside the player backend makes every edge
/// deterministic to test: the VM owns the seek side effect, while this policy
/// decides whether the current time is the first eligible visit to this
/// session/file/marker combination.
enum CreditsAutoSkipPolicy {
    static func target(
        enabled: Bool,
        playbackEligible: Bool,
        time: Double,
        range: TimeRange?,
        markerKey: String?,
        lastSkippedKey: String?
    ) -> Double? {
        guard enabled,
              playbackEligible,
              time.isFinite,
              let range,
              range.start.isFinite,
              range.end.isFinite,
              range.start >= 0,
              range.end > range.start,
              let markerKey,
              markerKey != lastSkippedKey,
              time >= range.start,
              time < range.end else {
            return nil
        }
        return range.end
    }
}

struct PlayerNextUpEpisode: Identifiable, Hashable {
    let contentId: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String
    let overview: String?
    let runtime: Int?
    let stillUrl: String?
    let stillThumbhash: String?
    let airDate: String?

    var id: String { contentId }
    var episodeLabel: String { "S\(seasonNumber):E\(episodeNumber)" }

    init(episode: EpisodeListItem, seriesId: String?, seriesTitle: String?) {
        contentId = episode.contentId
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        seasonNumber = episode.seasonNumber
        episodeNumber = episode.episodeNumber
        let trimmedTitle = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTitle, !trimmedTitle.isEmpty {
            title = trimmedTitle
        } else {
            title = "Episode \(episode.episodeNumber)"
        }
        overview = episode.overview
        runtime = episode.runtime
        stillUrl = episode.stillUrl
        stillThumbhash = episode.stillThumbhash
        airDate = episode.airDate
    }
}

struct PlayerOnDeckItem: Identifiable, Hashable {
    let sectionItem: SectionItem
    let contentId: String
    let title: String
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let artworkUrl: String?
    let artworkThumbhash: String?

    var id: String { contentId }

    var primaryTitle: String {
        if let seriesTitle, !seriesTitle.isEmpty {
            return seriesTitle
        }
        return title
    }

    var secondaryTitle: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        let episodeLabel = "S\(seasonNumber):E\(episodeNumber)"
        if seriesTitle?.isEmpty == false, !title.isEmpty {
            return "\(episodeLabel) · \(title)"
        }
        return episodeLabel
    }

    var progressFraction: Double {
        guard let positionSeconds,
              let durationSeconds,
              durationSeconds > 0 else {
            return 0
        }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    var minutesRemaining: Int? {
        guard let positionSeconds,
              let durationSeconds,
              durationSeconds > positionSeconds else {
            return nil
        }
        return max(1, Int(((durationSeconds - positionSeconds) / 60).rounded()))
    }

    init(
        item: SectionItem,
        artworkUrl preferredArtworkUrl: String? = nil,
        artworkThumbhash preferredArtworkThumbhash: String? = nil
    ) {
        sectionItem = item
        contentId = item.contentId
        title = item.title
        seriesTitle = item.seriesTitle
        seasonNumber = item.seasonNumber
        episodeNumber = item.episodeNumber
        positionSeconds = item.positionSeconds
        durationSeconds = item.durationSeconds
        artworkUrl = preferredArtworkUrl ?? item.backdropUrl
        artworkThumbhash = preferredArtworkThumbhash ?? item.backdropThumbhash
    }
}

struct PlayerBackendCapabilities: Equatable {
    let supportsBufferedAhead: Bool
    let supportsSecondarySubtitles: Bool
    let supportsChapters: Bool
    let supportsVideoGravity: Bool
    let supportsSubtitleDelay: Bool
    let supportsSubtitleStyling: Bool

    static func vivid(
        subtitleOverlayControls: Bool,
        hasTextSubtitleTrack: Bool
    ) -> PlayerBackendCapabilities {
        PlayerBackendCapabilities(
            supportsBufferedAhead: true,
            supportsSecondarySubtitles: hasTextSubtitleTrack,
            supportsChapters: true,
            supportsVideoGravity: true,
            supportsSubtitleDelay: true,
            supportsSubtitleStyling: subtitleOverlayControls
        )
    }
}

/// Video playback teardown at an app identity boundary — sign-out, server or
/// profile switch, or a cleared session.
///
/// Those transitions replace the authenticated view hierarchy, which removes
/// the player cover. That path deliberately defers the player's `cleanup()`
/// while Picture in Picture is engaged, so nothing else ends an engaged video
/// session: the previous identity's engine, its open server playback session,
/// and a live PiP window would otherwise all survive into the next identity.
///
/// Callable from the shared auth paths on every platform; a no-op where video
/// Picture in Picture is not hosted.
enum PlayerIdentityBoundary {
    static func endEngagedVideoPictureInPicture() {
        #if os(iOS)
        PictureInPictureCoordinator.endEngagedSessionForIdentityChange()
        #endif
    }
}

@MainActor
@Observable
class PlayerViewModel {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Player"
    )

    @ObservationIgnored
    var vividPlaybackController: VividPlaybackController!
    @ObservationIgnored
    var activeVividLoadEpoch: VividPlaybackController.LoadEpoch?
    /// The epoch whose `finishLoad` has returned, i.e. whose engine startup ran
    /// to completion and whose decode route is therefore settled.
    ///
    /// Vivid publishes its track inventory during startup (`streamsProbed`),
    /// several steps before it dispatches the source onto a backend. Applying a
    /// deferred track pick at that point makes the engine rebuild its pipeline
    /// against a route it has not chosen yet — on a software-decode source
    /// (VC-1, AV1) the rebuild lands on the native path, which rejects the
    /// codec, kills the in-flight load and leaves the app on a spinner. Nothing
    /// that drives the engine off a *pending* selection may run before this is
    /// set for the current epoch.
    @ObservationIgnored
    var establishedVividLoadEpoch: VividPlaybackController.LoadEpoch?
    @ObservationIgnored
    var committedProtocolV3LoadEpoch: VividPlaybackController.LoadEpoch?
    @ObservationIgnored
    var pendingProtocolV3FirstFrameEpoch: VividPlaybackController.LoadEpoch?
    @ObservationIgnored
    var pendingProtocolV3SeekReanchorPosition: Double?
    /// The load epoch whose startup milestone (`handleFileLoaded`) has already
    /// run. Video loads reach that milestone on Vivid's first frame; audio-only
    /// loads have no picture and reach it when the audio route starts playing.
    /// Both funnel through one epoch-scoped latch so a load can never take the
    /// milestone twice.
    @ObservationIgnored
    var startedVividLoadEpoch: VividPlaybackController.LoadEpoch?
    /// Next Up and On Deck for the current item are fetched at its startup
    /// milestone, not while the stream is still opening.
    @ObservationIgnored
    var nextUpPrefetchPending = false
    /// A user track change that arrived while a replan was already in flight.
    /// Re-issued when the in-flight replan settles so the local selection the
    /// UI already shows is actually applied by the server. Position is
    /// re-read at drain time — playback moved on while we waited.
    @ObservationIgnored
    var pendingProtocolV3TrackChange: QueuedProtocolV3TrackChange?
    @ObservationIgnored
    var scrubPreviewProvider: VividScrubPreviewProvider!
    @MainActor var vividEngine: VividEngine { vividPlaybackController.engine }
    var hasActiveVividSession: Bool {
        vividPlaybackController.activeSpec != nil
    }

    /// Keeps the auxiliary Vivid still decoder in the same lifetime as the
    /// transport. Replacement loads preserve Vivid's display/audio handoff;
    /// callers that own final teardown can await the returned task.
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
    /// Fill progress (0–100) toward the buffering-resume threshold; nil
    /// when not buffering or when the active backend doesn't report it.
    var bufferingProgress: Double?
    var error: String?
    var showControls = false
    #if os(iOS)
    var shouldShowMobilePlayerChrome: Bool {
        // Loading and Next Up must not independently reveal player chrome.
        // Close and rotation follow the same tap/auto-hide state as transport.
        showControls
    }
    #endif
    var activeNotice: PlayerNotice?
    var remoteDismissToken: UUID?
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    /// Server-resolved preferred subtitle language for the current item,
    /// snapshotted at prepare time. Used only to float the matching
    /// language group to the top of the displayed track lists.
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
    /// do not depend on `currentTime` and re-render on every time tick.
    private(set) var skipWindow = PlayerSkipWindow()
    var introAutoSkipCountdownSeconds: Int?
    var selectedAudioId: Int64?
    var selectedSubtitleId: Int64?
    var selectedSecondarySubtitleId: Int64?
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
    /// The cap the current playback was requested with. It moves in step with
    /// `activeQualityId` so a load that carries that quality forward repeats
    /// the same cap.
    @ObservationIgnored
    var activeBandwidthCap: CarriedBandwidthCap = .savedSetting
    var isQualitySwitching = false
    var qualitySwitchError: String?
    var isScrubbing = false
    var scrubPreviewTime: Double = 0
    /// Latest generation-fenced Vivid still for the active scrub target.
    /// Nil is a first-class state: native cache misses and sources that cannot
    /// vend an independent reader keep the existing time-only affordance.
    var scrubPreviewImage: CGImage?
    var scrubPreviewImageSourceTime: Double?
    /// True while the iOS touch-and-hold fast-forward gesture is engaged.
    /// The temporary rate is applied straight to the backend and never
    /// persisted, so releasing always restores `settings.playbackSpeed`.
    var isHoldFastForwarding = false
    /// Consumer-ready buffer used by playback recovery. Keep this separate
    /// from the deeper read-ahead cache shown by the Apple TV timeline.
    var bufferedAheadSeconds: Double = 0
    var playbackStats: PlaybackStats = .empty
    var playbackReadAheadSeconds: Double?
    @ObservationIgnored var playbackStatsCadence = VividPlaybackStatsCadence()
    @ObservationIgnored var playbackStatsEpoch: VividPlaybackController.LoadEpoch?
    @ObservationIgnored var playbackStatsRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingPlaybackStatsTelemetry: LiveTelemetry?
    #if DEBUG
    @ObservationIgnored var debugPlaybackStatsUptime: TimeInterval?
    #endif
    #if os(tvOS)
    /// Presentation only: prefer measured contiguous read-ahead, falling back
    /// to the consumer buffer on routes without a cache-frontier measurement.
    var timelineBufferedAheadSeconds: Double {
        if let available = playbackReadAheadSeconds, available.isFinite {
            return max(0, available)
        }
        return bufferedAheadSeconds.isFinite ? max(0, bufferedAheadSeconds) : 0
    }
    #endif
    var showNextUpScreen = false
    /// A Next Up load keeps its preview until the successor's own startup
    /// milestone. Repeated actions cannot reload it or expand an unready frame.
    var isNextUpTransitioning = false
    var nextUpEpisode: PlayerNextUpEpisode?
    var nextUpOnDeckItems: [PlayerOnDeckItem] = []
    var isLoadingNextUpEpisode = false
    var isLoadingNextUpOnDeck = false
    var nextUpLookupError: String?
    /// Set when an autoplay-initiated `beginFreshLoad` fails (timeout or any
    /// other error during `startSession`). Surfaces a recoverable message in
    /// the Next Up screen's `finishedMessage` instead of taking over the whole
    /// player with `viewModel.error`. Cleared by `resetPublishedLoadState` on
    /// the next successful load.
    var nextUpStartError: String?
    var nextUpCountdownSeconds: Int?
    var nextUpCountdownTotalSeconds: Int = 10
    var nextUpScreenVideoEnded = false
    enum NextUpPresentationSource {
        case automatic
        case hud
    }
    var nextUpPresentationSource: NextUpPresentationSource = .automatic

    /// Secondary metadata surfaced to the player overlay. Populated from
    /// `WatchDetail` + `FileVersion` once `PlaybackSessionBridge.startSession`
    /// resolves. Empty until then; the overlay hides the corresponding rows.
    var metadata: PlayerMetadata = .empty

    /// True while the tvOS floating options HUD is presented. Single source
    /// of truth so both `TVPlayerControls` (presentation) and `PlayerView`
    /// (shell-level Menu / exit handling) can agree on state without relying
    /// on an indirection flag. Driven by `openHUD()` / `closeHUD()`.
    var isHUDPresented = false

    var isRecapSkipActive: Bool { skipWindow.inRecap }

    var introSkipLabel: String { isRecapSkipActive ? "Skip Recap" : "Skip Intro" }
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

    /// Signed rate of an in-flight seek session. Zero when the user isn't
    /// in seek mode. Positive = forward, negative = backward. Magnitudes
    /// are drawn from `Self.seekRates`. Entered by holding an arrow past
    /// the tap threshold; exited via Select (commit) or Menu (cancel).
    /// Within the session, D-pad Left/Right adjust the rate along the
    /// signed ladder (-8, -4, -2, -1, +1, +2, +4, +8).
    ///
    /// Observed by the tvOS shell to render the indicator chip and to
    /// keep the focus sink alive so press events aren't orphaned by a
    /// focus shift to the scrubber.
    var holdSeekRate: Int = 0
    /// Convenience — any non-zero rate means we're actively seeking.
    var isHoldSeeking: Bool { holdSeekRate != 0 }

    #if os(tvOS)
    enum TVHUDEntryPoint: Equatable {
        case settings
        case playback
    }

    var requestedTVHUDEntryPoint: TVHUDEntryPoint?
    #endif

    /// Signed speed ladder the user steps through with Left/Right taps
    /// during a seek session. No zero: "pause" is spelled as Select
    /// (commit) or Menu (cancel) rather than a neutral rate. The ladder
    /// tops out at 32× so a long file can be traversed in a few seconds
    /// of tapping; the auto-ramp on entry only reaches 8× so the faster
    /// rates require deliberate user steering.
    static let seekRates: [Int] = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]

    /// Canonical user volume/mute, owned by the VM. A fresh Vivid load can
    /// replace its internal route, so the VM reapplies these values and keeps
    /// the cast UI in sync.
    var userVolume: Float = 1.0
    var userMuted = false
    var streamLoadGeneration: UInt64 = 0
    var backendCapabilities: PlayerBackendCapabilities {
        let engine = vividPlaybackController.engine
        let selected = engine.activeSubtitleTrackIndex.flatMap { selectedID in
            engine.subtitleTracks.first { $0.id == selectedID }
        }
        let codec = selected?.codec.lowercased() ?? ""
        let authored = selected?.isNativelyRenderedSubtitle == true &&
            (SubtitleCodecClassifier.isBitmap(codec) || codec == "ass" || codec == "ssa")
        return .vivid(
            subtitleOverlayControls: !authored,
            hasTextSubtitleTrack: subtitleTracks.contains {
                !SubtitleCodecClassifier.isBitmap($0.codec)
            }
        )
    }
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
    /// One-line, user-facing Vivid route description for the player HUD.
    var playbackRouteDisplay: String {
        "\(VividPlaybackEngineIdentity.name) · \(activeRouteLabel)"
    }
    var routeStatusRows: [PlayerRouteStatusRow] {
        [
            PlayerRouteStatusRow(label: "Playback", value: activeRouteLabel),
            PlayerRouteStatusRow(label: "Engine", value: VividPlaybackEngineIdentity.name),
            PlayerRouteStatusRow(
                label: "Route",
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
    var hasTrackSelectionOptions: Bool { !audioTracks.isEmpty || !subtitleTracks.isEmpty }
    var supportsSecondarySubtitles: Bool { backendCapabilities.supportsSecondarySubtitles }
    /// `subtitleTracks` grouped by language and sorted by preferred format
    /// for display. The stored array stays in source/append order (the
    /// selection and track-replacement logic depends on it); ordering is a
    /// display-only projection. The two in-player pickers iterate this.
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
    /// Set in `cleanup()` / `deinit`. All async callbacks into the VM gate
    /// on this so a late-landing handoff signal can't spin up a fresh
    /// pipeline on a view that's already gone.
    var isDisposed = false
    var needsReplacementForPresentation: Bool { isDisposed }
    /// Whether Vivid currently has a receiver-fetchable native video route.
    /// Header-authenticated remote HLS remains false because the receiver
    /// cannot reproduce the sender's AVURLAsset request headers.
    var supportsExternalPlayback = false
    /// Mirrors the active AVPlayer route, with the AirPlay/HDMI audio route
    /// used only to bridge Vivid's transient native-item replacement gap.
    var isExternalPlaybackActive = false
    #if os(iOS)
    var isPlayerPresentationVisible = false
    /// AVKit's restore completion handler, held while the re-presented cover
    /// is still on its way to `PlayerView.onAppear`. See
    /// `restorePictureInPictureUserInterface`.
    var pendingRestoreCompletion: ((Bool) -> Void)?
    var pendingRestoreTimeoutTask: Task<Void, Never>?
    /// How long the re-presented cover gets to actually mount before the
    /// restore is treated as failed. Generous next to a SwiftUI presentation,
    /// short next to a session that would otherwise play on forever.
    static let pictureInPictureRestoreTimeoutNanoseconds: UInt64 = 3_000_000_000
    #endif
    /// True after the active backend reports natural EOF. Used to keep the
    /// UI in a terminal paused state without letting tail-drain callbacks
    /// overwrite it or surface a false decode error.
    var hasReachedEndOfFile = false
    var pendingUnexpectedEndEpoch: VividPlaybackController.LoadEpoch?
    let settings = PlayerSettings.shared
    let sleepTimer = SleepTimer()
    let nowPlaying = VividVideoNowPlayingCoordinator()
    /// Optional poster / backdrop URLs supplied by the presenter so the
    /// now-playing widget can publish artwork without re-fetching the
    /// catalog item just for poster URLs. Populated via
    /// `applyArtworkURLHints`. Nil falls back to a `/catalog/items/{id}`
    /// fetch in `pushNowPlayingArtwork`.
    var artworkPosterURLHint: String?
    var artworkBackdropURLHint: String?

    /// Rate-limits Now Playing updates. The OS animates scrubber progress
    /// between updates based on `playbackRate`, so we only need to push an
    /// elapsed-time field once every couple of seconds.
    var lastNowPlayingPush: Date = .distantPast

    let sessionBridge = PlaybackSessionBridge()
    @ObservationIgnored
    var realtimeClient: PlaybackRealtimeClient!
    /// A marker update can finish after the playback session starts but before
    /// the realtime websocket has connected. Reconcile once after the socket
    /// is live so that event-delivery race cannot hide intro/credits prompts
    /// for the current Vivid load.
    var introDBLookupTask: Task<Void, Never>?
    var loadedIntroDBSegments: VividIntroDBClient.Segments?


    private var cleanupCompletionTask: Task<Void, Never>?
    /// Natural EOF should not wait for the ten-second periodic reporter. Keep
    /// the immediate write so teardown/autoplay can await it before claiming
    /// and stopping the same server session.
    var naturalEndProgressTask: Task<Void, Never>?

    var hideControlsTask: Task<Void, Never>?
    #if os(iOS)
    var touchControlsPinned = false
    var touchControlPressed = false
    #endif
    var noticeDismissTask: Task<Void, Never>?
    var remoteDismissTask: Task<Void, Never>?
    var progressTask: Task<Void, Never>?
    var staleSessionRecoveryTask: Task<Void, Never>?
    /// Held so the init-time `refreshSettingsFromServer` call can be cancelled
    /// from `cleanup()`. Without a handle the task lingered on a dismissed VM
    /// and could observe `self` after dispose.
    var settingsRefreshTask: Task<Void, Never>?
    var freshLoadTask: Task<Void, Never>?
    var freshLoadGeneration: UInt64 = 0
    /// True while `freshLoadTask` is the sole owner of a load failure's
    /// outcome. Vivid publishes its typed failure before the load throws, so
    /// without this the direct-play and offline paths surface the same
    /// failure twice — once through `handleVividFailure` and again through
    /// the load's own catch.
    var freshLoadOwnsFailureHandling = false
    /// The most recent `audioTrackSwitchFailed` Vivid published while a load
    /// owned failure handling. The engine kills the in-flight load as part of
    /// the same rebuild, so the load's own catch sees only a cancellation and
    /// would otherwise have no idea why it was abandoned.
    @ObservationIgnored
    var lastVividAudioTrackSwitchFailure: PlaybackErrorInfo?
    /// Serializes every Protocol V3 source replacement, including a same-plan
    /// reload whose only change is a refreshed bearer. Reusing this gate keeps
    /// credential recovery from racing route replans, seeks, or track changes.
    var protocolV3ReplanTask: Task<Void, Never>?
    var authenticationRecoveryBudget = VividAuthenticationRecoveryBudget()
    var transientRecoveryBudget = VividTransientRecoveryBudget()
    @ObservationIgnored var prematureEndRecoveryGate = VividPrematureEndRecoveryGate()
    var authenticationReloadGeneration: UInt64?
    var nextUpLookupTask: Task<Void, Never>?
    var nextUpOnDeckTask: Task<Void, Never>?
    var nextUpCountdownTask: Task<Void, Never>?
    /// Trailing-edge skip debounce: each tap updates the preview and resets
    /// this timer. The seek fires exactly once, after `skipDebounceNanos` of
    /// quiet. A leading-edge seek was tempting for responsiveness but led
    /// to visible stutter on bursts — the video would seek to tap #1, play
    /// briefly, and then jump again on the trailing commit. A single
    /// deferred seek is smooth at any burst length.
    var skipDebounceTask: Task<Void, Never>?
    /// Button skips share the seek preview, but must not fade touch controls.
    var isTimelineScrubbing: Bool { isScrubbing && skipDebounceTask == nil }
    let skipDebounceNanos: UInt64 = 200_000_000 // 200ms

    /// Drives the repeating preview advance while a seek session is
    /// active. Ticks at `holdSeekTickNanos`, advancing `scrubPreviewTime`
    /// by `holdSeekBaseStep * holdSeekRate` seconds each tick. Runs
    /// until `commitHoldSeek` / `cancelHoldSeek`.
    var holdSeekTask: Task<Void, Never>?
    /// Auto-ramps the rate magnitude 1 → 2 → 4 → 8 during the first ~4 s
    /// of a hold so the user gets acceleration without having to manually
    /// tap up. Cancelled the moment the user manually adjusts the rate
    /// — they've taken control, stop second-guessing them.
    var holdSeekAutoRampTask: Task<Void, Never>?
    static let holdSeekBaseStep: Double = 2.0 // seconds per tick at 1x
    static let holdSeekTickNanos: UInt64 = 100_000_000 // 100ms (10Hz)

    /// Seek-in-flight filter: both the pre-seek playhead and the target we
    /// asked Vivid to jump to. Clock reports that are closer to
    /// `seekOriginTime` than to `seekTargetTime` are treated as stale and
    /// dropped. This is direction-agnostic and handles back-to-back seeks.
    /// The filter releases as soon as a report crosses the midpoint
    /// between origin and target, which is the earliest point we can
    /// confidently say the new position has landed. Safety timeout below
    /// drops the filter if no matching report arrives (e.g. transport
    /// error on HLS transcode), since a stuck filter would pin the
    /// scrubber to the optimistic target forever.
    var seekOriginTime: Double?
    var seekTargetTime: Double?
    var seekFilterTimeoutTask: Task<Void, Never>?
    /// The in-flight `commitSeek` await. Held so a new load can cancel a seek
    /// whose `.requiresReplan` answer would otherwise arrive after the item
    /// it was issued against is gone.
    var seekReplanTask: Task<Void, Never>?
    static let seekFilterNanos: UInt64 = 5_000_000_000 // 5s
    /// Identity of the active offline download when playback was prepared
    /// locally (no server session). While set, watch progress is routed to
    /// `DownloadManager.recordOfflineProgress` — which queues it for the
    /// next `/sync/progress` flush — instead of the session bridge, so
    /// nothing on this path ever hits a server session/progress endpoint.
    struct OfflinePlaybackContext {
        let downloadId: String
        let mediaItemId: String
    }
    var offlinePlaybackContext: OfflinePlaybackContext?
    /// Server-supplied preferred track indices (ffmpeg stream indices). Kept
    /// until we've observed a matching track in the core's track-list and
    /// applied it, or until the user makes a manual selection.
    var pendingAudioFfIndex: Int?
    var pendingSubtitleFfIndex: Int?
    /// True when the most recent `loadAndPlay` came in with an explicit
    /// subtitle index from the caller (route arg / detail screen). The
    /// auto-resolver yields to the user in that case.
    var hasExplicitSubtitleChoice: Bool = false
    /// External subtitle picks don't have an FFmpeg stream index, so a
    /// reload/resume has to remember the synthesised sidecar `trackId`
    /// and re-apply it once `subtitle_urls` have been registered again.
    var pendingSidecarSubtitleTrackId: Int64?
    /// A protocol-v3 subtitle can remain represented by a sidecar picker row
    /// even when the replacement plan renders it on the server (for example,
    /// bitmap PGS subtitles burned into HLS). Preserve that picker selection
    /// across an Vivid reload without also opening the sidecar locally.
    var pendingServerRenderedSubtitleTrackId: Int64?
    /// Local subtitle preferences captured for the current item. Applied
    /// after Lucid Engine publishes its embedded tracks and cleared on cleanup.
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
    }
    /// Set after the resolver has fired once for the current item so we
    /// don't keep re-evaluating (and overriding the user) on every
    /// subsequent track-list update.
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
    var staleSessionRecoverySessionId: String?
    struct LoadRequest {
        let contentId: String
        let preferredFileId: Int?
        let preferredAudioTrackIndex: Int?
        let preferredSubtitleTrackIndex: Int?
        let preferredSidecarSubtitleTrackId: Int64?
        let startFromBeginning: Bool
        /// Authoritative protocol-v3 combined ordinal. Unlike
        /// `preferredSubtitleTrackIndex`, this also represents external,
        /// downloaded, and server-extracted subtitle rows.
        var preferredProtocolV3SubtitleIndex: Int? = nil
        /// Set for local playback of a completed download. Routes the
        /// prepare through `OfflinePlaybackBuilder` instead of a server
        /// session, so retry after an error stays on the offline path.
        var offlineDownloadId: String? = nil
        /// Explicit quality for this load (mid-stream quality-change replan);
        /// wins over `PlayerSettings.preferredQuality` in the bridge.
        var preferredQualityOverride: String? = nil
        /// Set when `preferredQualityOverride` carries the current playback's
        /// quality forward rather than a new in-player choice: the load repeats
        /// this cap instead of deriving one from the override id. Nil means the
        /// override is a fresh choice (or there is none).
        var carriedBandwidthCap: CarriedBandwidthCap? = nil
        /// Continue Watching only: select the server's last-used source file
        /// before applying the profile-wide automatic quality preference.
        var prefersLastUsedVersion = false

        /// Rebuild a request for the same playback session while retaining the
        /// user's temporary quality choice. Recovery must not fall back to the
        /// persisted preference merely because tracks or the file id changed.
        func copyForRecovery(
            preferredFileId: Int?,
            preferredAudioTrackIndex: Int?,
            preferredSubtitleTrackIndex: Int?,
            preferredSidecarSubtitleTrackId: Int64?,
            offlineDownloadId: String?,
            serverSubtitlesDisabled: Bool = false
        ) -> LoadRequest {
            var request = LoadRequest(
                contentId: contentId,
                preferredFileId: preferredFileId,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
                preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
                startFromBeginning: false,
                offlineDownloadId: offlineDownloadId,
                preferredQualityOverride: preferredQualityOverride,
                carriedBandwidthCap: carriedBandwidthCap
            )
            // A completed download can be selected after the last server plan.
            // Ask the replacement session for that combined ordinal; retaining
            // the old plan's ordinal would reselect its embedded subtitle.
            // Local decoder Off also accompanies burn-in. Only an explicit
            // server disable may erase the server's selected ordinal.
            if serverSubtitlesDisabled {
                request.preferredProtocolV3SubtitleIndex = nil
            } else if let preferredSidecarSubtitleTrackId,
                      SubtitleTrackIdSpace.isSidecar(preferredSidecarSubtitleTrackId) {
                request.preferredProtocolV3SubtitleIndex = SubtitleTrackIdSpace.sidecarIndex(
                    from: preferredSidecarSubtitleTrackId
                )
            } else {
                request.preferredProtocolV3SubtitleIndex = preferredProtocolV3SubtitleIndex
            }
            request.prefersLastUsedVersion = prefersLastUsedVersion
            return request
        }

        /// Refresh the inputs used by session renewal from an adopted V3 plan.
        /// Player track lists are transient and may already be empty when a
        /// failed transport reports that its server session disappeared.
        func adoptingProtocolV3Intent(
            plan: PlaybackV3Plan,
            selectedVersion: FileVersion,
            activeQualityId: String,
            bandwidthCap: CarriedBandwidthCap = .savedSetting
        ) -> LoadRequest {
            // Shared resolution order; see
            // `PlaybackV3Plan.selectedSubtitleInventoryItem`. An `off` plan
            // selects nothing even if it still carries a stale identity.
            let isSubtitleOff = plan.subtitle.mode == PlaybackProtocolV3.SubtitleMode.off
            let selectedSubtitleIndex = isSubtitleOff
                ? nil
                : plan.selectedSubtitleCombinedIndex
            let selectedSubtitle = isSubtitleOff ? nil : plan.selectedSubtitleInventoryItem
            let embeddedFFmpegIndex: Int? = selectedSubtitle.flatMap { item in
                // A sidecar is the server-selected artifact even when it was
                // extracted from an embedded stream. Arming both identities
                // would publish and select the same subtitle twice.
                if let embedded = plan.subtitle.embedded { return embedded.streamIndex }
                guard item.source == "embedded", item.delivery != "sidecar" else { return nil }
                return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                    serverCombinedIndex: item.combinedIndex,
                    in: selectedVersion,
                    inventory: plan.subtitle.inventory
                )
            }
            let sidecarTrackId: Int64? = selectedSubtitle.flatMap { item in
                guard plan.subtitle.embedded == nil, item.delivery == "sidecar" else { return nil }
                return SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            }
            var request = copyForRecovery(
                preferredFileId: plan.effectiveMediaFileId,
                preferredAudioTrackIndex: plan.selectedTracks.audio?.index,
                preferredSubtitleTrackIndex: embeddedFFmpegIndex,
                preferredSidecarSubtitleTrackId: sidecarTrackId,
                offlineDownloadId: offlineDownloadId
            )
            request.preferredProtocolV3SubtitleIndex = selectedSubtitleIndex
            request.preferredQualityOverride = activeQualityId
            // Renewal repeats this plan's quality, so it keeps the plan's cap.
            request.carriedBandwidthCap = bandwidthCap
            return request
        }
    }

    /// Where a `beginFreshLoad` invocation came from. Determines (a) whether
    /// `startSession` is bounded by a timeout and (b) how a load failure is
    /// surfaced to the user. The trigger is orthogonal to the `LoadRequest`
    /// itself, so it's threaded as a separate parameter.
    enum LoadOrigin {
        /// User picked an item — no timeout, full-screen error on failure.
        case userInitiated
        /// Auto-play hand-off from the Next Up postroll — timeout-bounded,
        /// failures restore the postroll with `nextUpStartError` set.
        case autoplay
        /// Automatic playback recovery. Failures stay on the player surface
        /// instead of using the Next Up postroll.
        case recovery
    }

    enum BeginFreshLoadError: Error {
        case startSessionTimeout
    }

    static let autoplayStartSessionTimeout: TimeInterval = 15
    @ObservationIgnored var watchTimeGate = PlaybackWatchTimeGate()
    var completedPlaybackContentId: String?
    var progressIsEligible: Bool { watchTimeGate.isEligible || completedPlaybackContentId != nil }
    var lastLoadRequest: LoadRequest?
    static let nextUpCountdownDefaultSeconds = 10
    static let nextUpHUDCountdownThresholdSeconds: Double = 100
    static let introAutoSkipCountdownDefaultSeconds = 5
    static var nextUpCountdownTotal: Int { nextUpCountdownDefaultSeconds }
    var nextUpAutoplayCancelled = false
    /// Set when the user taps Keep Watching; suppresses re-presenting the
    /// pre-end Next Up prompt while the playhead stays inside the prompt
    /// window. Cleared when the playhead leaves the window (seek back) or a
    /// new item loads, so the prompt can appear again naturally. Does not
    /// apply to the end-of-playback screen.
    @ObservationIgnored var nextUpPromptDismissed = false
    var contentIdsNeedingDetailRefresh: Set<String> = []
    #if os(iOS) || os(tvOS)
    @ObservationIgnored
    var refreshHomeAfterPlaybackWrite: (@MainActor () -> Void)?
    #endif
    /// Items that crossed the same completion boundary used by the final
    /// server progress report. The tvOS detail page consumes this only after
    /// that report has finished so it can move its editorial selection to the
    /// next unwatched episode without racing stale catalog data.
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

    /// Re-applies subtitle styling when the user edits the system's
    /// Subtitles & Captioning preferences mid-playback.
    private var systemCaptionObserverToken: NSObjectProtocol?
    /// Triggers a V3 replan when the audio route the session was planned
    /// against changes. iOS/tvOS only — macOS has no `AVAudioSession`.
    private var outputRouteObserverToken: NSObjectProtocol?
    /// Flushes the resume point when the app is about to stop getting
    /// foreground time. The periodic reporter ticks every 10s, so without
    /// this a backgrounded (or terminated) player loses up to that much
    /// progress. Deliberately does not stop the session — PiP and background
    /// audio keep playing after this fires.
    private var foregroundExitObserverToken: NSObjectProtocol?

    #if os(iOS) || os(tvOS)
    var openSubtitleFiles = OpenSubtitleSessionFiles()
    #endif
    /// Silo external subtitle files for the current load, by sidecar track ID.
    /// They're fetched only when chosen, because each fetch can start a
    /// server subtitle sync job.
    var lazySubtitleSidecars: [Int64: ExternalSubtitleTrack] = [:]
    /// A Silo external file picked on this device. Silo never sees it, so
    /// replacement loads of the same file re-apply it here.
    var localExternalSubtitlePick: (trackID: Int64, contentID: String, fileID: Int?)?

    init() {
        do {
            vividPlaybackController = try VividPlaybackController()
        } catch {
            fatalError("VividEngine initialization failed: \(error)")
        }
        scrubPreviewProvider = VividScrubPreviewProvider(
            engine: vividPlaybackController.engine
        )
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

        systemCaptionObserverToken = NotificationCenter.default.addObserver(
            forName: SystemCaptionAppearance.settingsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed,
                      self.settings.subtitleMatchesSystemAppearance else { return }
                self.settings.refreshSubtitleSystemAppearance()
                self.applySubtitleAppearanceToPlayer()
                self.subtitleOrderingLanguage = self.settings
                    .subtitleSystemSelectionPreferences.preferredLanguages.first
                guard !self.hasExplicitSubtitleChoice else { return }
                self.prefsForCurrentItem = self.systemCaptionPrefsSnapshot()
                self.prefsResolvedForCurrentItem = false
                self.applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
            }
        }
        #if !os(macOS)
        outputRouteObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let activeProtocolV3 = self.activePreparedProtocolV3,
                      !self.isDisposed,
                      !self.isLoading else { return }
                let observedSnapshot = ApplePlaybackV3Capabilities.snapshot()
                guard PlaybackSessionBridge.isMaterialOutputRouteChange(
                    activeOutputContextId: activeProtocolV3.outputContextId,
                    observedOutputContextId: observedSnapshot.outputContextId
                ) else {
                    Self.logger.debug(
                        "Ignoring AVAudioSession route notification with unchanged Playback V3 output context"
                    )
                    return
                }
                self.attemptProtocolV3Replan(
                    position: self.currentTime,
                    classification: "output_route_changed",
                    message: "The Apple audio output route changed.",
                    outputRouteSnapshot: observedSnapshot
                )
            }
        }
        #endif
        #if os(iOS) || os(tvOS)
        let foregroundExitNotification = UIApplication.didEnterBackgroundNotification
        #else
        let foregroundExitNotification = NSApplication.willTerminateNotification
        #endif
        foregroundExitObserverToken = NotificationCenter.default.addObserver(
            forName: foregroundExitNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushPlaybackProgressNow(reason: "foreground_exit")
            }
        }
        settingsRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshSettingsFromServer()
        }
    }

    @MainActor
    func cleanup() {
        guard !isDisposed else { return }
        #if os(iOS) || os(tvOS)
        AppHealthMonitor.playerClosed()
        #endif
        qualityFallbackTask?.cancel()
        qualityFallbackTask = nil
        Self.logger.info("PlayerViewModel.cleanup()")
        let currentItemCompleted = completedPlaybackContentId != nil
        recordCurrentPlaybackMutation(markedCompleted: currentItemCompleted)
        let pendingNaturalEndProgressTask = naturalEndProgressTask
        naturalEndProgressTask = nil
        isDisposed = true
        transientRecoveryBudget.cancel()
        #if os(iOS)
        // A restore waiting on a cover that will now never mount has to be
        // answered, or AVKit is left holding a handler for a dead session.
        resolvePendingPictureInPictureRestore(false)
        // The PiP coordinator is a singleton and its controller strongly
        // retains the AVPlayerLayer, the AVPlayer, and everything hanging off
        // it. SwiftUI's `dismantleUIView` normally releases it, but ordering
        // there is not guaranteed relative to this teardown, so drop it here
        // too rather than risk stranding the whole playback graph. Owner-keyed
        // so a late teardown cannot unbind a newer session's PiP.
        PictureInPictureCoordinator.shared.endSession(owner: self)
        // A restore that staged this view model but never reached SwiftUI would
        // otherwise hold the whole playback graph on a static.
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
        if let outputRouteObserverToken {
            NotificationCenter.default.removeObserver(outputRouteObserverToken)
            self.outputRouteObserverToken = nil
        }
        if let systemCaptionObserverToken {
            NotificationCenter.default.removeObserver(systemCaptionObserverToken)
            self.systemCaptionObserverToken = nil
        }
        if let foregroundExitObserverToken {
            NotificationCenter.default.removeObserver(foregroundExitObserverToken)
            self.foregroundExitObserverToken = nil
        }
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

        // Final offline progress flush before teardown — the counterpart of
        // the online path's `stopSession` report below. Captured into locals
        // so the detached task doesn't read torn-down player state.
        // Offline playback has no server session of its own (the fresh-load
        // path finalized any prior one), so skip the server stop below —
        // it would report the offline position against a stale session.
        let stopServerSessionOnTeardown = offlinePlaybackContext == nil
        if let offline = offlinePlaybackContext {
            let finalOfflinePosition = completionProgressPositionForCurrentItem()
            let endedNaturally = completedPlaybackContentId != nil
            // Strong capture on purpose: this is the last write of the
            // resume point and must not be dropped because the VM was
            // released between dismiss and the hop to the MainActor.
            Task { @MainActor in
                self.recordOfflineProgress(
                    context: offline,
                    position: finalOfflinePosition,
                    markCompleted: endedNaturally
                )
            }
        }

        // Preserve the real position. Watched completion is sent separately
        // after progress and Stop, using the same policy as offline playback.
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
            if stopServerSessionOnTeardown {
                // Commit the resume point first. Session event bookkeeping and
                // DELETE can finish afterward; neither changes Continue
                // Watching, so making Home wait for them only leaves stale
                // progress visible after the player has closed.
                let progressResult = await sessionBridge.reportProgress(
                    position: finalPosition,
                    isPaused: true, eligible: finalProgressEligible, completedContentId: finalCompletedContentId
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
                            completedContentIds: PlaybackProgressCommitPolicy
                                .confirmedCompletedContentIds(
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

    @MainActor
    func waitForCleanupCompletion() async {
        // onDisappear calls cleanup immediately before unregistering the TV
        // receiver. Yield briefly if presentation teardown has not installed
        // the final progress task yet.
        for _ in 0..<100 where cleanupCompletionTask == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await cleanupCompletionTask?.value
    }

    /// Safety net: SwiftUI normally drives `cleanup()` from `PlayerView.onDisappear`,
    /// but if that path is missed (edge cases in sheet/NavigationStack teardown)
    /// we still need to guarantee the backend is torn down so audio can't
    /// outlive the view. `dispose()` is idempotent.
    deinit {
        print("[CMP-LIFE] deinit PlayerViewModel")
        MainActor.assumeIsolated {
            Self.logger.info("PlayerViewModel.deinit")
            isDisposed = true
            playbackStatsRefreshTask?.cancel()
            transientRecoveryBudget.cancel()
            if let systemCaptionObserverToken {
                NotificationCenter.default.removeObserver(systemCaptionObserverToken)
            }
            if let outputRouteObserverToken {
                NotificationCenter.default.removeObserver(outputRouteObserverToken)
            }
            if let foregroundExitObserverToken {
                NotificationCenter.default.removeObserver(foregroundExitObserverToken)
            }
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

/// Marker ranges containing the playhead. Ranges are start-inclusive and
/// end-exclusive, matching the skip buttons and auto-skip checks.
struct PlayerSkipWindow: Equatable {
    var inRecap = false
    var inIntro = false
    var inCredits = false

    init() {}

    init(time: Double, recap: TimeRange?, intro: TimeRange?, credits: TimeRange?) {
        func contains(_ range: TimeRange?) -> Bool {
            guard let range else { return false }
            return time >= range.start && time < range.end
        }
        inRecap = contains(recap)
        inIntro = contains(intro)
        inCredits = contains(credits)
    }
}
