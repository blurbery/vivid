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
/// beside it when the duration is known.
struct ResumeProgressBar: View {
    let value: Double
    let duration: Double?
    let height: CGFloat
    let inset: CGFloat

    #if os(tvOS)
    init(value: Double, duration: Double? = nil, height: CGFloat = 8, inset: CGFloat = 20) {
        self.value = value
        self.duration = duration
        self.height = height
        self.inset = inset
    }
    #else
    init(value: Double, duration: Double? = nil, height: CGFloat = 5, inset: CGFloat = 14) {
        self.value = value
        self.duration = duration
        self.height = height
        self.inset = inset
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

            if let minutes = ResumePresentation(fraction: value, duration: duration)?.minutesLabel {
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

/// The sizes of a card's status row.
struct MediaStatusRowMetrics: Equatable {
    var pillFontSize: CGFloat
    var pillHorizontalPadding: CGFloat = 8
    /// The height of the resume bar on the artwork's bottom edge.
    var barHeight: CGFloat
    /// The gap between the pill and the artwork's right and bottom edges.
    /// At least 3 points more than `barHeight`, so the pill clears the bar.
    var padding: CGFloat = 12

    #if os(tvOS)
    /// Home's landscape cards and the detail pages' episode cards, so the
    /// pill is one size everywhere.
    static let standard = MediaStatusRowMetrics(pillFontSize: 18, barHeight: 6)
    #else
    /// Home's stills and the episode carousel.
    static let standard = MediaStatusRowMetrics(pillFontSize: 12, barHeight: 4)
    /// The small thumbnails of episode list rows.
    static let compact = MediaStatusRowMetrics(pillFontSize: 10, barHeight: 3, padding: 7)
    #endif
}

/// The status row along the bottom of landscape artwork: one pill in the
/// bottom-right corner with the time left or the watched tick, and the
/// resume bar along the artwork's bottom edge, from one side to the other.
/// The pill sits in the same place with or without a bar. Callers pin the
/// row to the bottom at the artwork's full width, inside the view that clips
/// the artwork's corners, so the bar's ends follow them.
struct MediaRuntimeStatusOverlay: View {
    let isPlayed: Bool
    let duration: Double?
    var progress: Double? = nil
    var runtimeMinutes: Int? = nil
    var metrics: MediaStatusRowMetrics = .standard

    /// What the pill shows.
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

    /// In progress: the minutes left, rounded as the Resume button rounds
    /// them. That wins over watched, so a rewatch shows its time left.
    /// Watched: the tick alone, with nothing left to watch. Not started:
    /// the full runtime. Nil when none of that is known.
    static func timePill(isPlayed: Bool, progress: Double?, duration: Double?, runtimeMinutes: Int?) -> TimePill? {
        let runtime = displayedRuntime(minutes: runtimeMinutes, duration: duration)
        if let progress, progress > 0 {
            let resume = ResumePresentation(fraction: progress, duration: duration)
                ?? runtime.flatMap { ResumePresentation(fraction: progress, duration: Double($0) * 60) }
            if let resume { return TimePill(showsTick: false, minutes: resume.minutesRemaining) }
        }
        if isPlayed { return TimePill(showsTick: true, minutes: nil) }
        return runtime.map { TimePill(showsTick: false, minutes: $0) }
    }

    var body: some View {
        let time = Self.timePill(
            isPlayed: isPlayed,
            progress: progress,
            duration: duration,
            runtimeMinutes: runtimeMinutes
        )
        ZStack(alignment: .bottomTrailing) {
            // A watched title shows its tick without a bar.
            if let progress, progress > 0, time?.showsTick != true {
                bar(share: progress.isFinite ? min(progress, 1) : 0)
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
                    fontSize: metrics.pillFontSize,
                    horizontalPadding: metrics.pillHorizontalPadding,
                    verticalPadding: 4
                ))
                .padding(.trailing, metrics.padding)
                .padding(.bottom, metrics.padding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A square-ended bar the width of the artwork; the card's own corner
    /// clip rounds its ends.
    private func bar(share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.30))
                Rectangle()
                    .fill(Color.white)
                    .frame(width: proxy.size.width * share)
            }
        }
        .frame(height: metrics.barHeight)
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
/// A small download mark pinned to a bottom corner (the trailing one unless
/// told otherwise) once the item is on the device.
struct DownloadedBadgeOverlay: View {
    let contentId: String?
    let padding: CGFloat
    var alignment: Alignment = .bottomTrailing

    var body: some View {
        if let contentId, DownloadManager.shared.isDownloaded(contentId: contentId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .shadow(color: .black.opacity(0.3), radius: 4)
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}
#endif
