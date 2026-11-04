#if !os(tvOS)
import SwiftUI

extension View {
    /// The download screens' card surface: the same light glass as the
    /// storage summary, so cards sit on whichever page theme is chosen
    /// instead of a fixed dark fill. Highlighted cards take a little more
    /// tint.
    func downloadGlassCard(cornerRadius: CGFloat, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = Color.white.opacity(highlighted ? 0.06 : 0.025)
        return background(Color.clear.vividGlass(in: shape, tint: tint))
            .overlay(shape.stroke(Color.vividOnSurface.opacity(0.10), lineWidth: 1))
    }

    /// A download menu's main action: a white label on the Play button's
    /// glass. A disabled action keeps the glass and dims instead.
    func downloadMenuActionSurface(cornerRadius: CGFloat, isEnabled: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return foregroundColor(.white)
            .vividPrimaryGlass(in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
#endif
