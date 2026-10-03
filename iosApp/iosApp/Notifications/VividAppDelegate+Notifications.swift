#if os(iOS)
import UIKit
import UserNotifications

extension VividAppDelegate: UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // BGTaskScheduler requires every identifier to be registered before
        // launch finishes — the system traps when it launches the app for a
        // task with no handler.
        DownloadBackgroundRefresh.register()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadSessionDelegate.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            // Touching `shared` recreates the background session so its
            // buffered events replay; the handler fires once the manager
            // drains `allEventsDelivered`. Scope activation runs right
            // after so finished media can resolve its on-disk destination
            // even on a cold background relaunch.
            DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
            // A cold background relaunch lands here before
            // ContentView.checkInitialState() has pointed TokenStore at the
            // active registry server; activating against an unresolved
            // profile would release the held session events into an empty
            // scope and discard the staged completions.
            if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
                await TokenStore.shared.retargetActiveServer(serverId: serverId)
            }
            await DownloadManager.shared.activateScopeIfNeeded()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Download notifications are local, so present them while the app
        // is open too.
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await NotificationDeepLinkCoordinator.shared.postDeepLink(
            from: response.notification.request.content.userInfo
        )
    }
}
#endif
