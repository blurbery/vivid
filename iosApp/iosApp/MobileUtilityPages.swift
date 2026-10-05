import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
struct MobileSearchPage: View {
    @State private var searchRouter = AppRouter()
    @Namespace private var zoomNamespace
    @State private var blurRequest = 0
    @State private var isDismissing = false

    let safeAreaInsets: EdgeInsets
    let onDismiss: () -> Void

    var body: some View {
        MobileUtilityPage(safeAreaInsets: safeAreaInsets, onDismiss: dismissPage) {
            NavigationStack(path: $searchRouter.path) {
                SearchView(blurRequest: blurRequest)
                    .toolbar {
                        MobileUtilityCloseToolbar(accessibilityLabel: "Close search", action: dismissPage)
                    }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .requestDetail(let type, let id): RequestDetailView(mediaType: type, tmdbId: id)
                        default: EmptyView()
                        }
                    }
            }
            .environment(\.zoomNamespace, zoomNamespace)
            .modifier(ItemDetailPresentationModifier(router: searchRouter, zoomNamespace: zoomNamespace))
            .modifier(PlayerPresentationModifier(router: searchRouter))
            .environment(searchRouter)
        }
    }

    private func dismissPage() {
        guard !isDismissing else { return }
        isDismissing = true
        blurRequest &+= 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        onDismiss()
    }
}

struct MobileSettingsPage: View {
    let router: AppRouter
    let safeAreaInsets: EdgeInsets
    let onDismiss: () -> Void

    @State private var isOverviewVisible = false

    var body: some View {
        MobileUtilityPage(safeAreaInsets: safeAreaInsets, allowsPullToDismiss: isOverviewVisible, onDismiss: onDismiss) {
            NavigationStack {
                SettingsView()
                    .onAppear { isOverviewVisible = true }
                    .onDisappear { isOverviewVisible = false }
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .toolbar {
                        MobileUtilityCloseToolbar(accessibilityLabel: "Close settings", action: onDismiss)
                    }
            }
            .modifier(MobileTopScrollEdgeModifier())
            .toolbarBackground(.hidden, for: .navigationBar)
            .environment(router)
        }
    }
}

private struct MobileUtilityPage<Content: View>: View {
    @State private var dragOffset: CGFloat = 0

    private let safeAreaInsets: EdgeInsets
    private let allowsPullToDismiss: Bool
    private let onDismiss: () -> Void
    private let content: Content

    init(safeAreaInsets: EdgeInsets, allowsPullToDismiss: Bool = true, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.allowsPullToDismiss = allowsPullToDismiss
        self.safeAreaInsets = safeAreaInsets
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        content
            .safeAreaPadding(safeAreaInsets)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .ignoresSafeArea(.container)
            .compositingGroup()
            .offset(y: dragOffset)
            .simultaneousGesture(dismissGesture, including: allowsPullToDismiss ? .all : .subviews)
            .onChange(of: allowsPullToDismiss) { _, _ in dragOffset = 0 }
            .preferredColorScheme(.dark)
            .progressViewStyle(VividLoadingProgressStyle())
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard allowsPullToDismiss, value.startLocation.y <= 120,
                      value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let isDownwardPull = value.startLocation.y <= 120
                    && value.translation.height > abs(value.translation.width)
                let shouldDismiss = allowsPullToDismiss && isDownwardPull
                    && (value.translation.height >= 110
                        || (value.translation.height >= 60 && value.predictedEndTranslation.height >= 220))

                if shouldDismiss {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.24)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private struct MobileUtilityCloseToolbar: ToolbarContent {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            closeItem.sharedBackgroundVisibility(.hidden)
        } else {
            closeItem
        }
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            MobileUtilityCloseButton(accessibilityLabel: accessibilityLabel, action: action)
        }
    }
}

private struct MobileUtilityCloseButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .vividGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
#endif
