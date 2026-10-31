import Foundation

extension Notification.Name {
    /// A `vivid://` link to open, under the user-info key `"url"`.
    static let vividDeepLink = Notification.Name("vividDeepLink")
}

/// A recovered session asks for a profile only when nobody holds one.
func shouldPresentProfileSelectionAfterRecovery(isLoggedIn: Bool, activeProfileID: String?) -> Bool {
    isLoggedIn && activeProfileID == nil
}

/// `vivid://item/<id>`, `vivid://play/<id>`, `vivid://downloads` and, on
/// Apple TV, `vivid://search?q=<term>`. A link that can't act yet waits
/// until someone is signed in with a profile.
extension AppRootModel {
    func receiveDeepLink(_ notification: Notification) {
        guard let url = notification.userInfo?["url"] as? URL else { return }
        #if os(iOS)
        NotificationDeepLinkCoordinator.shared.clearPendingURL(matching: url)
        #else
        TVSiriSearchLink.clearPending(matching: url)
        #endif
        handleDeepLink(url)
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "vivid", let host = url.host?.lowercased() else { return }

        #if os(tvOS)
        // Acting on a search link stops playback and resets the screens, so
        // one without words must do nothing at all.
        let searchTerm = TVSiriSearchLink.term(from: url)
        if searchTerm?.isEmpty == true { return }
        #endif

        // During the profile return lock a link must not open the previous
        // profile's data, even briefly.
        if ProfileLaunchPreferences.shared.requiresSelectionAfterBackground() {
            pendingDeepLink = url
            return
        }

        let isAuthenticated = router.authState == .authenticated

        if host == "downloads" {
            guard isAuthenticated else {
                pendingDeepLink = url
                return
            }
            #if os(iOS)
            guard DownloadManager.shared.downloadsEnabled else { return }
            router.popToRoot()
            router.switchTab(to: .downloads)
            #endif
            return
        }

        #if os(tvOS)
        if let searchTerm {
            guard isAuthenticated else {
                pendingDeepLink = url
                return
            }
            router.requestSearch(query: searchTerm)
            return
        }
        #endif

        let components = url.pathComponents
        guard components.count > 1 else { return }
        let contentId = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contentId.isEmpty else { return }

        guard isAuthenticated else {
            pendingDeepLink = url
            return
        }

        switch host {
        case "item":
            router.navigate(to: .itemDetail(contentId: contentId))
        case "play":
            let router = router
            Task { @MainActor in
                router.navigate(to: .player(contentId: contentId, startFromBeginning: false, resumePosition: nil))
            }
        default:
            break
        }
    }
}
