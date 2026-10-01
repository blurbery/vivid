import SwiftUI

/// App-wide default `ButtonStyle` that suppresses the tvOS system focus
/// treatment (the large white "slab" halo SwiftUI paints around focused
/// buttons). Applied at the window root so every `Button` that does not
/// explicitly set its own style renders as just its label, with a quiet
/// press-scale tick — no stray focus chrome leaking in.
///
/// Individual components that need their own focus visuals should opt in
/// with a locally-scoped `ButtonStyle` (e.g. `TVPillButtonStyle`, or the
/// invisible focus host behind `TVCircleActionButton`) — never with
/// `.buttonStyle(.plain)` on tvOS,
/// which still triggers the system highlight on `Button` bounds.
struct VividFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: VividTheme.fastDuration), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == VividFlatButtonStyle {
    /// App-wide flat style that does not add any platform focus chrome.
    static var vividFlat: VividFlatButtonStyle { .init() }
}

