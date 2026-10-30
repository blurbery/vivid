#if os(iOS)
import SwiftUI

/// Sign-in on iPhone and iPad: the first-run sign-in for the active server,
/// or, with `adding`, the sign-in for a server being added from Settings.
struct LoginView: View {
    var router: AppRouter
    var adding: ServerProbe?

    @State private var form = SignInForm()
    @State private var codeSignIn = CodeSignIn()
    @State private var offeredService: CodeSignIn.Service?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case username, password
    }

    init(router: AppRouter, adding: ServerProbe? = nil) {
        self.router = router
        self.adding = adding
    }

    private var serverURL: String { adding?.url ?? AuthService.shared.serverUrl }

    var body: some View {
        AuroraScreen(variant: .signIn, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 26)
            heading
            card
        }
        .navigationBarBackButtonHidden(adding == nil)
        .onAppear { form.hasLeftPage = false }
        .onDisappear {
            codeSignIn.cancel()
            form.hasLeftPage = true
        }
        .task {
            let provider = adding?.provider ?? .active
            if let service = await SignInForm.offeredCodeService(for: provider, serverURL: serverURL) {
                offeredService = service
            }
        }
    }

    private var heading: some View {
        VStack(spacing: 10) {
            Text("Welcome back")
                .font(.vividTitle)
                .foregroundStyle(Color.auroraInk)
            if let host = SignInForm.hostLabel(for: serverURL) {
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
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            if codeSignIn.isActive {
                codePanel
            } else {
                passwordForm
            }
        }
        .padding(22)
        .auroraGlass(cornerRadius: 24, emphasized: true)
        .animation(.easeInOut(duration: 0.2), value: form.message)
        .animation(.easeInOut(duration: 0.2), value: codeSignIn.phase)
    }

    @ViewBuilder
    private var passwordForm: some View {
        AuroraTextField(
            label: "Username",
            text: $form.username,
            placeholder: "yourname",
            focus: $focusedField,
            equals: .username,
            contentType: .username,
            submitLabel: .next,
            onSubmit: { focusedField = .password }
        )
        AuroraTextField(
            label: Text("Password"),
            text: $form.password,
            placeholder: Text(verbatim: "••••••"),
            focus: $focusedField,
            equals: .password,
            isSecure: true,
            showsRevealToggle: true,
            contentType: .password,
            submitLabel: .go,
            onSubmit: signIn
        )
        if let message = form.message {
            AuroraErrorLabel(message)
        }
        Button(action: signIn) {
            form.isBusy ? Text("Signing in…") : Text("Sign in")
        }
        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: form.isBusy))
        .disabled(form.isBusy)
        .padding(.top, 4)
        if let service = offeredService {
            Button {
                startCodeSignIn(service)
            } label: {
                Text("Use \(service.title)")
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(form.isBusy)
        }
        if adding == nil {
            Button("Use a different server") {
                router.resetToServerSetup()
            }
            .buttonStyle(AuroraGhostButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(form.isBusy)
        }
    }

    @ViewBuilder
    private var codePanel: some View {
        let service = codeSignIn.service
        VStack(spacing: 8) {
            Text(verbatim: service.title)
                .font(.vividHeadline)
                .foregroundStyle(Color.auroraInk)
            Text(verbatim: service.instructions)
                .font(.vividBody)
                .foregroundStyle(Color.auroraInkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        if let code = codeSignIn.code {
            Text(verbatim: code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(8)
                .foregroundStyle(Color.auroraInk)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                .accessibilityLabel(service.codeAccessibilityLabel(code))
        }
        if let status = codeSignIn.status {
            HStack(spacing: 10) {
                ProgressView()
                Text(verbatim: status)
            }
            .font(.vividCaption)
            .foregroundStyle(Color.auroraInkSecondary)
            .frame(maxWidth: .infinity)
        }
        if let failure = codeSignIn.failure {
            AuroraErrorLabel(failure)
            Button {
                startCodeSignIn(service)
            } label: {
                Text(verbatim: service.getNewLabel)
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
        }
        Button("Use a password instead") {
            codeSignIn.cancel()
        }
        .buttonStyle(AuroraGhostButtonStyle())
        .frame(maxWidth: .infinity)
        .disabled(!codeSignIn.canCancel)
    }

    private func signIn() {
        if let adding {
            form.signIn(adding: adding, router: router)
        } else {
            form.signIn(router: router)
        }
    }

    private func startCodeSignIn(_ service: CodeSignIn.Service) {
        form.startCodeSignIn(service, with: codeSignIn, adding: adding, router: router)
    }
}
#endif
