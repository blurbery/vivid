import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
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

    func invalidatePendingRegistrations() {
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
}
