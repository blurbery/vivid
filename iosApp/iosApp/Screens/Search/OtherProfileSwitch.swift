import Foundation

/// Opening something Search found in another saved profile: Vivid switches
/// to that profile first, so playback, progress and watched state go to the
/// server the title is on.
///
/// A switch rebuilds the whole signed-in shell (`contentRevision`), Search
/// included, so what was asked for waits on the app's router until the new
/// shell is showing (see `AppRouter.openAfterProfileSwitch`).
@MainActor
extension TVSavedAccountStore {
    /// Switches to `account`, then opens `item` there. If the switch didn't
    /// happen (busy, locked, failed, or it stopped at profile selection),
    /// nothing is opened, since content IDs only mean something on their own
    /// server.
    func openSearchResult(_ item: BrowseItem, in account: TVSavedAccount, router: AppRouter) async {
        let route = Route.itemDetail(browseItem: item)
        if isSettled(on: account, router: router.appRouter ?? router) {
            // Already this profile: open it like any other result, on the
            // router the caller's page uses.
            router.navigate(to: route)
            return
        }
        await switchForSearch(to: account, router: router, opening: .route(route))
    }

    /// Switches to `account`, then runs `query` in its Search tab.
    func search(_ query: String, in account: TVSavedAccount, router: AppRouter) async {
        let appRouter = router.appRouter ?? router
        if isSettled(on: account, router: appRouter) {
            appRouter.requestSearch(query: query)
            return
        }
        await switchForSearch(to: account, router: router, opening: .search(query))
    }

    /// Whether `account` is the profile in use, fully signed in, with the
    /// signed-in shell showing.
    private func isSettled(on account: TVSavedAccount, router: AppRouter) -> Bool {
        activeAccount?.id == account.id
            && ServerRegistry.shared.activeServerId == account.serverID
            && !busy && !showsSelector
            && AuthService.shared.isLoggedIn && AuthService.shared.hasProfile
            && router.authState == .authenticated
    }

    private func switchForSearch(to account: TVSavedAccount, router: AppRouter,
                                 opening destination: ProfileSwitchDestination.Target) async {
        // The switch resets, signs in and rebuilds the app, never just the
        // page Search runs in on iPhone and iPad.
        let appRouter = router.appRouter ?? router
        // Search's rows never offer a profile with a PIN, so this never
        // needs one; `select` itself refuses a locked profile, which the
        // checks below then catch.
        // A page's own router starts at `.loading`, so this also stops a
        // switch that somehow missed the app's router.
        guard !account.requiresLogin, !busy, !SearchSwitch.isRunning,
              appRouter.authState == .authenticated else { return }
        // `select` only sets `busy` after an await, so a second tap could
        // otherwise start a second switch and open the title twice.
        SearchSwitch.isRunning = true
        defer { SearchSwitch.isRunning = false }
        // Search is torn down while the switch runs, so the switch runs in
        // its own task: a caller's view going away mustn't cancel it half
        // way through signing in.
        let revisionBefore = contentRevision
        await Task { @MainActor in await self.select(account, router: appRouter) }.value
        // Only open anything if the switch really finished: this profile is
        // active and signed in with a viewing profile, it didn't stop at
        // profile selection or the saved-profile picker, and the shell was
        // rebuilt (a failed content prefetch returns before that). Content
        // IDs can repeat across servers, so opening after a partial switch
        // could show the wrong title.
        guard contentRevision != revisionBefore, isSettled(on: account, router: appRouter) else { return }
        appRouter.openAfterProfileSwitch(destination, contentRevision: contentRevision)
    }
}

/// Whether a switch Search started is still running.
@MainActor
private enum SearchSwitch {
    static var isRunning = false
}
