import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// The server and profile a download request belongs to.
struct DownloadScope: Equatable, Sendable {
    let serverId: String
    let profileId: String

    @MainActor
    static func current() async -> DownloadScope {
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        return DownloadScope(serverId: serverId, profileId: await TokenStore.shared.getProfileId() ?? "")
    }
}

enum DownloadError: LocalizedError {
    case unavailable
    case fileURLUnavailable
    case emptyRegistrationResponse
    case registrationAlreadyInFlight
    case scopeChangedDuringRegistration

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Downloads aren't available for this profile."
        case .fileURLUnavailable: return "Could not resolve the download URL."
        case .emptyRegistrationResponse: return "The server didn't create a download."
        case .registrationAlreadyInFlight: return "This download is already being prepared."
        case .scopeChangedDuringRegistration: return "The active profile changed before the download could start."
        }
    }
}

/// Coordinates the offline-downloads feature: capability gating, the local
/// registry, the background transfer pipeline, series-monitoring sync, and
/// offline progress reconciliation.
///
/// Concurrency model (the chosen hybrid): this is a single `@MainActor`
/// `@Observable` coordinator the UI reads directly, with all disk I/O
/// delegated to the `DownloadStore` actor and all media transfers to the
/// `DownloadSessionDelegate`'s background `URLSession`. The in-memory
/// `file` blob is the source of truth; every mutation persists through the
/// store actor.
@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Downloads"
    )

    /// Records preparing at once (manifest fetch and transfer hand-off).
    /// Media transfers themselves aren't capped here: they go straight to the
    /// background session, which spaces its own connections, so a whole
    /// season keeps downloading after the app is closed.
    private static let maxConcurrentPreparations = 3
    private static let maxRetries = 4

    /// In-memory persisted blob. `private(set)` so the `@Observable` macro
    /// tracks reads of its derived accessors below.
    private(set) var file: DownloadStoreFile = .empty {
        didSet {
            rebuildDownloadedIndex()
            let enabled = file.capability?.isUsable == true
            if enabled != downloadsEnabled { downloadsEnabled = enabled }
            let known = file.capability != nil
            if known != capabilityKnown { capabilityKnown = known }
            syncLiveActivity()
        }
    }

    private(set) var scopeServerId: String = ""
    private(set) var scopeProfileId: String = ""

    /// Coalesces the several legitimate app-lifecycle callers that can all ask
    /// for the same scope at launch. Without this, a late disk read can replace
    /// a newly registered in-memory download with its older empty snapshot.
    private var scopeLoadTask: Task<DownloadStoreFile, Never>?
    private var scopeLoadToken: UUID?
    private var scopeLoadServerId = ""
    private var scopeLoadProfileId = ""

    private let sessionDelegate = DownloadSessionDelegate()
    private var intentionalCancels: Set<Int> = []
    /// Preparing downloads whose poster and size estimate were already
    /// fetched this session (`prefetchPreparingDetails`), and how many times
    /// a manifest request failed for the rest.
    private var preparingDetailsFetched: Set<String> = []
    private var preparingDetailsAttempts: [String: Int] = [:]
    /// Set while `downloadEpisodes` registers a list. Transfers wait for the
    /// whole list: Silo counts transferring files against its per-user
    /// limit, so starting them early would get the rest of the list refused.
    private var queueHolds = 0
    /// Retries that came due while `queueHolds` was set; they start when the
    /// hold ends, for the same reason the queue waits.
    private var heldRetries: [() -> Void] = []
    /// Downloads deleted in the current scope. A list that was in flight
    /// during a delete can still return the row, which must not come back.
    /// Cleared on a scope change, which also drops any list in flight; each
    /// scope's unsent deletes stay in its own `pendingServerDeletes`.
    private var deletedDownloadIds: Set<String> = []
    private var pollTask: Task<Void, Never>?
    private var lastProgressPersist = Date.distantPast
    /// Session events that arrive before the first scope activation loads the
    /// persisted registry (a background relaunch replays buffered delegate
    /// events the moment the session is recreated). Handling them against an
    /// empty registry would discard finished media as unmatched, so they are
    /// held here and replayed by `releaseHeldSessionEvents()`.
    private var pendingSessionEvents: [DownloadSessionEvent] = []
    private var sessionEventsHeld = true
    /// In-flight back-off timers keyed by record id, tracked so a foreground
    /// reconcile doesn't re-queue a record that already has a scheduled
    /// restart (double-starting the transfer) and so pause/delete can abort
    /// the timer instead of leaving it to fire against a dead record.
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Records whose pause is still waiting on the resume-data capture
    /// round-trip. A resume tapped inside that window is deferred to
    /// `finishPause` (via `pendingResumeIds`) so the captured data isn't
    /// dropped and the transfer restarted from byte zero.
    private var pendingPauseIds: Set<String> = []
    private var pendingResumeIds: Set<String> = []
    /// Serializes disk saves so a rapid burst of `persist()` calls can't land
    /// out of order and overwrite a newer snapshot with an older one.
    private var saveChain: Task<Void, Never>?
    /// Cached scope storage usage; refreshed off the MainActor (a filesystem
    /// walk) so SwiftUI bodies reading `totalBytesUsed` don't block.
    private(set) var storageBytesUsed: Int64 = 0
    /// Smoothed transfer rate (bytes/sec) per downloading record, derived
    /// from progress deltas so the UI never needs its own timer competing
    /// with the `@Observable` update path.
    private(set) var transferRates: [String: Double] = [:]
    private var rateSamples: [String: (bytes: Int64, at: Date)] = [:]
    private static let rateSampleInterval: TimeInterval = 0.5
    private static let rateSmoothing = 0.3
    /// Last time each record's byte counter was published into the
    /// `@Observable` `file` blob. Delegate callbacks arrive many times per
    /// second; UI counters should tick at a readable cadence instead.
    private var lastProgressPublish: [String: Date] = [:]
    private static let progressPublishInterval: TimeInterval = 1.0

    private init() {
        // Drain background-session events for the lifetime of the app.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.sessionDelegate.events {
                self.handleSessionEvent(event)
            }
        }
    }

    // MARK: - Observable surface

    var capability: DownloadCapability? { file.capability }
    /// Stored mirror of `capability?.isUsable`, maintained by `file`'s
    /// `didSet`, so hot per-card checks (`isDownloaded`) never register the
    /// whole `file` blob — reassigned on every transfer progress tick — as
    /// their observed state.
    private(set) var downloadsEnabled: Bool = false
    /// Stored mirror of `capability != nil`: whether this account's download
    /// permission has been answered yet. Until it has, download controls stay
    /// usable and check again on tap instead of claiming downloads are off.
    private(set) var capabilityKnown = false
    private(set) var capabilityChecksInFlight = 0
    /// The last permission check failed and nothing earlier is known.
    private(set) var capabilityCheckFailed = false
    var isCheckingCapability: Bool { capabilityChecksInFlight > 0 }
    /// Downloads are known to be off for this account, so the controls show
    /// crossed out rather than disappearing.
    var downloadsDisallowed: Bool { capabilityKnown && !downloadsEnabled }
    /// Background time held while a download is registered or handed to the
    /// background session, so work started just before the app closes still
    /// reaches the transfer.
    @ObservationIgnored private var backgroundWorkCount = 0
    /// Set while the app is leaving the foreground, so every queued record
    /// is prepared at once rather than a few at a time.
    @ObservationIgnored private var preparesEverything = false
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundWorkID = UIBackgroundTaskIdentifier.invalid
    #endif
    /// Leaf ids currently waiting for POST /downloads to return. This belongs
    /// to the manager (rather than one button) so a detail rebuild cannot make
    /// the preparing indicator disappear during registration.
    private(set) var pendingRegistrationContentIds: Set<String> = []
    /// Each pending id owns a unique token. An older request may finish after
    /// sign-out and reactivation, but its defer must never clear a newer
    /// request for the same content id.
    private var pendingRegistrationTokens: [String: UUID] = [:]
    /// Incremented whenever the active server/profile identity is invalidated
    /// or replaced. Network responses captured under an older generation are
    /// discarded before they can mutate the newly active scope.
    private var registrationScopeGeneration: UInt64 = 0
    private var pipelineTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    var canDownloadSeason: Bool { downloadsEnabled && capability?.seasonDownload == true }
    /// Season and series downloads may use a smaller quality, not just original.
    var canChooseBatchQuality: Bool { downloadsEnabled && capability?.bulkQuality == true && availableFormats.count > 1 }
    /// Downloads the server is still converting, which only advance while the
    /// app can check on them.
    var hasServerPreparingDownloads: Bool { file.records.values.contains { $0.localStatus == .preparing } }
    var canMonitorSeries: Bool { downloadsEnabled && capability?.seriesMonitoring == true }

    /// The tallest output a preset makes on this server: what the server
    /// reports, or the shared ladder.
    func maxHeight(for format: DownloadFormat) -> Int? {
        capability?.qualityOptions.first { $0.preset == format.rawValue }?.maxHeight ?? format.ladderMaxHeight
    }

    /// "4K · 20 Mbps", "1080p · 10 Mbps" or "Original".
    func qualityLabel(_ format: DownloadFormat) -> String {
        format.qualityLabel(maxHeight: maxHeight(for: format))
    }

    func qualityLabel(rawValue: String) -> String {
        DownloadFormat(rawValue: rawValue).map(qualityLabel) ?? rawValue
    }

    /// "About 4.59 GB per hour" for a smaller preset, nil for original.
    static func sizePerHour(_ format: DownloadFormat) -> String? {
        StreamedTranscodeDownload.estimatedBytes(format: format, durationSeconds: 3600)
            // Not `DownloadFormatting`, which only the iOS views compile.
            .map { "About \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) per hour" }
    }

    var availableFormats: [DownloadFormat] {
        (capability?.qualityPresets ?? []).compactMap(DownloadFormat.init(rawValue:))
    }

    var monitoringModes: [SubscriptionMode] {
        (capability?.monitoringModes ?? []).compactMap(SubscriptionMode.init(rawValue:))
    }

    /// All records, newest first.
    var records: [DownloadRecord] {
        file.records.values.sorted { $0.registeredAt > $1.registeredAt }
    }

    var activeRecords: [DownloadRecord] { records.filter { $0.localStatus.isActive } }
    var completedRecords: [DownloadRecord] { records.filter { !$0.localStatus.isActive } }
    var subscriptions: [DownloadSubscription] { file.subscriptions }

    var totalBytesUsed: Int64 { storageBytesUsed }

    // MARK: - Lookups

    /// Leaf content ids (movie `contentId` / episode `episodeId`) whose media
    /// is on disk. Cached separately from `records` because poster cards check
    /// membership per card render — and only republished when membership
    /// actually changes, so in-flight progress ticks (which also mutate `file`)
    /// don't invalidate every visible card.
    private(set) var downloadedContentIds: Set<String> = []

    /// Single capability-aware check for the card badges: true only when the
    /// server still advertises downloads for this profile *and* the item's
    /// media is on device, so badges vanish alongside every other download
    /// affordance on servers without the capability. Membership is checked
    /// first so the (overwhelmingly common) non-downloaded card never touches
    /// the capability flag at all.
    func isDownloaded(contentId: String) -> Bool {
        downloadedContentIds.contains(contentId) && downloadsEnabled
    }

    private func rebuildDownloadedIndex() {
        // Revoked downloads keep their on-device file (playable offline),
        // so they badge the same as completed ones.
        let ids = Set(
            file.records.values
                .filter { $0.localStatus == .completed || $0.localStatus == .revoked }
                .map { $0.episodeId ?? $0.contentId }
        )
        if ids != downloadedContentIds {
            downloadedContentIds = ids
        }
    }

    /// The download record for a leaf content id (movie or episode), if any.
    func record(forContentId contentId: String) -> DownloadRecord? {
        file.records.values.first { $0.contentId == contentId || $0.episodeId == contentId }
    }

    func isRegistering(contentId: String) -> Bool {
        pendingRegistrationContentIds.contains(contentId)
    }

    func record(id: String) -> DownloadRecord? { file.records[id] }

    func subscription(forSeriesId seriesId: String) -> DownloadSubscription? {
        file.subscriptions.first { $0.seriesId == seriesId }
    }

    func absoluteMediaURL(for record: DownloadRecord) -> URL? {
        guard let filename = record.mediaFilename, !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id,
            filename: filename
        )
    }

    func absoluteFileURL(for record: DownloadRecord, filename: String) -> URL? {
        guard !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id,
            filename: filename
        )
    }

    func localProgress(forMediaItemId mediaItemId: String) -> LocalProgressEntry? {
        file.localProgress[mediaItemId]
    }

    /// On-disk poster image for a record — present once the asset pipeline
    /// has fetched artwork, which runs before the media transfer starts, so
    /// in-progress rows can show real art rather than a placeholder.
    func posterImageURL(for record: DownloadRecord) -> URL? {
        record.posterFilename.flatMap { absoluteFileURL(for: record, filename: $0) }
    }

    func transferRate(id: String) -> Double? {
        transferRates[id]
    }

    /// Decode the on-disk offline manifest for a completed download. The file
    /// read + decode happens on the `DownloadStore` actor, off the MainActor.
    func loadManifest(for record: DownloadRecord) async -> OfflineManifest? {
        guard let filename = record.manifestFilename,
              let url = absoluteFileURL(for: record, filename: filename) else {
            return nil
        }
        return await DownloadStore.shared.loadManifest(at: url)
    }

    // MARK: - Grouped surface (Downloads redesign)

    /// Whether this download's leaf item has been watched to completion —
    /// drives the reclaim suggestion and the "watched" episode dimming.
    func isWatched(_ record: DownloadRecord) -> Bool {
        file.localProgress[record.leafMediaItemId]?.completed == true
    }

    /// Completed/revoked records that physically occupy storage and can be
    /// browsed offline. Excludes failed and in-flight records.
    var onDeviceRecords: [DownloadRecord] {
        records.filter { $0.localStatus == .completed || $0.localStatus == .revoked }
    }

    /// Standalone downloaded movies (no parent series).
    var movieRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.seriesId == nil }
    }

    /// Downloaded episodes grouped by series, then season — the spine of the
    /// redesigned Downloads list and the offline series-browse screen.
    var seriesGroups: [DownloadSeriesGroup] {
        DownloadGroupBuilder.seriesGroups(
            from: onDeviceRecords,
            isWatched: { isWatched($0) },
            seriesTitle: { subscription(forSeriesId: $0)?.seriesTitle },
            isMonitored: { subscription(forSeriesId: $0) != nil }
        )
    }

    /// Records downloaded *and* watched to completion — the set the
    /// "Free up space" suggestion offers to delete.
    var reclaimableRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.localStatus == .completed && isWatched($0) }
    }

    var reclaimableBytes: Int64 {
        reclaimableRecords.reduce(0) { $0 + $1.fileSize }
    }

    /// Storage split for the hero bar: series vs movies (summed from record
    /// sizes), in-flight transfer bytes (from active records' progress —
    /// invisible to the on-disk walk while the media sits in the session's
    /// staging area), plus an "other" remainder (artwork/manifests/
    /// subtitles) derived from the true on-disk total.
    var storageBreakdown: DownloadStorageBreakdown {
        var series: Int64 = 0
        var movies: Int64 = 0
        for record in onDeviceRecords {
            if record.seriesId == nil { movies += record.fileSize }
            else { series += record.fileSize }
        }
        let inProgress = records.reduce(Int64(0)) {
            $0 + ($1.localStatus.isActive ? $1.bytesDownloaded : 0)
        }
        let other = max(0, storageBytesUsed - series - movies)
        return DownloadStorageBreakdown(
            series: series,
            movies: movies,
            inProgress: inProgress,
            other: other
        )
    }

    /// Total bytes downloaded for one series across all seasons.
    func bytesForSeries(_ seriesId: String) -> Int64 {
        onDeviceRecords
            .filter { $0.seriesId == seriesId }
            .reduce(0) { $0 + $1.fileSize }
    }

    /// The unified, sorted list the Manager renders: one entry per series
    /// group and one per standalone movie.
    func downloadListItems(sortedBy option: DownloadSortOption) -> [DownloadListItem] {
        var items = seriesGroups.map(DownloadListItem.series)
        items += movieRecords.map(DownloadListItem.movie)
        return DownloadGroupBuilder.sorted(items, by: option)
    }

    /// Delete several downloads in one pass: one store write, one storage
    /// recompute, and the server DELETEs fanned out in a single task.
    func deleteDownloads(ids: [String]) {
        var removed = false
        for id in ids {
            guard let record = file.records[id] else { continue }
            pipelineTasks.removeValue(forKey: id)?.task.cancel()
            if let taskId = record.taskIdentifier {
                intentionalCancels.insert(taskId)
                sessionDelegate.cancel(taskId: taskId)
            }
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            file.records.removeValue(forKey: id)
            clearTransferRate(recordId: id)
            if !scopeServerId.isEmpty {
                DownloadFilePaths.removeDownloadDirectory(
                    serverId: scopeServerId,
                    profileId: scopeProfileId,
                    downloadId: id
                )
            }
            removed = true
        }
        guard removed else { return }
        persist()
        deleteServerRows(ids)
        processQueue()
        refreshStorageUsage()
    }

    /// Delete server rows with this scope's own sign-in. If the sign-in has
    /// already moved to another account the deletes wait in this scope's
    /// registry and go out the next time it's active.
    private func deleteServerRows(_ ids: [String]) {
        guard !scopeServerId.isEmpty, !ids.isEmpty else { return }
        deletedDownloadIds.formUnion(ids)
        file.pendingServerDeletes = Array(Set(file.pendingServerDeletes ?? []).union(ids))
        persist()
        flushPendingServerDeletes()
    }

    private func flushPendingServerDeletes() {
        let serverId = scopeServerId
        let profileId = scopeProfileId
        let ids = file.pendingServerDeletes ?? []
        guard !serverId.isEmpty, !ids.isEmpty else { return }
        Task { @MainActor in
            guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
                  auth.account.serverId == serverId, auth.profileId == profileId else { return }
            var deleted: Set<String> = []
            for id in ids {
                do {
                    try await VividAPI.shared.deleteDownloadRow(id: id, auth: auth)
                    deleted.insert(id)
                } catch HTTPError.http(let status, _) where status == 404 {
                    deleted.insert(id)
                } catch {
                    // Kept for the next attempt.
                }
            }
            guard !deleted.isEmpty, serverId == self.scopeServerId, profileId == self.scopeProfileId else { return }
            let remaining = (self.file.pendingServerDeletes ?? []).filter { !deleted.contains($0) }
            self.file.pendingServerDeletes = remaining.isEmpty ? nil : remaining
            self.persist()
        }
    }

    /// Unfinished downloads (queued, preparing, transferring or paused) of one
    /// series, matched by series or by the batch's series content id.
    func activeRecords(seriesId: String) -> [DownloadRecord] {
        records.filter { $0.localStatus.isActive && ($0.seriesId == seriesId || $0.contentId == seriesId) }
    }

    /// Cancel every unfinished download of a series. Finished episodes stay.
    func cancelActiveDownloads(seriesId: String) {
        deleteDownloads(ids: activeRecords(seriesId: seriesId).map(\.id))
    }

    /// Cancel every unfinished download in this profile. Finished ones stay.
    func cancelAllActiveDownloads() {
        deleteDownloads(ids: activeRecords.map(\.id))
    }

    /// One-time hydration of `seasonNumber`/`episodeNumber`/`seriesTitle` for
    /// episode downloads created before those fields existed. A cheap no-op
    /// once every record carries them.
    private func backfillEpisodeMetadataIfNeeded() async {
        let needing = file.records.values.filter {
            $0.seriesId != nil
                && $0.manifestFilename != nil
                && ($0.seasonNumber == nil || $0.seriesTitle == nil)
        }
        guard !needing.isEmpty else { return }
        var changed = false
        for record in needing {
            guard let manifest = await loadManifest(for: record),
                  var current = file.records[record.id] else { continue }
            if current.seasonNumber == nil { current.seasonNumber = manifest.seasonNumber }
            if current.episodeNumber == nil { current.episodeNumber = manifest.episodeNumber }
            if current.seriesTitle == nil { current.seriesTitle = manifest.seriesTitle }
            file.records[record.id] = current
            changed = true
        }
        if changed { persist() }
    }

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

    // MARK: - Public download actions

    func downloadMovie(
        contentId: String,
        displayTitle: String?,
        year: Int?,
        posterThumbhash: String?,
        fileId: Int? = nil,
        quality: String? = nil
    ) async throws {
        try await requestDownload(
            contentId: contentId,
            fileId: fileId,
            quality: quality,
            type: "movie",
            displayTitle: displayTitle,
            displaySubtitle: year.map(String.init),
            posterThumbhash: posterThumbhash
        )
    }

    func downloadEpisode(
        seriesId: String,
        episodeId: String,
        displayTitle: String?,
        displaySubtitle: String?,
        seriesTitle: String? = nil,
        posterThumbhash: String?,
        preferredPosterPath: String? = nil,
        fileId: Int? = nil,
        quality: String? = nil,
        scope: DownloadScope? = nil
    ) async throws {
        try await requestDownload(
            contentId: seriesId,
            episodeId: episodeId,
            fileId: fileId,
            quality: quality,
            scope: scope,
            type: "episode",
            seriesId: seriesId,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle,
            seriesTitle: seriesTitle,
            posterThumbhash: posterThumbhash,
            preferredPosterPath: preferredPosterPath
        )
    }

    func downloadSeason(
        seriesId: String,
        seasonNumber: Int,
        seriesTitle: String?,
        posterThumbhash: String?,
        preferredPosterPath: String?,
        quality: String? = nil
    ) async throws {
        try await requestDownload(
            contentId: seriesId,
            quality: quality,
            series: true,
            seasonNumber: seasonNumber,
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            posterThumbhash: posterThumbhash,
            preferredPosterPath: preferredPosterPath
        )
    }

    func downloadSeries(
        seriesId: String,
        seriesTitle: String?,
        posterThumbhash: String?,
        preferredPosterPath: String?,
        quality: String? = nil
    ) async throws {
        try await requestDownload(
            contentId: seriesId,
            quality: quality,
            series: true,
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            posterThumbhash: posterThumbhash,
            preferredPosterPath: preferredPosterPath
        )
    }

    struct EpisodeRegistrationResult {
        var added = 0
        /// Already downloaded or on their way, or known to have no file.
        var skipped = 0
        var failures: [Error] = []
        var stoppedBySwitch = false

        /// What to tell the user, or nil when everything asked for was added.
        var problem: String? {
            let addedText = "\(added) episode\(added == 1 ? " was" : "s were") added."
            if stoppedBySwitch {
                return "The server or profile changed, so the rest weren't added. " + addedText
            }
            if let first = failures.first {
                let count = failures.count
                return "\(count) episode\(count == 1 ? "" : "s") couldn't be added: \(first.localizedDescription) " + addedText
            }
            if added == 0, skipped > 0 {
                return "Nothing new to add. These episodes are already downloaded, on their way, or don't have a file yet."
            }
            return nil
        }
    }

    /// Registers episodes one request each: hand-picked episodes, or every
    /// episode of a season or series at a chosen original version, which
    /// Silo's season and series requests can't express. Each episode gets
    /// the file matching `version` (nil, or no match, leaves the pick to the
    /// server). Episodes already downloaded or on their way, and episodes
    /// with no file, are skipped; a failure doesn't stop the rest. Stops if
    /// the server or profile changes part way through.
    func downloadEpisodes(
        _ episodes: [EpisodeListItem],
        seriesId: String,
        seriesTitle: String?,
        posterThumbhash: String?,
        preferredPosterPath: String?,
        quality: String,
        version: DownloadVersionPreference?,
        scope expectedScope: DownloadScope? = nil
    ) async -> EpisodeRegistrationResult {
        var result = EpisodeRegistrationResult()
        // The account the episodes were listed on; a caller that fetched
        // them first passes the one it started with.
        let scope: DownloadScope
        if let expectedScope { scope = expectedScope } else { scope = await DownloadScope.current() }
        queueHolds += 1
        defer {
            queueHolds -= 1
            processQueue()
            startHeldRetries()
        }
        for episode in episodes {
            guard await DownloadScope.current() == scope else {
                result.stoppedBySwitch = true
                break
            }
            // An empty list means the episode has no file (missing or not
            // aired yet); nil only means the server didn't say.
            let files = episode.files ?? []
            let existing = record(forContentId: episode.contentId)
            guard episode.files?.isEmpty != true, existing == nil || existing?.localStatus == .failed,
                  !isRegistering(contentId: episode.contentId) else {
                result.skipped += 1
                continue
            }
            do {
                try await downloadEpisode(
                    seriesId: seriesId,
                    episodeId: episode.contentId,
                    displayTitle: episode.title ?? "Episode \(episode.episodeNumber)",
                    displaySubtitle: "S\(episode.seasonNumber) · E\(episode.episodeNumber)",
                    seriesTitle: seriesTitle,
                    posterThumbhash: posterThumbhash,
                    preferredPosterPath: preferredPosterPath,
                    fileId: version?.file(in: files)?.fileId,
                    quality: version == nil ? quality : DownloadFormat.original.rawValue,
                    scope: scope
                )
                result.added += 1
            } catch DownloadError.registrationAlreadyInFlight {
                result.skipped += 1
            } catch DownloadError.scopeChangedDuringRegistration {
                result.stoppedBySwitch = true
                break
            } catch {
                // A request cut short by a switch isn't a download failure.
                if await DownloadScope.current() != scope {
                    result.stoppedBySwitch = true
                    break
                }
                result.failures.append(error)
            }
        }
        return result
    }

    private func requestDownload(
        contentId: String,
        episodeId: String? = nil,
        fileId: Int? = nil,
        quality requestedQuality: String? = nil,
        scope expectedScope: DownloadScope? = nil,
        series: Bool = false,
        seasonNumber: Int? = nil,
        type: String? = nil,
        seriesId: String? = nil,
        displayTitle: String? = nil,
        displaySubtitle: String? = nil,
        seriesTitle: String? = nil,
        posterThumbhash: String? = nil,
        preferredPosterPath: String? = nil
    ) async throws {
        // The item belongs to the account that was active when it was asked
        // for; a switch while preparing must not send it to the next one.
        // A list of episodes passes the account it started on, so one
        // switching part way can't take the rest with it.
        let current = await DownloadScope.current()
        let requestedServerId = expectedScope?.serverId ?? current.serverId
        let requestedProfileId = expectedScope?.profileId ?? current.profileId
        guard expectedScope == nil || expectedScope == current else { throw DownloadError.scopeChangedDuringRegistration }
        guard await prepareForDownload() else { throw DownloadError.unavailable }
        guard requestedServerId == scopeServerId, requestedProfileId == scopeProfileId,
              let registrationAuth = await scopeAuth() else {
            throw DownloadError.scopeChangedDuringRegistration
        }

        let registrationContentId = episodeId ?? contentId
        guard pendingRegistrationTokens[registrationContentId] == nil else {
            throw DownloadError.registrationAlreadyInFlight
        }
        let registrationToken = UUID()
        let capturedScopeGeneration = registrationScopeGeneration
        let capturedServerId = scopeServerId
        let capturedProfileId = scopeProfileId
        pendingRegistrationTokens[registrationContentId] = registrationToken
        pendingRegistrationContentIds.insert(registrationContentId)
        beginBackgroundWork()
        defer {
            finishPendingRegistration(
                contentId: registrationContentId,
                token: registrationToken
            )
            endBackgroundWork()
        }

        // Series/season batches take a smaller quality only where the server
        // says so (`bulkQuality`); otherwise they stay original. Single items
        // may use any advertised public quality preset.
        let isBatch = series || seasonNumber != nil
        let quality = isBatch && capability?.bulkQuality != true
            ? DownloadFormat.original.rawValue
            : resolvedDownloadQuality(requestedQuality)

        var request = CreateDownloadRequest(
            contentId: contentId,
            episodeId: episodeId,
            fileId: fileId,
            quality: quality,
            series: series ? true : nil,
            seasonNumber: seasonNumber,
            caps: DownloadCaps.current()
        )
        if isBatch {
            request.batchId = registrationToken.uuidString
        } else {
            let existing = file.records.values.first { ($0.episodeId ?? $0.contentId) == registrationContentId }
            request.expectedRevision = existing?.revision ?? 0
            if (request.expectedRevision ?? 0) > 0 { request.expectedDownloadId = existing?.id }
        }
        let rows: [ServerDownloadRow]
        do {
            rows = try await VividAPI.shared.createDownload(request, auth: registrationAuth)
            guard !rows.isEmpty else { throw DownloadError.emptyRegistrationResponse }
        } catch {
            // A request overtaken by an account, server or profile switch
            // isn't a failure, and the active provider is no longer its own.
            if capturedScopeGeneration == registrationScopeGeneration,
               capturedServerId == scopeServerId, capturedProfileId == scopeProfileId,
               let failure = DownloadFailureReport(stage: .registration, error: error,
                                                   server: MediaServerProvider.forServerID(capturedServerId).rawValue,
                                                   quality: quality, batch: isBatch, retries: 0) {
                AppHealthMonitor.downloadFailed(failure)
            }
            throw error
        }
        guard capturedScopeGeneration == registrationScopeGeneration,
              capturedServerId == scopeServerId,
              capturedProfileId == scopeProfileId else {
            throw DownloadError.scopeChangedDuringRegistration
        }
        for row in rows {
            upsertRow(
                row,
                displayTitle: rows.count == 1 ? displayTitle : nil,
                displaySubtitle: rows.count == 1 ? displaySubtitle : nil,
                type: type,
                seriesId: seriesId,
                seriesTitle: seriesTitle,
                posterThumbhash: posterThumbhash,
                preferredPosterPath: preferredPosterPath
            )
        }
        persist()
        processQueue()
        ensurePolling()
    }

    private func invalidatePendingRegistrations() {
        registrationScopeGeneration &+= 1
        for pipeline in pipelineTasks.values { pipeline.task.cancel() }
        pipelineTasks.removeAll()
        pendingRegistrationTokens.removeAll()
        pendingRegistrationContentIds.removeAll()
    }

    private func finishPendingRegistration(contentId: String, token: UUID) {
        guard pendingRegistrationTokens[contentId] == token else { return }
        pendingRegistrationTokens.removeValue(forKey: contentId)
        pendingRegistrationContentIds.remove(contentId)
    }

    private func resolvedDownloadQuality(_ requestedQuality: String?) -> String {
        let allowed = capability?.qualityPresets ?? []
        if let requestedQuality, allowed.contains(requestedQuality) {
            return requestedQuality
        }
        return DownloadSettings.shared.resolvedFormat(allowedFormats: allowed)
    }

    func deleteDownload(id: String) {
        guard let record = file.records[id] else { return }
        pipelineTasks.removeValue(forKey: id)?.task.cancel()
        if let taskId = record.taskIdentifier {
            intentionalCancels.insert(taskId)
            sessionDelegate.cancel(taskId: taskId)
        }
        retryTasks[id]?.cancel()
        retryTasks[id] = nil
        file.records.removeValue(forKey: id)
        clearTransferRate(recordId: id)
        persist()
        if !scopeServerId.isEmpty {
            DownloadFilePaths.removeDownloadDirectory(
                serverId: scopeServerId,
                profileId: scopeProfileId,
                downloadId: id
            )
        }
        deleteServerRows([id])
        processQueue()
        refreshStorageUsage()
    }

    func deleteDownload(forContentId contentId: String) {
        if let record = record(forContentId: contentId) {
            deleteDownload(id: record.id)
        }
    }

    /// Suspend an in-flight media transfer. The status flips to `.paused`
    /// synchronously (so the UI responds on the tap) and the resume data is
    /// captured asynchronously — the task identifier stays on the record
    /// until then so a transfer that finishes during the race still
    /// completes normally instead of being discarded.
    func pauseDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .downloading else { return }
        guard let taskId = record.taskIdentifier else {
            // No live task: the record is waiting out a retry back-off.
            // Abort the timer and park the record so the pause control isn't
            // dead during the window; resume re-queues from scratch.
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            record.localStatus = .paused
            file.records[id] = record
            clearTransferRate(recordId: id)
            persist()
            processQueue()
            return
        }
        intentionalCancels.insert(taskId)
        pendingPauseIds.insert(id)
        record.localStatus = .paused
        file.records[id] = record
        clearTransferRate(recordId: id)
        persist()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.sessionDelegate.pause(taskId: taskId)
            self.finishPause(recordId: id, resumeData: data)
        }
        processQueue()
    }

    /// Continue a paused transfer. Routed through the queue so resumes honor
    /// the concurrency cap — `processQueue` starts the record from its
    /// captured resume data when present, falling back to a full restart
    /// (same server registration, byte zero) when the data is missing,
    /// unreadable, or was never produced.
    func resumeDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .paused else { return }
        // The pause's resume-data capture is still in flight — flag the
        // intent and let `finishPause` re-queue with the data instead of
        // discarding the partial transfer.
        if pendingPauseIds.contains(id) {
            pendingResumeIds.insert(id)
            return
        }
        record.localStatus = .queued
        file.records[id] = record
        persist()
        processQueue()
    }

    /// Lands after `pause(taskId:)` resolves. Guarded on `.paused` because
    /// the transfer may have finished (or the record been deleted) during
    /// the cancel round-trip — clobbering the newer state would orphan it.
    /// A resume requested mid-round-trip re-queues here, once the captured
    /// data is on disk, rather than restarting from byte zero.
    private func finishPause(recordId: String, resumeData: Data?) {
        pendingPauseIds.remove(recordId)
        let resumeRequested = pendingResumeIds.remove(recordId) != nil
        guard var record = file.records[recordId], record.localStatus == .paused else { return }
        record.taskIdentifier = nil
        if let resumeData,
           let url = absoluteFileURLForNewAsset(recordId: recordId, filename: "resume.bin") {
            try? resumeData.write(to: url, options: .atomic)
            record.resumeDataFilename = "resume.bin"
        }
        if resumeRequested {
            record.localStatus = .queued
        }
        file.records[recordId] = record
        persist()
        if resumeRequested { processQueue() }
    }

    func retryDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .failed else { return }
        record.localStatus = .queued
        record.retryCount = 0
        record.lastError = nil
        file.records[id] = record
        persist()
        processQueue()
    }

    // MARK: - Pipeline

    /// Leaving the app: hand every queued download to the background session
    /// now, while Vivid still has time to run, instead of leaving episodes
    /// waiting for a wake-up that iOS may delay once the phone locks.
    func handOffQueuedTransfers() {
        // Nothing to hand off for a signed-out scope or an account that
        // can't download; retained records stay where they are.
        guard !scopeServerId.isEmpty, downloadsEnabled else { return }
        preparesEverything = true
        processQueue()
    }

    func resumeNormalPreparation() {
        preparesEverything = false
    }

    private func processQueue() {
        // Held while a list of episodes is registered one by one.
        guard queueHolds == 0 else { return }
        let preparingCount = file.records.values.filter { $0.localStatus == .fetchingAssets }.count
        var slots = preparesEverything ? Int.max : max(0, Self.maxConcurrentPreparations - preparingCount)
        guard slots > 0 else { return }

        let queued = file.records.values
            .filter { $0.localStatus == .queued }
            .sorted { $0.registeredAt < $1.registeredAt }

        for record in queued where slots > 0 {
            // Reserve the slot synchronously so a second pass doesn't pick
            // the same record before its async pipeline flips the status.
            guard !exceedsStorageCap(for: record) else { continue }
            slots -= 1
            startQueuedRecord(record)
        }
    }

    /// Start one queued record, preferring its captured resume data (a
    /// paused transfer) so completed byte ranges aren't refetched; missing
    /// or unreadable data falls back to the full pipeline restart.
    private func startQueuedRecord(_ record: DownloadRecord) {
        var record = record
        if let filename = record.resumeDataFilename,
           let url = absoluteFileURL(for: record, filename: filename) {
            let resumeData = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            record.resumeDataFilename = nil
            if let resumeData {
                record.taskIdentifier = sessionDelegate.resume(data: resumeData, tag: taskTag(recordId: record.id))
                record.localStatus = .downloading
                file.records[record.id] = record
                persist()
                return
            }
            record.bytesDownloaded = 0
            file.records[record.id] = record
        }
        setLocalStatus(.fetchingAssets, id: record.id)
        launchMediaPipeline(recordId: record.id)
    }

    private func launchMediaPipeline(recordId: String) {
        pipelineTasks.removeValue(forKey: recordId)?.task.cancel()
        let generation = registrationScopeGeneration
        let id = UUID()
        let task = Task { @MainActor in
            await self.startMediaPipeline(recordId: recordId, generation: generation)
            if self.pipelineTasks[recordId]?.id == id { self.pipelineTasks[recordId] = nil }
        }
        pipelineTasks[recordId] = (id, task)
    }

    private func pipelineIsCurrent(recordId: String, generation: UInt64) -> Bool {
        !Task.isCancelled && generation == registrationScopeGeneration && file.records[recordId] != nil
    }

    private func startMediaPipeline(recordId: String, generation: UInt64) async {
        guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
        beginBackgroundWork()
        var holdsBackgroundWork = true
        defer { if holdsBackgroundWork { endBackgroundWork() } }
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              pipelineIsCurrent(recordId: recordId, generation: generation),
              auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else {
            requeueStalledPipeline(recordId: recordId, generation: generation)
            return
        }
        do {
            let manifest = try await VividAPI.shared.fetchManifest(downloadId: recordId, auth: auth)
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            await persistManifest(manifest, recordId: recordId, generation: generation)
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            applyManifestDisplay(manifest, recordId: recordId)
            // The file goes to the background session first, so it keeps
            // downloading once the app is closed. Artwork and subtitles are
            // small best-effort extras and must never hold the file back.
            try await startMediaTransfer(recordId: recordId, generation: generation, auth: auth)
            holdsBackgroundWork = false
            endBackgroundWork()
            processQueue()
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            await fetchArtwork(manifest, recordId: recordId, generation: generation, auth: auth)
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            await fetchSubtitles(manifest, recordId: recordId, generation: generation, auth: auth)
        } catch {
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            handlePipelineError(error, recordId: recordId)
        }
    }

    /// No usable sign-in for this scope right now. Put the record back in the
    /// queue instead of leaving it marked as preparing with no work behind
    /// it, where it would sit forever and hold a preparation slot.
    private func requeueStalledPipeline(recordId: String, generation: UInt64) {
        guard generation == registrationScopeGeneration,
              var record = file.records[recordId], record.localStatus == .fetchingAssets else { return }
        record.localStatus = .queued
        file.records[recordId] = record
        persist()
    }

    /// The active sign-in, only while it belongs to this manager's scope.
    private func scopeAuth() async -> CapturedOrdinaryRequestAuth? {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              !scopeServerId.isEmpty, auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else { return nil }
        return auth
    }

    private func taskTag(recordId: String) -> DownloadTaskTag? {
        guard !scopeServerId.isEmpty, !scopeProfileId.isEmpty else { return nil }
        return DownloadTaskTag(serverId: scopeServerId, profileId: scopeProfileId, recordId: recordId)
    }

    private func startMediaTransfer(recordId: String, generation: UInt64, auth: CapturedOrdinaryRequestAuth) async throws {
        guard let fileURL = await VividAPI.shared.downloadFileURL(downloadId: recordId, auth: auth) else {
            throw DownloadError.fileURLUnavailable
        }
        let request = try await DownloadAuthHeaders.authorizedRequest(
            url: fileURL,
            allowsCellular: !DownloadSettings.shared.wifiOnly,
            expected: auth
        )
        guard pipelineIsCurrent(recordId: recordId, generation: generation),
              var record = file.records[recordId] else { return }
        let taskId = sessionDelegate.start(request: request, tag: taskTag(recordId: recordId))
        record.taskIdentifier = taskId
        record.localStatus = .downloading
        file.records[recordId] = record
        persist()
        Task { try? await VividAPI.shared.patchDownloadStatus(id: recordId, status: "downloading", revision: record.revision, updatedAt: Date(), auth: auth) }
    }

    private func persistManifest(_ manifest: OfflineManifest, recordId: String, generation: UInt64) async {
        guard let url = absoluteFileURLForNewAsset(recordId: recordId, filename: "manifest.json") else { return }
        await DownloadStore.shared.saveManifest(manifest, to: url)
        guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
        if var record = file.records[recordId] {
            record.manifestFilename = "manifest.json"
            file.records[recordId] = record
        }
    }

    private func applyManifestDisplay(_ manifest: OfflineManifest, recordId: String) {
        guard var record = file.records[recordId] else { return }
        record.title = record.title ?? manifest.title
        record.type = manifest.type
        record.format = manifest.quality
        record.effectiveQuality = manifest.effectiveQuality
        record.deliveryFormat = manifest.deliveryFormat
        record.targetBitrateKbps = manifest.targetBitrateKbps
        record.revision = manifest.revision ?? record.revision
        record.mediaFileId = manifest.mediaFileId
        record.container = manifest.container
        record.posterThumbhash = record.posterThumbhash ?? manifest.posterThumbhash
        record.stableIdentity = manifest.stableIdentity
        if let seriesId = manifest.seriesId { record.seriesId = seriesId }
        record.seriesTitle = record.seriesTitle ?? manifest.seriesTitle
        record.seasonNumber = record.seasonNumber ?? manifest.seasonNumber
        record.episodeNumber = record.episodeNumber ?? manifest.episodeNumber
        if record.subtitle == nil {
            if manifest.type == "episode" {
                let season = manifest.seasonNumber.map { "S\($0)" }
                let episode = manifest.episodeNumber.map { "E\($0)" }
                record.subtitle = [season, episode].compactMap { $0 }.joined(separator: " · ")
            } else if let year = manifest.year {
                record.subtitle = String(year)
            }
        }
        if record.fileSize <= 0, let size = manifest.fileSize { record.fileSize = size }
        file.records[recordId] = record
        persist()
    }

    /// Save the manifest's subtitle files beside the download so they're
    /// available offline. Best effort, like artwork: a file that can't be
    /// fetched never fails the download. A failure that could clear up (see
    /// `DownloadFailureReport.isRetryable`, including an expired sign-in)
    /// leaves the record unchecked so a later backfill tries again; a file
    /// the server refuses is not retried.
    private func fetchSubtitles(_ manifest: OfflineManifest, recordId: String, generation: UInt64, auth: CapturedOrdinaryRequestAuth) async {
        var saved = file.records[recordId]?.subtitleFilenames ?? [:]
        var retryLater = false
        for entry in OfflineSubtitleFiles.savable(manifest.subtitles ?? []) where saved[entry.subtitle.fetchUrl] == nil {
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            let filename = OfflineSubtitleFiles.filename(index: entry.index, ext: entry.ext)
            let data: Data
            do { data = try await VividAPI.shared.fetchDownloadAssetData(path: entry.subtitle.fetchUrl, auth: auth) }
            catch {
                if DownloadFailureReport.isRetryable(error) { retryLater = true }
                continue
            }
            guard pipelineIsCurrent(recordId: recordId, generation: generation),
                  !data.isEmpty, data.count <= OfflineSubtitleFiles.maxBytes else { continue }
            // A storage failure can clear up (for example once space is
            // freed), so it's tried again rather than marked checked.
            guard let url = absoluteFileURLForNewAsset(recordId: recordId, filename: filename),
                  (try? data.write(to: url, options: .atomic)) != nil else { retryLater = true; continue }
            saved[entry.subtitle.fetchUrl] = filename
        }
        guard pipelineIsCurrent(recordId: recordId, generation: generation), var record = file.records[recordId] else { return }
        record.subtitleFilenames = saved
        if !retryLater { record.subtitlesChecked = true }
        file.records[recordId] = record
        persist()
    }

    /// Downloads made before subtitle files were saved, or whose artwork and
    /// subtitles didn't finish before the app was closed (they're fetched
    /// after the file starts), get them once while the server is reachable.
    private func backfillAssetsIfNeeded() async {
        let pending = file.records.values.filter {
            // Revoked downloads stay playable offline, so they get theirs too.
            ($0.localStatus == .completed || $0.localStatus == .revoked || $0.localStatus == .downloading)
                && $0.manifestFilename != nil
                && ($0.subtitlesChecked != true || needsArtwork($0))
                && pipelineTasks[$0.id] == nil
        }
        guard !pending.isEmpty, let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else { return }
        let generation = registrationScopeGeneration
        for record in pending {
            guard generation == registrationScopeGeneration, file.records[record.id] != nil,
                  pipelineTasks[record.id] == nil,
                  let manifest = await loadManifest(for: record) else { continue }
            if needsArtwork(record) {
                await fetchArtwork(manifest, recordId: record.id, generation: generation, auth: auth)
            }
            if file.records[record.id]?.subtitlesChecked != true {
                await fetchSubtitles(manifest, recordId: record.id, generation: generation, auth: auth)
            }
        }
    }

    /// Artwork that was only partly saved, or never fetched. Downloads from
    /// before the flag existed that already have a poster are left alone.
    private func needsArtwork(_ record: DownloadRecord) -> Bool {
        record.artworkChecked == false || (record.artworkChecked == nil && record.posterFilename == nil)
    }

    private func fetchArtwork(_ manifest: OfflineManifest, recordId: String, generation: UInt64, auth: CapturedOrdinaryRequestAuth) async {
        let preferredPosterPath = file.records[recordId]?.preferredPosterPath
        // The series poster from the detail page comes first, so a season's
        // episodes share one poster; the download's own poster is the
        // fallback when that link can't be fetched.
        let kinds: [(kind: String, paths: [String], filename: String)] = [
            ("poster", [preferredPosterPath, manifest.artworkUrls?.poster].compactMap { $0 }, "poster.jpg"),
            ("backdrop", [manifest.artworkUrls?.backdrop].compactMap { $0 }, "backdrop.jpg"),
            ("logo", [manifest.artworkUrls?.logo].compactMap { $0 }, "logo.png"),
        ]
        var fetchedAll = true
        for entry in kinds {
            guard pipelineIsCurrent(recordId: recordId, generation: generation) else { return }
            // Only fetch artwork the manifest actually advertises. The server
            // omits artwork_urls.* (omitempty) when a title has no poster/
            // backdrop/logo, so synthesizing a path here would guarantee a 404.
            var fetched: Data?
            var lastError: Error?
            for path in entry.paths where fetched == nil {
                do { fetched = try await VividAPI.shared.fetchDownloadAssetData(path: path, auth: auth) }
                catch { lastError = error }
            }
            guard let data = fetched else {
                // Missing artwork (a 404) isn't retried; a failure that can
                // clear up is, by the asset backfill.
                if let lastError, DownloadFailureReport.isRetryable(lastError) { fetchedAll = false }
                continue
            }
            guard pipelineIsCurrent(recordId: recordId, generation: generation), !data.isEmpty else { continue }
            guard let url = absoluteFileURLForNewAsset(recordId: recordId, filename: entry.filename),
                  (try? data.write(to: url, options: .atomic)) != nil else {
                fetchedAll = false
                continue
            }
            guard var record = file.records[recordId] else { continue }
            switch entry.kind {
            case "poster": record.posterFilename = entry.filename
            case "backdrop": record.backdropFilename = entry.filename
            case "logo": record.logoFilename = entry.filename
            default: break
            }
            file.records[recordId] = record
        }
        // Anything missed is tried again by the asset backfill.
        if pipelineIsCurrent(recordId: recordId, generation: generation), var record = file.records[recordId] {
            record.artworkChecked = fetchedAll
            file.records[recordId] = record
        }
        persist()
    }

    private func handlePipelineError(_ error: Error, recordId: String) {
        guard var record = file.records[recordId] else { return }
        record.taskIdentifier = nil
        if case let HTTPError.http(statusCode, _) = error {
            switch statusCode {
            case 409:
                record.localStatus = .revoked
                record.serverStatus = "revoked"
            case 404:
                record.localStatus = .failed
                record.lastError = "not_found"
            case 403:
                record.localStatus = .failed
                record.lastError = "forbidden"
            case 429, 500...599:
                // Cap and back off pipeline retries (manifest/asset fetch),
                // mirroring the media-transfer retry path; otherwise a
                // persistent 429 would retry every 5s forever.
                if record.retryCount < Self.maxRetries {
                    record.retryCount += 1
                    file.records[recordId] = record
                    scheduleRetry(recordId: recordId, resumeData: nil, refreshToken: false)
                } else {
                    record.localStatus = .failed
                    record.lastError = "http_\(statusCode)"
                    file.records[recordId] = record
                    persist()
                    reportFailure(.preparing, error: error, record: record)
                    processQueue()
                }
                return
            default:
                record.localStatus = .failed
                record.lastError = "http_\(statusCode)"
            }
        } else {
            record.localStatus = .failed
            record.lastError = error.localizedDescription
        }
        file.records[recordId] = record
        persist()
        if record.localStatus == .failed {
            notifyTerminalFailure(record)
            reportFailure(.preparing, error: error, record: record)
        }
        processQueue()
    }

    /// Records a terminal failure in Settings → Diagnostics. Only tokens and
    /// numbers are kept; `lastError` text never leaves the record.
    private func reportFailure(_ stage: DownloadFailureReport.Stage, error: Error, record: DownloadRecord) {
        guard let failure = DownloadFailureReport(stage: stage, error: error, server: MediaServerProvider.active.rawValue,
                                                  quality: record.format, batch: record.batchId != nil,
                                                  retries: record.retryCount) else { return }
        AppHealthMonitor.downloadFailed(failure)
    }

    private func reportFailure(_ stage: DownloadFailureReport.Stage, status: Int?, urlErrorCode: Int?, error: String,
                               record: DownloadRecord) {
        AppHealthMonitor.downloadFailed(DownloadFailureReport(
            stage: stage, server: MediaServerProvider.active.rawValue, status: status, urlErrorCode: urlErrorCode,
            error: error, quality: record.format, batch: record.batchId != nil, retries: record.retryCount))
    }

    /// The delegate's own failure messages are fixed tokens; anything else is
    /// system text and is not kept.
    static func transferFailureToken(_ message: String) -> String {
        message == "stage_failed" ? "stage_failed" : "other"
    }

    /// Mirror the active queue into the lock-screen Live Activity. Hooked
    /// into `file`'s `didSet` so every mutation flows through — including
    /// scope deactivation (empty blob ends the activity). The controller
    /// dedupes identical content states, so burst mutations (reconcile
    /// loops, pipeline steps) cost a snapshot build and nothing more.
    private func syncLiveActivity() {
        #if os(iOS)
        let completedIds = Set(
            file.records.values
                .filter { $0.localStatus == .completed }
                .map(\.id)
        )
        DownloadLiveActivityController.shared.sync(
            activeRecords: activeRecords,
            completedRecordIds: completedIds,
            totalBytesPerSecond: transferRates.values.reduce(0, +)
        )
        #endif
    }

    /// Notify only for transfer/pipeline failures the user would otherwise
    /// discover much later. Reconcile-driven failures (rows revoked or
    /// removed server-side) stay silent — they can arrive in bulk during a
    /// sync and the Downloads screen already surfaces them.
    private func notifyTerminalFailure(_ record: DownloadRecord) {
        #if os(iOS)
        DownloadNotifier.downloadFailed(record)
        #endif
    }

    // MARK: - Background session events

    private func handleSessionEvent(_ event: DownloadSessionEvent) {
        // Hold events until the first scope activation has loaded the
        // persisted registry — on a cold (background) relaunch the recreated
        // session replays its buffered events immediately, and matching them
        // against a not-yet-loaded registry would delete finished media as
        // orphaned and re-download it from scratch.
        guard !sessionEventsHeld else {
            pendingSessionEvents.append(event)
            return
        }
        switch event {
        case let .progress(taskId, written, total, tag):
            guard var record = recordByTask(taskId, tag: tag) else { return }
            updateTransferRate(recordId: record.id, bytes: written)
            // Publish to the observable blob at a readable cadence — the raw
            // callbacks fire many times per second and each reassignment
            // redraws every byte counter "live". Skipped ticks lose nothing:
            // `written` is cumulative, so the next publish catches up.
            let now = Date()
            guard now.timeIntervalSince(lastProgressPublish[record.id] ?? .distantPast)
                >= Self.progressPublishInterval else { return }
            lastProgressPublish[record.id] = now
            record.bytesDownloaded = written
            if total > 0 { record.fileSize = total }
            file.records[record.id] = record
            persistProgressThrottled()

        case let .finished(taskId, stagedURL, _, tag):
            handleMediaFinished(taskId: taskId, stagedURL: stagedURL, tag: tag)

        case let .failed(taskId, statusCode, resumeData, message, urlErrorCode, tag):
            handleMediaFailure(taskId: taskId, statusCode: statusCode, resumeData: resumeData, message: message,
                               urlErrorCode: urlErrorCode, tag: tag)

        case .allEventsDelivered:
            // Flush queued store writes before handing control back — iOS
            // can suspend the process as soon as the completion handler
            // runs, and the `.finished`/`.failed` records handled above are
            // still on the async save chain.
            guard let handler = sessionDelegate.backgroundCompletionHandler else { return }
            sessionDelegate.backgroundCompletionHandler = nil
            let pendingSave = saveChain
            Task { @MainActor in
                await pendingSave?.value
                handler()
            }
        }
    }

    /// Replay events held during launch, in arrival order, now that the
    /// registry reflects the active scope (or the lack of one — orphan
    /// cleanup is then correct rather than premature).
    private func releaseHeldSessionEvents() {
        guard sessionEventsHeld else { return }
        sessionEventsHeld = false
        while !pendingSessionEvents.isEmpty {
            handleSessionEvent(pendingSessionEvents.removeFirst())
        }
    }

    private func handleMediaFinished(taskId: Int, stagedURL: URL, tag: DownloadTaskTag? = nil) {
        intentionalCancels.remove(taskId)
        guard var record = recordByTask(taskId, tag: tag) else {
            if let tag, !tag.isScope(serverId: scopeServerId, profileId: scopeProfileId) {
                finishOutOfScope(tag: tag, taskId: taskId, stagedURL: stagedURL)
            } else {
                try? FileManager.default.removeItem(at: stagedURL)
            }
            return
        }
        clearTransferRate(recordId: record.id)
        let ext = mediaExtension(for: record)
        let filename = "media.\(ext)"
        guard let destination = absoluteFileURLForNewAsset(recordId: record.id, filename: filename) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch {
            Self.logger.error("Failed to move finished media: \(String(describing: error), privacy: .private)")
            record.localStatus = .failed
            record.lastError = "move_failed"
            record.taskIdentifier = nil
            file.records[record.id] = record
            persist()
            reportFailure(.saving, status: nil, urlErrorCode: nil, error: "move_failed", record: record)
            processQueue()
            return
        }
        record.mediaFilename = filename
        record.localStatus = .completed
        record.downloadedAt = Date()
        record.taskIdentifier = nil
        record.lastError = nil
        // The file on disk is the truth: a transcode streamed without a
        // length only had an estimate until now.
        let sizeOnDisk = fileSizeOnDisk(destination)
        if sizeOnDisk > 0 { record.fileSize = sizeOnDisk }
        record.bytesDownloaded = record.fileSize
        file.records[record.id] = record
        persist()
        #if os(iOS)
        DownloadNotifier.downloadCompleted(record)
        #endif
        let id = record.id
        Task { try? await VividAPI.shared.patchDownloadStatus(id: id, status: "completed", revision: record.revision, updatedAt: record.downloadedAt ?? Date()) }
        processQueue()
        refreshStorageUsage()
        Task { await self.enforceRetention() }
    }

    private func handleMediaFailure(taskId: Int, statusCode: Int?, resumeData: Data?, message: String, urlErrorCode: Int? = nil,
                                    tag: DownloadTaskTag? = nil) {
        if intentionalCancels.remove(taskId) != nil { return }
        guard var record = recordByTask(taskId, tag: tag) else {
            if let tag, !tag.isScope(serverId: scopeServerId, profileId: scopeProfileId) {
                requeueOutOfScope(tag: tag, taskId: taskId, resumeData: resumeData)
            }
            return
        }
        record.taskIdentifier = nil
        clearTransferRate(recordId: record.id)

        if let statusCode {
            switch statusCode {
            case 409:
                record.localStatus = .revoked
                record.serverStatus = "revoked"
                file.records[record.id] = record
                persist()
                processQueue()
                return
            case 404, 403:
                record.localStatus = .failed
                record.lastError = statusCode == 404 ? "not_found" : "forbidden"
                file.records[record.id] = record
                persist()
                notifyTerminalFailure(record)
                reportFailure(.transfer, status: statusCode, urlErrorCode: nil, error: "http", record: record)
                processQueue()
                return
            case 401:
                // Bounded like every other retry path — a persistently
                // expired credential would otherwise refresh-and-retry
                // forever with the record stuck in `.downloading`.
                if record.retryCount < Self.maxRetries {
                    record.retryCount += 1
                    file.records[record.id] = record
                    scheduleRetry(recordId: record.id, resumeData: nil, refreshToken: true)
                } else {
                    record.localStatus = .failed
                    record.lastError = "unauthorized"
                    file.records[record.id] = record
                    persist()
                    notifyTerminalFailure(record)
                    reportFailure(.transfer, status: statusCode, urlErrorCode: nil, error: "http", record: record)
                    processQueue()
                }
                return
            default:
                break
            }
        }

        if record.retryCount < Self.maxRetries {
            record.retryCount += 1
            file.records[record.id] = record
            scheduleRetry(recordId: record.id, resumeData: resumeData, refreshToken: false)
        } else {
            record.localStatus = .failed
            record.lastError = message
            file.records[record.id] = record
            persist()
            notifyTerminalFailure(record)
            let httpStatus = statusCode.flatMap { (200..<300).contains($0) ? nil : $0 }
            reportFailure(.transfer, status: httpStatus, urlErrorCode: urlErrorCode,
                          error: httpStatus != nil ? "http" : urlErrorCode != nil ? "network" : Self.transferFailureToken(message),
                          record: record)
            processQueue()
        }
    }

    /// A transfer for another server or profile finished after the user
    /// switched away. Its file is saved into that scope's own registry, so
    /// the download is there when they switch back instead of being thrown
    /// away and fetched again.
    private func finishOutOfScope(tag: DownloadTaskTag, taskId: Int, stagedURL: URL) {
        Task { @MainActor in
            var other = await DownloadStore.shared.load(serverId: tag.serverId, profileId: tag.profileId)
            if tag.isScope(serverId: self.scopeServerId, profileId: self.scopeProfileId) {
                // Switched back while the registry loaded: handle it in scope.
                self.handleSessionEvent(.finished(taskId: taskId, stagedURL: stagedURL, statusCode: 200, tag: tag))
                return
            }
            guard var record = other.records[tag.recordId], record.taskIdentifier == taskId else {
                try? FileManager.default.removeItem(at: stagedURL)
                return
            }
            let filename = "media.\(self.mediaExtension(for: record))"
            let destination = DownloadFilePaths.fileURL(serverId: tag.serverId, profileId: tag.profileId,
                                                        downloadId: record.id, filename: filename)
            try? FileManager.default.removeItem(at: destination)
            record.taskIdentifier = nil
            do {
                try FileManager.default.moveItem(at: stagedURL, to: destination)
                record.mediaFilename = filename
                record.localStatus = .completed
                record.downloadedAt = Date()
                record.lastError = nil
                let size = self.fileSizeOnDisk(destination)
                if size > 0 { record.fileSize = size }
                record.bytesDownloaded = record.fileSize
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                record.localStatus = .queued
            }
            other.records[record.id] = record
            await DownloadStore.shared.save(other, serverId: tag.serverId, profileId: tag.profileId)
            self.adoptOutOfScopeUpdate(record, tag: tag, taskId: taskId)
        }
    }

    /// A transfer for another scope failed or was interrupted: queue it again
    /// in that scope, keeping any resume data, so it restarts on return.
    private func requeueOutOfScope(tag: DownloadTaskTag, taskId: Int, resumeData: Data?) {
        Task { @MainActor in
            var other = await DownloadStore.shared.load(serverId: tag.serverId, profileId: tag.profileId)
            guard !tag.isScope(serverId: self.scopeServerId, profileId: self.scopeProfileId),
                  var record = other.records[tag.recordId], record.taskIdentifier == taskId else { return }
            record.taskIdentifier = nil
            record.localStatus = .queued
            if let resumeData {
                let url = DownloadFilePaths.fileURL(serverId: tag.serverId, profileId: tag.profileId,
                                                    downloadId: record.id, filename: "resume.bin")
                if (try? resumeData.write(to: url, options: .atomic)) != nil { record.resumeDataFilename = "resume.bin" }
            }
            other.records[record.id] = record
            await DownloadStore.shared.save(other, serverId: tag.serverId, profileId: tag.profileId)
            self.adoptOutOfScopeUpdate(record, tag: tag, taskId: taskId)
        }
    }

    /// The user may have switched back to that scope while its registry was
    /// being saved, loading the older copy. Carry the update over.
    private func adoptOutOfScopeUpdate(_ record: DownloadRecord, tag: DownloadTaskTag, taskId: Int) {
        guard tag.isScope(serverId: scopeServerId, profileId: scopeProfileId),
              file.records[record.id]?.taskIdentifier == taskId else { return }
        file.records[record.id] = record
        persist()
        processQueue()
    }

    private func scheduleRetry(recordId: String, resumeData: Data?, refreshToken: Bool) {
        let generation = registrationScopeGeneration
        let attempt = file.records[recordId]?.retryCount ?? 1
        let delaySeconds = min(120, Int(pow(2.0, Double(attempt))) * 5)
        retryTasks[recordId]?.cancel()
        retryTasks[recordId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.scopeServerId.isEmpty else { return }
            self.retryTasks[recordId] = nil
            // Fire only while the record still looks like the failure this
            // retry was scheduled for — a pause, delete, revoke, or re-queue
            // that landed during the back-off owns the record now, and
            // restarting on top of it would run two transfers of one file.
            guard let record = self.file.records[recordId],
                  record.taskIdentifier == nil,
                  record.localStatus == .downloading || record.localStatus == .fetchingAssets else { return }
            if refreshToken {
                // Force HTTPClient's single-flight 401 refresh so the next
                // background request carries a fresh token.
                _ = try? await VividAPI.shared.listDownloads()
            }
            guard self.pipelineIsCurrent(recordId: recordId, generation: generation),
                  self.file.records[recordId]?.taskIdentifier == nil,
                  self.file.records[recordId]?.localStatus == record.localStatus else { return }
            let restart = { [weak self] in
                guard let self, self.pipelineIsCurrent(recordId: recordId, generation: generation),
                      self.file.records[recordId]?.taskIdentifier == nil,
                      self.file.records[recordId]?.localStatus == record.localStatus else { return }
                self.restartTransfer(recordId: recordId, resumeData: resumeData)
            }
            guard self.queueHolds == 0 else {
                self.heldRetries.append(restart)
                return
            }
            restart()
        }
    }

    private func startHeldRetries() {
        guard queueHolds == 0, !heldRetries.isEmpty else { return }
        let retries = heldRetries
        heldRetries.removeAll()
        retries.forEach { $0() }
    }

    private func restartTransfer(recordId: String, resumeData: Data?) {
        if let resumeData {
            let taskId = sessionDelegate.resume(data: resumeData, tag: taskTag(recordId: recordId))
            guard var rec = file.records[recordId] else { return }
            rec.taskIdentifier = taskId
            rec.localStatus = .downloading
            file.records[recordId] = rec
            persist()
        } else {
            // Restart from the manifest step — a pipeline failure may have
            // been in the manifest/asset fetch, not the media transfer.
            setLocalStatus(.fetchingAssets, id: recordId)
            launchMediaPipeline(recordId: recordId)
        }
    }

    // MARK: - Polling (preparing → ready)

    private func ensurePolling() {
        guard pollTask == nil else { return }
        guard file.records.values.contains(where: { $0.localStatus == .preparing }) else { return }
        pollTask = Task { @MainActor in
            defer { self.pollTask = nil }
            while !Task.isCancelled {
                guard self.file.records.values.contains(where: { $0.localStatus == .preparing }) else { break }
                await self.prefetchPreparingDetails()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await self.reconcileWithServer(triggerPipeline: true)
            }
        }
    }

    /// While Silo prepares a download, fetch its artwork so the row shows
    /// the poster rather than a blur, and for a smaller quality estimate the
    /// prepared file's size from the runtime: until the file is ready the
    /// server reports the source file's size. Once per download; the normal
    /// pipeline fetches the artwork again when the file is ready.
    private func prefetchPreparingDetails() async {
        guard MediaServerProvider.forServerID(scopeServerId) == .silo else { return }
        let pending = file.records.values.filter {
            $0.localStatus == .preparing && !preparingDetailsFetched.contains($0.id)
                && preparingDetailsAttempts[$0.id, default: 0] < 3
        }
        guard !pending.isEmpty, let auth = await scopeAuth() else { return }
        let generation = registrationScopeGeneration
        for record in pending {
            guard pipelineIsCurrent(recordId: record.id, generation: generation) else { continue }
            // A failed request is tried again on a later poll, up to three times.
            guard let manifest = try? await VividAPI.shared.fetchManifest(downloadId: record.id, auth: auth) else {
                preparingDetailsAttempts[record.id, default: 0] += 1
                continue
            }
            guard pipelineIsCurrent(recordId: record.id, generation: generation),
                  var current = file.records[record.id], current.localStatus == .preparing else { continue }
            preparingDetailsFetched.insert(record.id)
            if current.fileSize <= 0,
               let format = DownloadFormat(rawValue: current.format), format != .original,
               let estimate = StreamedTranscodeDownload.estimatedBytes(format: format, durationSeconds: manifest.durationSeconds) {
                current.fileSize = estimate
                file.records[record.id] = current
                persist()
            }
            if current.posterFilename == nil {
                await fetchArtwork(manifest, recordId: record.id, generation: generation, auth: auth)
            }
        }
    }

    // MARK: - Reconcile with server

    func reconcileWithServer(triggerPipeline: Bool) async {
        guard !scopeServerId.isEmpty, downloadsEnabled else { return }
        let generation = registrationScopeGeneration
        // Pin the list to this scope's account: during a switch the active
        // sign-in can already be the next server's, whose rows would mark
        // this account's downloads as removed.
        guard let auth = await scopeAuth(), generation == registrationScopeGeneration else { return }
        flushPendingServerDeletes()
        let rows: [ServerDownloadRow]
        do {
            rows = try await VividAPI.shared.listDownloads(auth: auth)
        } catch {
            return
        }
        guard generation == registrationScopeGeneration else { return }
        // Read after the list returns: a delete made while it was in flight
        // must still keep its row from being picked up again.
        let pendingDeletes = Set(file.pendingServerDeletes ?? []).union(deletedDownloadIds)
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var unreportedCompletions: [DownloadRecord] = []

        for (id, original) in file.records {
            if let row = byId[id] {
                var record = mergeExistingRecord(original, with: row)
                // A transfer that finished while another account was active
                // (or while a status update failed) still reads as pending on
                // the server, where it counts against the download limit.
                if record.localStatus == .completed, row.status == "ready" || row.status == "downloading" {
                    unreportedCompletions.append(record)
                }
                switch row.status {
                case "ready":
                    if record.localStatus == .preparing || record.localStatus == .registering {
                        record.localStatus = .queued
                    }
                case "revoked":
                    if record.localStatus == .completed {
                        record.localStatus = .revoked
                    } else if record.localStatus.isActive {
                        record.localStatus = .revoked
                    }
                case "failed":
                    if record.localStatus != .completed {
                        // The merge above may already have reset a newer
                        // revision to failed, so compare the earlier status.
                        if original.localStatus != .failed {
                            reportFailure(.conversion, status: nil, urlErrorCode: nil, error: "server_failed", record: record)
                        }
                        record.localStatus = .failed
                        record.lastError = "server_failed"
                    }
                default:
                    break
                }
                file.records[id] = record
            } else if original.localStatus.isActive {
                var record = original
                record.localStatus = .failed
                record.lastError = "removed_on_server"
                file.records[id] = record
            }
        }

        // Pick up rows registered out-of-band (e.g. subscription sync).
        for row in rows where file.records[row.id] == nil && !pendingDeletes.contains(row.id) {
            file.records[row.id] = makeRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
        }
        persist()
        if !unreportedCompletions.isEmpty {
            Task {
                for record in unreportedCompletions {
                    try? await VividAPI.shared.patchDownloadStatus(id: record.id, status: "completed", revision: record.revision,
                                                                   updatedAt: record.downloadedAt ?? Date(), auth: auth)
                }
            }
        }

        await reconnectActiveTasks()
        if triggerPipeline {
            processQueue()
            ensurePolling()
        }
    }

    /// After a relaunch the background session may have lost in-flight
    /// tasks (or finished them while we were dead). Re-queue records whose
    /// task is no longer live.
    private func reconnectActiveTasks() async {
        let active = await sessionDelegate.activeTaskIdentifiers()
        for (id, record) in file.records {
            var record = record
            // Task identifiers are only unique within one URLSession
            // instance — a recreated session hands the same small integers
            // to new tasks, so a persisted id with no live task must be
            // dropped before it can match (and misroute) another record's
            // transfer. Pause round-trips keep theirs: the cancelled task
            // may still deliver a final event that must find this record.
            if let taskId = record.taskIdentifier,
               !active.contains(taskId),
               !pendingPauseIds.contains(id) {
                record.taskIdentifier = nil
                file.records[id] = record
            }
            // Records with a live back-off timer are owned by the retry;
            // re-queuing them here would double-start the transfer when it
            // fires.
            guard retryTasks[id] == nil else { continue }
            guard record.localStatus == .downloading || record.localStatus == .fetchingAssets else {
                continue
            }
            // `.fetchingAssets` records were mid-pipeline in a detached Task
            // that did not survive the relaunch; re-queue them too so they
            // aren't wedged (and don't keep occupying a concurrency slot
            // forever).
            if record.localStatus == .downloading,
               let taskId = record.taskIdentifier, active.contains(taskId) {
                continue
            }
            setLocalStatus(.queued, id: id)
        }
    }

    // MARK: - Series monitoring

    func createSubscription(
        seriesId: String,
        seriesTitle: String?,
        mode: SubscriptionMode,
        seasonNumbers: [Int]?,
        deleteWatched: Bool,
        maxStorageBytes: Int64
    ) async throws {
        let request = CreateSubscriptionRequest(
            seriesId: seriesId,
            mode: mode.rawValue,
            seasonNumbers: mode == .specificSeasons ? seasonNumbers : nil,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes
        )
        let response = try await VividAPI.shared.createSubscription(request)
        upsertSubscription(response.subscription, seriesTitle: seriesTitle)
        persist()
        await reconcileWithServer(triggerPipeline: true)
    }

    func updateSubscription(
        id: String,
        mode: SubscriptionMode? = nil,
        seasonNumbers: [Int]? = nil,
        deleteWatched: Bool? = nil,
        maxStorageBytes: Int64? = nil,
        active: Bool? = nil
    ) async throws {
        let existingTitle = file.subscriptions.first(where: { $0.id == id })?.seriesTitle
        let request = UpdateSubscriptionRequest(
            mode: mode?.rawValue,
            seasonNumbers: seasonNumbers,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes,
            active: active
        )
        let response = try await VividAPI.shared.updateSubscription(id: id, request)
        upsertSubscription(response.subscription, seriesTitle: existingTitle)
        persist()
        await reconcileWithServer(triggerPipeline: true)
    }

    func deleteSubscription(id: String) async {
        file.subscriptions.removeAll { $0.id == id }
        persist()
        try? await VividAPI.shared.deleteSubscription(id: id)
    }

    /// Subscription sync + offline progress reconciliation, run on
    /// foreground and from the background refresh task. Client-driven: no
    /// server background worker.
    func runMonitoringAndProgressSync() async {
        guard downloadsEnabled else { return }
        var priorRecordIds: Set<String> = []
        var registered = 0
        if !file.subscriptions.isEmpty {
            priorRecordIds = Set(file.records.keys)
            registered = (try? await VividAPI.shared.syncSubscriptions()) ?? 0
        }
        await flushProgressQueue()
        await pullProgressDeltas()
        await reconcileWithServer(triggerPipeline: true)
        notifyMonitoringBatch(registered: registered, priorRecordIds: priorRecordIds)
        await enforceRetention()
    }

    /// One notification per sync batch when monitoring registered new
    /// episodes. The rows land locally via the reconcile that just ran; a
    /// fresh episode row's `contentId` is the series id (episode
    /// registrations are keyed by series), which is how the batch resolves
    /// the show name for the copy before the manifest hydrates `seriesId`.
    private func notifyMonitoringBatch(registered: Int, priorRecordIds: Set<String>) {
        #if os(iOS)
        guard registered > 0 else { return }
        let newEpisodes = file.records.values.filter {
            !priorRecordIds.contains($0.id) && $0.episodeId != nil
        }
        guard !newEpisodes.isEmpty else { return }
        let titles = Set(newEpisodes.compactMap {
            subscription(forSeriesId: $0.seriesId ?? $0.contentId)?.seriesTitle
        })
        DownloadNotifier.newEpisodesQueued(count: newEpisodes.count, seriesTitles: titles)
        #endif
    }

    /// Client-enforced `delete_watched`: remove completed downloads whose
    /// series is monitored with retention enabled and whose progress is
    /// completed. The server never deletes on-device files.
    private func enforceRetention() async {
        let retentionSeries = Set(
            file.subscriptions.filter { $0.deleteWatched }.map { $0.seriesId }
        )
        guard !retentionSeries.isEmpty else { return }
        let toDelete = file.records.values.filter { record in
            // Progress is keyed by the leaf item id (the episode), which for an
            // episode download is `episodeId`, not the series `contentId`.
            let leafId = record.episodeId ?? record.contentId
            return record.localStatus == .completed
                && record.seriesId.map(retentionSeries.contains) == true
                && file.localProgress[leafId]?.completed == true
        }
        for record in toDelete {
            deleteDownload(id: record.id)
        }
    }

    // MARK: - Offline progress

    /// Record a watch-progress event from offline playback: update the
    /// local resume point and queue it for the next reconnect flush.
    func recordOfflineProgress(mediaItemId: String, position: Double, duration: Double, completed: Bool) {
        guard !mediaItemId.isEmpty, position.isFinite, position >= 0 else { return }
        let now = Date()
        var entry = file.localProgress[mediaItemId]
            ?? LocalProgressEntry(position: 0, duration: duration, completed: false, updatedAt: now)
        entry.position = position
        if duration.isFinite, duration > 0 { entry.duration = duration }
        entry.completed = entry.completed || completed
        entry.updatedAt = now
        file.localProgress[mediaItemId] = entry

        // Collapse to the latest event per item so an offline session that
        // ticks every few seconds doesn't grow an unbounded flush queue.
        file.progressQueue.removeAll { $0.mediaItemId == mediaItemId }
        file.progressQueue.append(QueuedProgress(
            id: UUID(),
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            updatedAt: now,
            attempts: 0
        ))
        persist()
    }

    func flushProgressQueue() async {
        guard !file.progressQueue.isEmpty else { return }
        let scopeGeneration = registrationScopeGeneration
        let batch = file.progressQueue
        let completedIds = Set(batch.filter { file.localProgress[$0.mediaItemId]?.completed == true }.map { $0.mediaItemId })
        let items = batch.map {
            SyncProgressItem(
                mediaItemId: $0.mediaItemId,
                position: $0.position,
                duration: $0.duration,
                forceOverwrite: false,
                updatedAt: $0.updatedAt
            )
        }
        do {
            let results = try await VividAPI.shared.syncProgressBatch(items: items)
            guard scopeGeneration == registrationScopeGeneration else { return }
            var okItemIds = Set(results.filter { $0.isOK }.map { $0.mediaItemId })
            // Position sync alone cannot express credits-based completion.
            // Keep the queued event if the separate watched write fails.
            for contentId in completedIds.intersection(okItemIds) {
                do { try await VividAPI.shared.setWatched(contentId: contentId, played: true) }
                catch { okItemIds.remove(contentId) }
            }
            // Match queue entries by identity, not media item — an entry
            // appended while the POST was in flight carries a newer position
            // the server never saw, so it must survive this batch with its
            // full retry budget.
            guard scopeGeneration == registrationScopeGeneration else { return }
            let sentEntryIds = Set(batch.map { $0.id })
            let okEntryIds = Set(batch.filter { okItemIds.contains($0.mediaItemId) }.map { $0.id })
            file.progressQueue.removeAll {
                okEntryIds.contains($0.id)
                    || ($0.attempts >= Self.maxRetries && sentEntryIds.contains($0.id)
                        && !completedIds.contains($0.mediaItemId))
            }
            for index in file.progressQueue.indices
            where sentEntryIds.contains(file.progressQueue[index].id) {
                file.progressQueue[index].attempts += 1
            }
            persist()
        } catch {
            // Keep the queue for the next reconnect.
        }
    }

    private var progressBootstrapInFlight = false

    func pullProgressDeltas() async {
        guard !progressBootstrapInFlight else { return }
        progressBootstrapInFlight = true
        defer { progressBootstrapInFlight = false }
        do {
            if let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
               MediaServerProvider.forServerID(auth.account.serverId) == .silo,
               let url = URL(string: auth.account.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/progress"),
               try await SiloAPIDiscovery.shared.usesV2(for: url, session: .shared) {
                try await replaceSiloProgress(auth: auth)
                return
            }

            let response = try await VividAPI.shared.pullProgressDeltas(since: file.progressCursor)
            for item in response.progress {
                let serverTime = item.updatedAt ?? Date()
                var entry = file.localProgress[item.mediaItemId]
                    ?? LocalProgressEntry(
                        position: item.positionSeconds,
                        duration: item.durationSeconds,
                        completed: item.completed,
                        updatedAt: serverTime
                    )
                if serverTime >= entry.updatedAt {
                    entry.position = item.positionSeconds
                    if item.durationSeconds > 0 { entry.duration = item.durationSeconds }
                    entry.completed = entry.completed || item.completed
                    entry.updatedAt = serverTime
                    file.localProgress[item.mediaItemId] = entry
                }
            }
            if let cursor = response.nextCursor, !cursor.isEmpty {
                file.progressCursor = cursor
            }
            persist()
        } catch {
            // Non-fatal; retry next foreground.
        }
    }

    private func persistBootstrap(_ stagedFile: DownloadStoreFile? = nil) async throws {
        let snapshot = stagedFile ?? file
        let serverId = scopeServerId
        let profileId = scopeProfileId
        let previous = saveChain
        let write = Task { @MainActor in
            await previous?.value
            try await DownloadStore.shared.saveChecked(snapshot, serverId: serverId, profileId: profileId)
        }
        saveChain = Task { _ = try? await write.value }
        try await write.value
    }

    private func replaceSiloProgress(auth: CapturedOrdinaryRequestAuth) async throws {
        let scopeGeneration = registrationScopeGeneration
        func scopeIsCurrent() async -> Bool {
            guard scopeGeneration == registrationScopeGeneration,
                  auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else { return false }
            return await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
        }
        let http = HTTPClient.shared
        let capability: SiloProgressBootstrapCapability = try await http.get("/api/v2/sync/progress/capabilities", expectedAuth: auth)
        guard await scopeIsCurrent(), capability.state == "available", capability.allowed,
              capability.mode == "full_replace", !capability.incremental,
              let installation = capability.installationId, let generation = capability.generation else { return }
        let account: AuthUser = try await http.get("/api/v1/auth/me", expectedAuth: auth)
        guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
        if let stage = file.progressBootstrap,
           stage.installationId != installation || stage.generation != generation || stage.accountId != String(account.id) || stage.profileId != auth.profileId || Date().timeIntervalSince(stage.createdAt) > 900 {
            file.progressBootstrap = nil
        }
        if file.progressBootstrap == nil {
            file.progressBootstrap = SiloProgressBootstrapStage(requestId: UUID().uuidString, createdAt: Date(),
                installationId: installation, accountId: String(account.id), profileId: scopeProfileId, generation: generation)
        }
        try await persistBootstrap()
        guard await scopeIsCurrent(), var stage = file.progressBootstrap else { throw HTTPError.requestIdentityChanged }
        do {
            var seenCursors = Set<String>()
            var pages = 0
            while stage.page?.complete != true {
                try Task.checkCancellation()
                guard pages < 2000 else { throw HTTPError.invalidResponse }
                pages += 1
                let page: SiloProgressBootstrapPage
                if let previous = stage.page {
                    guard previous.expiresAt > Date(), let cursor = previous.page.nextCursor,
                          !cursor.isEmpty, seenCursors.insert(cursor).inserted else { throw HTTPError.invalidResponse }
                    page = try await http.get("/api/v2/sync/progress/snapshots/\(previous.snapshotId)", query: ["cursor": cursor], expectedAuth: auth)
                    guard page.snapshotId == previous.snapshotId, page.itemCount == previous.itemCount,
                          page.capturedAt == previous.capturedAt else { throw HTTPError.invalidResponse }
                } else {
                    struct Admission: Encodable { let requestId: String; let limit: Int }
                    page = try await http.post("/api/v2/sync/progress/snapshots", body: Admission(requestId: stage.requestId, limit: 200), timeout: .extended, expectedAuth: auth)
                }
                guard await scopeIsCurrent(), page.installationId == installation, page.generation == generation,
                      page.accountId == stage.accountId, page.profileId == stage.profileId,
                      page.mode == "full_replace", page.expiresAt > Date(), page.itemCount <= 100_000,
                      page.complete != page.page.hasMore else { throw HTTPError.invalidResponse }
                for item in page.items {
                    guard stage.items[item.mediaItemId] == nil else { throw HTTPError.invalidResponse }
                    stage.items[item.mediaItemId] = item
                }
                guard stage.items.count <= page.itemCount else { throw HTTPError.invalidResponse }
                stage.page = page
                file.progressBootstrap = stage
                try await persistBootstrap()
                guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
            }
            guard let terminal = stage.page, terminal.complete, !terminal.page.hasMore,
                  terminal.completionToken?.isEmpty == false, stage.items.count == terminal.itemCount else { throw HTTPError.invalidResponse }
            let current: SiloProgressBootstrapCapability = try await http.get("/api/v2/sync/progress/capabilities", expectedAuth: auth)
            guard await scopeIsCurrent(), current.state == "available", current.allowed,
                  current.installationId == installation, current.generation == generation else { throw HTTPError.requestIdentityChanged }
            var replacement = stage.items.mapValues { item in
                LocalProgressEntry(position: item.positionSeconds, duration: item.durationSeconds,
                    completed: item.completed, updatedAt: item.updatedAt ?? terminal.capturedAt)
            }
            // Unsynchronised local events remain authoritative until their
            // exact queue entries are acknowledged. Downloads are untouched.
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            guard terminal.expiresAt > Date() else { throw HTTPError.invalidResponse }
            var committed = file
            committed.localProgress = replacement
            committed.progressCursor = nil
            committed.progressBootstrap = nil
            try await persistBootstrap(committed)
            guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            file.localProgress = replacement
            file.progressCursor = nil
            file.progressBootstrap = nil
            persist()
        } catch {
            if await scopeIsCurrent(), let error = error as? HTTPError, [404, 409, 413].contains(error.statusCode ?? 0) {
                file.progressBootstrap = nil
                try await persistBootstrap()
            }
            throw error
        }
    }

    // MARK: - Helpers

    private func upsertRow(
        _ row: ServerDownloadRow,
        displayTitle: String?,
        displaySubtitle: String?,
        type: String?,
        seriesId: String?,
        seriesTitle: String?,
        posterThumbhash: String?,
        preferredPosterPath: String?
    ) {
        if let existing = file.records[row.id] {
            var merged = mergeExistingRecord(existing, with: row)
            if existing.localStatus == .failed || existing.localStatus == .revoked {
                merged.localStatus = mapInitialStatus(row.status)
                merged.lastError = nil
                merged.retryCount = 0
            }
            file.records[row.id] = merged
            return
        }
        var record = makeRecord(from: row, type: type)
        record.title = displayTitle
        record.subtitle = displaySubtitle
        record.seriesId = seriesId ?? record.seriesId
        record.seriesTitle = seriesTitle
        record.posterThumbhash = posterThumbhash
        record.preferredPosterPath = preferredPosterPath
        file.records[row.id] = record
    }

    private func mergeExistingRecord(_ existing: DownloadRecord, with row: ServerDownloadRow) -> DownloadRecord {
        var record = existing
        if shouldReplaceLocalAssets(record, with: row) {
            discardLocalAssets(for: record)
            resetLocalAssets(on: &record, status: row.status)
        }
        applyServerRow(row, to: &record)
        return record
    }

    private func shouldReplaceLocalAssets(_ record: DownloadRecord, with row: ServerDownloadRow) -> Bool {
        if let currentRevision = record.revision,
           let serverRevision = row.revision,
           serverRevision > currentRevision {
            return true
        }
        if record.revision == nil {
            return record.mediaFileId != row.mediaFileId || record.format != row.quality
        }
        return false
    }

    private func discardLocalAssets(for record: DownloadRecord) {
        if let taskId = record.taskIdentifier {
            intentionalCancels.insert(taskId)
            sessionDelegate.cancel(taskId: taskId)
        }
        guard !scopeServerId.isEmpty else { return }
        DownloadFilePaths.removeDownloadDirectory(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id
        )
    }

    private func resetLocalAssets(on record: inout DownloadRecord, status: String) {
        record.mediaFilename = nil
        record.manifestFilename = nil
        record.posterFilename = nil
        record.backdropFilename = nil
        record.logoFilename = nil
        record.subtitleFilenames = [:]
        record.subtitlesChecked = nil
        record.artworkChecked = nil
        record.resumeDataFilename = nil
        record.container = nil
        record.stableIdentity = nil
        record.bytesDownloaded = 0
        record.localStatus = mapInitialStatus(status)
        record.downloadedAt = nil
        record.lastError = nil
        record.retryCount = 0
        record.taskIdentifier = nil
    }

    private func applyServerRow(_ row: ServerDownloadRow, to record: inout DownloadRecord) {
        record.contentId = row.contentId
        record.mediaFileId = row.mediaFileId
        record.format = row.quality
        record.effectiveQuality = row.effectiveQuality
        record.deliveryFormat = row.deliveryFormat
        record.targetBitrateKbps = row.targetBitrateKbps
        record.revision = row.revision ?? record.revision
        record.serverStatus = row.status
        record.preparation = row.status == "preparing" ? row.preparation : nil
        if let size = Self.serverFileSize(
            row,
            provider: MediaServerProvider.forServerID(scopeServerId),
            currentSize: record.fileSize,
            bytesDownloaded: record.bytesDownloaded,
            localStatus: record.localStatus
        ) {
            record.fileSize = size
        }
        if let completedAt = row.completedAt {
            record.downloadedAt = completedAt
        }
    }

    /// The size to take from a server row, or nil to keep the record's.
    /// Silo's size can change before the transfer starts (a prepared file
    /// replaces the source's size when it's ready), so it's refreshed until
    /// bytes arrive. While Silo is still preparing a smaller quality it
    /// reports the source file's size, which is skipped in favour of the
    /// runtime estimate. Other servers keep the first size they report.
    nonisolated static func serverFileSize(
        _ row: ServerDownloadRow,
        provider: MediaServerProvider,
        currentSize: Int64,
        bytesDownloaded: Int64,
        localStatus: LocalDownloadStatus
    ) -> Int64? {
        guard let size = row.fileSize, size > 0 else { return nil }
        let isSilo = provider == .silo
        if isSilo, row.status == "preparing", row.quality != DownloadFormat.original.rawValue { return nil }
        if currentSize <= 0 { return size }
        guard isSilo, bytesDownloaded == 0 else { return nil }
        switch localStatus {
        case .registering, .preparing, .queued: return size
        case .fetchingAssets, .downloading, .paused, .completed, .failed, .revoked: return nil
        }
    }

    private func makeRecord(from row: ServerDownloadRow, type: String?) -> DownloadRecord {
        DownloadRecord(
            id: row.id,
            contentId: row.contentId,
            episodeId: row.episodeId,
            batchId: row.batchId,
            mediaFileId: row.mediaFileId,
            format: row.quality,
            effectiveQuality: row.effectiveQuality,
            deliveryFormat: row.deliveryFormat,
            targetBitrateKbps: row.targetBitrateKbps,
            revision: row.revision,
            serverStatus: row.status,
            localStatus: mapInitialStatus(row.status),
            fileSize: Self.serverFileSize(
                row,
                provider: MediaServerProvider.forServerID(scopeServerId),
                currentSize: 0,
                bytesDownloaded: 0,
                localStatus: .registering
            ) ?? 0,
            bytesDownloaded: 0,
            mediaFilename: nil,
            manifestFilename: nil,
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: nil,
            subtitle: nil,
            type: type,
            seriesId: nil,
            posterThumbhash: nil,
            preparation: row.status == "preparing" ? row.preparation : nil,
            container: nil,
            stableIdentity: nil,
            registeredAt: row.createdAt ?? Date(),
            downloadedAt: row.completedAt,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func mapInitialStatus(_ serverStatus: String) -> LocalDownloadStatus {
        switch serverStatus {
        case "ready": return .queued
        case "preparing": return .preparing
        case "revoked": return .revoked
        case "failed": return .failed
        default: return .registering
        }
    }

    private func upsertSubscription(_ server: ServerSubscription, seriesTitle: String?) {
        let mirror = DownloadSubscription(from: server, seriesTitle: seriesTitle)
        if let index = file.subscriptions.firstIndex(where: { $0.id == server.id }) {
            file.subscriptions[index] = mirror
        } else {
            file.subscriptions.append(mirror)
        }
    }

    private func setLocalStatus(_ status: LocalDownloadStatus, id: String) {
        guard var record = file.records[id] else { return }
        record.localStatus = status
        file.records[id] = record
        persist()
    }

    /// A tagged transfer only ever belongs to its own scope's record; an
    /// untagged one (started by an older build) is matched by identifier.
    private func recordByTask(_ taskId: Int, tag: DownloadTaskTag? = nil) -> DownloadRecord? {
        if let tag {
            guard tag.isScope(serverId: scopeServerId, profileId: scopeProfileId),
                  let record = file.records[tag.recordId], record.taskIdentifier == taskId else { return nil }
            return record
        }
        return file.records.values.first { $0.taskIdentifier == taskId }
    }

    // MARK: - Background time

    private func beginBackgroundWork() {
        backgroundWorkCount += 1
        #if canImport(UIKit)
        guard backgroundWorkID == .invalid else { return }
        backgroundWorkID = UIApplication.shared.beginBackgroundTask(withName: "Vivid downloads") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackgroundTime() }
        }
        #endif
    }

    private func endBackgroundWork() {
        backgroundWorkCount = max(0, backgroundWorkCount - 1)
        if backgroundWorkCount == 0 { releaseBackgroundTime() }
    }

    private func releaseBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundWorkID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundWorkID)
        backgroundWorkID = .invalid
        #endif
    }

    private func mediaExtension(for record: DownloadRecord) -> String {
        switch (record.container ?? "").lowercased() {
        case "mkv", "matroska": return "mkv"
        case "mov": return "mov"
        case "m4v": return "m4v"
        case "webm": return "webm"
        case "avi": return "avi"
        case "ts": return "ts"
        case "m2ts": return "m2ts"
        default: return "mp4"
        }
    }

    /// Per-subscription `max_storage_bytes` soft gate: skip starting a
    /// download that would push its series over the cap. The server only
    /// soft-gates; the client is authoritative.
    private func exceedsStorageCap(for record: DownloadRecord) -> Bool {
        guard let seriesId = capSeriesId(for: record),
              let subscription = subscription(forSeriesId: seriesId),
              subscription.maxStorageBytes > 0 else {
            return false
        }
        // Count completed bytes plus the expected size of in-flight
        // transfers — `processQueue` can start several episodes in one
        // pass, and counting only `.completed` would let each of them see
        // the same free capacity and overshoot the cap together.
        let used = file.records.values
            .filter { other in
                guard other.id != record.id, capSeriesId(for: other) == seriesId else { return false }
                switch other.localStatus {
                case .completed, .downloading, .fetchingAssets, .paused: return true
                default: return false
                }
            }
            .reduce(Int64(0)) { $0 + max($1.fileSize, $1.bytesDownloaded) }
        return used + max(record.fileSize, 0) > subscription.maxStorageBytes
    }

    /// Series identity for cap accounting. Episode rows registered by
    /// subscription sync carry the series id in `contentId` until the
    /// manifest hydrates `seriesId` — without the fallback, freshly synced
    /// episodes would bypass the cap entirely.
    private func capSeriesId(for record: DownloadRecord) -> String? {
        record.seriesId ?? (record.episodeId != nil ? record.contentId : nil)
    }

    private func absoluteFileURLForNewAsset(recordId: String, filename: String) -> URL? {
        guard !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: recordId,
            filename: filename
        )
    }

    private func fileSizeOnDisk(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func persist() {
        guard !scopeServerId.isEmpty, !scopeProfileId.isEmpty else { return }
        lastProgressPersist = Date()
        let snapshot = file
        let serverId = scopeServerId
        let profileId = scopeProfileId
        // Chain each save after the previous so writes land in call order.
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            await DownloadStore.shared.save(snapshot, serverId: serverId, profileId: profileId)
        }
    }

    /// Recompute scope storage usage off the MainActor and publish it.
    private func refreshStorageUsage() {
        let serverId = scopeServerId
        let profileId = scopeProfileId
        guard !serverId.isEmpty, !profileId.isEmpty else {
            storageBytesUsed = 0
            return
        }
        Task.detached(priority: .utility) {
            let bytes = DownloadFilePaths.bytesUsed(serverId: serverId, profileId: profileId)
            await MainActor.run { [weak self] in self?.storageBytesUsed = bytes }
        }
    }

    /// Throttle disk writes during the high-frequency progress callbacks;
    /// the in-memory mutation already drives the UI.
    private func persistProgressThrottled() {
        guard Date().timeIntervalSince(lastProgressPersist) > 2 else { return }
        persist()
    }

    // MARK: - Transfer rate

    /// Exponentially-smoothed rate from progress deltas. Samples at least
    /// `rateSampleInterval` apart so the burst-y delegate callbacks don't
    /// produce jittery instantaneous rates.
    private func updateTransferRate(recordId: String, bytes: Int64) {
        let now = Date()
        guard let sample = rateSamples[recordId] else {
            rateSamples[recordId] = (bytes, now)
            return
        }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= Self.rateSampleInterval else { return }
        // Resume-data restarts can report fewer bytes than the last sample;
        // reset the window instead of publishing a negative rate.
        guard bytes >= sample.bytes else {
            rateSamples[recordId] = (bytes, now)
            transferRates.removeValue(forKey: recordId)
            return
        }
        let instant = Double(bytes - sample.bytes) / elapsed
        if let previous = transferRates[recordId] {
            transferRates[recordId] = previous + Self.rateSmoothing * (instant - previous)
        } else {
            transferRates[recordId] = instant
        }
        rateSamples[recordId] = (bytes, now)
    }

    private func clearTransferRate(recordId: String) {
        rateSamples.removeValue(forKey: recordId)
        transferRates.removeValue(forKey: recordId)
        lastProgressPublish.removeValue(forKey: recordId)
    }
}
