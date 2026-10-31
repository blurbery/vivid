import Foundation

extension DownloadManager {
    // MARK: The queue

    /// Starts queued downloads, oldest first, while preparation slots are free.
    func runQueue() {
        guard queueHold == 0 else { return }
        let preparing = file.records.values.filter { $0.localStatus == .fetchingAssets }.count
        var slots = handOffMode ? Int.max : max(0, 3 - preparing)
        guard slots > 0 else { return }
        let queued = file.records.values
            .filter { $0.localStatus == .queued }
            .sorted { $0.registeredAt != $1.registeredAt ? $0.registeredAt < $1.registeredAt : $0.id < $1.id }
        for record in queued {
            guard slots > 0 else { break }
            guard !exceedsSeriesCap(record) else { continue }
            slots -= 1
            startQueued(record.id)
        }
    }

    /// Picks a paused download up from its resume data, or prepares it.
    private func startQueued(_ id: String) {
        guard var record = file.records[id] else { return }
        if let resumeName = record.resumeDataFilename, let resumeURL = fileURL(named: resumeName, forRecord: id) {
            let data = try? Data(contentsOf: resumeURL)
            DownloadEngine.Disk.remove(resumeURL)
            record.resumeDataFilename = nil
            if let data, !data.isEmpty {
                // A resumed transfer reports nothing and holds no background time.
                record.taskIdentifier = transfers.resume(from: data, description: transferTag(forRecord: id))
                record.localStatus = .downloading
                file.records[id] = record
                persist()
                return
            }
            record.bytesDownloaded = 0
        }
        record.localStatus = .fetchingAssets
        file.records[id] = record
        persist()
        launchPreparation(id)
    }

    /// Replaces any running preparation of the record with a new one.
    func launchPreparation(_ id: String) {
        preparations[id]?.task.cancel()
        let generation = self.generation
        preparations[id] = DownloadEngine.Running { [weak self] running in
            await self?.prepare(id, generation: generation)
            if self?.preparations[id]?.id == running { self?.preparations[id] = nil }
        }
    }

    // MARK: Preparation

    /// Manifest, transfer, then artwork and subtitles. Every step stops
    /// quietly once the preparation is cancelled, the scope moves on or the
    /// record is gone.
    private func prepare(_ id: String, generation: UInt64) async {
        holdBackgroundTime()
        var holding = true
        defer { if holding { releaseBackgroundTime() } }
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == self.generation && file.records[id] != nil
        }

        let identity = await TokenStore.shared.captureOrdinaryRequestAuth()
        guard let identity, isCurrent(), let scope = currentScope,
              identity.account.serverId == scope.serverId, identity.profileId == scope.profileId else {
            // Give the slot back rather than holding it for ever.
            if file.records[id]?.localStatus == .fetchingAssets, generation == self.generation {
                file.records[id]?.localStatus = .queued
                persist()
            }
            return
        }

        let manifest: OfflineManifest
        do {
            manifest = try await VividAPI.shared.fetchManifest(downloadId: id, auth: identity)
            guard isCurrent() else { return }
            if let url = fileURL(named: DownloadEngine.Disk.manifestFileName, forRecord: id) {
                await DownloadEngine.Store.shared.writeManifest(manifest, to: url)
                guard isCurrent() else { return }
                file.records[id]?.manifestFilename = DownloadEngine.Disk.manifestFileName
            }
            if var record = file.records[id] {
                Self.copyDisplayFields(from: manifest, into: &record)
                file.records[id] = record
            }
            persist()

            guard let url = await VividAPI.shared.downloadFileURL(downloadId: id, auth: identity) else {
                throw DownloadError.fileURLUnavailable
            }
            let request = try await DownloadEngine.TransferRequest.make(
                url: url, allowsCellular: !DownloadSettings.shared.wifiOnlyTransfers, expected: identity
            )
            guard isCurrent(), var record = file.records[id] else { return }
            record.taskIdentifier = transfers.start(request, description: transferTag(forRecord: id))
            record.localStatus = .downloading
            file.records[id] = record
            persist()
            let revision = record.revision
            Task {
                try? await VividAPI.shared.patchDownloadStatus(
                    id: id, status: "downloading", revision: revision, updatedAt: Date(), auth: identity
                )
            }
        } catch {
            guard isCurrent() else { return }
            preparationFailed(id, error: error)
            return
        }

        // The slot is free once the transfer runs.
        holding = false
        releaseBackgroundTime()
        runQueue()
        await fetchArtwork(id, manifest: manifest, identity: identity, isCurrent: isCurrent)
        await fetchSubtitles(id, manifest: manifest, identity: identity, isCurrent: isCurrent)
    }

    /// Display fields from the manifest: kept when already set, or always
    /// taken, as each line says.
    static func copyDisplayFields(from manifest: OfflineManifest, into record: inout DownloadRecord) {
        record.title = record.title ?? manifest.title
        record.posterThumbhash = record.posterThumbhash ?? manifest.posterThumbhash
        record.seriesTitle = record.seriesTitle ?? manifest.seriesTitle
        record.seasonNumber = record.seasonNumber ?? manifest.seasonNumber
        record.episodeNumber = record.episodeNumber ?? manifest.episodeNumber
        record.type = manifest.type
        record.format = manifest.quality
        record.effectiveQuality = manifest.effectiveQuality
        record.deliveryFormat = manifest.deliveryFormat
        record.targetBitrateKbps = manifest.targetBitrateKbps
        record.mediaFileId = manifest.mediaFileId
        record.container = manifest.container
        record.stableIdentity = manifest.stableIdentity
        if let revision = manifest.revision { record.revision = revision }
        if let seriesId = manifest.seriesId { record.seriesId = seriesId }
        if record.subtitle == nil {
            if manifest.type == "episode" {
                let parts = [manifest.seasonNumber.map { "S\($0)" }, manifest.episodeNumber.map { "E\($0)" }]
                record.subtitle = parts.compactMap { $0 }.joined(separator: DownloadEngine.dot)
            } else {
                record.subtitle = manifest.year.map { String($0) }
            }
        }
        if record.fileSize <= 0, let size = manifest.fileSize { record.fileSize = size }
    }

    /// What happens to a preparation that threw.
    private func preparationFailed(_ id: String, error: Error) {
        guard var record = file.records[id] else { return }
        record.taskIdentifier = nil
        let status = (error as? HTTPError)?.statusCode
        switch status {
        case 409?:
            record.localStatus = .revoked
            record.serverStatus = "revoked"
            file.records[id] = record
        case let busy? where busy == 429 || (500...599).contains(busy):
            if record.retryCount < 4 {
                // Keeps its slot while it waits; the next save carries the count.
                record.retryCount += 1
                file.records[id] = record
                scheduleRetry(id, resumeData: nil, refreshesSignIn: false)
                return
            }
            record.localStatus = .failed
            record.lastError = "http_\(busy)"
            file.records[id] = record
            persist()
            reportFailure(of: record, stage: .preparing, error: error)
            runQueue()
            return
        case _ where record.retryCount < 4 && Self.isTemporaryFailure(error):
            // A dropped connection or a timed-out request is retried like a
            // busy server, and an expired sign-in is refreshed first, as a
            // transfer's is; after the last try it fails as below.
            record.retryCount += 1
            file.records[id] = record
            scheduleRetry(id, resumeData: nil, refreshesSignIn: status == 401)
            return
        default:
            record.localStatus = .failed
            switch status {
            case 404?: record.lastError = "not_found"
            case 403?: record.lastError = "forbidden"
            case let other?: record.lastError = "http_\(other)"
            case nil: record.lastError = error.localizedDescription
            }
            file.records[id] = record
            notifyFailure(of: record)
            reportFailure(of: record, stage: .preparing, error: error)
        }
        persist()
        runQueue()
    }

    /// Network drops, timeouts and an expired sign-in, as the kept failure
    /// report classifies them. A cancellation never counts.
    private static func isTemporaryFailure(_ error: Error) -> Bool {
        DownloadFailureReport.classify(error) != nil && DownloadFailureReport.isRetryable(error)
    }

    // MARK: Artwork and subtitles

    /// Poster, backdrop and logo, each from the first path that answers.
    func fetchArtwork(_ id: String, manifest: OfflineManifest, identity: CapturedOrdinaryRequestAuth,
                      isCurrent: () -> Bool) async {
        guard let record = file.records[id] else { return }
        let artwork = manifest.artworkUrls
        let kinds: [(paths: [String], name: String, field: WritableKeyPath<DownloadRecord, String?>)] = [
            ([record.preferredPosterPath, artwork?.poster].compactMap { $0 }, DownloadEngine.Disk.posterFileName, \.posterFilename),
            ([artwork?.backdrop].compactMap { $0 }, DownloadEngine.Disk.backdropFileName, \.backdropFilename),
            ([artwork?.logo].compactMap { $0 }, DownloadEngine.Disk.logoFileName, \.logoFilename),
        ]
        var retryLater = false
        for kind in kinds {
            guard isCurrent() else { return }
            guard !kind.paths.isEmpty else { continue }
            var bytes: Data?
            var lastError: Error?
            for path in kind.paths {
                do {
                    // An empty answer still ends the search for this kind.
                    bytes = try await VividAPI.shared.fetchDownloadAssetData(path: path, auth: identity)
                    break
                } catch {
                    lastError = error
                }
            }
            guard let bytes else {
                if let lastError, DownloadFailureReport.isRetryable(lastError) { retryLater = true }
                continue
            }
            guard isCurrent(), !bytes.isEmpty else { continue }
            guard let url = fileURL(named: kind.name, forRecord: id), (try? bytes.write(to: url, options: .atomic)) != nil else {
                retryLater = true
                continue
            }
            file.records[id]?[keyPath: kind.field] = kind.name
        }
        if isCurrent() { file.records[id]?.artworkChecked = !retryLater }
        persist()
    }

    /// Text subtitle files the media file doesn't carry, saved beside it.
    func fetchSubtitles(_ id: String, manifest: OfflineManifest, identity: CapturedOrdinaryRequestAuth,
                        isCurrent: () -> Bool) async {
        guard var saved = file.records[id]?.subtitleFilenames else { return }
        var retryLater = false
        for item in DownloadEngine.SubtitleFiles.savable(in: manifest) where saved[item.entry.fetchUrl] == nil {
            guard isCurrent() else { break }
            let bytes: Data
            do {
                bytes = try await VividAPI.shared.fetchDownloadAssetData(path: item.entry.fetchUrl, auth: identity)
            } catch {
                if DownloadFailureReport.isRetryable(error) { retryLater = true }
                continue
            }
            guard isCurrent(), !bytes.isEmpty, bytes.count <= 10_485_760 else { continue }
            let name = "subtitle-\(item.position).\(item.ext)"
            // A failed write may succeed once space is freed.
            guard let url = fileURL(named: name, forRecord: id), (try? bytes.write(to: url, options: .atomic)) != nil else {
                retryLater = true
                continue
            }
            saved[item.entry.fetchUrl] = name
        }
        guard isCurrent() else { return }
        file.records[id]?.subtitleFilenames = saved
        if !retryLater { file.records[id]?.subtitlesChecked = true }
        persist()
    }

    /// Fills in artwork and subtitle files a download lacks: older
    /// downloads, and ones interrupted after their transfer began.
    func backfillAssets() async {
        let candidates = file.records.values.filter { record in
            guard [.completed, .revoked, .downloading].contains(record.localStatus),
                  record.manifestFilename != nil, preparations[record.id] == nil else { return false }
            return record.subtitlesChecked != true || Self.needsArtwork(record)
        }.map(\.id)
        guard !candidates.isEmpty, let identity = await scopeIdentity() else { return }
        let generation = self.generation
        for id in candidates {
            guard generation == self.generation, let record = file.records[id], preparations[id] == nil else { continue }
            guard let manifest = await readManifest(for: record) else { continue }
            let isCurrent = { generation == self.generation && self.file.records[id] != nil }
            if Self.needsArtwork(record) {
                await fetchArtwork(id, manifest: manifest, identity: identity, isCurrent: isCurrent)
            }
            if record.subtitlesChecked != true {
                await fetchSubtitles(id, manifest: manifest, identity: identity, isCurrent: isCurrent)
            }
        }
    }

    /// Unset with a poster saved counts as done.
    private static func needsArtwork(_ record: DownloadRecord) -> Bool {
        record.artworkChecked == false || (record.artworkChecked == nil && record.posterFilename == nil)
    }

    // MARK: Retries

    /// Tries again after 10, 20, 40 then 80 seconds, if nothing has changed.
    func scheduleRetry(_ id: String, resumeData: Data?, refreshesSignIn: Bool) {
        guard let record = file.records[id] else { return }
        retryTimers[id]?.task.cancel()
        let delay = min(pow(2, Double(record.retryCount)) * 5, 120)
        let retry = DownloadEngine.HeldRetry(
            recordId: id, status: record.localStatus, generation: generation, resumeData: resumeData,
            refreshesSignIn: refreshesSignIn
        )
        retryTimers[id] = DownloadEngine.Running { [weak self] running in
            try? await Task.sleep(for: .seconds(delay))
            await self?.fireRetry(retry, timer: running)
        }
    }

    private func fireRetry(_ retry: DownloadEngine.HeldRetry, timer: UUID?) async {
        let id = retry.recordId
        func timerIsMine() -> Bool { timer == nil || retryTimers[id]?.id == timer }
        func stillDue() -> Bool {
            guard timerIsMine(), !Task.isCancelled || timer == nil, currentScope != nil,
                  retry.generation == generation, let record = file.records[id] else { return false }
            return record.taskIdentifier == nil && record.localStatus == retry.status
        }
        defer { if let timer, retryTimers[id]?.id == timer { retryTimers[id] = nil } }
        guard stillDue() else { return }
        if retry.refreshesSignIn {
            // An ordinary request lets the HTTP client refresh the sign-in.
            _ = try? await VividAPI.shared.listDownloads()
            guard stillDue() else { return }
        }
        guard queueHold == 0 else {
            heldRetries.append(retry)
            return
        }
        restart(retry)
    }

    /// Retries that came due while a list of episodes was registering.
    func startHeldRetries() {
        guard queueHold == 0, !heldRetries.isEmpty else { return }
        let due = heldRetries
        heldRetries = []
        for retry in due {
            guard currentScope != nil, retry.generation == generation, let record = file.records[retry.recordId],
                  record.taskIdentifier == nil, record.localStatus == retry.status else { continue }
            restart(retry)
        }
    }

    private func restart(_ retry: DownloadEngine.HeldRetry) {
        let id = retry.recordId
        guard var record = file.records[id] else { return }
        if let data = retry.resumeData {
            record.taskIdentifier = transfers.resume(from: data, description: transferTag(forRecord: id))
            record.localStatus = .downloading
            file.records[id] = record
            persist()
        } else {
            record.localStatus = .fetchingAssets
            file.records[id] = record
            persist()
            launchPreparation(id)
        }
    }

    // MARK: Series storage cap

    /// A monitored series' download would go over its storage limit. The
    /// record stays queued and the queue passes it over.
    func exceedsSeriesCap(_ record: DownloadRecord) -> Bool {
        guard let series = Self.seriesKey(record),
              let subscription = file.subscriptions.first(where: { $0.seriesId == series }),
              subscription.maxStorageBytes > 0 else { return false }
        let counted: Set<LocalDownloadStatus> = [.completed, .downloading, .fetchingAssets, .paused]
        let used = file.records.values.reduce(Int64(0)) { total, other in
            guard other.id != record.id, Self.seriesKey(other) == series, counted.contains(other.localStatus) else { return total }
            return total + max(other.fileSize, other.bytesDownloaded)
        }
        return used + max(record.fileSize, 0) > subscription.maxStorageBytes
    }

    /// Episode rows a reconcile added carry the series id as content id
    /// until preparation sets the series.
    private static func seriesKey(_ record: DownloadRecord) -> String? {
        record.seriesId ?? (record.episodeId != nil ? record.contentId : nil)
    }

    // MARK: Failure reports and notices

    func reportFailure(of record: DownloadRecord, stage: DownloadFailureReport.Stage, error: Error) {
        guard let report = DownloadFailureReport(
            stage: stage, error: error, server: MediaServerProvider.active.rawValue, quality: record.format,
            batch: record.batchId != nil, retries: record.retryCount
        ) else { return }
        AppHealthMonitor.downloadFailed(report)
    }

    func report(_ record: DownloadRecord, stage: DownloadFailureReport.Stage, status: Int?, urlErrorCode: Int?, error: String) {
        AppHealthMonitor.downloadFailed(DownloadFailureReport(
            stage: stage, server: MediaServerProvider.active.rawValue, status: status, urlErrorCode: urlErrorCode,
            error: error, quality: record.format, batch: record.batchId != nil, retries: record.retryCount
        ))
    }

    func notifyFailure(of record: DownloadRecord) {
        #if os(iOS)
        DownloadEngine.Alerts.failed(record)
        #endif
    }
}

extension DownloadEngine {
    /// A retry waiting to restart, with what must still hold when it does.
    struct HeldRetry {
        let recordId: String
        let status: LocalDownloadStatus
        let generation: UInt64
        let resumeData: Data?
        let refreshesSignIn: Bool
    }

    /// Which manifest subtitles are saved as files: text formats the media
    /// file doesn't already carry, each with its place in the manifest.
    enum SubtitleFiles {
        struct Item {
            let position: Int
            let entry: OfflineManifest.SubtitleEntry
            let ext: String
        }

        static func savable(in manifest: OfflineManifest) -> [Item] {
            (manifest.subtitles ?? []).enumerated().compactMap { position, entry in
                guard let ext = fileExtension(entry.format), !isEmbedded(entry.fetchUrl) else { return nil }
                return Item(position: position, entry: entry, ext: ext)
            }
        }

        static func fileExtension(_ format: String?) -> String? {
            switch format?.lowercased() {
            case "srt", "subrip": "srt"
            case "vtt", "webvtt": "vtt"
            case "ass": "ass"
            case "ssa": "ssa"
            default: nil
            }
        }

        /// Silo lists tracks inside the media file as `embedded:<n>`.
        private static func isEmbedded(_ fetchUrl: String) -> Bool {
            let path = fetchUrl.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let last = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return (last.removingPercentEncoding ?? last).hasPrefix("embedded:")
        }
    }
}
