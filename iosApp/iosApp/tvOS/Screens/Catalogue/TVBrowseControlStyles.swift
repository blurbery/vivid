#if os(tvOS)
import SwiftUI
import UIKit

/// The capsule behind a page's sub-tabs and its Sort, Filter and A–Z pills:
/// the top bar's dark glass, lighter when selected, and in focus the bar's
/// white outline rather than a white fill.
struct TVBrowsePillBackground: View {
    let isFocused: Bool
    var isSelected = false

    var body: some View {
        ZStack {
            Capsule().fill(Color.black.opacity(0.45))
            Capsule().fill(.ultraThinMaterial)
            if isFocused {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().strokeBorder(Color.white.opacity(0.92), lineWidth: 2.5)
            } else {
                if isSelected { Capsule().fill(Color.vividChromeSelectedFill) }
                Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.5)
            }
        }
    }
}

/// The capsule behind Sort, Filter, A–Z and similar controls. It reads focus
/// from the environment so it styles menu labels as well as buttons.
struct TVBrowseControlPillStyle: ButtonStyle {
    var active: Bool = false

    /// The sub-tabs' text size and weight, so pills beside them match.
    static let font = Font.system(size: 26, weight: .semibold)
    /// A sub-tab's height: one line of that text and 10 points either side.
    static let height = UIFont.systemFont(ofSize: 26, weight: .semibold).lineHeight.rounded(.up) + 20

    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, active: active)
    }

    private struct Pill<Content: View>: View {
        let label: Content
        let active: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .font(TVBrowseControlPillStyle.font)
                .lineLimit(1)
                .foregroundStyle(Color.vividOnSurface)
                .padding(.horizontal, 22)
                .frame(height: TVBrowseControlPillStyle.height)
                .background(TVBrowsePillBackground(isFocused: isFocused, isSelected: active))
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
            .modifier(TVTopMenuTucksOnScroll())
    }
}
#endif
