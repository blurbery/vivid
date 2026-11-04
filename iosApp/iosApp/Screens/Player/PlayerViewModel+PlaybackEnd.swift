import Foundation
import OSLog

/// The end of an item. An end of stream completes the item and opens Next Up
/// only when its timing confirms it; any other end is recovered as a failure
/// of the current item.
extension PlayerViewModel {
    static let prematureSourceEndMessage = "The media stream ended before playback completion could be confirmed."

    /// Hides Next Up for a failure, without changing the viewer's autoplay
    /// choice.
    func suppressNextUpForPlaybackFailure() {
        cancelNextUpCountdown()
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
    }

    /// Handles the engine's end of stream.
    ///
    /// A confirmed end (finite source timing within eight seconds of the
    /// duration, `PlayerNextUpCompletionPolicy`) runs once per load: pause on
    /// the last frame, show the controls, complete the item and start the
    /// Next Up postroll. Anything earlier never completes the item or writes
    /// watched state. It first tries reopening the same route, and otherwise
    /// takes the current item's failure path, which ends at Retry. While a
    /// load or replan owns failures, the end is held for it instead.
    func handleEndOfFile() {
        guard !hasReachedEndOfFile else { return }
        let observedPosition = currentTime
        let safeDuration = duration
        guard PlayerNextUpCompletionPolicy.isConfirmedEnd(currentTime: observedPosition, duration: safeDuration) else {
            Self.logger.warning(
                "Unexpected source end at \(observedPosition, privacy: .public)/\(safeDuration, privacy: .public); recovering current item"
            )
            #if os(iOS) || os(tvOS)
            DiagTrace.breadcrumb(
                .essential, level: .warning, category: .playback, tag: "Player",
                message: "unexpected end of stream",
                attrs: [
                    "reason": .string("premature_source_end"),
                    "position_ms": .int(PlaybackSessionBridge.diagnosticsPositionMilliseconds(observedPosition)),
                ]
            )
            #endif
            suppressNextUpForPlaybackFailure()
            if freshLoadOwnsFailureHandling || protocolV3ReplanTask != nil
                || (activePreparedProtocolV3 != nil && committedProtocolV3LoadEpoch == nil) {
                // An end doesn't throw from the load, so hold it until the
                // owning load settles rather than dropping it.
                pendingUnexpectedEndEpoch = activeVividLoadEpoch
                return
            }
            if attemptPrematureEndReload() { return }
            handleVividFailure(PlaybackErrorInfo(kind: .softwarePipelineFailed, message: Self.prematureSourceEndMessage))
            return
        }
        hasReachedEndOfFile = true

        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            level: .info,
            category: .playback,
            tag: "Player",
            message: "playback reached end of stream",
            attrs: [
                "reason": .string("natural_end"),
                "play_method": .string(activeRouteLabel),
                "position_ms": .int(PlaybackSessionBridge.diagnosticsPositionMilliseconds(observedPosition)),
            ]
        )
        #endif

        hideControlsTask?.cancel()
        hideControlsTask = nil
        vividPlaybackController.pause()
        if duration.isFinite, duration > 0 {
            currentTime = duration
        }
        isLoading = false
        isBuffering = false
        isLoadingSubtitles = false
        bufferingProgress = nil
        isPlaying = false
        setControlsVisible(true, cause: .playbackEnded)
        nowPlaying.update(
            title: title,
            duration: duration,
            position: currentTime,
            isPlaying: false,
            playbackRate: settings.playbackSpeed
        )

        updatePlaybackCompletion(at: currentTime, endedNaturally: true)
        beginNextUpPostroll(videoEnded: true)
    }

    /// Recovers an early end held while a load or replan owned failures, once
    /// that owner has settled. Dropped when another load has replaced the one
    /// it belonged to.
    func recoverPendingUnexpectedEnd() {
        guard let epoch = pendingUnexpectedEndEpoch else { return }
        guard !isDisposed, epoch == activeVividLoadEpoch else {
            pendingUnexpectedEndEpoch = nil
            return
        }
        guard !freshLoadOwnsFailureHandling, protocolV3ReplanTask == nil else { return }
        pendingUnexpectedEndEpoch = nil
        if attemptPrematureEndReload() { return }
        handlePlaybackError(Self.prematureSourceEndMessage)
    }

    /// A stream that ends early has usually lost its connection, and the
    /// engine's own reconnect is refused once the bearer it opened with has
    /// expired (it can't swap headers on a live reader). Reopen the same route
    /// at the current position with current credentials before asking the
    /// server to adapt, which can fail outright when no remux route exists.
    private func attemptPrematureEndReload() -> Bool {
        guard vividPlaybackController.activeSpec?.options.nativeRemoteHLS == false else { return false }
        #if DEBUG
        testRecorder?.record(.sameRouteReopenRequest)
        #endif
        return beginProtocolV3SameRouteReload(
            fallbackClassification: PlaybackErrorKind.softwarePipelineFailed.rawValue,
            fallbackMessage: Self.prematureSourceEndMessage,
            prematureSourceEnd: true
        )
    }
}
