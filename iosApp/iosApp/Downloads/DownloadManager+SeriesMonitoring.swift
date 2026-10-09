import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
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
    func enforceRetention() async {
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
}
