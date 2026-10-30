#if os(tvOS)
import SwiftUI

/// Shown when the server is reachable but its administrator hasn't finished
/// setting it up: check again, or pick another server.
struct TVServerNeedsSetupView: View {
    var router: AppRouter

    @State private var isChecking = false
    @State private var message: String?
    @State private var checkTask: Task<Void, Never>?
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable {
        case check
        case change
    }

    init(router: AppRouter) {
        self.router = router
    }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VividLogoView(size: 96)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 48)
                card
                Spacer()
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: message)
        .onDisappear(perform: cancelCheck)
    }

    private var card: some View {
        VStack(spacing: 28) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(Color.auroraAccent)
            VStack(spacing: 14) {
                AuroraEyebrow(text: "Server setup", centered: true)
                Text("Server setup required")
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                Text("Ask the server administrator to finish setup. When it is ready, check again.")
                    .font(.vividBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.vividCaption)
                    .foregroundStyle(Color.requestRose)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Error: \(message)"))
            }
            HStack(spacing: 24) {
                Button(action: checkAgain) {
                    if isChecking {
                        Label("Checking…", systemImage: "arrow.clockwise")
                    } else {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isChecking))
                .disabled(isChecking)
                .focused($focusedAction, equals: .check)

                Button("Change server", action: changeServer)
                    .buttonStyle(AuroraGhostButtonStyle())
                    .focused($focusedAction, equals: .change)
            }
            .focusSection()
            .defaultFocus($focusedAction, .check, priority: .userInitiated)
        }
        .padding(56)
        .frame(width: 820)
        .auroraGlass(cornerRadius: 30, emphasized: true)
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
                message = String(localized: "Could not reach the server. Check that it is running and try again.")
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
