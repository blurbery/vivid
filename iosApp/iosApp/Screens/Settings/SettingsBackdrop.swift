import SwiftUI

/// Settings inherits the persistent app canvas on tvOS. Other platforms
/// retain their existing page backgrounds.
struct SettingsBackdrop: View {
    var body: some View {
        #if os(tvOS)
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        #elseif os(iOS)
        Color.black.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        #else
        ZStack {
            Color.vividBackground

            RadialGradient(
                colors: [
                    Color.vividAccent.opacity(0.14),
                    Color(hex: "#162235").opacity(0.07),
                    .clear,
                ],
                center: UnitPoint(x: 0.82, y: 0.04),
                startRadius: 0,
                endRadius: 620
            )

            RadialGradient(
                colors: [
                    Color.vividBrandOrange.opacity(0.045),
                    .clear,
                ],
                center: UnitPoint(x: 0.08, y: 0.72),
                startRadius: 0,
                endRadius: 440
            )

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.4)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #endif
    }
}

#if os(tvOS)
/// One static canvas behind the app's changing navigation content. Full-screen
/// presentations reuse it because they are hosted outside the app container.
struct TVAppBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: "#283840"), Color(hex: "#283239"), Color(hex: "#303238")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
