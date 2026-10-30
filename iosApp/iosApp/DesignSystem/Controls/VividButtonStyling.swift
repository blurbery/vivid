import SwiftUI

/// Draws only the label, which shrinks slightly while pressed. Buttons using
/// it draw their own focus look.
struct LabelOnlyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LabelOnlyButtonStyle {
    static var vividFlat: LabelOnlyButtonStyle { LabelOnlyButtonStyle() }
}

extension View {
    /// A text button: system glass on iOS 26 and later, Vivid's own capsule
    /// on Apple TV and earlier iOS.
    @ViewBuilder
    func vividTextButton() -> some View {
        #if os(tvOS)
        buttonStyle(CapsuleTextButtonStyle())
        #else
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(CapsuleTextButtonStyle())
        }
        #endif
    }

    /// The system glass button style, or bordered before iOS 26. The caller
    /// keeps control of the border shape and tint.
    @ViewBuilder
    func vividGlassButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.glass)
        #else
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
        #endif
    }
}

/// A plain label that turns into a filled, lifted capsule when focused.
private struct CapsuleTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CapsuleTextButtonBody(configuration: configuration)
    }
}

private struct CapsuleTextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(.vividBody)
            .foregroundStyle(isFocused ? Color.vividBackground : Color.vividOnSurface)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(Color.vividOnSurface.opacity(isFocused ? 1 : 0))
            }
            .overlay {
                Capsule().stroke(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
            }
            .scaleEffect(isFocused ? 1.045 : 1)
            .shadow(color: Color.vividOnSurface.opacity(isFocused ? 0.28 : 0), radius: 14, x: 0, y: 4)
            .opacity(configuration.isPressed ? 0.6 : 1)
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}
