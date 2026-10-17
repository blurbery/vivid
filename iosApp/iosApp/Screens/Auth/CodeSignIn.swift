import Foundation

/// Sign-in with a code approved somewhere else, for accounts without a
/// password: Jellyfin Quick Connect (approved from a signed-in Jellyfin app)
/// or Emby Connect (a PIN entered at emby.media/pin). Shows the code, waits
/// for approval, then hands the new session to the sign-in form that started
/// it. Password sign-in stays available alongside.
@Observable @MainActor
final class CodeSignIn {
    enum Service: Equatable {
        case jellyfinQuickConnect, embyConnect

        /// The choice offered for a provider, if any.
        init?(_ provider: MediaServerProvider) {
            switch provider {
            case .jellyfin: self = .jellyfinQuickConnect
            case .emby: self = .embyConnect
            case .silo: return nil
            }
        }

        var title: String {
            switch self {
            case .jellyfinQuickConnect: "Quick Connect"
            case .embyConnect: "Emby Connect"
            }
        }

        var instructions: String {
            switch self {
            case .jellyfinQuickConnect: "On a device that’s signed in to Jellyfin, go to Settings > Quick Connect and enter this code."
            case .embyConnect: "On your phone or computer, go to emby.media/pin and enter this PIN with your Emby Connect email and password."
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case starting
        case waiting(code: String)
        case signingIn
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var service: Service = .jellyfinQuickConnect
    private var task: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

    /// Once the code is approved, the sign-in finishes like a password
    /// sign-in in progress, so the code screen can't be cancelled.
    var canCancel: Bool { phase != .signingIn }

    var code: String? {
        if case .waiting(let code) = phase { return code }
        return nil
    }

    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var status: String? {
        switch phase {
        case .starting: service == .embyConnect ? "Getting a PIN…" : "Getting a code…"
        case .waiting: "Waiting for approval…"
        case .signingIn: "Signing in…"
        case .idle, .failed: nil
        }
    }

    /// Whether the active server offers this choice on the first-run form.
    /// Jellyfin reports whether Quick Connect is turned on; any Emby server
    /// can be linked to Emby Connect. Errors count as no, so the password
    /// form never waits on this check.
    static func isAvailable(_ service: Service, serverURL: String) async -> Bool {
        switch service {
        case .jellyfinQuickConnect:
            return (try? await JellyfinConnection.signIn(serverURL: serverURL).quickConnectEnabled()) ?? false
        case .embyConnect:
            return true
        }
    }

    /// Starts a Jellyfin Quick Connect code, replacing any earlier one.
    /// `complete` saves the approved session and returns a message to show
    /// when that fails.
    func startQuickConnect(serverURL: String, complete: @escaping @MainActor (JellyfinLogin) async -> String?) {
        run(.jellyfinQuickConnect, complete: complete) { [weak self] in
            let connection = JellyfinConnection.signIn(serverURL: serverURL)
            guard try await connection.quickConnectEnabled() else { throw JellyfinError.quickConnectDisabled }
            let request = try await connection.initiateQuickConnect()
            // A cancelled or replaced flow must not show its code.
            try Task.checkCancellation()
            self?.phase = .waiting(code: request.code)
            try await Self.poll(expired: JellyfinError.quickConnectExpired) {
                try await connection.quickConnectApproved(secret: request.secret)
            }
            try Task.checkCancellation()
            self?.phase = .signingIn
            return try await Self.retryingTemporaryFailures {
                try await connection.authenticate(quickConnectSecret: request.secret)
            }
        }
    }

    /// Starts an Emby Connect PIN, replacing any earlier one.
    func startEmbyConnect(serverURL: String, complete: @escaping @MainActor (EmbyLogin) async -> String?) {
        run(.embyConnect, complete: complete) { [weak self] in
            let pin = try await EmbyConnectService.createPIN()
            try Task.checkCancellation()
            self?.phase = .waiting(code: pin.pin)
            try await Self.poll(expired: EmbyError.connectPINExpired) {
                try await EmbyConnectService.isConfirmed(pin)
            }
            try Task.checkCancellation()
            self?.phase = .signingIn
            let account = try await Self.retryingTemporaryFailures { try await EmbyConnectService.authenticate(pin) }
            return try await Self.retryingTemporaryFailures {
                try await EmbyConnection.login(serverURL: serverURL, connect: account)
            }
        }
    }

    /// Stops waiting and returns to the password form.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Every start goes through here. An approved code that is still signing
    /// in is never replaced, whichever button asked.
    private func run<Login: Sendable>(_ service: Service, complete: @escaping @MainActor (Login) async -> String?,
                                      flow: @escaping @MainActor () async throws -> Login) {
        guard canCancel else { return }
        task?.cancel()
        self.service = service
        phase = .starting
        task = Task { [weak self] in
            do {
                let login = try await flow()
                try Task.checkCancellation()
                // The form disappears while Home is prepared, which cancels
                // this flow. Finishing the sign-in must outlive it, as a
                // password sign-in does.
                let message = await Task { await complete(login) }.value
                guard !Task.isCancelled else { return }
                self?.phase = message.map { .failed($0) } ?? .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Checks every five seconds, as Jellyfin's and Emby's own apps do. A
    /// temporary failure keeps waiting; the code itself expires after ten
    /// minutes.
    private static func poll(expired: Error, approved: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            do {
                if try await approved() { return }
            } catch let error where isTemporary(error) {
                try Task.checkCancellation()
            }
        }
        throw expired
    }

    /// The approved code stays valid briefly, so a temporary failure after
    /// approval is tried twice more before giving up.
    private static func retryingTemporaryFailures<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error where attempt < 3 && isTemporary(error) {
                attempt += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// No connection, a timeout, rate limiting or a server error, rather than
    /// an answer about the code.
    nonisolated static func isTemporary(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if case HTTPError.http(let status, _) = error { return status == 408 || status == 429 || status >= 500 }
        if case EmbyError.connectUnavailable = error { return true }
        return false
    }
}
