import SwiftUI

/// How far into a title the viewer is, for resume buttons and bars.
struct ResumePresentation {
    let fraction: Double
    let minutesRemaining: Int
    let episodeLabel: String?

    var minutesLabel: String {
        String(localized: "\(minutesRemaining)m", comment: "Minutes, abbreviated, e.g. 23m")
    }

    init?(position: Double?, duration: Double?, episodeLabel: String? = nil) {
        guard let position, let duration,
              position.isFinite, duration.isFinite,
              duration > 0, position > 0, position < duration,
              duration / 60 < Double(Int.max) else { return nil }
        fraction = position / duration
        minutesRemaining = max(1, Int(((duration - position) / 60).rounded(.up)))
        self.episodeLabel = episodeLabel
    }

    init?(fraction: Double, duration: Double?) {
        guard let duration else { return nil }
        self.init(position: fraction * duration, duration: duration)
    }
}

/// The progress track and minutes left inside a Resume button. Takes its
/// font and colour from the button.
struct ResumeButtonProgressLabel: View {
    let progress: ResumePresentation

    #if os(tvOS)
    private let labelFontSize: CGFloat = 20
    private let trackHeight: CGFloat = 8
    private let plainWidth: CGFloat = 64
    private let labelledWidth: CGFloat = 84
    #else
    private let labelFontSize: CGFloat = 12
    private let trackHeight: CGFloat = 5
    private let plainWidth: CGFloat = 54
    private let labelledWidth: CGFloat = 64
    #endif

    init(progress: ResumePresentation) {
        self.progress = progress
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                if let label = progress.episodeLabel {
                    Text(verbatim: label)
                        .font(.system(size: labelFontSize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Capsule()
                    .fill(.foreground.opacity(0.25))
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.foreground)
                                .frame(width: proxy.size.width * progress.fraction)
                        }
                    }
                    .frame(height: trackHeight)
            }
            .frame(width: progress.episodeLabel == nil ? plainWidth : labelledWidth)

            Text(verbatim: progress.minutesLabel)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: Text {
        let minutes = progress.minutesRemaining
        if let label = progress.episodeLabel {
            return Text("Resume, \(label), \(minutes) minutes remaining")
        }
        return Text("Resume, \(minutes) minutes remaining")
    }
}
