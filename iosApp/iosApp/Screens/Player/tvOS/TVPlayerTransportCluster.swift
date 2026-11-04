#if os(tvOS)
import SwiftUI

/// The two round shortcuts above the Apple TV timeline: Subtitles, then
/// Options. Both open the HUD and leave playback alone. They share one native
/// focus section, and Down hands focus back to the timeline.
struct TVPlayerTransportCluster: View {
    let viewModel: PlayerViewModel
    let onOpenHUD: () -> Void
    let onOpenSubtitles: () -> Void
    let onMoveToScrubber: () -> Void
    /// Turned off while the timeline is focused or selecting. With both
    /// circles disabled, a move from the timeline has nowhere native to go,
    /// so the timeline keeps focus and decides the hand-off itself.
    var allowsFocus: Bool = true

    @FocusState.Binding var focusedButton: FocusTarget?

    enum FocusTarget: Hashable {
        case subtitles, options
    }

    private enum Metrics {
        static let gap: CGFloat = 14
        static let diameter: CGFloat = 52
        static let subtitleGlyphSide: CGFloat = 28
        static let optionsGlyphSize: CGFloat = 26
        static let restingFillOpacity = 0.10
        static let restingRingOpacity = 0.3
        static let focusFade = 0.18
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            circle(.subtitles, perform: onOpenSubtitles) { lit in
                Image("PlayerSubtitlesIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Metrics.subtitleGlyphSide, height: Metrics.subtitleGlyphSide)
                    .foregroundStyle(glyphColour(lit: lit))
            }
            .accessibilityLabel("Subtitles")
            .accessibilityValue(currentSubtitleName)

            circle(.options, perform: onOpenHUD) { lit in
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: Metrics.optionsGlyphSize, weight: .medium))
                    .foregroundStyle(glyphColour(lit: lit))
            }
            .accessibilityLabel("Info and playback options")
        }
        .focusSection()
        .onMoveCommand { move in
            guard move == .down else { return }
            onMoveToScrubber()
        }
    }

    /// The selected subtitle track's name for VoiceOver, or Off.
    private var currentSubtitleName: String {
        let selected = viewModel.subtitleTracks.first { $0.trackId == viewModel.selectedSubtitleId }
        return selected?.primaryLabel ?? String(localized: "Off")
    }

    private func glyphColour(lit: Bool) -> Color {
        lit ? .black : .white
    }

    /// A translucent ringed circle that fills white, with a black glyph, while
    /// focused. It draws that look itself, so the system focus effect is off.
    private func circle<Glyph: View>(
        _ target: FocusTarget,
        perform action: @escaping () -> Void,
        @ViewBuilder glyph: (Bool) -> Glyph
    ) -> some View {
        let lit = focusedButton == target
        return Button(action: action) {
            glyph(lit)
                .frame(width: Metrics.diameter, height: Metrics.diameter)
                .background(lit ? Color.white : Color.white.opacity(Metrics.restingFillOpacity), in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(lit ? 0 : Metrics.restingRingOpacity), lineWidth: 1)
                }
        }
        .buttonStyle(BareShortcutStyle())
        .disabled(!allowsFocus)
        .focused($focusedButton, equals: target)
        .focusEffectDisabled()
        .animation(.easeOut(duration: Metrics.focusFade), value: lit)
    }
}

/// Shows the label as it is, with a capsule hit shape and no system focus
/// effect, so the circle's own focus look is the only one.
private struct BareShortcutStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Capsule())
            .focusEffectDisabled()
    }
}
#endif
