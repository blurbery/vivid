import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Lifecycle

    /// Re-point the manager at the active `(server, profile)` scope,
    /// loading that scope's persisted blob. Returns false when there is no
    /// signed-in scope.
    @discardableResult
    func activateScopeIfNeeded() async -> Bool {
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        guard !serverId.isEmpty, !profileId.isEmpty else {
            deactivate()
            releaseHeldSessionEvents()
            return false
        }
        // A load still in flight for this scope means `file` is the previous
        // account's, so wait for it below instead of returning early.
        if serverId == scopeServerId, profileId == scopeProfileId, scopeLoadTask == nil,
           !file.records.isEmpty || file.capability != nil {
            releaseHeldSessionEvents()
            return true
        }
        if serverId != scopeServerId || profileId != scopeProfileId {
            invalidatePendingRegistrations()
            scopeServerId = serverId
            scopeProfileId = profileId
            capabilityCheckFailed = false
            // Transfers that finish while the new scope's registry loads are
            // held and replayed against it, as on a cold launch.
            sessionEventsHeld = true
        }

        let loadTask: Task<DownloadStoreFile, Never>
        let loadToken: UUID
        if let existing = scopeLoadTask,
           scopeLoadServerId == serverId,
           scopeLoadProfileId == profileId,
           let existingToken = scopeLoadToken {
            loadTask = existing
            loadToken = existingToken
        } else {
            scopeLoadTask?.cancel()
            let token = UUID()
            let task = Task {
                await DownloadStore.shared.load(serverId: serverId, profileId: profileId)
            }
            scopeLoadTask = task
            scopeLoadToken = token
            scopeLoadServerId = serverId
            scopeLoadProfileId = profileId
            loadTask = task
            loadToken = token
        }

        let loadedFile = await loadTask.value
        guard scopeServerId == serverId, scopeProfileId == profileId else { return false }
        if scopeLoadToken == loadToken {
            // Exactly one waiter installs this snapshot. Later waiters observe
            // the already-hydrated `file` instead of assigning it a second time.
            file = loadedFile
            scopeLoadTask = nil
            scopeLoadToken = nil
            scopeLoadServerId = ""
            scopeLoadProfileId = ""
        } else if scopeLoadToken != nil {
            // A newer load for this scope replaced ours (an A to B to A
            // switch) and hasn't installed its snapshot yet. Releasing held
            // transfer events now would replay them against the wrong
            // registry, so wait for that load instead.
            return await activateScopeIfNeeded()
        }
        releaseHeldSessionEvents()
        refreshStorageUsage()
        await backfillEpisodeMetadataIfNeeded()
        return true
    }

    /// Called on app launch / foreground and on the first authenticated
    /// transition. Refreshes capability, reconciles with the server, and
    /// runs subscription + progress sync.
    func onAppActive() async {
        guard await activateScopeIfNeeded() else { return }
        await refreshCapability()
        guard downloadsEnabled else { return }
        await reconcileWithServer(triggerPipeline: true)
        await runMonitoringAndProgressSync()
        await backfillAssetsIfNeeded()
    }

    /// Load the active server's scope and permission before a download
    /// request, so a tap straight after launch or a server switch never runs
    /// against an empty or stale scope.
    func prepareForDownload() async -> Bool {
        // A server switch publishes the new server before its sign-in is in
        // place; wait for it so the scope and the sign-in agree.
        guard await HTTPClient.shared.waitForRequestDispatchOpen() else { return false }
        guard await activateScopeIfNeeded() else { return false }
        if !capabilityKnown || capabilityCheckFailed { await refreshCapability() }
        return downloadsEnabled
    }

    /// Profile/server switched — load the new scope and refresh.
    func onScopeChanged() async {
        deactivate()
        await onAppActive()
    }

    /// Sign-out: stop active transfers and drop in-memory state. On-disk
    /// files are intentionally preserved (the user may sign back in).
    func clearForSignOut() {
        cancelActiveTasks()
        deactivate()
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        pendingPauseIds.removeAll()
        pendingResumeIds.removeAll()
        preparingDetailsFetched.removeAll()
        preparingDetailsAttempts.removeAll()
        deletedDownloadIds.removeAll()
        invalidatePendingRegistrations()
        scopeLoadTask?.cancel()
        scopeLoadTask = nil
        scopeLoadToken = nil
        scopeLoadServerId = ""
        scopeLoadProfileId = ""
        scopeServerId = ""
        scopeProfileId = ""
        capabilityCheckFailed = false
        file = .empty
        rateSamples.removeAll()
        transferRates.removeAll()
    }

    private func cancelActiveTasks() {
        for record in file.records.values where record.localStatus == .downloading {
            if let taskId = record.taskIdentifier {
                intentionalCancels.insert(taskId)
                sessionDelegate.cancel(taskId: taskId)
            }
        }
    }

    // MARK: - Background relaunch

    /// Store the system completion handler delivered when iOS relaunches
    /// the app to finish background events.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        sessionDelegate.backgroundCompletionHandler = handler
    }

    // MARK: - Capability

    func refreshCapability() async {
        guard !scopeServerId.isEmpty else { return }
        let serverId = scopeServerId
        let profileId = scopeProfileId
        let generation = registrationScopeGeneration
        capabilityChecksInFlight += 1
        defer { capabilityChecksInFlight -= 1 }
        // Mid-switch the active sign-in can already be the next account's;
        // the activation for that account checks it instead.
        guard let auth = await scopeAuth() else { return }
        do {
            let capability = try await VividAPI.shared.downloadCapability(auth: auth)
            // A switch during the request makes this answer another account's.
            guard generation == registrationScopeGeneration, serverId == scopeServerId, profileId == scopeProfileId else { return }
            file.capability = capability
            file.capabilityFetchedAt = Date()
            capabilityCheckFailed = false
            persist()
        } catch {
            guard generation == registrationScopeGeneration, serverId == scopeServerId, profileId == scopeProfileId else { return }
            if case HTTPError.http(let status, _) = error, status == 404 || status == 501 {
                // A server without the downloads API: show the controls as
                // unavailable instead of checking forever.
                file.capability = .unsupported
                file.capabilityFetchedAt = Date()
                capabilityCheckFailed = false
                persist()
                return
            }
            if file.capability == nil { capabilityCheckFailed = true }
            Self.logger.debug("capability refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}
