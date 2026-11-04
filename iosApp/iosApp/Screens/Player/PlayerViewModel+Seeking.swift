import Foundation
import OSLog

/// Skips, scrubbing, the Apple TV hold-to-seek session and the seek commit
/// they all end in.
///
/// Every seek goes through `commitSeek`, which moves the playhead straight
/// away and holds back stale clock reports until the engine lands. A target
/// the loaded stream can't reach (outside a re-anchored Silo transport)
/// replans on the server or reloads at that position.
extension PlayerViewModel {
    // MARK: - Skips

    func skipForward(_ seconds: Double = 30, revealingControls: Bool = true) {
        guard !hasReachedEndOfFile else { return }
        Self.logger.info(
            "[CMP-SEEK] skip forward requested seconds=\(seconds, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public)"
        )
        queueSkipDebounce(delta: seconds)
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    func skipBackward(_ seconds: Double = 10, revealingControls: Bool = true) {
        guard !hasReachedEndOfFile else { return }
        Self.logger.info(
            "[CMP-SEEK] skip backward requested seconds=\(seconds, privacy: .public) current=\(self.currentTime, privacy: .public) preview=\(self.scrubPreviewTime, privacy: .public) isScrubbing=\(self.isScrubbing, privacy: .public)"
        )
        queueSkipDebounce(delta: -seconds)
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    func skipIntro() {
        PlaybackTrialTrace.controlEvent("skip_intro_action", fields: "has_range=\(activeIntroSkipRange != nil) loading=\(isLoading)")
        guard let introRange = activeIntroSkipRange else { return }
        if let key = currentIntroSkipKey(for: introRange) {
            autoSkippedIntroKey = key
        }
        cancelPendingIntroAutoSkip()
        seekTo(seconds: introRange.end, revealingControls: false)
    }

    func skipCredits() {
        PlaybackTrialTrace.controlEvent("skip_credits_action", fields: "has_range=\(creditsRange != nil) loading=\(isLoading)")
        guard let creditsRange else { return }
        if let key = currentCreditsSkipKey(for: creditsRange) {
            autoSkippedCreditsKey = key
        }
        performCreditsSkip(to: creditsRange.end)
    }

    func cancelIntroAutoSkip() {
        if let introRange = activeIntroSkipRange,
           let key = currentIntroSkipKey(for: introRange) {
            autoSkipIntroCancelledKey = key
            Self.logger.info("[CMP-MARKERS] cancelled auto-skip intro key=\(key, privacy: .public)")
        }
        cancelPendingIntroAutoSkip()
    }

    /// Adds a skip to the preview and restarts a trailing 200 ms timer, so a
    /// burst of presses becomes a single seek once they stop. Seeking on the
    /// first press and again at the end made the picture jump twice.
    private func queueSkipDebounce(delta: Double) {
        let wasScrubbing = isScrubbing
        let base = isScrubbing ? scrubPreviewTime : currentTime
        let cap = duration > 0 ? duration : base + abs(delta)
        let target = max(0, min(base + delta, cap))

        isScrubbing = true
        scrubPreviewTime = target
        if wasScrubbing {
            scrubPreviewProvider.request(atSourceTime: target)
        } else {
            scrubPreviewProvider.begin(atSourceTime: target)
        }
        Self.logger.info(
            "[CMP-SEEK] skip debounce queued delta=\(delta, privacy: .public) base=\(base, privacy: .public) target=\(target, privacy: .public) duration=\(self.duration, privacy: .public)"
        )

        skipDebounceTask?.cancel()
        skipDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.skipDebounceNanos ?? 200_000_000)
            guard !Task.isCancelled, let self else { return }
            Self.logger.info(
                "[CMP-SEEK] skip debounce commit target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            self.commitSeek(to: self.scrubPreviewTime, source: "skipDebounce")
            self.skipDebounceTask = nil
        }
    }

    /// Drops a pending skip, so it can't commit behind a newer seek.
    private func cancelSkipDebounce() {
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
    }

    // MARK: - Hold to seek (Apple TV)

    /// Enters continuous seek mode. The rate starts at 1x in the arrow's
    /// direction and ramps 2x, 4x, 8x over about four seconds unless the
    /// viewer steers it with Left and Right. The session outlasts the press:
    /// Select commits it and Menu cancels it.
    ///
    /// Doesn't schedule the auto-hide: the focus sink has to stay in place
    /// so the following presses reach the player rather than the scrubber
    /// or the transport buttons.
    func beginHoldSeek(forward: Bool) {
        guard !hasReachedEndOfFile, !isHoldSeeking else { return }
        Self.logger.info(
            "[CMP-SEEK] hold seek begin direction=\(forward ? "forward" : "backward", privacy: .public) current=\(self.currentTime, privacy: .public)"
        )
        cancelSkipDebounce()

        holdSeekRate = forward ? 1 : -1
        // Always start from the live playhead, not a skip preview that never
        // landed.
        scrubPreviewTime = currentTime
        isScrubbing = true
        scrubPreviewProvider.begin(atSourceTime: scrubPreviewTime)

        holdSeekTask?.cancel()
        holdSeekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let rate = self.holdSeekRate
                if rate == 0 { break }
                let step = Self.holdSeekBaseStep * Double(rate)
                let cap = self.duration > 0 ? self.duration : self.scrubPreviewTime + abs(step)
                self.scrubPreviewTime = max(0, min(self.scrubPreviewTime + step, cap))
                self.scrubPreviewProvider.request(atSourceTime: self.scrubPreviewTime)
                try? await Task.sleep(nanoseconds: Self.holdSeekTickNanos)
            }
        }

        startHoldSeekAutoRamp()
    }

    /// Steps the rate along `seekRates`; a positive `delta` moves forward.
    /// Stops the automatic ramp, since the viewer is now steering.
    func adjustHoldSeekRate(delta: Int) {
        guard isHoldSeeking else { return }
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        guard let index = Self.seekRates.firstIndex(of: holdSeekRate) else { return }
        holdSeekRate = Self.seekRates[max(0, min(Self.seekRates.count - 1, index + delta))]
    }

    /// Seeks to the preview and leaves seek mode. The auto-hide follows, so
    /// the landed position shows on the timeline briefly.
    func commitHoldSeek() {
        guard isHoldSeeking else { return }
        Self.logger.info(
            "[CMP-SEEK] hold seek commit target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
        )
        tearDownHoldSeek()
        commitSeek(to: scrubPreviewTime, source: "holdSeek")
        scheduleHideControls()
    }

    /// Leaves seek mode without moving the playhead.
    func cancelHoldSeek() {
        guard isHoldSeeking else { return }
        tearDownHoldSeek()
        cancelScrub()
    }

    /// Raises the rate's size to 2, 4 and then 8, 1.2 seconds apart, keeping
    /// its direction.
    private func startHoldSeekAutoRamp() {
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = Task { @MainActor [weak self] in
            for magnitude in [2, 4, 8] {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                let current = self.holdSeekRate
                guard current != 0 else { return }
                self.holdSeekRate = current > 0 ? magnitude : -magnitude
            }
        }
    }

    func tearDownHoldSeek() {
        holdSeekTask?.cancel()
        holdSeekTask = nil
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        holdSeekRate = 0
    }

    // MARK: - Commit

    /// Seeks to `target` (clamped to the item) and returns true when the
    /// loaded stream can't reach it, so a replan or reload takes over.
    ///
    /// `currentTime` moves to the target at once, and clock reports nearer
    /// the old position than the target are dropped until one crosses the
    /// midpoint, or for five seconds at most. Without that the timeline
    /// jumps back between the seek and the first report after it. Back-to-
    /// back seeks work because the origin is the previous optimistic target.
    @discardableResult
    func commitSeek(to target: Double, source: String = "unspecified") -> Bool {
        pendingUnexpectedEndEpoch = nil
        let clampedTarget = duration > 0 ? min(max(0, target), duration) : max(0, target)
        let requiresReplan: Bool
        if let timeline = vividPlaybackController.activeSpec?.timeline,
           case .local = timeline.seekDisposition(forSourceTime: clampedTarget) {
            requiresReplan = false
        } else {
            requiresReplan = true
        }

        Self.logger.info(
            "[CMP-SEEK] commit requested source=\(source, privacy: .public) target=\(clampedTarget, privacy: .public) current=\(self.currentTime, privacy: .public) route=\(self.activeRouteLabel, privacy: .public) replan=\(requiresReplan, privacy: .public)"
        )
        hasReachedEndOfFile = false
        seekOriginTime = currentTime
        seekTargetTime = clampedTarget
        currentTime = clampedTarget
        scrubPreviewTime = clampedTarget
        isScrubbing = false
        scrubPreviewProvider.endInteraction()

        // Taken now, before the seek is issued. A `.requiresReplan` answer
        // that arrives after another item started loading would otherwise
        // restart that new item at this one's position.
        let seekFreshLoadGeneration = freshLoadGeneration
        let seekLoadEpoch = vividPlaybackController.activeLoadEpoch
        seekReplanTask?.cancel()
        seekReplanTask = Task { @MainActor [weak self] in
            guard let self, !self.isDisposed else { return }
            let result = await self.vividPlaybackController.seek(toSourceTime: clampedTarget)
            guard !Task.isCancelled,
                  !self.isDisposed,
                  self.freshLoadGeneration == seekFreshLoadGeneration,
                  self.vividPlaybackController.activeLoadEpoch == seekLoadEpoch else {
                return
            }
            self.seekReplanTask = nil
            if case .requiresReplan(let sourceSeconds) = result {
                self.replanOrReloadForSeek(to: sourceSeconds)
            }
        }

        seekFilterTimeoutTask?.cancel()
        seekFilterTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.seekFilterNanos)
            guard !Task.isCancelled, let self else { return }
            self.seekOriginTime = nil
            self.seekTargetTime = nil
            self.seekFilterTimeoutTask = nil
        }
        return requiresReplan
    }

    /// A target outside the loaded stream: a Silo server that can re-anchor
    /// the stream does so, anything else reloads at that position.
    private func replanOrReloadForSeek(to sourceSeconds: Double) {
        if let protocolV3 = activePreparedProtocolV3,
           protocolV3.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            // `attemptProtocolV3Replan` raises the spinner once it commits to
            // a replan. Raising it first left the player spinning after an
            // early refusal (no watch detail), with nothing left to clear it.
            let replanStarted = attemptProtocolV3Replan(
                position: sourceSeconds,
                classification: "seek_reanchor",
                message: "Reanchor the active stream at the requested source position.",
                operation: PlaybackProtocolV3.ReplanOperation.seekReanchor
            )
            guard !replanStarted else { return }
            isLoading = false
            showNotice(
                title: String(localized: "Couldn't seek"),
                message: String(localized: "Playback couldn't move to that position. Try again."),
                tone: .warning,
                duration: 5
            )
        } else if let request = lastLoadRequest {
            beginFreshLoad(
                request: request.resumingInPlace(),
                progressPosition: seekOriginTime,
                resumePositionOverride: sourceSeconds,
                allowNearEndResume: true
            )
        }
    }

    func seek(to fraction: Double) {
        guard !hasReachedEndOfFile, duration > 0 else { return }
        cancelSkipDebounce()
        Self.logger.info(
            "[CMP-SEEK] fraction seek requested fraction=\(fraction, privacy: .public) duration=\(self.duration, privacy: .public)"
        )
        commitSeek(to: fraction * duration, source: "fraction")
        scheduleHideControls()
    }

    /// Seeks to a time in seconds: chapters, markers, the Apple TV timeline
    /// and the system's remote commands.
    func seekTo(seconds: Double, revealingControls: Bool = true) {
        guard !hasReachedEndOfFile else { return }
        cancelSkipDebounce()
        Self.logger.info(
            "[CMP-SEEK] absolute seek requested seconds=\(seconds, privacy: .public)"
        )
        commitSeek(to: max(0, seconds), source: "absolute")
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    // MARK: - Scrubbing

    func beginScrub(fraction: Double) {
        guard !hasReachedEndOfFile, duration > 0 else { return }
        cancelSkipDebounce()
        isScrubbing = true
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.begin(atSourceTime: scrubPreviewTime)
        hideControlsTask?.cancel()
    }

    func updateScrub(fraction: Double) {
        guard !hasReachedEndOfFile, duration > 0 else { return }
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.request(atSourceTime: scrubPreviewTime)
    }

    func endScrub(resumePlayback: Bool = false, shouldSeek: Bool = true) {
        guard !hasReachedEndOfFile else {
            // The item ended mid-scrub. There's nothing to seek, but the scrub
            // still ends, or it would keep the controls up and its preview
            // reader open until the next load.
            cancelScrub()
            return
        }
        guard isScrubbing else { return }
        cancelSkipDebounce()
        let reloadsPlaybackPipeline: Bool
        if shouldSeek {
            Self.logger.info(
                "[CMP-SEEK] scrub ended target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            reloadsPlaybackPipeline = commitSeek(to: scrubPreviewTime, source: "scrub")
        } else {
            // Select entered and left the timeline without moving. Leave the
            // engine paused where it is: a seek to the same place can snap to
            // a nearby keyframe and rebuffer.
            isScrubbing = false
            scrubPreviewTime = currentTime
            scrubPreviewProvider.endInteraction()
            reloadsPlaybackPipeline = false
            Self.logger.info(
                "[CMP-SEEK] scrub ended without movement; resuming without seek at current=\(self.currentTime, privacy: .public)"
            )
        }
        if resumePlayback, !reloadsPlaybackPipeline {
            vividPlaybackController.play()
        }
        scheduleHideControls()
    }

    /// Abandons a scrub without seeking, for example when a sheet opens, so
    /// the preview doesn't become an accidental seek.
    func cancelScrub() {
        guard isScrubbing else { return }
        cancelSkipDebounce()
        isScrubbing = false
        scrubPreviewTime = currentTime
        scrubPreviewProvider.endInteraction()
    }
}
