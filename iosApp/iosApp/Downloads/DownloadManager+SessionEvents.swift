import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Background session events

    func handleSessionEvent(_ event: DownloadSessionEvent) {
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
    func releaseHeldSessionEvents() {
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

    func scheduleRetry(recordId: String, resumeData: Data?, refreshToken: Bool) {
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

    func startHeldRetries() {
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
}
