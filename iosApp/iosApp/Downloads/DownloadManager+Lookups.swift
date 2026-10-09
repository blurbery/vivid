import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Lookups

    /// Single capability-aware check for the card badges: true only when the
    /// server still advertises downloads for this profile *and* the item's
    /// media is on device, so badges vanish alongside every other download
    /// affordance on servers without the capability. Membership is checked
    /// first so the (overwhelmingly common) non-downloaded card never touches
    /// the capability flag at all.
    func isDownloaded(contentId: String) -> Bool {
        downloadedContentIds.contains(contentId) && downloadsEnabled
    }

    func rebuildDownloadedIndex() {
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
}
