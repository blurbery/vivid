#if os(tvOS)
import SwiftUI

/// Username and password sign-in shared by the supported tvOS providers.
/// Jellyfin servers with Quick Connect turned on, and Emby servers through
/// Emby Connect, also offer a code approved somewhere else, for accounts
/// without a password.
struct TVLoginView: View {
    var router: AppRouter

    @State private var loginVM = LoginViewModel()
    @State private var codeSignIn = CodeSignIn()
    /// The code sign-in this server offers, once checked.
    @State private var codeService: CodeSignIn.Service?
    @State private var showPassword: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case changeServer
        case username
        case password
        case togglePassword
        case signIn
        case codeSignIn
        case usePassword
        case newCode
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            passwordContent
                .padding(.horizontal, 108)
                .padding(.top, 64)
                .padding(.bottom, 64)
        }
        .task { focusedField = .username }
        .task {
            guard let service = CodeSignIn.Service(MediaServerProvider.active),
                  await CodeSignIn.isAvailable(service, serverURL: AuthService.shared.serverUrl) else { return }
            codeService = service
        }
        .onDisappear { codeSignIn.cancel() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter().padding(.bottom, 40)
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            VividLogoView(size: 96)
            if let host = hostLabel {
                Label(host, systemImage: "server.rack")
                    .font(.vividCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sign-in form

    private var passwordContent: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 24) {
                if codeSignIn.isActive {
                    codeSignInFields
                } else {
                    passwordFields
                }

                HStack(spacing: 18) {
                    if codeSignIn.isActive {
                        Button {
                            codeSignIn.cancel()
                            // The pressed button is gone; its replacement takes focus.
                            moveFocusAfterUpdate(to: .codeSignIn)
                        } label: {
                            Text("Use a password instead")
                        }
                        .buttonStyle(AuroraGhostButtonStyle())
                        .focused($focusedField, equals: .usePassword)
                    } else if let codeService {
                        Button {
                            startCodeSignIn(codeService)
                            moveFocusAfterUpdate(to: .usePassword)
                        } label: {
                            Text("Use \(codeService.title)")
                        }
                        .buttonStyle(AuroraGhostButtonStyle())
                        .focused($focusedField, equals: .codeSignIn)
                        .disabled(loginVM.isLoading)
                    }

                    Button {
                        router.resetToServerSetup()
                    } label: {
                        Text("Use another server")
                    }
                    .buttonStyle(AuroraGhostButtonStyle())
                    .focused($focusedField, equals: .changeServer)
                }
                .padding(.top, 6)
            }
            .padding(48)
            .frame(maxWidth: 780, alignment: .leading)
            .auroraGlass(cornerRadius: 30)
            .animation(.easeInOut(duration: 0.2), value: loginVM.error)
            .animation(.easeInOut(duration: 0.2), value: codeSignIn.phase)
            .focusSection()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var passwordFields: some View {
        Text("Sign in with a password")
            .font(.vividTitle)
            .foregroundStyle(Color.auroraInk)
        if let host = hostLabel {
            Text("Use the account credentials for \(host).")
                .font(.vividBody)
                .foregroundStyle(Color.auroraInkSecondary)
        }

        fieldGroup(label: "Username") {
            AuroraInputField(
                text: $loginVM.username,
                placeholder: "yourname",
                inputTitle: "Username",
                focus: $focusedField,
                equals: .username,
                contentType: .username
            )
            // Advance to the password field once the username is entered.
            .submitLabel(.next)
            .onSubmit { moveFocusAfterUpdate(to: .password) }
        }

        fieldGroup(label: "Password") {
            HStack(spacing: 12) {
                AuroraInputField(
                    text: $loginVM.password,
                    placeholder: "••••••",
                    inputTitle: "Password",
                    focus: $focusedField,
                    equals: .password,
                    isSecure: !showPassword,
                    contentType: .password
                )
                // Hand focus to the Sign In button once the password is entered.
                .submitLabel(.done)
                .onSubmit { moveFocusAfterUpdate(to: .signIn) }

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 22, weight: .medium))
                }
                .buttonStyle(TVAuthIconButtonStyle())
                .focused($focusedField, equals: .togglePassword)
                .disabled(!canFocusPasswordToggle)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
        }

        if let error = loginVM.error {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.requestRose)
                Text(error)
                    .font(.vividCaption)
                    .foregroundStyle(Color.requestRose)
            }
            .transition(.opacity)
        }

        Button {
            guard !loginVM.isLoading else { return }
            Task { await loginVM.login(router: router) }
        } label: {
            Text(loginVM.isLoading ? "Signing in…" : "Sign in")
        }
        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: loginVM.isLoading))
        .focused($focusedField, equals: .signIn)
        .padding(.top, 4)
    }

    /// Quick Connect or Emby Connect: the code to approve somewhere else.
    @ViewBuilder
    private var codeSignInFields: some View {
        Text("Sign in with \(codeSignIn.service.title)")
            .font(.vividTitle)
            .foregroundStyle(Color.auroraInk)
        Text(codeSignIn.service.instructions)
            .font(.vividBody)
            .foregroundStyle(Color.auroraInkSecondary)
            .fixedSize(horizontal: false, vertical: true)

        if let code = codeSignIn.code {
            Text(code)
                .font(.system(size: 76, weight: .semibold, design: .monospaced))
                .tracking(14)
                .foregroundStyle(Color.auroraInk)
                .accessibilityLabel("\(codeSignIn.service.title) code \(code.map(String.init).joined(separator: " "))")
        }

        if let status = codeSignIn.status {
            HStack(spacing: 14) {
                ProgressView()
                Text(status)
                    .font(.vividCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
        }

        if let failure = codeSignIn.failure {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.requestRose)
                Text(failure)
                    .font(.vividCaption)
                    .foregroundStyle(Color.requestRose)
            }
            .transition(.opacity)

            Button {
                startCodeSignIn(codeSignIn.service)
            } label: {
                Text(codeSignIn.service == .embyConnect ? "Get a new PIN" : "Get a new code")
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .focused($focusedField, equals: .newCode)
        }
    }

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        loginVM.error = nil
        let serverURL = AuthService.shared.serverUrl
        switch service {
        case .jellyfinQuickConnect:
            codeSignIn.startQuickConnect(serverURL: serverURL) { login in
                await loginVM.login(jellyfinQuickConnect: login, serverURL: serverURL, router: router)
            }
        case .embyConnect:
            codeSignIn.startEmbyConnect(serverURL: serverURL) { login in
                await loginVM.login(embyConnect: login, serverURL: serverURL, router: router)
            }
        }
    }

    @ViewBuilder
    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.auroraInkTertiary)
            content()
        }
    }

    // MARK: - Computed helpers

    /// "yourserver.local" pulled out of the stored URL so the user knows
    /// which server they're signing into without a full URL on display.
    private var hostLabel: String? {
        let url = AuthService.shared.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        if let parsed = URL(string: url), let host = parsed.host, !host.isEmpty {
            return host
        }
        return url.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private var canFocusPasswordToggle: Bool {
        focusedField == .password || focusedField == .togglePassword
    }

    /// Waits a turn so a control shown by the same update exists to take focus.
    private func moveFocusAfterUpdate(to field: Field) {
        Task { @MainActor in
            await Task.yield()
            focusedField = field
        }
    }

}

// MARK: - Local button styles

/// Square icon-only focus affordance for the password show/hide toggle.
struct TVAuthIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVAuthIconButtonBody(configuration: configuration)
    }
}

private struct TVAuthIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Color.vividBackground : Color.white.opacity(0.7))
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                    .fill(isFocused ? Color.vividOnSurface : Color.vividSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
                            .stroke(
                                isFocused ? Color.clear : Color.vividOutline,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .focusEffectDisabled()
            .animation(VividTheme.springAnimation, value: isFocused)
    }
}

#endif
