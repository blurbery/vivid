#if os(iOS)
import Foundation
import UserNotifications

/// Posts local notifications for download lifecycle events: completion,
/// terminal failure, and monitoring-queued episodes.
///
/// Permission is requested once by `LocalNotificationAuthorization` when the
/// person first asks for a download or turns on series monitoring, so this
/// only checks the current status when it posts and stays silent when the
/// person declined, never re-prompting.
@MainActor
enum DownloadNotifier {
    /// Tapping any download notification lands on the Downloads screen
    /// through `NotificationDeepLinkCoordinator`.
    private static let downloadsDeepLink = "vivid://downloads"

    static func downloadCompleted(_ record: DownloadRecord) {
        post(
            id: "download-completed-\(record.id)",
            body: String(localized: "\(displayName(for: record)) is ready to watch offline", comment: "Notification when a download finishes. The title, e.g. Exodus (S2E8)")
        )
    }

    static func downloadFailed(_ record: DownloadRecord) {
        post(
            id: "download-failed-\(record.id)",
            body: String(localized: "Download failed: \(displayName(for: record))", comment: "Notification when a download fails. The title, e.g. Exodus (S2E8)")
        )
    }

    /// One notification per monitoring-sync batch. When every queued
    /// episode belongs to one series the body names the show; a
    /// multi-series batch falls back to a count-only summary.
    static func newEpisodesQueued(count: Int, seriesTitles: Set<String>) {
        guard count > 0 else { return }
        let body: String
        if seriesTitles.count == 1, let title = seriesTitles.first {
            body = String(localized: "\(count) new episodes of \(title) are downloading", comment: "Notification when monitoring queues new episodes of one series")
        } else {
            body = String(localized: "\(count) new episodes are downloading", comment: "Notification when monitoring queues new episodes of several series")
        }
        post(id: "downloads-monitoring-\(UUID().uuidString)", body: body)
    }

    /// "Exodus (S2E8)" for episodes, plain title for movies. The series
    /// title is preferred for episodes because the S/E marker already
    /// disambiguates which entry finished.
    private static func displayName(for record: DownloadRecord) -> String {
        let base = record.seriesTitle ?? record.title
            ?? String(localized: "download.noun", defaultValue: "Download", comment: "Noun: one download that has no title. Not the Download button.")
        if let season = record.seasonNumber, let episode = record.episodeNumber {
            return String(localized: "\(base) (S\(String(season))E\(String(episode)))", comment: "A series title with its season and episode, e.g. Exodus (S2E8)")
        }
        return base
    }

    /// No title: banners then lead with the app name, keeping the copy a
    /// single sentence. Foreground presentation is intentionally not
    /// suppressed — the app-wide delegate already presents banners for
    /// every notification while active.
    private static func post(id: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }
            let content = UNMutableNotificationContent()
            content.body = body
            content.sound = .default
            content.userInfo = [NotificationDeepLinkCoordinator.urlUserInfoKey: downloadsDeepLink]
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
#endif
