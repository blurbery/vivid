import Foundation
import UIKit

/// What the keyframe still service may know about the player. Everything
/// here is read from state the player already publishes; nothing is
/// written, and the engine is never asked to do anything.
extension PlayerViewModel {
    var keyframeStillPlayer: KeyframeStillService.Player {
        KeyframeStillService.Player(
            state: { [weak self] in self?.keyframeStillPlayerState },
            headers: { [weak self] url in self?.keyframeStillHeaders(for: url) }
        )
    }

    /// Nil unless the load that is playing has shown its first frame.
    private var keyframeStillPlayerState: KeyframeStillService.PlayerState? {
        guard !isDisposed, let epoch = activeVividLoadEpoch, startedVividLoadEpoch == epoch,
              vividPlaybackController.activeLoadEpoch == epoch
        else { return nil }
        let engine = vividEngine
        let telemetry = engine.liveTelemetry
        var unsettled: KeyframeStillService.PlayerState.Unsettled?
        if error != nil || hasReachedEndOfFile {
            unsettled = .ended
        } else if protocolV3ReplanTask != nil {
            unsettled = .replanning
        } else if authenticationReloadGeneration != nil || staleSessionRecoveryTask != nil {
            unsettled = .recovering
        } else if isQualitySwitching {
            unsettled = .changingQuality
        } else if isScrubbing || seekTargetTime != nil || vividPlaybackController.isSeeking {
            unsettled = .seeking
        } else if isLoading {
            unsettled = .loading
        } else if isBuffering {
            unsettled = .buffering
        }
        var isHandedOff = vividPlaybackController.isAirPlayHandOffEngaged
        #if os(iOS)
        isHandedOff = isHandedOff || engine.pictureInPictureActive
        #endif
        return KeyframeStillService.PlayerState(
            sourceTime: currentTime,
            isPlaying: isPlaying,
            unsettled: unsettled,
            bufferedAheadSeconds: playbackReadAheadSeconds,
            isAppActive: UIApplication.shared.applicationState == .active,
            isHandedOff: isHandedOff,
            // The engine names the decoder it is using. Anything other than
            // VideoToolbox is decoding on the processor.
            decodesInSoftware: engine.activeVideoDecoder.map { !$0.lowercased().contains("videotoolbox") },
            droppedFrames: telemetry?.droppedFrameCount,
            avSyncGapMilliseconds: telemetry?.avSyncGapMs
        )
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
