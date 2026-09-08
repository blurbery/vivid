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
        guard !password.isEmpty || MediaServerProvider.active == .emby else {
            error = "Please enter your password."
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await auth.login(username: username, password: password)
            #if os(tvOS) || os(iOS)
            password = ""
            await TVLoginPreparation.shared.begin(router: router)
            #else
            await StartupContentPrefetcher.prefetchProfiles()
            router.showProfileSelection()
            #endif
        } catch let loginError {
            self.error = loginError.localizedDescription
        }
    }
}
