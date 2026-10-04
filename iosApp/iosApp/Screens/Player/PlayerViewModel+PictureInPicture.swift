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
    #if os(iOS)
    func playerPresentationDidAppear() {
        isPlayerPresentationVisible = true
        // Only reached once SwiftUI really mounted the cover — for a restore,
        // via `PlayerPresentationRestoration.consumeAdoption`. That is the
        // first moment AVKit's restore can honestly be reported successful.
        resolvePendingPictureInPictureRestore(true)
    }

    /// SwiftUI can remove the full-screen player while AVKit is moving the
    /// same Vivid graph into PiP. Defer final teardown only for that exact,
    /// owner-scoped engagement; every ordinary dismissal still cleans up now.
    func playerPresentationDidDisappear() {
        isPlayerPresentationVisible = false
        guard PictureInPictureCoordinator.shared.ownsEngagedSession(self) else {
            cleanup()
            return
        }
        Self.logger.info("Deferring player cleanup while Vivid PiP is engaged")
    }

    func pictureInPictureEngagementDidEnd() {
        guard !isPlayerPresentationVisible else { return }
        // A restore still in flight owns the outcome: AVKit can report the
        // stop before the re-presented cover mounts, and cleaning up here
        // would tear down the very session the user asked to come back to.
        // The restore timeout is the backstop if the cover never arrives.
        guard pendingRestoreCompletion == nil else {
            Self.logger.info("Deferring player cleanup while a PiP restore is still pending")
            return
        }
        cleanup()
    }

    /// Answer AVKit's restore-user-interface request for this session.
    ///
    /// Three outcomes, and every one of them has to be truthful: AVKit tears the
    /// PiP window down regardless, so an optimistic `true` with nothing behind it
    /// leaves the engine playing to no surface with the server session still open.
    func restorePictureInPictureUserInterface(_ completion: @escaping (Bool) -> Void) {
        guard !isDisposed else {
            completion(false)
            return
        }
        // Auto-PiP from inline never removed the cover, so it is already the
        // interface AVKit is asking for.
        if isPlayerPresentationVisible {
            completion(true)
            return
        }
        guard PlayerPresentationRestoration.reopen(self) else {
            Self.logger.error("PiP restore found no player presentation owner; ending the session")
            completion(false)
            // Nothing can come back, so the deferred teardown happens now rather
            // than waiting for a stop callback that leaves playback headless.
            cleanup()
            return
        }
        Self.logger.info("PiP restore re-presenting the full-screen player")
        // Asking the router to re-present is not the same as the cover being
        // on screen: another full-screen cover can keep SwiftUI from mounting
        // this one. Reporting success there leaves AVKit's window gone,
        // `handleDidStop` suppressed because the restore "worked", and a
        // headless playing session parked on `pendingAdoption` forever. Hold
        // AVKit's handler until `playerPresentationDidAppear` confirms the
        // adoption, or until the timeout ends the session.
        resolvePendingPictureInPictureRestore(false)
        pendingRestoreCompletion = completion
        pendingRestoreTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pictureInPictureRestoreTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.abandonPictureInPictureRestore()
        }
    }

    /// Answer AVKit's held restore handler at most once and stop the timeout.
    func resolvePendingPictureInPictureRestore(_ didRestore: Bool) {
        pendingRestoreTimeoutTask?.cancel()
        pendingRestoreTimeoutTask = nil
        guard let completion = pendingRestoreCompletion else { return }
        pendingRestoreCompletion = nil
        completion(didRestore)
    }

    /// The re-presented cover never mounted. AVKit has taken the PiP window
    /// down regardless, so the session ends here — final progress and the
    /// server session stop — rather than playing on with no surface.
    private func abandonPictureInPictureRestore() {
        guard pendingRestoreCompletion != nil else { return }
        Self.logger.error("PiP restore never mounted the player; ending the session")
        PlayerPresentationRestoration.discardAdoption(for: self)
        resolvePendingPictureInPictureRestore(false)
        cleanup()
    }

    /// A Picture in Picture start that never happened is invisible to the user —
    /// AVKit reports both cases to the delegate only, so the tapped button just
    /// looks inert. Surface it on the same transient notice the player already
    /// uses for replan rejections.
    func reportPictureInPictureStartFailure(
        _ failure: PictureInPictureCoordinator.StartFailure
    ) {
        guard !isDisposed else { return }
        switch failure {
        case .notReady:
            showNotice(
                title: "Picture in Picture not ready",
                message: "This video isn't ready for Picture in Picture yet. Try again in a moment.",
                tone: .warning,
                duration: 4
            )
        case .failed:
            showNotice(
                title: "Picture in Picture failed",
                message: "iOS couldn't start Picture in Picture for this video.",
                tone: .warning,
                duration: 5
            )
        }
    }
    #endif
}
