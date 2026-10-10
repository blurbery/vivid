import SwiftUI

extension View {
    /// Vivid's Liquid Glass background in `shape` on Apple 26+, with the native
    /// material fallback used by iOS 18. This is the single place glass styling
    /// is configured so call sites keep the same tint and shape conventions.
    @ViewBuilder
    func vividGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                vividGlassConfiguration(tint: tint, interactive: interactive),
                in: shape
            )
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.glassEffect(
            vividGlassConfiguration(tint: tint, interactive: interactive),
            in: shape
        )
        #endif
    }

    /// Matches the detail page Play button's surface: dark-tinted interactive
    /// glass with a light diagonal edge. Sheets and download screens use it
    /// for their main actions so they read as the same kind of button.
    func vividPrimaryGlass(in shape: some InsettableShape) -> some View {
        self
            .vividGlass(in: shape, tint: .black.opacity(0.26), interactive: true)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.65), .white.opacity(0.14), .white.opacity(0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
    }

    /// Glass for surfaces drawn over LIVE VIDEO (player HUD, controls,
    /// notices). Backdrop-sampling effects — glassEffect and the legacy
    /// materials alike — make the render server re-sample and re-blur the
    /// covered video region on every video frame, which A12-class Apple
    /// TVs pay for as a visible spike whenever the player menu is up.
    /// Low-power devices and iOS 18 (whose oldest supported phone is the
    /// A12 iPhone XS) draw a non-sampling translucent fill instead;
    /// everything else gets standard Vivid glass.
    @ViewBuilder
    func vividPlayerGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.vividGlass(in: shape, tint: tint, interactive: interactive)
        } else {
            // Avoid per-frame backdrop sampling over video on A12-era phones.
            self.background(shape.fill(Color(white: 0.10).opacity(0.88)))
        }
        #else
        if DevicePower.isLowPowerAppleTV {
            self.background(shape.fill(Color(white: 0.10).opacity(0.88)))
        } else {
            self.vividGlass(in: shape, tint: tint, interactive: interactive)
        }
        #endif
    }
}

@available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
private func vividGlassConfiguration(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
