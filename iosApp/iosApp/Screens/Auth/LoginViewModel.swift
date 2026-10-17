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
            error = "Please enter your username."
            return
        }
        guard !password.isEmpty || MediaServerProvider.active.usesNativeUser else {
            error = "Please enter your password."
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

    private func finishSignIn(router: AppRouter) async {
        #if os(tvOS) || os(iOS)
        await TVLoginPreparation.shared.begin(router: router, newSignIn: true)
        #else
        await StartupContentPrefetcher.prefetchProfiles()
        router.showProfileSelection()
        #endif
    }
}
