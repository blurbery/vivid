import SwiftUI

/// Settings page backdrop. tvOS retains the full-page layout while letting
/// the native presentation container supply its colour.
struct SettingsBackdrop: View {
    var body: some View {
        #if os(tvOS)
        Color.clear.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
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
