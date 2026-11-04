#if os(tvOS)
import CoreGraphics
import SwiftUI

/// Feedback for a hold-to-seek session started with the controls hidden.
///
/// The controls stay hidden until the session ends, because showing them
/// would move focus off the press sink and the remote with it. This panel is
/// all the viewer sees between the hold and Select or Menu: an optional
/// preview frame, the speed and direction with the target time, a thin
/// position line and a reminder of what the buttons do.
struct HoldSeekIndicator: View {
    /// Signed speed. Below zero seeks backwards, otherwise forwards.
    let rate: Int
    let previewTime: Double
    let duration: Double
    let previewImage: CGImage?

    private enum Metrics {
        static let stackGap: CGFloat = 16
        static let topInset: CGFloat = 120
        static let frameSize = CGSize(width: 480, height: 270)
        static let frameCorner: CGFloat = 20
        static let lineWidth: CGFloat = 520
        static let lineHeight: CGFloat = 3
        static let pillGap: CGFloat = 18
        static let hintGap: CGFloat = 18
        static let edgeOpacity = 0.18
    }

    var body: some View {
        VStack(spacing: Metrics.stackGap) {
            if let previewImage {
                frameThumbnail(previewImage)
            }
            speedPill
            if duration > 0 {
                positionLine
                    .frame(width: Metrics.lineWidth)
            }
            buttonGuide
        }
        .padding(.top, Metrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
    }

    private func frameThumbnail(_ image: CGImage) -> some View {
        let corner = RoundedRectangle(cornerRadius: Metrics.frameCorner, style: .continuous)
        return Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: Metrics.frameSize.width, height: Metrics.frameSize.height)
            .clipShape(corner)
            .overlay {
                corner.stroke(.white.opacity(Metrics.edgeOpacity), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 18, y: 7)
    }

    private var speedPill: some View {
        let speed = abs(rate)
        return HStack(spacing: Metrics.pillGap) {
            Image(systemName: rate < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("\(speed)×")
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
        .vividPlayerGlass(in: Capsule(style: .continuous), tint: Color.black.opacity(0.35))
        .overlay(Capsule().stroke(.white.opacity(Metrics.edgeOpacity), lineWidth: 1))
    }

    /// Where the target sits in the title. Display only, since the real
    /// timeline is hidden for the session.
    private var positionLine: some View {
        GeometryReader { proxy in
            let filled = proxy.size.width * TVTimelineScrubMath.fraction(of: previewTime, duration: duration)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white).frame(width: filled)
            }
        }
        .frame(height: Metrics.lineHeight)
    }

    /// A seek session works differently from the Apple TV app's press and
    /// hold to fast-forward, so the buttons are spelt out.
    private var buttonGuide: some View {
        HStack(spacing: Metrics.hintGap) {
            Label("Speed", systemImage: "arrow.left.arrow.right")
            Label("Play", systemImage: "circle.fill")
            Label("Cancel", systemImage: "arrow.uturn.backward")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .labelStyle(.titleAndIcon)
    }
}
#endif
