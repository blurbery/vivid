import SwiftUI

extension EnvironmentValues {
    /// Where cards register as zoom sources for the item detail cover. Nil
    /// opens details without a zoom.
    @Entry var zoomNamespace: Namespace.ID? = nil
}

#if os(iOS)
/// Presents an item's detail as a full-screen cover that zooms out of the
/// card that opened it, with its own navigation stack and player.
struct ItemDetailPresentationModifier: ViewModifier {
    @Bindable var router: AppRouter
    let zoomNamespace: Namespace.ID

    init(router: AppRouter, zoomNamespace: Namespace.ID) {
        self.router = router
        self.zoomNamespace = zoomNamespace
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $router.presentedItemDetail, onDismiss: router.itemDetailPresentationDidDismiss) { presentation in
                ItemDetailCoverContent(router: router, presentation: presentation)
                    // With no source card, as for a deep link, the zoom
                    // starts from the centre.
                    .navigationTransition(.zoom(
                        sourceID: presentation.zoomSourceID ?? presentation.id.uuidString,
                        in: zoomNamespace
                    ))
            }
    }
}

private struct ItemDetailCoverContent: View {
    @Bindable var router: AppRouter
    let presentation: AppRouter.ItemDetailPresentation

    /// The full screen size, kept for pages pushed inside the cover.
    @State private var viewportSize: CGSize = .zero

    private var currentContentId: String {
        router.presentedItemDetail?.contentId ?? presentation.contentId
    }

    var body: some View {
        NavigationStack(path: $router.itemDetailPath) {
            GeometryReader { geometry in
                let insets = geometry.safeAreaInsets
                let screenSize = CGSize(
                    width: geometry.size.width + insets.leading + insets.trailing,
                    height: geometry.size.height + insets.top + insets.bottom
                )
                let contentId = currentContentId
                let resumeContext = presentation.resumeContext?.seriesContentId == contentId
                    ? presentation.resumeContext : nil
                ItemDetailView(contentId: contentId, onClose: router.dismissItemDetail, resumeContext: resumeContext)
                    .frame(width: geometry.size.width, height: geometry.size.height + insets.bottom)
                    .id(contentId)
                    .environment(\.detailViewportSize, screenSize)
                    .onChange(of: screenSize, initial: true) { _, size in
                        viewportSize = size
                    }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                pushedPage(for: route)
                    .environment(\.detailPullBackAction, {
                        withAnimation { router.goBackInItemDetail() }
                    })
                    .environment(\.detailViewportSize, viewportSize)
            }
        }
        // Artwork paints to the bottom edge; the top keeps room for Close and Back.
        .ignoresSafeArea(.container, edges: .bottom)
        .interactiveDismissDisabled(!router.itemDetailPath.isEmpty)
        .modifier(PlayerPresentationModifier(router: router, detailPresentationID: presentation.id))
        .environment(router)
    }

    @ViewBuilder
    private func pushedPage(for route: Route) -> some View {
        switch route {
        case .itemDetail(let contentId, _):
            ItemDetailView(contentId: contentId)
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        default:
            EmptyView()
        }
    }
}
#endif
