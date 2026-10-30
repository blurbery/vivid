#if os(tvOS)
import SwiftUI

/// First-run sign-in on Apple TV: a password, or a code approved on another
/// device for Emby and Jellyfin.
struct TVLoginView: View {
    var router: AppRouter

    @State private var form = SignInForm()
    @State private var codeSignIn = CodeSignIn()
    @State private var offeredService: CodeSignIn.Service?
    @State private var showsPassword = false
    @FocusState private var focusedTarget: Target?

    private enum Target: Hashable {
        case username, password, reveal, signIn, offer, usePassword, newCode, otherServer
    }

    init(router: AppRouter) {
        self.router = router
    }

    private var host: String? { SignInForm.hostLabel(for: AuthService.shared.serverUrl) }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    VividLogoView(size: 96)
                    if let host {
                        Label(host, systemImage: "server.rack")
                            .font(.vividCaption)
                            .foregroundStyle(Color.auroraInkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 28)
                card
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 108)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            VividCopyrightFooter()
                .padding(.bottom, 40)
        }
        .ignoresSafeArea()
        .onAppear { focusedTarget = .username }
        .onDisappear { codeSignIn.cancel() }
        .task {
            if let service = await SignInForm.offeredCodeService(for: .active, serverURL: AuthService.shared.serverUrl) {
                offeredService = service
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 24) {
            if codeSignIn.isActive {
                codeFields
            } else {
                passwordFields
            }
            bottomRow
        }
        .padding(48)
        .frame(maxWidth: 780, alignment: .leading)
        .auroraGlass(cornerRadius: 30)
        .animation(.easeInOut(duration: 0.2), value: form.message)
        .animation(.easeInOut(duration: 0.2), value: codeSignIn.phase)
        .focusSection()
    }

    @ViewBuilder
    private var passwordFields: some View {
        Text("Sign in with a password")
            .font(.vividTitle)
            .foregroundStyle(Color.auroraInk)
        if let host {
            Text("Use the account credentials for \(host).")
                .font(.vividBody)
                .foregroundStyle(Color.auroraInkSecondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            TVFieldLabel(text: String(localized: "Username"))
            AuroraInputField(
                text: $form.username,
                placeholder: "yourname",
                inputTitle: "Username",
                focus: $focusedTarget,
                equals: .username,
                isSecure: false,
                contentType: .username,
                keyboard: .default
            )
            .submitLabel(.next)
            .onSubmit { moveFocus(to: .password) }
        }
        VStack(alignment: .leading, spacing: 10) {
            TVFieldLabel(text: String(localized: "Password"))
            HStack(spacing: 12) {
                AuroraInputField(
                    text: $form.password,
                    placeholder: Self.passwordPlaceholder,
                    inputTitle: String(localized: "Password"),
                    focus: $focusedTarget,
                    equals: .password,
                    isSecure: !showsPassword,
                    contentType: .password,
                    keyboard: .default
                )
                .submitLabel(.done)
                .onSubmit { moveFocus(to: .signIn) }
                Button {
                    showsPassword.toggle()
                } label: {
                    Image(systemName: showsPassword ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 22, weight: .medium))
                }
                .buttonStyle(TVIconButtonStyle())
                .accessibilityLabel(showsPassword ? Text("Hide password") : Text("Show password"))
                .disabled(focusedTarget != .password && focusedTarget != .reveal)
                .focused($focusedTarget, equals: .reveal)
            }
        }
        if let message = form.message {
            TVFormMessage(text: message)
                .transition(.opacity)
        }
        Button {
            form.signIn(router: router)
        } label: {
            form.isBusy ? Text("Signing in…") : Text("Sign in")
        }
        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: form.isBusy))
        .padding(.top, 4)
        .focused($focusedTarget, equals: .signIn)
    }

    @ViewBuilder
    private var codeFields: some View {
        let service = codeSignIn.service
        Text("Sign in with \(service.title)")
            .font(.vividTitle)
            .foregroundStyle(Color.auroraInk)
        Text(verbatim: service.instructions)
            .font(.vividBody)
            .foregroundStyle(Color.auroraInkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let code = codeSignIn.code {
            Text(verbatim: code)
                .font(.system(size: 76, weight: .semibold, design: .monospaced))
                .tracking(14)
                .foregroundStyle(Color.auroraInk)
                .accessibilityLabel(service.codeAccessibilityLabel(code))
        }
        if let status = codeSignIn.status {
            HStack(spacing: 14) {
                ProgressView()
                Text(verbatim: status)
                    .font(.vividCaption)
                    .foregroundStyle(Color.auroraInkSecondary)
            }
        }
        if let failure = codeSignIn.failure {
            TVFormMessage(text: failure)
                .transition(.opacity)
            Button {
                startCodeSignIn(service)
            } label: {
                Text(verbatim: service.getNewLabel)
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .focused($focusedTarget, equals: .newCode)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 18) {
            if codeSignIn.isActive {
                // Stays enabled so focus isn't pushed off the button while
                // an approved code finishes signing in.
                Button("Use a password instead") {
                    guard codeSignIn.canCancel else { return }
                    codeSignIn.cancel()
                    moveFocus(to: .offer)
                }
                .buttonStyle(AuroraGhostButtonStyle())
                .focused($focusedTarget, equals: .usePassword)
            } else if let service = offeredService {
                Button {
                    startCodeSignIn(service)
                    moveFocus(to: .usePassword)
                } label: {
                    Text("Use \(service.title)")
                }
                .buttonStyle(AuroraGhostButtonStyle())
                .disabled(form.isBusy)
                .focused($focusedTarget, equals: .offer)
            }
            Button("Use another server") {
                router.resetToServerSetup()
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .focused($focusedTarget, equals: .otherServer)
        }
        .padding(.top, 6)
    }

    private static let passwordPlaceholder: String = "••••••"

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        form.startCodeSignIn(service, with: codeSignIn, adding: nil, router: router)
    }

    /// Moves focus once the current update has finished, so the target
    /// exists by then.
    private func moveFocus(to target: Target) {
        Task { @MainActor in focusedTarget = target }
    }
}

/// The show or hide password button: a small square that fills in when
/// focused.
private struct TVIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButton(configuration: configuration)
    }

    private struct IconButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: VividTheme.cornerRadius)
            configuration.label
                .frame(width: 56, height: 56)
                .foregroundStyle(isFocused ? Color.vividBackground : Color.white.opacity(0.7))
                .background {
                    shape
                        .fill(isFocused ? Color.vividOnSurface : Color.vividSurfaceVariant)
                        .overlay(shape.stroke(isFocused ? Color.clear : Color.vividOutline, lineWidth: 1))
                }
                .scaleEffect(isFocused ? 1.04 : 1)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .focusEffectDisabled()
                .animation(VividTheme.springAnimation, value: isFocused)
        }
    }
}
#endif
