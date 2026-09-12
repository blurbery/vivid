#if os(tvOS)
import SwiftUI

/// Subtitle and Info shortcuts share a native horizontal focus section.
/// Each opens the existing HUD controls without changing the playback session.
struct TVPlayerTransportCluster: View {
    let viewModel: PlayerViewModel
    let onOpenHUD: () -> Void
    let onOpenSubtitles: () -> Void
    let onMoveToScrubber: () -> Void
    let onDismiss: () -> Void
    /// False while the scrubber's timeline-scrub mode is active — pulls every
    /// button out of the focus graph so a Down press/swipe on the puck finds
    /// no target and focus stays on the scrub.
    var allowsFocus: Bool = true

    @FocusState.Binding var focusedButton: FocusTarget?

    enum FocusTarget: Hashable {
        case skipBack, playPause, skipForward, nextUp, subtitles, options, dismiss
    }

    var body: some View {
        HStack(spacing: 14) {
            subtitleButton
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

    private var subtitleButton: some View {
        let isFocused = focusedButton == .subtitles
        return Button(action: onOpenSubtitles) {
            Image("PlayerSubtitlesIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 52, height: 52)
                .background(isFocused ? Color.white : Color.white.opacity(0.10), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.3), lineWidth: 1)
                }
        }
        .buttonStyle(TVPlayerInfoButtonStyle())
        .disabled(!allowsFocus)
        .focused($focusedButton, equals: .subtitles)
        .focusEffectDisabled()
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .accessibilityLabel("Subtitles")
        .accessibilityValue(viewModel.subtitleTracks.first(where: {
            $0.trackId == viewModel.selectedSubtitleId
        })?.primaryLabel ?? "Off")
    }

    private var secondaryRow: some View {
        let isFocused = focusedButton == .options
        return Button(action: onOpenHUD) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(isFocused ? .black : .white)
                .frame(width: 52, height: 52)
                .background(isFocused ? Color.white : Color.white.opacity(0.10), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(isFocused ? 0 : 0.3), lineWidth: 1)
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
