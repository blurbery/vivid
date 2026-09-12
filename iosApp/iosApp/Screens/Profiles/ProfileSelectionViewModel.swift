import Foundation

@Observable
@MainActor
class ProfileSelectionViewModel {
    var profiles: [UserProfile] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var error: ErrorState?
    private let auth = AuthService.shared

    init() {
        if let cached: [UserProfile] = ResponseCache.shared.get(CacheKey.profiles) {
            profiles = cached
        }
    }

    /// Fetch the user's profiles from the server.
    func loadProfiles() async {
        if profiles.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let fresh = try await StartupContentPrefetcher.fetchProfiles()
            profiles = fresh
        } catch {
            if profiles.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }

    /// Select a profile that has no PIN and navigate to home.
    func selectProfile(_ profile: UserProfile, router: AppRouter) async {
        do {
            try await auth.selectProfile(
                profileId: profile.id,
                requiresPIN: profile.hasPin
            )
            #if os(iOS)
            // Identity is committed at this point, so reveal Home immediately.
            // Optional settings and content warm-up must never hold the profile
            // card on screen behind a slow server request.
            router.resetToHome()
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            Task { await PlayerSettings.shared.reloadForCurrentProfile() }
            #else
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            await PlayerSettings.shared.reloadForCurrentProfile()
            router.resetToHome()
            #endif
        } catch {
            self.error = ErrorState(error)
        }
    }

    /// Select a profile with a PIN.
    func selectProfileWithPIN(_ profile: UserProfile, pin: String, router: AppRouter) async throws {
        try await auth.selectProfile(
            profileId: profile.id,
            pin: pin,
            requiresPIN: profile.hasPin
        )
        #if os(iOS)
        router.resetToHome()
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        Task { await PlayerSettings.shared.reloadForCurrentProfile() }
        #else
        StartupContentPrefetcher.prefetchAuthenticatedContent()
        await PlayerSettings.shared.reloadForCurrentProfile()
        router.resetToHome()
        #endif
    }

}
