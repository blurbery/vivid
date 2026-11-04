import Foundation
import OSLog

#if os(iOS)
/// Picture in Picture on iPhone and iPad: keeping the session alive while the
/// full-screen player is gone, and answering AVKit's restore request
/// truthfully.
///
/// AVKit takes the PiP window down whatever the restore answer is, so a
/// `true` with nothing behind it would leave the engine playing to no
/// surface with the server session still open.
extension PlayerViewModel {
    func playerPresentationDidAppear() {
        isPlayerPresentationVisible = true
        // Only reached once SwiftUI has really mounted the cover (for a
        // restore, through `PlayerPresentationRestoration.consumeAdoption`).
        // That's the first moment AVKit's restore can honestly succeed.
        resolvePendingPictureInPictureRestore(true)
    }

    /// SwiftUI can remove the full-screen player while AVKit is moving the
    /// same engine into PiP. Teardown waits only for that exact engagement,
    /// owned by this view model; every ordinary dismissal cleans up now.
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
        // would end the very session the viewer asked to come back to. The
        // restore timeout is the backstop if the cover never arrives.
        guard pendingRestoreCompletion == nil else {
            Self.logger.info("Deferring player cleanup while a PiP restore is still pending")
            return
        }
        cleanup()
    }

    /// Answers AVKit's restore request for this session.
    func restorePictureInPictureUserInterface(_ completion: @escaping (Bool) -> Void) {
        guard !isDisposed else {
            completion(false)
            return
        }
        // Automatic PiP from inline never removed the cover, so it's already
        // the interface AVKit is asking for.
        if isPlayerPresentationVisible {
            completion(true)
            return
        }
        guard PlayerPresentationRestoration.reopen(self) else {
            Self.logger.error("PiP restore found no player presentation owner; ending the session")
            completion(false)
            // Nothing can come back, so tear down now rather than wait for a
            // stop callback while playback carries on with no surface.
            cleanup()
            return
        }
        Self.logger.info("PiP restore re-presenting the full-screen player")
        // Asking the router to re-present isn't the same as the cover being
        // on screen: another full-screen cover can keep SwiftUI from mounting
        // this one. Reporting success then would leave AVKit's window gone,
        // the coordinator's stop handling skipped because the restore
        // "worked", and a playing session waiting for good for a surface to
        // adopt it. AVKit's handler is held until `playerPresentationDidAppear`
        // confirms the adoption, or the timeout ends the session.
        resolvePendingPictureInPictureRestore(false)
        pendingRestoreCompletion = completion
        pendingRestoreTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pictureInPictureRestoreTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.abandonPictureInPictureRestore()
        }
    }

    /// Answers AVKit's held restore handler at most once and stops the timeout.
    func resolvePendingPictureInPictureRestore(_ didRestore: Bool) {
        pendingRestoreTimeoutTask?.cancel()
        pendingRestoreTimeoutTask = nil
        guard let completion = pendingRestoreCompletion else { return }
        pendingRestoreCompletion = nil
        completion(didRestore)
    }

    /// The re-presented cover never mounted. AVKit has taken the PiP window
    /// down anyway, so the session ends here (final progress and the server
    /// session's stop) rather than playing on with no surface.
    private func abandonPictureInPictureRestore() {
        guard pendingRestoreCompletion != nil else { return }
        Self.logger.error("PiP restore never mounted the player; ending the session")
        PlayerPresentationRestoration.discardAdoption(for: self)
        resolvePendingPictureInPictureRestore(false)
        cleanup()
    }

    /// AVKit tells only its delegate when Picture in Picture fails to start,
    /// so the button would just look broken. The failure shows as a notice,
    /// like a refused replan.
    func reportPictureInPictureStartFailure(_ failure: PictureInPictureCoordinator.StartFailure) {
        guard !isDisposed else { return }
        switch failure {
        case .notReady:
            showNotice(
                title: String(localized: "Picture in Picture not ready"),
                message: String(localized: "This video isn't ready for Picture in Picture yet. Try again in a moment."),
                tone: .warning,
                duration: 4
            )
        case .failed:
            showNotice(
                title: String(localized: "Picture in Picture failed"),
                message: String(localized: "iOS couldn't start Picture in Picture for this video."),
                tone: .warning,
                duration: 5
            )
        }
    }
}
#endif
