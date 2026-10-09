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
        let scopeGeneration = registrationScopeGeneration
        let batch = file.progressQueue
        let completedIds = Set(batch.filter { file.localProgress[$0.mediaItemId]?.completed == true }.map { $0.mediaItemId })
        let items = batch.map {
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
            var okItemIds = Set(results.filter { $0.isOK }.map { $0.mediaItemId })
            // Position sync alone cannot express credits-based completion.
            // Keep the queued event if the separate watched write fails.
            for contentId in completedIds.intersection(okItemIds) {
                do { try await VividAPI.shared.setWatched(contentId: contentId, played: true) }
                catch { okItemIds.remove(contentId) }
            }
            // Match queue entries by identity, not media item — an entry
            // appended while the POST was in flight carries a newer position
            // the server never saw, so it must survive this batch with its
            // full retry budget.
            guard scopeGeneration == registrationScopeGeneration else { return }
            let sentEntryIds = Set(batch.map { $0.id })
            let okEntryIds = Set(batch.filter { okItemIds.contains($0.mediaItemId) }.map { $0.id })
            file.progressQueue.removeAll {
                okEntryIds.contains($0.id)
                    || ($0.attempts >= Self.maxRetries && sentEntryIds.contains($0.id)
                        && !completedIds.contains($0.mediaItemId))
            }
            for index in file.progressQueue.indices
            where sentEntryIds.contains(file.progressQueue[index].id) {
                file.progressQueue[index].attempts += 1
            }
            persist()
        } catch {
            // Keep the queue for the next reconnect.
        }
    }

    func pullProgressDeltas() async {
        guard !progressBootstrapInFlight else { return }
        progressBootstrapInFlight = true
        defer { progressBootstrapInFlight = false }
        do {
            if let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
               MediaServerProvider.forServerID(auth.account.serverId) == .silo,
               let url = URL(string: auth.account.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/progress"),
               try await SiloAPIDiscovery.shared.usesV2(for: url, session: .shared) {
                try await replaceSiloProgress(auth: auth)
                return
            }

            let response = try await VividAPI.shared.pullProgressDeltas(since: file.progressCursor)
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
