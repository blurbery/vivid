#if os(iOS)
import AVKit
import SwiftUI

/// The AirPlay button in the player's top strip and the half-folded deck.
///
/// Above the video it lives inside the controls, which the auto-hide takes
/// down. Taps on this UIKit view never reach SwiftUI, so without
/// `onPresentingRoutes` the timer would keep running while the route sheet is
/// open and remove the button, and the sheet with it, mid-choice. The
/// callback lets the caller hold the controls up while the sheet is open, as
/// an open popover does.
struct AirPlayRoutePicker: UIViewRepresentable {
    let onPresentingRoutes: (Bool) -> Void

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .white
        picker.tintColor = .white
        picker.prioritizesVideoDevices = true
        picker.accessibilityLabel = "AirPlay"
        picker.accessibilityHint = String(localized: "Choose a device for video playback")
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // The closure belongs to the current view value. Refresh it so the
        // coordinator never calls back into a stale one.
        context.coordinator.onPresentingRoutes = onPresentingRoutes
    }

    static func dismantleUIView(_ uiView: AVRoutePickerView, coordinator: Coordinator) {
        uiView.delegate = nil
        // If the view goes while the sheet is open, "did end" never arrives,
        // so release the hold here and let the controls hide again.
        coordinator.resignPresentation()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPresentingRoutes: onPresentingRoutes)
    }

    /// `AVRoutePickerView.delegate` is weak and SwiftUI owns the coordinator,
    /// so it holds no reference back to the view.
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentingRoutes: (Bool) -> Void
        private var isPresenting = false

        init(onPresentingRoutes: @escaping (Bool) -> Void) {
            self.onPresentingRoutes = onPresentingRoutes
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            guard !isPresenting else { return }
            isPresenting = true
            onPresentingRoutes(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            resignPresentation()
        }

        func resignPresentation() {
            guard isPresenting else { return }
            isPresenting = false
            onPresentingRoutes(false)
        }
    }
}
#endif
