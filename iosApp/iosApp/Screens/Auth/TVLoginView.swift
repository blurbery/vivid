#if os(tvOS)
import SwiftUI

/// Username and password sign-in shared by the supported tvOS providers.
struct TVLoginView: View {
    var router: AppRouter

    @State private var loginVM = LoginViewModel()
    @State private var showPassword: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case changeServer
        case username
        case password
        case togglePassword
        case signIn
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            passwordContent
                .padding(.horizontal, 108)
                .padding(.top, 64)
                .padding(.bottom, 64)
        }
        .task { focusedField = .username }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
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
                    .onSubmit { moveFocusAfterTextEntry(to: .password) }
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
                        .onSubmit { moveFocusAfterTextEntry(to: .signIn) }

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

                HStack(spacing: 18) {
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
            .focusSection()
            Spacer(minLength: 0)
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

    private func moveFocusAfterTextEntry(to field: Field) {
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
