import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Posted the moment the final position has reached the server, so Home can
/// refresh without waiting for the rest of the session to wind down.
struct PlaybackProgressCommittedEvent {
    let contentIds: Set<String>
    let completedContentIds: Set<String>
}

extension Notification.Name {
    static let playbackProgressDidCommit = Notification.Name("playbackProgressDidCommit")
}

#if os(tvOS)
/// Posted once the final progress is saved and every detail page still in
/// memory for the items that played has reloaded.
struct TVPlaybackStateRefreshEvent {
    let refreshedContentIds: Set<String>
    let completedContentIds: Set<String>
}

extension Notification.Name {
    static let tvPlaybackStateDidRefresh = Notification.Name("tvPlaybackStateDidRefresh")
}
#endif

/// The full-screen player. It hosts the video surface from
/// `PlayerViewModel` and lays each platform's controls over it: touch
/// controls with anchored popovers on iPhone and iPad, and on Apple TV a
/// focus-driven transport bar with the floating HUD for routes, tracks,
/// chapters and playback settings.
struct PlayerView: View {
    let contentId: String
    let preferredFileId: Int?
    let preferredAudioTrackIndex: Int?
    let preferredSubtitleTrackIndex: Int?
    /// Set when the caller asked to start over instead of resuming where
    /// the server left off. The session bridge receives it so direct play
    /// and transcodes start at the same place.
    let startFromBeginning: Bool
    let resumePositionOverride: Double?
    let prefersLastUsedVersion: Bool
    /// Set to play a finished download offline. Loading then goes through
    /// `OfflinePlaybackBuilder` (the saved manifest and the local file, no
    /// server session), so it works without a network and progress waits for
    /// the next `/sync/progress` upload.
    let offlineDownloadId: String?
    /// Artwork the presenting screen already has. With it, Now Playing
    /// doesn't fetch the catalogue item just for artwork; without it, the
    /// usual fetch while preparing runs.
    let posterURLHint: String?
    let backdropURLHint: String?
    let onPlaybackStarted: (() -> Void)?
    let onDismissRequested: (() -> Void)?

    @State private var player = PlayerViewModel()
    @State private var hasReportedPlayback = false
    @Environment(\.dismiss) var dismiss
    #if os(iOS)
    @State private var orientation = PlayerOrientationCoordinator.shared
    /// Set while an iPhone Duo is half folded like a laptop: video above the
    /// crease, controls below.
    @State private var duoTabletop: DuoTabletop?
    #endif
    #if os(tvOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var showsTimelinePeek = false
    @State private var timeReadout: TVPlayerTimeDisplayMode = .elapsedRemaining
    @State private var timelineFocusRequest: UUID?
    @State private var peekHideTask: Task<Void, Never>?
    @State private var touchMayToggleReadout = false
    #endif

    init(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePositionOverride: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        offlineDownloadId: String? = nil,
        posterURLHint: String? = nil,
        backdropURLHint: String? = nil,
        onPlaybackStarted: (() -> Void)? = nil,
        onDismissRequested: (() -> Void)? = nil
    ) {
        self.contentId = contentId
        self.preferredFileId = preferredFileId
        self.preferredAudioTrackIndex = preferredAudioTrackIndex
        self.preferredSubtitleTrackIndex = preferredSubtitleTrackIndex
        self.startFromBeginning = startFromBeginning
        self.resumePositionOverride = resumePositionOverride
        self.prefersLastUsedVersion = prefersLastUsedVersion
        self.offlineDownloadId = offlineDownloadId
        self.posterURLHint = posterURLHint
        self.backdropURLHint = backdropURLHint
        self.onPlaybackStarted = onPlaybackStarted
        self.onDismissRequested = onDismissRequested
    }

    var body: some View {
        PlayerSurfaceLayout(isPreview: player.showNextUpScreen,
                            isTransitioning: player.isNextUpTransitioning,
                            topRegionHeight: tabletopVideoHeight) {
            videoLayer
        } content: {
            backdropLayer
        }
        .overlay(alignment: .top) { foregroundLayer }
        #if os(iOS)
        .overlay(alignment: .topTrailing) { rotationButtons }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            orientation.refreshInterfaceOrientation()
        }
        .onDuoTabletopChange { tabletop in
            duoTabletop = tabletop
            orientation.setDuoTabletop(tabletop != nil)
        }
        #endif
        #if os(tvOS)
        // The remote's Play/Pause button always works, and on Next Up it
        // starts the next episode.
        .onPlayPauseCommand(perform: handlePlayPausePress)
        // Menu unwinds one layer at a time (see `handleMenuPress`). It sits
        // on the whole screen so it still works if focus has wandered; the
        // HUD's own `onExitCommand` deals with the usual case of focus inside
        // it.
        .onExitCommand(perform: handleMenuPress)
        #endif
        .onChange(of: player.settings.introDBEnabled) { _, _ in
            player.refreshIntroDBPreference()
        }
        .onChange(of: player.isPlaying) { _, playing in
            reportFirstPlayback(playing)
        }
        #if os(tvOS)
        .onChange(of: scenePhase) { _, phase in
            guard isOnScreen else { return }
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .onChange(of: player.showControls) { _, shown in
            controlsVisibilityChanged(shown)
        }
        #endif
        .onChange(of: player.remoteDismissToken) { _, token in
            if token != nil { closePlayer() }
        }
        .onAppear(perform: presentationDidAppear)
        .onDisappear(perform: presentationDidDisappear)
        .vividStatusBarHidden()
        #if !os(tvOS)
        .navigationBarHidden(true)
        #endif
        .preferredColorScheme(.dark)
    }

    // MARK: Layers

    private var hasFailure: Bool { player.error != nil }

    /// The video, hidden behind the failure panel when playback has failed.
    private var videoLayer: some View {
        surfaceWithSubtitles()
            .opacity(hasFailure ? 0 : 1)
            .accessibilityHidden(hasFailure)
    }

    /// Black behind the video, and the Next Up screen once it has settled.
    private var backdropLayer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                #if os(iOS)
                .onTapGesture(perform: revealControlsBeforeLoad)
                #endif
            if showsNextUpScreen {
                PlayerNextUpScreen(viewModel: player, onBack: leaveNextUp)
            }
        }
    }

    private var showsNextUpScreen: Bool {
        player.showNextUpScreen && !player.isNextUpTransitioning && !hasFailure
    }

    /// The failure panel, or the controls and loading indicator.
    private var foregroundLayer: some View {
        ZStack(alignment: .top) {
            if let error = player.error {
                PlaybackFailurePanel(error: error, onRetry: player.retry, onBack: closePlayer)
            } else {
                #if os(iOS)
                if player.showNextUpScreen { earlyCloseButton }
                #endif
                if !player.showNextUpScreen {
                    playbackControls
                }

                PlayerLoadingIndicator(
                    isLoading: player.isLoading,
                    isBuffering: player.isBuffering,
                    isPlaying: player.isPlaying,
                    currentTime: { player.currentTime }
                )
                #if os(iOS)
                .duoTabletopTopHalf(duoTabletop)
                #endif
            }
        }
    }

    /// The controls shown while an item plays (not on Next Up).
    @ViewBuilder
    private var playbackControls: some View {
        #if os(tvOS)
        if remoteCaptureIsActive {
            TVPressCaptureView(
                onArrowTap: handleArrowTap,
                onArrowHoldBegin: handleArrowHold,
                onDirectionalPressBegan: { touchMayToggleReadout = false },
                onTouchSurfaceContactBegan: peekTouchBegan,
                onTouchSurfaceContactEnded: peekTouchEnded,
                onTouchSurfaceContactCancelled: peekTouchCancelled,
                onSelect: handleSelectPress
            )
            .ignoresSafeArea()
        }

        if mountsTransportControls {
            TVPlayerControls(
                viewModel: player,
                showsTimelinePreview: showsTimelinePeek,
                timeDisplayMode: timeReadout,
                timelineSelectionRequest: timelineFocusRequest,
                onToggleTimeDisplayMode: toggleTimeDisplayModeAnimated,
                onDismiss: { closePlayer() }
            )
        }

        // While a hold-to-seek session runs, the transport bar is unmounted so
        // the capture view keeps focus, which makes this chip the only
        // feedback until Select commits or Menu cancels.
        if player.isHoldSeeking {
            HoldSeekIndicator(
                rate: player.holdSeekRate,
                previewTime: player.scrubPreviewTime,
                duration: player.duration,
                previewImage: player.scrubPreviewImage
            )
            .transition(.opacity)
            .allowsHitTesting(false)
        }
        #else
        // The controls (with their own close button) only appear once the
        // file has opened, so until then a tap shows this close button.
        // Apple TV closes with Menu instead.
        if player.isLoading {
            earlyCloseButton
        }

        if !player.isLoading {
            // The invisible gestures (tap to show or hide, double-tap to
            // skip, hold for 2x, pinch) sit under the buttons.
            MobilePlayerGestureLayer(viewModel: player)
                .duoTabletopTopHalf(duoTabletop)
        }
        MobilePlayerControls(
            viewModel: player,
            onDismiss: { closePlayer() },
            tabletop: duoTabletop
        )
        #endif

        if let notice = player.activeNotice {
            PlayerNoticeOverlay(notice: notice)
        }
    }

    /// The video surface. Apple TV drives it through focus; on iPhone and
    /// iPad the touch gestures live in `MobilePlayerGestureLayer` above it.
    /// Vivid chooses the native or software route behind this one surface.
    private func surfaceWithSubtitles() -> some View {
        VividPlayerSurface(engine: player.vividEngine)
            .background(Color.black)
            .overlay { subtitleLayer }
    }

    private var subtitleLayer: some View {
        VividSubtitleOverlay(
            engine: player.vividEngine,
            sourceTime: { player.currentTime },
            primaryUsesMovieTimeline: player.subtitleUsesMovieTimeline(player.selectedSubtitleId),
            secondaryUsesMovieTimeline: player.subtitleUsesMovieTimeline(player.selectedSecondarySubtitleId, slot: .secondary),
            appearance: player.settings.effectiveSubtitleAppearance,
            subtitleSyncMs: player.subtitleDelayMs,
            secondarySubtitleSyncMs: player.secondarySubtitleDelayMs
        )
        .onChange(of: player.settings.effectiveSubtitleAppearance, initial: true) {
            player.applySubtitleAppearanceToPlayer()
        }
        .onChange(of: [player.subtitleDelayMs, player.secondarySubtitleDelayMs]) {
            // Switching to or from an OpenSubtitles file changes these too.
            player.applySubtitleAppearanceToPlayer()
        }
    }

    /// How tall the video is above the crease of a half-folded iPhone Duo.
    private var tabletopVideoHeight: CGFloat? {
        #if os(iOS)
        duoTabletop?.crease.minY
        #else
        nil
        #endif
    }

    // MARK: Presentation

    private func presentationDidAppear() {
        #if os(tvOS)
        // Keep the screen awake for as long as the player is up, paused or
        // not. Playback state has no say over the idle timer here.
        isOnScreen = true
        UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
        #endif
        #if os(iOS)
        // Coming back from Picture in Picture shows this cover again for a
        // session that never stopped. Take over that model as it is, without
        // making a new one or loading anything.
        if let resumed = PlayerPresentationRestoration.consumeAdoption(matching: contentId) {
            player = resumed
            attachMobilePresentation(to: resumed)
            return
        }
        #endif
        let model = modelForThisPresentation()
        #if os(iOS)
        attachMobilePresentation(to: model)
        #endif
        model.applyArtworkURLHints(posterURL: posterURLHint, backdropURL: backdropURLHint)
        model.loadAndPlay(
            contentId: contentId,
            preferredFileId: preferredFileId,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePositionOverride: resumePositionOverride,
            prefersLastUsedVersion: prefersLastUsedVersion,
            offlineDownloadId: offlineDownloadId
        )
    }

    /// The model this appearance plays with: the current one, or a fresh one
    /// when the current one can't be used for another presentation.
    private func modelForThisPresentation() -> PlayerViewModel {
        guard player.needsReplacementForPresentation else { return player }
        let fresh = PlayerViewModel()
        player = fresh
        return fresh
    }

    private func presentationDidDisappear() {
        #if os(tvOS)
        isOnScreen = false
        UIApplication.shared.isIdleTimerDisabled = false
        peekHideTask?.cancel()
        peekHideTask = nil
        #endif
        #if os(iOS)
        player.playerPresentationDidDisappear()
        orientation.deactivatePlayer()
        #else
        player.cleanup()
        #endif
        #if os(tvOS)
        // A detail or Home read started by this same disappearance could
        // overtake cleanup's final progress write and cache the old watched
        // state. So the affected items are noted now, and the caches are only
        // cleared and reloaded once the session bridge has finished writing.
        let played: Set<String> = player.contentIdsNeedingDetailRefresh.isEmpty
            ? [contentId]
            : player.contentIdsNeedingDetailRefresh
        let finished = player.completedContentIdsNeedingDetailAdvance
        Task { @MainActor in
            await player.waitForCleanupCompletion()
            await Self.refreshScreensAfterPlayback(played: played, finished: finished)
        }
        #endif
    }

    #if os(tvOS)
    @MainActor
    private static func refreshScreensAfterPlayback(played: Set<String>, finished: Set<String>) async {
        // A Home request may have begun as the cover went away. Retire it
        // before asking for the Continue Watching row the finished write
        // produced.
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        ResponseCache.shared.remove(CacheKey.homeSections)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)

        let reloaded = await ItemDetailCache.shared.refreshAfterPlayback(contentIds: played)
        let event = TVPlaybackStateRefreshEvent(refreshedContentIds: reloaded, completedContentIds: finished)
        NotificationCenter.default.post(name: .tvPlaybackStateDidRefresh, object: event)
    }
    #endif

    private func reportFirstPlayback(_ playing: Bool) {
        guard playing, !hasReportedPlayback else { return }
        hasReportedPlayback = true
        onPlaybackStarted?()
    }

    private func leaveNextUp() {
        if !player.keepWatchingCurrentEpisode() {
            closePlayer()
        }
    }

    private func closePlayer() {
        #if os(iOS)
        orientation.refreshInterfaceOrientation()
        let phoneInLandscape = UIDevice.current.userInterfaceIdiom == .phone
            && orientation.observedOrientation == .landscape
        if phoneInLandscape {
            var still = Transaction(animation: nil)
            still.disablesAnimations = true
            UIView.performWithoutAnimation {
                withTransaction(still) {
                    orientation.deactivatePlayer()
                    finishClosing()
                }
            }
            return
        }
        orientation.deactivatePlayer()
        #endif
        finishClosing()
    }

    private func finishClosing() {
        player.cleanup()
        guard let onDismissRequested else {
            dismiss()
            return
        }
        onDismissRequested()
    }

    #if os(iOS)
    // MARK: iPhone and iPad

    private func revealControlsBeforeLoad() {
        // Once loaded, MobilePlayerGestureLayer handles taps. Until it's
        // there, a tap still has to show the controls.
        if player.isLoading || hasFailure {
            player.toggleControls(cause: .loadingTap)
        }
    }

    /// Hooks a model up to this cover: orientation, presentation and
    /// Picture in Picture, in that order.
    private func attachMobilePresentation(to model: PlayerViewModel) {
        orientation.activatePlayer()
        model.playerPresentationDidAppear()
        hookUpPictureInPicture(to: model)
    }

    /// The single place the PiP hooks are installed, so the restore and
    /// start-failure handlers can't end up on one path and missing from the
    /// other.
    private func hookUpPictureInPicture(to model: PlayerViewModel) {
        PictureInPictureCoordinator.shared.bind(
            engine: model.vividEngine,
            owner: model,
            onEngagementEnded: { [weak model] in
                model?.pictureInPictureEngagementDidEnd()
            },
            onRestoreUserInterface: { [weak model] completion in
                // With the engaged player gone, AVKit must hear that the
                // interface did not come back.
                guard let model else { return completion(false) }
                model.restorePictureInPictureUserInterface(completion)
            },
            onStartFailure: { [weak model] failure in
                model?.reportPictureInPictureStartFailure(failure)
            }
        )
    }

    private var rotationButtons: some View {
        MobilePlayerRotationControls(
            orientationCoordinator: orientation,
            isVisible: player.shouldShowMobilePlayerChrome && duoTabletop == nil
        ) {
            player.resumeAutoHide()
        }
        .padding(.horizontal)
        .padding(.top)
    }

    /// The close button for loading and Next Up, shown by a tap. It matches
    /// the close button in `MobilePlayerControls`' top strip in place, size
    /// and glass, so the two look like one control.
    private var earlyCloseButton: some View {
        HStack {
            Button(action: closePlayer) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle())
            .accessibilityLabel("Close Player")
            .accessibilityIdentifier("player.close")

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top)
        .transition(.opacity)
        .modifier(MobilePlayerChromeVisibility(isVisible: player.shouldShowMobilePlayerChrome))
    }
    #endif

    #if os(tvOS)
    // MARK: Apple TV remote

    /// Whether the press-capture view owns the Siri Remote. It needs the
    /// item to have loaded and the HUD to be closed, and then either the
    /// transport bar hidden with no intro or credits skip button showing, or
    /// a hold-to-seek session in progress (whatever those show).
    ///
    /// Outside seek mode, tapping left or right skips, down opens the player
    /// menu, up shows the transport bar, Select pauses into the timeline, and
    /// holding left or right starts seeking. In seek mode, left and right
    /// step the rate along its ladder, Select commits and Menu cancels; up,
    /// down and holds do nothing.
    ///
    /// Never while the HUD is up: the capture view and the HUD's focus graph
    /// would both own the same presses (docs/apple-tv-focus.md), and the
    /// capture view's Down would switch the HUD tab under the viewer.
    private var remoteCaptureIsActive: Bool {
        let seeking = player.isHoldSeeking
        let skipButtonShowing = player.showIntroSkip || player.showCreditsSkip
        return !player.isLoading
            && !player.isHUDPresented
            && (!skipButtonShowing || seeking)
            && (!player.showControls || seeking)
    }

    /// `isLoading` is also true during a Protocol V3 replan, including track
    /// or quality changes made from the HUD itself. Unmounting then would
    /// throw away the HUD's @State and @FocusState mid-press and put focus
    /// back on a reset tab, so the HUD stays mounted through a replan. A
    /// replacement load closes the HUD in `resetPublishedLoadState`, so cold
    /// starts and item changes still unmount it.
    private var mountsTransportControls: Bool {
        (!player.isLoading || player.isHUDPresented) && !player.isHoldSeeking
    }

    private func handleArrowTap(_ direction: TVPressCaptureView.ArrowDirection) {
        if player.isHoldSeeking {
            switch direction {
            case .left: player.adjustHoldSeekRate(delta: -1)
            case .right: player.adjustHoldSeekRate(delta: +1)
            case .up, .down: break
            }
            return
        }
        switch direction {
        case .left: player.skipBackward()
        case .right: player.skipForward()
        case .down: player.openSettingsHUD()
        case .up: player.revealControls()
        }
    }

    /// Only left and right start seeking. Holding up or down is ignored, so
    /// a hold can't begin by accident in the middle of skipping.
    private func handleArrowHold(_ direction: TVPressCaptureView.ArrowDirection) {
        switch direction {
        case .left: player.beginHoldSeek(forward: false)
        case .right: player.beginHoldSeek(forward: true)
        case .up, .down: break
        }
    }

    private func handleSelectPress() {
        if player.isHoldSeeking {
            player.commitHoldSeek()
        } else if player.isPlaying {
            touchMayToggleReadout = false
            hidePeek(immediately: true)
            player.pauseForTimelineSelection()
            timelineFocusRequest = UUID()
        } else {
            player.revealControls()
        }
    }

    private func handlePlayPausePress() {
        if player.showNextUpScreen {
            player.playNextEpisodeNow()
        } else {
            player.togglePlayPause()
        }
    }

    /// Menu steps back one layer per press: Next Up, then a seek session,
    /// then the HUD, then the transport bar, then out of the player, the way
    /// Infuse and the Apple TV app behave.
    private func handleMenuPress() {
        if player.isNextUpTransitioning {
            closePlayer()
            return
        }
        if player.showNextUpScreen {
            leaveNextUp()
            return
        }
        if player.isHoldSeeking {
            player.cancelHoldSeek()
            return
        }
        if player.isHUDPresented {
            // Checked before `isLoading`: a replan started from the HUD keeps
            // it mounted while loading, and Menu then has to close the HUD
            // rather than leave the player. A load that really is stuck can
            // still be left: the first Menu closes the HUD, the next exits.
            player.closeHUD()
            return
        }
        // Loading, or paused (Menu leaves instead of hiding the controls over
        // a still frame), or nothing on screen to hide: leave the player.
        if !player.isLoading, player.isPlaying, player.showControls {
            player.dismissControls()
        } else {
            closePlayer()
        }
    }

    private func controlsVisibilityChanged(_ shown: Bool) {
        if shown {
            hidePeek()
        } else {
            timeReadout = .elapsedRemaining
        }
    }

    // MARK: Apple TV timeline preview

    private func toggleTimeDisplayModeAnimated() {
        withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
            timeReadout.toggle()
        }
    }

    private func peekTouchBegan() {
        let mayPreview = player.isPlaying
            && !player.showControls
            && !player.isHUDPresented
            && !player.isHoldSeeking
        guard mayPreview else { return }

        peekHideTask?.cancel()
        peekHideTask = nil
        // A touch that lands while the preview is already up may switch the
        // time display when it lifts.
        touchMayToggleReadout = showsTimelinePeek
        withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
            if !showsTimelinePeek {
                showsTimelinePeek = true
            }
        }
    }

    private func peekTouchEnded() {
        guard showsTimelinePeek else { return }
        if touchMayToggleReadout {
            toggleTimeDisplayModeAnimated()
        }
        touchMayToggleReadout = false
        schedulePeekHide()
    }

    private func peekTouchCancelled() {
        touchMayToggleReadout = false
        schedulePeekHide()
    }

    private func schedulePeekHide() {
        guard showsTimelinePeek else { return }
        peekHideTask?.cancel()
        peekHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled {
                hidePeek()
            }
        }
    }

    private func hidePeek(immediately: Bool = false) {
        peekHideTask?.cancel()
        peekHideTask = nil
        touchMayToggleReadout = false
        guard showsTimelinePeek else { return }
        guard !immediately else {
            // Handing over to the HUD with Select keeps the display mode.
            showsTimelinePeek = false
            return
        }
        withAnimation(.easeOut(duration: VividTheme.fastDuration)) {
            showsTimelinePeek = false
        }
        // The next light touch after a dismissed preview starts again in
        // duration mode.
        timeReadout = .elapsedRemaining
    }
    #endif
}

// MARK: - Playback failure

private struct PlaybackFailurePanel: View {
    let error: String
    let onRetry: () -> Void
    let onBack: () -> Void

    #if os(tvOS)
    @Namespace private var focusNamespace
    #endif

    private enum Metrics {
        #if os(tvOS)
        static let width: CGFloat = 680
        static let inset: CGFloat = 40
        #else
        static let width: CGFloat = 460
        static let inset: CGFloat = 24
        #endif
        static let corner: CGFloat = 30
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 20) {
                heading
                ViewThatFits(in: .vertical) {
                    message.fixedSize(horizontal: false, vertical: true)
                    ScrollView { message }
                }
                .frame(maxHeight: Self.messageHeightLimit(forPanelHeight: geometry.size.height))
                actions
            }
            .padding(Metrics.inset)
            .frame(maxWidth: Metrics.width)
            .background { glass }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        #if os(tvOS)
        .focusScope(focusNamespace)
        #endif
    }

    /// Between 56 and 160 points: 22% of the space available.
    private static func messageHeightLimit(forPanelHeight height: CGFloat) -> CGFloat {
        max(56, min(160, height * 0.22))
    }

    private var heading: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityHidden(true)

            Text("Unable to Play")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            actionButton("Retry", icon: "arrow.clockwise", primary: true, identifier: "playbackFailure.retry", perform: onRetry)
                #if os(tvOS)
                .prefersDefaultFocus(true, in: focusNamespace)
                #endif
            actionButton("Back", icon: "chevron.left", primary: false, identifier: "playbackFailure.back", perform: onBack)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        icon: String,
        primary: Bool,
        identifier: String,
        perform action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlaybackFailureButtonStyle(isPrimary: primary))
        .accessibilityIdentifier(identifier)
    }

    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
        let edge = LinearGradient(
            colors: [.white.opacity(0.24), .white.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        return shape
            .fill(.ultraThinMaterial)
            .overlay { shape.fill(Color.black.opacity(0.35)) }
            .overlay { shape.strokeBorder(edge, lineWidth: 1) }
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }

    private var message: some View {
        Text(PlaybackFailureText.localized(error))
            .font(.callout)
            .foregroundStyle(.white.opacity(0.68))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

private struct PlaybackFailureButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        // Apple TV fills whichever button has focus; touch fills the
        // primary one.
        #if os(tvOS)
        let filled = isFocused
        #else
        let filled = isPrimary
        #endif
        let pressScale: CGFloat = configuration.isPressed ? 0.97 : (isFocused ? 1.05 : 1)
        return configuration.label
            .font(.headline)
            .foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background {
                Capsule().fill(Color.white.opacity(filled ? 0.9 : 0.10))
            }
            .overlay {
                Capsule().strokeBorder(.white.opacity(filled ? 0 : 0.15), lineWidth: 1)
            }
            .contentShape(Capsule())
            .scaleEffect(pressScale)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Next Up

/// The Next Up screen at the end of an episode. The persistent player
/// surface shrinks into the preview slot this screen marks out.
struct PlayerNextUpScreen: View {
    let viewModel: PlayerViewModel
    private var player: PlayerViewModel { viewModel }
    let onBack: () -> Void

    #if os(tvOS)
    private enum Focus: Hashable {
        case playNow
        case keepWatching
        case back
        case autoPlay
    }

    @FocusState private var focus: Focus?
    @State private var initialFocusRequested = false
    @Namespace private var defaultFocusNamespace
    private static let captionSize: CGFloat = 19
    #else
    private static let captionSize: CGFloat = 13
    #endif

    private var nextEpisode: PlayerNextUpEpisode? { player.nextUpEpisode }
    private var hasNextEpisode: Bool { nextEpisode != nil }
    private var isFindingEpisode: Bool { player.isLoadingNextUpEpisode }
    private var videoEnded: Bool { player.nextUpScreenVideoEnded }

    var body: some View {
        let change = Animation.easeInOut(duration: 0.2)
        return GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                    #if os(iOS)
                    // A tap on the background shows or hides the rotation
                    // buttons without catching Play Now, Back or Auto Play.
                    .onTapGesture { player.toggleControls(cause: .nextUpTap) }
                    #endif
                #if os(tvOS)
                tvLayout(in: proxy.size)
                #else
                PlayerNextUpMobileLayout {
                    previewSlot
                } panel: { compact in
                    mobileNextUpPanel(compact: compact)
                        .anchorPreference(key: PlayerPreviewBoundsKey.self, value: .bounds) { .init(actions: $0) }
                } extras: {
                }
                .padding(.top, MobilePlayerRotationControls.topClearance)
                #endif
            }
            // The artwork is decoration and mustn't grow this ZStack's ideal
            // size, so the whole screen is pinned to the real viewport.
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background { backdrop }
            .clipped()
        }
        #if os(tvOS)
        .ignoresSafeArea()
        #endif
        .animation(change, value: player.nextUpCountdownSeconds)
        .animation(change, value: player.nextUpEpisode)
        .animation(change, value: player.nextUpCarouselItems)
        #if os(tvOS)
        .onAppear(perform: focusFirstActionOnce)
        .onChange(of: player.nextUpEpisode?.contentId) { _, _ in
            focusFirstActionOnce()
        }
        #endif
    }

    /// The transparent slot the shrunken player surface is drawn into.
    private var previewSlot: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .anchorPreference(key: PlayerPreviewBoundsKey.self, value: .bounds) { .init(bounds: $0) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let artwork = backdropArtwork {
            AsyncImageView(url: artwork.url, thumbhash: artwork.thumbhash)
                .scaledToFill()
                .blur(radius: 44)
                .scaleEffect(1.12)
                .opacity(0.18)
                .overlay(Color.black.opacity(0.78))
                .ignoresSafeArea()
        }
    }

    /// The next episode's still, or else the first On Deck item's artwork.
    private var backdropArtwork: (url: String, thumbhash: String?)? {
        if let still = nextEpisode?.stillUrl {
            return (still, nextEpisode?.stillThumbhash)
        }
        guard let first = player.nextUpCarouselItems.first, let artwork = first.artworkUrl else { return nil }
        return (artwork, first.artworkThumbhash)
    }

    private var autoPlayToggle: some View {
        Button {
            player.setNextUpAutoPlayEnabled(!player.settings.autoPlayNextEpisode)
        } label: {
            Text(player.settings.autoPlayNextEpisode ? "Auto-play is On" : "Auto-play is Off")
                .font(.system(size: Self.captionSize, weight: .semibold))
        }
        .buttonStyle(AutoPlayToggleButtonStyle())
        #if os(tvOS)
        .focused($focus, equals: .autoPlay)
        .onMoveCommand { direction in
            // Nothing sits below the toggle on Apple TV.
            if direction == .up {
                focus = preferredFocus
            }
        }
        #endif
    }

    private var finishedMessage: String {
        if player.nextUpStartError != nil {
            return String(localized: "Couldn't start the next episode. Try again or go back.")
        }
        if player.nextUpLookupError != nil {
            return String(localized: "Couldn't load the next episode. Go back to choose something else.")
        }
        return String(localized: "No next episode is available.")
    }

    #if os(iOS)
    // MARK: iPhone and iPad

    func mobileNextUpPanel(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // On short landscape screens every action has to stay clear of
            // the space kept for the rotation buttons, so there's no eyebrow.
            if let episode = nextEpisode {
                VStack(alignment: .leading, spacing: 6) {
                    if let series = episode.seriesTitle { Text(series).font(.system(size: 22, weight: .bold)) }
                    Text("\(episode.episodeLabel) · \(episode.title)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }.foregroundStyle(.white)
            } else if isFindingEpisode {
                Text("Finding the next episode")
                    .font(.callout)
                    .foregroundStyle(.white)
            } else {
                Text(player.nextUpScreenVideoEnded ? "End of playback" : "Almost finished")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            mobileActions
            if hasNextEpisode {
                autoPlayToggle
            } else if !isFindingEpisode {
                Text(finishedMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var mobileActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if hasNextEpisode {
                    Button { player.playNextEpisodeNow() } label: {
                        Label("Play Now", systemImage: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 160, height: 44)
                            .background(.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isNextUpTransitioning)
                    .accessibilityIdentifier("next-up-play-now")
                }
                countdown
            }
            HStack(spacing: 10) {
                if !videoEnded {
                    Button { player.keepWatchingCurrentEpisode() } label: {
                        Text("Keep Watching").frame(width: 160)
                    }
                    .buttonStyle(MobilePlayerGlassButtonStyle())
                    .disabled(player.isNextUpTransitioning)
                }
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").frame(width: 84)
                }.buttonStyle(MobilePlayerGlassButtonStyle())
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
        }
    }
    #endif

    @ViewBuilder
    private var countdown: some View {
        if let seconds = player.nextUpCountdownSeconds {
            CountdownRing(seconds: seconds, totalSeconds: player.nextUpCountdownTotalSeconds)
        }
    }

    #if os(tvOS)
    // MARK: Apple TV

    private func tvLayout(in size: CGSize) -> some View {
        tvContent
            .frame(width: max(0, size.width - 200), height: max(0, size.height - 180))
            .padding(.horizontal, 100)
            .padding(.top, 100)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusScope(defaultFocusNamespace)
            .transformAnchorPreference(key: PlayerPreviewBoundsKey.self, value: .bounds) {
                $0.viewport = $1
            }
    }

    private var tvContent: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(eyebrowText)
                            .font(.system(size: 18, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.52))
                        if let episode = nextEpisode {
                            episodeDetails(episode)
                        } else if !isFindingEpisode {
                            Text("End of playback")
                                .font(.system(size: 40, weight: .bold))
                            Text(finishedMessage)
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(maxWidth: 750, alignment: .leading)
                    Spacer(minLength: 0)
                    previewSlot.frame(width: 960, height: 540)
                }
                Spacer(minLength: 40)
                tvActions
                if hasNextEpisode { autoPlayToggle }
            }
            if isFindingEpisode {
                PlayerBufferingCapsule(label: "Finding the next episode")
            }
        }
    }

    private var eyebrowText: String {
        switch (hasNextEpisode || isFindingEpisode, videoEnded) {
        case (false, true):
            String(localized: "Finished", comment: "Next Up screen eyebrow: the title ended and nothing plays next")
        case (false, false):
            String(localized: "More To Watch", comment: "Next Up screen eyebrow")
        case (true, true):
            String(localized: "Playing Next", comment: "Next Up screen eyebrow")
        case (true, false):
            String(localized: "Up Next", comment: "Next Up screen eyebrow")
        }
    }

    private func episodeDetails(_ episode: PlayerNextUpEpisode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let seriesTitle = episode.seriesTitle, !seriesTitle.isEmpty {
                Text(seriesTitle)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text(episode.episodeLabel)
                    .foregroundStyle(.white.opacity(0.62))
                Text(episode.title)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 25, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(.leading)

            if let facts = Self.factsLine(for: episode) {
                Text(facts)
                    .font(.system(size: Self.captionSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }

            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 22))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    /// Air date and runtime joined by a dot, or nil when neither is known.
    private static func factsLine(for episode: PlayerNextUpEpisode) -> String? {
        var facts: [String] = []
        if let airDate = episode.airDate, !airDate.isEmpty {
            facts.append((try? Date(airDate, strategy: .iso8601))?.formatted(date: .abbreviated, time: .omitted) ?? airDate)
        }
        if let minutes = episode.runtime, minutes > 0 {
            facts.append(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    private var tvActions: some View {
        HStack(alignment: .center, spacing: 24) {
            // Leaves room for the primary pill's focus growth and outline so
            // the countdown never runs into it.
            HStack(spacing: 24) {
                if hasNextEpisode {
                    Button(action: { player.playNextEpisodeNow() }) {
                        tvPillLabel("Play Now", icon: "play.fill", iconSize: 32, iconWeight: .bold, titleSize: 30, spacing: 18, width: 220)
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .primary, stabilizesFocusMotion: true, fixedWidth: 280))
                    .disabled(player.isNextUpTransitioning)
                    .focused($focus, equals: .playNow)
                    .prefersDefaultFocus(true, in: defaultFocusNamespace)
                }
                countdown
            }

            HStack(spacing: 20) {
                if !videoEnded {
                    Button(action: { player.keepWatchingCurrentEpisode() }) {
                        tvPillLabel("Keep Watching", icon: "rectangle.inset.filled", iconSize: 25, titleSize: 26, width: 250)
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .secondary, stabilizesFocusMotion: true))
                    .disabled(player.isNextUpTransitioning)
                    .focused($focus, equals: .keepWatching)
                    .prefersDefaultFocus(!hasNextEpisode, in: defaultFocusNamespace)
                }

                Button(action: onBack) {
                    tvPillLabel("Back", icon: "chevron.left", iconSize: 26, titleSize: 26, width: 120)
                }
                .buttonStyle(TVPillButtonStyle(kind: .secondary, stabilizesFocusMotion: true))
                .focused($focus, equals: .back)
                .prefersDefaultFocus(!hasNextEpisode && videoEnded, in: defaultFocusNamespace)
            }
            .onMoveCommand { direction in
                // Down from the actions goes to the auto-play toggle, which
                // only exists with a next episode.
                if direction == .down, hasNextEpisode {
                    focus = .autoPlay
                }
            }
        }
    }

    private func tvPillLabel(
        _ title: LocalizedStringKey,
        icon: String,
        iconSize: CGFloat,
        iconWeight: Font.Weight = .semibold,
        titleSize: CGFloat,
        spacing: CGFloat = 16,
        width: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: iconWeight))
            Text(title)
                .font(.system(size: titleSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: width)
    }

    /// Play Now when there's a next episode, else Keep Watching while the
    /// video is still going, else Back.
    private var preferredFocus: Focus {
        if hasNextEpisode { return .playNow }
        return videoEnded ? .back : .keepWatching
    }

    /// Moves focus to the preferred action the first time there's something
    /// to show: a next episode, or the end of the search for one.
    private func focusFirstActionOnce() {
        guard !initialFocusRequested, hasNextEpisode || !isFindingEpisode else { return }
        initialFocusRequested = true
        Task { @MainActor in
            await Task.yield()
            focus = preferredFocus
        }
    }
    #endif
}

private struct AutoPlayToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AutoPlayToggleLabel(configuration: configuration)
    }
}

/// A view of its own so it can read the button's focus from the
/// environment.
private struct AutoPlayToggleLabel: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let scale: CGFloat = configuration.isPressed ? 0.98 : (isFocused ? 1.04 : 1.0)
        configuration.label
            .foregroundStyle(.white.opacity(isFocused ? 0.92 : 0.54))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .overlay(Capsule().stroke(.white.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5))
            .scaleEffect(scale)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(VividTheme.springAnimation, value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}

/// The Next Up countdown: a ring that empties as the seconds run down.
private struct CountdownRing: View {
    let seconds: Int
    let totalSeconds: Int

    #if os(tvOS)
    private let diameter: CGFloat = 58
    private let digitSize: CGFloat = 24
    #else
    private let diameter: CGFloat = 44
    private let digitSize: CGFloat = 17
    #endif

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)")
                .font(.system(size: digitSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Playing next in \(seconds) seconds")
    }

    /// The share of the countdown left, from 0 to 1.
    private var remaining: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(seconds) / Double(totalSeconds)))
    }
}
