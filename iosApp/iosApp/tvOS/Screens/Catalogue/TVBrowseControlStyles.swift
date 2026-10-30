#if os(tvOS)
import SwiftUI

/// The capsule behind Sort, Filter, A–Z and similar controls. It reads focus
/// from the environment so it styles menu labels as well as buttons.
struct TVBrowseControlPillStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, active: active)
    }

    private struct Pill<Content: View>: View {
        let label: Content
        let active: Bool

        @Environment(\.isFocused) private var isFocused

        private var fill: Color {
            if isFocused { return .vividOnSurface }
            return active ? .vividChromeSelectedFill : .vividChromeRestingFill
        }

        var body: some View {
            label
                .foregroundStyle(isFocused ? Color.vividBackground : Color.vividOnSurface)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(isFocused ? Color.clear : Color.vividChromeRestingBorder, lineWidth: 1))
                .scaleEffect(isFocused ? 1.04 : 1)
                .animation(.easeOut(duration: VividTheme.fastDuration), value: isFocused)
        }
    }
}

/// Lets a personal page's scroll view fill its space without the scroll
/// edge effect.
struct TVPersonalScrollAppearance: ViewModifier {
    init() {}

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectHidden(true, for: .all)
    }
}
#endif
