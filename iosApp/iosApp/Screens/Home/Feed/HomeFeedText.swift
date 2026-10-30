#if os(iOS)
import SwiftUI

/// Sizes shared by the rows on iPhone and iPad Home.
enum HomeFeedMetrics {
    static let posterAspect: CGFloat = 3 / 2
    static let posterWidth: CGFloat = 132
    static let stillWidth: CGFloat = 240
    static let bottomRunway: CGFloat = 96
    static let posterRadius: CGFloat = 10
    static let stillRadius: CGFloat = 12
    static let gutter: CGFloat = 16
    static let cardSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 30
    static let headerGap: CGFloat = 12
}

/// The short text Home cards show under their artwork.
enum HomeFeedMeta {
    /// "1h 5m", "2h" or "45m"; nil for no runtime.
    static func runtime(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let leftover = minutes % 60
        if hours > 0, leftover > 0 {
            return String(localized: "\(hours)h \(leftover)m")
        }
        if hours > 0 {
            return String(localized: "\(hours)h")
        }
        return String(localized: "\(leftover)m")
    }

    static func remaining(position: Double?, duration: Double?) -> String? {
        guard let resume = ResumePresentation(position: position, duration: duration),
              let time = runtime(minutes: resume.minutesRemaining) else { return nil }
        return String(localized: "\(time) left")
    }

    /// How far through the item is, from 0 to 1, once it has been started.
    static func progress(of item: SectionItem) -> Double? {
        guard let position = item.positionSeconds, let duration = item.durationSeconds,
              duration > 0, position > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    static func secondLine(for item: SectionItem) -> String? {
        EpisodeCardCaption.line(for: item) ?? item.year.map { String($0) }
    }

    static func resumeCaption(for item: SectionItem) -> String? {
        if let remaining = remaining(position: item.positionSeconds, duration: item.durationSeconds) {
            return remaining
        }
        guard let fraction = progress(of: item) else { return nil }
        let percent = Int((fraction * 100).rounded())
        return String(localized: "\(percent)% watched")
    }

    /// Episodes are titled by their series.
    static func title(for item: SectionItem) -> String {
        if item.type.lowercased() == "episode", let series = item.seriesTitle {
            return series
        }
        return item.title
    }

    static func isResumeRow(_ section: ResolvedSection) -> Bool {
        let type = section.sectionType.lowercased()
        return type == "continue_watching" || type == "in_progress"
    }
}

/// A Home row's title.
struct HomeSectionHeader: View {
    private let title: String

    init(title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(verbatim: title)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.vividOnSurface)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, HomeFeedMetrics.gutter)
    }
}

extension View {
    /// The title under a Home poster.
    func homePosterTitleStyle() -> some View {
        font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.vividOnSurface)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The year or episode line under a Home poster's title.
    func homePosterSecondLineStyle() -> some View {
        font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.vividOnSurface.opacity(0.5))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
#endif
