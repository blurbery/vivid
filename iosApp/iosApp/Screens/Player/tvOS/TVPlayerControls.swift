#if os(tvOS)
import CoreGraphics
import SwiftUI
import UIKit

/// Which pair of clock labels sits under the Apple TV timeline. A light
/// touch on the Siri Remote surface switches between them.
enum TVPlayerTimeDisplayMode: Equatable {
    case elapsedRemaining
    case currentAndFinish

    mutating func toggle() {
        self = self == .elapsedRemaining ? .currentAndFinish : .elapsedRemaining
    }
}

/// The Apple TV player overlay.
///
/// Idle, it is a minimal bottom transport: title, the subtitle and options
/// shortcuts, the timeline and its clock labels. Opening options swaps it for
/// `TVPlayerInfoHUD`, a floating panel at the top. Intro and credits skip
/// prompts float above the transport, or stand alone when it is hidden. The
/// controls auto-hide 5 seconds after the last focus move while playing.
/// Menu handling lives in `PlayerView`, which can see the whole player.
struct TVPlayerControls: View {
    private static let transportHorizontalInset: CGFloat = 80

    let viewModel: PlayerViewModel
    let showsTimelinePreview: Bool
    let timeDisplayMode: TVPlayerTimeDisplayMode
    let timelineSelectionRequest: UUID?
    let onToggleTimeDisplayMode: () -> Void
    let onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    /// The HUD reopens on the tab used last. This lives here because the HUD
    /// view is rebuilt every time it opens.
    @State private var activeHUDTab: TVPlayerInfoHUD.Tab = .info
    @State private var subtitleOnlyHUD = false
    @State private var rememberedInfoTab: TVPlayerInfoHUD.Tab = .info
    @State private var hudReturnTarget: TVPlayerTransportCluster.FocusTarget?

    /// Set just before the HUD opens, so the scrubber treats the blur that
    /// follows as a cancel rather than a commit. Otherwise opening the HUD
    /// with a scrub preview in flight would seek to it.
    @State private var cancelPendingScrub: Bool = false
    /// Mirrors the scrubber's explicit timeline selection, so the shortcut
    /// row can leave the focus graph while the selection is modal.
    @State private var isTimelineScrubbing: Bool = false
    /// Whether the current timeline selection interrupted playback. A
    /// selection opened while already paused leaves playback paused; Select
    /// from playing resumes it.
    @State private var resumePlaybackAfterTimelineSelection = false
    /// True while the scrubber owns focus. The shortcut row leaves the focus
    /// graph meanwhile, so a press towards it has no native target: the
    /// engine would otherwise move focus geometrically to whichever button
    /// sits nearest the playhead before the scrubber's `onMoveCommand` runs,
    /// which reads as a hop off the wrong button. It is released on the
    /// hand-off to the row, so the seed has a target, and whenever the
    /// scrubber loses focus for another reason (intro skip, HUD).
    @State private var trapsTransportFocus = false
    /// A touch-surface contact toggles the clock labels only if it ends as a
    /// light touch. Select, clicks and drags clear it, so their transport
    /// behaviour stays exclusive.
    @State private var fullHUDContactCanToggle = false
    @State private var transportHeight: CGFloat = 240

    private var skipPromptBottomInset: CGFloat {
        viewModel.showControls ? max(180, transportHeight + 48 + 32) : 180
    }

    // One focus binding per zone. Focusing one clears the others. The HUD tab
    // binding lives here, not in `TVPlayerInfoHUD`, so opening the HUD can
    // seed a pill: with nothing focused, Menu has no handler to bubble to and
    // the user is stuck in the panel.
    @FocusState private var isScrubberFocused: Bool
    @FocusState private var focusedTransportButton: TVPlayerTransportCluster.FocusTarget?
    @FocusState private var focusedHUDTab: TVPlayerInfoHUD.Tab?
    @FocusState private var focusedIntroAction: IntroAction?
    @FocusState private var isCreditsSkipFocused: Bool

    private var isHUDPresented: Bool { viewModel.isHUDPresented }

    var body: some View {
        ZStack {
            if showsTimelinePreview && !viewModel.showControls && !isHUDPresented {
                timelinePreviewOverlay
                    .transition(.opacity)
            }
            // The idle overlay and the HUD never show together. Stacking them
            // let scrubber clicks reach hidden shortcut buttons and left the
            // progress bar showing under the panel.
            if viewModel.showControls && !isHUDPresented {
                idleOverlay
                    .transition(.opacity)
            }
            if viewModel.showIntroSkip && !isHUDPresented {
                introSkipLayer
                    .transition(.opacity)
            }
            if viewModel.showCreditsSkip && !isHUDPresented {
                creditsSkipLayer
                    .transition(.opacity)
            }
            if isHUDPresented {
                TVPlayerInfoHUD(
                    viewModel: viewModel,
                    activeTab: $activeHUDTab,
                    focusedTab: $focusedHUDTab,
                    subtitleOnly: subtitleOnlyHUD,
                    onDismiss: { closeHUD() }
                )
                .transition(.opacity)
            }
        }
        .background {
            TVTouchSurfaceContactGestureView(
                // Active in both the idle and timeline-selection states. It
                // recognises alongside the pan, so a real drag still scrubs.
                isActive: viewModel.showControls && !isHUDPresented,
                onContactBegan: {
                    fullHUDContactCanToggle = true
                },
                onContactEnded: {
                    guard fullHUDContactCanToggle else { return }
                    fullHUDContactCanToggle = false
                    onToggleTimeDisplayMode()
                },
                onContactCancelled: {
                    fullHUDContactCanToggle = false
                },
                onDirectionalPressBegan: {
                    fullHUDContactCanToggle = false
                }
            )
            .frame(width: 1, height: 1)
        }
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isHUDPresented)
        // No Menu handler here: `PlayerView` reads `isHUDPresented` itself, so
        // it catches Menu even when focus drifts off the HUD, and a handler
        // here would swallow Menu while the HUD is closed.
        .onChange(of: isHUDPresented) { _, presented in
            fullHUDContactCanToggle = false
            guard !presented else { return }
            cancelPendingScrub = false
            focusedHUDTab = nil
            let target: TVPlayerTransportCluster.FocusTarget = subtitleOnlyHUD ? .subtitles : .options
            hudReturnTarget = target
            trapsTransportFocus = false
            isScrubberFocused = false
            DispatchQueue.main.async {
                guard !isHUDPresented, viewModel.showControls else { return }
                focusedTransportButton = target
            }
        }
        .onChange(of: viewModel.requestedTVHUDEntryPoint) { _, entryPoint in
            guard let entryPoint else { return }
            applyHUDEntryPoint(entryPoint)
            viewModel.consumeTVHUDEntryRequest()
        }
        .onChange(of: timelineSelectionRequest) { _, request in
            guard request != nil else { return }
            fullHUDContactCanToggle = false
            // PlayerView only sends this from its playing Select path, just
            // after pausing.
            resumePlaybackAfterTimelineSelection = true
            enterTimelineSelection()
        }
        .onChange(of: viewModel.showControls) { _, visible in
            fullHUDContactCanToggle = false
            if !visible {
                hudReturnTarget = nil
                DispatchQueue.main.async { focusStandaloneSkipPrompt() }
            }
        }
        // A focus move restarts the auto-hide, so the fixed 5 second timer
        // can't hide the controls, and the user's focus, mid-interaction.
        .onChange(of: isScrubberFocused) { _, focused in
            if focused { rearmAutoHideOnFocusMove() }
            trapsTransportFocus = focused
        }
        .onChange(of: focusedTransportButton) { _, target in
            if target != nil { rearmAutoHideOnFocusMove() }
        }
        // TV sleep drops the app's focus while `showControls` stays true, so
        // on wake the overlay is already mounted, its `onAppear` seed doesn't
        // run again, and nothing is focused. Menu then never reaches
        // PlayerView's `onExitCommand`. Reseed focus when the scene is active.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // One turn later, once the focus engine is back on the scene; a
            // claim in the same transaction can be dropped.
            DispatchQueue.main.async {
                reseedFocusAfterWake()
            }
        }
    }

    private func reseedFocusAfterWake() {
        if isHUDPresented {
            if focusedHUDTab == nil { focusedHUDTab = activeHUDTab }
        } else if viewModel.showControls {
            if focusedTransportButton == nil && !isScrubberFocused &&
                focusedIntroAction == nil && !isCreditsSkipFocused {
                isScrubberFocused = true
            }
        } else {
            focusStandaloneSkipPrompt()
        }
    }

    @MainActor
    private func focusMountedSkipPrompt() async {
        // Let the button join the focus graph before claiming focus.
        await Task.yield()
        guard !Task.isCancelled else { return }
        focusStandaloneSkipPrompt()
    }

    private func focusStandaloneSkipPrompt() {
        guard !isHUDPresented, !viewModel.showControls else { return }
        if viewModel.showIntroSkip {
            focusedIntroAction = .skip
        } else if viewModel.showCreditsSkip {
            isCreditsSkipFocused = true
        }
    }

    private func rearmAutoHideOnFocusMove() {
        guard viewModel.showControls, !isHUDPresented else { return }
        viewModel.revealControls()
    }

    // MARK: - Timeline preview

    /// The passive timeline and clock labels a light touch shows while the
    /// controls are hidden.
    private var timelinePreviewOverlay: some View {
        ZStack(alignment: .bottom) {
            bottomGradient.ignoresSafeArea()
            VStack(spacing: 10) {
                PlayerTickIsolated { passiveTimelineBar }
                PlayerTickIsolated { timeRow }
            }
            .padding(.horizontal, Self.transportHorizontalInset)
            .padding(.bottom, 48)
        }
        .allowsHitTesting(false)
    }

    private var passiveTimelineBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = progressFraction
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 7)

                let bufferedAhead = max(0, bufferedFraction - progress)
                if bufferedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: width * bufferedAhead, height: 7)
                        .offset(x: width * progress)
                }

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * progress, height: 7)
            }
            .frame(height: 20, alignment: .center)
        }
        .frame(height: 20)
    }

    private var progressFraction: Double {
        TVTimelineScrubMath.fraction(of: scrubberDisplayTime, duration: viewModel.duration)
    }

    private var bufferedFraction: Double {
        TVTimelineScrubMath.fraction(
            of: viewModel.currentTime + viewModel.timelineBufferedAheadSeconds,
            duration: viewModel.duration
        )
    }

    // MARK: - Idle overlay

    @ViewBuilder
    private var idleOverlay: some View {
        ZStack(alignment: .bottom) {
            bottomGradient.ignoresSafeArea()
            statusColumn
                .padding(.top, viewModel.isBuffering ? 120 : 64)
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            transportStack
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    transportHeight = height
                }
                .padding(.horizontal, Self.transportHorizontalInset)
                .padding(.bottom, 48)
        }
        .onAppear {
            focusedTransportButton = nil
            // Opening the controls is an explicit move away from a skip prompt.
            focusedIntroAction = nil
            isCreditsSkipFocused = false
            if let returnTarget = hudReturnTarget {
                trapsTransportFocus = false
                isScrubberFocused = false
                focusedTransportButton = returnTarget
            } else {
                isScrubberFocused = true
            }
        }
    }

    /// A shallow gradient that gives the transport contrast on bright frames.
    private var bottomGradient: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
        }
    }

    /// The sleep timer chip, top right, while a timer runs. Buffering belongs
    /// to the player shell so it shows outside this overlay too.
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if viewModel.sleepTimer.isActive {
                Label(PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds),
                      systemImage: "moon.zzz.fill")
                    .font(.vividSmall.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .vividPlayerGlass(in: Capsule())
            }
        }
    }

    // MARK: - Skip prompts

    /// A move off a standalone prompt reveals the timeline. Once the controls
    /// are up, their native focus graph owns movement.
    private func moveFromSkipPrompt(_ direction: MoveCommandDirection) {
        guard !viewModel.showControls, !isHUDPresented else { return }
        // Left and Right stay between Cancel and Skip during a countdown.
        if viewModel.showIntroSkip && viewModel.introAutoSkipCountdownSeconds != nil &&
            (direction == .left || direction == .right) {
            return
        }
        viewModel.revealControls()
    }

    private var introSkipLayer: some View {
        introSkipButtons
            .focusSection()
            .onMoveCommand(perform: moveFromSkipPrompt)
            .task { await focusMountedSkipPrompt() }
            .padding(.horizontal, 80)
            .padding(.bottom, skipPromptBottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var creditsSkipLayer: some View {
        TVSkipButton(accessibilityTitle: String(localized: "Skip Credits")) {
            viewModel.skipCredits()
        } label: {
            Label("Skip Credits", systemImage: "forward.end.fill")
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 220)
        }
        .focused($isCreditsSkipFocused)
        .accessibilityLabel("Skip Credits")
        .focusSection()
        .onMoveCommand(perform: moveFromSkipPrompt)
        .task { await focusMountedSkipPrompt() }
        .padding(.horizontal, 80)
        .padding(.bottom, skipPromptBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var introSkipButtons: some View {
        VStack(alignment: .trailing, spacing: 16) {
            if let countdown = viewModel.introAutoSkipCountdownSeconds {
                introCountdownBadge(countdown)
            }

            HStack(spacing: 18) {
                if viewModel.introAutoSkipCountdownSeconds != nil {
                    TVSkipButton(accessibilityTitle: viewModel.introSkipCancelLabel) {
                        viewModel.cancelIntroAutoSkip()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.system(size: 24, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 136)
                    }
                    .focused($focusedIntroAction, equals: .cancel)
                    .accessibilityLabel(viewModel.introSkipCancelLabel)
                }

                skipIntroButton
            }
        }
    }

    private var skipIntroButton: some View {
        let isCountingDown = viewModel.introAutoSkipCountdownSeconds != nil
        return TVSkipButton(accessibilityTitle: viewModel.introSkipLabel) {
            viewModel.skipIntro()
        } label: {
            Label(
                isCountingDown ? String(localized: "Skip Now") : viewModel.introSkipLabel,
                systemImage: "forward.end.fill"
            )
            .font(.system(size: 26, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: 220)
        }
        .focused($focusedIntroAction, equals: .skip)
        .accessibilityLabel(isCountingDown ? viewModel.introSkipNowLabel : viewModel.introSkipLabel)
    }

    private func introCountdownBadge(_ countdown: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 19, weight: .semibold))
            Text("Intro")
                .font(.system(size: 17, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.62))
            Text("Skipping in \(countdown)")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VividTheme.smallCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    private enum IntroAction: Hashable {
        case cancel
        case skip
    }

    // MARK: - Transport stack

    private var transportStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 24) {
                titleFooter
                Spacer(minLength: 24)
                transportShortcuts
            }
            TVPlayerScrubber(
                viewModel: viewModel,
                isFocused: $isScrubberFocused,
                onSelectInteraction: {
                    fullHUDContactCanToggle = false
                },
                onMoveToTransport: {
                    // This only runs because the trap kept the shortcut row
                    // out of the focus graph. Restore the row first, then seed
                    // Options on the next turn: a claim in the same
                    // transaction as the re-enable gets dropped. Focus stays
                    // on the scrubber for that frame, so there's no visible
                    // stop on the way.
                    trapsTransportFocus = false
                    DispatchQueue.main.async {
                        focusedTransportButton = .options
                    }
                },
                onExitWhenIdle: {
                    // While paused, Menu leaves the player rather than hiding
                    // the controls over a frozen frame.
                    if viewModel.isPlaying {
                        viewModel.dismissControls()
                    } else {
                        onDismiss()
                    }
                },
                isTimelineScrubbing: $isTimelineScrubbing,
                resumePlaybackAfterTimelineSelection: $resumePlaybackAfterTimelineSelection,
                cancelOnBlur: cancelPendingScrub
            )
            PlayerTickIsolated { timeRow }
        }
    }

    private var transportShortcuts: some View {
        TVPlayerTransportCluster(
            viewModel: viewModel,
            onOpenHUD: { openHUD() },
            onOpenSubtitles: { openHUD(subtitles: true) },
            onMoveToScrubber: {
                // One write, as in onMoveToTransport: clearing the shortcut
                // focus first invites a geometric repair hop.
                isScrubberFocused = true
            },
            // A timeline selection is modal, and a focused scrubber traps the
            // move towards the row: with the shortcuts out of the focus graph
            // there's no native target, so the hand-off goes through
            // onMoveToTransport instead of the engine's geometric pick.
            allowsFocus: !isTimelineScrubbing && !trapsTransportFocus,
            focusedButton: $focusedTransportButton
        )
    }

    /// The playing title as a quiet caption above the timeline, hidden until
    /// a title resolves.
    @ViewBuilder
    private var titleFooter: some View {
        let title = displayTitle
        if !title.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let series = viewModel.metadata.seriesTitle, !series.isEmpty {
                    Text(series)
                        .font(.vividSmall.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(title)
                        .font(.vividHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episode = viewModel.metadata.episodeTag {
                        Text(episode)
                            .font(.vividSmall)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        }
    }

    private var displayTitle: String {
        viewModel.metadata.primaryTitle.isEmpty
            ? viewModel.title
            : viewModel.metadata.primaryTitle
    }

    // MARK: - Clock labels

    @ViewBuilder
    private var timeRow: some View {
        if timeDisplayMode == .currentAndFinish {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    pauseIndicator
                    clockText(formatClockTime(context.date))
                    Spacer()
                    if viewModel.duration > 0 {
                        let finish = formatClockTime(estimatedFinishDate(from: context.date))
                        let remaining = PlayerTimeFormatter.formatHMS(remainingTime)
                        clockText(String(localized: "\(finish) · \(remaining) left", comment: "Finish time and time remaining, for example 9:41 PM · 1:02:03 left"))
                    }
                }
            }
        } else {
            HStack {
                pauseIndicator
                clockText(PlayerTimeFormatter.formatHMS(scrubberDisplayTime))
                Spacer()
                if viewModel.duration > 0 {
                    let remaining = PlayerTimeFormatter.formatHMS(remainingTime)
                    clockText(String(localized: "\(remaining) left", comment: "Time remaining in the title, for example 1:02:03 left"))
                }
            }
        }
    }

    private var pauseIndicator: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .opacity(viewModel.isPlaying ? 0 : 1)
            .accessibilityHidden(viewModel.isPlaying)
            .accessibilityLabel("Paused")
    }

    private func clockText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
    }

    private var scrubberDisplayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    private var remainingTime: Double {
        max(0, viewModel.duration - scrubberDisplayTime)
    }

    private func estimatedFinishDate(from now: Date) -> Date {
        let speed = max(viewModel.settings.playbackSpeed, 0.1)
        return now.addingTimeInterval(remainingTime / speed)
    }

    private func formatClockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Timeline selection and HUD

    private func enterTimelineSelection() {
        cancelPendingScrub = false
        focusedHUDTab = nil
        focusedTransportButton = nil
        focusedIntroAction = nil
        viewModel.pinControlsVisible()

        guard viewModel.duration > 0 else {
            isTimelineScrubbing = false
            resumePlaybackAfterTimelineSelection = false
            isScrubberFocused = true
            return
        }

        viewModel.beginScrub(fraction: TVTimelineScrubMath.fraction(of: viewModel.currentTime, duration: viewModel.duration))
        isTimelineScrubbing = true
        isScrubberFocused = true
    }

    /// Opens the HUD. The order matters for focus:
    /// 1. `cancelPendingScrub`, so the scrubber cancels on the coming blur.
    /// 2. The idle overlay's focus bindings clear, so SwiftUI isn't holding
    ///    focus on a view that is about to leave.
    /// 3. `focusedHUDTab` is seeded, so the HUD opens with focus and Menu
    ///    has a handler to bubble to.
    /// 4. The view model presents the HUD.
    private func openHUD(subtitles: Bool = false) {
        if !subtitleOnlyHUD { rememberedInfoTab = activeHUDTab }
        subtitleOnlyHUD = subtitles
        activeHUDTab = subtitles ? .subtitles : rememberedInfoTab
        cancelPendingScrub = true
        isScrubberFocused = false
        focusedTransportButton = nil
        focusedHUDTab = activeHUDTab
        viewModel.openHUD()
    }

    private func applyHUDEntryPoint(_ entryPoint: PlayerViewModel.TVHUDEntryPoint) {
        subtitleOnlyHUD = false
        cancelPendingScrub = true
        isScrubberFocused = false
        focusedTransportButton = nil
        switch entryPoint {
        case .settings:
            activeHUDTab = .video
        case .playback:
            activeHUDTab = viewModel.audioTracks.isEmpty ? .video : .audio
        }
        focusedHUDTab = activeHUDTab
    }

    private func closeHUD() {
        hudReturnTarget = subtitleOnlyHUD ? .subtitles : .options
        viewModel.closeHUD()
    }
}

// MARK: - Skip button

/// A skip prompt button. The native view is the only focus and Select
/// owner; the glass label is passive, which avoids a SwiftUI Button's
/// activation on release.
private struct TVSkipButton<Label: View>: View {
    let accessibilityTitle: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isFocused = false
    @State private var isPressed = false

    var body: some View {
        label()
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 76)
            .vividPlayerGlass(in: Capsule(), tint: isFocused ? .white.opacity(0.3) : nil)
            .overlay(Capsule().stroke(.white.opacity(isFocused ? 1 : 0), lineWidth: 3))
            .allowsHitTesting(false)
            .overlay {
                TVSkipSelectView(
                    accessibilityTitle: accessibilityTitle,
                    action: action,
                    onFocus: { isFocused = $0 },
                    onPress: { isPressed = $0 }
                )
            }
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 12, y: 6)
            .opacity(isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

private struct TVSkipSelectView: UIViewRepresentable {
    let accessibilityTitle: String
    let action: () -> Void
    let onFocus: (Bool) -> Void
    let onPress: (Bool) -> Void

    func makeUIView(context: Context) -> TVSkipSelectUIView {
        let view = TVSkipSelectUIView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: TVSkipSelectUIView, context: Context) {
        view.accessibilityLabel = accessibilityTitle
        view.action = action
        view.onFocus = onFocus
        view.onPress = onPress
    }
}

/// Focusable view that runs the skip action once on Select press-down and
/// treats the release or cancellation as the end of that press. Other
/// presses (arrows, Menu) continue up the responder chain.
private final class TVSkipSelectUIView: UIView {
    var action: () -> Void = {}
    var onFocus: (Bool) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    private var selectIsDown = false

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocus(isFocused)
        if !isFocused { endSelect() }
        PlaybackTrialTrace.controlEvent("skip_focus", fields: "focused=\(isFocused)")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }), isFocused, !selectIsDown {
            selectIsDown = true
            onPress(true)
            PlaybackTrialTrace.controlEvent("skip_select", fields: "focused=true")
            action()
        }
        let others = Self.nonSelect(presses)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { endSelect() }
        let others = Self.nonSelect(presses)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { endSelect() }
        let others = Self.nonSelect(presses)
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    override func accessibilityActivate() -> Bool {
        action()
        return true
    }

    private func endSelect() {
        guard selectIsDown else { return }
        selectIsDown = false
        onPress(false)
    }

    private static func nonSelect(_ presses: Set<UIPress>) -> Set<UIPress> {
        presses.filter { $0.type != .select }
    }
}
#endif
