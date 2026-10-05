import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
/// The full-screen detail owns its nested navigation. iPhone uses the system's
/// continuously interactive zoom so a pull can shrink, move, cancel or return
/// to the tapped card while the browse page retains its position.
struct ItemDetailPresentationModifier: ViewModifier {
    @Bindable var router: AppRouter
    let zoomNamespace: Namespace.ID

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $router.presentedItemDetail,
                                onDismiss: { router.itemDetailPresentationDidDismiss() }) { presentation in
            if UIDevice.current.userInterfaceIdiom == .phone {
                ItemDetailSheet(presentation: presentation, router: router)
                    // Keep zoom on the cover, not a pushed destination. The
                    // source remains mounted, including across player returns.
                    // A source-less deep link uses the system's centred zoom.
                    .navigationTransition(.zoom(
                        sourceID: presentation.zoomSourceID ?? presentation.id.uuidString,
                        in: zoomNamespace
                    ))
            } else {
                ItemDetailSheet(presentation: presentation, router: router)
            }
        }
    }
}

private struct ItemDetailSheet: View {
    let presentation: AppRouter.ItemDetailPresentation
    @Bindable var router: AppRouter

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone {
                detailNavigation
            } else {
                detailNavigation
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationContentInteraction(.resizes)
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(28)
                    .presentationBackground(.ultraThickMaterial)
            }
        }
        // Actor and episode pages retain Back within this presentation.
        .interactiveDismissDisabled(!router.itemDetailPath.isEmpty)
        .modifier(PlayerPresentationModifier(router: router, detailPresentationID: presentation.id))
        .environment(router)
    }

    private var detailNavigation: some View {
        NavigationStack(path: $router.itemDetailPath) {
            GeometryReader { geometry in
                let pageHeight = geometry.size.height + geometry.safeAreaInsets.bottom

                if browseSource == nil {
                    // Keep the vertical scroll view directly in the cover so
                    // the native zoom gesture can coordinate with scrolling.
                    detailPage(contentID: currentContentID, width: geometry.size.width, height: pageHeight)
                } else {
                    // Keep iPad's source-aware, finger-following page deck.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(pageContentIDs, id: \.self) { contentID in
                                detailPage(contentID: contentID, width: geometry.size.width, height: pageHeight)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: pagingSelection, anchor: .center)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .frame(height: pageHeight, alignment: .top)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .task(id: currentContentID) {
                        await prefetchAdjacentDetails()
                    }
                }
            }
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                        .environment(\.detailPullBackAction, {
                            withAnimation { router.goBackInItemDetail() }
                        })
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        // Artwork paints to the screen edges. Keep the top safe area for the
        // existing X/Back chrome; each detail scroll surface extends its own
        // artwork above it. Content already owns its bottom breathing room.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var currentContentID: String {
        router.presentedItemDetail?.contentId ?? presentation.contentId
    }

    @ViewBuilder
    private func detailPage(contentID: String, width: CGFloat, height: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 28, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 28, style: .continuous
        )
        let page = ItemDetailView(
            contentId: contentID,
            onClose: router.dismissItemDetail,
            resumeContext: presentation.resumeContext?.seriesContentId == contentID ? presentation.resumeContext : nil
        )
            .frame(width: width, height: height)
            .id(contentID)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // UIKit rounds the moving card during the interactive transition.
            // Clipping here would cut off the artwork behind the status bar.
            page
        } else {
            page.clipShape(shape).contentShape(shape)
        }
    }

    /// iPhone detail cards are intentionally fixed to the title that was
    /// opened. iPad keeps its existing wider, source-aware page deck.
    private var browseSource: ItemDetailBrowseSource? {
        guard UIDevice.current.userInterfaceIdiom != .phone else { return nil }
        return router.presentedItemDetail?.browseSource ?? presentation.browseSource
    }

    private var pageContentIDs: [String] {
        browseSource?.contentIDs ?? [currentContentID]
    }

    private var pagingSelection: Binding<String?> {
        Binding(
            get: { currentContentID },
            set: { contentID in
                guard let contentID, contentID != currentContentID else { return }
                router.selectPresentedItemDetail(contentId: contentID)
            }
        )
    }

    /// Warm just the two neighbouring cards. This keeps the first sideways
    /// swipe cache-fast without launching requests for an entire long library.
    @MainActor
    private func prefetchAdjacentDetails() async {
        guard let source = browseSource,
              let currentIndex = source.contentIDs.firstIndex(of: currentContentID)
        else { return }

        let neighborIDs = [currentIndex - 1, currentIndex + 1]
            .filter(source.contentIDs.indices.contains)
            .map { source.contentIDs[$0] }

        for contentID in neighborIDs {
            guard !Task.isCancelled else { return }
            let key = CacheKey.itemDetail(contentID)
            if let _: ItemDetail = ResponseCache.shared.get(key) { continue }
            guard let detail = try? await VividAPI.shared.itemDetail(contentId: contentID),
                  !Task.isCancelled else { continue }
            ResponseCache.shared.set(detail, for: key)
        }
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
