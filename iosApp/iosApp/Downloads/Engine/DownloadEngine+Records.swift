import Foundation

// MARK: - Scope and errors

/// The server and profile a set of downloads belongs to.
struct DownloadScope: Equatable, Sendable {
    let serverId: String
    let profileId: String

    /// The active server and the token store's profile, empty when absent.
    @MainActor static func current() async -> DownloadScope {
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        return DownloadScope(serverId: serverId, profileId: profileId)
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
        case .unavailable: String(localized: "Downloads aren't available for this profile.")
        case .fileURLUnavailable: String(localized: "Could not resolve the download URL.")
        case .emptyRegistrationResponse: String(localized: "The server didn't create a download.")
        case .registrationAlreadyInFlight: String(localized: "This download is already being prepared.")
        case .scopeChangedDuringRegistration: String(localized: "The active profile changed before the download could start.")
        }
    }

    /// Silo's refusal while the account already has as many downloads in
    /// progress as it may. Only this sends episodes to the waiting list.
    static func isAccountLimit(_ error: Error) -> Bool {
        guard case let .http(statusCode, body)? = error as? HTTPError, statusCode == 429, let body else { return false }
        let text = body.lowercased()
        return text.contains("download_limit_exceeded") || text.contains("concurrent download limit")
    }
}

// MARK: - Records

/// Where one download is on this device. The server's own status is kept
/// separately on the record.
enum LocalDownloadStatus: String, Codable, Sendable {
    case registering
    case preparing
    case queued
    case downloading
    case paused
    case fetchingAssets
    case completed
    case failed
    case revoked
    case waiting

    var isActive: Bool {
        switch self {
        case .registering, .preparing, .queued, .downloading, .paused, .fetchingAssets, .waiting: true
        case .completed, .failed, .revoked: false
        }
    }
}

/// One managed download. Every field is saved in `store.json`; file names are
/// relative to the download's folder, because the app container moves.
struct DownloadRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var contentId: String
    let episodeId: String?
    var batchId: String? = nil
    var mediaFileId: Int
    var format: String
    var effectiveQuality: String? = nil
    var deliveryFormat: String? = nil
    var targetBitrateKbps: Int? = nil
    var revision: Int? = nil
    var serverStatus: String
    var localStatus: LocalDownloadStatus
    var fileSize: Int64
    var bytesDownloaded: Int64
    var mediaFilename: String? = nil
    var manifestFilename: String? = nil
    var posterFilename: String? = nil
    var backdropFilename: String? = nil
    var logoFilename: String? = nil
    /// Subtitle fetch URL to saved file name.
    var subtitleFilenames: [String: String] = [:]
    var resumeDataFilename: String? = nil
    var subtitlesChecked: Bool? = nil
    var artworkChecked: Bool? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var type: String? = nil
    var seriesId: String? = nil
    var seriesTitle: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var posterThumbhash: String? = nil
    var preferredPosterPath: String? = nil
    var preparation: DownloadPreparationStatus? = nil
    var container: String? = nil
    var stableIdentity: OfflineManifest.StableIdentity? = nil
    var registeredAt: Date
    var downloadedAt: Date? = nil
    /// A token, an `HTTP <status>` text or an error description. Never sent.
    var lastError: String? = nil
    var retryCount: Int = 0
    var taskIdentifier: Int? = nil

    var isPlayableOffline: Bool {
        (localStatus == .completed || localStatus == .revoked) && mediaFilename != nil
    }

    /// The id progress and badges use: the episode, else the item itself.
    var leafMediaItemId: String { episodeId ?? contentId }

    var progressFraction: Double {
        guard fileSize > 0 else { return 0 }
        return min(max(Double(bytesDownloaded) / Double(fileSize), 0), 1)
    }
}

/// An episode Silo turned away while the account was at its limit.
struct WaitingDownload: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let seriesId: String
    let title: String?
    let subtitle: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let posterThumbhash: String?
    let preferredPosterPath: String?
    let fileId: Int?
    let quality: String
    let queuedAt: Date

    /// The episode as a row of the in-progress list.
    var displayRecord: DownloadRecord {
        DownloadRecord(
            id: "waiting-\(id)", contentId: seriesId, episodeId: id, batchId: nil, mediaFileId: fileId ?? 0,
            format: quality, serverStatus: "waiting", localStatus: .waiting, fileSize: 0, bytesDownloaded: 0,
            title: title, subtitle: subtitle, type: "episode", seriesId: seriesId, seriesTitle: seriesTitle,
            seasonNumber: seasonNumber, episodeNumber: episodeNumber, posterThumbhash: posterThumbhash,
            preferredPosterPath: preferredPosterPath, registeredAt: queuedAt
        )
    }
}

// MARK: - Mirrors and progress

/// The saved copy of one series monitoring subscription.
struct MonitoredSeries: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let seriesId: String
    var seriesTitle: String?
    var mode: String
    var targetSeason: Int?
    var seasonNumbers: [Int]?
    var deleteWatched: Bool
    var maxStorageBytes: Int64
    var active: Bool
}

/// The local watch progress of one media item.
struct SavedProgress: Codable, Sendable {
    var position: Double
    var duration: Double
    var completed: Bool
    var updatedAt: Date
}

extension DownloadEngine {
    /// Offline progress waiting to be sent. At most one per media item.
    struct QueuedProgress: Codable, Hashable, Sendable {
        var id: UUID
        var mediaItemId: String
        var position: Double
        var duration: Double
        var updatedAt: Date
        var attempts: Int
        /// Set when the position was accepted but marking the item watched failed.
        var positionSent: Bool?
    }

    /// Silo's progress generation, kept as the server sends it.
    enum SnapshotGeneration: Codable, Hashable, Sendable {
        case number(Int64)
        case text(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .number(let number): try container.encode(number)
            case .text(let text): try container.encode(text)
            }
        }
    }

    /// One page of Silo's full progress snapshot.
    struct SnapshotPage: Codable, Sendable {
        struct Paging: Codable, Sendable {
            let hasMore: Bool
            let nextCursor: String?
        }

        let snapshotId: String
        let installationId: String
        let accountId: String
        let profileId: String
        let generation: SnapshotGeneration
        let mode: String
        let capturedAt: Date
        let expiresAt: Date
        let itemCount: Int
        let items: [ProgressPullItem]
        let page: Paging
        let complete: Bool
        let completionToken: String?
    }

    /// A snapshot being gathered, saved so a retry reuses its request id.
    struct SnapshotStage: Codable, Sendable {
        let requestId: String
        let createdAt: Date
        let installationId: String
        let accountId: String
        let profileId: String
        let generation: SnapshotGeneration
        var page: SnapshotPage?
        var items: [String: ProgressPullItem]
    }
}

// MARK: - The scope file

/// One scope's saved state, `store.json`.
struct DownloadStoreFile: Codable, Sendable {
    var version: Int
    var records: [String: DownloadRecord]
    var subscriptions: [MonitoredSeries]
    var capability: DownloadCapability?
    var capabilityFetchedAt: Date?
    var progressQueue: [DownloadEngine.QueuedProgress]
    var progressCursor: String?
    var localProgress: [String: SavedProgress]
    var progressBootstrap: DownloadEngine.SnapshotStage?
    var pendingServerDeletes: [String]?
    var waitingDownloads: [WaitingDownload]? = nil

    enum CodingKeys: String, CodingKey {
        case version, records, subscriptions, capability, capabilityFetchedAt, progressQueue, progressCursor
        case localProgress, progressBootstrap, pendingServerDeletes, waitingDownloads
    }

    static let empty = DownloadStoreFile(
        version: 1, records: [:], subscriptions: [], capability: nil, capabilityFetchedAt: nil, progressQueue: [],
        progressCursor: nil, localProgress: [:], progressBootstrap: nil, pendingServerDeletes: nil
    )
}

extension DownloadStoreFile {
    /// Each record is read on its own: one that can't be read is skipped and
    /// logged, and the rest are kept, so the next save keeps them too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        let entries = try container.nestedContainer(keyedBy: DownloadEngine.AnyKey.self, forKey: .records)
        var records: [String: DownloadRecord] = [:]
        for key in entries.allKeys {
            do {
                records[key.stringValue] = try entries.decode(DownloadRecord.self, forKey: key)
            } catch {
                DownloadEngine.log.error("Skipped a download record that couldn't be read: \(String(describing: error), privacy: .private)")
            }
        }
        self.records = records
        subscriptions = try container.decode([MonitoredSeries].self, forKey: .subscriptions)
        capability = try container.decodeIfPresent(DownloadCapability.self, forKey: .capability)
        capabilityFetchedAt = try container.decodeIfPresent(Date.self, forKey: .capabilityFetchedAt)
        progressQueue = try container.decode([DownloadEngine.QueuedProgress].self, forKey: .progressQueue)
        progressCursor = try container.decodeIfPresent(String.self, forKey: .progressCursor)
        localProgress = try container.decode([String: SavedProgress].self, forKey: .localProgress)
        progressBootstrap = try container.decodeIfPresent(DownloadEngine.SnapshotStage.self, forKey: .progressBootstrap)
        pendingServerDeletes = try container.decodeIfPresent([String].self, forKey: .pendingServerDeletes)
        waitingDownloads = try container.decodeIfPresent([WaitingDownload].self, forKey: .waitingDownloads)
    }
}

extension DownloadEngine {
    /// A coding key for objects whose keys are data, such as record ids.
    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
