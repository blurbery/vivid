import XCTest
import Foundation
@testable import Vivid

/// Pure-logic coverage for the Downloads redesign grouping/sorting rules
/// (`DownloadGroupBuilder`). These are the highest-risk new behaviors:
/// season ordering (newest-first, specials last), episode ordering, watched
/// counts, title resolution, and list sort options.
final class DownloadGroupingTests: XCTestCase {

    func testAbsoluteDownloadArtworkURLBecomesRelativeAuthenticatedRequest() throws {
        let location = try DownloadAssetRequestLocation.resolve(
            "https://media.example.com/vivid/api/v1/images/poster%20art?width=1000&format=jpg",
            relativeTo: "https://media.example.com/vivid"
        )
        XCTAssertEqual(location.path, "/api/v1/images/poster%20art")
        XCTAssertEqual(location.query, ["width": "1000", "format": "jpg"])
    }

    func testRelativeDownloadArtworkPathRemainsRelative() throws {
        let location = try DownloadAssetRequestLocation.resolve(
            "/api/v1/downloads/artwork/poster?width=600",
            relativeTo: "https://media.example.com"
        )
        XCTAssertEqual(location.path, "/api/v1/downloads/artwork/poster")
        XCTAssertEqual(location.query, ["width": "600"])
    }

    func testDownloadArtworkRejectsAnotherServerOrigin() {
        XCTAssertThrowsError(try DownloadAssetRequestLocation.resolve(
            "https://other.example.com/api/v1/images/poster",
            relativeTo: "https://media.example.com"
        ))
    }

    func testDownloadPreferencesStayWithTheirProfileAcrossSwitches() throws {
        let domain = "vivid.download-profile-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = DownloadSettings(defaults: defaults)
        settings.reload(for: "server-a/profile-a")
        settings.defaultMaxStorageGB = 50
        settings.wifiOnly = false
        settings.keepWatchedDownloads = true
        settings.reload(for: "server-a/profile-b")
        XCTAssertEqual(settings.defaultMaxStorageGB, 0)
        XCTAssertTrue(settings.wifiOnly)
        XCTAssertFalse(settings.keepWatchedDownloads)
        settings.defaultMaxStorageGB = 100
        settings.reload(for: "server-a/profile-a")
        XCTAssertEqual(settings.defaultMaxStorageGB, 50)
        XCTAssertFalse(settings.wifiOnly)
        XCTAssertTrue(settings.keepWatchedDownloads)
        settings.reload(for: "server-b/profile-a")
        XCTAssertEqual(settings.defaultMaxStorageGB, 0)
        XCTAssertTrue(settings.wifiOnly)
        settings.reload(for: "server-a/profile-b")
        XCTAssertEqual(settings.defaultMaxStorageGB, 100)
    }

    // MARK: - Factories

    private func episode(
        _ id: String,
        series: String,
        season: Int,
        number: Int,
        bytes: Int64,
        title: String? = nil,
        seriesTitle: String? = nil,
        status: LocalDownloadStatus = .completed
    ) -> DownloadRecord {
        DownloadRecord(
            id: id,
            contentId: series,
            episodeId: "\(id)-leaf",
            batchId: nil,
            mediaFileId: 0,
            format: "original",
            serverStatus: "ready",
            localStatus: status,
            fileSize: bytes,
            bytesDownloaded: bytes,
            mediaFilename: "media.mp4",
            manifestFilename: "manifest.json",
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: title ?? "Episode \(number)",
            subtitle: "S\(season) · E\(number)",
            type: "episode",
            seriesId: series,
            seriesTitle: seriesTitle,
            seasonNumber: season,
            episodeNumber: number,
            posterThumbhash: nil,
            container: "mp4",
            stableIdentity: nil,
            registeredAt: Date(timeIntervalSince1970: 1_000_000 + Double(season * 100 + number)),
            downloadedAt: nil,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func movie(_ id: String, bytes: Int64, title: String) -> DownloadRecord {
        DownloadRecord(
            id: id,
            contentId: id,
            episodeId: nil,
            batchId: nil,
            mediaFileId: 0,
            format: "original",
            serverStatus: "ready",
            localStatus: .completed,
            fileSize: bytes,
            bytesDownloaded: bytes,
            mediaFilename: "media.mp4",
            manifestFilename: "manifest.json",
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: title,
            subtitle: "2024",
            type: "movie",
            seriesId: nil,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            posterThumbhash: nil,
            container: "mp4",
            stableIdentity: nil,
            registeredAt: Date(timeIntervalSince1970: 1_000_000),
            downloadedAt: nil,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func groups(
        _ records: [DownloadRecord],
        watched: Set<String> = [],
        seriesTitle: @escaping (String) -> String? = { _ in nil },
        monitored: Set<String> = []
    ) -> [DownloadSeriesGroup] {
        DownloadGroupBuilder.seriesGroups(
            from: records,
            isWatched: { watched.contains($0.leafMediaItemId) },
            seriesTitle: seriesTitle,
            isMonitored: { monitored.contains($0) }
        )
    }

    // MARK: - Grouping

    func testGroupsEpisodesBySeriesAndExcludesMovies() {
        let records = [
            episode("a", series: "show", season: 1, number: 1, bytes: 100),
            episode("b", series: "show", season: 1, number: 2, bytes: 200),
            movie("m", bytes: 999, title: "A Movie"),
        ]
        let result = groups(records)
        XCTAssertEqual(result.count, 1, "movies must not produce a series group")
        XCTAssertEqual(result.first?.seriesId, "show")
        XCTAssertEqual(result.first?.episodeCount, 2)
        XCTAssertEqual(result.first?.totalBytes, 300)
    }

    func testSeasonsAreNewestFirstWithSpecialsLast() {
        let records = [
            episode("a", series: "s", season: 1, number: 1, bytes: 1),
            episode("b", series: "s", season: 2, number: 1, bytes: 1),
            episode("c", series: "s", season: 0, number: 1, bytes: 1),
        ]
        let group = groups(records).first
        XCTAssertEqual(group?.seasons.map(\.seasonNumber), [2, 1, 0])
    }

    func testEpisodesWithinSeasonSortedByNumber() {
        let records = [
            episode("a", series: "s", season: 1, number: 3, bytes: 1),
            episode("b", series: "s", season: 1, number: 1, bytes: 1),
            episode("c", series: "s", season: 1, number: 2, bytes: 1),
        ]
        let season = groups(records).first?.seasons.first
        XCTAssertEqual(season?.records.map { $0.episodeNumber }, [1, 2, 3])
    }

    func testWatchedCountsAndAllWatched() {
        let records = [
            episode("a", series: "s", season: 1, number: 1, bytes: 1),
            episode("b", series: "s", season: 1, number: 2, bytes: 1),
        ]
        let partial = groups(records, watched: ["a-leaf"]).first
        XCTAssertEqual(partial?.watchedCount, 1)
        XCTAssertFalse(partial?.allWatched ?? true)

        let all = groups(records, watched: ["a-leaf", "b-leaf"]).first
        XCTAssertTrue(all?.allWatched ?? false)
    }

    func testPerSeasonTotalsAndCounts() {
        let records = [
            episode("a", series: "s", season: 2, number: 1, bytes: 100),
            episode("b", series: "s", season: 2, number: 2, bytes: 150),
            episode("c", series: "s", season: 1, number: 1, bytes: 300),
        ]
        let group = groups(records).first
        XCTAssertEqual(group?.totalBytes, 550)
        XCTAssertEqual(group?.seasons.first?.seasonNumber, 2)
        XCTAssertEqual(group?.seasons.first?.totalBytes, 250)
        XCTAssertEqual(group?.seasons.first?.episodeCount, 2)
    }

    // MARK: - Title resolution

    func testTitlePrefersRecordSeriesTitleThenSubscription() {
        let withRecordTitle = [episode("a", series: "sid", season: 1, number: 1, bytes: 1, seriesTitle: "The Show")]
        XCTAssertEqual(groups(withRecordTitle, seriesTitle: { _ in "Fallback" }).first?.title, "The Show")

        let withoutRecordTitle = [episode("a", series: "sid", season: 1, number: 1, bytes: 1)]
        XCTAssertEqual(groups(withoutRecordTitle, seriesTitle: { _ in "Sub Title" }).first?.title, "Sub Title")
    }

    func testMonitoredFlagThreadedThrough() {
        let records = [episode("a", series: "sid", season: 1, number: 1, bytes: 1)]
        XCTAssertTrue(groups(records, monitored: ["sid"]).first?.isMonitored ?? false)
        XCTAssertFalse(groups(records).first?.isMonitored ?? true)
    }

    // MARK: - List sorting

    func testSortLargestFirst() {
        let items: [DownloadListItem] = [
            .movie(movie("a", bytes: 100, title: "A")),
            .movie(movie("b", bytes: 300, title: "B")),
            .movie(movie("c", bytes: 200, title: "C")),
        ]
        XCTAssertEqual(
            DownloadGroupBuilder.sorted(items, by: .largestFirst).map(\.totalBytes),
            [300, 200, 100]
        )
    }

    func testSortAlphabeticalIsCaseInsensitive() {
        let items: [DownloadListItem] = [
            .movie(movie("a", bytes: 1, title: "Zodiac")),
            .movie(movie("b", bytes: 1, title: "arrival")),
            .movie(movie("c", bytes: 1, title: "Dune")),
        ]
        XCTAssertEqual(
            DownloadGroupBuilder.sorted(items, by: .alphabetical).map(\.sortTitle),
            ["arrival", "Dune", "Zodiac"]
        )
    }

    // MARK: - Emby and Jellyfin watch state

    func testServerWatchStateReachesDownloadsUnlessALocalEventIsWaiting() {
        let now = Date(timeIntervalSince1970: 1_000)
        let earlier = Date(timeIntervalSince1970: 10)
        func server(_ id: String, position: Double, duration: Double = 2_600, completed: Bool) -> ProgressPullItem {
            ProgressPullItem(mediaItemId: id, positionSeconds: position, durationSeconds: duration,
                             completed: completed, updatedAt: nil)
        }
        func local(position: Double, completed: Bool) -> LocalProgressEntry {
            LocalProgressEntry(position: position, duration: 2_600, completed: completed, updatedAt: earlier)
        }
        let updates = DownloadManager.currentProgressUpdates([
            server("streamed", position: 0, completed: true),
            server("resumed", position: 1_200, completed: false),
            server("unmarked", position: 0, completed: false),
            server("queued", position: 0, completed: false),
            server("unchanged", position: 600, duration: 0, completed: false),
            server("untouched", position: 0, completed: false),
        ], local: [
            "resumed": local(position: 300, completed: false),
            "unmarked": local(position: 0, completed: true),
            "queued": local(position: 2_500, completed: true),
            "unchanged": local(position: 600, completed: false),
            "missing": local(position: 900, completed: false),
        ], pending: ["queued"], now: now)

        // Watched online without playing the download, watched further
        // elsewhere, and marked unwatched on the server all reach the device.
        XCTAssertEqual(Set(updates.keys), ["streamed", "resumed", "unmarked"])
        XCTAssertEqual(updates["streamed"]?.completed, true)
        XCTAssertEqual(updates["streamed"]?.duration, 2_600)
        XCTAssertEqual(updates["resumed"]?.position, 1_200)
        XCTAssertEqual(updates["resumed"]?.updatedAt, now)
        XCTAssertEqual(updates["unmarked"]?.completed, false)
        // An unsent offline event, an unchanged item, an item the server
        // didn't return and one never started anywhere are left alone.
        XCTAssertNil(updates["queued"])
        XCTAssertNil(updates["unchanged"])
        XCTAssertNil(updates["missing"])
        XCTAssertNil(updates["untouched"])
    }

    func testFlushNeverResendsAnAcknowledgedPosition() {
        func entry(_ id: String, attempts: Int = 0, positionSent: Bool? = nil) -> QueuedProgress {
            QueuedProgress(id: UUID(), mediaItemId: id, position: 600, duration: 2_600,
                           updatedAt: Date(timeIntervalSince1970: 10), attempts: attempts, positionSent: positionSent)
        }
        func result(_ id: String, ok: Bool) -> SyncProgressResult {
            SyncProgressResult(mediaItemId: id, status: ok ? "ok" : "error", error: nil)
        }
        let batch = [entry("done"), entry("watchedFailed"), entry("retried"), entry("lastTry", attempts: 4),
                     entry("completedRejected", attempts: 4), entry("unanswered", attempts: 2),
                     entry("sentEarlier", positionSent: true)]
        let appended = entry("appended")
        let queue = DownloadManager.progressQueue(
            batch + [appended], afterSending: batch,
            results: [result("done", ok: true), result("watchedFailed", ok: true), result("retried", ok: false),
                      result("lastTry", ok: false), result("completedRejected", ok: false)],
            watchedFailures: ["watchedFailed", "sentEarlier"], completed: ["watchedFailed", "completedRejected", "sentEarlier"],
            maxRetries: 4)

        XCTAssertEqual(queue.map(\.mediaItemId), ["watchedFailed", "retried", "completedRejected", "unanswered", "sentEarlier", "appended"])
        let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.mediaItemId, $0) })
        // An acknowledged position whose watched write failed is kept only
        // for that write, so the next flush doesn't send the stop again.
        XCTAssertEqual(byID["watchedFailed"]?.positionSent, true)
        XCTAssertEqual(byID["sentEarlier"]?.positionSent, true)
        XCTAssertNil(byID["retried"]?.positionSent)
        XCTAssertEqual(byID["retried"]?.attempts, 1)
        XCTAssertEqual(byID["completedRejected"]?.attempts, 5, "A completed item is never dropped")
        // A batch that failed part-way leaves the items it didn't reach as
        // they were, and an entry queued meanwhile is untouched.
        XCTAssertEqual(byID["unanswered"]?.attempts, 2)
        XCTAssertEqual(byID["appended"]?.attempts, 0)
    }

    func testOnlyEmbyAndJellyfinReadCurrentProgress() {
        XCTAssertTrue(DownloadManager.readsCurrentProgress(.emby))
        XCTAssertTrue(DownloadManager.readsCurrentProgress(.jellyfin))
        XCTAssertFalse(DownloadManager.readsCurrentProgress(.silo), "Silo keeps its change feed")
    }
}
