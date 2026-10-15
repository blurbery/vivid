import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Offline progress

    /// Record a watch-progress event from offline playback: update the
    /// local resume point and queue it for the next reconnect flush.
    func recordOfflineProgress(mediaItemId: String, position: Double, duration: Double, completed: Bool) {
        guard !mediaItemId.isEmpty, position.isFinite, position >= 0 else { return }
        let now = Date()
        var entry = file.localProgress[mediaItemId]
            ?? LocalProgressEntry(position: 0, duration: duration, completed: false, updatedAt: now)
        entry.position = position
        if duration.isFinite, duration > 0 { entry.duration = duration }
        entry.completed = entry.completed || completed
        entry.updatedAt = now
        file.localProgress[mediaItemId] = entry

        // Collapse to the latest event per item so an offline session that
        // ticks every few seconds doesn't grow an unbounded flush queue.
        file.progressQueue.removeAll { $0.mediaItemId == mediaItemId }
        file.progressQueue.append(QueuedProgress(
            id: UUID(),
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            updatedAt: now,
            attempts: 0
        ))
        persist()
    }

    func flushProgressQueue() async {
        guard !file.progressQueue.isEmpty else { return }
        guard !progressFlushInFlight else {
            progressFlushRequested = true
            return
        }
        progressFlushInFlight = true
        progressFlushRequested = false
        let scopeGeneration = registrationScopeGeneration
        defer {
            progressFlushInFlight = false
            if scopeGeneration != registrationScopeGeneration, !scopeServerId.isEmpty {
                // A flush for a newly active scope returns early while this
                // one holds the flag, so run it now rather than at the next
                // foreground.
                progressFlushRequested = false
                Task {
                    guard await self.activateScopeIfNeeded() else { return }
                    await self.flushProgressQueue()
                }
            } else if progressFlushRequested {
                // Another trigger asked for a flush while this one was
                // sending. Run it once now, from the queue as this flush left
                // it, so nothing acknowledged here is sent again.
                progressFlushRequested = false
                Task { await self.flushProgressQueue() }
            }
        }
        let batch = file.progressQueue
        let completedIds = Set(batch.filter { file.localProgress[$0.mediaItemId]?.completed == true }.map { $0.mediaItemId })
        // A position the server already acknowledged isn't sent again. On
        // Emby and Jellyfin it is a playback stop report, and each one is
        // another "finished playing" event for the server and its plugins.
        let items = batch.filter { $0.positionSent != true }.map {
            SyncProgressItem(
                mediaItemId: $0.mediaItemId,
                position: $0.position,
                duration: $0.duration,
                forceOverwrite: false,
                updatedAt: $0.updatedAt
            )
        }
        do {
            let results = try await VividAPI.shared.syncProgressBatch(items: items)
            guard scopeGeneration == registrationScopeGeneration else { return }
            let okItemIds = Set(results.filter { $0.isOK }.map { $0.mediaItemId })
                .union(batch.filter { $0.positionSent == true }.map { $0.mediaItemId })
            // Position sync alone cannot express credits-based completion.
            // Keep the queued event if the separate watched write fails.
            var watchedFailures: Set<String> = []
            for contentId in completedIds.intersection(okItemIds) {
                do { try await VividAPI.shared.setWatched(contentId: contentId, played: true) }
                catch { watchedFailures.insert(contentId) }
            }
            guard scopeGeneration == registrationScopeGeneration else { return }
            file.progressQueue = Self.progressQueue(file.progressQueue, afterSending: batch, results: results,
                                                    watchedFailures: watchedFailures, completed: completedIds,
                                                    maxRetries: Self.maxRetries)
            persist()
        } catch {
            // Keep the queue for the next reconnect.
        }
    }

    /// The queue after a flush. An acknowledged entry leaves it, unless it is
    /// a completed item whose watched write failed: that stays, marked as
    /// sent, so the next flush retries only the watched write. An entry the
    /// server rejected uses up a retry (completed items are never dropped),
    /// while one it didn't answer, because the batch failed part-way, keeps
    /// its budget. Entries are matched by identity, not media item, so one
    /// appended while the request was out, with a newer position the server
    /// never saw, is kept as it is.
    nonisolated static func progressQueue(_ queue: [QueuedProgress], afterSending batch: [QueuedProgress],
                                          results: [SyncProgressResult], watchedFailures: Set<String>,
                                          completed: Set<String>, maxRetries: Int) -> [QueuedProgress] {
        let sentEntryIds = Set(batch.map(\.id))
        var accepted: [String: Bool] = [:]
        for result in results { accepted[result.mediaItemId] = result.isOK }
        return queue.compactMap { entry in
            guard sentEntryIds.contains(entry.id) else { return entry }
            var entry = entry
            if entry.positionSent == true || accepted[entry.mediaItemId] == true {
                guard watchedFailures.contains(entry.mediaItemId) else { return nil }
                entry.positionSent = true
            } else {
                guard accepted[entry.mediaItemId] != nil else { return entry }
                if entry.attempts >= maxRetries && !completed.contains(entry.mediaItemId) { return nil }
            }
            entry.attempts += 1
            return entry
        }
    }

    func pullProgressDeltas() async {
        guard !progressBootstrapInFlight else { return }
        progressBootstrapInFlight = true
        let startGeneration = registrationScopeGeneration
        defer {
            progressBootstrapInFlight = false
            // A pull for a newly active scope returns early while this one
            // holds the flag, so run it now rather than at the next foreground.
            if startGeneration != registrationScopeGeneration, !scopeServerId.isEmpty {
                Task {
                    // Let the new scope's registry finish loading first, so
                    // the pull reads and saves that account's file.
                    guard await self.activateScopeIfNeeded() else { return }
                    await self.pullProgressDeltas()
                }
            }
        }
        do {
            if let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
               MediaServerProvider.forServerID(auth.account.serverId) == .silo,
               let url = URL(string: auth.account.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/progress"),
               try await SiloAPIDiscovery.shared.usesV2(for: url, session: .shared) {
                try await replaceSiloProgress(auth: auth)
                return
            }
            if let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
               Self.readsCurrentProgress(MediaServerProvider.forServerID(auth.account.serverId)) {
                try await pullDownloadedItemProgress()
                return
            }

            // A server or profile switch while this request is out must not
            // merge the old account's progress into the new scope's file.
            let scopeGeneration = registrationScopeGeneration
            let response = try await VividAPI.shared.pullProgressDeltas(since: file.progressCursor)
            guard scopeGeneration == registrationScopeGeneration else { return }
            for item in response.progress {
                let serverTime = item.updatedAt ?? Date()
                var entry = file.localProgress[item.mediaItemId]
                    ?? LocalProgressEntry(
                        position: item.positionSeconds,
                        duration: item.durationSeconds,
                        completed: item.completed,
                        updatedAt: serverTime
                    )
                if serverTime >= entry.updatedAt {
                    entry.position = item.positionSeconds
                    if item.durationSeconds > 0 { entry.duration = item.durationSeconds }
                    entry.completed = entry.completed || item.completed
                    entry.updatedAt = serverTime
                    file.localProgress[item.mediaItemId] = entry
                }
            }
            if let cursor = response.nextCursor, !cursor.isEmpty {
                file.progressCursor = cursor
            }
            persist()
        } catch {
            // Non-fatal; retry next foreground.
        }
    }

    /// Emby and Jellyfin have no progress change feed, so their downloads
    /// read each item's current state instead.
    nonisolated static func readsCurrentProgress(_ provider: MediaServerProvider) -> Bool {
        provider == .emby || provider == .jellyfin
    }

    /// Picks up items watched on an Emby or Jellyfin server since the last
    /// foreground, so the Downloads tab is current when it opens.
    func refreshDownloadedProgress() async {
        guard downloadsEnabled, Self.readsCurrentProgress(MediaServerProvider.forServerID(scopeServerId)) else { return }
        await pullProgressDeltas()
    }

    /// Reads the server's watch state for every downloaded item, so watching
    /// online (in Vivid or another app) marks the download watched too.
    private func pullDownloadedItemProgress() async throws {
        let ids = Set(file.records.values.map(\.leafMediaItemId)).sorted()
        guard !ids.isEmpty else { return }
        let scopeGeneration = registrationScopeGeneration
        let progress = try await VividAPI.shared.currentProgress(mediaItemIds: ids)
        guard scopeGeneration == registrationScopeGeneration else { return }
        let updates = Self.currentProgressUpdates(progress, local: file.localProgress,
                                                  pending: Set(file.progressQueue.map(\.mediaItemId)), now: Date())
        guard !updates.isEmpty else { return }
        file.localProgress.merge(updates) { _, server in server }
        persist()
    }

    /// The server's state replaces each returned item's entry, including
    /// marking it unwatched, unless a local event for it is still waiting to
    /// be sent. Items the server didn't return keep their entry, and items
    /// never started anywhere get none.
    nonisolated static func currentProgressUpdates(_ progress: [ProgressPullItem], local: [String: LocalProgressEntry],
                                                   pending: Set<String>, now: Date) -> [String: LocalProgressEntry] {
        var updates: [String: LocalProgressEntry] = [:]
        for item in progress where !pending.contains(item.mediaItemId) {
            let existing = local[item.mediaItemId]
            guard existing != nil || item.completed || item.positionSeconds > 0 else { continue }
            let duration = item.durationSeconds > 0 ? item.durationSeconds : existing?.duration ?? 0
            guard existing?.position != item.positionSeconds || existing?.duration != duration
                    || existing?.completed != item.completed else { continue }
            updates[item.mediaItemId] = LocalProgressEntry(position: item.positionSeconds, duration: duration,
                                                           completed: item.completed, updatedAt: now)
        }
        return updates
    }

    private func persistBootstrap(_ stagedFile: DownloadStoreFile? = nil) async throws {
        let snapshot = stagedFile ?? file
        let serverId = scopeServerId
        let profileId = scopeProfileId
        let previous = saveChain
        let write = Task { @MainActor in
            await previous?.value
            try await DownloadStore.shared.saveChecked(snapshot, serverId: serverId, profileId: profileId)
        }
        saveChain = Task { _ = try? await write.value }
        try await write.value
    }

    private func replaceSiloProgress(auth: CapturedOrdinaryRequestAuth) async throws {
        let scopeGeneration = registrationScopeGeneration
        func scopeIsCurrent() async -> Bool {
            guard scopeGeneration == registrationScopeGeneration,
                  auth.account.serverId == scopeServerId, auth.profileId == scopeProfileId else { return false }
            return await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
        }
        let http = HTTPClient.shared
        let capability: SiloProgressBootstrapCapability = try await http.get("/api/v2/sync/progress/capabilities", expectedAuth: auth)
        guard await scopeIsCurrent(), capability.state == "available", capability.allowed,
              capability.mode == "full_replace", !capability.incremental,
              let installation = capability.installationId, let generation = capability.generation else { return }
        let account: AuthUser = try await http.get("/api/v1/auth/me", expectedAuth: auth)
        guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
        if let stage = file.progressBootstrap,
           stage.installationId != installation || stage.generation != generation || stage.accountId != String(account.id) || stage.profileId != auth.profileId || Date().timeIntervalSince(stage.createdAt) > 900 {
            file.progressBootstrap = nil
        }
        if file.progressBootstrap == nil {
            file.progressBootstrap = SiloProgressBootstrapStage(requestId: UUID().uuidString, createdAt: Date(),
                installationId: installation, accountId: String(account.id), profileId: scopeProfileId, generation: generation)
        }
        try await persistBootstrap()
        guard await scopeIsCurrent(), var stage = file.progressBootstrap else { throw HTTPError.requestIdentityChanged }
        do {
            var seenCursors = Set<String>()
            var pages = 0
            while stage.page?.complete != true {
                try Task.checkCancellation()
                guard pages < 2000 else { throw HTTPError.invalidResponse }
                pages += 1
                let page: SiloProgressBootstrapPage
                if let previous = stage.page {
                    guard previous.expiresAt > Date(), let cursor = previous.page.nextCursor,
                          !cursor.isEmpty, seenCursors.insert(cursor).inserted else { throw HTTPError.invalidResponse }
                    page = try await http.get("/api/v2/sync/progress/snapshots/\(previous.snapshotId)", query: ["cursor": cursor], expectedAuth: auth)
                    guard page.snapshotId == previous.snapshotId, page.itemCount == previous.itemCount,
                          page.capturedAt == previous.capturedAt else { throw HTTPError.invalidResponse }
                } else {
                    struct Admission: Encodable { let requestId: String; let limit: Int }
                    page = try await http.post("/api/v2/sync/progress/snapshots", body: Admission(requestId: stage.requestId, limit: 200), timeout: .extended, expectedAuth: auth)
                }
                guard await scopeIsCurrent(), page.installationId == installation, page.generation == generation,
                      page.accountId == stage.accountId, page.profileId == stage.profileId,
                      page.mode == "full_replace", page.expiresAt > Date(), page.itemCount <= 100_000,
                      page.complete != page.page.hasMore else { throw HTTPError.invalidResponse }
                for item in page.items {
                    guard stage.items[item.mediaItemId] == nil else { throw HTTPError.invalidResponse }
                    stage.items[item.mediaItemId] = item
                }
                guard stage.items.count <= page.itemCount else { throw HTTPError.invalidResponse }
                stage.page = page
                file.progressBootstrap = stage
                try await persistBootstrap()
                guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
            }
            guard let terminal = stage.page, terminal.complete, !terminal.page.hasMore,
                  terminal.completionToken?.isEmpty == false, stage.items.count == terminal.itemCount else { throw HTTPError.invalidResponse }
            let current: SiloProgressBootstrapCapability = try await http.get("/api/v2/sync/progress/capabilities", expectedAuth: auth)
            guard await scopeIsCurrent(), current.state == "available", current.allowed,
                  current.installationId == installation, current.generation == generation else { throw HTTPError.requestIdentityChanged }
            var replacement = stage.items.mapValues { item in
                LocalProgressEntry(position: item.positionSeconds, duration: item.durationSeconds,
                    completed: item.completed, updatedAt: item.updatedAt ?? terminal.capturedAt)
            }
            // Unsynchronised local events remain authoritative until their
            // exact queue entries are acknowledged. Downloads are untouched.
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            guard terminal.expiresAt > Date() else { throw HTTPError.invalidResponse }
            var committed = file
            committed.localProgress = replacement
            committed.progressCursor = nil
            committed.progressBootstrap = nil
            try await persistBootstrap(committed)
            guard await scopeIsCurrent() else { throw HTTPError.requestIdentityChanged }
            for queued in file.progressQueue {
                if let local = file.localProgress[queued.mediaItemId] { replacement[queued.mediaItemId] = local }
            }
            file.localProgress = replacement
            file.progressCursor = nil
            file.progressBootstrap = nil
            persist()
        } catch {
            if await scopeIsCurrent(), let error = error as? HTTPError, [404, 409, 413].contains(error.statusCode ?? 0) {
                file.progressBootstrap = nil
                try await persistBootstrap()
            }
            throw error
        }
    }
}
