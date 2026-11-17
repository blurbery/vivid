import SwiftUI

/// A tick capsule for watched posters and picked rows. Callers pad and pin it.
struct WatchedCheckPill: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: Self.fontSize))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }

    #if os(tvOS)
    private static let fontSize: CGFloat = 18
    #else
    private static let fontSize: CGFloat = 12
    #endif
}

/// A thin resume bar along the bottom of artwork, with the minutes left
/// beside it when the duration is known and `showsMinutes` is on.
struct ResumeProgressBar: View {
    let value: Double
    let duration: Double?
    let height: CGFloat
    let inset: CGFloat
    /// Off where a status pill beside the bar already gives the time left.
    let showsMinutes: Bool

    #if os(tvOS)
    init(
        value: Double,
        duration: Double? = nil,
        height: CGFloat = 8,
        inset: CGFloat = 20,
        showsMinutes: Bool = true
    ) {
        self.value = value
        self.duration = duration
        self.height = height
        self.inset = inset
        self.showsMinutes = showsMinutes
    }
    #else
    init(
        value: Double,
        duration: Double? = nil,
        height: CGFloat = 5,
        inset: CGFloat = 14,
        showsMinutes: Bool = true
    ) {
        self.value = value
        self.duration = duration
        self.height = height
        self.inset = inset
        self.showsMinutes = showsMinutes
    }
    #endif

    private var filledShare: Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private var minutesFontSize: CGFloat {
        if height >= 8 { return 20 }
        return inset <= 8 ? 10 : 12
    }

    var body: some View {
        let share = filledShare
        HStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.35))
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: proxy.size.width * share)
                }
                .clipShape(Capsule())
            }
            .frame(height: height)

            if showsMinutes, let minutes = ResumePresentation(fraction: value, duration: duration)?.minutesLabel {
                Text(verbatim: minutes)
                    .font(.system(size: minutesFontSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .fixedSize()
            }
        }
        .padding(.horizontal, inset)
        .padding(.bottom, inset)
        .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The sizes of a card's status row. The time pill is drawn at about 80% of
/// the episode pill's size.
struct MediaStatusRowMetrics: Equatable {
    /// The episode pill's font size.
    var pillFontSize: CGFloat
    var pillHorizontalPadding: CGFloat = 8
    var barHeight: CGFloat
    /// The gap between the row and the artwork's edges.
    var padding: CGFloat = 12
    /// The gap between the pills and the bar.
    var spacing: CGFloat = 10

    var timePillFontSize: CGFloat { (pillFontSize * 0.8).rounded() }

    #if os(tvOS)
    /// Home's landscape cards.
    static let standard = MediaStatusRowMetrics(pillFontSize: 18, barHeight: 8)
    /// The episode cards on series, season and episode pages.
    static let detail = MediaStatusRowMetrics(pillFontSize: 22, pillHorizontalPadding: 10, barHeight: 8, spacing: 12)
    #else
    /// Home's stills and the episode carousel.
    static let standard = MediaStatusRowMetrics(pillFontSize: 12, barHeight: 5)
    /// The small thumbnails of episode list rows.
    static let compact = MediaStatusRowMetrics(pillFontSize: 10, barHeight: 5, padding: 7, spacing: 6)
    #endif
}

/// The status row along the bottom of landscape artwork: the episode code in
/// a pill on the left, the resume bar filling the gap, and a smaller pill on
/// the right with the time left or the watched tick. Movies have no code, so
/// their bar starts at the left edge. Callers pin it to the bottom.
struct MediaRuntimeStatusOverlay: View {
    let isPlayed: Bool
    let duration: Double?
    var progress: Double? = nil
    var runtimeMinutes: Int? = nil
    /// "S1E7" from `EpisodeCardCaption.compactCode`; nil for movies and for
    /// episodes missing a number.
    var episodeCode: String? = nil
    var metrics: MediaStatusRowMetrics = .standard

    /// What the right-hand pill shows.
    struct TimePill: Equatable {
        let showsTick: Bool
        let minutes: Int?
    }

    static func applies(toType type: String, inContinueWatching: Bool) -> Bool {
        switch type.lowercased() {
        case "episode": true
        case "movie": inContinueWatching
        default: false
        }
    }

    static func displayedRuntime(minutes: Int?, duration: Double?) -> Int? {
        if let minutes, minutes > 0 { return minutes }
        guard let duration, duration.isFinite, duration > 0, duration / 60 < Double(Int.max) else { return nil }
        return max(1, Int(duration / 60))
    }

    /// Watched: the tick and the full runtime. In progress: the minutes
    /// left, rounded as the Resume button rounds them. Not started: the
    /// full runtime. Nil when none of that is known.
    static func timePill(isPlayed: Bool, progress: Double?, duration: Double?, runtimeMinutes: Int?) -> TimePill? {
        let runtime = displayedRuntime(minutes: runtimeMinutes, duration: duration)
        if isPlayed { return TimePill(showsTick: true, minutes: runtime) }
        if let progress, progress > 0 {
            let resume = ResumePresentation(fraction: progress, duration: duration)
                ?? runtime.flatMap { ResumePresentation(fraction: progress, duration: Double($0) * 60) }
            if let resume { return TimePill(showsTick: false, minutes: resume.minutesRemaining) }
        }
        return runtime.map { TimePill(showsTick: false, minutes: $0) }
    }

    var body: some View {
        let time = Self.timePill(
            isPlayed: isPlayed,
            progress: progress,
            duration: duration,
            runtimeMinutes: runtimeMinutes
        )
        HStack(spacing: metrics.spacing) {
            if let episodeCode {
                Text(verbatim: episodeCode)
                    .monospacedDigit()
                    .lineLimit(1)
                    .modifier(MediaStatusPillStyle(
                        fontSize: metrics.pillFontSize,
                        horizontalPadding: metrics.pillHorizontalPadding,
                        verticalPadding: 4
                    ))
                    .layoutPriority(1)
            }
            if let progress, progress > 0 {
                // The bar gives way before either pill does.
                ResumeProgressBar(value: progress, height: metrics.barHeight, inset: 0, showsMinutes: false)
                    .frame(minWidth: 12)
            } else {
                Spacer(minLength: 0)
            }
            if let time {
                HStack(spacing: 3) {
                    if time.showsTick {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    if let minutes = time.minutes {
                        Text("\(minutes)m")
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .modifier(MediaStatusPillStyle(
                    fontSize: metrics.timePillFontSize,
                    horizontalPadding: metrics.pillHorizontalPadding - 2,
                    verticalPadding: 3
                ))
                .layoutPriority(1)
            }
        }
        .padding(metrics.padding)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dark capsule behind a status row's text.
private struct MediaStatusPillStyle: ViewModifier {
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: fontSize))
            .foregroundStyle(.white)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}

#if os(iOS)
/// A small download mark pinned bottom-trailing once the item is on the device.
struct DownloadedBadgeOverlay: View {
    let contentId: String?
    let padding: CGFloat

    var body: some View {
        if let contentId, DownloadManager.shared.isDownloaded(contentId: contentId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .shadow(color: .black.opacity(0.3), radius: 4)
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}
#endif
