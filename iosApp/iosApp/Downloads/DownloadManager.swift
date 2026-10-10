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

    /// Silo refused a download because this account already has as many in
    /// progress as its server allows (HTTP 429). Its quota for a period is a
    /// different refusal, which waiting a few minutes won't clear.
    static func isAccountLimit(_ error: Error) -> Bool {
        guard case HTTPError.http(429, let body) = error, let body = body?.lowercased() else { return false }
        return body.contains("download_limit_exceeded") || body.contains("concurrent download limit")
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

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.vivid.app",
        category: "Downloads"
    )

    /// Records preparing at once (manifest fetch and transfer hand-off).
    /// Media transfers themselves aren't capped here: they go straight to the
    /// background session, which spaces its own connections, so a whole
    /// season keeps downloading after the app is closed.
    static let maxConcurrentPreparations = 3
    static let maxRetries = 4

    /// In-memory persisted blob. Stored on the class so the `@Observable`
    /// macro tracks reads of its derived accessors below. Only
    /// `DownloadManager` and its extensions write it.
    var file: DownloadStoreFile = .empty {
        didSet {
            rebuildDownloadedIndex()
            let enabled = file.capability?.isUsable == true
            if enabled != downloadsEnabled { downloadsEnabled = enabled }
            let known = file.capability != nil
            if known != capabilityKnown { capabilityKnown = known }
            syncLiveActivity()
        }
    }

    var scopeServerId: String = ""
    var scopeProfileId: String = ""

    /// Coalesces the several legitimate app-lifecycle callers that can all ask
    /// for the same scope at launch. Without this, a late disk read can replace
    /// a newly registered in-memory download with its older empty snapshot.
    var scopeLoadTask: Task<DownloadStoreFile, Never>?
    var scopeLoadToken: UUID?
    var scopeLoadServerId = ""
    var scopeLoadProfileId = ""

    let sessionDelegate = DownloadSessionDelegate()
    var intentionalCancels: Set<Int> = []
    /// Preparing downloads whose poster and size estimate were already
    /// fetched this session (`prefetchPreparingDetails`), and how many times
    /// a manifest request failed for the rest.
    var preparingDetailsFetched: Set<String> = []
    var preparingDetailsAttempts: [String: Int] = [:]
    /// Set while `downloadEpisodes` registers a list. Transfers wait for the
    /// whole list: Silo counts transferring files against its per-user
    /// limit, so starting them early would get the rest of the list refused.
    var queueHolds = 0
    /// Retries that came due while `queueHolds` was set; they start when the
    /// hold ends, for the same reason the queue waits.
    var heldRetries: [() -> Void] = []
    /// Retries waiting downloads while any are left (see `scheduleWaitingDownloads`).
    var waitingTask: Task<Void, Never>?
    var isStartingWaiting = false
    /// Downloads deleted in the current scope. A list that was in flight
    /// during a delete can still return the row, which must not come back.
    /// Cleared on a scope change, which also drops any list in flight; each
    /// scope's unsent deletes stay in its own `pendingServerDeletes`.
    var deletedDownloadIds: Set<String> = []
    var pollTask: Task<Void, Never>?
    var lastProgressPersist = Date.distantPast
    /// Session events that arrive before the first scope activation loads the
    /// persisted registry (a background relaunch replays buffered delegate
    /// events the moment the session is recreated). Handling them against an
    /// empty registry would discard finished media as unmatched, so they are
    /// held here and replayed by `releaseHeldSessionEvents()`.
    var pendingSessionEvents: [DownloadSessionEvent] = []
    var sessionEventsHeld = true
    /// In-flight back-off timers keyed by record id, tracked so a foreground
    /// reconcile doesn't re-queue a record that already has a scheduled
    /// restart (double-starting the transfer) and so pause/delete can abort
    /// the timer instead of leaving it to fire against a dead record.
    var retryTasks: [String: Task<Void, Never>] = [:]
    /// Records whose pause is still waiting on the resume-data capture
    /// round-trip. A resume tapped inside that window is deferred to
    /// `finishPause` (via `pendingResumeIds`) so the captured data isn't
    /// dropped and the transfer restarted from byte zero.
    var pendingPauseIds: Set<String> = []
    var pendingResumeIds: Set<String> = []
    /// Serializes disk saves so a rapid burst of `persist()` calls can't land
    /// out of order and overwrite a newer snapshot with an older one.
    var saveChain: Task<Void, Never>?
    /// Cached scope storage usage; refreshed off the MainActor (a filesystem
    /// walk) so SwiftUI bodies reading `totalBytesUsed` don't block.
    var storageBytesUsed: Int64 = 0
    /// Smoothed transfer rate (bytes/sec) per downloading record, derived
    /// from progress deltas so the UI never needs its own timer competing
    /// with the `@Observable` update path.
    var transferRates: [String: Double] = [:]
    var rateSamples: [String: (bytes: Int64, at: Date)] = [:]
    static let rateSampleInterval: TimeInterval = 0.5
    static let rateSmoothing = 0.3
    /// Last time each record's byte counter was published into the
    /// `@Observable` `file` blob. Delegate callbacks arrive many times per
    /// second; UI counters should tick at a readable cadence instead.
    var lastProgressPublish: [String: Date] = [:]
    static let progressPublishInterval: TimeInterval = 1.0

    /// Leaf content ids (movie `contentId` / episode `episodeId`) whose media
    /// is on disk. Cached separately from `records` because poster cards check
    /// membership per card render — and only republished when membership
    /// actually changes, so in-flight progress ticks (which also mutate `file`)
    /// don't invalidate every visible card.
    var downloadedContentIds: Set<String> = []

    var progressBootstrapInFlight = false

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
    var capabilityChecksInFlight = 0
    /// The last permission check failed and nothing earlier is known.
    var capabilityCheckFailed = false
    var isCheckingCapability: Bool { capabilityChecksInFlight > 0 }
    /// Downloads are known to be off for this account, so the controls show
    /// crossed out rather than disappearing.
    var downloadsDisallowed: Bool { capabilityKnown && !downloadsEnabled }
    /// Background time held while a download is registered or handed to the
    /// background session, so work started just before the app closes still
    /// reaches the transfer.
    @ObservationIgnored var backgroundWorkCount = 0
    /// Set while the app is leaving the foreground, so every queued record
    /// is prepared at once rather than a few at a time.
    @ObservationIgnored var preparesEverything = false
    #if canImport(UIKit)
    @ObservationIgnored var backgroundWorkID = UIBackgroundTaskIdentifier.invalid
    #endif
    /// Leaf ids currently waiting for POST /downloads to return. This belongs
    /// to the manager (rather than one button) so a detail rebuild cannot make
    /// the preparing indicator disappear during registration.
    var pendingRegistrationContentIds: Set<String> = []
    /// Each pending id owns a unique token. An older request may finish after
    /// sign-out and reactivation, but its defer must never clear a newer
    /// request for the same content id.
    var pendingRegistrationTokens: [String: UUID] = [:]
    /// Incremented whenever the active server/profile identity is invalidated
    /// or replaced. Network responses captured under an older generation are
    /// discarded before they can mutate the newly active scope.
    var registrationScopeGeneration: UInt64 = 0
    var pipelineTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]
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
}
