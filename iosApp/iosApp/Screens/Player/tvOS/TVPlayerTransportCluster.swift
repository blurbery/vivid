#if os(tvOS)
import SwiftUI

/// Info control above the scrubber. Post-redesign this is an
/// icon-only row with no container pill — the buttons float on the bottom
/// gradient, VidHub-style, so the overlay stays visually quiet. A single
/// `focusSection()` keeps D-pad left/right pinned within transport; vertical
/// presses remain inside the visible controls.
///
/// Consolidates what used to be three separate entry points (chapters,
/// tracks, settings) into one `options` button that opens `TVPlayerInfoHUD`;
/// the HUD's tab bar handles routing to the right pane.
struct TVPlayerTransportCluster: View {
    let viewModel: PlayerViewModel
    let onOpenHUD: () -> Void
    let onMoveToScrubber: () -> Void
    let onDismiss: () -> Void
    /// False while the scrubber's timeline-scrub mode is active — pulls every
    /// button out of the focus graph so a Down press/swipe on the puck finds
    /// no target and focus stays on the scrub.
    var allowsFocus: Bool = true

    @FocusState.Binding var focusedButton: FocusTarget?

    enum FocusTarget: Hashable {
        case skipBack, playPause, skipForward, nextUp, options, dismiss
    }

    var body: some View {
        HStack(spacing: 14) {
            secondaryRow
        }
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .down:
                onMoveToScrubber()
            default:
                break
            }
        }
    }

    private var secondaryRow: some View {
        let isFocused = focusedButton == .options
        return Button(action: onOpenHUD) {
            Label("Info", systemImage: "info.circle")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 126, height: 52)
                .background(isFocused ? Color.white : Color.white.opacity(0.10), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(isFocused ? 0 : 0.3), lineWidth: 1)
                }
        }
        .buttonStyle(TVPlayerInfoButtonStyle())
        .disabled(!allowsFocus)
        .focused($focusedButton, equals: .options)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .accessibilityLabel("Info and playback options")
    }
}
private struct TVPlayerInfoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .focusEffectDisabled()
    }
}
#endif
