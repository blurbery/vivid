import Foundation

/// The active profile's preferred subtitle language, for the detail page's
/// subtitle menu, which lists that language first. Playback reads the exact
/// per-item values from `WatchDetail`; the detail page only has the catalogue
/// item, so it uses the profile default as a close enough guide.
///
/// Loaded on first use and cleared on sign-out and profile switches. Nothing
/// is stored.
@MainActor
final class ProfilePrefsStore: ObservableObject {
    static let shared = ProfilePrefsStore()

    /// The language code, or nil when the profile hasn't set one.
    @Published private(set) var preferredSubtitleLanguage: String?

    private var isLoaded = false
    private var load: Task<Void, Never>?
    private var generation = 0

    /// Loads once; later calls do nothing until `clear()`.
    func hydrateIfNeeded() async {
        guard !isLoaded else { return }
        await refresh()
    }

    /// Reads the profile list again. A failure, or no active profile yet,
    /// leaves it unloaded so the next `hydrateIfNeeded()` tries again.
    func refresh() async {
        if let load {
            await load.value
            return
        }
        guard let profileID = ServerRegistry.shared.activeProfileId else { return }

        let started = generation
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, self.generation == started { self.load = nil }
            }
            guard let profiles = try? await AuthService.shared.getProfiles(),
                  let self,
                  !Task.isCancelled,
                  self.generation == started,
                  ServerRegistry.shared.activeProfileId == profileID
            else { return }
            self.preferredSubtitleLanguage = profiles.first { $0.id == profileID }?.subtitleLanguage
            self.isLoaded = true
        }
        load = task
        await task.value
    }

    func clear() {
        generation &+= 1
        load?.cancel()
        load = nil
        preferredSubtitleLanguage = nil
        isLoaded = false
    }
}
