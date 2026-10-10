import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

extension DownloadManager {
    // MARK: - Polling (preparing → ready)

    func ensurePolling() {
        guard pollTask == nil else { return }
        guard file.records.values.contains(where: { $0.localStatus == .preparing }) else { return }
        pollTask = Task { @MainActor in
            defer { self.pollTask = nil }
            while !Task.isCancelled {
                guard self.file.records.values.contains(where: { $0.localStatus == .preparing }) else { break }
                await self.prefetchPreparingDetails()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await self.reconcileWithServer(triggerPipeline: true)
            }
        }
    }

    /// While Silo prepares a download, fetch its artwork so the row shows
    /// the poster rather than a blur, and for a smaller quality estimate the
    /// prepared file's size from the runtime: until the file is ready the
    /// server reports the source file's size. Once per download; the normal
    /// pipeline fetches the artwork again when the file is ready.
    private func prefetchPreparingDetails() async {
        guard MediaServerProvider.forServerID(scopeServerId) == .silo else { return }
        let pending = file.records.values.filter {
            $0.localStatus == .preparing && !preparingDetailsFetched.contains($0.id)
                && preparingDetailsAttempts[$0.id, default: 0] < 3
        }
        guard !pending.isEmpty, let auth = await scopeAuth() else { return }
        let generation = registrationScopeGeneration
        for record in pending {
            guard pipelineIsCurrent(recordId: record.id, generation: generation) else { continue }
            // A failed request is tried again on a later poll, up to three times.
            guard let manifest = try? await VividAPI.shared.fetchManifest(downloadId: record.id, auth: auth) else {
                preparingDetailsAttempts[record.id, default: 0] += 1
                continue
            }
            guard pipelineIsCurrent(recordId: record.id, generation: generation),
                  var current = file.records[record.id], current.localStatus == .preparing else { continue }
            preparingDetailsFetched.insert(record.id)
            if current.fileSize <= 0,
               let format = DownloadFormat(rawValue: current.format), format != .original,
               let estimate = StreamedTranscodeDownload.estimatedBytes(format: format, durationSeconds: manifest.durationSeconds) {
                current.fileSize = estimate
                file.records[record.id] = current
                persist()
            }
            if current.posterFilename == nil {
                await fetchArtwork(manifest, recordId: record.id, generation: generation, auth: auth)
            }
        }
    }

    // MARK: - Reconcile with server

    func reconcileWithServer(triggerPipeline: Bool) async {
        guard !scopeServerId.isEmpty, downloadsEnabled else { return }
        let generation = registrationScopeGeneration
        // Pin the list to this scope's account: during a switch the active
        // sign-in can already be the next server's, whose rows would mark
        // this account's downloads as removed.
        guard let auth = await scopeAuth(), generation == registrationScopeGeneration else { return }
        flushPendingServerDeletes()
        let rows: [ServerDownloadRow]
        do {
            rows = try await VividAPI.shared.listDownloads(auth: auth)
        } catch {
            return
        }
        guard generation == registrationScopeGeneration else { return }
        // Read after the list returns: a delete made while it was in flight
        // must still keep its row from being picked up again.
        let pendingDeletes = Set(file.pendingServerDeletes ?? []).union(deletedDownloadIds)
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var unreportedCompletions: [DownloadRecord] = []

        for (id, original) in file.records {
            if let row = byId[id] {
                var record = mergeExistingRecord(original, with: row)
                // A transfer that finished while another account was active
                // (or while a status update failed) still reads as pending on
                // the server, where it counts against the download limit.
                if record.localStatus == .completed, row.status == "ready" || row.status == "downloading" {
                    unreportedCompletions.append(record)
                }
                switch row.status {
                case "ready":
                    if record.localStatus == .preparing || record.localStatus == .registering {
                        record.localStatus = .queued
                    }
                case "revoked":
                    if record.localStatus == .completed {
                        record.localStatus = .revoked
                    } else if record.localStatus.isActive {
                        record.localStatus = .revoked
                    }
                case "failed":
                    if record.localStatus != .completed {
                        // The merge above may already have reset a newer
                        // revision to failed, so compare the earlier status.
                        if original.localStatus != .failed {
                            reportFailure(.conversion, status: nil, urlErrorCode: nil, error: "server_failed", record: record)
                        }
                        record.localStatus = .failed
                        record.lastError = "server_failed"
                    }
                default:
                    break
                }
                file.records[id] = record
            } else if original.localStatus.isActive {
                var record = original
                record.localStatus = .failed
                record.lastError = "removed_on_server"
                file.records[id] = record
            }
        }

        // Pick up rows registered out-of-band (e.g. subscription sync).
        for row in rows where file.records[row.id] == nil && !pendingDeletes.contains(row.id) {
            file.records[row.id] = makeRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
        }
        persist()
        if !unreportedCompletions.isEmpty {
            Task {
                for record in unreportedCompletions {
                    try? await VividAPI.shared.patchDownloadStatus(id: record.id, status: "completed", revision: record.revision,
                                                                   updatedAt: record.downloadedAt ?? Date(), auth: auth)
                }
            }
        }

        await reconnectActiveTasks()
        if triggerPipeline {
            processQueue()
            ensurePolling()
        }
    }

    /// After a relaunch the background session may have lost in-flight
    /// tasks (or finished them while we were dead). Re-queue records whose
    /// task is no longer live.
    private func reconnectActiveTasks() async {
        let active = await sessionDelegate.activeTaskIdentifiers()
        for (id, record) in file.records {
            var record = record
            // Task identifiers are only unique within one URLSession
            // instance — a recreated session hands the same small integers
            // to new tasks, so a persisted id with no live task must be
            // dropped before it can match (and misroute) another record's
            // transfer. Pause round-trips keep theirs: the cancelled task
            // may still deliver a final event that must find this record.
            if let taskId = record.taskIdentifier,
               !active.contains(taskId),
               !pendingPauseIds.contains(id) {
                record.taskIdentifier = nil
                file.records[id] = record
            }
            // Records with a live back-off timer are owned by the retry;
            // re-queuing them here would double-start the transfer when it
            // fires.
            guard retryTasks[id] == nil else { continue }
            guard record.localStatus == .downloading || record.localStatus == .fetchingAssets else {
                continue
            }
            // `.fetchingAssets` records were mid-pipeline in a detached Task
            // that did not survive the relaunch; re-queue them too so they
            // aren't wedged (and don't keep occupying a concurrency slot
            // forever).
            if record.localStatus == .downloading,
               let taskId = record.taskIdentifier, active.contains(taskId) {
                continue
            }
            // A foreground reconcile can find a preparation still running in
            // this process. It owns the record, and re-queuing it would make
            // `processQueue()` cancel and restart that work.
            if record.localStatus == .fetchingAssets, pipelineTasks[id] != nil {
                continue
            }
            setLocalStatus(.queued, id: id)
        }
    }
}
