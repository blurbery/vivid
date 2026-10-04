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

extension PlayerViewModel {
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

    /// Enter continuous seek mode. The rate starts at ±1× (sign from
    /// `forward`) and auto-ramps 1 → 2 → 4 → 8 over the next ~4 s unless
    /// the user manually adjusts it with Left/Right, in which case the
    /// ramp yields to manual control. The session persists after the
    /// arrow is released — exit via Select (commit) or Menu (cancel).
    ///
    /// Does *not* call `scheduleHideControls()`: the tvOS focus sink
    /// needs to stay in the focus hierarchy so subsequent D-pad / Select
    /// / Menu presses route through us rather than the scrubber or the
    /// transport buttons.
    func beginHoldSeek(forward: Bool) {
        guard !hasReachedEndOfFile else { return }
        if isHoldSeeking { return } // already in a session
        Self.logger.info(
            "[CMP-SEEK] hold seek begin direction=\(forward ? "forward" : "backward", privacy: .public) current=\(self.currentTime, privacy: .public)"
        )

        // A pending tap-skip debounce would commit behind our back; kill it.
        skipDebounceTask?.cancel()
        skipDebounceTask = nil

        holdSeekRate = forward ? 1 : -1
        // Seek preview always starts from the live playhead (ignore any
        // stale `scrubPreviewTime` left by a prior tap-skip preview that
        // didn't land).
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

    /// Step the seek rate along the signed ladder. Positive `delta` moves
    /// toward +8× (faster / more forward), negative toward -8×. Cancels
    /// the auto-ramp — once the user touches Left/Right they're driving.
    func adjustHoldSeekRate(delta: Int) {
        guard isHoldSeeking else { return }
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = nil
        guard let currentIdx = Self.seekRates.firstIndex(of: holdSeekRate) else { return }
        let newIdx = max(0, min(Self.seekRates.count - 1, currentIdx + delta))
        holdSeekRate = Self.seekRates[newIdx]
    }

    /// Commit the current seek preview and exit seek mode. Schedules the
    /// overlay auto-hide so the user briefly sees the landed position on
    /// the scrubber before it fades.
    func commitHoldSeek() {
        guard isHoldSeeking else { return }
        Self.logger.info(
            "[CMP-SEEK] hold seek commit target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
        )
        tearDownHoldSeek()
        commitSeek(to: scrubPreviewTime, source: "holdSeek")
        scheduleHideControls()
    }

    /// Abandon the seek session without moving the playhead. Used by
    /// Menu / Exit so a curious user can back out without committing.
    func cancelHoldSeek() {
        guard isHoldSeeking else { return }
        tearDownHoldSeek()
        cancelScrub()
    }

    /// Run a short auto-ramp that steps the rate magnitude 1 → 2 → 4 → 8
    /// in ~1.2 s increments. Only runs during the initial phase of a
    /// session; cancelled the instant the user manually steers.
    private func startHoldSeekAutoRamp() {
        holdSeekAutoRampTask?.cancel()
        holdSeekAutoRampTask = Task { @MainActor [weak self] in
            let magnitudes: [Int] = [2, 4, 8]
            for magnitude in magnitudes {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                let current = self.holdSeekRate
                guard current != 0 else { return }
                let sign = current > 0 ? 1 : -1
                self.holdSeekRate = magnitude * sign
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

    /// Accumulate a skip delta into `scrubPreviewTime` and schedule a
    /// trailing-edge commit. Each call cancels the prior pending commit and
    /// starts a fresh window, so rapid bursts coalesce into a single seek
    /// fired after the user stops pressing.
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

    /// Commit a seek target. Optimistically moves `currentTime` to the
    /// target and arms the origin↔target filter so stale `onTimeChange`
    /// frames from the pipeline can't overwrite it. Without this, the
    /// scrubber visibly jumps back to the pre-seek position between the
    /// `seek` call and the first post-seek report.
    ///
    /// Back-to-back seeks are safe because we capture `seekOriginTime`
    /// from the pre-commit `currentTime` (which on a repeat commit is the
    /// prior optimistic target) — the midpoint between that and the new
    /// target still correctly rejects drainage from either the current or
    /// the prior seek.
    @discardableResult
    func commitSeek(to target: Double, source: String = "unspecified") -> Bool {
        pendingUnexpectedEndEpoch = nil
        watchTimeGate.interrupt()
        let clampedTarget = duration > 0 ? min(max(0, target), duration) : max(0, target)
        let requiresReplan: Bool = {
            guard let timeline = vividPlaybackController.activeSpec?.timeline else { return true }
            if case .replan = timeline.seekDisposition(forSourceTime: clampedTarget) {
                return true
            }
            return false
        }()

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

        // Snapshotted synchronously, before the seek is even issued. A seek
        // that resolves `.requiresReplan` after a different item began
        // loading would otherwise restart that *new* item at this item's
        // position, because `lastLoadRequest` has already been replaced.
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
            switch result {
            case .completed:
                break
            case .requiresReplan(let sourceSeconds):
                if let protocolV3 = self.activePreparedProtocolV3,
                   protocolV3.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
                    // `attemptProtocolV3Replan` raises the spinner itself once
                    // it commits to a replan. Raising it here first meant an
                    // early rejection (no watch detail) left the player
                    // spinning with nothing in flight to ever clear it.
                    guard self.attemptProtocolV3Replan(
                        position: sourceSeconds,
                        classification: "seek_reanchor",
                        message: "Reanchor the active stream at the requested source position.",
                        operation: PlaybackProtocolV3.ReplanOperation.seekReanchor
                    ) else {
                        self.isLoading = false
                        self.showNotice(
                            title: "Couldn't seek",
                            message: "Playback couldn't move to that position. Try again.",
                            tone: .warning,
                            duration: 5
                        )
                        return
                    }
                } else if let request = self.lastLoadRequest {
                    self.beginFreshLoad(
                        request: request,
                        progressPosition: self.seekOriginTime,
                        resumePositionOverride: sourceSeconds,
                        allowNearEndResume: true
                    )
                }
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

    func seek(to fraction: Double) {
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        Self.logger.info(
            "[CMP-SEEK] fraction seek requested fraction=\(fraction, privacy: .public) duration=\(self.duration, privacy: .public)"
        )
        commitSeek(to: fraction * duration, source: "fraction")
        scheduleHideControls()
    }

    /// Seek to a specific timestamp. Used by the chapter sheet and the tvOS
    /// progress-bar scrubber.
    func seekTo(seconds: Double, revealingControls: Bool = true) {
        guard !hasReachedEndOfFile else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        Self.logger.info(
            "[CMP-SEEK] absolute seek requested seconds=\(seconds, privacy: .public)"
        )
        commitSeek(to: max(0, seconds), source: "absolute")
        if revealingControls || showControls {
            scheduleHideControls()
        }
    }

    func beginScrub(fraction: Double) {
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = true
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.begin(atSourceTime: scrubPreviewTime)
        hideControlsTask?.cancel()
    }

    func updateScrub(fraction: Double) {
        guard !hasReachedEndOfFile else { return }
        guard duration > 0 else { return }
        scrubPreviewTime = max(0, min(fraction, 1)) * duration
        scrubPreviewProvider.request(atSourceTime: scrubPreviewTime)
    }

    func endScrub(resumePlayback: Bool = false, shouldSeek: Bool = true) {
        guard !hasReachedEndOfFile else { return }
        guard isScrubbing else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        let reloadsPlaybackPipeline: Bool
        if shouldSeek {
            Self.logger.info(
                "[CMP-SEEK] scrub ended target=\(self.scrubPreviewTime, privacy: .public) current=\(self.currentTime, privacy: .public)"
            )
            reloadsPlaybackPipeline = commitSeek(to: scrubPreviewTime, source: "scrub")
        } else {
            // Select entered and exited timeline mode without moving the
            // playhead. Keep the backend parked at its exact paused position
            // instead of issuing a redundant seek that can snap to a nearby
            // keyframe and briefly rebuffer.
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

    /// Abandon an in-progress scrub without seeking. Used when the user
    /// transitions focus away from the scrubber for a reason that's not a
    /// commit — most commonly, opening a sheet — so the scrub preview
    /// doesn't become an accidental seek.
    func cancelScrub() {
        guard isScrubbing else { return }
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        isScrubbing = false
        scrubPreviewTime = currentTime
        scrubPreviewProvider.endInteraction()
    }

    func seekToAdjacentChapter(forward: Bool) {
        guard !chapters.isEmpty else { return }
        let sorted = chapters.sorted { $0.time < $1.time }
        let target: PlayerChapterInfo?
        if forward {
            target = sorted.first { $0.time > currentTime + 1.0 }
        } else {
            target = sorted.last { $0.time < currentTime - 1.0 }
        }
        if let target {
            seekTo(seconds: target.time)
        }
    }
}
