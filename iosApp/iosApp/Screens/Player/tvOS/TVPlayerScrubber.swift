#if os(tvOS)
import SwiftUI

// BEGIN TVTimelineScrubMath
// scripts/ci/check-tv-remote-wheel.sh compiles the code between these
// markers on its own, so it must only need Foundation.

/// Timeline arithmetic for the Apple TV scrubber.
enum TVTimelineScrubMath {
    /// Left and Right steps, in seconds.
    static let backwardStep: Double = 10
    static let forwardStep: Double = 30

    /// A held Left or Right seeks this many seconds times the rate every
    /// 100 ms. Left and Right step the rate along the ladder, which skips 0.
    static let autoSeekBaseStep: Double = 2
    static let autoSeekRates = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]

    /// One full edge-to-edge swipe on the Siri Remote surface is about
    /// 1,000 points, so a full swipe covers roughly 8% of the timeline and a
    /// light drag lands within seconds of where it started.
    static let panPointsForFullTimeline: CGFloat = 12000
    /// Accumulated drag before the playhead moves. A clickpad click always
    /// jitters the finger a few points and must not nudge the preview.
    static let panDeadzone: CGFloat = 12

    /// `time` as a fraction of `duration`, clamped to 0...1, or 0 when the
    /// duration is unknown.
    static func fraction(of time: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(time / duration, 0), 1)
    }

    /// `time` clamped to the timeline.
    static func clampedTime(_ time: Double, duration: Double) -> Double {
        min(max(time, 0), duration)
    }

    /// The rate `delta` rungs along the ladder from `rate`, stopping at
    /// either end, or nil when `rate` isn't on the ladder.
    static func autoSeekRate(from rate: Int, delta: Int) -> Int? {
        guard let index = autoSeekRates.firstIndex(of: rate) else { return nil }
        return autoSeekRates[max(0, min(autoSeekRates.count - 1, index + delta))]
    }

    /// Seconds of timeline a drag of `translation` points covers.
    static func panSeconds(forTranslation translation: CGFloat, duration: Double) -> Double {
        Double(translation / panPointsForFullTimeline) * duration
    }
}

/// Deadzone for one drag on the Siri Remote surface. Small deltas build up
/// until they cross the deadzone; the whole build-up then applies at once,
/// and every later delta applies directly.
struct TVTimelinePanTracker {
    private(set) var isEngaged = false
    private var accumulated: CGFloat = 0

    /// The translation to apply for `delta`, or nil while the drag is still
    /// inside the deadzone.
    mutating func translation(for delta: CGFloat) -> CGFloat? {
        if isEngaged { return delta }
        accumulated += delta
        guard abs(accumulated) >= TVTimelineScrubMath.panDeadzone else { return nil }
        isEngaged = true
        return accumulated
    }
}
// END TVTimelineScrubMath


/// The Apple TV timeline: a thin progress line that grows a puck while it has
/// focus.
///
/// With focus and nothing selected, Left and Right skip back 10 or forward 30
/// seconds through `PlayerViewModel`, which folds quick repeats into one
/// seek. Select pauses and starts a time selection. While selecting, the
/// preview moves by Left and Right steps, by swipes, or by holding Left or
/// Right to seek at a speed; Select commits it, and Menu or opening a player
/// menu throws it away. The clock labels sit in the footer under the line.
struct TVPlayerScrubber: View {
    let viewModel: PlayerViewModel
    @FocusState.Binding var isFocused: Bool
    /// Every Select on the timeline, before it's handled.
    let onSelectPressed: () -> Void
    /// Up from an idle timeline.
    let onMoveUpToShortcuts: () -> Void
    /// Menu with no scrub or selection to cancel.
    let onMenuWhileIdle: () -> Void

    /// Whether a time selection is running. The controls own it, so they can
    /// take the shortcut circles out of the focus graph while it's modal;
    /// otherwise a Down press or swipe would move focus natively before
    /// `onMoveCommand` sees it.
    @Binding var isSelecting: Bool

    /// Whether committing this selection should resume playback, because the
    /// selection is what paused it. The controls own it so a selection they
    /// start can carry the state from before their pause.
    @Binding var resumesAfterSelection: Bool

    /// Losing focus cancels a scrub in flight rather than committing it. The
    /// controls set this before opening a menu, so the blur can't seek.
    var cancelsScrubOnBlur: Bool = false

    /// Signed hold-to-seek speed, or 0 when no hold seek is running.
    @State private var holdRate = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var isSwiping = false
    @State private var swipeDeadzone = TVTimelinePanTracker()
    /// Whether the preview has moved in this selection. Select straight back
    /// out with no movement resumes the paused pipeline where it was.
    @State private var selectionMoved = false

    private enum Metrics {
        static let restingLine: CGFloat = 5
        static let selectingLine: CGFloat = 7
        static let restingPuckWidth: CGFloat = 30
        static let selectingPuckWidth: CGFloat = 36
        static let restingPuckHeight: CGFloat = 17
        static let selectingPuckHeight: CGFloat = 20
        /// Tall enough for the biggest puck, so focus never resizes the
        /// transport.
        static let rowHeight: CGFloat = 56
        static let chipLift: CGFloat = -34
        /// The window observers only need a point to exist.
        static let observerSide: CGFloat = 1
        static let loadedOpacity = 0.28
        static let holdTick: UInt64 = 100_000_000
    }

    /// The scrub preview during a scrub, otherwise the playhead.
    private var shownTime: Double {
        if viewModel.isScrubbing { return viewModel.scrubPreviewTime }
        return viewModel.currentTime
    }

    private var hasKnownLength: Bool { viewModel.duration > 0 }

    private var playedShare: Double {
        TVTimelineScrubMath.fraction(of: shownTime, duration: viewModel.duration)
    }

    private var loadedShare: Double {
        TVTimelineScrubMath.fraction(
            of: viewModel.currentTime + viewModel.timelineBufferedAheadSeconds,
            duration: viewModel.duration
        )
    }

    private var isHoldSeeking: Bool { holdRate != 0 }

    private var lineHeight: CGFloat {
        isSelecting ? Metrics.selectingLine : Metrics.restingLine
    }

    var body: some View {
        // A plain focusable view, not a Button. Every tvOS button style paints
        // a focused surface across its whole frame, which made the line a
        // full-width white slab, and `.focusEffectDisabled()` can't remove a
        // style's own surface. Select reaches a focused view as a tap.
        line
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if isHoldSeeking {
                    holdSpeedChip
                        .offset(y: Metrics.chipLift)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .focusable(true)
            .focused($isFocused)
            .onTapGesture { selectPressed() }
            .background {
                ZStack {
                    TVSideArrowObserver(
                        isActive: isFocused && !viewModel.isHoldSeeking && holdRate == 0,
                        onArrowTap: sideArrowTapped,
                        onArrowHoldBegin: sideArrowHeld
                    )
                    // While selecting, swipes drag the preview smoothly rather
                    // than stepping it by move commands.
                    TVSwipeObserver(
                        isActive: isFocused && isSelecting && !isHoldSeeking,
                        onSwipeBegan: {
                            isSwiping = true
                            swipeDeadzone = TVTimelinePanTracker()
                        },
                        onSwipeMoved: swipeMoved,
                        onSwipeEnded: { isSwiping = false }
                    )
                }
                .frame(width: Metrics.observerSide, height: Metrics.observerSide)
            }
            .onChange(of: isFocused) { _, nowFocused in
                // Gaining focus isn't a scrub; the first press starts one.
                // Losing it only matters with a scrub in flight.
                if !nowFocused && viewModel.isScrubbing {
                    focusLeftDuringScrub()
                }
            }
            .onChange(of: isSelecting) { _, started in
                if started { selectionMoved = false }
            }
            .onMoveCommand(perform: moved)
            .onExitCommand {
                if isSelecting || viewModel.isScrubbing {
                    abandonSelection()
                } else {
                    onMenuWhileIdle()
                }
            }
            // Otherwise the hold task outlives the view and keeps moving the
            // preview after a reload takes the controls away.
            .onDisappear { stopHoldSeek() }
            .accessibilityLabel("Scrubber")
            .accessibilityValue(Text(PlayerTimeFormatter.formatHMS(shownTime)))
    }

    // MARK: - Drawing

    private var line: some View {
        GeometryReader { proxy in
            let span = proxy.size.width
            ZStack(alignment: .leading) {
                // A translucent track with the played part in solid white.
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(trackOpacity))
                    .frame(height: lineHeight)

                openingMarkers(span: span)

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: span * playedShare, height: lineHeight)

                // Only what's loaded beyond the playhead. Routes with no buffer
                // telemetry leave `timelineBufferedAheadSeconds` at 0.
                let loadedAhead = max(0, loadedShare - playedShare)
                if loadedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(Metrics.loadedOpacity))
                        .frame(width: span * loadedAhead, height: lineHeight)
                        .offset(x: span * playedShare)
                }

                // No puck without focus, so the line reads as plain progress.
                if isFocused {
                    puck(span: span)
                }
            }
            .frame(height: Metrics.rowHeight, alignment: .center)
        }
        .frame(height: Metrics.rowHeight)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        // Progress isn't animated on purpose: animating it turned every tick,
        // and every hand-off from preview to playhead, into a visible slide.
    }

    private var trackOpacity: Double {
        if isSelecting { return 0.48 }
        return isFocused ? 0.35 : 0.24
    }

    /// The recap and intro ranges, tinted on the track.
    @ViewBuilder
    private func openingMarkers(span: CGFloat) -> some View {
        ForEach(Array(viewModel.openingSkipRanges.enumerated()), id: \.offset) { _, range in
            if hasKnownLength {
                let from = TVTimelineScrubMath.fraction(of: range.start, duration: viewModel.duration)
                let to = TVTimelineScrubMath.fraction(of: range.end, duration: viewModel.duration)
                if to > from {
                    Capsule(style: .continuous)
                        .fill(Color.cyan.opacity(isSelecting || isFocused ? 0.45 : 0.34))
                        .frame(width: span * (to - from), height: lineHeight)
                        .offset(x: span * from)
                }
            }
        }
    }

    private func puck(span: CGFloat) -> some View {
        let width = isSelecting ? Metrics.selectingPuckWidth : Metrics.restingPuckWidth
        return Ellipse()
            .fill(Color.white)
            .frame(width: width, height: isSelecting ? Metrics.selectingPuckHeight : Metrics.restingPuckHeight)
            .overlay(Ellipse().stroke(Color.white.opacity(isSelecting ? 0.55 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(0.48), radius: 8, y: 3)
            .offset(x: span * CGFloat(playedShare) - width / 2)
    }

    private var holdSpeedChip: some View {
        let speed = abs(holdRate)
        return HStack(spacing: 7) {
            Image(systemName: holdRate < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 13, weight: .bold))
            Text("\(speed)x")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: holdRate)
    }

    // MARK: - Remote input

    /// -1 for Left, 1 for Right, nil for Up and Down.
    private static func sideSign(of arrow: TVPressCaptureView.ArrowDirection) -> Int? {
        switch arrow {
        case .left: return -1
        case .right: return 1
        case .up, .down: return nil
        }
    }

    /// The step for a side arrow while selecting: back 10 or forward 30.
    private static func selectionStep(sign: Int) -> Double {
        sign < 0 ? -TVTimelineScrubMath.backwardStep : TVTimelineScrubMath.forwardStep
    }

    private func sideArrowTapped(_ arrow: TVPressCaptureView.ArrowDirection) {
        guard let sign = Self.sideSign(of: arrow) else { return }
        if isHoldSeeking {
            changeHoldRate(by: sign)
        } else if isSelecting {
            movePreview(by: Self.selectionStep(sign: sign))
        } else if sign < 0 {
            viewModel.skipBackward(TVTimelineScrubMath.backwardStep)
        } else {
            viewModel.skipForward(TVTimelineScrubMath.forwardStep)
        }
    }

    private func sideArrowHeld(_ arrow: TVPressCaptureView.ArrowDirection) {
        guard let sign = Self.sideSign(of: arrow) else { return }
        startHoldSeek(rate: sign)
    }

    private func moved(_ direction: MoveCommandDirection) {
        switch direction {
        case .left, .right:
            guard hasKnownLength else { return }
            let sign = direction == .left ? -1 : 1
            // A swipe also sends Left and Right move commands. While the drag
            // owns the preview, the steps stay out of its way.
            let swipeOwnsPreview = isSwiping && isSelecting && !isHoldSeeking
            if isHoldSeeking {
                changeHoldRate(by: sign)
            } else if isSelecting && !swipeOwnsPreview {
                movePreview(by: Self.selectionStep(sign: sign))
            }
        case .up:
            // Mid-scrub, an upward move is nearly always a drag spilling over,
            // so the preview waits for Select or Menu.
            guard !isSelecting && !viewModel.isScrubbing else { return }
            onMoveUpToShortcuts()
        case .down:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Selecting

    /// Select commits a scrub in flight at once, without waiting out the skip
    /// debounce, or starts a time selection.
    private func selectPressed() {
        onSelectPressed()
        guard isSelecting || viewModel.isScrubbing else {
            guard hasKnownLength else { return }
            resumesAfterSelection = viewModel.isPlaying
            viewModel.pauseForTimelineSelection()
            viewModel.beginScrub(fraction: viewModel.currentTime / viewModel.duration)
            isSelecting = true
            return
        }
        let resume = isSelecting && resumesAfterSelection
        let seek = !isSelecting || selectionMoved
        finishSelecting()
        viewModel.endScrub(resumePlayback: resume, shouldSeek: seek)
    }

    private func focusLeftDuringScrub() {
        if isSelecting {
            finishSelecting()
            viewModel.cancelScrub()
        } else if cancelsScrubOnBlur {
            viewModel.cancelScrub()
        } else {
            viewModel.endScrub()
        }
    }

    private func abandonSelection() {
        guard isSelecting || viewModel.isScrubbing else { return }
        finishSelecting()
        viewModel.cancelScrub()
    }

    /// Stops any hold seek and clears the selection state, before the view
    /// model is told how the scrub ends.
    private func finishSelecting() {
        stopHoldSeek()
        isSelecting = false
        resumesAfterSelection = false
    }

    // MARK: - Hold to seek

    /// A hold starts a selection when none is running, without pausing.
    /// Committing resumes only if playback was running.
    private func startHoldSeek(rate: Int) {
        if !isSelecting && hasKnownLength {
            resumesAfterSelection = viewModel.isPlaying
            viewModel.beginScrub(fraction: TVTimelineScrubMath.fraction(of: shownTime, duration: viewModel.duration))
            isSelecting = true
        }
        holdRate = rate
        holdTask?.cancel()
        // Steps at once, then every 100 ms, until the rate goes back to 0.
        holdTask = Task { @MainActor in
            while !Task.isCancelled && holdRate != 0 {
                movePreview(by: TVTimelineScrubMath.autoSeekBaseStep * Double(holdRate))
                try? await Task.sleep(nanoseconds: Metrics.holdTick)
            }
        }
    }

    private func changeHoldRate(by delta: Int) {
        guard isHoldSeeking, let next = TVTimelineScrubMath.autoSeekRate(from: holdRate, delta: delta) else { return }
        holdRate = next
    }

    private func stopHoldSeek() {
        holdTask?.cancel()
        holdTask = nil
        holdRate = 0
    }

    // MARK: - Moving the preview

    private func swipeMoved(_ deltaX: CGFloat) {
        // The deadzone only builds up while a selection with a known length
        // is running.
        guard isSelecting, hasKnownLength,
              let translation = swipeDeadzone.translation(for: deltaX)
        else { return }
        movePreview(by: TVTimelineScrubMath.panSeconds(forTranslation: translation, duration: viewModel.duration))
    }

    private func movePreview(by seconds: Double) {
        let from = shownTime
        let to = TVTimelineScrubMath.clampedTime(from + seconds, duration: viewModel.duration)
        if to != from {
            selectionMoved = true
        }
        viewModel.updateScrub(fraction: to / viewModel.duration)
    }
}
#endif
