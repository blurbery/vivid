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

/// The Apple TV timeline, a thin bar with a puck while focused.
///
/// Focused but idle, Left and Right go through `PlayerViewModel.skipBackward`
/// and `skipForward`, which debounce rapid presses into one seek. Select
/// starts an explicit timeline selection: the preview moves by Left and Right
/// steps, by swipes, or by holding Left or Right to seek at a rate, and
/// Select commits it while Menu or opening a player menu abandons it. The
/// time readout lives in the footer below the timeline.
struct TVPlayerScrubber: View {
    let viewModel: PlayerViewModel
    @FocusState.Binding var isFocused: Bool
    let onSelectInteraction: () -> Void
    let onMoveToTransport: () -> Void
    let onExitWhenIdle: () -> Void

    /// Explicit timeline selection. The shell owns it so it can take the
    /// shortcut row out of the focus graph while the selection is modal;
    /// otherwise a Down press or swipe moves focus there natively before
    /// `onMoveCommand` runs.
    @Binding var isTimelineScrubbing: Bool

    /// Whether this timeline selection paused playback, and so resumes it on
    /// commit. The shell owns it so a selection it starts can carry the state
    /// from before its pause.
    @Binding var resumePlaybackAfterTimelineSelection: Bool

    /// When true, losing focus cancels an in-flight scrub instead of
    /// committing it. The shell sets it before opening a menu so the blur
    /// doesn't turn into an accidental seek.
    var cancelOnBlur: Bool = false

    private static let timelineAutoSeekTickNanos: UInt64 = 100_000_000
    @State private var timelineAutoSeekRate = 0
    @State private var timelineAutoSeekTask: Task<Void, Never>?

    @State private var isPanScrubbing = false
    @State private var panTracker = TVTimelinePanTracker()
    /// Tells entering and leaving the timeline apart from a real seek. A
    /// Select round trip with no movement resumes the paused pipeline in
    /// place.
    @State private var hasTimelineSelectionMoved = false

    private static let barHeight: CGFloat = 5
    private static let activeBarHeight: CGFloat = 7
    private static let puckSize: CGFloat = 20
    private static let activePuckSize: CGFloat = 26
    /// Room for the largest puck, so focus never resizes the transport stack.
    private static let trackStackHeight: CGFloat = 56

    /// The scrub preview while scrubbing, otherwise the playhead.
    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    private var progressFraction: Double {
        TVTimelineScrubMath.fraction(of: displayTime, duration: viewModel.duration)
    }

    private var bufferedFraction: Double {
        TVTimelineScrubMath.fraction(
            of: viewModel.currentTime + viewModel.timelineBufferedAheadSeconds,
            duration: viewModel.duration
        )
    }

    private var isTimelineAutoSeeking: Bool {
        timelineAutoSeekRate != 0
    }

    var body: some View {
        // A bare focusable view rather than a Button: every tvOS button style
        // draws a full-bounds focused surface that turned the bar into a
        // full-width white slab, and `.focusEffectDisabled()` can't remove it
        // because it belongs to the style. Select reaches the focused view as
        // a tap.
        barLayer
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if isTimelineAutoSeeking {
                    timelineAutoSeekChip
                        .offset(y: -34)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .focusable(true)
            .focused($isFocused)
            .onTapGesture { commitScrub() }
            .background {
                ZStack {
                    TVDirectionalPressGestureView(
                        isActive: isFocused && !viewModel.isHoldSeeking && timelineAutoSeekRate == 0,
                        onArrowTap: handleArrowTap,
                        onArrowHoldBegin: handleArrowHoldBegin
                    )
                    // During a timeline selection, swipes drag the preview
                    // continuously instead of stepping by move commands.
                    TVPanCaptureView(
                        isActive: isFocused && isTimelineScrubbing && !isTimelineAutoSeeking,
                        onPanBegan: {
                            isPanScrubbing = true
                            panTracker = TVTimelinePanTracker()
                        },
                        onPanChanged: handlePanChanged,
                        onPanEnded: { isPanScrubbing = false }
                    )
                }
                .frame(width: 1, height: 1)
            }
            .onChange(of: isFocused) { _, focused in
                // Gaining focus isn't a scrub; one starts with the first press.
                // Losing focus only matters while a scrub is in flight.
                guard !focused, viewModel.isScrubbing else { return }
                if isTimelineScrubbing {
                    stopTimelineAutoSeek()
                    isTimelineScrubbing = false
                    resumePlaybackAfterTimelineSelection = false
                    viewModel.cancelScrub()
                } else if cancelOnBlur {
                    viewModel.cancelScrub()
                } else {
                    viewModel.endScrub()
                }
            }
            .onChange(of: isTimelineScrubbing) { _, scrubbing in
                if scrubbing {
                    hasTimelineSelectionMoved = false
                }
            }
            .onMoveCommand(perform: handleMove)
            .onExitCommand {
                if isTimelineScrubbing || viewModel.isScrubbing {
                    cancelTimelineScrub()
                } else {
                    onExitWhenIdle()
                }
            }
            // The auto-seek task outlives the view otherwise, and keeps
            // moving the preview after a reload unmounts the controls.
            .onDisappear { stopTimelineAutoSeek() }
            .accessibilityLabel("Scrubber")
            .accessibilityValue(Text(PlayerTimeFormatter.formatHMS(displayTime)))
    }

    // MARK: - Bar

    private var barLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // A plain translucent track; the played part is solid white.
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isTimelineScrubbing ? 0.48 : isFocused ? 0.35 : 0.24))
                    .frame(height: trackHeight)

                introRegions(barWidth: width)

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * progressFraction, height: trackHeight)

                // Only the loaded range ahead of the playhead. Routes without
                // buffer telemetry leave `timelineBufferedAheadSeconds` at 0.
                let bufferedAhead = max(0, bufferedFraction - progressFraction)
                if bufferedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: width * bufferedAhead, height: trackHeight)
                        .offset(x: width * progressFraction)
                }

                // The puck only shows while focused, so the bar reads as a
                // passive progress line otherwise.
                if isFocused {
                    puck(barWidth: width)
                }
            }
            .frame(height: Self.trackStackHeight, alignment: .center)
        }
        .frame(height: Self.trackStackHeight)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        // Progress is deliberately not animated: animating it turned every
        // tick and every preview-to-playhead handoff into a visible slide.
    }

    @ViewBuilder
    private func introRegions(barWidth: CGFloat) -> some View {
        ForEach(Array(viewModel.openingSkipRanges.enumerated()), id: \.offset) { _, introRange in
            if viewModel.duration > 0 {
                let start = TVTimelineScrubMath.fraction(of: introRange.start, duration: viewModel.duration)
                let end = TVTimelineScrubMath.fraction(of: introRange.end, duration: viewModel.duration)
                if end > start {
                    Capsule(style: .continuous)
                        .fill(Color.cyan.opacity(isTimelineScrubbing || isFocused ? 0.45 : 0.34))
                        .frame(width: barWidth * (end - start), height: trackHeight)
                        .offset(x: barWidth * start)
                }
            }
        }
    }

    private func puck(barWidth: CGFloat) -> some View {
        let width = (isTimelineScrubbing ? Self.activePuckSize : Self.puckSize) + 10
        return Ellipse()
            .fill(Color.white)
            .frame(width: width, height: isTimelineScrubbing ? 20 : 17)
            .overlay(
                Ellipse().stroke(Color.white.opacity(isTimelineScrubbing ? 0.55 : 0), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.48), radius: 8, y: 3)
            .offset(x: barWidth * CGFloat(progressFraction) - width / 2)
    }

    private var trackHeight: CGFloat {
        isTimelineScrubbing ? Self.activeBarHeight : Self.barHeight
    }

    private var timelineAutoSeekChip: some View {
        HStack(spacing: 7) {
            Image(systemName: timelineAutoSeekRate < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 13, weight: .bold))
            Text("\(abs(timelineAutoSeekRate))x")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.easeOut(duration: VividTheme.fastDuration), value: timelineAutoSeekRate)
    }

    // MARK: - Input

    private func handleArrowTap(_ direction: TVPressCaptureView.ArrowDirection) {
        switch direction {
        case .left:
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: -1)
            } else if isTimelineScrubbing {
                stepTimeline(by: -TVTimelineScrubMath.backwardStep)
            } else {
                viewModel.skipBackward(TVTimelineScrubMath.backwardStep)
            }
        case .right:
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: 1)
            } else if isTimelineScrubbing {
                stepTimeline(by: TVTimelineScrubMath.forwardStep)
            } else {
                viewModel.skipForward(TVTimelineScrubMath.forwardStep)
            }
        case .up, .down:
            break
        }
    }

    private func handleArrowHoldBegin(_ direction: TVPressCaptureView.ArrowDirection) {
        switch direction {
        case .left:
            beginTimelineAutoSeek(rate: -1)
        case .right:
            beginTimelineAutoSeek(rate: 1)
        case .up, .down:
            break
        }
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        // A swipe during a drag also arrives here as Left and Right move
        // commands. The drag owns the preview, so the steps stay quiet.
        let panOwnsTimeline = isPanScrubbing && isTimelineScrubbing && !isTimelineAutoSeeking
        switch direction {
        case .left:
            guard viewModel.duration > 0 else { return }
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: -1)
            } else if isTimelineScrubbing, !panOwnsTimeline {
                stepTimeline(by: -TVTimelineScrubMath.backwardStep)
            }
        case .right:
            guard viewModel.duration > 0 else { return }
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: 1)
            } else if isTimelineScrubbing, !panOwnsTimeline {
                stepTimeline(by: TVTimelineScrubMath.forwardStep)
            }
        case .down:
            break
        case .up:
            // During a scrub an upward swipe is almost always drag spillover,
            // so the preview stays until Select commits or Menu cancels it.
            guard !isTimelineScrubbing, !viewModel.isScrubbing else { return }
            onMoveToTransport()
        @unknown default:
            break
        }
    }

    /// Select commits a scrub in flight straight away, without waiting for
    /// the skip debounce, or starts a timeline selection.
    private func commitScrub() {
        onSelectInteraction()
        if isTimelineScrubbing || viewModel.isScrubbing {
            let resumesPlayback = isTimelineScrubbing && resumePlaybackAfterTimelineSelection
            let shouldSeek = !isTimelineScrubbing || hasTimelineSelectionMoved
            stopTimelineAutoSeek()
            isTimelineScrubbing = false
            resumePlaybackAfterTimelineSelection = false
            viewModel.endScrub(resumePlayback: resumesPlayback, shouldSeek: shouldSeek)
        } else {
            guard viewModel.duration > 0 else { return }
            resumePlaybackAfterTimelineSelection = viewModel.isPlaying
            viewModel.pauseForTimelineSelection()
            viewModel.beginScrub(fraction: viewModel.currentTime / viewModel.duration)
            isTimelineScrubbing = true
        }
    }

    private func cancelTimelineScrub() {
        guard isTimelineScrubbing || viewModel.isScrubbing else { return }
        stopTimelineAutoSeek()
        isTimelineScrubbing = false
        resumePlaybackAfterTimelineSelection = false
        viewModel.cancelScrub()
    }

    // MARK: - Timeline selection

    /// A hold starts a timeline selection if one isn't running yet, without
    /// pausing; it resumes on commit only if playback was running.
    private func beginTimelineSelectionForHold() {
        guard !isTimelineScrubbing, viewModel.duration > 0 else { return }
        resumePlaybackAfterTimelineSelection = viewModel.isPlaying
        viewModel.beginScrub(fraction: TVTimelineScrubMath.fraction(of: displayTime, duration: viewModel.duration))
        isTimelineScrubbing = true
    }

    private func beginTimelineAutoSeek(rate: Int) {
        beginTimelineSelectionForHold()
        timelineAutoSeekRate = rate
        timelineAutoSeekTask?.cancel()
        timelineAutoSeekTask = Task { @MainActor in
            while !Task.isCancelled {
                let rate = timelineAutoSeekRate
                if rate == 0 { break }
                stepTimeline(by: TVTimelineScrubMath.autoSeekBaseStep * Double(rate))
                try? await Task.sleep(nanoseconds: Self.timelineAutoSeekTickNanos)
            }
        }
    }

    private func adjustTimelineAutoSeekRate(delta: Int) {
        guard isTimelineAutoSeeking,
              let rate = TVTimelineScrubMath.autoSeekRate(from: timelineAutoSeekRate, delta: delta)
        else { return }
        timelineAutoSeekRate = rate
    }

    private func stopTimelineAutoSeek() {
        timelineAutoSeekTask?.cancel()
        timelineAutoSeekTask = nil
        timelineAutoSeekRate = 0
    }

    private func handlePanChanged(_ deltaX: CGFloat) {
        guard isTimelineScrubbing, viewModel.duration > 0,
              let translation = panTracker.translation(for: deltaX)
        else { return }
        let base = displayTime
        let seconds = TVTimelineScrubMath.panSeconds(forTranslation: translation, duration: viewModel.duration)
        movePreview(from: base, to: TVTimelineScrubMath.clampedTime(base + seconds, duration: viewModel.duration))
    }

    private func stepTimeline(by delta: Double) {
        let base = displayTime
        movePreview(from: base, to: TVTimelineScrubMath.clampedTime(base + delta, duration: viewModel.duration))
    }

    private func movePreview(from base: Double, to target: Double) {
        if target != base {
            hasTimelineSelectionMoved = true
        }
        viewModel.updateScrub(fraction: target / viewModel.duration)
    }
}
#endif
