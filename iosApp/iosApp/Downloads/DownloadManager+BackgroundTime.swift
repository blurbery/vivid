import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Background time

    func beginBackgroundWork() {
        backgroundWorkCount += 1
        #if canImport(UIKit)
        guard backgroundWorkID == .invalid else { return }
        backgroundWorkID = UIApplication.shared.beginBackgroundTask(withName: "Vivid downloads") { [weak self] in
            MainActor.assumeIsolated { self?.releaseBackgroundTime() }
        }
        #endif
    }

    func endBackgroundWork() {
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

    func mediaExtension(for record: DownloadRecord) -> String {
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
    func exceedsStorageCap(for record: DownloadRecord) -> Bool {
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

    func absoluteFileURLForNewAsset(recordId: String, filename: String) -> URL? {
        guard !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: recordId,
            filename: filename
        )
    }

    func fileSizeOnDisk(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func persist() {
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
    func refreshStorageUsage() {
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
    func persistProgressThrottled() {
        guard Date().timeIntervalSince(lastProgressPersist) > 2 else { return }
        persist()
    }
}
