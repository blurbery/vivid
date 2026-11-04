#if os(iOS)
import SwiftUI

// The shared pieces of the iPhone and iPad player chrome: the glass button
// styles, the visibility rule for the close and rotation buttons, and the
// rotation buttons themselves.

private struct MobilePlayerControlPressKey: EnvironmentKey {
    static let defaultValue: (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Told when a player button is pressed and released, so the controls
    /// don't hide under a finger that's still down.
    var mobilePlayerControlPressChanged: (Bool) -> Void {
        get { self[MobilePlayerControlPressKey.self] }
        set { self[MobilePlayerControlPressKey.self] = newValue }
    }
}

/// Matches the detail page's chrome without the extra padding of the system
/// glass button styles. A 44-point square label is a circle; a longer label
/// makes a 44-point pill.
struct MobilePlayerGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    @Environment(\.mobilePlayerControlPressChanged) private var controlPressChanged

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: VividTheme.topBarIconHitSize)
            .frame(height: VividTheme.topBarIconHitSize)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .vividPlayerGlass(in: Capsule(), tint: tint, interactive: true)
            .onChange(of: configuration.isPressed) { _, pressed in controlPressChanged(pressed) }
            .onDisappear { if configuration.isPressed { controlPressChanged(false) } }
    }
}

/// A large rounded tile for the half-folded deck, in the same glass as the
/// round player buttons.
struct MobilePlayerTileButtonStyle: ButtonStyle {
    static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    var tint: Color? = nil
    @Environment(\.mobilePlayerControlPressChanged) private var controlPressChanged
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = Self.shape
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(shape)
            .vividPlayerGlass(in: shape, tint: tint, interactive: true)
            .onChange(of: configuration.isPressed) { _, pressed in controlPressChanged(pressed) }
            .onDisappear { if configuration.isPressed { controlPressChanged(false) } }
    }
}

extension View {
    /// A round glass button above the video, or a rounded square in the deck.
    @ViewBuilder
    func mobilePlayerSelectorStyle(asTile: Bool) -> some View {
        if asTile {
            buttonStyle(MobilePlayerTileButtonStyle())
        } else {
            buttonStyle(MobilePlayerGlassButtonStyle())
        }
    }
}

/// The close and rotation buttons share one visibility, hit-testing and
/// accessibility state, including while loading and on Next Up.
struct MobilePlayerChromeVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            // The transport, PiP, Rotate and Lock buttons must appear in the
            // same frame. An implicit animation here made the separate
            // top-right overlay visibly trail the main controls after a tap.
            .transaction { transaction in transaction.animation = nil }
    }
}

/// Rotate and Lock, top right. They follow the controls' visibility in
/// every playback phase, and equal tap areas keep Lock in place through a
/// rotation.
struct MobilePlayerRotationControls: View {
    static let height = VividTheme.topBarIconHitSize
    static let width = height * 2 + 8
    static let topClearance: CGFloat = height + 32

    let orientationCoordinator: PlayerOrientationCoordinator
    let isVisible: Bool
    var onInteraction: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button {
                orientationCoordinator.togglePlayerOrientation()
                onInteraction()
            } label: {
                icon("rectangle.landscape.rotate")
            }
            .accessibilityLabel(orientationCoordinator.nextPlayerOrientation.rotateAccessibilityLabel)
            .accessibilityHint("Rotates the screen without interrupting playback")
            .accessibilityIdentifier("player.rotate")

            Button {
                orientationCoordinator.toggleRotationLock()
                onInteraction()
            } label: {
                icon(orientationCoordinator.isRotationLocked ? "lock" : "lock.open")
            }
            .accessibilityLabel(orientationCoordinator.isRotationLocked ? "Unlock screen rotation" : "Lock screen rotation")
            .accessibilityValue(orientationCoordinator.isRotationLocked ? "Locked" : "Unlocked")
            .accessibilityHint(orientationCoordinator.isRotationLocked
                ? "Allows video to follow phone orientation"
                : "Stops phone movement rotating video. The rotate button still works")
            .accessibilityIdentifier("player.rotation-lock")
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
        .modifier(MobilePlayerChromeVisibility(isVisible: isVisible))
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .frame(width: VividTheme.topBarIconHitSize, height: VividTheme.topBarIconHitSize)
            .contentShape(Rectangle())
    }
}
#endif
