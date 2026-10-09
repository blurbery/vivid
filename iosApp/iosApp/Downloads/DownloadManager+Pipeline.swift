import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
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

    func processQueue() {
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

    func launchMediaPipeline(recordId: String) {
        pipelineTasks.removeValue(forKey: recordId)?.task.cancel()
        let generation = registrationScopeGeneration
        let id = UUID()
        let task = Task { @MainActor in
            await self.startMediaPipeline(recordId: recordId, generation: generation)
            if self.pipelineTasks[recordId]?.id == id { self.pipelineTasks[recordId] = nil }
        }
        pipelineTasks[recordId] = (id, task)
    }

    func pipelineIsCurrent(recordId: String, generation: UInt64) -> Bool {
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
    func scopeAuth() async -> CapturedOrdinaryRequestAuth? {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              !scopeServerId.isEmpty, auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else { return nil }
        return auth
    }

    func taskTag(recordId: String) -> DownloadTaskTag? {
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
    func backfillAssetsIfNeeded() async {
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

    func fetchArtwork(_ manifest: OfflineManifest, recordId: String, generation: UInt64, auth: CapturedOrdinaryRequestAuth) async {
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
    func reportFailure(_ stage: DownloadFailureReport.Stage, error: Error, record: DownloadRecord) {
        guard let failure = DownloadFailureReport(stage: stage, error: error, server: MediaServerProvider.active.rawValue,
                                                  quality: record.format, batch: record.batchId != nil,
                                                  retries: record.retryCount) else { return }
        AppHealthMonitor.downloadFailed(failure)
    }

    func reportFailure(_ stage: DownloadFailureReport.Stage, status: Int?, urlErrorCode: Int?, error: String,
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
    func syncLiveActivity() {
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
    func notifyTerminalFailure(_ record: DownloadRecord) {
        #if os(iOS)
        DownloadNotifier.downloadFailed(record)
        #endif
    }
}
