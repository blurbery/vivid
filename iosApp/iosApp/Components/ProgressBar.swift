import SwiftUI

struct ResumeProgressBar: View {
    let value: Double
    var duration: Double? = nil
    #if os(tvOS)
    var height: CGFloat = 8
    var inset: CGFloat = 20
    #else
    var height: CGFloat = 5
    var inset: CGFloat = 14
    #endif

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.35)
                    Color.white.frame(width: geometry.size.width * (value.isFinite ? min(max(value, 0), 1) : 0))
                }.clipShape(Capsule())
            }
            .frame(height: height)
            if let progress = ResumePresentation(fraction: value, duration: duration) {
                Text(progress.minutesLabel)
                    .font(.system(size: height >= 8 ? 20 : (inset <= 8 ? 10 : 12), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .fixedSize()
            }
        }
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

/// A thin progress bar (0-1) for showing watch progress.
/// Uses white fill on translucent track (Plezy style — no accent color).
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 3)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.vividOnSurface)
                    .frame(width: geo.size.width * min(max(value, 0), 1), height: 3)
            }
        }
        .frame(height: 3)
    }
}

struct ResumePresentation {
    let fraction: Double
    let minutesRemaining: Int
    let episodeLabel: String?
    var minutesLabel: String { "\(minutesRemaining)m" }

    init?(position: Double?, duration: Double?, episodeLabel: String? = nil) {
        guard let position, let duration, position.isFinite, duration.isFinite,
              duration > 0, position > 0, position < duration,
              duration / 60 < Double(Int.max) else { return nil }
        self.episodeLabel = episodeLabel
        fraction = position / duration
        minutesRemaining = max(1, Int(ceil((duration - position) / 60)))
    }

    init?(fraction: Double, duration: Double?) {
        guard let duration else { return nil }
        self.init(position: fraction * duration, duration: duration)
    }
}

struct ResumeButtonProgressLabel: View {
    let progress: ResumePresentation
    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                if let episodeLabel = progress.episodeLabel {
                    Text(episodeLabel)
                        #if os(tvOS)
                        .font(.system(size: 20, weight: .semibold))
                        #else
                        .font(.system(size: 12, weight: .semibold))
                        #endif
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill().opacity(0.25)
                        Capsule().fill().frame(width: geometry.size.width * progress.fraction)
                    }
                }
                #if os(tvOS)
                .frame(height: 8)
                #else
                .frame(height: 5)
                #endif
            }
            #if os(tvOS)
            .frame(width: progress.episodeLabel == nil ? 64 : 84)
            #else
            .frame(width: progress.episodeLabel == nil ? 54 : 64)
            #endif
            Text(progress.minutesLabel).monospacedDigit().fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resume, \(progress.episodeLabel.map { $0 + ", " } ?? "")\(progress.minutesRemaining) minutes remaining")
    }
}
