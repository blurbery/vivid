#if !os(tvOS)
import SwiftUI

extension View {
    /// The download screens' card surface: the same light glass as the
    /// storage summary, so cards sit on whichever page theme is chosen
    /// instead of a fixed dark fill.
    func downloadGlassCard(cornerRadius: CGFloat, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color.clear.vividGlass(in: shape, tint: Color.white.opacity(highlighted ? 0.06 : 0.025)))
            .overlay(shape.stroke(Color.vividOnSurface.opacity(0.10), lineWidth: 1))
    }

    /// A download menu's main action: white label on the Play button's glass.
    /// Disabled actions keep the glass and dim instead.
    func downloadMenuActionSurface(cornerRadius: CGFloat, isEnabled: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .foregroundColor(.white)
            .vividPrimaryGlass(in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
#endif
