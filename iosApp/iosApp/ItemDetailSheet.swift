import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
/// The full-screen detail owns its nested navigation. iPhone and iPad use the
/// system's continuously interactive zoom so a pull can shrink, move, cancel or
/// return to the tapped card while the browse page retains its position.
struct ItemDetailPresentationModifier: ViewModifier {
    @Bindable var router: AppRouter
    let zoomNamespace: Namespace.ID

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $router.presentedItemDetail,
                                onDismiss: { router.itemDetailPresentationDidDismiss() }) { presentation in
            ItemDetailSheet(presentation: presentation, router: router)
                // Keep zoom on the cover, not a pushed destination. The
                // source remains mounted, including across player returns.
                // A source-less deep link uses the system's centred zoom.
                .navigationTransition(.zoom(
                    sourceID: presentation.zoomSourceID ?? presentation.id.uuidString,
                    in: zoomNamespace
                ))
        }
    }
}

private struct ItemDetailSheet: View {
    let presentation: AppRouter.ItemDetailPresentation
    @Bindable var router: AppRouter
    /// Pushed pages read the screen size from here; the root page gets it
    /// in its first layout pass so it never opens in the wrong layout.
    @State private var viewportSize: CGSize = .zero

    var body: some View {
        detailNavigation
            // Actor and episode pages retain Back within this presentation.
            .interactiveDismissDisabled(!router.itemDetailPath.isEmpty)
            .modifier(PlayerPresentationModifier(router: router, detailPresentationID: presentation.id))
            .environment(router)
    }

    private var detailNavigation: some View {
        NavigationStack(path: $router.itemDetailPath) {
            GeometryReader { geometry in
                // Keep the vertical scroll view directly in the cover so the
                // native zoom gesture can coordinate with scrolling.
                detailPage(
                    contentID: currentContentID,
                    width: geometry.size.width,
                    height: geometry.size.height + geometry.safeAreaInsets.bottom
                )
                .environment(\.detailViewportSize, Self.screenSize(geometry))
                .onChange(of: Self.screenSize(geometry), initial: true) { _, size in
                    viewportSize = size
                }
            }
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                        .environment(\.detailPullBackAction, {
                            withAnimation { router.goBackInItemDetail() }
                        })
                        .environment(\.detailViewportSize, viewportSize)
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        // Artwork paints to the screen edges. Keep the top safe area for the
        // existing X/Back chrome; each detail scroll surface extends its own
        // artwork above it. Content already owns its bottom breathing room.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private static func screenSize(_ geometry: GeometryProxy) -> CGSize {
        let insets = geometry.safeAreaInsets
        return CGSize(
            width: geometry.size.width + insets.leading + insets.trailing,
            height: geometry.size.height + insets.top + insets.bottom
        )
    }

    private var currentContentID: String {
        router.presentedItemDetail?.contentId ?? presentation.contentId
    }

    private func detailPage(contentID: String, width: CGFloat, height: CGFloat) -> some View {
        // UIKit rounds the moving card during the interactive transition.
        // Clipping here would cut off the artwork behind the status bar.
        ItemDetailView(
            contentId: contentID,
            onClose: router.dismissItemDetail,
            resumeContext: presentation.resumeContext?.seriesContentId == contentID ? presentation.resumeContext : nil
        )
            .frame(width: width, height: height)
            .id(contentID)
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
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
