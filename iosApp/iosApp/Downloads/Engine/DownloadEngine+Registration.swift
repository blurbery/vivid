import Foundation

extension DownloadManager {
    /// What a list of episodes added, skipped, sent to wait or couldn't add.
    struct EpisodeRegistrationResult {
        var added = 0
        var skipped = 0
        var failures: [Error] = []
        var stoppedBySwitch = false
        var waiting = 0

        init() {}

        /// A sentence for the person when something wasn't added. Episodes
        /// left waiting aren't a problem.
        var problem: String? {
            let addedSentence = String(localized: "\(added) episodes were added.")
            if stoppedBySwitch {
                return String(localized: "The server or profile changed, so the rest weren't added.") + " " + addedSentence
            }
            if let first = failures.first {
                let reason = first.localizedDescription
                return String(localized: "\(failures.count) episodes couldn't be added: \(reason)",
                              comment: "The second part is the reason, e.g. The server didn't create a download.")
                    + " " + addedSentence
            }
            if added == 0, waiting == 0, skipped > 0 {
                return String(localized: "Nothing new to add. These episodes are already downloaded, on their way, or don't have a file yet.")
            }
            return nil
        }
    }

    /// The size a server row gives a record, or nil to keep the record's own.
    nonisolated static func serverFileSize(_ row: ServerDownloadRow, provider: MediaServerProvider, currentSize: Int64,
                                           bytesDownloaded: Int64, localStatus: LocalDownloadStatus) -> Int64? {
        guard let size = row.fileSize, size > 0 else { return nil }
        // While Silo prepares a smaller file it reports the source's size.
        if provider == .silo, row.status == "preparing", row.quality != DownloadFormat.original.rawValue { return nil }
        if currentSize <= 0 { return size }
        guard provider == .silo, bytesDownloaded <= 0 else { return nil }
        switch localStatus {
        case .registering, .preparing, .queued: return size
        default: return nil
        }
    }

    // MARK: Entry points

    func downloadEpisode(seriesId: String, episodeId: String, displayTitle: String?, displaySubtitle: String?,
                         seriesTitle: String? = nil, posterThumbhash: String?, preferredPosterPath: String? = nil,
                         fileId: Int? = nil, quality: String? = nil, scope: DownloadScope? = nil) async throws {
        try await register(DownloadEngine.Registration(
            contentId: seriesId, episodeId: episodeId, batch: false, seasonNumber: nil, fileId: fileId, quality: quality,
            type: "episode", seriesId: seriesId, seriesTitle: seriesTitle, title: displayTitle,
            subtitle: displaySubtitle, posterThumbhash: posterThumbhash, posterPath: preferredPosterPath
        ), scope: scope)
    }

    func requestMovie(contentId: String, title: String?, year: Int?, posterThumbhash: String?, fileId: Int?,
                      quality: String?) async throws {
        try await register(DownloadEngine.Registration(
            contentId: contentId, episodeId: nil, batch: false, seasonNumber: nil, fileId: fileId, quality: quality,
            type: "movie", seriesId: nil, seriesTitle: nil, title: title, subtitle: year.map { String($0) },
            posterThumbhash: posterThumbhash, posterPath: nil
        ), scope: nil)
    }

    func requestSeason(_ seasonNumber: Int, seriesId: String, seriesTitle: String?, posterThumbhash: String?,
                       posterPath: String?, quality: String?) async throws {
        try await register(DownloadEngine.Registration(
            contentId: seriesId, episodeId: nil, batch: true, seasonNumber: seasonNumber, fileId: nil, quality: quality,
            type: nil, seriesId: seriesId, seriesTitle: seriesTitle, title: nil, subtitle: nil,
            posterThumbhash: posterThumbhash, posterPath: posterPath
        ), scope: nil)
    }

    func requestWholeSeries(seriesId: String, seriesTitle: String?, posterThumbhash: String?, posterPath: String?,
                            quality: String?) async throws {
        try await register(DownloadEngine.Registration(
            contentId: seriesId, episodeId: nil, batch: true, seasonNumber: nil, fileId: nil, quality: quality,
            type: nil, seriesId: seriesId, seriesTitle: seriesTitle, title: nil, subtitle: nil,
            posterThumbhash: posterThumbhash, posterPath: posterPath
        ), scope: nil)
    }

    /// Registers episodes one request at a time, in order. Episodes the
    /// account's limit turns away wait and are asked for again later.
    func requestEpisodes(_ episodes: [EpisodeListItem], seriesId: String, seriesTitle: String?, posterThumbhash: String?,
                         posterPath: String?, quality: String, version: DownloadVersionPreference?,
                         scope: DownloadScope?) async -> DownloadManager.EpisodeRegistrationResult {
        let callScope: DownloadScope
        if let scope { callScope = scope } else { callScope = await DownloadScope.current() }
        var result = EpisodeRegistrationResult()
        queueHold += 1
        defer {
            queueHold -= 1
            runQueue()
            startHeldRetries()
        }

        func isRegistrable(_ episode: EpisodeListItem) -> Bool {
            if let files = episode.files, files.isEmpty { return false }
            if let existing = record(forContentId: episode.contentId), existing.localStatus != .failed { return false }
            return registrationKeys[episode.contentId] == nil && !isWaiting(contentId: episode.contentId)
        }

        func needsEveryFile(_ episode: EpisodeListItem) -> Bool {
            version != nil && !episode.hasEveryFile && !EpisodeSourceFiles.listsEveryFile
        }

        func waitingItem(_ episode: EpisodeListItem, files: [EpisodeFile]) -> WaitingDownload {
            WaitingDownload(
                id: episode.contentId, seriesId: seriesId, title: Self.episodeTitle(episode),
                subtitle: Self.episodeTag(episode), seriesTitle: seriesTitle, seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber, posterThumbhash: posterThumbhash, preferredPosterPath: posterPath,
                fileId: version?.file(in: files)?.fileId, quality: quality, queuedAt: Date()
            )
        }

        for (offset, episode) in episodes.enumerated() {
            guard await DownloadScope.current() == callScope else {
                result.stoppedBySwitch = true
                break
            }
            guard isRegistrable(episode) else {
                result.skipped += 1
                continue
            }
            var files = episode.files ?? []
            if needsEveryFile(episode) {
                do {
                    files = try await VividAPI.shared.episodeFiles(contentId: episode.contentId)
                } catch {
                    guard await DownloadScope.current() == callScope else {
                        result.stoppedBySwitch = true
                        break
                    }
                    result.failures.append(error)
                    continue
                }
                guard await DownloadScope.current() == callScope else {
                    result.stoppedBySwitch = true
                    break
                }
            }
            do {
                try await downloadEpisode(
                    seriesId: seriesId, episodeId: episode.contentId, displayTitle: Self.episodeTitle(episode),
                    displaySubtitle: Self.episodeTag(episode), seriesTitle: seriesTitle, posterThumbhash: posterThumbhash,
                    preferredPosterPath: posterPath, fileId: version?.file(in: files)?.fileId, quality: quality,
                    scope: callScope
                )
                result.added += 1
            } catch DownloadError.registrationAlreadyInFlight {
                result.skipped += 1
            } catch DownloadError.scopeChangedDuringRegistration {
                result.stoppedBySwitch = true
                break
            } catch where DownloadError.isAccountLimit(error) {
                // This episode and the rest wait for the account to have room.
                var waiting = [waitingItem(episode, files: files)]
                for later in episodes.dropFirst(offset + 1) {
                    guard later.contentId == episode.contentId || isRegistrable(later) else { continue }
                    var laterFiles = later.files ?? []
                    if needsEveryFile(later),
                       let fetched = try? await VividAPI.shared.episodeFiles(contentId: later.contentId) {
                        laterFiles = fetched
                    }
                    waiting.append(waitingItem(later, files: laterFiles))
                }
                guard await DownloadScope.current() == callScope else {
                    result.stoppedBySwitch = true
                    break
                }
                addWaiting(waiting)
                result.waiting = waiting.count
                break
            } catch {
                guard await DownloadScope.current() == callScope else {
                    result.stoppedBySwitch = true
                    break
                }
                result.failures.append(error)
            }
        }
        return result
    }

    private static func episodeTitle(_ episode: EpisodeListItem) -> String {
        episode.title ?? String(localized: "Episode \(String(episode.episodeNumber))")
    }

    private static func episodeTag(_ episode: EpisodeListItem) -> String {
        "S\(episode.seasonNumber)\(DownloadEngine.dot)E\(episode.episodeNumber)"
    }

    // MARK: Registering

    private func register(_ ask: DownloadEngine.Registration, scope requested: DownloadScope?) async throws {
        let activeScope = await DownloadScope.current()
        if let requested, requested != activeScope { throw DownloadError.scopeChangedDuringRegistration }
        let target = requested ?? activeScope
        guard await prepareForDownload() else { throw DownloadError.unavailable }
        #if os(iOS)
        Task { await LocalNotificationAuthorization.requestIfNeeded() }
        #endif
        guard target == currentScope, let identity = await scopeIdentity() else {
            throw DownloadError.scopeChangedDuringRegistration
        }
        let key = ask.episodeId ?? ask.contentId
        guard registrationKeys[key] == nil else { throw DownloadError.registrationAlreadyInFlight }
        let token = UUID()
        registrationKeys[key] = token
        let generation = self.generation
        let scope = currentScope
        holdBackgroundTime()
        defer {
            if registrationKeys[key] == token { registrationKeys[key] = nil }
            releaseBackgroundTime()
        }

        let quality: String
        if ask.batch, capability?.bulkQuality != true {
            quality = DownloadFormat.original.rawValue
        } else if let wanted = ask.quality, capability?.qualityPresets.contains(wanted) == true {
            quality = wanted
        } else {
            quality = DownloadFormat.original.rawValue
        }
        let existing = file.records.values.first { $0.leafMediaItemId == key }
        let revision = existing?.revision ?? 0
        let body = CreateDownloadRequest(
            contentId: ask.contentId,
            episodeId: ask.episodeId,
            fileId: ask.fileId,
            quality: quality,
            series: ask.batch ? true : nil,
            seasonNumber: ask.seasonNumber,
            caps: DownloadCaps.current(),
            expectedRevision: ask.batch ? nil : revision,
            expectedDownloadId: !ask.batch && revision > 0 ? existing?.id : nil,
            batchId: ask.batch ? token.uuidString : nil
        )

        let rows: [ServerDownloadRow]
        do {
            rows = try await VividAPI.shared.createDownload(body, auth: identity)
            if rows.isEmpty { throw DownloadError.emptyRegistrationResponse }
        } catch {
            if self.generation == generation, currentScope == scope,
               let report = DownloadFailureReport(
                stage: .registration, error: error,
                server: MediaServerProvider.forServerID(identity.account.serverId).rawValue,
                quality: quality, batch: ask.batch, retries: 0
               ) {
                AppHealthMonitor.downloadFailed(report)
            }
            throw error
        }
        guard self.generation == generation, currentScope == scope else {
            throw DownloadError.scopeChangedDuringRegistration
        }

        var state = file
        let single = rows.count == 1
        for row in rows {
            if var record = state.records[row.id] {
                let wasDropped = record.localStatus == .failed || record.localStatus == .revoked
                merge(row, into: &record)
                if wasDropped {
                    record.localStatus = Self.initialStatus(row.status)
                    record.lastError = nil
                    record.retryCount = 0
                }
                state.records[row.id] = record
            } else {
                var record = newRecord(from: row, type: ask.type)
                if single {
                    record.title = ask.title
                    record.subtitle = ask.subtitle
                }
                if let seriesId = ask.seriesId { record.seriesId = seriesId }
                record.seriesTitle = ask.seriesTitle
                record.posterThumbhash = ask.posterThumbhash
                record.preferredPosterPath = ask.posterPath
                state.records[row.id] = record
            }
        }
        file = state
        persist()
        runQueue()
        startPreparationPoll()
    }

    // MARK: Rows

    /// The first local status of a record from its server row.
    static func initialStatus(_ serverStatus: String) -> LocalDownloadStatus {
        switch serverStatus {
        case "ready": .queued
        case "preparing": .preparing
        case "revoked": .revoked
        case "failed": .failed
        default: .registering
        }
    }

    /// A record for a row the app hasn't seen, with no display fields.
    func newRecord(from row: ServerDownloadRow, type: String?) -> DownloadRecord {
        let size = Self.serverFileSize(row, provider: scopeProvider, currentSize: 0, bytesDownloaded: 0,
                                       localStatus: .registering)
        return DownloadRecord(
            id: row.id, contentId: row.contentId, episodeId: row.episodeId, batchId: row.batchId,
            mediaFileId: row.mediaFileId, format: row.quality, effectiveQuality: row.effectiveQuality,
            deliveryFormat: row.deliveryFormat, targetBitrateKbps: row.targetBitrateKbps, revision: row.revision,
            serverStatus: row.status, localStatus: Self.initialStatus(row.status), fileSize: size ?? 0,
            bytesDownloaded: 0, type: type, preparation: row.status == "preparing" ? row.preparation : nil,
            registeredAt: row.createdAt ?? Date(), downloadedAt: row.completedAt
        )
    }

    /// Takes a server row into its record. A newer revision, or a different
    /// file or quality on a record without one, replaces the local files.
    func merge(_ row: ServerDownloadRow, into record: inout DownloadRecord) {
        let replaces: Bool
        if let rowRevision = row.revision, let recordRevision = record.revision {
            replaces = rowRevision > recordRevision
        } else if record.revision == nil {
            replaces = record.mediaFileId != row.mediaFileId || record.format != row.quality
        } else {
            replaces = false
        }
        if replaces {
            if let task = record.taskIdentifier {
                intentionalCancels.insert(task)
                Task { await transfers.cancel(task) }
            }
            deleteFolder(ofRecord: record.id)
            record.mediaFilename = nil
            record.manifestFilename = nil
            record.posterFilename = nil
            record.backdropFilename = nil
            record.logoFilename = nil
            record.subtitleFilenames = [:]
            record.subtitlesChecked = nil
            record.artworkChecked = nil
            record.resumeDataFilename = nil
            record.container = nil
            record.stableIdentity = nil
            record.bytesDownloaded = 0
            record.localStatus = Self.initialStatus(row.status)
            record.downloadedAt = nil
            record.lastError = nil
            record.retryCount = 0
            record.taskIdentifier = nil
        }
        record.contentId = row.contentId
        record.mediaFileId = row.mediaFileId
        record.format = row.quality
        record.effectiveQuality = row.effectiveQuality
        record.deliveryFormat = row.deliveryFormat
        record.targetBitrateKbps = row.targetBitrateKbps
        record.serverStatus = row.status
        if let revision = row.revision { record.revision = revision }
        record.preparation = row.status == "preparing" ? row.preparation : nil
        if let size = Self.serverFileSize(row, provider: scopeProvider, currentSize: record.fileSize,
                                          bytesDownloaded: record.bytesDownloaded, localStatus: record.localStatus) {
            record.fileSize = size
        }
        if let completedAt = row.completedAt { record.downloadedAt = completedAt }
    }
}

extension DownloadEngine {
    /// One registration request and the display fields new records get.
    struct Registration {
        let contentId: String
        let episodeId: String?
        let batch: Bool
        let seasonNumber: Int?
        let fileId: Int?
        let quality: String?
        let type: String?
        let seriesId: String?
        let seriesTitle: String?
        let title: String?
        let subtitle: String?
        let posterThumbhash: String?
        let posterPath: String?
    }
}
