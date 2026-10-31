import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// The app's root: the launch splash, then whichever screen the sign-in
/// state calls for. Everything below the two identity keys is rebuilt when
/// the active server or saved profile changes; the startup check and the
/// observers sit outside them and are never restarted by a rebuild.
struct ContentView: View {
    @State private var model = AppRootModel()
    @StateObject private var overlayPrefs = OverlayPrefsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {}

    private var router: AppRouter { model.router }

    /// How long the splash takes to hand over to the first screen.
    private var handoffDuration: Double { reduceMotion ? 0.2 : 0.55 }

    var body: some View {
        @Bindable var model = model
        savedProfileKeyedContent
            .onOpenURL { url in
                NotificationCenter.default.post(name: .vividDeepLink, object: nil, userInfo: ["url": url])
            }
            .task(id: model.startupAttempt) {
                await model.runStartupCheckIfNeeded()
            }
            .sheet(isPresented: $model.showsCloudRestore) {
                TVCloudRestoreView(onRestored: model.cloudRestoreFinished)
                    .vividGlassSheet(startsTall: true)
            }
            .environmentObject(overlayPrefs)
            .preferredColorScheme(.dark)
            .progressViewStyle(VividLoadingProgressStyle())
            .onReceive(NotificationCenter.default.publisher(for: .vividDeepLink)) { notification in
                model.receiveDeepLink(notification)
            }
            .onAppear {
                model.rootViewAppeared()
            }
            .onReceive(NotificationCenter.default.publisher(for: .vividSessionExpired).receive(on: DispatchQueue.main)) { notification in
                model.sessionDidExpire(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .vividProfileSelectionRequired).receive(on: DispatchQueue.main)) { _ in
                model.profileSelectionDidBecomeRequired()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                LaunchTimeline.recordMemoryWarning(scenePhase.timelineToken)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                LaunchTimeline.recordTermination(scenePhase.timelineToken)
            }
            #if os(tvOS)
            .onChange(of: router.authState, initial: true) {
                model.noteProviderSetupIfComplete()
            }
            #endif
            .task(id: pluginSyncKey(MDBListSyncStore.shared.contextKey)) {
                await model.syncMDBList(scenePhase: scenePhase)
            }
            .task(id: pluginSyncKey(SimklSyncStore.shared.contextKey)) {
                await model.syncSimkl(scenePhase: scenePhase)
            }
            .task(id: router.authState) {
                await model.authStateChanged()
            }
            .task(id: ServerRegistry.shared.activeProfileId) {
                await model.activeProfileChanged()
            }
            .task(id: ServerRegistry.shared.activeServerId) {
                await model.activeServerChanged()
            }
            .onChange(of: scenePhase) { _, phase in
                model.scenePhaseChanged(to: phase)
            }
            #if os(iOS)
            .onChange(of: PictureInPictureCoordinator.shared.isEngaged) {
                // Picture in Picture starting stops the away clock; ending
                // while hidden starts a fresh interval.
                if scenePhase == .background { model.applyBackgroundAwayClock() }
            }
            #endif
    }

    private func pluginSyncKey(_ contextKey: String) -> String {
        "\(contextKey)|\(scenePhase.timelineToken)|\(router.authState.diagnosticsState)"
    }

    // MARK: Identity layers

    private var savedProfileKeyedContent: some View {
        serverKeyedContent
            #if os(tvOS)
            .background { TVAppBackdrop() }
            #endif
            .id(TVSavedAccountStore.shared.contentRevision)
    }

    private var serverKeyedContent: some View {
        @Bindable var model = model
        return launchStack
            .environment(router)
            .alert("Saved login unavailable", isPresented: $model.showsCredentialAlert) {
                Button("Retry") { model.retryStartup() }
            } message: {
                Text("Vivid couldn’t read your saved login from Keychain. Your saved account has not been removed. Try again.")
            }
            .id(ServerRegistry.shared.activeServerId)
    }

    // MARK: Launch

    private var launchStack: some View {
        ZStack {
            routedContent
                .animation(.easeInOut(duration: 0.6 * handoffDuration).delay(0.4 * handoffDuration)) { content in
                    content.opacity(model.splashFinished ? 1 : 0)
                }
                .disabled(model.showsSplashOverlay)
                .accessibilityHidden(model.showsSplashOverlay)

            if model.showsSplashOverlay {
                VividStartupView(
                    isContentReady: model.pendingInitialState != nil,
                    isLoading: model.isStartupCheckRunning && !model.showsCredentialAlert,
                    onCompletion: model.splashDidFinish
                )
                .animation(.easeInOut(duration: 0.4 * handoffDuration)) { splash in
                    splash
                        .opacity(model.splashFinished ? 0 : 1)
                        .scaleEffect(model.splashFinished && !reduceMotion ? 0.96 : 1)
                }
                .zIndex(1)
            }
        }
        .background { VividAppBackdrop() }
        .task(id: model.splashFinished) {
            await model.removeSplashAfterHandoff(duration: handoffDuration)
        }
    }

    // MARK: Routing

    #if os(tvOS)
    @ViewBuilder
    private var routedContent: some View {
        if TVLoginPreparation.shared.isPresented {
            TVLoginPreparationView()
        } else if TVSavedAccountStore.shared.busy {
            ZStack {
                Color.clear.ignoresSafeArea()
                VividLoadingDots()
            }
        } else if model.didCompleteProviderSetup, isPastSetup, TVSavedAccountStore.shared.showsSelector {
            TVSavedProfilesScreen(router: router)
        } else {
            switch router.authState {
            case .loading:
                Color.clear.ignoresSafeArea()
            case .needsServerSetup, .needsLogin:
                signedOutStack {
                    TVProviderSelectionView(onRestore: { model.showsCloudRestore = true })
                }
                .toolbar(.hidden, for: .navigationBar)
            case .needsProfile:
                Color.clear.ignoresSafeArea()
                    .onAppear { model.beginLoginPreparation() }
            case .authenticated:
                TVMainTabView(router: router)
            }
        }
    }
    #else
    @ViewBuilder
    private var routedContent: some View {
        if TVLoginPreparation.shared.isPresented {
            TVLoginPreparationView()
        } else if TVSavedAccountStore.shared.busy {
            ZStack {
                VividAppBackdrop()
                VividLoadingDots()
            }
        } else if isPastSetup, TVSavedAccountStore.shared.showsSelector {
            PhoneSavedProfilesScreen()
        } else {
            switch router.authState {
            case .loading:
                VividAppBackdrop()
            case .needsServerSetup:
                signedOutStack {
                    PhoneProviderSelectionView(router: router, onRestore: { model.showsCloudRestore = true })
                }
            case .needsLogin:
                signedOutStack {
                    LoginView(router: router)
                }
            case .needsProfile:
                VividAppBackdrop()
                    .onAppear { model.beginLoginPreparation() }
            case .authenticated:
                MainTabView(router: router)
            }
        }
    }
    #endif

    private var isPastSetup: Bool {
        router.authState != .loading && router.authState != .needsServerSetup
    }

    private func signedOutStack<Root: View>(@ViewBuilder root: () -> Root) -> some View {
        @Bindable var router = router
        return NavigationStack(path: $router.path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    signedOutDestination(route)
                }
        }
    }

    @ViewBuilder
    private func signedOutDestination(_ route: Route) -> some View {
        switch route {
        case .serverNeedsSetup:
            #if os(tvOS)
            TVServerNeedsSetupView(router: router)
            #else
            ServerNeedsSetupView(router: router)
            #endif
        #if os(tvOS)
        case .login:
            TVLoginView(router: router)
        case .serverSetup:
            TVServerSetupView(router: router, prefillCurrentServer: true)
        #endif
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .vividPageBackground()
        }
    }
}
