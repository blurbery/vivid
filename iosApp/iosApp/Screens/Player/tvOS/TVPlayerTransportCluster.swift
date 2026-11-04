#if os(tvOS)
import SwiftUI

/// The round Subtitles and Options shortcuts above the timeline, in one
/// native horizontal focus section. Each opens the HUD without touching the
/// playback session.
struct TVPlayerTransportCluster: View {
    let viewModel: PlayerViewModel
    let onOpenHUD: () -> Void
    let onOpenSubtitles: () -> Void
    let onMoveToScrubber: () -> Void
    /// False while the scrubber owns focus or a timeline selection runs. It
    /// takes both buttons out of the focus graph, so a move towards them from
    /// the timeline finds no target and focus stays on the scrubber.
    var allowsFocus: Bool = true

    @FocusState.Binding var focusedButton: FocusTarget?

    enum FocusTarget: Hashable {
        case subtitles, options
    }

    var body: some View {
        HStack(spacing: 14) {
            subtitlesButton
            optionsButton
        }
        .focusSection()
        .onMoveCommand { direction in
            if direction == .down {
                onMoveToScrubber()
            }
        }
    }

    private var subtitlesButton: some View {
        shortcutButton(.subtitles, action: onOpenSubtitles) { isFocused in
            Image("PlayerSubtitlesIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(isFocused ? .black : .white)
        }
        .accessibilityLabel("Subtitles")
        .accessibilityValue(selectedSubtitleLabel)
    }

    private var optionsButton: some View {
        shortcutButton(.options, action: onOpenHUD) { isFocused in
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isFocused ? .black : .white)
        }
        .accessibilityLabel("Info and playback options")
    }

    private var selectedSubtitleLabel: String {
        viewModel.subtitleTracks.first(where: { $0.trackId == viewModel.selectedSubtitleId })?.primaryLabel
            ?? String(localized: "Off")
    }

    /// A 52-point circle that turns white with a black icon when focused.
    /// It draws its own focus look, so the system focus effect is off.
    private func shortcutButton<Icon: View>(
        _ target: FocusTarget,
        action: @escaping () -> Void,
        @ViewBuilder icon: (Bool) -> Icon
    ) -> some View {
        let isFocused = focusedButton == target
        return Button(action: action) {
            icon(isFocused)
                .frame(width: 52, height: 52)
                .background(isFocused ? Color.white : Color.white.opacity(0.10), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.3), lineWidth: 1)
                }
        }
        .buttonStyle(TVPlayerShortcutButtonStyle())
        .disabled(!allowsFocus)
        .focused($focusedButton, equals: target)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct TVPlayerShortcutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .focusEffectDisabled()
    }
}
#endif
