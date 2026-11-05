#if os(iOS)
import AVKit
import SwiftUI

/// The system AirPlay button, used in the player's top strip and on the
/// half-folded deck.
///
/// Over the video the button sits inside the controls, which hide on a
/// timer. A tap on this UIKit view never reaches SwiftUI, so nothing would
/// stop that timer while the route sheet is open, and the controls would
/// take the button and its sheet away mid-choice. `onPresentingRoutes`
/// reports the sheet opening and closing, so the caller can keep the
/// controls up the way an open popover does.
struct AirPlayRoutePicker: UIViewRepresentable {
    let onPresentingRoutes: (Bool) -> Void

    func makeCoordinator() -> RouteSheetTracker {
        RouteSheetTracker(report: onPresentingRoutes)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let button = AVRoutePickerView()
        button.tintColor = .white
        button.activeTintColor = .white
        button.prioritizesVideoDevices = true
        button.accessibilityLabel = "AirPlay"
        button.accessibilityHint = String(localized: "Choose a device for video playback")
        button.delegate = context.coordinator
        return button
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        // Each new view value brings its own closure; keep the tracker on the
        // latest one.
        context.coordinator.report = onPresentingRoutes
    }

    static func dismantleUIView(_ uiView: AVRoutePickerView, coordinator: RouteSheetTracker) {
        uiView.delegate = nil
        // The sheet's "did end" never comes if the button is removed while
        // it's open, so let go of the controls here.
        coordinator.sheetClosed()
    }

    /// Reports the route sheet opening and closing once each. SwiftUI owns
    /// it and the picker's delegate reference is weak, so it holds nothing
    /// back.
    final class RouteSheetTracker: NSObject, AVRoutePickerViewDelegate {
        var report: (Bool) -> Void
        private var sheetIsOpen = false

        init(report: @escaping (Bool) -> Void) {
            self.report = report
        }

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            if sheetIsOpen { return }
            sheetIsOpen = true
            report(true)
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            sheetClosed()
        }

        func sheetClosed() {
            if !sheetIsOpen { return }
            sheetIsOpen = false
            report(false)
        }
    }
}
#endif
