#if os(iOS)
import Foundation
import OSLog

/// Puts the full-screen player back when Picture in Picture restores it.
///
/// The player is a `fullScreenCover` driven by `AppRouter.presentedPlayer`,
/// and once that cover has gone, `PictureInPictureCoordinator` is what keeps
/// the engaged `PlayerViewModel` alive. A restore has to do two things at
/// once: show the cover again, and have the `PlayerView` it mounts take over
/// that same view model. A `PlayerView` left to itself makes a new view model
/// and calls `loadAndPlay`, which would start the title again from its resume
/// point instead of carrying on the session already playing.
///
/// There's one router, one cover and one engaged player at a time, so this is
/// a main-actor namespace with static state.
@MainActor
enum PlayerPresentationRestoration {
    /// A view model waiting for the next `PlayerView` of the same title.
    private struct StagedAdoption {
        let viewModel: PlayerViewModel
        let contentId: String
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "PictureInPicture"
    )

    /// The router that owns the player cover. Held weakly: restoring must
    /// never be what keeps the app's navigation alive.
    static weak var presenter: AppRouter?

    /// The payload the current player was shown with, recorded where it's
    /// presented. `PlayerView`'s own parameters lack `returnToContentId`, so
    /// they can't rebuild it.
    private static var recordedPayload: AppRouter.PlayerPresentation?

    /// Held strongly on purpose. Between AVKit's stop and SwiftUI mounting
    /// the cover, the coordinator has already unpinned the view model and
    /// nothing else keeps it alive.
    private static var staged: StagedAdoption?

    static func recordPresentation(_ payload: AppRouter.PlayerPresentation) {
        recordedPayload = payload
    }

    /// Shows the full-screen player again for a view model AVKit is
    /// restoring. `false` means there's nowhere to show it, and the caller
    /// must end the session rather than let it play with no screen.
    static func reopen(_ viewModel: PlayerViewModel) -> Bool {
        guard let router = presenter, let payload = recordedPayload else {
            log.error("No player presentation owner available for a PiP restore")
            return false
        }
        staged = StagedAdoption(viewModel: viewModel, contentId: payload.contentId)
        // A new id makes `fullScreenCover(item:)` present again, even while
        // the router still holds the old payload.
        var presentation = payload.reopened()
        // The detail the player came from may have closed during PiP. Return
        // above whatever detail is showing now, never a sheet that's gone.
        presentation.detailPresentationID = router.presentedItemDetail?.id
        router.presentedPlayer = presentation
        return true
    }

    /// Taken by `PlayerView.onAppear`. Matching the title stops a staged view
    /// model from being handed to some other player started in the meantime.
    static func consumeAdoption(matching contentId: String) -> PlayerViewModel? {
        guard let adoption = staged, adoption.contentId == contentId else { return nil }
        staged = nil
        return adoption.viewModel
    }

    /// Drops the staged view model when it's being torn down, so a restore
    /// SwiftUI never mounted can't keep the whole playback graph alive.
    static func discardAdoption(for viewModel: PlayerViewModel) {
        guard staged?.viewModel === viewModel else { return }
        staged = nil
    }
}

extension AppRouter.PlayerPresentation {
    /// The same presentation under a new identity. The memberwise
    /// initialiser gives every value a fresh `id`, so
    /// `fullScreenCover(item:)` sees a new presentation.
    func reopened() -> Self {
        Self(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            prefersLastUsedVersion: prefersLastUsedVersion,
            returnToContentId: returnToContentId,
            offlineDownloadId: offlineDownloadId,
            detailPresentationID: detailPresentationID,
            posterURL: posterURL,
            backdropURL: backdropURL
        )
    }
}
#endif
