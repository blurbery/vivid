import Foundation
import SwiftUI

/// Work tied to the signed-in session: what runs on sign-in, on a server or
/// profile change and on each foreground and background.
extension AppRootModel {
    // MARK: Sign-in, server and profile changes

    func authStateChanged() async {
        guard router.authState == .authenticated else { return }
        #if os(iOS)
        DownloadSettings.shared.reloadForCurrentProfile()
        TVTMDbStore.shared.reloadForCurrentProfile()
        #endif
        // The first sign-in after a held first launch lets iCloud restore again.
        TVSavedAccountStore.shared.resumeCloudRestore()
        Task { await TVSavedAccountStore.shared.captureCurrent() }
        #if os(iOS)
        Task { await DownloadManager.shared.onAppActive() }
        #endif

        let queuedLink = pendingDeepLink
        if let queuedLink {
            pendingDeepLink = nil
            handleDeepLink(queuedLink)
        }
        #if os(tvOS)
        reopenTrailerTitle(hadPendingLink: queuedLink != nil)
        #endif

        await hydrateOverlayPreferences(phase: "session_hydrate")
        await AICapabilities.shared.refresh()
        await ImageSizeCapability.shared.refresh()
        await RequestsFeatureStore.shared.refresh()
        await CurrentProfileStore.shared.refresh()
        await UICustomizationPreferences.shared.refresh()
    }

    func activeProfileChanged() async {
        guard router.authState == .authenticated else { return }
        await UICustomizationPreferences.shared.refresh()
    }

    func activeServerChanged() async {
        // The registry publishes a new server while the switch still holds
        // requests back; nothing server-scoped may run before it commits.
        guard await HTTPClient.shared.waitForRequestDispatchOpen(), !Task.isCancelled else { return }
        await TokenStore.shared.switchActiveServer(serverId: ServerRegistry.shared.activeServerId ?? "")
        OverlayPrefsStore.shared.clear()
        guard !Task.isCancelled else { return }
        Task { await AuthService.shared.refreshActiveServerName() }
        guard router.authState == .authenticated else { return }
        #if os(iOS)
        // Moving between signed-in servers leaves the sign-in state alone.
        Task { await DownloadManager.shared.onAppActive() }
        #endif
        await UICustomizationPreferences.shared.refresh()
        await hydrateOverlayPreferences(phase: "server_switch_hydrate")
    }

    #if os(tvOS)
    /// Reopens the title whose trailer went to YouTube, unless a link is
    /// already taking the person somewhere.
    private func reopenTrailerTitle(hadPendingLink: Bool) {
        let contentId = TVTrailerReturnStore.shared.consumeColdLaunchRestore()
        guard let contentId, !hadPendingLink, router.path.isEmpty else { return }
        router.navigate(to: .itemDetail(contentId: contentId))
    }
    #endif

    /// Logs a refresh only when this call actually fetched.
    func hydrateOverlayPreferences(phase: String) async {
        let mark = DispatchTime.now()
        let store = OverlayPrefsStore.shared
        guard await store.hydrateIfNeeded() else { return }
        LaunchTimeline.recordRefreshOutcome(
            phase: phase, startedAt: mark,
            failureReason: store.lastError == nil ? nil : "overlay_prefs_unavailable"
        )
    }

    // MARK: Scene phase

    func scenePhaseChanged(to phase: ScenePhase) {
        LaunchTimeline.recordScenePhase(phase.timelineToken)
        let savedAccounts = TVSavedAccountStore.shared

        switch phase {
        case .active:
            savedAccounts.enteredForeground()
            #if os(iOS)
            DownloadManager.shared.resumeNormalPreparation()
            #endif
        case .background:
            savedAccounts.enteredBackground()
            #if os(iOS)
            VividImagePipeline.shared.prepareForMacSuspension()
            let downloads = DownloadManager.shared
            downloads.handOffQueuedTransfers()
            if downloads.downloadsEnabled {
                DownloadBackgroundRefresh.schedule(soon: downloads.hasServerPreparingDownloads)
            }
            #endif
        default:
            break
        }

        if phase == .active, allowsCloudSyncOnForeground {
            let router = router
            Task { await VividCloudAccountSync.shared.synchronize(router: router) }
        }

        if phase == .background {
            applyBackgroundAwayClock()
        } else if phase == .active, router.authState == .authenticated {
            let launch = ProfileLaunchPreferences.shared
            if isPictureInPictureEngaged {
                launch.clearBackgroundedAt()
            } else if launch.requiresSelectionAfterBackground() {
                Task { await applyProfileReturnLock() }
                return
            } else {
                launch.clearBackgroundedAt()
            }
        }

        guard phase == .active, router.authState == .authenticated else { return }
        Task { await hydrateOverlayPreferences(phase: "foreground_refresh") }
        Task { await AICapabilities.shared.refresh() }
        Task { await ImageSizeCapability.shared.refresh() }
        Task { await RequestsFeatureStore.shared.refresh() }
        Task { await UICustomizationPreferences.shared.refresh() }
        #if os(tvOS)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        #else
        Task { await DownloadManager.shared.onAppActive() }
        #endif
    }

    /// Starts the profile's away clock, or stops it while Picture in Picture
    /// keeps the video on screen.
    func applyBackgroundAwayClock() {
        guard router.authState == .authenticated, AuthService.shared.profileId != nil else { return }
        if isPictureInPictureEngaged {
            ProfileLaunchPreferences.shared.clearBackgroundedAt()
        } else {
            ProfileLaunchPreferences.shared.markBackgrounded(at: .now)
        }
    }

    private var allowsCloudSyncOnForeground: Bool {
        #if os(tvOS)
        !TVSavedAccountStore.shared.accounts.isEmpty && router.authState != .needsServerSetup && !showsCloudRestore
        #else
        true
        #endif
    }

    private var isPictureInPictureEngaged: Bool {
        #if os(iOS)
        PictureInPictureCoordinator.shared.isEngaged
        #else
        false
        #endif
    }

    /// Once the away time has run out, the profile is signed out the way
    /// choosing another profile signs it out.
    private func applyProfileReturnLock() async {
        let launch = ProfileLaunchPreferences.shared
        guard !isApplyingReturnLock, router.authState == .authenticated, !isPictureInPictureEngaged,
              launch.requiresSelectionAfterBackground(),
              let expectedProfileID = AuthService.shared.profileId else { return }
        isApplyingReturnLock = true
        defer { isApplyingReturnLock = false }
        router.presentedPlayer = nil
        guard router.authState == .authenticated, !isPictureInPictureEngaged,
              launch.requiresSelectionAfterBackground() else { return }
        let deactivated = await AuthService.shared.deactivateProfile(
            preserveRememberedProfile: true, markSelectionRequired: true, expectedProfileID: expectedProfileID
        )
        if deactivated {
            router.showProfileSelection()
        }
    }

    // MARK: Session observers

    func sessionDidExpire(_ notification: Notification) {
        guard let event = notification.object as? SessionExpiryEvent,
              case .persistentSessionCleared = event.disposition else { return }
        let router = router
        Task { @MainActor in
            // A newer sign-in on the same server may already have replaced
            // the credentials this event is about.
            guard await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) else { return }
            #if os(iOS)
            DownloadManager.shared.clearForSignOut()
            #endif
            TVSavedAccountStore.shared.sessionExpired(serverID: event.account.serverId)
            router.expiredSession()
        }
    }

    func profileSelectionDidBecomeRequired() {
        let auth = AuthService.shared
        guard shouldPresentProfileSelectionAfterRecovery(isLoggedIn: auth.isLoggedIn, activeProfileID: auth.profileId) else { return }
        router.showProfileSelection()
    }

    // MARK: Plugins

    func syncMDBList(scenePhase: ScenePhase) async {
        guard scenePhase == .active, router.authState == .authenticated else { return }
        await MDBListSyncStore.shared.run()
    }

    func syncSimkl(scenePhase: ScenePhase) async {
        guard scenePhase == .active, router.authState == .authenticated, SimklApp.isAvailable else { return }
        await SimklSyncStore.shared.run()
    }
}

extension ScenePhase {
    /// The scene phase as launch diagnostics name it.
    var timelineToken: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
