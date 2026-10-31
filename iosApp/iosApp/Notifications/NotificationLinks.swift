#if os(iOS)
import Foundation
import UIKit
import UserNotifications

/// Turns a tapped local notification into a Vivid link. The latest link is
/// also kept, for a cold launch where the root view isn't listening yet.
@MainActor
final class NotificationDeepLinkCoordinator {
    static let shared = NotificationDeepLinkCoordinator()

    /// Delivered and scheduled notifications already carry this key, so it
    /// never changes.
    nonisolated static let urlUserInfoKey = "silo_url"

    private var pendingURL: URL?

    private init() {}

    /// Only `vivid` links are followed.
    nonisolated static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[urlUserInfoKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "vivid" else { return nil }
        return url
    }

    func open(userInfo: [AnyHashable: Any]) {
        guard let url = Self.deepLinkURL(from: userInfo) else { return }
        pendingURL = url
        NotificationCenter.default.post(name: .vividDeepLink, object: nil, userInfo: ["url": url])
    }

    func takePendingURL() -> URL? {
        defer { pendingURL = nil }
        return pendingURL
    }

    func clearPendingURL(matching url: URL) {
        if pendingURL?.absoluteString == url.absoluteString { pendingURL = nil }
    }
}

/// Asks for notification permission once, the first time Vivid has a
/// download or series to report on.
@MainActor
enum LocalNotificationAuthorization {
    private static var isRequesting = false

    static func requestIfNeeded() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

extension VividAppDelegate: UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Every background task identifier has to be registered before launch finishes.
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
            DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
            // A background relaunch arrives before the root view's startup has run.
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
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            NotificationDeepLinkCoordinator.shared.open(userInfo: userInfo)
        }
    }
}
#endif
