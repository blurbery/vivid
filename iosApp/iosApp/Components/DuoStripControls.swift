#if os(iOS)
import SwiftUI
import UIKit

/// An X or back button on the iPhone Duo, under the connectivity icon and
/// centred on the same line as the status icons: in the side strip on the
/// cover and in landscape, in the top corner in portrait. It fills the window
/// and measures from its edge, so it lands in the same place whether or not
/// the page it sits on ignores the safe area.
struct DuoStripButton: View {
    let corner: PhoneDuo.ControlCorner
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        let fromEdge = PhoneDuo.ControlCorner.centreFromEdge
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: systemName == "chevron.left" ? 17 : 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .vividGlass(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .frame(width: 2 * fromEdge)
        .padding(.top, corner.top)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: corner.edge == .trailing ? .topTrailing : .topLeading
        )
        .ignoresSafeArea()
    }
}

extension View {
    /// Moves a pushed page's back button under the iPhone Duo's status
    /// icons. Does nothing on a stack's first page or off the Duo.
    func duoStripBackButton() -> some View {
        modifier(DuoStripBackButtonModifier())
    }
}

private struct DuoStripBackButtonModifier: ViewModifier {
    @Environment(\.duoControlCorner) private var corner
    @Environment(\.duoStripBackHidden) private var backHidden
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        let active = corner != nil && isPresented && !backHidden
        // Modifiers rather than branches, so a fold keeps the page's state.
        content
            .navigationBarBackButtonHidden(active || backHidden)
            .background {
                if active { DuoSwipeBackEnabler().frame(width: 0, height: 0) }
            }
            .overlay {
                if active, let corner {
                    DuoStripButton(corner: corner, systemName: "chevron.left", accessibilityLabel: "Back") {
                        dismiss()
                    }
                }
            }
    }
}

/// Hiding a page's back button also turns off the edge swipe back. Keep the
/// swipe for pages whose back button moved into the Duo's strip.
private struct DuoSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var previousDelegate: UIGestureRecognizerDelegate?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let swipe = navigationController?.interactivePopGestureRecognizer else { return }
            if swipe.delegate !== self {
                previousDelegate = swipe.delegate
                swipe.delegate = self
            }
            swipe.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard let swipe = navigationController?.interactivePopGestureRecognizer,
                  swipe.delegate === self else { return }
            swipe.delegate = previousDelegate
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
#endif
