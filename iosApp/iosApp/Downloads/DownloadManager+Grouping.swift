import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
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
        nudgeWaitingDownloads()
    }

    /// Delete server rows with this scope's own sign-in. If the sign-in has
    /// already moved to another account the deletes wait in this scope's
    /// registry and go out the next time it's active.
    func deleteServerRows(_ ids: [String]) {
        guard !scopeServerId.isEmpty, !ids.isEmpty else { return }
        deletedDownloadIds.formUnion(ids)
        file.pendingServerDeletes = Array(Set(file.pendingServerDeletes ?? []).union(ids))
        persist()
        flushPendingServerDeletes()
    }

    func flushPendingServerDeletes() {
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

    /// Cancel every unfinished download of a series, including any waiting
    /// for room on the server. Finished episodes stay.
    func cancelActiveDownloads(seriesId: String) {
        cancelWaiting(seriesId: seriesId)
        deleteDownloads(ids: activeRecords(seriesId: seriesId).map(\.id))
    }

    /// Cancel every unfinished download in this profile, including any
    /// waiting for room on the server. Finished ones stay.
    func cancelAllActiveDownloads() {
        cancelAllWaiting()
        deleteDownloads(ids: activeRecords.map(\.id))
    }

    /// One-time hydration of `seasonNumber`/`episodeNumber`/`seriesTitle` for
    /// episode downloads created before those fields existed. A cheap no-op
    /// once every record carries them.
    func backfillEpisodeMetadataIfNeeded() async {
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
}
