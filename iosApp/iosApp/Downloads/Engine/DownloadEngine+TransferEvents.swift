import Foundation

extension DownloadManager {
    // MARK: Matching

    /// A tagged event matches only its own record in the current scope, and
    /// only while that record still runs this task. An untagged one (an
    /// older build's transfer) matches the first record running the task.
    private func recordId(forTask task: Int, tag: DownloadTaskTag?) -> String? {
        if let tag {
            guard let scope = currentScope, tag.isScope(serverId: scope.serverId, profileId: scope.profileId),
                  file.records[tag.recordId]?.taskIdentifier == task else { return nil }
            return tag.recordId
        }
        return file.records.values.first { $0.taskIdentifier == task }?.id
    }

    private func belongsToAnotherScope(_ tag: DownloadTaskTag?) -> DownloadScope? {
        guard let tag else { return nil }
        if let scope = currentScope, tag.isScope(serverId: scope.serverId, profileId: scope.profileId) { return nil }
        return DownloadScope(serverId: tag.serverId, profileId: tag.profileId)
    }

    // MARK: Progress

    func transferProgressed(task: Int, written: Int64, expected: Int64, tag: DownloadTaskTag?) {
        guard let id = recordId(forTask: task, tag: tag) else { return }
        sampleRate(id, bytes: written)
        let now = Date()
        // At most once a second; the total is cumulative, so nothing is lost.
        if let last = progressPublishedAt[id], now.timeIntervalSince(last) < 1 { return }
        progressPublishedAt[id] = now
        guard var record = file.records[id] else { return }
        record.bytesDownloaded = written
        if expected > 0 { record.fileSize = expected }
        file.records[id] = record
        if now.timeIntervalSince(lastSaveAt) > 2 { persist() }
    }

    private func sampleRate(_ id: String, bytes: Int64) {
        let now = Date()
        guard let sample = rateSamples[id] else {
            rateSamples[id] = DownloadEngine.RateSample(bytes: bytes, at: now)
            return
        }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= 0.5 else { return }
        guard bytes >= sample.bytes else {
            // A restart from resume data.
            rateSamples[id] = DownloadEngine.RateSample(bytes: bytes, at: now)
            transferRates[id] = nil
            return
        }
        let instant = Double(bytes - sample.bytes) / elapsed
        transferRates[id] = transferRates[id].map { $0 + 0.3 * (instant - $0) } ?? instant
        rateSamples[id] = DownloadEngine.RateSample(bytes: bytes, at: now)
    }

    /// Forgets a record's rate, and its last progress time so the next
    /// progress shows at once.
    func clearRate(_ id: String) {
        rateSamples[id] = nil
        transferRates[id] = nil
        progressPublishedAt[id] = nil
    }

    // MARK: Finished

    func transferFinished(task: Int, staged: URL, status: Int, tag: DownloadTaskTag?) {
        intentionalCancels.remove(task)
        guard let id = recordId(forTask: task, tag: tag), var record = file.records[id] else {
            if let other = belongsToAnotherScope(tag), let tag {
                otherScopeFinished(task: task, staged: staged, status: status, tag: tag, scope: other)
            } else {
                DownloadEngine.Disk.remove(staged)
            }
            return
        }
        clearRate(id)
        let name = DownloadEngine.Disk.mediaFileName(container: record.container)
        guard let destination = fileURL(named: name, forRecord: id) else {
            DownloadEngine.Disk.remove(staged)
            return
        }
        do {
            try DownloadEngine.Disk.move(staged, to: destination)
        } catch {
            // The staged file stays in staging; no failure notice is posted.
            DownloadEngine.log.error("Couldn't move a finished download into place: \(error.localizedDescription, privacy: .private)")
            record.localStatus = .failed
            record.lastError = "move_failed"
            record.taskIdentifier = nil
            file.records[id] = record
            persist()
            report(record, stage: .saving, status: nil, urlErrorCode: nil, error: "move_failed")
            runQueue()
            return
        }
        let finishedAt = Date()
        record.localStatus = .completed
        record.mediaFilename = name
        record.downloadedAt = finishedAt
        record.taskIdentifier = nil
        record.lastError = nil
        let onDisk = DownloadEngine.Disk.fileSize(at: destination)
        if onDisk > 0 { record.fileSize = onDisk }
        record.bytesDownloaded = record.fileSize
        file.records[id] = record
        persist()
        #if os(iOS)
        DownloadEngine.Alerts.completed(record)
        #endif
        // Not pinned; reconcile reports it again if this one is lost.
        let revision = record.revision
        Task {
            try? await VividAPI.shared.patchDownloadStatus(id: id, status: "completed", revision: revision, updatedAt: finishedAt)
        }
        runQueue()
        refreshStorageUsage()
        Task { enforceRetention() }
    }

    // MARK: Failed

    func transferFailed(task: Int, status: Int?, resumeData: Data?, message: String, urlErrorCode: Int?,
                        tag: DownloadTaskTag?) {
        // A pause, delete, sign-out or replaced file.
        if intentionalCancels.remove(task) != nil { return }
        guard let id = recordId(forTask: task, tag: tag), var record = file.records[id] else {
            if let other = belongsToAnotherScope(tag), let tag {
                otherScopeFailed(task: task, resumeData: resumeData, tag: tag, scope: other)
            }
            return
        }
        record.taskIdentifier = nil
        clearRate(id)
        switch status {
        case 409?:
            record.localStatus = .revoked
            record.serverStatus = "revoked"
            file.records[id] = record
            persist()
            runQueue()
        case let refused? where refused == 404 || refused == 403:
            record.localStatus = .failed
            record.lastError = refused == 404 ? "not_found" : "forbidden"
            file.records[id] = record
            persist()
            notifyFailure(of: record)
            report(record, stage: .transfer, status: refused, urlErrorCode: nil, error: "http")
            runQueue()
        case 401?:
            if record.retryCount < 4 {
                record.retryCount += 1
                file.records[id] = record
                scheduleRetry(id, resumeData: nil, refreshesSignIn: true)
                return
            }
            record.localStatus = .failed
            record.lastError = "unauthorized"
            file.records[id] = record
            persist()
            notifyFailure(of: record)
            report(record, stage: .transfer, status: 401, urlErrorCode: nil, error: "http")
            runQueue()
        default:
            if record.retryCount < 4 {
                record.retryCount += 1
                file.records[id] = record
                scheduleRetry(id, resumeData: resumeData, refreshesSignIn: false)
                return
            }
            record.localStatus = .failed
            record.lastError = message
            file.records[id] = record
            persist()
            notifyFailure(of: record)
            let failedStatus = status.flatMap { (200...299).contains($0) ? nil : $0 }
            let token: String
            if failedStatus != nil {
                token = "http"
            } else if urlErrorCode != nil {
                token = "network"
            } else {
                token = message == "stage_failed" ? "stage_failed" : "other"
            }
            report(record, stage: .transfer, status: failedStatus, urlErrorCode: urlErrorCode, error: token)
            runQueue()
        }
    }

    // MARK: Another scope's transfers

    /// A transfer that finished after a server or profile switch is saved
    /// into its own scope's file instead of being thrown away.
    private func otherScopeFinished(task: Int, staged: URL, status: Int, tag: DownloadTaskTag, scope: DownloadScope) {
        Task { @MainActor in
            var state = await DownloadEngine.Store.shared.load(scope)
            if currentScope == scope {
                redeliver(.finished(task: task, staged: staged, status: status, tag: tag))
                return
            }
            guard var record = state.records[tag.recordId], record.taskIdentifier == task else {
                DownloadEngine.Disk.remove(staged)
                return
            }
            let name = DownloadEngine.Disk.mediaFileName(container: record.container)
            let destination = DownloadEngine.Disk.file(name, scope: scope, downloadId: record.id)
            record.taskIdentifier = nil
            do {
                try DownloadEngine.Disk.move(staged, to: destination)
                record.localStatus = .completed
                record.mediaFilename = name
                record.downloadedAt = Date()
                record.lastError = nil
                let onDisk = DownloadEngine.Disk.fileSize(at: destination)
                if onDisk > 0 { record.fileSize = onDisk }
                record.bytesDownloaded = record.fileSize
            } catch {
                DownloadEngine.Disk.remove(staged)
                record.localStatus = .queued
            }
            state.records[record.id] = record
            await DownloadEngine.Store.shared.save(state, to: scope)
            adoptIfBack(record, task: task, scope: scope)
        }
    }

    private func otherScopeFailed(task: Int, resumeData: Data?, tag: DownloadTaskTag, scope: DownloadScope) {
        Task { @MainActor in
            var state = await DownloadEngine.Store.shared.load(scope)
            // Back in that scope already: the next reconcile queues it again.
            guard currentScope != scope, var record = state.records[tag.recordId], record.taskIdentifier == task else { return }
            record.taskIdentifier = nil
            record.localStatus = .queued
            if let resumeData {
                let url = DownloadEngine.Disk.file(DownloadEngine.Disk.resumeFileName, scope: scope, downloadId: record.id)
                if (try? resumeData.write(to: url, options: .atomic)) != nil {
                    record.resumeDataFilename = DownloadEngine.Disk.resumeFileName
                }
            }
            state.records[record.id] = record
            await DownloadEngine.Store.shared.save(state, to: scope)
            adoptIfBack(record, task: task, scope: scope)
        }
    }

    /// When the app has switched back to that scope meanwhile, takes the
    /// saved record into the loaded state.
    private func adoptIfBack(_ record: DownloadRecord, task: Int, scope: DownloadScope) {
        guard currentScope == scope, file.records[record.id]?.taskIdentifier == task else { return }
        file.records[record.id] = record
        persist()
        runQueue()
    }

    // MARK: Pause, resume and retry

    func pauseTransfer(recordId id: String) {
        guard var record = file.records[id], record.localStatus == .downloading else { return }
        guard let task = record.taskIdentifier else {
            // Waiting out a retry delay.
            retryTimers[id]?.task.cancel()
            retryTimers[id] = nil
            record.localStatus = .paused
            file.records[id] = record
            clearRate(id)
            persist()
            runQueue()
            return
        }
        intentionalCancels.insert(task)
        pausePending.insert(id)
        // The task identifier stays until the pause finishes, so a transfer
        // that completes meanwhile still completes the record.
        record.localStatus = .paused
        file.records[id] = record
        clearRate(id)
        persist()
        Task { @MainActor in
            let data = await transfers.pause(task)
            finishPause(id, resumeData: data)
        }
        runQueue()
    }

    private func finishPause(_ id: String, resumeData: Data?) {
        pausePending.remove(id)
        let resumes = resumeRequested.remove(id) != nil
        guard var record = file.records[id], record.localStatus == .paused else { return }
        record.taskIdentifier = nil
        if let resumeData, let url = fileURL(named: DownloadEngine.Disk.resumeFileName, forRecord: id) {
            try? resumeData.write(to: url, options: .atomic)
            record.resumeDataFilename = DownloadEngine.Disk.resumeFileName
        }
        if resumes { record.localStatus = .queued }
        file.records[id] = record
        persist()
        if resumes { runQueue() }
    }

    func resumeTransfer(recordId id: String) {
        guard var record = file.records[id], record.localStatus == .paused else { return }
        if pausePending.contains(id) {
            // The resume data being captured is used.
            resumeRequested.insert(id)
            return
        }
        record.localStatus = .queued
        file.records[id] = record
        persist()
        runQueue()
    }

    func retryFailed(recordId id: String) {
        guard var record = file.records[id], record.localStatus == .failed else { return }
        record.localStatus = .queued
        record.retryCount = 0
        record.lastError = nil
        file.records[id] = record
        persist()
        runQueue()
    }

    // MARK: Deleting

    func remove(recordId id: String) {
        guard let record = file.records[id] else { return }
        stopWork(on: record)
        file.records[id] = nil
        clearRate(id)
        persist()
        deleteFolder(ofRecord: id)
        deleteServerRows([id])
        runQueue()
        refreshStorageUsage()
        nudgeWaitingDownloads()
    }

    func deleteDownload(forContentId contentId: String) {
        guard let record = record(forContentId: contentId) else { return }
        remove(recordId: record.id)
    }

    func remove(recordIds ids: [String]) {
        var state = file
        var removedAny = false
        for id in ids {
            guard let record = state.records[id] else { continue }
            stopWork(on: record)
            state.records[id] = nil
            clearRate(id)
            deleteFolder(ofRecord: id)
            removedAny = true
        }
        guard removedAny else { return }
        file = state
        persist()
        deleteServerRows(ids)
        runQueue()
        refreshStorageUsage()
        nudgeWaitingDownloads()
    }

    /// Cancels the series' waiting episodes and unfinished downloads.
    /// Finished episodes stay.
    func cancelUnfinished(inSeries seriesId: String) {
        cancelWaiting(seriesId: seriesId)
        remove(recordIds: unfinishedRecords(inSeries: seriesId).map(\.id))
    }

    /// Cancels every waiting episode and unfinished download. Finished
    /// downloads stay.
    func cancelEveryUnfinished() {
        cancelAllWaiting()
        remove(recordIds: unfinishedRecords.map(\.id))
    }

    /// Cancels the record's preparation, transfer and retry timer.
    private func stopWork(on record: DownloadRecord) {
        preparations[record.id]?.task.cancel()
        preparations[record.id] = nil
        if let task = record.taskIdentifier {
            intentionalCancels.insert(task)
            Task { await transfers.cancel(task) }
        }
        retryTimers[record.id]?.task.cancel()
        retryTimers[record.id] = nil
    }

    // MARK: Server rows

    /// Deletes the rows on the server with this scope's own sign-in. Ids
    /// wait in the scope file until the server has them gone.
    private func deleteServerRows(_ ids: [String]) {
        guard currentScope != nil, !ids.isEmpty else { return }
        deletedSinceDeactivation.formUnion(ids)
        var pending = Set(file.pendingServerDeletes ?? [])
        pending.formUnion(ids)
        file.pendingServerDeletes = Array(pending)
        persist()
        flushServerDeletes()
    }

    /// A repeated delete gets 404, which counts as deleted.
    func flushServerDeletes() {
        Task { @MainActor in
            guard let scope = currentScope, let identity = await scopeIdentity() else { return }
            var deleted: Set<String> = []
            for id in file.pendingServerDeletes ?? [] {
                do {
                    try await VividAPI.shared.deleteDownloadRow(id: id, auth: identity)
                    deleted.insert(id)
                } catch let error as HTTPError where error.statusCode == 404 {
                    deleted.insert(id)
                } catch {}
            }
            guard !deleted.isEmpty, currentScope == scope else { return }
            let remaining = (file.pendingServerDeletes ?? []).filter { !deleted.contains($0) }
            file.pendingServerDeletes = remaining.isEmpty ? nil : remaining
            persist()
        }
    }
}
