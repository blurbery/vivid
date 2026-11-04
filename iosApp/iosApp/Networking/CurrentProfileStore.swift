import Foundation

/// The active profile for this session, so top-bar avatars render from one
/// value instead of every root page refetching the profile list and briefly
/// showing the fallback initial.
///
/// Loaded once per session. `AuthService`, `ServerRegistry` and the app root
/// reset and refresh it on sign-in, sign-out and profile or server switches.
@MainActor
@Observable
final class CurrentProfileStore {
    static let shared = CurrentProfileStore()

    /// Nil until the first successful load; the avatar shows a fallback.
    private(set) var profile: UserProfile?

    /// Bumped by `reset()`, so a load that finishes after a sign-out or
    /// profile switch drops its result instead of filling in the next
    /// account's avatar.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    /// Loads the active profile unless it's already here. Concurrent callers
    /// share one request; `force` refetches after a known change.
    func refresh(force: Bool = false) async {
        if !force, profile != nil { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let loadGeneration = generation
        let task = Task { @MainActor in
            defer {
                // A reset may already have started the next generation's load.
                if loadGeneration == generation { inFlight = nil }
            }
            guard let profileId = AuthService.shared.profileId else { return }
            guard let profiles = try? await AuthService.shared.getProfiles(),
                  loadGeneration == generation else { return }
            profile = profiles.first { $0.id == profileId }
        }
        inFlight = task
        await task.value
    }

    func reset() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        profile = nil
    }
}
