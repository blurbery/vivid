import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Helpers

    func upsertRow(
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

    func mergeExistingRecord(_ existing: DownloadRecord, with row: ServerDownloadRow) -> DownloadRecord {
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

    func makeRecord(from row: ServerDownloadRow, type: String?) -> DownloadRecord {
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

    func upsertSubscription(_ server: ServerSubscription, seriesTitle: String?) {
        let mirror = DownloadSubscription(from: server, seriesTitle: seriesTitle)
        if let index = file.subscriptions.firstIndex(where: { $0.id == server.id }) {
            file.subscriptions[index] = mirror
        } else {
            file.subscriptions.append(mirror)
        }
    }

    func setLocalStatus(_ status: LocalDownloadStatus, id: String) {
        guard var record = file.records[id] else { return }
        record.localStatus = status
        file.records[id] = record
        persist()
    }

    /// A tagged transfer only ever belongs to its own scope's record; an
    /// untagged one (started by an older build) is matched by identifier.
    func recordByTask(_ taskId: Int, tag: DownloadTaskTag? = nil) -> DownloadRecord? {
        if let tag {
            guard tag.isScope(serverId: scopeServerId, profileId: scopeProfileId),
                  let record = file.records[tag.recordId], record.taskIdentifier == taskId else { return nil }
            return record
        }
        return file.records.values.first { $0.taskIdentifier == taskId }
    }
}
