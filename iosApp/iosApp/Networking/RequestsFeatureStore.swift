import Foundation

/// The server's `requests_enabled` flag, checked once per session and reset
/// on sign-out and profile or server switches (by `AuthService`,
/// `ServerRegistry` and the app root).
@MainActor
@Observable
final class RequestsFeatureStore {
    static let shared = RequestsFeatureStore()

    /// False until a check reports the feature on, so request entry points
    /// stay hidden while the first check runs.
    private(set) var isEnabled = false

    /// Bumped by `reset()`, so a check that finishes after a sign-out or
    /// profile switch can't set the next account's flag.
    private var generation = 0
    private let api: VividAPI

    init(api: VividAPI = .shared) {
        self.api = api
    }

    /// A failed check (including a 404 from an older server) keeps the
    /// current value; the next foreground or sign-in checks again.
    func refresh() async {
        let started = generation
        let status = try? await api.requestsStatus()
        guard started == generation, let status else { return }
        isEnabled = status.requestsEnabled
    }

    func reset() {
        generation &+= 1
        isEnabled = false
    }
}
