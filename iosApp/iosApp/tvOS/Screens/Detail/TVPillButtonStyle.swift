#if os(tvOS)
import SwiftUI

/// The capsule button of the Apple TV detail actions, also used by the
/// player's next-up screen. It draws its own fill, focus colours, scale and
/// shadow in place of the system focus effect, at a fixed 76-point height.
struct TVPillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    enum FocusTreatment {
        case hero
        case compact
    }

    let kind: Kind
    let focusTreatment: FocusTreatment
    let collapsesWhenUnfocused: Bool
    let stabilizesFocusMotion: Bool
    let fixedWidth: CGFloat?

    init(
        kind: Kind,
        focusTreatment: FocusTreatment = .hero,
        collapsesWhenUnfocused: Bool = false,
        stabilizesFocusMotion: Bool = false,
        fixedWidth: CGFloat? = nil
    ) {
        self.kind = kind
        self.focusTreatment = focusTreatment
        self.collapsesWhenUnfocused = collapsesWhenUnfocused
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.fixedWidth = fixedWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        TVPillButtonBody(configuration: configuration, style: self)
    }

    fileprivate func horizontalPadding(focused: Bool) -> CGFloat {
        switch kind {
        case .primary:
            if stabilizesFocusMotion { return 16 }
            return focused ? 70 : 20
        case .secondary:
            if stabilizesFocusMotion { return 20 }
            return collapsesWhenUnfocused && !focused ? 20 : 40
        }
    }

    fileprivate func fill(focused: Bool) -> Color {
        if focused { return .white }
        switch kind {
        case .primary: return .white.opacity(0.10)
        case .secondary: return .black.opacity(0.52)
        }
    }

    fileprivate func scale(focused: Bool, pressed: Bool) -> CGFloat {
        var scale: CGFloat = 1
        if focused, !stabilizesFocusMotion {
            switch (focusTreatment, kind) {
            case (.compact, _): scale = 1.025
            case (.hero, .primary): scale = 1.085
            case (.hero, .secondary): scale = 1.06
            }
        }
        return pressed ? scale * 0.98 : scale
    }

    fileprivate func shadow(focused: Bool) -> (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch (focusTreatment, kind) {
        case (.compact, _):
            return focused ? (0.24, 10, 4) : (0.14, 4, 2)
        case (.hero, .primary):
            return focused ? (0.42, 24, 10) : (0.20, 6, 2)
        case (.hero, .secondary):
            return focused ? (0.36, 20, 10) : (0.18, 4, 2)
        }
    }
}

private struct TVPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: TVPillButtonStyle

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shadow = style.shadow(focused: isFocused)
        configuration.label
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .padding(.horizontal, style.horizontalPadding(focused: isFocused))
            .frame(width: style.fixedWidth, height: 76)
            .background(Capsule().fill(style.fill(focused: isFocused)))
            .contentShape(Capsule())
            .scaleEffect(style.scale(focused: isFocused, pressed: configuration.isPressed))
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
            .focusEffectDisabled()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}
#endif
