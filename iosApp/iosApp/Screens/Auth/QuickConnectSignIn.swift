import Foundation

/// Jellyfin Quick Connect: shows a code the user approves from a signed-in
/// Jellyfin app, waits for that approval, then hands the new session to the
/// sign-in form that started it. Password sign-in stays available alongside.
@Observable @MainActor
final class QuickConnectSignIn {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting(code: String)
        case signingIn
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

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
        case .starting: "Getting a code…"
        case .waiting: "Waiting for approval…"
        case .signingIn: "Signing in…"
        case .idle, .failed: nil
        }
    }

    /// Whether the active server offers Quick Connect. Errors count as no, so
    /// the password form never waits on this check.
    static func isAvailable(serverURL: String) async -> Bool {
        (try? await JellyfinConnection.signIn(serverURL: serverURL).quickConnectEnabled()) ?? false
    }

    /// Starts a new code, replacing any earlier one. `complete` saves the
    /// approved session and returns a message to show when that fails.
    func start(serverURL: String, complete: @escaping @MainActor (JellyfinLogin) async -> String?) {
        task?.cancel()
        phase = .starting
        task = Task { [weak self] in
            let connection = JellyfinConnection.signIn(serverURL: serverURL)
            do {
                guard try await connection.quickConnectEnabled() else { throw JellyfinError.quickConnectDisabled }
                let request = try await connection.initiateQuickConnect()
                self?.phase = .waiting(code: request.code)
                try await Self.waitForApproval(of: request, on: connection)
                self?.phase = .signingIn
                let login = try await connection.authenticate(quickConnectSecret: request.secret)
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

    /// Stops waiting and returns to the password form.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Polls every five seconds, as Jellyfin's own apps do. A dropped
    /// connection keeps waiting; the code itself expires after ten minutes.
    private static func waitForApproval(of request: JellyfinQuickConnectCode, on connection: JellyfinConnection) async throws {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            do {
                if try await connection.quickConnectApproved(secret: request.secret) { return }
            } catch is URLError {
                try Task.checkCancellation()
            }
        }
        throw JellyfinError.quickConnectExpired
    }
}
