import Foundation

extension DownloadManager {
    // MARK: Capability

    var downloadsOffForAccount: Bool { hasDownloadAnswer && !downloadsEnabled }

    var allowsSeasonRequests: Bool { downloadsEnabled && capability?.seasonDownload == true }

    var allowsBatchQuality: Bool {
        downloadsEnabled && capability?.bulkQuality == true && offeredQualities.count > 1
    }

    var allowsMonitoring: Bool { downloadsEnabled && capability?.seriesMonitoring == true }

    /// The capability's presets this app knows, in the capability's order.
    var offeredQualities: [DownloadFormat] {
        (capability?.qualityPresets ?? []).compactMap(DownloadFormat.init(rawValue:))
    }

    var offeredMonitoringRules: [MonitoringRule] {
        (capability?.monitoringModes ?? []).compactMap(MonitoringRule.init(rawValue:))
    }

    /// The server's own height for a preset when it gives one, else the ladder's.
    func tallestOutput(of format: DownloadFormat) -> Int? {
        capability?.qualityOptions.first { $0.preset == format.rawValue }?.maxHeight ?? format.ladderMaxHeight
    }

    func qualityTitle(for format: DownloadFormat) -> String {
        format.qualityLabel(maxHeight: tallestOutput(of: format))
    }

    func qualityTitle(forRaw raw: String) -> String {
        DownloadFormat(rawValue: raw).map { qualityTitle(for: $0) } ?? raw
    }

    func hasPendingRequest(contentId: String) -> Bool {
        registrationKeys[contentId] != nil
    }

    // MARK: Records

    /// Any record whose content id or episode id is this one. An episode
    /// record carries its series id as content id, so a series id finds some
    /// episode of that series; which one is not defined.
    func record(forContentId contentId: String) -> DownloadRecord? {
        file.records.values.first { $0.contentId == contentId || $0.episodeId == contentId }
    }

    func record(withId id: String) -> DownloadRecord? {
        file.records[id]
    }

    var unfinishedRecords: [DownloadRecord] {
        records.filter { $0.localStatus.isActive }
    }

    func unfinishedRecords(inSeries seriesId: String) -> [DownloadRecord] {
        unfinishedRecords.filter { $0.seriesId == seriesId || $0.contentId == seriesId }
    }

    // MARK: Monitoring and progress

    var monitoredSeries: [MonitoredSeries] { file.subscriptions }

    func monitoring(forSeries seriesId: String) -> MonitoredSeries? {
        file.subscriptions.first { $0.seriesId == seriesId }
    }

    func savedProgress(for mediaItemId: String) -> SavedProgress? {
        file.localProgress[mediaItemId]
    }

    func isFinishedWatching(_ record: DownloadRecord) -> Bool {
        file.localProgress[record.leafMediaItemId]?.completed == true
    }

    func smoothedRate(forRecord id: String) -> Double? {
        transferRates[id]
    }

    // MARK: Files

    /// The record's poster, else any other episode's of the same series.
    /// Built from saved names and not checked on disk.
    func posterFile(for record: DownloadRecord) -> URL? {
        if let name = record.posterFilename { return fileURL(named: name, forRecord: record.id) }
        guard let seriesId = record.seriesId,
              let sibling = file.records.values.first(where: { $0.seriesId == seriesId && $0.posterFilename != nil }),
              let name = sibling.posterFilename else { return nil }
        return fileURL(named: name, forRecord: sibling.id)
    }

    /// The record's saved manifest, read off the main actor.
    func readManifest(for record: DownloadRecord) async -> OfflineManifest? {
        guard let name = record.manifestFilename, let url = fileURL(named: name, forRecord: record.id) else { return nil }
        return await DownloadEngine.Store.shared.readManifest(at: url)
    }

    /// Season, episode and series title from the saved manifests of episodes
    /// that lack them (records saved before these fields were kept).
    func fillMissingEpisodeDetails() async {
        let lacking = file.records.values.filter {
            $0.seriesId != nil && $0.manifestFilename != nil && ($0.seasonNumber == nil || $0.seriesTitle == nil)
        }
        guard !lacking.isEmpty else { return }
        var readAny = false
        for record in lacking {
            guard let manifest = await readManifest(for: record), var current = file.records[record.id] else { continue }
            readAny = true
            let before = current
            current.seasonNumber = current.seasonNumber ?? manifest.seasonNumber
            current.episodeNumber = current.episodeNumber ?? manifest.episodeNumber
            current.seriesTitle = current.seriesTitle ?? manifest.seriesTitle
            if current != before { file.records[record.id] = current }
        }
        if readAny { persist() }
    }

    // MARK: Grouped views

    var storageSplit: StorageSplit {
        let onDevice = DownloadEngine.Shelf.onDevice(Array(file.records.values))
        let series = onDevice.filter { $0.seriesId != nil }.reduce(Int64(0)) { $0 + $1.fileSize }
        let movies = onDevice.filter { $0.seriesId == nil }.reduce(Int64(0)) { $0 + $1.fileSize }
        let unfinished = file.records.values.filter { $0.localStatus.isActive }.reduce(Int64(0)) { $0 + $1.bytesDownloaded }
        return StorageSplit(
            seriesBytes: series, movieBytes: movies, unfinishedBytes: unfinished,
            otherBytes: max(0, bytesOnDisk - series - movies)
        )
    }

    var savedSeries: [DownloadedSeries] {
        DownloadEngine.Shelf.series(
            from: DownloadEngine.Shelf.onDevice(Array(file.records.values)),
            isWatched: { self.isFinishedWatching($0) },
            subscriptionTitle: { seriesId in self.monitoring(forSeries: seriesId)?.seriesTitle },
            isMonitored: { seriesId in self.monitoring(forSeries: seriesId) != nil }
        )
    }

    func shelfEntries(orderedBy order: DownloadListOrder) -> [DownloadShelfEntry] {
        let movies = DownloadEngine.Shelf.onDevice(Array(file.records.values)).filter { $0.seriesId == nil }
        let entries = savedSeries.map(DownloadShelfEntry.show) + movies.map(DownloadShelfEntry.film)
        return DownloadEngine.Shelf.sorted(entries, by: order)
    }

    var watchedToClear: [DownloadRecord] {
        DownloadEngine.Shelf.onDevice(Array(file.records.values)).filter {
            $0.localStatus == .completed && isFinishedWatching($0)
        }
    }

    var watchedBytesToClear: Int64 {
        watchedToClear.reduce(0) { $0 + $1.fileSize }
    }
}
