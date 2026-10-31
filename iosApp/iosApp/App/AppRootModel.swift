import Foundation
import Observation
import SwiftUI

/// The root view's state for the life of the process: the router, the launch
/// splash and first route, the saved-login alert, the queued deep link and the
/// Restore from iCloud sheet.
@MainActor
@Observable
final class AppRootModel {
    let router = AppRouter()

    var startupAttempt = 0
    private(set) var isStartupCheckRunning = false
    var showsCredentialAlert = false
    private(set) var splashFinished = false
    private(set) var showsSplashOverlay = true
    private(set) var pendingInitialState: AppRouter.AuthState?
    var showsCloudRestore = false

    /// One link waits at a time; the latest wins.
    @ObservationIgnored var pendingDeepLink: URL?
    @ObservationIgnored var isApplyingReturnLock = false
    @ObservationIgnored private var didAppear = false
    @ObservationIgnored private var startupRun: UUID?

    private static let providerSetupKey = "vivid.didCompleteProviderSetup"

    /// Apple TV only: set once it has had a server. After that, provider
    /// setup is no longer needed, the saved-profile selector may show, and a
    /// server that needs setting up opens the server setup page. Never set on
    /// iPhone and iPad.
    var didCompleteProviderSetup = UserDefaults.standard.bool(forKey: AppRootModel.providerSetupKey) {
        didSet {
            guard didCompleteProviderSetup != oldValue else { return }
            UserDefaults.standard.set(didCompleteProviderSetup, forKey: Self.providerSetupKey)
        }
    }

    init() {}

    // MARK: Splash

    func splashDidFinish() {
        LaunchTimeline.recordSplashFinished()
        splashFinished = true
        commitFirstRouteIfReady()
    }

    /// Removes the splash once the hand-off has played. A re-key of the
    /// content starts the wait again.
    func removeSplashAfterHandoff(duration: Double) async {
        guard splashFinished, showsSplashOverlay else { return }
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        showsSplashOverlay = false
    }

    // MARK: First route

    func runStartupCheckIfNeeded() async {
        guard router.authState == .loading, !isStartupCheckRunning else { return }
        let run = UUID()
        startupRun = run
        isStartupCheckRunning = true
        LaunchTimeline.recordInitialStateCheckStarted()
        await resolveFirstRoute()
        if startupRun == run { isStartupCheckRunning = false }
    }

    func retryStartup() {
        startupAttempt += 1
    }

    private func resolveFirstRoute() async {
        #if DEBUG && os(iOS)
        if ProcessInfo.processInfo.environment["VIVID_SHOW_SERVER_SETUP"] == "1" {
            router.path = NavigationPath()
            pendingInitialState = .needsServerSetup
            LaunchTimeline.recordInitialStateResolved(.needsServerSetup)
            commitFirstRouteIfReady()
            return
        }
        #endif

        let registry = ServerRegistry.shared
        let savedAccounts = TVSavedAccountStore.shared

        do {
            try await KeychainReadFailure.retryTemporaryRead {
                try registry.retryInitialRegistryReadIfNeeded()
                #if os(tvOS)
                try await savedAccounts.restoreLocalSessionForLaunch()
                #endif
            }
        } catch {
            isStartupCheckRunning = false
            if !Task.isCancelled { showsCredentialAlert = true }
            return
        }

        #if os(iOS)
        let needsCloudBootstrap = savedAccounts.accounts.isEmpty || registry.entries.isEmpty || !registry.hasActiveServer
        #else
        let needsCloudBootstrap = savedAccounts.accounts.isEmpty || registry.entries.isEmpty
        #endif
        if needsCloudBootstrap {
            #if os(iOS)
            _ = await VividCloudAccountSync.shared.synchronizeForFirstLaunch(router: router, limit: .seconds(5))
            #endif
        } else {
            let router = router
            Task { await VividCloudAccountSync.shared.synchronize(router: router) }
        }

        #if os(tvOS)
        if !registry.entries.isEmpty { didCompleteProviderSetup = true }
        let needsProviderSetup = !didCompleteProviderSetup
        #else
        let needsProviderSetup = false
        #endif
        if !needsProviderSetup {
            savedAccounts.prepareColdLaunch()
        }

        var hasToken = false
        if !needsProviderSetup, let serverId = registry.activeServerId, !serverId.isEmpty {
            do {
                // A server switch during the read makes the answer useless.
                hasToken = try await KeychainReadFailure.retryTemporaryRead {
                    guard registry.activeServerId == serverId else { throw HTTPError.requestIdentityChanged }
                    let found = try await TokenStore.shared.hasAccessTokenForActiveServer(serverId: serverId)
                    guard registry.activeServerId == serverId else { throw HTTPError.requestIdentityChanged }
                    return found
                }
                guard registry.activeServerId == serverId else { throw HTTPError.requestIdentityChanged }
            } catch {
                isStartupCheckRunning = false
                guard !Task.isCancelled else { return }
                if registry.activeServerId != serverId {
                    startupAttempt += 1
                } else {
                    showsCredentialAlert = true
                }
                return
            }
        }

        let target: AppRouter.AuthState
        if needsProviderSetup || !AuthService.shared.hasServer {
            target = .needsServerSetup
        } else if !hasToken {
            target = .needsLogin
        } else if await AuthService.shared.resolveActiveProfileForSession() {
            target = .authenticated
        } else {
            target = .needsProfile
        }
        LaunchTimeline.recordInitialStateResolved(target)

        guard await StartupContentPrefetcher.prefetchForInitialRoute(target) else {
            isStartupCheckRunning = false
            if !Task.isCancelled { startupAttempt += 1 }
            return
        }

        pendingInitialState = target
        commitFirstRouteIfReady()
    }

    /// Commits the first route once both the splash and the check are done,
    /// whichever finishes last.
    private func commitFirstRouteIfReady() {
        guard router.authState == .loading, splashFinished, let target = pendingInitialState else { return }
        pendingInitialState = nil
        LaunchTimeline.recordFirstContent(target)
        #if os(tvOS)
        if target == .needsServerSetup, didCompleteProviderSetup {
            router.path = NavigationPath([Route.serverSetup])
        }
        #endif
        router.authState = target
    }

    // MARK: Appearance

    /// Runs once, when the root view first appears.
    func rootViewAppeared() {
        guard !didAppear else { return }
        didAppear = true
        LaunchTimeline.recordRootViewAppeared()
        #if os(iOS)
        if let url = NotificationDeepLinkCoordinator.shared.takePendingURL() { handleDeepLink(url) }
        #else
        if let url = TVSiriSearchLink.consumePending() { handleDeepLink(url) }
        #endif
    }

    // MARK: Signed-out flow

    func beginLoginPreparation() {
        let router = router
        // Preparation swaps this screen out straight away, so the task must
        // outlive it.
        Task { await TVLoginPreparation.shared.begin(router: router) }
    }

    func cloudRestoreFinished() {
        #if os(tvOS)
        didCompleteProviderSetup = true
        #endif
        TVSavedAccountStore.shared.showsSelector = true
        showsCloudRestore = false
        router.resetToLogin()
    }

    #if os(tvOS)
    func noteProviderSetupIfComplete() {
        let state = router.authState
        guard state != .loading, state != .needsServerSetup, !ServerRegistry.shared.entries.isEmpty else { return }
        didCompleteProviderSetup = true
    }
    #endif
}
