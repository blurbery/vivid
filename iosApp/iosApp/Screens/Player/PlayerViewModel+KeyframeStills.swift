import Foundation
import UIKit

/// What the keyframe still service may know about the player. Everything
/// here is read from state the player already publishes; nothing is
/// written, and the engine is never asked to do anything. Nothing here is
/// built or run unless the hidden switch is on: the provider only holds a
/// weak reference to the view model until then.
extension PlayerViewModel: KeyframeStillPlayerSource {
    var keyframeStillPlayer: KeyframeStillService.Player {
        KeyframeStillService.Player(
            state: { [weak self] in self?.keyframeStillPlayerState },
            headers: { [weak self] url in self?.keyframeStillHeaders(for: url) }
        )
    }

    /// Nil unless the load that is playing has shown its first frame. The
    /// values are only gathered here; what they mean to the service is
    /// worked out in `KeyframeStillService.playerState(from:)`.
    private var keyframeStillPlayerState: KeyframeStillService.PlayerState? {
        guard !isDisposed, let epoch = activeVividLoadEpoch, startedVividLoadEpoch == epoch,
              vividPlaybackController.activeLoadEpoch == epoch
        else { return nil }
        let engine = vividEngine
        let telemetry = engine.liveTelemetry
        var snapshot = KeyframeStillService.PlayerSnapshot(
            sourceTime: currentTime,
            isPlaying: isPlaying,
            hasError: error != nil,
            hasReachedEnd: hasReachedEndOfFile,
            isReplanning: protocolV3ReplanTask != nil,
            isRecovering: authenticationReloadGeneration != nil || staleSessionRecoveryTask != nil,
            isChangingQuality: isQualitySwitching,
            isSeeking: isScrubbing || seekTargetTime != nil || vividPlaybackController.isSeeking,
            isLoading: isLoading,
            isBuffering: isBuffering,
            bufferedAheadSeconds: playbackReadAheadSeconds,
            isAppActive: UIApplication.shared.applicationState == .active,
            isAirPlayHandOff: vividPlaybackController.isAirPlayHandOffEngaged,
            // The engine names the decoder it is using.
            videoDecoder: engine.activeVideoDecoder,
            droppedFrames: telemetry?.droppedFrameCount,
            avSyncGapMilliseconds: telemetry?.avSyncGapMs
        )
        // Picture in Picture is only read on iPhone and iPad, where the
        // app runs it. On Apple TV only the AirPlay hand-off counts as
        // handed off.
        #if os(iOS)
        snapshot.isPictureInPicture = engine.pictureInPictureActive
        #endif
        return KeyframeStillService.playerState(from: snapshot)
    }

    /// The headers the playing load's source takes now, which a token
    /// refresh may have changed since it opened. Read-only: the player's
    /// own refresh is never asked for from here.
    private func keyframeStillHeaders(for url: URL) -> [String: String]? {
        guard !isDisposed, let epoch = activeVividLoadEpoch, vividPlaybackController.activeLoadEpoch == epoch,
              let spec = vividPlaybackController.activeSpec, spec.sourceURL == url
        else { return nil }
        return spec.options.httpHeaders
    }
}
