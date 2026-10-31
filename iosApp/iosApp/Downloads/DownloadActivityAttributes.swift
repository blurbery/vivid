#if os(iOS)
import ActivityKit
import Foundation

/// The contract between the app, which starts and updates the downloads Live
/// Activity, and the widget extension, which draws it. This file is compiled
/// into both, so it uses nothing but ActivityKit and Foundation. Changing a
/// field breaks activities the system still holds from an earlier build.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading
            case paused
            case preparing
            case completed
        }

        var phase: Phase
        var title: String
        var subtitle: String?
        /// The whole queue's progress, 0 to 1.
        var fraction: Double
        var bytesDownloaded: Int64
        var bytesExpected: Int64
        var completedCount: Int
        var totalCount: Int
        var bytesPerSecond: Double?
        /// When the bar would have been empty at the current rate, so the
        /// widget can animate from where it is now.
        var estimateStart: Date?
        var estimatedEnd: Date?

        /// The range the widget animates along. Only while downloading, and
        /// only while the finish is still ahead.
        var estimate: ClosedRange<Date>? {
            guard phase == .downloading,
                  let estimateStart, let estimatedEnd,
                  estimateStart < estimatedEnd,
                  estimatedEnd > Date() else { return nil }
            return estimateStart...estimatedEnd
        }
    }
}
#endif
