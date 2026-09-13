#if os(tvOS) || os(iOS)
import SwiftUI
import OSLog

@Observable @MainActor
final class TVLoginPreparation {
    static let shared = TVLoginPreparation()
    var isPresented = false
    var status = "Getting ready"
    var ready = false
    var error: String?
    var pinProfile: UserProfile?
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
        ready = false
        error = nil
        status = "Getting ready"
        pinProfile = nil
        var stage = "profile"
        do {
            let account = await TokenStore.shared.refreshAccountIdentity()
            if !AuthService.shared.hasProfile {
                let profiles = try await retryTemporaryFailure { try await StartupContentPrefetcher.fetchProfiles() }
                guard let primary = profiles.first(where: \.isPrimary) ?? (profiles.count == 1 ? profiles.first : nil) else {
                    error = "This account has no primary profile. Set a primary profile on your server, then try again."
                    return
                }
                if primary.hasPin, pin == nil {
                    pinProfile = primary
                    return
                }
                try await AuthService.shared.selectProfile(profileId: primary.id, pin: pin, requiresPIN: primary.hasPin)
            }
            if showsWelcome { try await Task.sleep(for: .seconds(3)) }
            status = "Almost done"
            stage = "home"
            let almostDoneStarted = ContinuousClock.now
            _ = try await retryTemporaryFailure { try await StartupContentPrefetcher.fetchHomeSections() }
            stage = "libraries"
            _ = try await retryTemporaryFailure { try await StartupContentPrefetcher.fetchUserLibraries() }
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            guard account == (await TokenStore.shared.refreshAccountIdentity()) else { throw CancellationError() }
            #if os(tvOS)
            await TVSavedAccountStore.shared.captureCurrent()
            #endif
            if showsWelcome {
                try await ContinuousClock().sleep(until: almostDoneStarted.advanced(by: .seconds(3)))
                status = "Welcome to Vivid"
                try await Task.sleep(for: .seconds(3))
            }
            try Task.checkCancellation()
            guard account == (await TokenStore.shared.refreshAccountIdentity()) else { throw CancellationError() }
            ready = true
        } catch is CancellationError {
            cancel()
        } catch {
            Logger(subsystem: "Vivid", category: "LoginPreparation")
                .error("Preparation failed at \(stage, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            self.error = stage == "profile"
                ? "Couldn’t prepare your viewing profile. Please try again."
                : "You’re signed in, but Vivid couldn’t load your home data. Please try again."
        }
    }

    private func retryTemporaryFailure<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            let retryable: Bool
            if let urlError = error as? URLError {
                retryable = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(urlError.code)
            } else if case HTTPError.http(let status, _) = error {
                retryable = [502, 503, 504].contains(status)
            } else {
                retryable = false
            }
            guard retryable else { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await operation()
        }
    }

    func finish() {
        guard ready else { return }
        UserDefaults.standard.set(true, forKey: completionKey)
        router?.resetToHome()
        isPresented = false
        router = nil
    }

    func cancel() {
        isPresented = false
        pinProfile = nil
        router = nil
    }
}

struct TVLoginPreparationView: View {
    @State private var preparation = TVLoginPreparation.shared
    var body: some View {
        if let profile = preparation.pinProfile {
            PINEntryView(profile: profile, onCancel: { preparation.cancel() }) { pin in
                Task { await preparation.prepare(pin: pin) }
            }
        } else if let error = preparation.error {
            VStack(spacing: 28) {
                Text(error).multilineTextAlignment(.center).frame(maxWidth: 850)
                Button("Try again") { Task { await preparation.prepare() } }
                Button("Back to sign in") { preparation.cancel() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
            .background(Color.black.ignoresSafeArea())
            #endif
        } else {
            VividStartupView(isContentReady: preparation.ready,
                             statusText: preparation.showsWelcome ? preparation.status : nil) {
                preparation.finish()
            }
        }
    }
}
#endif
