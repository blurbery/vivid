import Foundation

extension DownloadManager {
    // MARK: Recording

    /// Offline playback progress. Kept locally and queued for the server;
    /// completion is never undone here.
    func recordOfflineProgress(mediaItemId: String, position: Double, duration: Double, completed: Bool) {
        guard !mediaItemId.isEmpty, position.isFinite, position >= 0 else { return }
        let now = Date()
        var entry = file.localProgress[mediaItemId]
            ?? SavedProgress(position: 0, duration: duration, completed: false, updatedAt: now)
        entry.position = position
        if duration.isFinite, duration > 0 { entry.duration = duration }
        entry.completed = entry.completed || completed
        entry.updatedAt = now
        var state = file
        state.localProgress[mediaItemId] = entry
        state.progressQueue.removeAll { $0.mediaItemId == mediaItemId }
        state.progressQueue.append(DownloadEngine.QueuedProgress(
            id: UUID(), mediaItemId: mediaItemId, position: position, duration: duration, updatedAt: now,
            attempts: 0, positionSent: nil
        ))
        file = state
        persist()
    }

    // MARK: Flushing

    /// Sends queued offline progress. A call while one is sending asks for
    /// one more pass afterwards.
    func flushProgressQueue() async {
        guard !file.progressQueue.isEmpty else { return }
        guard !flushingProgress else {
            flushProgressAgain = true
            return
        }
        flushingProgress = true
        flushProgressAgain = false
        let generation = self.generation
        await sendProgressQueue(generation: generation)
        flushingProgress = false
        if generation != self.generation, currentScope != nil {
            // The scope switched: flush the new one once it's loaded.
            flushProgressAgain = false
            Task { if await self.activateScopeIfNeeded() { await self.flushProgressQueue() } }
        } else if flushProgressAgain {
            flushProgressAgain = false
            Task { await self.flushProgressQueue() }
        }
    }

    private func sendProgressQueue(generation: UInt64) async {
        let batch = file.progressQueue
        let completed = Set(batch.lazy.filter { self.file.localProgress[$0.mediaItemId]?.completed == true }.map(\.mediaItemId))
        // Emby and Jellyfin turn each into a stop report, so an acknowledged
        // position is never sent again.
        let items = batch.filter { $0.positionSent != true }.map {
            SyncProgressItem(mediaItemId: $0.mediaItemId, position: $0.position, duration: $0.duration,
                             forceOverwrite: false, updatedAt: $0.updatedAt)
        }
        let results: [SyncProgressResult]
        do {
            results = try await VividAPI.shared.syncProgressBatch(items: items)
        } catch {
            return
        }
        guard generation == self.generation else { return }
        var resultsById: [String: SyncProgressResult] = [:]
        for result in results where resultsById[result.mediaItemId] == nil { resultsById[result.mediaItemId] = result }
        let acknowledged = Set(batch.filter { $0.positionSent == true || resultsById[$0.mediaItemId]?.isOK == true }.map(\.mediaItemId))
        // Position sync alone can't say the credits were reached.
        var watchedFailed: Set<String> = []
        for id in completed.sorted() where acknowledged.contains(id) {
            do {
                try await VividAPI.shared.setWatched(contentId: id, played: true)
            } catch {
                watchedFailed.insert(id)
            }
        }
        guard generation == self.generation else { return }
        file.progressQueue = DownloadEngine.ProgressRules.queueAfterFlush(
            file.progressQueue, sent: batch, results: resultsById, watchedFailed: watchedFailed,
            completed: completed, retryLimit: 4
        )
        persist()
    }

    // MARK: Pulling

    /// Brings watch progress from the server into the local entries. Errors
    /// end it quietly; it runs again on the next foreground.
    func pullProgress() async {
        guard !pullingProgress else { return }
        pullingProgress = true
        let generation = self.generation
        do {
            try await performPull()
        } catch {
            DownloadEngine.log.debug("Downloads progress pull ended: \(error.localizedDescription, privacy: .private)")
        }
        pullingProgress = false
        if generation != self.generation, currentScope != nil {
            Task { if await self.activateScopeIfNeeded() { await self.pullProgress() } }
        }
    }

    private func performPull() async throws {
        let identity = await TokenStore.shared.captureOrdinaryRequestAuth()
        if let identity {
            let provider = MediaServerProvider.forServerID(identity.account.serverId)
            if provider == .silo {
                let server = identity.account.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let url = URL(string: server + "/api/v1/progress"),
                   try await SiloAPIDiscovery.shared.usesV2(for: url, session: .shared) {
                    try await pullSiloSnapshot(identity)
                    return
                }
            } else if DownloadEngine.ProgressRules.readsCurrentState(provider) {
                try await pullCurrentState()
                return
            }
        }
        try await pullChangeFeed()
    }

    /// Silo's v1 change feed since the stored cursor.
    private func pullChangeFeed() async throws {
        let generation = self.generation
        let response = try await VividAPI.shared.pullProgressDeltas(since: file.progressCursor)
        guard generation == self.generation else { return }
        var state = file
        for item in response.progress {
            let serverTime = item.updatedAt ?? Date()
            var entry = state.localProgress[item.mediaItemId] ?? SavedProgress(
                position: item.positionSeconds, duration: item.durationSeconds, completed: item.completed,
                updatedAt: serverTime
            )
            guard serverTime >= entry.updatedAt else { continue }
            entry.position = item.positionSeconds
            if item.durationSeconds > 0 { entry.duration = item.durationSeconds }
            entry.completed = entry.completed || item.completed
            entry.updatedAt = serverTime
            state.localProgress[item.mediaItemId] = entry
        }
        if let next = response.nextCursor, !next.isEmpty { state.progressCursor = next }
        file = state
        persist()
    }

    /// Emby and Jellyfin: the current state of every downloaded item.
    private func pullCurrentState() async throws {
        let ids = Set(file.records.values.map(\.leafMediaItemId)).sorted()
        guard !ids.isEmpty else { return }
        let generation = self.generation
        let items = try await VividAPI.shared.currentProgress(mediaItemIds: ids)
        guard generation == self.generation else { return }
        let updates = DownloadEngine.ProgressRules.currentStateUpdates(
            items, local: file.localProgress, pending: Set(file.progressQueue.map(\.mediaItemId)), now: Date()
        )
        guard !updates.isEmpty else { return }
        var state = file
        state.localProgress.merge(updates) { _, server in server }
        file = state
        persist()
    }

    /// The Downloads page's refresh of watched state (Emby and Jellyfin).
    func refreshWatchedState() async {
        guard downloadsEnabled, let scope = currentScope,
              DownloadEngine.ProgressRules.readsCurrentState(MediaServerProvider.forServerID(scope.serverId)) else { return }
        await pullProgress()
    }

    // MARK: Silo progress snapshot

    /// Replaces local progress with Silo's full snapshot, page by page. The
    /// stage is saved as it grows, so an interrupted pull resumes.
    private func pullSiloSnapshot(_ identity: CapturedOrdinaryRequestAuth) async throws {
        guard let scope = currentScope else { return }
        let generation = self.generation
        let http = HTTPClient.shared
        func stillCurrent() async -> Bool {
            guard generation == self.generation, identity.account.serverId == scope.serverId,
                  identity.profileId == scope.profileId else { return false }
            return await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: identity) != nil
        }
        let capabilitiesPath = "/api/v2/sync/progress/capabilities"

        let capabilities: DownloadEngine.SnapshotCapabilities = try await http.get(capabilitiesPath, expectedAuth: identity)
        guard await stillCurrent(), capabilities.state == "available", capabilities.allowed,
              capabilities.mode == "full_replace", !capabilities.incremental,
              let installationId = capabilities.installationId, let serverGeneration = capabilities.generation else { return }

        let user: AuthUser = try await http.get("/api/v1/auth/me", expectedAuth: identity)
        let accountId = String(user.id)
        guard await stillCurrent() else { throw HTTPError.requestIdentityChanged }

        var stage = file.progressBootstrap
        if let saved = stage, saved.installationId != installationId || saved.generation != serverGeneration
            || saved.accountId != accountId || saved.profileId != scope.profileId
            || Date().timeIntervalSince(saved.createdAt) > 900 {
            stage = nil
        }
        if stage == nil {
            stage = DownloadEngine.SnapshotStage(
                requestId: UUID().uuidString, createdAt: Date(), installationId: installationId, accountId: accountId,
                profileId: scope.profileId, generation: serverGeneration, page: nil, items: [:]
            )
        }
        file.progressBootstrap = stage
        // Saved before asking for anything, so a retry reuses the request id.
        try await checkedSave(file)
        guard await stillCurrent(), file.progressBootstrap != nil else { throw HTTPError.requestIdentityChanged }

        do {
            var seenCursors: Set<String> = []
            var pages = 0
            while true {
                guard var stage = file.progressBootstrap else { throw HTTPError.requestIdentityChanged }
                if stage.page?.complete == true { break }
                try Task.checkCancellation()
                pages += 1
                guard pages <= 2_000 else { throw HTTPError.invalidResponse }
                let page: DownloadEngine.SnapshotPage
                if let previous = stage.page {
                    guard previous.expiresAt > Date(), let cursor = previous.page.nextCursor, !cursor.isEmpty,
                          !seenCursors.contains(cursor) else { throw HTTPError.invalidResponse }
                    seenCursors.insert(cursor)
                    page = try await http.get(
                        "/api/v2/sync/progress/snapshots/\(previous.snapshotId)", query: ["cursor": cursor], expectedAuth: identity
                    )
                    guard page.snapshotId == previous.snapshotId, page.itemCount == previous.itemCount,
                          page.capturedAt == previous.capturedAt else { throw HTTPError.invalidResponse }
                } else {
                    page = try await http.post(
                        "/api/v2/sync/progress/snapshots",
                        body: DownloadEngine.SnapshotRequest(requestId: stage.requestId, limit: 200),
                        timeout: .extended, expectedAuth: identity
                    )
                }
                guard await stillCurrent(), page.installationId == stage.installationId,
                      page.generation == stage.generation, page.accountId == stage.accountId,
                      page.profileId == stage.profileId, page.mode == "full_replace", page.expiresAt > Date(),
                      page.itemCount <= 100_000, page.complete != page.page.hasMore else { throw HTTPError.invalidResponse }
                for item in page.items {
                    guard stage.items[item.mediaItemId] == nil else { throw HTTPError.invalidResponse }
                    stage.items[item.mediaItemId] = item
                }
                guard stage.items.count <= page.itemCount else { throw HTTPError.invalidResponse }
                stage.page = page
                file.progressBootstrap = stage
                try await checkedSave(file)
                guard await stillCurrent() else { throw HTTPError.requestIdentityChanged }
            }

            guard let stage = file.progressBootstrap, let last = stage.page, last.complete, !last.page.hasMore,
                  let token = last.completionToken, !token.isEmpty,
                  stage.items.count == last.itemCount else { throw HTTPError.invalidResponse }
            let again: DownloadEngine.SnapshotCapabilities = try await http.get(capabilitiesPath, expectedAuth: identity)
            guard await stillCurrent(), again.state == "available", again.allowed,
                  again.installationId == stage.installationId, again.generation == stage.generation else {
                throw HTTPError.requestIdentityChanged
            }
            var replacement = stage.items.mapValues { item in
                SavedProgress(position: item.positionSeconds, duration: item.durationSeconds, completed: item.completed,
                              updatedAt: item.updatedAt ?? last.capturedAt)
            }
            // Unsent local events stay authoritative until acknowledged.
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            guard last.expiresAt > Date() else { throw HTTPError.invalidResponse }
            var copy = file
            copy.localProgress = replacement
            copy.progressCursor = nil
            copy.progressBootstrap = nil
            try await checkedSave(copy)
            guard await stillCurrent() else { throw HTTPError.requestIdentityChanged }
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            var state = file
            state.localProgress = replacement
            state.progressCursor = nil
            state.progressBootstrap = nil
            file = state
            persist()
        } catch {
            if let status = (error as? HTTPError)?.statusCode, [404, 409, 413].contains(status), await stillCurrent() {
                file.progressBootstrap = nil
                try? await checkedSave(file)
            }
            throw error
        }
    }
}

extension DownloadEngine {
    struct SnapshotCapabilities: Decodable, Sendable {
        let state: String
        let allowed: Bool
        let mode: String
        let incremental: Bool
        let installationId: String?
        let generation: SnapshotGeneration?
    }

    struct SnapshotRequest: Encodable, Sendable {
        let requestId: String
        let limit: Int
    }

    /// Pure rules for offline progress, kept apart so they can be checked
    /// without a server.
    enum ProgressRules {
        /// Emby and Jellyfin read the current state of downloaded items; Silo
        /// keeps its change feed or snapshot.
        static func readsCurrentState(_ provider: MediaServerProvider) -> Bool {
            provider == .emby || provider == .jellyfin
        }

        /// The local entries the server's current progress replaces. Items
        /// with an unsent local event, items never started anywhere and
        /// items that match are left alone; watching can be undone.
        static func currentStateUpdates(_ items: [ProgressPullItem], local: [String: SavedProgress],
                                        pending: Set<String>, now: Date) -> [String: SavedProgress] {
            var updates: [String: SavedProgress] = [:]
            for item in items {
                guard !pending.contains(item.mediaItemId) else { continue }
                let existing = local[item.mediaItemId]
                if existing == nil, !item.completed, item.positionSeconds <= 0 { continue }
                let duration = item.durationSeconds > 0 ? item.durationSeconds : (existing?.duration ?? 0)
                if let existing, existing.position == item.positionSeconds, existing.duration == duration,
                   existing.completed == item.completed { continue }
                updates[item.mediaItemId] = SavedProgress(
                    position: item.positionSeconds, duration: duration, completed: item.completed, updatedAt: now
                )
            }
            return updates
        }

        /// The queue after a flush. Entries match by id, so one added while
        /// the request was out stays as it is. An acknowledged entry leaves
        /// unless marking it watched failed; a rejected one gets another try
        /// until the limit, except a completed item, which is never dropped.
        static func queueAfterFlush(_ queue: [QueuedProgress], sent: [QueuedProgress],
                                    results: [String: SyncProgressResult], watchedFailed: Set<String>,
                                    completed: Set<String>, retryLimit: Int) -> [QueuedProgress] {
            let sentIds = Set(sent.map(\.id))
            return queue.compactMap { entry in
                guard sentIds.contains(entry.id) else { return entry }
                var entry = entry
                let result = results[entry.mediaItemId]
                if entry.positionSent == true || result?.isOK == true {
                    guard watchedFailed.contains(entry.mediaItemId) else { return nil }
                    entry.positionSent = true
                    entry.attempts += 1
                    return entry
                }
                guard result != nil else { return entry }
                if entry.attempts >= retryLimit, !completed.contains(entry.mediaItemId) { return nil }
                entry.attempts += 1
                return entry
            }
        }
    }
}
