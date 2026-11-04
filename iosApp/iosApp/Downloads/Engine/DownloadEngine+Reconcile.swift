import Foundation

extension DownloadManager {
    // MARK: Reconcile

    /// Brings the records in line with the server's rows: merges each row,
    /// marks what the server dropped, adds rows registered elsewhere (series
    /// monitoring, another device) and reconnects running transfers.
    func reconcile(runningQueue: Bool) async {
        guard currentScope != nil, downloadsEnabled else { return }
        let generation = self.generation
        guard let identity = await scopeIdentity(), generation == self.generation else { return }
        flushServerDeletes()
        let rows: [ServerDownloadRow]
        do {
            rows = try await VividAPI.shared.listDownloads(auth: identity)
        } catch {
            return
        }
        guard generation == self.generation else { return }
        // Read now, so a delete made while the list was in flight still counts.
        let notBack = Set(file.pendingServerDeletes ?? []).union(deletedSinceDeactivation)
        var rowsById: [String: ServerDownloadRow] = [:]
        for row in rows where rowsById[row.id] == nil { rowsById[row.id] = row }

        var state = file
        var completions: [(id: String, revision: Int?, at: Date?)] = []
        for (id, before) in state.records {
            var record = before
            if let row = rowsById[id] {
                merge(row, into: &record)
                if record.localStatus == .completed, row.status == "ready" || row.status == "downloading" {
                    completions.append((id, record.revision, record.downloadedAt))
                }
                switch row.status {
                case "ready":
                    if record.localStatus == .preparing || record.localStatus == .registering { record.localStatus = .queued }
                case "revoked":
                    if record.localStatus == .completed || record.localStatus.isActive { record.localStatus = .revoked }
                case "failed":
                    if record.localStatus != .completed {
                        record.localStatus = .failed
                        record.lastError = "server_failed"
                        if before.localStatus != .failed {
                            report(record, stage: .conversion, status: nil, urlErrorCode: nil, error: "server_failed")
                        }
                    }
                default:
                    break
                }
            } else if record.localStatus.isActive {
                // Its transfer and files are left as they are.
                record.localStatus = .failed
                record.lastError = "removed_on_server"
            }
            state.records[id] = record
        }
        for row in rows where state.records[row.id] == nil && !notBack.contains(row.id) {
            state.records[row.id] = newRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
        }
        file = state
        persist()
        if !completions.isEmpty {
            Task {
                for completion in completions {
                    try? await VividAPI.shared.patchDownloadStatus(
                        id: completion.id, status: "completed", revision: completion.revision,
                        updatedAt: completion.at ?? Date(), auth: identity
                    )
                }
            }
        }
        await reconnectTransfers()
        if runningQueue {
            runQueue()
            startPreparationPoll()
        }
    }

    /// Queues again what a relaunch or a lost task left without a transfer.
    private func reconnectTransfers() async {
        // A transfer started while the live list is read keeps its new task:
        // records added, or whose task changed, during the wait are left alone.
        let tasksBefore = file.records.mapValues(\.taskIdentifier)
        let live = await transfers.liveIdentifiers()
        var state = file
        var requeued = false
        for (id, before) in state.records {
            guard let taskBefore = tasksBefore[id], taskBefore == before.taskIdentifier else { continue }
            var record = before
            // A recreated session reuses identifiers, so a stale one must go.
            if let task = record.taskIdentifier, !live.contains(task), !pausePending.contains(id) {
                record.taskIdentifier = nil
            }
            defer { state.records[id] = record }
            guard retryTimers[id] == nil else { continue }
            guard record.localStatus == .downloading || record.localStatus == .fetchingAssets else { continue }
            if record.localStatus == .downloading, let task = record.taskIdentifier, live.contains(task) { continue }
            if record.localStatus == .fetchingAssets, preparations[id] != nil { continue }
            record.localStatus = .queued
            requeued = true
        }
        file = state
        if requeued { persist() }
    }

    // MARK: Preparing on the server

    /// While Silo prepares downloads: look at each one's manifest once for
    /// its estimated size and artwork, then reconcile every 15 seconds.
    func startPreparationPoll() {
        guard preparationPoll == nil, hasServerPreparingDownloads else { return }
        preparationPoll = DownloadEngine.Running { [weak self] running in
            while let self, self.hasServerPreparingDownloads {
                await self.lookAtPreparingDownloads()
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await self.reconcile(runningQueue: true)
            }
            if self?.preparationPoll?.id == running { self?.preparationPoll = nil }
        }
    }

    private func lookAtPreparingDownloads() async {
        guard let scope = currentScope, MediaServerProvider.forServerID(scope.serverId) == .silo else { return }
        let candidates = file.records.values.filter {
            $0.localStatus == .preparing && !lookedAtPreparing.contains($0.id) && (preparingLookFailures[$0.id] ?? 0) < 3
        }.map(\.id)
        guard !candidates.isEmpty, let identity = await scopeIdentity() else { return }
        let generation = self.generation
        func isCurrent(_ id: String) -> Bool {
            !Task.isCancelled && generation == self.generation && file.records[id] != nil
        }
        for id in candidates {
            guard isCurrent(id) else { continue }
            let manifest: OfflineManifest
            do {
                manifest = try await VividAPI.shared.fetchManifest(downloadId: id, auth: identity)
            } catch {
                preparingLookFailures[id, default: 0] += 1
                continue
            }
            guard isCurrent(id), let record = file.records[id], record.localStatus == .preparing else { continue }
            lookedAtPreparing.insert(id)
            // Until the file is ready, Silo reports the source's size.
            if record.fileSize <= 0, let format = DownloadFormat(rawValue: record.format), format != .original,
               let estimate = StreamedTranscodeDownload.estimatedBytes(format: format, durationSeconds: manifest.durationSeconds) {
                file.records[id]?.fileSize = estimate
                persist()
            }
            if record.posterFilename == nil {
                await fetchArtwork(id, manifest: manifest, identity: identity, isCurrent: { isCurrent(id) })
            }
        }
    }

    // MARK: Series monitoring

    // Each request goes under the scope's own sign-in and profile, and its
    // answer is only mirrored while that scope is still the current one.

    func startMonitoring(seriesId: String, seriesTitle: String?, rule: MonitoringRule, seasonNumbers: [Int]?,
                         deleteWatched: Bool, maxStorageBytes: Int64) async throws {
        guard let scope = currentScope, let identity = await scopeIdentity() else {
            throw HTTPError.requestIdentityChanged
        }
        let generation = self.generation
        let request = CreateSubscriptionRequest(
            seriesId: seriesId, mode: rule.rawValue,
            seasonNumbers: rule == .chosenSeasons ? seasonNumbers : nil,
            deleteWatched: deleteWatched, maxStorageBytes: maxStorageBytes
        )
        #if os(iOS)
        // Monitoring announces the episodes it queues.
        Task { await LocalNotificationAuthorization.requestIfNeeded() }
        #endif
        let response = try await VividAPI.shared.createSubscription(request, auth: identity)
        guard currentScope == scope, self.generation == generation else { return }
        mirror(response.subscription, seriesTitle: seriesTitle)
        persist()
        await reconcile(runningQueue: true)
    }

    func changeMonitoring(id: String, rule: MonitoringRule?, seasonNumbers: [Int]?, deleteWatched: Bool?,
                          maxStorageBytes: Int64?, active: Bool?) async throws {
        guard let scope = currentScope, let identity = await scopeIdentity() else {
            throw HTTPError.requestIdentityChanged
        }
        let generation = self.generation
        let seriesTitle = file.subscriptions.first { $0.id == id }?.seriesTitle
        let request = UpdateSubscriptionRequest(
            mode: rule?.rawValue, seasonNumbers: seasonNumbers, deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes, active: active
        )
        #if os(iOS)
        if active == true { Task { await LocalNotificationAuthorization.requestIfNeeded() } }
        #endif
        let response = try await VividAPI.shared.updateSubscription(id: id, request, auth: identity)
        guard currentScope == scope, self.generation == generation else { return }
        mirror(response.subscription, seriesTitle: seriesTitle)
        persist()
        await reconcile(runningQueue: true)
    }

    /// Deletes the subscription on the server, then the local copy. If the
    /// server delete fails the local copy stays, so the series still shows
    /// as monitored and Stop Monitoring can be tried again. False when it
    /// stays.
    @discardableResult
    func stopMonitoring(id: String) async -> Bool {
        guard let scope = currentScope, let identity = await scopeIdentity() else { return false }
        let generation = self.generation
        do {
            try await VividAPI.shared.deleteSubscription(id: id, auth: identity)
        } catch {
            guard DownloadEngine.MonitoringRules.deleteRemovesLocalCopy(after: error) else {
                DownloadEngine.log.error("Couldn't stop monitoring a series: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard currentScope == scope, self.generation == generation else { return false }
        file.subscriptions.removeAll { $0.id == id }
        persist()
        return true
    }

    private func mirror(_ subscription: DownloadEngine.ServerSubscription, seriesTitle: String?) {
        let copy = MonitoredSeries(
            id: subscription.id, seriesId: subscription.seriesId, seriesTitle: seriesTitle, mode: subscription.mode,
            targetSeason: subscription.targetSeason, seasonNumbers: subscription.seasonNumbers,
            deleteWatched: subscription.deleteWatched, maxStorageBytes: subscription.maxStorageBytes,
            active: subscription.active
        )
        if let index = file.subscriptions.firstIndex(where: { $0.id == subscription.id }) {
            file.subscriptions[index] = copy
        } else {
            file.subscriptions.append(copy)
        }
    }

    /// Monitoring, offline progress and retention, on each foreground and in
    /// the background refresh.
    func syncMonitoringAndProgress() async {
        guard downloadsEnabled else { return }
        var registered = 0
        var known: Set<String> = []
        let generation = self.generation
        if !file.subscriptions.isEmpty, let identity = await scopeIdentity() {
            known = Set(file.records.keys)
            registered = (try? await VividAPI.shared.syncSubscriptions(auth: identity)) ?? 0
        }
        await flushProgressQueue()
        await pullProgress()
        await reconcile(runningQueue: true)
        #if os(iOS)
        if registered > 0, self.generation == generation {
            let fresh = file.records.values.filter { !known.contains($0.id) && $0.episodeId != nil }
            if !fresh.isEmpty {
                let titles = Set(fresh.compactMap { record in
                    let seriesId = record.seriesId ?? record.contentId
                    return file.subscriptions.first { $0.seriesId == seriesId }?.seriesTitle
                })
                DownloadEngine.Alerts.newEpisodes(count: fresh.count, seriesTitles: titles)
            }
        }
        #endif
        enforceRetention()
    }

    /// Deletes watched episodes of series whose subscription asks for it,
    /// active or not. The server never deletes files on the device.
    func enforceRetention() {
        let series = Set(file.subscriptions.filter(\.deleteWatched).map(\.seriesId))
        guard !series.isEmpty else { return }
        let watched = file.records.values.filter { record in
            guard record.localStatus == .completed, let seriesId = record.seriesId else { return false }
            return series.contains(seriesId) && isFinishedWatching(record)
        }
        for record in watched { remove(recordId: record.id) }
    }
}

extension DownloadEngine {
    enum MonitoringRules {
        /// Whether a failed server delete still lets Stop Monitoring drop the
        /// local copy: only when the server no longer has the subscription.
        static func deleteRemovesLocalCopy(after error: Error) -> Bool {
            (error as? HTTPError)?.statusCode == 404
        }
    }
}
