#if os(iOS)
import Foundation
import UserNotifications

/// Routes a tapped local notification (download finished, failed or queued)
/// to its `vivid://` destination, holding it until ContentView can handle
/// it after a cold launch.
@MainActor
final class NotificationDeepLinkCoordinator {
    static let shared = NotificationDeepLinkCoordinator()

    /// The userInfo key carrying a notification's `vivid://` link. Kept from
    /// the earlier push pipeline so notifications delivered before an update
    /// still open their destination.
    nonisolated static let urlUserInfoKey = "silo_url"

    private var pendingDeepLink: URL?

    private init() {}

    func postDeepLink(from userInfo: [AnyHashable: Any]) {
        guard let url = Self.deepLinkURL(from: userInfo) else { return }
        pendingDeepLink = url
        NotificationCenter.default.post(
            name: .vividDeepLink,
            object: nil,
            userInfo: ["url": url]
        )
    }

    func consumePendingDeepLink() -> URL? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    func clearPendingDeepLink(matching url: URL) {
        guard pendingDeepLink?.absoluteString == url.absoluteString else { return }
        pendingDeepLink = nil
    }

    /// Only Vivid's own links are followed; ContentView.handleDeepLink owns
    /// which routes are valid.
    nonisolated static func deepLinkURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo[urlUserInfoKey] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "vivid" else { return nil }
        return url
    }
}

/// Asks once for permission to show local notifications, when the person
/// first asks for a download or turns on series monitoring, so download
/// notifications can appear. Never prompts again after the person has
/// answered.
@MainActor
enum LocalNotificationAuthorization {
    private static var isRequesting = false

    static func requestIfNeeded() async {
        // An episode list asks for each episode in turn; one prompt covers them.
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}
#endif
