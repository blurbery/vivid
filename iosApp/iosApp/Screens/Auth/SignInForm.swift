import Foundation

/// The sign-in form on iPhone, iPad and Apple TV: a password, or a code
/// approved on another device for Emby and Jellyfin.
@MainActor @Observable
final class SignInForm {
    var username = ""
    var password = ""
    private(set) var isBusy = false
    var message: String?
    #if os(iOS)
    /// Set while the Add Server sign-in page is off screen, so a credential
    /// check that finishes then is dropped.
    var hasLeftPage = false
    #endif

    private func credentialsProblem(for provider: MediaServerProvider) -> String? {
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(localized: "Please enter your username.")
        }
        if provider == .silo, password.isEmpty {
            return String(localized: "Please enter your password.")
        }
        return nil
    }

    /// First run: signs in to the active server, then prepares Home.
    func signIn(router: AppRouter) {
        guard !isBusy else { return }
        let provider = MediaServerProvider.active
        if let problem = credentialsProblem(for: provider) {
            message = problem
            return
        }
        isBusy = true
        message = nil
        let username = username, password = password
        Task {
            do {
                if provider == .silo {
                    try await AuthService.shared.login(username: username, password: password, defersSiloSignInRecord: true)
                    self.password = ""
                    #if os(iOS) || os(tvOS)
                    TVSavedAccountStore.shared.beginProfileChoice()
                    #endif
                } else {
                    try await AuthService.shared.login(username: username, password: password)
                    self.password = ""
                }
                await prepareHome(router: router)
            } catch {
                message = error.localizedDescription
            }
            isBusy = false
        }
    }

    /// Starts a code sign-in. First run uses the active server; Add Server
    /// uses the server that was found.
    func startCodeSignIn(_ service: CodeSignIn.Service, with flow: CodeSignIn, adding server: ServerProbe?, router: AppRouter) {
        message = nil
        #if os(iOS)
        if let server {
            startAddingWithCode(service, with: flow, server: server, router: router)
            return
        }
        #endif
        let serverURL = AuthService.shared.serverUrl
        switch service {
        case .jellyfinQuickConnect:
            flow.startQuickConnect(serverURL: serverURL) { login in
                do {
                    try await AuthService.shared.installQuickConnectSession(login, approvedAt: serverURL)
                } catch {
                    return error.localizedDescription
                }
                self.password = ""
                await self.prepareHome(router: router)
                return nil
            }
        case .embyConnect:
            flow.startEmbyConnect(serverURL: serverURL) { login in
                do {
                    try await AuthService.shared.installEmbyConnectSession(login, approvedAt: serverURL)
                } catch {
                    return error.localizedDescription
                }
                self.password = ""
                await self.prepareHome(router: router)
                return nil
            }
        }
    }

    /// Hands a first-run sign-in over to profile entry and Home preparation.
    private func prepareHome(router: AppRouter) async {
        #if os(iOS) || os(tvOS)
        await TVLoginPreparation.shared.begin(router: router, newSignIn: true)
        #endif
    }

    #if os(iOS)
    /// Add Server: checks the password with the found server first, and only
    /// then saves it as a new profile and switches to it.
    func signIn(adding server: ServerProbe, router: AppRouter) {
        guard !isBusy else { return }
        if let problem = credentialsProblem(for: server.provider) {
            message = problem
            return
        }
        let store = TVSavedAccountStore.shared
        guard store.canAddAccount else {
            message = String(localized: "You can save up to eight profiles. Delete a saved profile to add another.")
            return
        }
        isBusy = true
        message = nil
        let username = username, password = password
        Task {
            do {
                let verified = try await VerifiedServerLogin.signIn(
                    serverURL: server.url, provider: server.provider, username: username, password: password
                )
                if !hasLeftPage {
                    let added = await store.authenticate(
                        id: nil, serverURL: server.url, username: username, password: password, router: router,
                        provider: server.provider, verified: verified, serverName: server.fetchedName
                    )
                    if added { self.password = "" } else { message = store.error }
                }
            } catch {
                if !hasLeftPage { message = error.localizedDescription }
            }
            isBusy = false
        }
    }

    private func startAddingWithCode(_ service: CodeSignIn.Service, with flow: CodeSignIn, server: ServerProbe, router: AppRouter) {
        let fallback = String(localized: "Couldn’t finish signing in with \(service.title). Please try again.")
        let store = TVSavedAccountStore.shared
        switch service {
        case .jellyfinQuickConnect:
            flow.startQuickConnect(serverURL: server.url) { login in
                let added = await store.authenticate(
                    id: nil, serverURL: server.url, username: login.username, password: "", router: router,
                    provider: .jellyfin, quickConnect: login, serverName: server.fetchedName
                )
                return added ? nil : store.error ?? fallback
            }
        case .embyConnect:
            flow.startEmbyConnect(serverURL: server.url) { login in
                let added = await store.authenticate(
                    id: nil, serverURL: server.url, username: login.username, password: "", router: router,
                    provider: .emby, embyConnect: login, serverName: server.fetchedName
                )
                return added ? nil : store.error ?? fallback
            }
        }
    }
    #endif

    /// The host shown above the form: the address's host, or the address
    /// without its scheme when it doesn't parse.
    static func hostLabel(for address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let host = URL(string: text)?.host, !host.isEmpty { return host }
        return text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    /// The code sign-in to offer for `provider`, when its server has it.
    static func offeredCodeService(for provider: MediaServerProvider, serverURL: String) async -> CodeSignIn.Service? {
        guard let service = CodeSignIn.Service(provider),
              await CodeSignIn.isAvailable(service, serverURL: serverURL) else { return nil }
        return service
    }
}
