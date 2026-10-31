import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The single coordinator of downloads for the active server and profile.
/// It owns the scope's saved state, the background transfers and every step
/// between asking the server for a download and playing it offline.
@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    // MARK: Scope state (observed)

    /// The active scope's saved state. Every assignment, from any file,
    /// refreshes the derived values below and the Live Activity.
    var file: DownloadStoreFile = .empty {
        didSet { scopeStateChanged() }
    }

    /// The scope's capability is enabled and allowed.
    private(set) var downloadsEnabled = false
    /// A capability is stored for the scope.
    private(set) var hasDownloadAnswer = false
    /// The last capability check failed while none was known.
    private(set) var hasFailedCheck = false
    /// Bytes used by the scope's folder.
    private(set) var bytesOnDisk: Int64 = 0
    private(set) var currentScope: DownloadScope?
    private var checksInFlight = 0
    /// Registration keys in flight (episode id, else content id) and their tokens.
    var registrationKeys: [String: UUID] = [:]
    /// Leaf ids of every download with a file on the device. Replaced only
    /// when it changes, so poster badges don't redraw on progress.
    private var downloadedIndex: Set<String> = []
    /// Smoothed transfer rates in bytes per second, by record id.
    var transferRates: [String: Double] = [:]

    // MARK: The waiting list's state (kept file)

    @ObservationIgnored var waitingTask: Task<Void, Never>?
    @ObservationIgnored var isStartingWaiting = false

    // MARK: Work in flight

    let transfers: DownloadEngine.Transfers
    #if os(iOS)
    let liveActivity: DownloadLiveActivityController
    #endif
    /// Raised whenever the scope is invalidated or replaced. Work captured
    /// under an older value must not change the current scope.
    @ObservationIgnored var generation: UInt64 = 0
    /// On from moving to the background until active again: no slot limit.
    @ObservationIgnored var handOffMode = false
    /// Above 0 while a list of episodes registers; the queue waits.
    @ObservationIgnored var queueHold = 0
    @ObservationIgnored var preparations: [String: DownloadEngine.Running] = [:]
    @ObservationIgnored var retryTimers: [String: DownloadEngine.Running] = [:]
    @ObservationIgnored var heldRetries: [DownloadEngine.HeldRetry] = []
    @ObservationIgnored var preparationPoll: DownloadEngine.Running?
    @ObservationIgnored var pausePending: Set<String> = []
    @ObservationIgnored var resumeRequested: Set<String> = []
    /// Task identifiers whose cancellation the app asked for.
    @ObservationIgnored var intentionalCancels: Set<Int> = []
    @ObservationIgnored var lookedAtPreparing: Set<String> = []
    @ObservationIgnored var preparingLookFailures: [String: Int] = [:]
    @ObservationIgnored var deletedSinceDeactivation: Set<String> = []
    @ObservationIgnored var rateSamples: [String: DownloadEngine.RateSample] = [:]
    @ObservationIgnored var progressPublishedAt: [String: Date] = [:]
    @ObservationIgnored var lastSaveAt = Date.distantPast
    @ObservationIgnored var flushingProgress = false
    @ObservationIgnored var flushProgressAgain = false
    @ObservationIgnored var pullingProgress = false
    @ObservationIgnored private var holdingEvents = true
    @ObservationIgnored private var heldEvents: [DownloadEngine.TransferEvent] = []
    @ObservationIgnored private var completionHandler: (() -> Void)?
    @ObservationIgnored private var scopeLoad: DownloadEngine.ScopeLoad?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var backgroundHolds = 0
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {
        transfers = DownloadEngine.Transfers()
        #if os(iOS)
        liveActivity = DownloadLiveActivityController()
        #endif
        // Drained for the life of the process; nothing sent before is lost.
        let events = transfers.events
        Task { @MainActor [self] in
            for await event in events { receive(event) }
        }
    }

    // MARK: Derived state

    var capability: DownloadCapability? { file.capability }

    /// Every record of the scope, newest registration first.
    var records: [DownloadRecord] { DownloadEngine.Shelf.newestFirst(Array(file.records.values)) }

    var hasServerPreparingDownloads: Bool {
        file.records.values.contains { $0.localStatus == .preparing }
    }

    var isCheckingDownloads: Bool { checksInFlight > 0 }

    func isDownloaded(contentId: String) -> Bool {
        downloadedIndex.contains(contentId) && downloadsEnabled
    }

    private func scopeStateChanged() {
        let index = Set(file.records.values.lazy
            .filter { $0.localStatus == .completed || $0.localStatus == .revoked }
            .map(\.leafMediaItemId))
        if index != downloadedIndex { downloadedIndex = index }
        let enabled = file.capability?.isUsable == true
        if enabled != downloadsEnabled { downloadsEnabled = enabled }
        let known = file.capability != nil
        if known != hasDownloadAnswer { hasDownloadAnswer = known }
        #if os(iOS)
        let all = records
        liveActivity.sync(
            active: all.filter { $0.localStatus.isActive },
            completedIds: Set(all.lazy.filter { $0.localStatus == .completed }.map(\.id)),
            totalRate: transferRates.values.reduce(0, +)
        )
        #endif
    }

    // MARK: Saving

    /// Saves the scope state as it is now. Saves finish in the order asked.
    func persist() {
        guard let scope = currentScope else { return }
        lastSaveAt = Date()
        let state = file
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            await DownloadEngine.Store.shared.save(state, to: scope)
        }
    }

    /// The same ordered write, throwing its failure. Used by the Silo
    /// progress snapshot, which may write a staged copy of the state.
    func checkedSave(_ state: DownloadStoreFile) async throws {
        guard let scope = currentScope else { throw HTTPError.requestIdentityChanged }
        let previous = saveChain
        let write = Task { @MainActor () async throws -> Void in
            await previous?.value
            try await DownloadEngine.Store.shared.write(state, to: scope)
        }
        saveChain = Task { @MainActor in _ = try? await write.value }
        try await write.value
    }

    // MARK: Scope

    /// Loads the active scope's saved state. False without a server or profile.
    @discardableResult
    func activateScopeIfNeeded() async -> Bool {
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        guard !serverId.isEmpty, !profileId.isEmpty else {
            deactivate()
            releaseHeldEvents()
            return false
        }
        let target = DownloadScope(serverId: serverId, profileId: profileId)
        let loadingTarget = scopeLoad?.scope == target
        if target == currentScope, !loadingTarget, !(file.records.isEmpty && file.capability == nil) {
            releaseHeldEvents()
            return true
        }
        if target != currentScope {
            invalidatePendingRegistrations()
            currentScope = target
            hasFailedCheck = false
            holdingEvents = true
        }
        var load: DownloadEngine.ScopeLoad
        if let pending = scopeLoad, pending.scope == target {
            load = pending
        } else {
            scopeLoad?.task.cancel()
            load = DownloadEngine.ScopeLoad(target)
            scopeLoad = load
        }
        var installedHere = false
        while true {
            let state = await load.task.value
            guard currentScope == target else { return false }
            guard let pending = scopeLoad, pending.scope == target else { break }
            if pending.id == load.id {
                scopeLoad = nil
                file = state
                installedHere = true
                break
            }
            // A newer read of the same scope replaced this one.
            load = pending
        }
        releaseHeldEvents()
        if installedHere {
            refreshStorageUsage()
            await fillMissingEpisodeDetails()
        }
        return true
    }

    /// Leaves the scope: stops its work and empties the state. Files on disk
    /// stay, and running transfers carry on into their own scope's file.
    func deactivate() {
        preparationPoll?.task.cancel()
        preparationPoll = nil
        waitingTask?.cancel()
        waitingTask = nil
        for timer in retryTimers.values { timer.task.cancel() }
        retryTimers = [:]
        scopeLoad?.task.cancel()
        scopeLoad = nil
        pausePending = []
        resumeRequested = []
        lookedAtPreparing = []
        preparingLookFailures = [:]
        deletedSinceDeactivation = []
        invalidatePendingRegistrations()
        currentScope = nil
        hasFailedCheck = false
        rateSamples = [:]
        transferRates = [:]
        file = .empty
    }

    /// Any registration finishing after this fails, and every preparation stops.
    func invalidatePendingRegistrations() {
        generation &+= 1
        for preparation in preparations.values { preparation.task.cancel() }
        preparations = [:]
        registrationKeys = [:]
    }

    /// The token store's identity, only when it is this scope's account and profile.
    func scopeIdentity() async -> CapturedOrdinaryRequestAuth? {
        guard let scope = currentScope,
              let identity = await TokenStore.shared.captureOrdinaryRequestAuth(),
              identity.account.serverId == scope.serverId,
              identity.profileId == scope.profileId else { return nil }
        return identity
    }

    // MARK: Foreground and background

    /// The full foreground refresh.
    func onAppActive() async {
        guard await activateScopeIfNeeded() else { return }
        await refreshDownloadCheck()
        guard downloadsEnabled else { return }
        await reconcile(runningQueue: true)
        await startWaitingDownloads()
        scheduleWaitingDownloads()
        await syncMonitoringAndProgress()
        await backfillAssets()
    }

    /// Waits for a server switch to settle, loads the scope and makes sure
    /// the capability is known. True when downloads are available.
    func prepareForDownload() async -> Bool {
        guard await HTTPClient.shared.waitForRequestDispatchOpen() else { return false }
        guard await activateScopeIfNeeded() else { return false }
        if file.capability == nil || hasFailedCheck {
            await refreshDownloadCheck()
        }
        return downloadsEnabled
    }

    /// Asks the server what this profile may download.
    func refreshDownloadCheck() async {
        guard let scope = currentScope else { return }
        let generation = self.generation
        checksInFlight += 1
        defer { checksInFlight -= 1 }
        // Mid-switch there's no identity; the next account's activation checks.
        guard let identity = await scopeIdentity() else { return }
        let answer: DownloadCapability
        do {
            answer = try await VividAPI.shared.downloadCapability(auth: identity)
        } catch let error as HTTPError where error.statusCode == 404 || error.statusCode == 501 {
            // No downloads API on this server.
            answer = .unsupported
        } catch {
            guard currentScope == scope, self.generation == generation else { return }
            if file.capability == nil { hasFailedCheck = true }
            DownloadEngine.log.debug("Downloads capability check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard currentScope == scope, self.generation == generation else { return }
        var state = file
        state.capability = answer
        state.capabilityFetchedAt = Date()
        file = state
        hasFailedCheck = false
        persist()
    }

    /// The app is going to the background: hand every queued download to the
    /// background session now, before the app is suspended.
    func handOffQueuedTransfers() {
        guard currentScope != nil, downloadsEnabled else { return }
        handOffMode = true
        runQueue()
    }

    func resumeNormalPreparation() {
        handOffMode = false
    }

    /// Cancels running transfers and forgets the scope. Files on disk stay.
    func clearForSignOut() {
        for record in file.records.values where record.localStatus == .downloading {
            guard let task = record.taskIdentifier else { continue }
            intentionalCancels.insert(task)
            Task { await transfers.cancel(task) }
        }
        deactivate()
    }

    /// The system's handler for a background session relaunch, called once
    /// every event is delivered and pending saves have finished.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        completionHandler = handler
    }

    // MARK: Transfer events

    private func receive(_ event: DownloadEngine.TransferEvent) {
        if holdingEvents {
            heldEvents.append(event)
        } else {
            handle(event)
        }
    }

    /// Feeds an event back through the normal path, held while events are.
    func redeliver(_ event: DownloadEngine.TransferEvent) {
        receive(event)
    }

    private func releaseHeldEvents() {
        holdingEvents = false
        while !heldEvents.isEmpty, !holdingEvents {
            handle(heldEvents.removeFirst())
        }
    }

    private func handle(_ event: DownloadEngine.TransferEvent) {
        switch event {
        case let .progress(task, written, expected, tag):
            transferProgressed(task: task, written: written, expected: expected, tag: tag)
        case let .finished(task, staged, status, tag):
            transferFinished(task: task, staged: staged, status: status, tag: tag)
        case let .failed(task, status, resumeData, message, urlErrorCode, tag):
            transferFailed(task: task, status: status, resumeData: resumeData, message: message,
                           urlErrorCode: urlErrorCode, tag: tag)
        case .endOfDelivery:
            guard let handler = completionHandler else { return }
            completionHandler = nil
            let pending = saveChain
            Task { @MainActor in
                await pending?.value
                handler()
            }
        }
    }

    // MARK: Storage usage

    /// Walks the scope's folder off the main actor and publishes the total.
    func refreshStorageUsage() {
        guard let scope = currentScope else {
            bytesOnDisk = 0
            return
        }
        Task.detached(priority: .utility) {
            let total = DownloadEngine.Disk.bytesUnder(DownloadEngine.Disk.scopeDirectory(scope))
            await DownloadManager.shared.publishStorage(total)
        }
    }

    private func publishStorage(_ total: Int64) {
        bytesOnDisk = total
    }

    // MARK: Background time

    /// Keeps the app running briefly after it leaves the foreground, so work
    /// started just before reaches the background session.
    func holdBackgroundTime() {
        backgroundHolds += 1
        #if canImport(UIKit)
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Vivid downloads") {
            // The count stays, so a later hold starts a new task.
            MainActor.assumeIsolated { DownloadManager.shared.endBackgroundTask() }
        }
        #endif
    }

    func releaseBackgroundTime() {
        backgroundHolds = max(0, backgroundHolds - 1)
        if backgroundHolds == 0 { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        #if canImport(UIKit)
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        #endif
    }

    // MARK: Files

    /// A file in the record's folder. Nil without a scope.
    func fileURL(named name: String, forRecord id: String) -> URL? {
        guard let scope = currentScope else { return nil }
        return DownloadEngine.Disk.file(name, scope: scope, downloadId: id)
    }

    func mediaFileURL(for record: DownloadRecord) -> URL? {
        record.mediaFilename.flatMap { fileURL(named: $0, forRecord: record.id) }
    }

    /// Removes a download's folder. Nothing without a scope.
    func deleteFolder(ofRecord id: String) {
        guard let scope = currentScope else { return }
        DownloadEngine.Disk.remove(DownloadEngine.Disk.downloadDirectory(scope, downloadId: id))
    }

    /// The transfer tag for a record of the current scope.
    func transferTag(forRecord id: String) -> String? {
        currentScope.map { DownloadTaskTag(serverId: $0.serverId, profileId: $0.profileId, recordId: id).taskDescription }
    }

    var scopeProvider: MediaServerProvider {
        MediaServerProvider.forServerID(currentScope?.serverId)
    }
}

extension DownloadEngine {
    /// A piece of work the manager may cancel or replace, with its own id so
    /// a finished task only clears its own entry.
    struct Running {
        let id: UUID
        let task: Task<Void, Never>

        init(_ operation: @escaping @MainActor (UUID) async -> Void) {
            let id = UUID()
            self.id = id
            task = Task { @MainActor in await operation(id) }
        }
    }

    /// A shared read of one scope's file.
    struct ScopeLoad {
        let scope: DownloadScope
        let id = UUID()
        let task: Task<DownloadStoreFile, Never>

        init(_ scope: DownloadScope) {
            self.scope = scope
            task = Task { await Store.shared.load(scope) }
        }
    }

    struct RateSample {
        let bytes: Int64
        let at: Date
    }
}
