#if os(tvOS)
import SwiftUI
import UIKit

/// The two clock label layouts under the Apple TV timeline. A light touch on
/// the Siri Remote clickpad flips between them.
enum TVPlayerTimeDisplayMode: Equatable {
    case elapsedRemaining
    case currentAndFinish

    mutating func toggle() {
        switch self {
        case .elapsedRemaining: self = .currentAndFinish
        case .currentAndFinish: self = .elapsedRemaining
        }
    }
}

/// Everything the Apple TV player draws over the picture.
///
/// At rest it's a slim transport along the bottom: the title, the Subtitles
/// and Options circles, the timeline and its clock labels. Options swaps that
/// for `TVPlayerInfoHUD`, a floating panel at the top. Intro and credits skip
/// prompts float above the transport, or on their own when it's hidden. While
/// playing, the transport hides 5 seconds after focus last moved. Menu is
/// handled by `PlayerView`, which can see the whole player.
struct TVPlayerControls: View {
    let viewModel: PlayerViewModel
    let showsTimelinePreview: Bool
    let timeDisplayMode: TVPlayerTimeDisplayMode
    let timelineSelectionRequest: UUID?
    let onToggleTimeDisplayMode: () -> Void
    let onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    /// The tab the options HUD shows. It lives here because the HUD itself
    /// is rebuilt each time it opens, and it should reopen where it was.
    @State private var hudTab: TVPlayerInfoHUD.Tab = .info
    @State private var hudIsSubtitlesOnly = false
    /// The options tab to go back to after the subtitle-only HUD.
    @State private var lastOptionsTab: TVPlayerInfoHUD.Tab = .info
    /// The circle that gets focus back when the transport reappears.
    @State private var shortcutToRestore: TVPlayerTransportCluster.FocusTarget?

    /// Raised just before the HUD opens, so the timeline treats the blur that
    /// follows as a cancel. Otherwise opening the HUD mid-scrub would seek.
    @State private var scrubCancelsOnBlur = false
    /// Mirrors the timeline's time selection, which is modal, so the circles
    /// can leave the focus graph while it runs.
    @State private var isSelectingTime = false
    /// Whether committing the selection should resume playback. A selection
    /// started while paused stays paused; one started by Select while playing
    /// resumes.
    @State private var selectionResumesPlayback = false
    /// Raised while the timeline has focus. The circles leave the focus graph
    /// meanwhile, so a press towards them has no native target: otherwise the
    /// focus engine would jump to whichever circle sits nearest the playhead
    /// before the timeline's `onMoveCommand` runs, which looks like a hop off
    /// the wrong button. It drops for the hand-off to the circles, so the
    /// seed has a target, and whenever the timeline loses focus some other way
    /// (a skip prompt, the HUD).
    @State private var timelineHoldsFocus = false
    /// A clickpad touch flips the clock labels only if it ends as a light
    /// touch. Select, clicks and swipes clear this, so they keep their own
    /// transport behaviour.
    @State private var touchMayToggleClock = false
    @State private var measuredTransportHeight: CGFloat = 240

    // One focus binding per zone; focusing one clears the rest. The HUD pill
    // binding lives here rather than in `TVPlayerInfoHUD` so opening the HUD
    // can seed a pill. With nothing focused, Menu has no handler to bubble to
    // and the viewer is stuck in the panel.
    @FocusState private var timelineFocused: Bool
    @FocusState private var focusedShortcut: TVPlayerTransportCluster.FocusTarget?
    @FocusState private var focusedHUDPill: TVPlayerInfoHUD.Tab?
    @FocusState private var focusedIntroButton: IntroButton?
    @FocusState private var creditsSkipFocused: Bool

    private enum IntroButton: Hashable {
        case cancel, skip
    }

    private enum Layout {
        static let sideInset: CGFloat = 80
        static let bottomInset: CGFloat = 48
        static let gradientHeight: CGFloat = 240
        /// The skip prompts' bottom inset with no transport, and their lowest.
        static let promptFloor: CGFloat = 180
        /// Space between a skip prompt and the transport under it.
        static let promptGap: CGFloat = 32
        static let wideSkipWidth: CGFloat = 220
        static let cancelWidth: CGFloat = 136
        static let observerSide: CGFloat = 1
        static let previewRowHeight: CGFloat = 20
        static let previewLineHeight: CGFloat = 7
        static let trackOpacity = 0.24
        static let loadedOpacity = 0.28
    }

    private var hudShown: Bool { viewModel.isHUDPresented }

    private var skipPromptBottomInset: CGFloat {
        guard viewModel.showControls else { return Layout.promptFloor }
        return max(Layout.promptFloor, measuredTransportHeight + Layout.bottomInset + Layout.promptGap)
    }

    var body: some View {
        ZStack {
            if showsTimelinePreview && !viewModel.showControls && !hudShown {
                lightTouchPreview
                    .transition(.opacity)
            }
            // The transport and the HUD never share the screen. Stacked, the
            // timeline's clicks reached hidden circles and the progress line
            // showed under the panel.
            if viewModel.showControls && !hudShown {
                transportOverlay
                    .transition(.opacity)
            }
            if viewModel.showIntroSkip && !hudShown {
                introPrompt
                    .transition(.opacity)
            }
            if viewModel.showCreditsSkip && !hudShown {
                creditsPrompt
                    .transition(.opacity)
            }
            if hudShown {
                TVPlayerInfoHUD(
                    viewModel: viewModel,
                    activeTab: $hudTab,
                    focusedTab: $focusedHUDPill,
                    subtitleOnly: hudIsSubtitlesOnly,
                    onDismiss: { closeHUD() }
                )
                .transition(.opacity)
            }
        }
        .background {
            // On for the resting transport and for time selection. It
            // recognises alongside the swipe observer, so a real drag still
            // scrubs.
            TVLightTouchObserver(
                isActive: viewModel.showControls && !hudShown,
                onContactBegan: { touchMayToggleClock = true },
                onContactEnded: {
                    guard touchMayToggleClock else { return }
                    touchMayToggleClock = false
                    onToggleTimeDisplayMode()
                },
                onContactCancelled: { touchMayToggleClock = false },
                onArrowClick: { touchMayToggleClock = false }
            )
            .frame(width: Layout.observerSide, height: Layout.observerSide)
        }
        .animation(.easeOut(duration: VividTheme.fastDuration), value: hudShown)
        // No Menu handler here. `PlayerView` reads `isHUDPresented` itself so
        // it still catches Menu when focus drifts off the HUD, and a handler
        // here would swallow Menu while the HUD is closed.
        .onChange(of: hudShown) { _, shown in
            touchMayToggleClock = false
            if !shown { hudDidClose() }
        }
        .onChange(of: viewModel.requestedTVHUDEntryPoint) { _, requested in
            if let requested {
                openHUD(at: requested)
                viewModel.consumeTVHUDEntryRequest()
            }
        }
        .onChange(of: timelineSelectionRequest) { _, token in
            if token == nil { return }
            touchMayToggleClock = false
            // PlayerView only sends this from its Select-while-playing path,
            // straight after pausing.
            selectionResumesPlayback = true
            startTimeSelection()
        }
        .onChange(of: viewModel.showControls) { _, shown in
            touchMayToggleClock = false
            guard !shown else { return }
            shortcutToRestore = nil
            DispatchQueue.main.async { focusLoneSkipPrompt() }
        }
        // Each focus move restarts the auto-hide, so the 5 second timer can't
        // pull the transport, and focus with it, out from under the viewer.
        .onChange(of: timelineFocused) { _, focused in
            if focused { keepTransportUp() }
            timelineHoldsFocus = focused
        }
        .onChange(of: focusedShortcut) { _, shortcut in
            if shortcut != nil { keepTransportUp() }
        }
        // TV sleep drops the app's focus while `showControls` stays true. On
        // wake the transport is still mounted, so its `onAppear` seed doesn't
        // run, nothing has focus and Menu never reaches PlayerView's
        // `onExitCommand`. Seed focus again once the scene is active.
        .onChange(of: scenePhase) { _, phaseNow in
            // A turn later, once the focus engine has the scene back; a claim
            // in the same transaction can be lost.
            if phaseNow == .active {
                DispatchQueue.main.async { refocusAfterWake() }
            }
        }
    }

    // MARK: - Focus

    private func hudDidClose() {
        scrubCancelsOnBlur = false
        focusedHUDPill = nil
        let shortcut: TVPlayerTransportCluster.FocusTarget = hudIsSubtitlesOnly ? .subtitles : .options
        shortcutToRestore = shortcut
        timelineHoldsFocus = false
        timelineFocused = false
        DispatchQueue.main.async {
            if !hudShown && viewModel.showControls {
                focusedShortcut = shortcut
            }
        }
    }

    private func refocusAfterWake() {
        if hudShown {
            if focusedHUDPill == nil { focusedHUDPill = hudTab }
            return
        }
        guard viewModel.showControls else {
            focusLoneSkipPrompt()
            return
        }
        let nothingFocused = focusedShortcut == nil && !timelineFocused &&
            focusedIntroButton == nil && !creditsSkipFocused
        if nothingFocused { timelineFocused = true }
    }

    /// Waits a turn so a newly mounted prompt is in the focus graph, then
    /// focuses it.
    @MainActor
    private func focusPromptOnceMounted() async {
        await Task.yield()
        if !Task.isCancelled {
            focusLoneSkipPrompt()
        }
    }

    /// Focuses the skip prompt when it stands alone, so Select skips straight
    /// away.
    private func focusLoneSkipPrompt() {
        guard !hudShown && !viewModel.showControls else { return }
        switch (viewModel.showIntroSkip, viewModel.showCreditsSkip) {
        case (true, _): focusedIntroButton = .skip
        case (false, true): creditsSkipFocused = true
        case (false, false): break
        }
    }

    private func keepTransportUp() {
        guard viewModel.showControls && !hudShown else { return }
        viewModel.revealControls()
    }

    // MARK: - Light-touch preview

    /// The passive timeline and clock labels a light touch shows while the
    /// transport is hidden.
    private var lightTouchPreview: some View {
        ZStack(alignment: .bottom) {
            shade.ignoresSafeArea()
            VStack(spacing: 10) {
                PlayerTickIsolated { previewLine }
                PlayerTickIsolated { clockRow }
            }
            .padding(.horizontal, Layout.sideInset)
            .padding(.bottom, Layout.bottomInset)
        }
        .allowsHitTesting(false)
    }

    private var previewLine: some View {
        GeometryReader { proxy in
            let span = proxy.size.width
            let played = playedShare
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(Layout.trackOpacity))
                    .frame(height: Layout.previewLineHeight)

                let loadedAhead = max(0, loadedShare - played)
                if loadedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(Layout.loadedOpacity))
                        .frame(width: span * loadedAhead, height: Layout.previewLineHeight)
                        .offset(x: span * played)
                }

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: span * played, height: Layout.previewLineHeight)
            }
            .frame(height: Layout.previewRowHeight, alignment: .center)
        }
        .frame(height: Layout.previewRowHeight)
    }

    private var playedShare: Double {
        TVTimelineScrubMath.fraction(of: shownTime, duration: viewModel.duration)
    }

    private var loadedShare: Double {
        TVTimelineScrubMath.fraction(
            of: viewModel.currentTime + viewModel.timelineBufferedAheadSeconds,
            duration: viewModel.duration
        )
    }

    // MARK: - Transport

    private var transportOverlay: some View {
        ZStack(alignment: .bottom) {
            shade.ignoresSafeArea()
            sleepTimerChip
                .padding(.top, sleepTimerTopInset)
                .padding(.horizontal, Layout.sideInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            transportColumn
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    measuredTransportHeight = height
                }
                .padding(.horizontal, Layout.sideInset)
                .padding(.bottom, Layout.bottomInset)
        }
        .onAppear(perform: seedTransportFocus)
    }

    /// The sleep timer chip sits lower while playback is buffering.
    private var sleepTimerTopInset: CGFloat {
        viewModel.isBuffering ? 120 : 64
    }

    /// Opening the transport is an explicit move away from any skip prompt.
    /// Focus goes back to the circle the HUD was opened from, or else to the
    /// timeline.
    private func seedTransportFocus() {
        focusedShortcut = nil
        focusedIntroButton = nil
        creditsSkipFocused = false
        guard let shortcut = shortcutToRestore else {
            timelineFocused = true
            return
        }
        timelineHoldsFocus = false
        timelineFocused = false
        focusedShortcut = shortcut
    }

    /// A low gradient that keeps the transport readable over bright frames.
    private var shade: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: Layout.gradientHeight)
        }
    }

    /// The sleep timer, top right, while one runs. Buffering belongs to the
    /// player shell, so it shows outside this overlay too.
    private var sleepTimerChip: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if viewModel.sleepTimer.isActive {
                let remaining = PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds)
                Label(remaining, systemImage: "moon.zzz.fill")
                    .font(.vividSmall.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .vividPlayerGlass(in: Capsule())
            }
        }
    }

    private var transportColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 24) {
                nowPlayingCaption
                Spacer(minLength: 24)
                shortcuts
            }
            TVPlayerScrubber(
                viewModel: viewModel,
                isFocused: $timelineFocused,
                onSelectPressed: { touchMayToggleClock = false },
                onMoveUpToShortcuts: {
                    // This only runs because the circles were out of the focus
                    // graph. Put them back first, then seed Options a turn
                    // later: a claim in the same transaction as re-enabling
                    // them gets lost. Focus stays on the timeline for that
                    // frame, so there's no visible stop on the way.
                    timelineHoldsFocus = false
                    DispatchQueue.main.async { focusedShortcut = .options }
                },
                onMenuWhileIdle: {
                    // After going back to watch the credits, Menu brings
                    // Next Up back, even with the transport showing.
                    if viewModel.reopenNextUpForCredits() { return }
                    // Paused, Menu leaves the player rather than hiding the
                    // transport over a still frame.
                    if viewModel.isPlaying {
                        viewModel.dismissControls()
                    } else {
                        onDismiss()
                    }
                },
                isSelecting: $isSelectingTime,
                resumesAfterSelection: $selectionResumesPlayback,
                cancelsScrubOnBlur: scrubCancelsOnBlur
            )
            PlayerTickIsolated { clockRow }
        }
    }

    private var shortcuts: some View {
        TVPlayerTransportCluster(
            viewModel: viewModel,
            onOpenHUD: { openHUD() },
            onOpenSubtitles: { openHUD(subtitlesOnly: true) },
            // A single write, as with Up from the timeline: clearing the
            // circle's focus first invites the focus engine to repair it with
            // a hop of its own.
            onMoveToScrubber: { timelineFocused = true },
            // The circles leave the focus graph during a time selection, which
            // is modal, and while the timeline holds focus. With no native
            // target, Up from the timeline goes through onMoveUpToShortcuts
            // instead of the focus engine's nearest-button guess.
            allowsFocus: !isSelectingTime && !timelineHoldsFocus,
            focusedButton: $focusedShortcut
        )
    }

    /// The title as a quiet caption over the timeline, once one is known.
    @ViewBuilder
    private var nowPlayingCaption: some View {
        let title = viewModel.metadata.primaryTitle.isEmpty ? viewModel.title : viewModel.metadata.primaryTitle
        if !title.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let showName = viewModel.metadata.seriesTitle, !showName.isEmpty {
                    Text(showName)
                        .font(.vividSmall.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(title)
                        .font(.vividHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episodeLabel = viewModel.metadata.episodeTag {
                        Text(episodeLabel)
                            .font(.vividSmall)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        }
    }

    // MARK: - Clock labels

    @ViewBuilder
    private var clockRow: some View {
        switch timeDisplayMode {
        case .currentAndFinish:
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                HStack {
                    pausedGlyph
                    clockLabel(clockTime(tick.date))
                    Spacer()
                    if hasKnownLength {
                        let finish = clockTime(finishDate(from: tick.date))
                        let remaining = PlayerTimeFormatter.formatHMS(timeLeft)
                        clockLabel(String(localized: "\(finish) · \(remaining) left", comment: "Finish time and time remaining, for example 9:41 PM · 1:02:03 left"))
                    }
                }
            }
        case .elapsedRemaining:
            HStack {
                pausedGlyph
                clockLabel(PlayerTimeFormatter.formatHMS(shownTime))
                Spacer()
                if hasKnownLength {
                    let remaining = PlayerTimeFormatter.formatHMS(timeLeft)
                    clockLabel(String(localized: "\(remaining) left", comment: "Time remaining in the title, for example 1:02:03 left"))
                }
            }
        }
    }

    /// A pause symbol that only shows while paused, keeping its space either
    /// way so the labels don't shift.
    private var pausedGlyph: some View {
        let playing = viewModel.isPlaying
        return Image(systemName: "pause.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .opacity(playing ? 0 : 1)
            .accessibilityHidden(playing)
            .accessibilityLabel("Paused")
    }

    private func clockLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
    }

    /// The scrub preview during a scrub, otherwise the playhead.
    private var shownTime: Double {
        if viewModel.isScrubbing { return viewModel.scrubPreviewTime }
        return viewModel.currentTime
    }

    private var hasKnownLength: Bool { viewModel.duration > 0 }

    private var timeLeft: Double {
        max(0, viewModel.duration - shownTime)
    }

    /// When the title will end at the current speed, counting from `now`.
    private func finishDate(from now: Date) -> Date {
        let playbackRate = max(viewModel.settings.playbackSpeed, 0.1)
        return now.addingTimeInterval(timeLeft / playbackRate)
    }

    private func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Skip prompts

    /// A move off a lone skip prompt brings up the timeline. Once the
    /// transport is up, its native focus graph handles movement.
    private func moveOffPrompt(_ direction: MoveCommandDirection) {
        guard !viewModel.showControls && !hudShown else { return }
        // During a countdown, Left and Right stay between Cancel and Skip.
        let sideways = direction == .left || direction == .right
        if sideways && viewModel.showIntroSkip && isCountingDown {
            return
        }
        viewModel.revealControls()
    }

    /// Whether the intro is counting down to skip itself.
    private var isCountingDown: Bool {
        viewModel.introAutoSkipCountdownSeconds != nil
    }

    /// Places a prompt bottom right, above the transport when it shows. The
    /// focus section wraps only the buttons, not the full-screen frame.
    private func placePrompt(_ prompt: some View) -> some View {
        prompt
            .focusSection()
            .onMoveCommand(perform: moveOffPrompt)
            .task { await focusPromptOnceMounted() }
            .padding(.horizontal, Layout.sideInset)
            .padding(.bottom, skipPromptBottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var introPrompt: some View {
        placePrompt(
            VStack(alignment: .trailing, spacing: 16) {
                if let secondsLeft = viewModel.introAutoSkipCountdownSeconds {
                    countdownBadge(secondsLeft)
                }
                HStack(spacing: 18) {
                    if isCountingDown {
                        cancelAutoSkipButton
                    }
                    skipIntroButton
                }
            }
        )
    }

    private var creditsPrompt: some View {
        placePrompt(
            SkipPromptButton(voiceOverTitle: String(localized: "Skip Credits")) {
                viewModel.skipCredits()
            } label: {
                Label("Skip Credits", systemImage: "forward.end.fill")
                    .skipPromptText(size: 26, width: Layout.wideSkipWidth)
            }
            .focused($creditsSkipFocused)
            .accessibilityLabel("Skip Credits")
        )
    }

    private var cancelAutoSkipButton: some View {
        SkipPromptButton(voiceOverTitle: viewModel.introSkipCancelLabel) {
            viewModel.cancelIntroAutoSkip()
        } label: {
            Label("Cancel", systemImage: "xmark")
                .skipPromptText(size: 24, width: Layout.cancelWidth)
        }
        .focused($focusedIntroButton, equals: .cancel)
        .accessibilityLabel(viewModel.introSkipCancelLabel)
    }

    private var skipIntroButton: some View {
        let countingDown = isCountingDown
        let title = countingDown ? String(localized: "Skip Now") : viewModel.introSkipLabel
        return SkipPromptButton(voiceOverTitle: viewModel.introSkipLabel) {
            viewModel.skipIntro()
        } label: {
            Label(title, systemImage: "forward.end.fill")
                .skipPromptText(size: 26, width: Layout.wideSkipWidth)
        }
        .focused($focusedIntroButton, equals: .skip)
        .accessibilityLabel(countingDown ? viewModel.introSkipNowLabel : viewModel.introSkipLabel)
    }

    private func countdownBadge(_ seconds: Int) -> some View {
        let plate = RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 19, weight: .semibold))
            Text("Intro")
                .font(.system(size: 17, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.62))
            Text("Skipping in \(seconds)")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(plate.fill(.black.opacity(0.46)))
        .overlay(plate.stroke(.white.opacity(0.24), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    // MARK: - Time selection and HUD

    /// Starts a time selection for PlayerView's Select-while-playing path. A
    /// title with no known length only focuses the timeline.
    private func startTimeSelection() {
        scrubCancelsOnBlur = false
        focusedHUDPill = nil
        focusedShortcut = nil
        focusedIntroButton = nil
        viewModel.pinControlsVisible()

        if hasKnownLength {
            viewModel.beginScrub(fraction: TVTimelineScrubMath.fraction(of: viewModel.currentTime, duration: viewModel.duration))
            isSelectingTime = true
        } else {
            isSelectingTime = false
            selectionResumesPlayback = false
        }
        timelineFocused = true
    }

    /// Opens the HUD. The order matters for focus: first the timeline is told
    /// to cancel on the coming blur, then the transport's focus bindings
    /// clear so SwiftUI isn't holding focus on a view about to leave, then a
    /// pill is seeded so Menu has a handler to bubble to, and only then does
    /// the view model present the HUD.
    private func openHUD(subtitlesOnly: Bool = false) {
        if !hudIsSubtitlesOnly { lastOptionsTab = hudTab }
        hudIsSubtitlesOnly = subtitlesOnly
        hudTab = subtitlesOnly ? .subtitles : lastOptionsTab
        scrubCancelsOnBlur = true
        timelineFocused = false
        focusedShortcut = nil
        focusedHUDPill = hudTab
        viewModel.openHUD()
    }

    /// Readies the HUD on the tab a request names. The view model presents it.
    private func openHUD(at entryPoint: PlayerViewModel.TVHUDEntryPoint) {
        hudIsSubtitlesOnly = false
        scrubCancelsOnBlur = true
        timelineFocused = false
        focusedShortcut = nil
        switch entryPoint {
        case .settings:
            hudTab = .video
        case .playback:
            hudTab = viewModel.audioTracks.isEmpty ? .video : .audio
        }
        focusedHUDPill = hudTab
    }

    private func closeHUD() {
        shortcutToRestore = hudIsSubtitlesOnly ? .subtitles : .options
        viewModel.closeHUD()
    }
}

private extension View {
    /// One line of skip prompt text at its fixed width.
    func skipPromptText(size: CGFloat, width: CGFloat) -> some View {
        font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width)
    }
}

// MARK: - Skip prompt button

/// A skip prompt. The UIKit view underneath is its only focus and Select
/// owner, and the glass label on top is passive, so there's no SwiftUI Button
/// waiting to activate on release.
private struct SkipPromptButton<Content: View>: View {
    let voiceOverTitle: String
    let perform: () -> Void
    @ViewBuilder let label: () -> Content

    @State private var focused = false
    @State private var pressed = false

    var body: some View {
        label()
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 76)
            .vividPlayerGlass(in: Capsule(), tint: focused ? .white.opacity(0.3) : nil)
            .overlay(Capsule().stroke(.white.opacity(focused ? 1 : 0), lineWidth: 3))
            .allowsHitTesting(false)
            .overlay {
                SkipPromptPressTarget(
                    voiceOverTitle: voiceOverTitle,
                    perform: perform,
                    focusChanged: { focused = $0 },
                    pressChanged: { pressed = $0 }
                )
            }
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 12, y: 6)
            .opacity(pressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

private struct SkipPromptPressTarget: UIViewRepresentable {
    let voiceOverTitle: String
    let perform: () -> Void
    let focusChanged: (Bool) -> Void
    let pressChanged: (Bool) -> Void

    func makeUIView(context: Context) -> SkipPromptPressView {
        let view = SkipPromptPressView()
        view.target = self
        view.accessibilityLabel = voiceOverTitle
        return view
    }

    func updateUIView(_ uiView: SkipPromptPressView, context: Context) {
        uiView.target = self
        uiView.accessibilityLabel = voiceOverTitle
    }
}

/// A focusable view that runs the skip once, on Select press-down, and
/// treats the release or a cancellation as the end of that press. Every
/// other button (the arrows, Menu) carries on up the responder chain.
private final class SkipPromptPressView: UIView {
    var target: SkipPromptPressTarget?
    private var holdingSelect = false

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SkipPromptPressView is only made in code")
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        target?.focusChanged(isFocused)
        if !isFocused { releaseSelect() }
        PlaybackTrialTrace.controlEvent("skip_focus", fields: "focused=\(isFocused)")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if Self.includesSelect(presses) && isFocused && !holdingSelect {
            holdingSelect = true
            target?.pressChanged(true)
            PlaybackTrialTrace.controlEvent("skip_select", fields: "focused=true")
            target?.perform()
        }
        let others = Self.withoutSelect(presses)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if Self.includesSelect(presses) { releaseSelect() }
        let others = Self.withoutSelect(presses)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if Self.includesSelect(presses) { releaseSelect() }
        let others = Self.withoutSelect(presses)
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    override func accessibilityActivate() -> Bool {
        target?.perform()
        return true
    }

    private func releaseSelect() {
        guard holdingSelect else { return }
        holdingSelect = false
        target?.pressChanged(false)
    }

    private static func withoutSelect(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { $0.type != .select }
    }

    private static func includesSelect(_ presses: Set<UIPress>) -> Bool {
        presses.contains { $0.type == .select }
    }
}
#endif
