#if os(iOS)
import SwiftUI

/// Presents the full-screen player. It's applied at the app root and on the
/// detail sheet, and each payload names exactly one of them as its owner, so
/// closing the player never takes the detail underneath with it.
struct PlayerPresentationModifier: ViewModifier {
    @Bindable var router: AppRouter
    var detailPresentationID: UUID? = nil

    func body(content: Content) -> some View {
        // Captured when the body runs, so a dismissal from SwiftUI clears
        // exactly the payload this cover was built for, even if the router
        // has moved on since.
        let shown = router.playerPresentation(forDetailID: detailPresentationID)
        let cover = Binding<AppRouter.PlayerPresentation?>(
            get: { router.playerPresentation(forDetailID: detailPresentationID) },
            set: { newValue in
                if newValue == nil, let shownID = shown?.id {
                    router.dismissPlayerPresentation(id: shownID)
                }
            }
        )
        content.fullScreenCover(item: cover) { presentation in
            playerScreen(for: presentation)
        }
    }

    private func playerScreen(for presentation: AppRouter.PlayerPresentation) -> some View {
        PlayerView(
            contentId: presentation.contentId,
            preferredFileId: presentation.fileId,
            preferredAudioTrackIndex: presentation.audioTrackIndex,
            preferredSubtitleTrackIndex: presentation.subtitleTrackIndex,
            startFromBeginning: presentation.startFromBeginning,
            resumePositionOverride: presentation.resumePosition,
            prefersLastUsedVersion: presentation.prefersLastUsedVersion,
            offlineDownloadId: presentation.offlineDownloadId,
            posterURLHint: presentation.posterURL,
            backdropURLHint: presentation.backdropURL,
            onDismissRequested: { router.dismissPlayerPresentation(id: presentation.id) }
        )
        // The player closes with its X button only, never a pull down. This
        // applies to the player cover alone, not the detail beneath it.
        .interactiveDismissDisabled()
        .onAppear {
            #if DEBUG
            DiagTrace.breadcrumb(.essential, category: .focus, tag: "PlayButton", message: "player cover appeared")
            #endif
            PlayerPresentationRestoration.presenter = router
            PlayerPresentationRestoration.recordPresentation(presentation)
        }
    }
}
#endif
