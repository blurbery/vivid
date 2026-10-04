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
    func suppressNextUpForPlaybackFailure() {
        // Cancel the task without changing the user's autoplay preference.
        cancelNextUpCountdown()
        showNextUpScreen = false
        nextUpScreenVideoEnded = false
    }

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

    static let prematureSourceEndMessage = "The media stream ended before playback completion could be confirmed."

    /// A stream that ends early has usually lost its connection, and the
    /// engine's own reconnect is refused once the bearer it opened with has
    /// expired (it can't swap headers on a live reader). Reopen the same route
    /// at the current position with current credentials before asking the
    /// server to adapt, which can fail outright when no remux route exists.
    private func attemptPrematureEndReload() -> Bool {
        guard vividPlaybackController.activeSpec?.options.nativeRemoteHLS == false else { return false }
        return beginProtocolV3SameRouteReload(
            fallbackClassification: PlaybackErrorKind.softwarePipelineFailed.rawValue,
            fallbackMessage: Self.prematureSourceEndMessage,
            prematureSourceEnd: true
        )
    }

    /// Validate terminal timing before completing an item or showing Next Up.
    func handleEndOfFile() {
        guard !hasReachedEndOfFile else { return }
        let observedPosition = currentTime
        let safeDuration = duration
        guard PlayerNextUpCompletionPolicy.isConfirmedEnd(
            currentTime: observedPosition, duration: safeDuration
        ) else {
            // Do not latch completion or write watched history for a truncated
            // stream. The existing recovery path retains the current item,
            // source position and track selections; failure offers Retry.
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
                // An EOF does not throw from load(). Retain it until the
                // owning load settles, instead of silently dropping it.
                pendingUnexpectedEndEpoch = activeVividLoadEpoch
                return
            }
            if attemptPrematureEndReload() { return }
            handleVividFailure(PlaybackErrorInfo(kind: .softwarePipelineFailed,
                message: Self.prematureSourceEndMessage))
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
                "position_ms": .int(
                    PlaybackSessionBridge.diagnosticsPositionMilliseconds(observedPosition)
                ),
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
        showControls = true
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
}
