import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var router = AppRouter()
    @State private var serverRegistry = ServerRegistry.shared
    @State private var launchPreferences = ProfileLaunchPreferences.shared
    @State private var isApplyingProfileReturnPolicy = false
    #if os(iOS)
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    #endif
    #if DEBUG
    @State private var debugPlayContentId: String?
    @State private var didAttemptDebugAutoPlay = false
    #endif
    @State private var didStartInitialStateCheck = false
    @State private var initialStateAttempt = 0
    @State private var showsCredentialReadError = false
    @State private var didFinishStartupSplash = false
    @State private var showsStartupOverlay = true
    @Environment(\.accessibilityReduceMotion) private var reduceStartupMotion
    @State private var pendingInitialAuthState: AppRouter.AuthState?
    #if os(iOS) || os(tvOS)
    @State private var showsCloudRestore = false
    #endif
    #if os(tvOS)
    @AppStorage("vivid.didCompleteProviderSetup") private var didCompleteProviderSetup = false
    #endif
    /// Deep link URL received before the auth state was ready. Content links
    /// drain on the next `.authenticated` transition.
    @State private var pendingDeepLink: URL?
    /// Shared with every screen that renders cards. Hydrates lazily on
    /// the first .authenticated transition so cards stay visible during
    /// the brief window between sign-in and the overlay-config fetch.
    @StateObject private var overlayPrefs = OverlayPrefsStore.shared
    /// Server-synced navigation and card presentation for this client family.
    /// The store paints its offline cache first, then reconciles whenever the
    /// authenticated server/profile boundary changes.
    @State private var uiCustomization = UICustomizationPreferences.shared
    /// Used to retry overlay hydration on foreground transitions: if the
    /// initial fetch failed transiently, `hydrateIfNeeded()` will retry
    /// because the store left `hasHydrated == false`. Idempotent when
    /// the previous hydration succeeded.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        launchContent
            .environment(router)
            .alert("Saved login unavailable", isPresented: $showsCredentialReadError) {
                Button("Retry") { initialStateAttempt += 1 }
            } message: {
                Text("Vivid couldn’t read your saved login from Keychain. Your saved account has not been removed. Try again.")
            }
        // A server change is a hard data boundary even when both servers map
        // to the same auth state. Re-key the routed subtree so profile, home,
        // library, focus, and modal state cannot survive from the old server.
        .id(serverRegistry.activeServerId)
        #if os(tvOS)
        .background { TVAppBackdrop() }
        #endif
        #if os(iOS) || os(tvOS)
        .id(TVSavedAccountStore.shared.contentRevision)
        #endif
        // Account restoration may re-key the content while Keychain retries.
        // Keep the startup task outside that subtree so it can finish routing.
        .task(id: initialStateAttempt) {
            guard router.authState == .loading, !didStartInitialStateCheck else { return }
            didStartInitialStateCheck = true
            defer { didStartInitialStateCheck = false }
            #if os(iOS) || os(tvOS)
            LaunchTimeline.recordInitialStateCheckStarted()
            #endif
            await checkInitialState()
        }
        #if os(iOS) || os(tvOS)
        .sheet(isPresented: $showsCloudRestore) {
            TVCloudRestoreView {
                #if os(tvOS)
                didCompleteProviderSetup = true
                #endif
                TVSavedAccountStore.shared.showsSelector = true
                showsCloudRestore = false
                router.resetToLogin()
            }
        }
        #endif
        .environmentObject(overlayPrefs)
        .preferredColorScheme(.dark)
        .progressViewStyle(VividLoadingProgressStyle())
        #if os(tvOS) && DEBUG
        .modifier(TVFocusDebugActivationModifier())
        #endif
        #if DEBUG
        .modifier(DebugPlayerPresentationModifier(
            contentId: debugPlayContentId,
            isPresented: debugPlayerPresentation,
            router: router,
            overlayPrefs: overlayPrefs
        ))
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .vividDeepLink)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            #if os(iOS)
            NotificationDeepLinkCoordinator.shared.clearPendingDeepLink(matching: url)
            #endif
            handleDeepLink(url)
        }
        .onAppear {
            #if os(iOS) || os(tvOS)
            // The first frame SwiftUI actually produced. A launch whose
            // breadcrumbs stop at `process_start` never got here, which
            // separates a failure in static/scene setup from one in the
            // startup work `authContent` drives below.
            LaunchTimeline.recordRootViewAppeared()
            #endif
            #if os(iOS)
            if let url = NotificationDeepLinkCoordinator.shared.consumePendingDeepLink() {
                handleDeepLink(url)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .vividSessionExpired)) { notification in
            guard let event = notification.object as? SessionExpiryEvent,
                  event.disposition == .persistentSessionCleared else { return }
            Task { @MainActor in
                // Delivery is asynchronous. Revalidate at the destructive
                // consumer so a same-server login that replaced this epoch
                // after posting cannot be routed back to login.
                guard await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) else { return }
                #if !os(tvOS)
                DownloadManager.shared.clearForSignOut()
                #endif
                #if os(iOS) || os(tvOS)
                TVSavedAccountStore.shared.sessionExpired(serverID: event.account.serverId)
                #endif
                router.expiredSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vividProfileSelectionRequired)) { _ in
            guard shouldPresentProfileSelectionAfterRecovery(
                isLoggedIn: AuthService.shared.isLoggedIn,
                activeProfileID: AuthService.shared.profileId
            ) else { return }
            router.showProfileSelection()
        }
        #if os(iOS) || os(tvOS)
        // Memory pressure is the one launch/runtime failure the user perceives
        // as "it just closed" and that leaves no other trace: the jetsam kill
        // that usually follows produces no termination notification and no
        // crash report the app can see. One warning-level breadcrumb followed
        // by silence is the readable signature of that outcome.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            LaunchTimeline.recordMemoryWarning(state: Self.diagnosticsScenePhase(scenePhase))
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification
        )) { _ in
            LaunchTimeline.recordTermination(state: Self.diagnosticsScenePhase(scenePhase))
        }
        #endif
        #if os(tvOS)
        .onChange(of: router.authState, initial: true) { _, state in
            if state != .loading, state != .needsServerSetup, !serverRegistry.entries.isEmpty {
                didCompleteProviderSetup = true
            }
        }
        #endif
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            markProfileAwayStartForTermination()
        }
        #endif
        #if DEBUG
        .task {
            // Debug: auto-play from launch argument -debugPlay <contentId>
            if let idx = CommandLine.arguments.firstIndex(of: "-debugPlay"),
               idx + 1 < CommandLine.arguments.count {
                let contentId = CommandLine.arguments[idx + 1]
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                debugPlayContentId = contentId
            }
        }
        .task {
            await maybeDebugAutoLogin()
        }
        #endif
        #if os(iOS) || os(tvOS)
        .task(id: MDBListSyncStore.shared.contextKey + String(describing: scenePhase) + String(describing: router.authState)) {
            guard scenePhase == .active, router.authState == .authenticated else { return }
            await MDBListSyncStore.shared.run()
        }
        #endif
        .task(id: router.authState) {
            #if os(tvOS) || os(iOS)
            if router.authState == .authenticated {
                #if os(iOS)
                DownloadSettings.shared.reloadForCurrentProfile()
                TVTMDbStore.shared.reloadForCurrentProfile()
                #endif
                Task { await TVSavedAccountStore.shared.captureCurrent() }
            }
            #endif
            #if DEBUG
            await maybeAutoPlayForDebug()
            #endif
            if router.authState == .authenticated {
                #if !os(tvOS)
                // Downloads load their own scope and permission straight away.
                // Waiting behind the refreshes below (one of which can sit on
                // the notification prompt) left them "unavailable" until the
                // app next came to the foreground.
                Task { await DownloadManager.shared.onAppActive() }
                #endif
                let hasPendingDeepLink = pendingDeepLink != nil
                if let pending = pendingDeepLink {
                    pendingDeepLink = nil
                    handleDeepLink(pending)
                }
                #if os(tvOS)
                restoreTrailerReturnIfNeeded(hasPriorityLaunchIntent: hasPendingDeepLink)
                #endif
                await hydrateOverlayPrefs(phase: "session_hydrate")
                // Hydrate AI capabilities on a cold relaunch into a restored
                // session — `selectProfile` only refreshes on a fresh sign-in,
                // so without this the metadata-language / on-view-translate
                // features stay hidden until a profile switch. Idempotent and
                // failure-tolerant, so double-calling with `selectProfile` is safe.
                await AICapabilities.shared.refresh()
                // Same cold-relaunch reasoning: without this, a restored
                // session on tvOS would request default-size images until
                // the next profile switch.
                await ImageSizeCapability.shared.refresh()
                await RequestsFeatureStore.shared.refresh()
                await CurrentProfileStore.shared.refresh()
                await uiCustomization.refresh()
                #if os(iOS)
                await LocalNotificationAuthorization.requestIfNeeded()
                #endif
            }
        }
        .task(id: serverRegistry.activeServerId) {
            // ServerRegistry publishes the destination ID while its identity
            // transition lease is still held. Wait before reading or
            // retargeting any server-scoped state so this task cannot race the
            // final token commit. A superseded SwiftUI task is cancelled while
            // queued and must perform no work for the stale destination.
            guard await HTTPClient.shared.waitForRequestDispatchOpen() else { return }
            guard !Task.isCancelled else { return }
            // `activeServerId` changes before ServerRegistry finishes its
            // async token retarget. Complete that boundary here before any
            // server-scoped overlay request, then clear and rehydrate even
            // when the destination remains `.authenticated`.
            await TokenStore.shared.switchActiveServer(
                serverId: serverRegistry.activeServerId ?? ""
            )
            overlayPrefs.clear()
            guard !Task.isCancelled else { return }
            Task { await AuthService.shared.refreshActiveServerName() }
            #if !os(tvOS)
            // A switch between signed-in servers stays `.authenticated`, so
            // the auth-state task never reruns. Point downloads at the new
            // server here, or they keep the previous server's permission.
            if router.authState == .authenticated {
                Task { await DownloadManager.shared.onAppActive() }
            }
            #endif
            if router.authState == .authenticated {
                await uiCustomization.refresh()
                // The one hydration whose outcome is never optional: `clear()`
                // above guarantees a real fetch, so the wrapper's
                // short-circuit case cannot apply here and a failure leaves
                // every card — including the admin kill switch — on registry
                // defaults for a server the user just switched to.
                await hydrateOverlayPrefs(phase: "server_switch_hydrate")
            }
        }
        .task(id: serverRegistry.activeProfileId) {
            if router.authState == .authenticated {
                await uiCustomization.refresh()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS) || os(tvOS)
            // Single funnel for every scene edge. `LaunchTimeline` decides the
            // tier (`.inactive` is verbose noise; active/background are the
            // timeline) and stamps the inter-phase `duration_ms`.
            LaunchTimeline.recordScenePhase(Self.diagnosticsScenePhase(newPhase))
            #endif
            #if os(iOS)
            switch newPhase {
            case .active:
                TVSavedAccountStore.shared.enteredForeground()
                DownloadManager.shared.resumeNormalPreparation()
            case .background:
                TVSavedAccountStore.shared.enteredBackground()
                VividImagePipeline.shared.prepareForMacSuspension()
                DownloadManager.shared.handOffQueuedTransfers()
                // Keep series monitoring alive while backgrounded; only
                // worth a wake when the profile can download at all.
                if DownloadManager.shared.downloadsEnabled {
                    DownloadBackgroundRefresh.schedule(soon: DownloadManager.shared.hasServerPreparingDownloads)
                }
            default:
                break
            }
            #endif
            #if os(tvOS)
            switch newPhase {
            case .active:
                TVSavedAccountStore.shared.enteredForeground()
            case .background:
                TVSavedAccountStore.shared.enteredBackground()
            default:
                break
            }
            #endif
            #if os(iOS) || os(tvOS)
            #if os(tvOS)
            let canSyncCloudOnForeground = !TVSavedAccountStore.shared.accounts.isEmpty
                && router.authState != .needsServerSetup && !showsCloudRestore
            #else
            let canSyncCloudOnForeground = true
            #endif
            if newPhase == .active, canSyncCloudOnForeground {
                Task { await VividCloudAccountSync.shared.synchronize(router: router) }
            }
            #endif

            if newPhase == .background {
                markProfileAwayStartIfNeeded()
            } else if newPhase == .active,
                      router.authState == .authenticated {
                if keepsProfileActiveInBackground {
                    launchPreferences.clearBackgroundedAt()
                } else if launchPreferences.requiresSelectionAfterBackground() {
                    Task { await applyProfileReturnPolicy() }
                    return
                } else {
                    launchPreferences.clearBackgroundedAt()
                }
            }

            // Cover the transient-failure case Codex flagged on #41:
            // initial overlay hydration runs once in the auth-state
            // task above. If that fetch transiently failed and the
            // user never opens overlay settings, the admin kill
            // switch and baseline stay stale until app restart.
            // Foreground transitions are a natural opportunity to
            // retry — `hydrateIfNeeded()` is a no-op when the
            // previous hydration succeeded, so this costs nothing in
            // the happy path.
            guard newPhase == .active,
                  router.authState == .authenticated else { return }
            Task { await hydrateOverlayPrefs(phase: "foreground_refresh") }
            // Same rationale as overlay hydration above: a transiently-failed
            // capability probe (or one skipped on a cold restore) gets a
            // natural retry on foreground. `refresh()` is idempotent, so the
            // happy path costs nothing.
            Task { await AICapabilities.shared.refresh() }
            Task { await ImageSizeCapability.shared.refresh() }
            Task { await RequestsFeatureStore.shared.refresh() }
            Task { await uiCustomization.refresh() }
            #if os(iOS)
            Task { await LocalNotificationAuthorization.requestIfNeeded() }
            #endif
            #if os(tvOS)
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            #endif
            #if !os(tvOS)
            Task { await DownloadManager.shared.onAppActive() }
            #endif
        }
        #if os(iOS)
        .onChange(of: pictureInPicture.isEngaged) { _, _ in
            updateProfileAwayStartForBackgroundPlayback()
        }
        #endif
    }

    /// Overlay hydration is the one post-authentication refresh whose failure
    /// is silently sticky: `hydrateIfNeeded()` leaves `hasHydrated == false`
    /// and every card renders from registry defaults — including the admin
    /// kill switch — until a later foreground happens to succeed. Wrapping the
    /// single funnel both call sites already share turns "my badges are wrong"
    /// into a dated line with an outcome.
    ///
    /// The store swallows the error and exposes it as `lastError`, so the
    /// reason is read back rather than caught. That text is server-authored, so
    /// only its presence is logged, as a fixed token. A still-broken store
    /// leaves `hasHydrated == false` and therefore re-fetches — and re-reports
    /// a failure — on every foreground; that repetition is the intended signal
    /// that overlays are persistently stale rather than transiently slow.
    ///
    /// Only the call that actually performed the fetch reports an outcome.
    /// `hydrateIfNeeded()` short-circuits when the store is already hydrated or
    /// a hydration is in flight — the cold-start case, where
    /// `StartupContentPrefetcher.prefetchAuthenticatedContent()` starts an
    /// unawaited hydration before this runs. In that window `lastError` has
    /// already been cleared by the running `refresh()` and reads as success, so
    /// reporting here would stamp a near-zero-duration success on a request
    /// that may still fail. A missing line costs a reader nothing; a false
    /// success actively misdirects the person debugging that cold start.
    @MainActor
    private func hydrateOverlayPrefs(phase: String) async {
        #if os(iOS) || os(tvOS)
        let mark = LaunchTimeline.mark()
        guard await overlayPrefs.hydrateIfNeeded() else { return }
        LaunchTimeline.recordRefreshOutcome(
            phase: phase,
            since: mark,
            failureReason: overlayPrefs.lastError == nil ? nil : "overlay_prefs_unavailable"
        )
        #else
        await overlayPrefs.hydrateIfNeeded()
        #endif
    }

    /// PiP is still active use of the selected profile, so its running time
    /// does not count toward a profile-selection timeout.
    private var keepsProfileActiveInBackground: Bool {
        #if os(iOS)
        if pictureInPicture.isEngaged { return true }
        #endif
        return false
    }

    private func markProfileAwayStartIfNeeded(at date: Date = .now) {
        guard router.authState == .authenticated,
              AuthService.shared.profileId != nil else { return }
        if keepsProfileActiveInBackground {
            launchPreferences.clearBackgroundedAt()
        } else {
            launchPreferences.markBackgrounded(at: date)
        }
    }

    /// macOS does not reliably publish a background scene phase before Cmd-Q.
    /// Termination always ends active playback, so it starts an away interval
    /// even when media was still playing at the time of the notification.
    private func markProfileAwayStartForTermination(at date: Date = .now) {
        guard AuthService.shared.isLoggedIn,
              AuthService.shared.profileId != nil else { return }
        launchPreferences.markBackgrounded(at: date)
    }

    /// If PiP starts, stop the away clock. If it later stops while Vivid is
    /// still hidden, begin a fresh interval at that point.
    private func updateProfileAwayStartForBackgroundPlayback() {
        guard scenePhase == .background else { return }
        markProfileAwayStartIfNeeded()
    }

    /// Turn an expired away interval into the same durable identity boundary
    /// as an explicit profile switch. The account and remembered-profile hint
    /// remain available to Who's Watching.
    @MainActor
    private func applyProfileReturnPolicy() async {
        guard !isApplyingProfileReturnPolicy,
              router.authState == .authenticated,
              !keepsProfileActiveInBackground,
              launchPreferences.requiresSelectionAfterBackground(),
              let expectedProfileID = AuthService.shared.profileId else {
            return
        }
        isApplyingProfileReturnPolicy = true
        defer { isApplyingProfileReturnPolicy = false }

        // Retire player UI while the old profile still owns request identity,
        // then close the HTTP dispatch gate and clear every profile-scoped
        // cache through AuthService.
        router.presentedPlayer = nil

        guard router.authState == .authenticated,
              !keepsProfileActiveInBackground,
              launchPreferences.requiresSelectionAfterBackground() else {
            return
        }
        let deactivated = await AuthService.shared.deactivateProfile(
            preserveRememberedProfile: true,
            markSelectionRequired: true,
            expectedProfileID: expectedProfileID
        )
        guard deactivated else { return }
        router.showProfileSelection()
    }

    #if os(iOS) || os(tvOS)
    private static func diagnosticsScenePhase(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
    #endif

    // Fade the loading logo out before revealing the destination on the shared
    // canvas. Route resolution still owns authentication.
    @ViewBuilder
    private var launchContent: some View {
        #if os(iOS) || os(tvOS)
        ZStack {
            authContent
                .opacity(didFinishStartupSplash ? 1 : 0)
                .animation(startupContentRevealAnimation, value: didFinishStartupSplash)
                .disabled(showsStartupOverlay)
                .accessibilityHidden(showsStartupOverlay)
            if showsStartupOverlay {
                startupPresentation
                    .opacity(didFinishStartupSplash ? 0 : 1)
                    .scaleEffect(didFinishStartupSplash && !reduceStartupMotion ? 0.96 : 1)
                    .animation(startupLogoFadeAnimation, value: didFinishStartupSplash)
                    .zIndex(1)
            }
        }
        .background {
            // Navigation and startup use the same saved device theme.
            VividAppBackdrop()
        }
        .task(id: didFinishStartupSplash) {
            guard didFinishStartupSplash else { return }
            do {
                try await Task.sleep(for: .seconds(startupHandoffDuration))
            } catch { return }
            showsStartupOverlay = false
        }
        #else
        authContent
        #endif
    }

    private var startupHandoffDuration: Double { reduceStartupMotion ? 0.2 : 0.55 }

    private var startupLogoFadeAnimation: Animation {
        .easeInOut(duration: startupHandoffDuration * 0.4)
    }

    private var startupContentRevealAnimation: Animation {
        // Keep the total handoff duration unchanged, with no overlapping logo.
        .easeInOut(duration: startupHandoffDuration * 0.6)
            .delay(startupHandoffDuration * 0.4)
    }

    private var initialSplashContentReady: Bool {
        pendingInitialAuthState != nil
    }

    @ViewBuilder
    private var startupPresentation: some View {
        #if os(tvOS) || os(iOS)
        VividStartupView(
            isContentReady: initialSplashContentReady,
            isLoading: didStartInitialStateCheck && !showsCredentialReadError
        ) {
            LaunchTimeline.recordSplashFinished()
            didFinishStartupSplash = true
            finishInitialStartupIfReady()
        }
        #else
        ProgressView("Loading Vivid")
            .onAppear {
                if initialSplashContentReady {
                    didFinishStartupSplash = true
                    finishInitialStartupIfReady()
                }
            }
            .onChange(of: initialSplashContentReady) { _, ready in
                if ready {
                    didFinishStartupSplash = true
                    finishInitialStartupIfReady()
                }
            }
        #endif
    }

    @ViewBuilder
    private var authContent: some View {
        #if os(tvOS)
        if TVLoginPreparation.shared.isPresented {
            TVLoginPreparationView()
        } else if TVSavedAccountStore.shared.busy {
            Color.clear.ignoresSafeArea().overlay { VividLoadingDots() }
        } else if didCompleteProviderSetup,
                  router.authState != .loading, router.authState != .needsServerSetup,
                  TVSavedAccountStore.shared.showsSelector {
            TVSavedProfilesScreen(router: router)
        } else {
            routedAuthContent
        }
        #elseif os(iOS)
        if TVLoginPreparation.shared.isPresented {
            TVLoginPreparationView()
        } else if TVSavedAccountStore.shared.busy {
            VividAppBackdrop().overlay { VividLoadingDots() }
        } else if router.authState != .loading, router.authState != .needsServerSetup,
                  TVSavedAccountStore.shared.showsSelector {
            PhoneSavedProfilesScreen()
        } else {
            routedAuthContent
        }
        #else
        routedAuthContent
        #endif
    }

    @ViewBuilder
    private var routedAuthContent: some View {
        switch router.authState {
        case .loading:
            Group {
                #if os(tvOS)
                Color.clear.ignoresSafeArea()
                #elseif os(iOS)
                VividAppBackdrop()
                #else
                startupPresentation
                #endif
            }

        case .needsServerSetup, .needsLogin:
            #if os(tvOS)
            NavigationStack(path: $router.path) {
                TVProviderSelectionView(onRestore: { showsCloudRestore = true })
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            #else
            if router.authState == .needsServerSetup {
                #if os(iOS)
                NavigationStack(path: $router.path) {
                    PhoneProviderSelectionView(router: router, onRestore: { showsCloudRestore = true })
                        .navigationDestination(for: Route.self) { route in
                            destinationView(for: route)
                        }
                }
                #else
                ServerSetupView(router: router)
                #endif
            } else {
                NavigationStack(path: $router.path) {
                    loginRoot
                        .navigationDestination(for: Route.self) { route in
                            destinationView(for: route)
                        }
                }
            }
            #endif

        case .needsProfile:
            // Login preparation enters the primary (or only) profile and asks
            // for its PIN when needed. Choosing between several profiles is
            // handled by the saved-profiles screen, not a server profile picker.
            #if os(tvOS)
            Color.clear.ignoresSafeArea()
                .onAppear { Task { await TVLoginPreparation.shared.begin(router: router) } }
            #elseif os(iOS)
            VividAppBackdrop()
                .task { await TVLoginPreparation.shared.begin(router: router) }
            #else
            Color.clear
            #endif

        case .authenticated:
            #if os(tvOS)
            TVMainTabView(router: router)
            #else
            MainTabView(router: router)
            #endif
        }
    }

    #if DEBUG
    private var debugPlayerPresentation: Binding<Bool> {
        Binding(
            get: { debugPlayContentId != nil },
            set: { if !$0 { debugPlayContentId = nil } }
        )
    }
    #endif

    /// Resolves a `vivid://` URL to a navigation action. Supported
    /// shapes:
    /// - `vivid://item/{contentId}` — push the detail screen
    /// - `vivid://play/{contentId}` — push the player (resume from
    ///   last known position)
    /// - `vivid://downloads` — select the Downloads tab (local
    ///   download notifications)
    ///
    /// If the auth state isn't ready yet, the link is queued in
    /// `pendingDeepLink` until startup commits its initial route.
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "vivid",
              let host = url.host?.lowercased() else { return }

        // A content link received while the app is returning must not race the
        // timeout lock and briefly open data for the previous profile. The
        // authenticated-state task drains it after profile selection succeeds.
        guard !launchPreferences.requiresSelectionAfterBackground() else {
            pendingDeepLink = url
            return
        }

        if host == "downloads" {
            guard router.authState == .authenticated else {
                pendingDeepLink = url
                return
            }
            // The tab only exists while downloads are enabled — a stale
            // download notification tapped after a profile/capability
            // change must not select a tab that never renders.
            guard DownloadManager.shared.downloadsEnabled else { return }
            // Select the tab rather than pushing the route — a push stacks
            // a duplicate Downloads screen when that tab is already showing,
            // and hides the tab context from anywhere else.
            router.popToRoot()
            router.switchTab(to: .downloads)
            return
        }

        guard !url.pathComponents.isEmpty else { return }
        let contentId = url.pathComponents
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentId, !contentId.isEmpty else { return }

        guard router.authState == .authenticated else {
            pendingDeepLink = url
            return
        }

        switch host {
        case "item":
            router.navigate(to: .itemDetail(contentId: contentId))
        case "play":
            Task { await routePlayDeepLink(contentId: contentId) }
        default:
            break
        }
    }

    #if os(tvOS)
    /// Consumes a fresh trailer handoff as soon as authentication resolves,
    /// before unrelated startup hydration can delay navigation. A queued deep
    /// link remains the priority launch intent, but the trailer record is still
    /// consumed so it cannot ghost-navigate a later launch.
    private func restoreTrailerReturnIfNeeded(hasPriorityLaunchIntent: Bool) {
        guard let contentId = TVTrailerReturnStore.shared.consumeColdLaunchRestore(),
              !hasPriorityLaunchIntent,
              router.path.isEmpty else {
            return
        }
        router.navigate(to: .itemDetail(contentId: contentId))
    }
    #endif

    @MainActor
    private func routePlayDeepLink(contentId: String) async {
        router.navigate(
            to: .player(
                contentId: contentId,
                startFromBeginning: false,
                resumePosition: nil
            )
        )
    }

    @ViewBuilder
    private var loginRoot: some View {
        #if os(tvOS)
        TVLoginView(router: router)
        #else
        LoginView(router: router)
        #endif
    }

    /// Determine the initial auth state with the smallest launch-time
    /// Keychain surface possible. The registry loads synchronously in `init`;
    /// TokenStore only needs to be retargeted to that active server before the
    /// first authenticated request lazily loads the full token cache.
    private func checkInitialState() async {
        #if DEBUG && os(iOS)
        if ProcessInfo.processInfo.environment["VIVID_SHOW_SERVER_SETUP"] == "1" {
            // Device testing can open the provider chooser without signing out
            // saved accounts or changing their Keychain/iCloud records.
            router.path = NavigationPath()
            pendingInitialAuthState = .needsServerSetup
            LaunchTimeline.recordInitialStateResolved(state: AppRouter.AuthState.needsServerSetup.diagnosticsState)
            finishInitialStartupIfReady()
            return
        }
        #endif
        #if os(iOS) || os(tvOS)
        #if DEBUG
        let shouldSyncCloudAccounts = ProcessInfo.processInfo.environment["VIVID_RESTART_SETUP"] != "1"
        #else
        let shouldSyncCloudAccounts = true
        #endif
        if shouldSyncCloudAccounts {
            do {
                try await KeychainReadFailure.retryTemporaryRead {
                    try ServerRegistry.shared.retryInitialRegistryReadIfNeeded()
                    #if os(tvOS)
                    try await TVSavedAccountStore.shared.restoreLocalSessionForLaunch()
                    #endif
                }
            } catch {
                didStartInitialStateCheck = false
                if !Task.isCancelled { showsCredentialReadError = true }
                return
            }
        }
        if shouldSyncCloudAccounts {
            let needsCloudBootstrap = TVSavedAccountStore.shared.accounts.isEmpty
                || ServerRegistry.shared.entries.isEmpty
            if needsCloudBootstrap {
                #if os(iOS)
                await VividCloudAccountSync.shared.synchronize(router: router)
                #endif
                // Apple TV offers explicit restoration from the server choices.
                // Failed mobile restoration also falls through to local setup.
            } else {
                // An existing installation can route immediately from its
                // local Keychain. The fetch still runs before any cloud write,
                // so remote deletion tombstones keep priority without adding
                // iCloud latency to every normal launch.
                Task { await VividCloudAccountSync.shared.synchronize(router: router) }
            }
        }
        #if os(tvOS)
        if !ServerRegistry.shared.entries.isEmpty {
            didCompleteProviderSetup = true
        }
        #endif
        #endif
        #if os(tvOS)
        #if DEBUG
        print("VIVID_SETUP_RESET_REQUESTED=\(ProcessInfo.processInfo.environment["VIVID_RESTART_SETUP"] == "1")")
        if ProcessInfo.processInfo.environment["VIVID_RESTART_SETUP"] == "1" {
            if let serverId = ServerRegistry.shared.activeServerId {
                await TokenStore.shared.retargetActiveServer(serverId: serverId)
            }
            if await TVSavedAccountStore.shared.signOutForSetup() {
                didCompleteProviderSetup = false
                UserDefaults.standard.removeObject(forKey: "vivid.didCompleteFirstLoginPreparation")
                router.path = NavigationPath()
                print("VIVID_SETUP_RESET_OK")
            } else {
                print("VIVID_SETUP_RESET_FAILED")
            }
        }
        #endif
        let needsProviderSetup = !didCompleteProviderSetup
        if !needsProviderSetup { TVSavedAccountStore.shared.prepareColdLaunch() }
        #else
        var needsProviderSetup = false
        #if os(iOS)
        #if DEBUG
        if ProcessInfo.processInfo.environment["VIVID_RESTART_SETUP"] == "1" {
            if let serverId = ServerRegistry.shared.activeServerId {
                await TokenStore.shared.retargetActiveServer(serverId:serverId)
            }
            needsProviderSetup = await TVSavedAccountStore.shared.signOutForSetup()
        }
        #endif
        if !needsProviderSetup { TVSavedAccountStore.shared.prepareColdLaunch() }
        #endif
        #endif
        let activeServerId = ServerRegistry.shared.activeServerId
        let hasStoredAccessToken: Bool
        if !needsProviderSetup, let activeServerId, !activeServerId.isEmpty {
            do {
                hasStoredAccessToken = try await KeychainReadFailure.retryTemporaryRead {
                    guard ServerRegistry.shared.activeServerId == activeServerId else {
                        throw HTTPError.requestIdentityChanged
                    }
                    return try await TokenStore.shared.hasAccessTokenForActiveServer(serverId: activeServerId)
                }
                guard ServerRegistry.shared.activeServerId == activeServerId else {
                    throw HTTPError.requestIdentityChanged
                }
            } catch {
                didStartInitialStateCheck = false
                if !Task.isCancelled {
                    if ServerRegistry.shared.activeServerId != activeServerId {
                        initialStateAttempt += 1
                    } else {
                        showsCredentialReadError = true
                    }
                }
                return
            }
        } else {
            hasStoredAccessToken = false
        }

        let api = AuthService.shared
        let targetState: AppRouter.AuthState
        if needsProviderSetup || !api.hasServer {
            targetState = .needsServerSetup
        } else if !hasStoredAccessToken {
            targetState = .needsLogin
        } else {
            targetState = await api.resolveActiveProfileForSession()
                ? .authenticated
                : .needsProfile
        }

        #if os(iOS) || os(tvOS)
        // The single most useful launch line: everything above it is Keychain
        // and profile resolution, everything below is the routed app. A cold
        // launch that stalls here (no server reachable, a wedged Keychain read)
        // shows as a long gap before this phase and nothing after it.
        LaunchTimeline.recordInitialStateResolved(state: targetState.diagnosticsState)
        #endif

        guard await StartupContentPrefetcher.prefetchForInitialRoute(targetState) else {
            didStartInitialStateCheck = false
            if !Task.isCancelled { initialStateAttempt += 1 }
            return
        }
        pendingInitialAuthState = targetState
        finishInitialStartupIfReady()

        #if DEBUG
        Task.detached(priority: .background) { await Self.logTopShelfDiagnostics() }
        #endif
    }

    private func finishInitialStartupIfReady() {
        guard router.authState == .loading,
              didFinishStartupSplash, let targetState = pendingInitialAuthState else { return }
        pendingInitialAuthState = nil
        #if os(iOS) || os(tvOS)
        // The splash, route resolution and tvOS Home preparation gates have
        // cleared, so this is the moment the user first sees
        // real content. `AppRouter` logs the auth transition itself; this line
        // records that launch reached a terminal, usable state at all.
        LaunchTimeline.recordFirstContent(state: targetState.diagnosticsState)
        #endif
        #if os(tvOS)
        if targetState == .needsServerSetup, didCompleteProviderSetup {
            router.path = NavigationPath([Route.serverSetup])
        }
        #endif
        router.authState = targetState
    }

    #if DEBUG
    /// Dumps the state the Top Shelf extension relies on, plus the last
    /// breadcrumb the extension wrote. tvOS captures main-app stdout only,
    /// so this is how we inspect the extension's view of the world
    /// post-hoc. Run off the critical launch path.
    private static func logTopShelfDiagnostics() async {
        let suite = SharedStorage.suite
        let accountKeychain = SharedKeychain(audience: SharedStorage.accountCredentialAudience)
        let profileKeychain = SharedKeychain(audience: .currentUser)
        let hasServerURL = suite.string(forKey: SharedStorage.serverUrlKey) != nil
        let hasProfileID = suite.string(forKey: SharedStorage.profileIdKey) != nil
        let hasAccess = accountKeychain.get(SharedStorage.mirroredAccessTokenAccount) != nil
        let hasProfile = profileKeychain.get(SharedStorage.mirroredProfileTokenAccount) != nil
        let lastRun = suite.string(forKey: SharedStorage.topShelfLastRunAtKey) ?? "<never>"
        let hasLastStatus = suite.string(forKey: SharedStorage.topShelfLastStatusKey) != nil
        print("[TopShelfDiag] hasServerURL=\(hasServerURL) hasProfileID=\(hasProfileID) mirroredAccess=\(hasAccess) mirroredProfile=\(hasProfile)")
        print("[TopShelfDiag] lastRunAt=\(lastRun) hasLastStatus=\(hasLastStatus)")
    }
    #endif

    #if DEBUG
    private func maybeAutoPlayForDebug() async {
        guard router.authState == .authenticated else { return }
        guard !didAttemptDebugAutoPlay else { return }

        if let searchQuery = debugPlaySearchQuery {
            didAttemptDebugAutoPlay = true

            do {
                debugPlayContentId = try await resolveDebugSearchContentId(query: searchQuery)
            } catch {
                print("[DebugPlaySearch] Failed to resolve the requested item")
            }
            return
        }

        guard CommandLine.arguments.contains("-debugPlayFirst") else { return }
        didAttemptDebugAutoPlay = true

        do {
            let sections = try await VividAPI.shared.homeSections()
            guard let contentId = sections.sections.lazy
                .compactMap({ $0.items.first?.contentId })
                .first else {
                return
            }
            debugPlayContentId = contentId
        } catch {
            print("[DebugPlayFirst] Failed to fetch home sections")
        }
    }

    private var debugPlaySearchQuery: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-debugPlaySearch"),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func debugLaunchArgValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debug: sign in from launch arguments, with the password accepted from
    /// `VIVID_DEBUG_PASSWORD` so physical-device runs do not expose it in the
    /// process arguments. Simulator fixtures may still pass `-debugPassword`.
    /// Selects the primary (or only) PIN-less profile.
    private func maybeDebugAutoLogin() async {
        let password = debugLaunchArgValue("-debugPassword")
            ?? ProcessInfo.processInfo.environment["VIVID_DEBUG_PASSWORD"]
        guard router.authState != .authenticated,
              let server = debugLaunchArgValue("-debugServer"),
              let username = debugLaunchArgValue("-debugUsername"),
              let password,
              !password.isEmpty else {
            return
        }
        do {
            _ = try await AuthService.shared.checkServer(url: server)
            try await AuthService.shared.login(username: username, password: password)
            let profiles = try await StartupContentPrefetcher.fetchProfiles()
            guard let profile = profiles.first(where: \.isPrimary)
                ?? (profiles.count == 1 ? profiles.first : nil) else {
                print("[DebugAutoLogin] no selectable profile")
                return
            }
            try await AuthService.shared.selectProfile(
                profileId: profile.id,
                requiresPIN: profile.hasPin
            )
            guard await StartupContentPrefetcher.prefetchAuthenticatedContent() else { return }
            #if os(iOS)
            DownloadSettings.shared.reloadForCurrentProfile()
                TVTMDbStore.shared.reloadForCurrentProfile()
            #endif
            await PlayerSettings.shared.reloadForCurrentProfile()
            router.resetToHome()
            print("[DebugAutoLogin] signed in and selected profile")
        } catch {
            print("[DebugAutoLogin] failed")
        }
    }

    private func resolveDebugSearchContentId(query: String) async throws -> String {
        let response = try await VividAPI.shared.catalog(query: [
            "source": "query",
            "q": query,
            "limit": "20",
            "offset": "0",
        ])

        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let preferredItem = response.items.first { item in
            item.type == "series" &&
            item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        } ?? response.items.first { item in
            item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        } ?? response.items.first

        guard let preferredItem else {
            throw DebugAutoPlayError.noSearchResults(query: query)
        }

        if preferredItem.type == "series" {
            let seasons = try await VividAPI.shared.seasons(seriesId: preferredItem.contentId)
            guard let firstSeason = seasons.seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }).first else {
                throw DebugAutoPlayError.noPlayableEpisode(seriesTitle: preferredItem.title)
            }

            let episodes = try await VividAPI.shared.episodes(
                seriesId: preferredItem.contentId,
                seasonNumber: firstSeason.seasonNumber
            )
            guard let firstEpisode = episodes.episodes
                .sorted(by: { $0.episodeNumber < $1.episodeNumber })
                .first else {
                throw DebugAutoPlayError.noPlayableEpisode(seriesTitle: preferredItem.title)
            }

            print("[DebugPlaySearch] Resolved an episode")
            return firstEpisode.contentId
        }

        print("[DebugPlaySearch] Resolved an item")
        return preferredItem.contentId
    }
    #endif

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .serverNeedsSetup:
            #if os(tvOS)
            TVServerNeedsSetupView(router: router)
            #else
            ServerNeedsSetupView(router: router)
            #endif
        case .login:
            loginRoot
        case .serverSetup:
            #if os(tvOS)
            TVServerSetupView(router: router, prefillCurrentServer: true)
            #else
            ServerSetupView(router: router)
            #endif
        default:
            // Routes handled inside the authenticated tab view
            EmptyStateView(
                icon: "hammer.fill",
                title: "Coming Soon",
                subtitle: "This screen is under construction."
            )
            .vividPageBackground()
        }
    }
}

func shouldPresentProfileSelectionAfterRecovery(
    isLoggedIn: Bool,
    activeProfileID: String?
) -> Bool {
    isLoggedIn && activeProfileID == nil
}

#if DEBUG
private struct DebugPlayerPresentationModifier: ViewModifier {
    let contentId: String?
    @Binding var isPresented: Bool
    let router: AppRouter
    let overlayPrefs: OverlayPrefsStore

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(isPresented: $isPresented) {
            player
        }
        #else
        content.fullScreenCover(isPresented: $isPresented) {
            player
        }
        #endif
    }

    @ViewBuilder
    private var player: some View {
        if let contentId {
            PlayerView(contentId: contentId)
                .environment(router)
                .environmentObject(overlayPrefs)
        }
    }
}

private enum DebugAutoPlayError: LocalizedError {
    case noPlayableEpisode(seriesTitle: String)
    case noSearchResults(query: String)

    var errorDescription: String? {
        switch self {
        case .noPlayableEpisode(let seriesTitle):
            return "No playable episode found for \(seriesTitle)"
        case .noSearchResults(let query):
            return "No search results found for \(query)"
        }
    }
}

#endif
