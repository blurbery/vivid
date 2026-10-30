#if os(iOS)
import SwiftUI

/// Shown on iPhone and iPad when the server answers but its administrator
/// hasn't finished setting it up: check again, or pick another server.
struct ServerNeedsSetupView: View {
    var router: AppRouter

    @State private var isChecking = false
    @State private var message: String?
    @State private var checkTask: Task<Void, Never>?

    init(router: AppRouter) {
        self.router = router
    }

    var body: some View {
        AuroraScreen(variant: .server, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            AuroraEyebrow(text: "Server setup", centered: true)
                .padding(.bottom, 16)
            badge
            VStack(spacing: 12) {
                Text("This server isn't ready")
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text("Ask the server administrator to finish setup. When it's ready, return here and check again.")
                    .font(.vividBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)
            card
        }
        .navigationBarBackButtonHidden(true)
        .onDisappear(perform: cancelCheck)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(Color.auroraAccent.opacity(0.14))
            Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
            Image(systemName: "gearshape.2")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.auroraAccent)
        }
        .frame(width: 78, height: 78)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }

    private var card: some View {
        VStack(spacing: 16) {
            if let message {
                AuroraErrorLabel(message)
            }
            Button(action: checkAgain) {
                isChecking ? Text("Checking…") : Text("Check again")
            }
            .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
            .disabled(isChecking)
            Button("Change server", action: changeServer)
                .buttonStyle(AuroraGhostButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .padding(22)
        .auroraGlass(cornerRadius: 24, emphasized: true)
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    private func checkAgain() {
        guard !isChecking else { return }
        isChecking = true
        message = nil
        let serverURL = AuthService.shared.serverUrl
        checkTask = Task {
            do {
                let status = try await AuthService.shared.checkServer(url: serverURL)
                isChecking = false
                guard !Task.isCancelled, AuthService.shared.serverUrl == serverURL else { return }
                if status.needsSetup {
                    message = String(localized: "This server still needs administrator setup.")
                } else {
                    router.goBack()
                }
            } catch {
                isChecking = false
                guard !Task.isCancelled else { return }
                message = String(localized: "Couldn't reach the server. Check it's running and try again.")
            }
        }
    }

    private func changeServer() {
        cancelCheck()
        router.resetToServerSetup()
    }

    private func cancelCheck() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
    }
}
#endif
