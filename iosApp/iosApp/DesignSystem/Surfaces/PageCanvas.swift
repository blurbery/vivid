import SwiftUI

/// The canvas behind a page. On Apple TV the app's root already draws the
/// canvas, so pages there get a clear layer.
struct VividPageBackdrop: View {
    var body: some View {
        #if os(iOS)
        VividAppBackdrop()
        #else
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #endif
    }
}

extension View {
    /// The themed canvas behind the view on iPhone and iPad. Apple TV leaves
    /// the view as it is.
    func vividBackground() -> some View {
        #if os(iOS)
        background {
            VividAppBackdrop()
        }
        #else
        self
        #endif
    }

    /// `VividPageBackdrop` behind the view on every platform.
    func vividPageBackground() -> some View {
        background {
            VividPageBackdrop()
        }
    }
}
