import SwiftUI

#if !os(tvOS)
/// Password-first sign-in on iOS and macOS; tvOS uses `TVLoginView`.
/// Jellyfin servers with Quick Connect turned on, and Emby servers through
/// Emby Connect, also offer a code approved somewhere else, for accounts
/// without a password.
struct LoginView: View {
    var router: AppRouter
    /// The server being added from Settings, before Vivid saves it or
    /// switches to it. This sign-in is then a page in Settings with a back
    /// button, and the current profile stays in use until it works.
    var adding: ServerProbe? = nil
    @State private var viewModel = LoginViewModel()
    @State private var codeSignIn = CodeSignIn()
    /// The code sign-in this server offers, once checked.
    @State private var codeService: CodeSignIn.Service?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)

            VStack(spacing: 10) {
                Text("Welcome back")
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                if let host = hostLabel {
                    Label(host, systemImage: "server.rack")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.auroraInkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .overlay(Capsule().stroke(Color.vividOutline, lineWidth: 1))
                }
                Text("Sign in to start watching.")
                    .font(.vividBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 18) {
                if codeSignIn.isActive {
                    codeSignInPanel
                } else {
                    passwordForm
                }
            }
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
            .animation(.easeInOut(duration: 0.2), value: viewModel.error)
            .animation(.easeInOut(duration: 0.2), value: codeSignIn.phase)
        }
        .navigationBarBackButtonHidden(adding == nil)
        .task {
            guard let service = CodeSignIn.Service(adding?.provider ?? MediaServerProvider.active),
                  await CodeSignIn.isAvailable(service, serverURL: serverURL) else { return }
            codeService = service
        }
        .onAppear { viewModel.leftSignIn = false }
        .onDisappear {
            codeSignIn.cancel()
            viewModel.leftSignIn = true
        }
    }

    /// The server this sign-in is for.
    private var serverURL: String { adding?.url ?? AuthService.shared.serverUrl }

    @ViewBuilder
    private var passwordForm: some View {
        AuroraTextField(
            label: "Username",
            text: $viewModel.username,
            placeholder: "yourname",
            focus: $focusedField,
            equals: .username,
            contentType: .username,
            submitLabel: .next,
            onSubmit: { focusedField = .password }
        )

        AuroraTextField(
            label: Text("Password"),
            text: $viewModel.password,
            placeholder: Text(verbatim: "••••••"),
            focus: $focusedField,
            equals: .password,
            isSecure: true,
            showsRevealToggle: true,
            contentType: .password,
            submitLabel: .go,
            onSubmit: { signIn() }
        )

        if let error = viewModel.error {
            AuroraErrorLabel(error)
        }

        Button {
            signIn()
        } label: {
            Text(viewModel.isLoading ? "Signing in…" : "Sign in")
        }
        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: viewModel.isLoading))
        .disabled(viewModel.isLoading)
        .padding(.top, 4)

        if let codeService {
            Button("Use \(codeService.title)") { startCodeSignIn(codeService) }
                .buttonStyle(AuroraGhostButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(viewModel.isLoading)
        }

        // Adding a server goes back to its address instead.
        if adding == nil {
            Button("Use a different server") { router.resetToServerSetup() }
                .buttonStyle(AuroraGhostButtonStyle())
                .frame(maxWidth: .infinity)
            .disabled(viewModel.isLoading)
        }
    }

    /// Quick Connect or Emby Connect: the code to approve somewhere else.
    @ViewBuilder
    private var codeSignInPanel: some View {
        VStack(spacing: 8) {
            Text(codeSignIn.service.title)
                .font(.vividHeadline)
                .foregroundStyle(Color.auroraInk)
            Text(codeSignIn.service.instructions)
                .font(.vividBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)

        if let code = codeSignIn.code {
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(8)
                .foregroundStyle(Color.auroraInk)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                .accessibilityLabel(codeSignIn.service.codeAccessibilityLabel(code))
        }

        if let status = codeSignIn.status {
            HStack(spacing: 10) {
                ProgressView()
                Text(status)
            }
            .font(.vividCaption)
            .foregroundStyle(Color.auroraInkSecondary)
            .frame(maxWidth: .infinity)
        }

        if let failure = codeSignIn.failure {
            AuroraErrorLabel(failure)
            Button(codeSignIn.service.getNewLabel) { startCodeSignIn(codeSignIn.service) }
                .buttonStyle(AuroraPrimaryButtonStyle())
        }

        Button("Use a password instead") { codeSignIn.cancel() }
            .buttonStyle(AuroraGhostButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(!codeSignIn.canCancel)
    }

    private func signIn() {
        guard !viewModel.isLoading else { return }
        if let adding {
            Task { await viewModel.signIn(adding: adding, router: router) }
        } else {
            Task { await viewModel.login(router: router) }
        }
    }

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        viewModel.error = nil
        if let adding {
            startAddingCodeSignIn(service, server: adding)
            return
        }
        let serverURL = AuthService.shared.serverUrl
        switch service {
        case .jellyfinQuickConnect:
            codeSignIn.startQuickConnect(serverURL: serverURL) { login in
                await viewModel.login(jellyfinQuickConnect: login, serverURL: serverURL, router: router)
            }
        case .embyConnect:
            codeSignIn.startEmbyConnect(serverURL: serverURL) { login in
                await viewModel.login(embyConnect: login, serverURL: serverURL, router: router)
            }
        }
    }

    /// A code approved for a server being added saves it as a new profile, as
    /// Add Profile in Settings does.
    private func startAddingCodeSignIn(_ service: CodeSignIn.Service, server: ServerProbe) {
        let store = TVSavedAccountStore.shared
        let fallback = String(localized: "Couldn’t finish signing in with \(service.title). Please try again.")
        switch service {
        case .jellyfinQuickConnect:
            codeSignIn.startQuickConnect(serverURL: server.url) { login in
                let success = await store.authenticate(id: nil, serverURL: server.url, username: login.username, password: "",
                                                       router: router, provider: .jellyfin, quickConnect: login,
                                                       serverName: server.fetchedName)
                return success ? nil : store.error ?? fallback
            }
        case .embyConnect:
            codeSignIn.startEmbyConnect(serverURL: server.url) { login in
                let success = await store.authenticate(id: nil, serverURL: server.url, username: login.username, password: "",
                                                       router: router, provider: .emby, embyConnect: login,
                                                       serverName: server.fetchedName)
                return success ? nil : store.error ?? fallback
            }
        }
    }

    /// Host pulled out of the server URL so the user sees which server
    /// they're signing into. Mirrors `TVLoginView.hostLabel`.
    private var hostLabel: String? {
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return host
        }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}
#endif
