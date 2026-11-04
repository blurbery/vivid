#if os(tvOS)
import CoreGraphics
import SwiftUI

/// Floating chip shown during a hold-to-seek session that started while the
/// controls were hidden. The controls stay hidden for the whole session
/// (showing them would take focus off the press sink and lose the remote),
/// so this is the only feedback between the hold and Select or Menu. It
/// shows the direction and speed, the preview time, a thin progress line
/// and a hint for the buttons.
struct HoldSeekIndicator: View {
    /// Signed multiplier: negative = backward, positive = forward.
    let rate: Int
    let previewTime: Double
    let duration: Double
    let previewImage: CGImage?

    var body: some View {
        VStack(spacing: 16) {
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 480, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 7)
            }
            chip
            if duration > 0 {
                miniProgress
                    .frame(width: 520)
            }
            hint
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
    }

    private var chip: some View {
        HStack(spacing: 18) {
            Image(systemName: directionIcon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("\(abs(rate))×")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(PlayerTimeFormatter.formatHMS(previewTime))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .vividPlayerGlass(
            in: Capsule(style: .continuous),
            tint: Color.black.opacity(0.35)
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// Where the preview lands on the timeline. Read-only: the scrubber is
    /// hidden while this shows.
    private var miniProgress: some View {
        GeometryReader { geo in
            let fraction = TVTimelineScrubMath.fraction(of: previewTime, duration: duration)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    /// Which buttons do what. A seek session isn't the Apple TV app's
    /// momentary hold to fast-forward, so first-time users need the hint.
    private var hint: some View {
        HStack(spacing: 18) {
            Label("Speed", systemImage: "arrow.left.arrow.right")
            Label("Play", systemImage: "circle.fill")
            Label("Cancel", systemImage: "arrow.uturn.backward")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .labelStyle(.titleAndIcon)
    }

    private var directionIcon: String {
        rate >= 0 ? "forward.fill" : "backward.fill"
    }
}
#endif
