#if os(iOS)
import BackgroundTasks
import Foundation
import UserNotifications

/// Keeps series monitoring and server-prepared downloads moving while Vivid
/// is in the background. Transfers carry on without it.
enum DownloadBackgroundRefresh {
    /// Listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    private static let identifier = "com.blurbery.vivid.downloads-refresh"

    /// Must run before launch finishes; the system traps otherwise.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    /// Asks for a refresh in 4 hours, or 15 minutes when `soon`. Replaces any
    /// earlier request.
    static func schedule(soon: Bool = false) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: soon ? 15 * 60 : 4 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator, or Background App Refresh turned off.
            DownloadEngine.log.debug("Couldn't schedule the downloads refresh: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Scheduled first, so an expiry or crash can't drop the schedule.
        schedule()
        let work = Task { @MainActor in
            // A cold background launch arrives before startup has retargeted.
            if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
                await TokenStore.shared.retargetActiveServer(serverId: serverId)
            }
            let manager = DownloadManager.shared
            await manager.onAppActive()
            if manager.downloadsEnabled, manager.hasServerPreparingDownloads || !manager.waitingDownloads.isEmpty {
                schedule(soon: true)
            }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }
}

extension DownloadEngine {
    /// Local notices for finished, failed and newly queued downloads. They
    /// open the Downloads tab, and are posted only with permission given.
    enum Alerts {
        static func completed(_ record: DownloadRecord) {
            let name = displayName(record)
            post(
                id: "download-completed-\(record.id)",
                body: String(localized: "\(name) is ready to watch offline",
                             comment: "Notification when a download finishes. The title, e.g. Exodus (S2E8)")
            )
        }

        static func failed(_ record: DownloadRecord) {
            let name = displayName(record)
            post(
                id: "download-failed-\(record.id)",
                body: String(localized: "Download failed: \(name)",
                             comment: "Notification when a download fails. The title, e.g. Exodus (S2E8)")
            )
        }

        static func newEpisodes(count: Int, seriesTitles: Set<String>) {
            guard count > 0 else { return }
            let body: String
            if seriesTitles.count == 1, let series = seriesTitles.first {
                body = String(localized: "\(count) new episodes of \(series) are downloading",
                              comment: "Notification when monitoring queues new episodes of one series")
            } else {
                body = String(localized: "\(count) new episodes are downloading",
                              comment: "Notification when monitoring queues new episodes of several series")
            }
            post(id: "downloads-monitoring-\(UUID().uuidString)", body: body)
        }

        /// The series title, else the title, else "Download"; with the season
        /// and episode when both are known, as in "Exodus (S2E8)".
        static func displayName(_ record: DownloadRecord) -> String {
            let name = record.seriesTitle ?? record.title ?? String(
                localized: "download.noun", defaultValue: "Download",
                comment: "Noun: one download that has no title. Not the Download button."
            )
            guard let season = record.seasonNumber, let episode = record.episodeNumber else { return name }
            return String(localized: "\(name) (S\(String(season))E\(String(episode)))",
                          comment: "A series title with its season and episode, e.g. Exodus (S2E8)")
        }

        private static func post(id: String, body: String) {
            Task {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
                let content = UNMutableNotificationContent()
                content.body = body
                content.sound = .default
                content.userInfo = [NotificationDeepLinkCoordinator.urlUserInfoKey: "vivid://downloads"]
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            }
        }
    }
}
#endif
