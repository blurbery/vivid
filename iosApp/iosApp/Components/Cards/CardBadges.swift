import SwiftUI

/// A tick capsule, optionally with a runtime. Callers pad and pin it.
struct WatchedCheckPill: View {
    var isPlayed: Bool = true
    var runtimeMinutes: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            if isPlayed {
                Image(systemName: "checkmark.circle.fill")
            }
            if let runtimeMinutes {
                Text("\(runtimeMinutes)m")
            }
        }
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
    var duration: Double?
    var height: CGFloat
    var inset: CGFloat

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

/// Runtime and watched state with an optional resume bar, for Home cards.
struct MediaRuntimeStatusOverlay: View {
    let isPlayed: Bool
    let duration: Double?
    var progress: Double? = nil
    var runtimeMinutes: Int? = nil

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

    var body: some View {
        let runtime = Self.displayedRuntime(minutes: runtimeMinutes, duration: duration)
        HStack(spacing: 10) {
            if isPlayed || runtime != nil {
                WatchedCheckPill(isPlayed: isPlayed, runtimeMinutes: runtime)
            }
            if let progress, progress > 0 {
                ResumeProgressBar(value: progress, duration: duration, inset: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
