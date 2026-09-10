#if os(tvOS)
import SwiftUI

struct TVWatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color(red: 0.16, green: 0.62, blue: 0.34), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .accessibilityLabel("Watched")
    }
}

struct TVCardFocusButtonStyle: ButtonStyle {
    var scale: CGFloat = 1.05
    var focusedShadowOpacity: Double = 0.45
    var focusedShadowRadius: CGFloat = 18
    var focusedShadowY: CGFloat = 8
    var unfocusedShadowOpacity: Double = 0.3
    var unfocusedShadowRadius: CGFloat = 8
    var unfocusedShadowY: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        TVCardFocusButtonStyleBody(
            configuration: configuration,
            focusedScale: scale,
            focusedShadowOpacity: focusedShadowOpacity,
            focusedShadowRadius: focusedShadowRadius,
            focusedShadowY: focusedShadowY,
            unfocusedShadowOpacity: unfocusedShadowOpacity,
            unfocusedShadowRadius: unfocusedShadowRadius,
            unfocusedShadowY: unfocusedShadowY
        )
    }
}

private struct TVCardFocusButtonStyleBody: View {
    let configuration: ButtonStyleConfiguration
    let focusedScale: CGFloat
    let focusedShadowOpacity: Double
    let focusedShadowRadius: CGFloat
    let focusedShadowY: CGFloat
    let unfocusedShadowOpacity: Double
    let unfocusedShadowRadius: CGFloat
    let unfocusedShadowY: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(currentScale)
            .shadow(
                color: .black.opacity(isFocused ? focusedShadowOpacity : unfocusedShadowOpacity),
                radius: isFocused ? focusedShadowRadius : unfocusedShadowRadius,
                y: isFocused ? focusedShadowY : unfocusedShadowY
            )
            .focusEffectDisabled()
            .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }

    private var currentScale: CGFloat {
        guard !reduceMotion else { return 1 }
        let base = isFocused ? focusedScale : 1
        return configuration.isPressed ? base * 0.97 : base
    }
}

extension View {
    func tvArtworkEdge(isFocused: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            TVArtworkEdge(isFocused: isFocused, cornerRadius: cornerRadius)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
    }

}
private struct TVArtworkEdge: View {
    let isFocused: Bool
    let cornerRadius: CGFloat
    @Environment(\.homeCardPresentation) private var homePresentation

    private var edge: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(isFocused ? 0.65 : 0.16),
                             .white.opacity(isFocused ? 0.28 : 0.06),
                             .white.opacity(isFocused ? 0.48 : 0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: isFocused ? 1.5 : 1
            )
    }

    @ViewBuilder var body: some View {
        if homePresentation != nil {
            // Home profiling identified CPU gradient-stroke rasterisation as a hotspot.
            // Flatten only the decorative edge, never the button or its artwork.
            edge.drawingGroup(opaque: false, colorMode: .nonLinear)
        } else {
            edge
        }
    }
}
#endif
