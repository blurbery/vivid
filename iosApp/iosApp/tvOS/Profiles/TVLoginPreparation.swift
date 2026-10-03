#if os(tvOS) || os(iOS)
import SwiftUI
import OSLog

/// Why login preparation stopped, mapped to the recovery the user can take.
/// Each case names the real cause so a dead server, an expired sign-in and a
/// mistyped PIN no longer share one generic message.
enum LoginPreparationFailure: Equatable {
    case offline
    case unreachable
    case wrongPIN
    case tooManyAttempts
    case signInExpired
    case serverError
    case unexpectedResponse
    case noPrimaryProfile
    case unknown

    static func classify(_ error: Error, enteredPIN: Bool) -> LoginPreparationFailure {
        var error = error
        if case HTTPError.network(let underlying) = error { error = underlying }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default:
                return .unreachable
            }
        }
        let status: Int?
        if case HTTPError.http(let code, _) = error {
            status = code
        } else if case APIError.httpError(let code) = error {
            status = code
        } else {
            status = nil
        }
        if let status {
            switch status {
            case 401, 403: return enteredPIN ? .wrongPIN : .signInExpired
            case 429: return .tooManyAttempts
            // Gateway and Cloudflare origin errors mean the server behind the
            // proxy is down, not that it answered badly.
            case 502, 503, 504, 520...524, 530: return .unreachable
            case 500...599: return .serverError
            default: return .unknown
            }
        }
        if enteredPIN, case ProfileTransitionError.missingPINProof = error { return .wrongPIN }
        if case HTTPError.decodingFailed = error { return .unexpectedResponse }
        if case HTTPError.invalidResponse = error { return .unexpectedResponse }
        return .unknown
    }

    /// Network failures that are worth one quiet retry before showing an error.
    static func isTemporary(_ error: Error) -> Bool {
        var error = error
        if case HTTPError.network(let underlying) = error { error = underlying }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(urlError.code)
        }
        if case HTTPError.http(let status, _) = error { return [502, 503, 504].contains(status) }
        return false
    }

    var title: String {
        switch self {
        case .offline: "You’re offline"
        case .unreachable: "Can’t reach your server"
        case .wrongPIN: "That PIN didn’t match"
        case .tooManyAttempts: "Too many attempts"
        case .signInExpired: "Your sign-in has expired"
        case .serverError: "Your server ran into a problem"
        case .unexpectedResponse: "Unexpected server response"
        case .noPrimaryProfile: "No primary profile"
        case .unknown: "Couldn’t open your profile"
        }
    }

    var message: String {
        switch self {
        case .offline:
            "Check your Wi-Fi or network connection, then try again."
        case .unreachable:
            "The server isn’t responding. If it has moved or shut down, go back and sign in to a different server."
        case .wrongPIN:
            "Enter the profile PIN again."
        case .tooManyAttempts:
            "Wait a minute, then try again."
        case .signInExpired:
            "This server signed you out, or your sign-in timed out. Sign in again to continue."
        case .serverError:
            "It returned an error while loading your profile. Try again in a moment."
        case .unexpectedResponse:
            "Check the server address and any reverse proxy in front of it, then try again."
        case .noPrimaryProfile:
            "Set a primary profile for this account on your server, then try again."
        case .unknown:
            "Something went wrong while preparing your profile. Try again, or go back and sign in to a different server."
        }
    }

    var symbol: String {
        switch self {
        case .offline: "wifi.slash"
        case .unreachable: "server.rack"
        case .wrongPIN, .tooManyAttempts: "lock"
        case .signInExpired: "person.crop.circle.badge.exclamationmark"
        case .serverError, .unexpectedResponse: "exclamationmark.triangle"
        case .noPrimaryProfile: "person.crop.circle.badge.questionmark"
        case .unknown: "exclamationmark.circle"
        }
    }

    /// An expired sign-in can't be fixed by retrying, so its primary action
    /// leaves the account instead.
    var primaryActionSignsOut: Bool { self == .signInExpired }

    var primaryTitle: String {
        switch self {
        case .wrongPIN: "Enter PIN"
        case .signInExpired: "Sign in again"
        default: "Try again"
        }
    }

    var primarySymbol: String {
        switch self {
        case .wrongPIN: "lock.open"
        case .signInExpired: "person.crop.circle"
        default: "arrow.clockwise"
        }
    }
}

@Observable @MainActor
final class TVLoginPreparation {
    static let shared = TVLoginPreparation()
    var isPresented = false
    var status = "Getting ready"
    var ready = false
    private(set) var failure: LoginPreparationFailure?
    /// Name of the server the failure belongs to, so the page says which
    /// server it is stuck on.
    private(set) var failedServerName: String?
    var pinProfile: UserProfile?
    private(set) var isSigningOut = false
    private(set) var showsWelcome = false
    private var router: AppRouter?
    private let completionKey = "vivid.didCompleteFirstLoginPreparation"

    func begin(router: AppRouter) async {
        guard !isPresented else { return }
        self.router = router
        showsWelcome = !UserDefaults.standard.bool(forKey: completionKey)
        isPresented = true
        await prepare()
    }

    func prepare(pin: String? = nil) async {
        guard !isSigningOut else { return }
        ready = false
        failure = nil
        status = "Getting ready"
        pinProfile = nil
        // Only the PIN check itself can mean a wrong PIN. A 401 from the
        // profile list is an expired sign-in even when a PIN was typed.
        var checkedPIN = false
        do {
            let account = await TokenStore.shared.refreshAccountIdentity()
            if !AuthService.shared.hasProfile {
                let profiles = try await retryTemporaryFailure { try await StartupContentPrefetcher.fetchProfiles() }
                guard let primary = profiles.first(where: \.isPrimary) ?? (profiles.count == 1 ? profiles.first : nil) else {
                    fail(.noPrimaryProfile)
                    return
                }
                if primary.hasPin, pin == nil {
                    pinProfile = primary
                    return
                }
                checkedPIN = pin != nil
                try await AuthService.shared.selectProfile(profileId: primary.id, pin: pin, requiresPIN: primary.hasPin)
            }
            // Home hydrates its profile-scoped disk snapshot before its first
            // render. Fresh sections and libraries must not gate the handoff.
            guard account == (await TokenStore.shared.refreshAccountIdentity()) else { throw CancellationError() }
            guard await StartupContentPrefetcher.prefetchAuthenticatedContent() else { throw CancellationError() }
            try Task.checkCancellation()
            guard account == (await TokenStore.shared.refreshAccountIdentity()) else { throw CancellationError() }
            ready = true
        } catch is CancellationError {
            cancel()
        } catch {
            Logger(subsystem: "Vivid", category: "LoginPreparation")
                .error("Profile preparation failed: \(String(describing: type(of: error)), privacy: .public)")
            fail(LoginPreparationFailure.classify(error, enteredPIN: checkedPIN))
        }
    }

    private func fail(_ failure: LoginPreparationFailure) {
        failedServerName = ServerRegistry.shared.activeServer?.displayName
        self.failure = failure
    }

    private func retryTemporaryFailure<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            guard LoginPreparationFailure.isTemporary(error) else { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await operation()
        }
    }

    /// Runs the failure page's primary action.
    func performPrimaryAction() async {
        if failure?.primaryActionSignsOut == true {
            await signOutToLogin()
        } else {
            await prepare()
        }
    }

    func finish() {
        guard ready else { return }
        UserDefaults.standard.set(true, forKey: completionKey)
        router?.resetToHome()
        isPresented = false
        router = nil
    }

    /// Leaves the account being prepared rather than only hiding this screen.
    /// While the account still needs a profile, the screen underneath starts
    /// preparation again, so an unreachable server would bring the user
    /// straight back here. The overlay stays up until the sign-out has moved
    /// the router to login or server setup.
    func signOutToLogin() async {
        guard isPresented, !isSigningOut, let router else { return }
        isSigningOut = true
        pinProfile = nil
        defer { isSigningOut = false }
        let store = TVSavedAccountStore.shared
        if let account = store.activeAccount, account.serverID == ServerRegistry.shared.activeServerId {
            // Marks the saved account as needing sign-in, so iCloud sync can't
            // restore its session on this or another device.
            await store.signOut(router: router)
            guard store.activeID == nil else {
                fail(.unknown)
                return
            }
        } else {
            guard await AuthService.shared.signOut() else {
                fail(.unknown)
                return
            }
            if ServerRegistry.shared.hasActiveServer {
                router.resetToLogin()
            } else {
                router.resetToServerSetup()
            }
        }
        cancel()
    }

    func cancel() {
        isPresented = false
        pinProfile = nil
        failure = nil
        failedServerName = nil
        router = nil
    }
}

struct TVLoginPreparationView: View {
    @State private var preparation = TVLoginPreparation.shared
    var body: some View {
        if let failure = preparation.failure {
            LoginPreparationFailureView(
                failure: failure,
                serverName: preparation.failedServerName,
                isSigningOut: preparation.isSigningOut,
                onPrimary: { Task { await preparation.performPrimaryAction() } },
                onSignOut: { Task { await preparation.signOutToLogin() } }
            )
        } else if preparation.isSigningOut {
            LoginPreparationSigningOutView()
        } else if let profile = preparation.pinProfile {
            PINEntryView(profile: profile, onCancel: { Task { await preparation.signOutToLogin() } }) { pin in
                Task { await preparation.prepare(pin: pin) }
            }
        } else {
            VividStartupView(isContentReady: preparation.ready,
                             statusText: preparation.showsWelcome ? preparation.status : "Loading your Home") {
                preparation.finish()
            }
            .overlay(alignment: .bottom) {
                if !preparation.ready {
                    ProgressView().padding(.bottom, 80)
                }
            }
        }
    }
}

// MARK: - Failure page

/// Recovery page shown when a signed-in account can't open its profile. It
/// uses the same Aurora language as server setup and sign-in, and keeps a
/// real way out: going back signs out of the account rather than only
/// hiding this page.
private struct LoginPreparationFailureView: View {
    let failure: LoginPreparationFailure
    let serverName: String?
    let isSigningOut: Bool
    let onPrimary: () -> Void
    let onSignOut: () -> Void

    #if os(tvOS)
    @FocusState private var focusedAction: Action?
    private enum Action: Hashable { case primary, signOut }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    VividLogoView(size: 96)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 48)

                VStack(spacing: 28) {
                    LoginPreparationBadge(symbol: failure.symbol, size: 118, glyph: 50)

                    VStack(spacing: 14) {
                        AuroraEyebrow(text: "Profile setup", centered: true)
                        Text(failure.title)
                            .font(.vividTitle)
                            .foregroundStyle(Color.auroraInk)
                            .multilineTextAlignment(.center)
                        Text(failure.message)
                            .font(.vividBody)
                            .foregroundStyle(Color.auroraInkSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let serverName {
                            LoginPreparationServerLabel(name: serverName)
                        }
                    }

                    HStack(spacing: 24) {
                        Button(action: onPrimary) {
                            Label(failure.primaryTitle, systemImage: failure.primarySymbol)
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isSigningOut && failure.primaryActionSignsOut))
                        .focused($focusedAction, equals: .primary)

                        if !failure.primaryActionSignsOut {
                            Button(isSigningOut ? "Signing out…" : "Back to sign in", action: onSignOut)
                                .buttonStyle(AuroraGhostButtonStyle())
                                .focused($focusedAction, equals: .signOut)
                        }
                    }
                    .disabled(isSigningOut)
                    .focusSection()
                }
                .padding(56)
                .frame(width: 820)
                .auroraGlass(cornerRadius: 30, emphasized: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 96)
            .padding(.top, 64)
            .padding(.bottom, 64)
        }
        .ignoresSafeArea()
        .defaultFocus($focusedAction, .primary, priority: .userInitiated)
        .animation(.easeInOut(duration: 0.2), value: failure)
    }
    #else
    var body: some View {
        AuroraScreen(variant: .profile, scrim: .soft) {
            VividMarkView(width: 112)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)

            AuroraEyebrow(text: "Profile setup", centered: true)
                .padding(.bottom, 16)

            LoginPreparationBadge(symbol: failure.symbol, size: 78, glyph: 32)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 18)

            VStack(spacing: 12) {
                Text(failure.title)
                    .font(.vividTitle)
                    .foregroundStyle(Color.auroraInk)
                    .multilineTextAlignment(.center)
                Text(failure.message)
                    .font(.vividBody)
                    .foregroundStyle(Color.auroraInkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let serverName {
                    LoginPreparationServerLabel(name: serverName)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 22)

            VStack(spacing: 16) {
                Button(action: onPrimary) {
                    Label(failure.primaryTitle, systemImage: failure.primarySymbol)
                }
                .buttonStyle(AuroraPrimaryButtonStyle(isLoading: isSigningOut && failure.primaryActionSignsOut))

                if !failure.primaryActionSignsOut {
                    Button(isSigningOut ? "Signing out…" : "Back to sign in", action: onSignOut)
                        .buttonStyle(AuroraGhostButtonStyle())
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isSigningOut)
            .padding(22)
            .auroraGlass(cornerRadius: 24, emphasized: true)
        }
        .animation(.easeInOut(duration: 0.2), value: failure)
    }
    #endif
}

private struct LoginPreparationBadge: View {
    let symbol: String
    let size: CGFloat
    let glyph: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color.auroraAccent.opacity(0.14))
            Circle().stroke(Color.auroraAccent.opacity(0.34), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: glyph, weight: .regular))
                .foregroundStyle(Color.auroraAccent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct LoginPreparationServerLabel: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "server.rack")
            .font(.vividCaption)
            .foregroundStyle(Color.auroraInkTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityLabel("Server: \(name)")
    }
}

/// Shown while leaving an account from the PIN prompt, where there is no
/// failure page to carry the progress.
private struct LoginPreparationSigningOutView: View {
    var body: some View {
        VStack(spacing: 24) {
            VividLogoView(size: logoSize)
            ProgressView()
            Text("Signing out…")
                .font(.vividBody)
                .foregroundStyle(Color.auroraInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    #if os(tvOS)
    private let logoSize: CGFloat = 96
    #else
    private let logoSize: CGFloat = 72
    #endif
}


#endif
