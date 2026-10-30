import Foundation
#if os(tvOS)
import AVKit
#endif

#if canImport(UIKit)
import UIKit
#endif

enum VividDisplayContext {
    /// A panel sitting in SDR reports a headroom of exactly 1.0. Vivid's own
    /// post-handshake check uses the same tolerance, so host and engine agree
    /// on the same panel rather than disagreeing on a float comparison.
    private static let hdrHeadroomFloor: CGFloat = 1.001

    @MainActor
    static var matchContentEnabled: Bool {
        #if os(tvOS)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let window = windowScene.windows.first(where: \.isKeyWindow)
                ?? windowScene.windows.first
            if let window, window.responds(to: #selector(getter: UIWindow.avDisplayManager)) {
                let displayManager = window.avDisplayManager
                return displayManager.isDisplayCriteriaMatchingEnabled
            }
        }
        return false
        #else
        return true
        #endif
    }

    /// Mirror of the panel's live EDR headroom, which is what
    /// `LoadOptions.panelIsInHDRMode` documents itself as
    /// (`currentEDRHeadroom > 1`, api.md).
    ///
    /// It must be sampled before `load`: Vivid runs the display-criteria
    /// handshake synchronously inside the load and falls back to this
    /// pre-load snapshot on any path that has no handshake of its own to
    /// observe. Passing the default `false` there makes an HDR panel look
    /// like an SDR one and declines the HDR10-to-Dolby Vision upgrade.
    ///
    /// Reports the display's current HDR presentation state.
    @MainActor
    static var panelIsInHDRMode: Bool {
        #if canImport(UIKit)
        guard let screen = activeWindowScene?.screen else { return false }
        return screen.currentEDRHeadroom > hdrHeadroomFloor
        #endif
    }

    #if canImport(UIKit)
    /// Headroom is a property of the display the app is actually on, so a
    /// backgrounded or unattached scene must not answer for a foreground one.
    @MainActor
    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
    #endif
}
