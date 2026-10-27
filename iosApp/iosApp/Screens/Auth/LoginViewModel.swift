import Foundation

@Observable
class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    var error: String?

    private let auth = AuthService.shared

    /// Authenticate with username and password.
    func login(router: AppRouter) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = String(localized: "Please enter your username.")
            return
        }
        guard !password.isEmpty || MediaServerProvider.active.usesNativeUser else {
            error = String(localized: "Please enter your password.")
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            #if os(tvOS) || os(iOS)
            let isSilo = MediaServerProvider.active == .silo
            try await auth.login(username: username, password: password, defersSiloSignInRecord: isSilo)
            password = ""
            // A Silo sign-in becomes a saved profile, and records the sign-in,
            // once its viewing profile is entered.
            if isSilo { await TVSavedAccountStore.shared.beginProfileChoice() }
            #else
            try await auth.login(username: username, password: password)
            #endif
            await finishSignIn(router: router)
        } catch let loginError {
            self.error = loginError.localizedDescription
        }
    }

    #if os(iOS)
    /// Set when the person goes back from an Add Server sign-in, so a password
    /// check still running doesn't switch servers after they've left.
    var leftSignIn = false

    /// Adding a server from Settings. The server checks the password before
    /// Vivid saves or switches to anything, so a wrong one shows here and the
    /// current profile stays in use until the sign-in works.
    func signIn(adding server: ServerProbe, router: AppRouter) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = String(localized: "Please enter your username.")
            return
        }
        guard !password.isEmpty || server.provider.usesNativeUser else {
            error = String(localized: "Please enter your password.")
            return
        }
        guard await TVSavedAccountStore.shared.canAddAccount else {
            error = String(localized: "You can save up to eight profiles. Delete a saved profile to add another.")
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let verified = try await VerifiedServerLogin.signIn(serverURL: server.url, provider: server.provider,
                                                                username: username, password: password)
            guard !leftSignIn else { return }
            // Keeps the name the server gave, which the saved profile doesn't carry.
            _ = ServerRegistry.shared.addOrUpdate(ServerEntry(id: server.id, url: server.url,
                                                              fetchedName: server.fetchedName, lastUsedAt: Date()))
            let store = await TVSavedAccountStore.shared
            if await store.authenticate(id: nil, serverURL: server.url, username: username, password: password,
                                        router: router, provider: server.provider, verified: verified) {
                password = ""
            } else {
                error = await store.error
            }
        } catch let loginError {
            self.error = loginError.localizedDescription
        }
    }
    #endif

    /// Finishes a Jellyfin Quick Connect sign-in. Returns a message to show
    /// when the approved session couldn't be saved.
    func login(jellyfinQuickConnect login: JellyfinLogin, serverURL: String, router: AppRouter) async -> String? {
        do {
            try await auth.login(jellyfinQuickConnect: login, serverURL: serverURL)
            password = ""
            await finishSignIn(router: router)
            return nil
        } catch let loginError {
            return loginError.localizedDescription
        }
    }

    /// Finishes an Emby Connect sign-in. Returns a message to show when the
    /// session couldn't be saved.
    func login(embyConnect login: EmbyLogin, serverURL: String, router: AppRouter) async -> String? {
        do {
            try await auth.login(embyConnect: login, serverURL: serverURL)
            password = ""
            await finishSignIn(router: router)
            return nil
        } catch let loginError {
            return loginError.localizedDescription
        }
    }

    private func finishSignIn(router: AppRouter) async {
        #if os(tvOS) || os(iOS)
        await TVLoginPreparation.shared.begin(router: router, newSignIn: true)
        #else
        await StartupContentPrefetcher.prefetchProfiles()
        router.showProfileSelection()
        #endif
    }
}
