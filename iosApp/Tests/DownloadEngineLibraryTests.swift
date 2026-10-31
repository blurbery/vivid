import XCTest
@testable import Vivid

/// Artwork locations, per-profile preferences, the grouped Downloads list
/// and the offline progress rules.
final class DownloadEngineLibraryTests: XCTestCase {
    // MARK: Artwork locations

    func testAbsoluteArtworkOnTheServerBecomesARelativeRequest() throws {
        let location = try DownloadEngine.AssetLocation(
            "https://media.example.com/vivid/api/v1/images/poster%20art?width=1000&format=jpg",
            serverURL: "https://media.example.com/vivid"
        )
        XCTAssertEqual(location.path, "/api/v1/images/poster%20art", "The base path goes and the encoding stays")
        XCTAssertEqual(location.query, ["width": "1000", "format": "jpg"])
    }

    func testRelativeArtworkStaysRelative() throws {
        let location = try DownloadEngine.AssetLocation(
            "/api/v1/downloads/artwork/poster?width=600", serverURL: "https://media.example.com"
        )
        XCTAssertEqual(location.path, "/api/v1/downloads/artwork/poster")
        XCTAssertEqual(location.query, ["width": "600"])
    }

    func testArtworkFromAnotherOriginIsRefused() {
        XCTAssertThrowsError(try DownloadEngine.AssetLocation(
            "https://other.example.com/api/v1/images/poster", serverURL: "https://media.example.com"
        ))
    }

    // MARK: Preferences

    func testPreferencesStayWithTheirProfile() throws {
        let suiteName = "vivid.tests.download-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = DownloadSettings(defaults: defaults)

        settings.load(scope: "server-a/profile-a")
        settings.monitoringLimitGBByDefault = 50
        settings.wifiOnlyTransfers = false
        settings.keepsWatchedDownloads = true

        settings.load(scope: "server-a/profile-b")
        XCTAssertEqual(settings.monitoringLimitGBByDefault, 0)
        XCTAssertTrue(settings.wifiOnlyTransfers)
        XCTAssertFalse(settings.keepsWatchedDownloads)
        settings.monitoringLimitGBByDefault = 100

        settings.load(scope: "server-a/profile-a")
        XCTAssertEqual(settings.monitoringLimitGBByDefault, 50)
        XCTAssertFalse(settings.wifiOnlyTransfers)
        XCTAssertTrue(settings.keepsWatchedDownloads)

        settings.load(scope: "server-b/profile-a")
        XCTAssertEqual(settings.monitoringLimitGBByDefault, 0)
        XCTAssertTrue(settings.wifiOnlyTransfers)

        settings.load(scope: "server-a/profile-b")
        XCTAssertEqual(settings.monitoringLimitGBByDefault, 100)
    }

    // MARK: Grouping

    private func record(_ id: String, series: String? = "show", season: Int? = 1, episode: Int? = 1, bytes: Int64 = 100,
                        seriesTitle: String? = nil, title: String? = nil,
                        registeredAt: Date = Date(timeIntervalSince1970: 0)) -> DownloadRecord {
        DownloadRecord(
            id: id, contentId: series ?? id, episodeId: series == nil ? nil : "\(id)-leaf", mediaFileId: 1,
            format: "original", serverStatus: "ready", localStatus: .completed, fileSize: bytes, bytesDownloaded: bytes,
            mediaFilename: "media.mp4", title: title, type: series == nil ? "movie" : "episode", seriesId: series,
            seriesTitle: seriesTitle, seasonNumber: season, episodeNumber: episode, registeredAt: registeredAt
        )
    }

    private func group(_ records: [DownloadRecord], watched: Set<String> = [], title: String? = nil,
                       monitored: Set<String> = []) -> [DownloadedSeries] {
        DownloadEngine.Shelf.series(
            from: records,
            isWatched: { watched.contains($0.leafMediaItemId) },
            subscriptionTitle: { _ in title },
            isMonitored: { monitored.contains($0) }
        )
    }

    func testEpisodesGroupBySeriesAndMoviesMakeNoGroup() throws {
        let groups = group([record("a", bytes: 100), record("b", episode: 2, bytes: 200), record("m", series: nil, bytes: 999)])
        XCTAssertEqual(groups.count, 1)
        let show = try XCTUnwrap(groups.first)
        XCTAssertEqual(show.seriesId, "show")
        XCTAssertEqual(show.episodeTotal, 2)
        XCTAssertEqual(show.storedBytes, 300)
    }

    func testSeasonsComeNewestFirstWithSpecialsLast() throws {
        let show = try XCTUnwrap(group([record("a", season: 1), record("b", season: 2), record("c", season: 0)]).first)
        XCTAssertEqual(show.seasonGroups.map(\.seasonKey), [2, 1, 0])
        XCTAssertTrue(try XCTUnwrap(show.seasonGroups.last).holdsSpecials)
    }

    func testEpisodesAreInEpisodeNumberOrder() throws {
        let show = try XCTUnwrap(group([record("c", episode: 3), record("a", episode: 1), record("b", episode: 2)]).first)
        XCTAssertEqual(show.seasonGroups.first?.episodes.map(\.episodeNumber), [1, 2, 3])
    }

    func testWatchedEpisodesAreCounted() throws {
        let episodes = [record("a", episode: 1), record("b", episode: 2)]
        let partly = try XCTUnwrap(group(episodes, watched: ["a-leaf"]).first)
        XCTAssertEqual(partly.watchedEpisodes, 1)
        XCTAssertFalse(partly.fullyWatched)
        let all = try XCTUnwrap(group(episodes, watched: ["a-leaf", "b-leaf"]).first)
        XCTAssertTrue(all.fullyWatched)
    }

    func testTotalsAddUpPerSeriesAndSeason() throws {
        let show = try XCTUnwrap(group([
            record("a", season: 2, episode: 1, bytes: 100), record("b", season: 2, episode: 2, bytes: 150),
            record("c", season: 1, episode: 1, bytes: 300),
        ]).first)
        XCTAssertEqual(show.storedBytes, 550)
        let first = try XCTUnwrap(show.seasonGroups.first)
        XCTAssertEqual(first.seasonKey, 2)
        XCTAssertEqual(first.storedBytes, 250)
        XCTAssertEqual(first.episodeTotal, 2)
    }

    func testARecordsOwnSeriesTitleWinsOverTheSubscriptions() {
        XCTAssertEqual(group([record("a", seriesTitle: "The Show")], title: "Fallback").first?.displayTitle, "The Show")
        XCTAssertEqual(group([record("a")], title: "Sub Title").first?.displayTitle, "Sub Title")
    }

    func testMonitoredSeriesAreMarked() {
        XCTAssertEqual(group([record("a")], monitored: ["show"]).first?.hasMonitoring, true)
        XCTAssertEqual(group([record("a")]).first?.hasMonitoring, false)
    }

    func testLargestFirstSortsByStoredBytes() {
        let entries = [100, 300, 200].map { DownloadShelfEntry.film(record("m\($0)", series: nil, bytes: Int64($0))) }
        XCTAssertEqual(DownloadEngine.Shelf.sorted(entries, by: .biggestFirst).map(\.storedBytes), [300, 200, 100])
    }

    func testNameOrderIgnoresCase() {
        let entries = ["Zodiac", "arrival", "Dune"].map { DownloadShelfEntry.film(record($0, series: nil, title: $0)) }
        XCTAssertEqual(DownloadEngine.Shelf.sorted(entries, by: .byName).map(\.nameForSorting), ["arrival", "Dune", "Zodiac"])
    }

    // MARK: Offline progress

    func testEmbyAndJellyfinCurrentProgressReplacesOnlyWhatChanged() throws {
        let earlier = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 1_000)
        func server(_ id: String, _ position: Double, duration: Double = 2_600, completed: Bool = false) -> ProgressPullItem {
            ProgressPullItem(mediaItemId: id, positionSeconds: position, durationSeconds: duration, completed: completed, updatedAt: nil)
        }
        func local(_ position: Double, completed: Bool = false) -> SavedProgress {
            SavedProgress(position: position, duration: 2_600, completed: completed, updatedAt: earlier)
        }
        let items = [
            server("streamed", 0, completed: true),
            server("resumed", 1_200),
            server("unmarked", 0),
            server("queued", 0),
            server("unchanged", 600, duration: 0),
            server("untouched", 0),
        ]
        let entries = [
            "resumed": local(300),
            "unmarked": local(0, completed: true),
            "queued": local(2_500, completed: true),
            "unchanged": local(600),
            "missing": local(900),
        ]
        let updates = DownloadEngine.ProgressRules.currentStateUpdates(items, local: entries, pending: ["queued"], now: now)
        XCTAssertEqual(Set(updates.keys), ["streamed", "resumed", "unmarked"])
        let streamed = try XCTUnwrap(updates["streamed"])
        XCTAssertTrue(streamed.completed)
        XCTAssertEqual(streamed.duration, 2_600)
        let resumed = try XCTUnwrap(updates["resumed"])
        XCTAssertEqual(resumed.position, 1_200)
        XCTAssertEqual(resumed.updatedAt, now)
        XCTAssertEqual(updates["unmarked"]?.completed, false, "Watching can be undone")
    }

    func testAFlushNeverResendsAnAcknowledgedPosition() throws {
        func entry(_ id: String, attempts: Int = 0, positionSent: Bool? = nil) -> DownloadEngine.QueuedProgress {
            DownloadEngine.QueuedProgress(id: UUID(), mediaItemId: id, position: 600, duration: 2_600,
                                          updatedAt: Date(timeIntervalSince1970: 100), attempts: attempts,
                                          positionSent: positionSent)
        }
        let sent = [
            entry("done"), entry("watchedFailed"), entry("retried"), entry("lastTry", attempts: 4),
            entry("completedRejected", attempts: 4), entry("unanswered", attempts: 2),
            entry("sentEarlier", positionSent: true),
        ]
        let queue = sent + [entry("appended")]
        func result(_ id: String, _ status: String) -> (String, SyncProgressResult) {
            (id, SyncProgressResult(mediaItemId: id, status: status, error: status == "ok" ? nil : status))
        }
        let results = Dictionary(uniqueKeysWithValues: [
            result("done", "ok"), result("watchedFailed", "ok"), result("retried", "error"),
            result("lastTry", "error"), result("completedRejected", "error"),
        ])
        let next = DownloadEngine.ProgressRules.queueAfterFlush(
            queue, sent: sent, results: results, watchedFailed: ["watchedFailed", "sentEarlier"],
            completed: ["watchedFailed", "completedRejected", "sentEarlier"], retryLimit: 4
        )
        XCTAssertEqual(next.map(\.mediaItemId),
                       ["watchedFailed", "retried", "completedRejected", "unanswered", "sentEarlier", "appended"])
        let byId = Dictionary(uniqueKeysWithValues: next.map { ($0.mediaItemId, $0) })
        XCTAssertEqual(byId["watchedFailed"]?.positionSent, true)
        XCTAssertEqual(byId["sentEarlier"]?.positionSent, true)
        XCTAssertNotEqual(byId["retried"]?.positionSent, true)
        XCTAssertEqual(byId["retried"]?.attempts, 1)
        XCTAssertEqual(byId["completedRejected"]?.attempts, 5, "A completed item is never dropped")
        XCTAssertEqual(byId["unanswered"]?.attempts, 2)
        XCTAssertEqual(byId["appended"]?.attempts, 0)
    }

    func testOnlyEmbyAndJellyfinReadCurrentProgress() {
        XCTAssertTrue(DownloadEngine.ProgressRules.readsCurrentState(.emby))
        XCTAssertTrue(DownloadEngine.ProgressRules.readsCurrentState(.jellyfin))
        XCTAssertFalse(DownloadEngine.ProgressRules.readsCurrentState(.silo), "Silo keeps its change feed")
    }
}
