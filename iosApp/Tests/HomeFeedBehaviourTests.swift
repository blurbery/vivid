import XCTest
@testable import Vivid

final class HomeFeedBehaviourTests: XCTestCase {
    private static let progressStamp = "2026-07-10T12:00:00Z"

    // MARK: Fixtures

    private func makeItem(
        _ contentId: String,
        type: String = "movie",
        progressUpdatedAt: String? = "2026-07-10T12:00:00Z",
        seriesId: String? = nil,
        posterUrl: String? = nil,
        extra: [String: Any] = [:]
    ) throws -> SectionItem {
        var json: [String: Any] = ["contentId": contentId, "type": type, "title": "Test Item"]
        if let progressUpdatedAt { json["progressUpdatedAt"] = progressUpdatedAt }
        if let seriesId { json["seriesId"] = seriesId }
        if let posterUrl { json["posterUrl"] = posterUrl }
        json.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SectionItem.self, from: data)
    }

    private func makeRow(_ id: String, type: String, total: Int?, items: [SectionItem]) -> ResolvedSection {
        ResolvedSection(
            id: id,
            sectionType: type,
            title: id,
            featured: false,
            itemLimit: nil,
            totalCount: total,
            isCustom: false,
            customized: false,
            items: items
        )
    }

    private func oneItemRow(_ id: String) throws -> ResolvedSection {
        makeRow(id, type: "latest", total: 1, items: [try makeItem("\(id)-item")])
    }

    private func layoutKey() -> String {
        "test.home-\(UUID().uuidString)"
    }

    @MainActor
    private func makeLayoutStore(key: String) -> HomeSectionPreferences {
        HomeSectionPreferences(defaults: SharedDefaults.shared, storageKey: { key })
    }

    @MainActor
    private func storedJSON(_ key: String) throws -> [String: Any] {
        let data = try XCTUnwrap(SharedDefaults.shared.data(forKey: key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func prime(_ rows: [ResolvedSection]) {
        ResponseCache.shared.set(SectionsResponse(sections: rows), for: CacheKey.homeSections)
    }

    @MainActor
    private func cachedItemIDs() -> [[String]]? {
        ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self)?
            .sections.map { $0.items.map(\.contentId) }
    }

    private struct StubFailure: Error {}

    // MARK: Layout store

    @MainActor
    func testHiddenEmptyRowIsListedOnlyWhenIncludingHidden() throws {
        let key = layoutKey()
        defer { SharedDefaults.shared.removeObject(forKey: key) }
        let stored = #"{"orderedSectionIds":["hidden"],"hiddenSectionIds":["hidden"],"seenSectionIds":["hidden"]}"#
        SharedDefaults.shared.set(Data(stored.utf8), forKey: key)
        let store = makeLayoutStore(key: key)
        let row = makeRow("hidden", type: "latest", total: 0, items: [])

        XCTAssertFalse(store.arrangedSections([row]).contains { $0.id == "hidden" })
        XCTAssertTrue(store.arrangedSections([row], includingHidden: true).contains { $0.id == "hidden" })
    }

    @MainActor
    func testRowsBeyondSixStartHidden() throws {
        let key = layoutKey()
        let otherKey = layoutKey()
        defer {
            SharedDefaults.shared.removeObject(forKey: key)
            SharedDefaults.shared.removeObject(forKey: otherKey)
        }
        let store = makeLayoutStore(key: key)
        let six = try ["a", "b", "c", "d", "e", "f"].map(oneItemRow)
        store.enforceVisibleRowLimit(in: six)
        XCTAssertEqual(store.arrangedSections(six).map(\.id), ["a", "b", "c", "d", "e", "f"])

        let withNew = [try oneItemRow("new")] + six
        store.enforceVisibleRowLimit(in: withNew)
        XCTAssertFalse(store.isVisible("new"))
        XCTAssertEqual(store.arrangedSections(withNew).map(\.id), ["a", "b", "c", "d", "e", "f"])

        store.enforceVisibleRowLimit(in: Array(six[2...]))
        store.enforceVisibleRowLimit(in: withNew)
        XCTAssertEqual(store.arrangedSections(withNew).map(\.id), ["a", "b", "c", "d", "e", "f"])

        let fresh = makeLayoutStore(key: otherKey)
        let eight = try (1...8).map { try oneItemRow(String($0)) }
        fresh.enforceVisibleRowLimit(in: eight)
        XCTAssertEqual(fresh.arrangedSections(eight).map(\.id), ["1", "2", "3", "4", "5", "6"])
        XCTAssertFalse(fresh.isVisible("7"))
    }

    @MainActor
    func testOnlySiloKeepsTheFirstSeenOrder() throws {
        let siloKey = layoutKey()
        let embyKey = layoutKey()
        defer {
            SharedDefaults.shared.removeObject(forKey: siloKey)
            SharedDefaults.shared.removeObject(forKey: embyKey)
        }
        let a = try oneItemRow("a")
        let b = try oneItemRow("b")
        let c = try oneItemRow("c")

        let silo = makeLayoutStore(key: siloKey)
        silo.enforceVisibleRowLimit(in: [a, b, c], provider: .silo)
        let reordered = [try oneItemRow("new"), c, a, b]
        silo.enforceVisibleRowLimit(in: reordered, provider: .silo)
        XCTAssertEqual(silo.arrangedSections(reordered).map(\.id), ["a", "b", "c", "new"])

        let emby = makeLayoutStore(key: embyKey)
        emby.enforceVisibleRowLimit(in: [a, b, c], provider: .emby)
        XCTAssertEqual(emby.arrangedSections([c, a, b]).map(\.id), ["c", "a", "b"])
    }

    @MainActor
    func testUnchangedLayoutWritesIdenticalBytesAndKeepsOutsideChanges() throws {
        let key = layoutKey()
        let sharedKey = layoutKey()
        defer {
            SharedDefaults.shared.removeObject(forKey: key)
            SharedDefaults.shared.removeObject(forKey: sharedKey)
        }
        let nine = try (1...9).map { try oneItemRow("row-\($0)") }

        makeLayoutStore(key: key).enforceVisibleRowLimit(in: nine)
        let firstBytes = try XCTUnwrap(SharedDefaults.shared.data(forKey: key))
        SharedDefaults.shared.removeObject(forKey: key)
        makeLayoutStore(key: key).enforceVisibleRowLimit(in: nine)
        XCTAssertEqual(SharedDefaults.shared.data(forKey: key), firstBytes)

        let store = makeLayoutStore(key: sharedKey)
        store.enforceVisibleRowLimit(in: nine)
        var edited = try storedJSON(sharedKey)
        edited["combineEmbyNextUp"] = true
        SharedDefaults.shared.set(try JSONSerialization.data(withJSONObject: edited), forKey: sharedKey)

        store.enforceVisibleRowLimit(in: nine + [try oneItemRow("new")])
        let saved = try storedJSON(sharedKey)
        XCTAssertEqual(saved["combineEmbyNextUp"] as? Bool, true)
        XCTAssertTrue(store.combineEmbyNextUp)
        XCTAssertTrue((saved["seenSectionIds"] as? [String])?.contains("new") == true)
    }

    @MainActor
    func testLayoutSavedBeforeSeenRowsResetsItsHiddenRowsOnce() throws {
        let server = "test-server-\(UUID().uuidString)"
        let key = "tvos.homeSections.v1.\(server).profile"
        defer { SharedDefaults.shared.removeObject(forKey: key) }
        let stored = #"{"orderedSectionIds":["b","a"],"hiddenSectionIds":["a","c","d"],"combineEmbyNextUp":true}"#
        SharedDefaults.shared.set(Data(stored.utf8), forKey: key)

        XCTAssertEqual(HomeSectionPreferences.hiddenSections(server: server, profile: "profile"), [])
        let store = makeLayoutStore(key: key)
        XCTAssertEqual(store.hiddenSectionIds, [])
        XCTAssertEqual(store.orderedSectionIds, ["b", "a"])
        XCTAssertTrue(store.combineEmbyNextUp)

        let rows = try ["a", "b", "c", "d", "e", "f", "g", "h"].map(oneItemRow)
        store.enforceVisibleRowLimit(in: rows)
        XCTAssertEqual(store.arrangedSections(rows).map(\.id), ["b", "a", "c", "d", "e", "f"])
        XCTAssertFalse(store.isVisible("g"))
        XCTAssertFalse(store.isVisible("h"))

        store.setVisible(false, sectionId: "c")
        let reopened = makeLayoutStore(key: key)
        reopened.enforceVisibleRowLimit(in: rows)
        XCTAssertEqual(reopened.hiddenSectionIds, ["c", "g", "h"])
        XCTAssertEqual(reopened.arrangedSections(rows).map(\.id), ["b", "a", "d", "e", "f"])
        XCTAssertEqual(HomeSectionPreferences.hiddenSections(server: server, profile: "profile"), ["c", "g", "h"])
        XCTAssertTrue(reopened.combineEmbyNextUp)
    }

    // MARK: Combining Continue Watching and Next Up

    func testSpotlightInterleavesWhileHomeKeepsResumeItemsFirst() throws {
        let resume = try (0..<12).map { try makeItem("resume-\($0)") }
        let nextUp = try (0..<12).map { try makeItem("next-\($0)", progressUpdatedAt: nil) }
        let rows = [
            makeRow("resume", type: "continue_watching", total: 12, items: resume),
            makeRow("next", type: "next_up", total: 12, items: nextUp),
        ]

        for provider in [MediaServerProvider.jellyfin, .emby] {
            let spotlight = TVHomeSpotlightPreferences.projectedSources(rows, combined: true, provider: provider)
            XCTAssertEqual(spotlight.map(\.id), ["resume"])
            XCTAssertEqual(
                spotlight.first?.items.prefix(4).map(\.contentId),
                ["resume-0", "next-0", "resume-1", "next-1"]
            )
            let home = HomeSectionPreferences.combinedSections(rows, enabled: true, provider: provider)
            XCTAssertEqual(home.first?.items.dropFirst().first?.contentId, "resume-1")
            XCTAssertEqual(TVHomeSpotlightPreferences.projectedSources(rows, combined: false, provider: provider), rows)
        }
        XCTAssertEqual(TVHomeSpotlightPreferences.projectedSources(rows, combined: true, provider: .silo), rows)
    }

    func testEmbyMergesNextUpIntoContinueWatching() throws {
        try assertMergesDuplicateEpisode(provider: .emby)
    }

    func testJellyfinMergesNextUpIntoContinueWatching() throws {
        try assertMergesDuplicateEpisode(provider: .jellyfin)
    }

    private func assertMergesDuplicateEpisode(provider: MediaServerProvider) throws {
        let rows = [
            makeRow("resume", type: "continue_watching", total: 1, items: [try makeItem("episode")]),
            makeRow("next-up", type: "next_up", total: 2, items: [
                try makeItem("episode", progressUpdatedAt: nil),
                try makeItem("next", progressUpdatedAt: nil),
            ]),
        ]
        let combined = HomeSectionPreferences.combinedSections(rows, enabled: true, provider: provider)
        XCTAssertEqual(combined.count, 1)
        let row = try XCTUnwrap(combined.first)
        XCTAssertEqual(row.id, "resume")
        XCTAssertEqual(row.title, "Continue Watching")
        XCTAssertEqual(row.items.map(\.contentId), ["episode", "next"])
        XCTAssertEqual(row.items.first?.progressUpdatedAt, Self.progressStamp)
    }

    func testCombinedRowTakesTheFirstResumeRowsPlace() throws {
        let rows = [
            makeRow("next", type: "next_up", total: 1, items: [try makeItem("next-episode", progressUpdatedAt: nil)]),
            makeRow("latest", type: "latest", total: 1, items: [try makeItem("movie")]),
            makeRow("resume", type: "continue_watching", total: 1, items: [try makeItem("resume-episode")]),
        ]
        let combined = HomeSectionPreferences.combinedSections(rows, enabled: true, provider: .emby)
        XCTAssertEqual(combined.map(\.id), ["latest", "resume"])
        XCTAssertEqual(combined.last?.items.map(\.contentId), ["resume-episode", "next-episode"])
    }

    func testCombiningIsOffForSiloAndWhenDisabled() throws {
        let rows = [makeRow("next", type: "next_up", total: 1, items: [try makeItem("next-episode", progressUpdatedAt: nil)])]
        XCTAssertEqual(HomeSectionPreferences.combinedSections(rows, enabled: true, provider: .silo), rows)
        XCTAssertEqual(HomeSectionPreferences.combinedSections(rows, enabled: false, provider: .emby), rows)
        XCTAssertEqual(HomeSectionPreferences.combinedSections(rows, enabled: false, provider: .jellyfin), rows)
    }

    func testNextUpAloneBecomesContinueWatching() throws {
        let rows = [makeRow("next", type: "next_up", total: 1, items: [try makeItem("next-episode", progressUpdatedAt: nil)])]
        let combined = HomeSectionPreferences.combinedSections(rows, enabled: true, provider: .emby)
        let row = try XCTUnwrap(combined.first)
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(row.id, "continue_watching")
        XCTAssertEqual(row.sectionType, "continue_watching")
        XCTAssertEqual(row.title, "Continue Watching")
        XCTAssertEqual(row.items.count, 1)
    }

    // MARK: Model refresh

    @MainActor
    func testJellyfinReloadsOnEveryEntry() async throws {
        ResponseCache.shared.remove(CacheKey.homeSections)
        var requests = 0
        let model = HomeViewModel(fetchHomeSections: {
            requests += 1
            return SectionsResponse(sections: [])
        })

        await model.refreshForHomeEntry(sinceLastHidden: nil, provider: .jellyfin)
        await model.refreshForHomeEntry(sinceLastHidden: Date().addingTimeInterval(-1), provider: .jellyfin)
        XCTAssertEqual(requests, 2)

        XCTAssertEqual(HomeViewModel.televisionRefreshInterval(provider: .jellyfin), .seconds(10))
        XCTAssertEqual(HomeViewModel.televisionRefreshInterval(provider: .silo), .seconds(1_800))
        XCTAssertNil(HomeViewModel.televisionRefreshInterval(provider: .emby))
    }

    @MainActor
    func testCachedRowsShowAtOnceAndReturnsWaitAMinute() async throws {
        let row = makeRow("latest", type: "latest", total: 1, items: [try makeItem("movie")])
        prime([row])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        var requests = 0
        let model = HomeViewModel(fetchHomeSections: {
            requests += 1
            return SectionsResponse(sections: [row])
        })
        XCTAssertEqual(model.sections.map(\.id), ["latest"])
        XCTAssertFalse(model.isLoading)

        let now = Date()
        await model.refreshForHomeEntry(sinceLastHidden: nil, now: now, provider: .silo)
        XCTAssertEqual(requests, 1)
        await model.refreshForHomeEntry(sinceLastHidden: now.addingTimeInterval(-59), now: now, provider: .silo)
        XCTAssertEqual(requests, 1)
        await model.refreshForHomeEntry(sinceLastHidden: now.addingTimeInterval(-60), now: now, provider: .silo)
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testFetchedRowsReplaceCachedArtworkLinks() async throws {
        let oldPoster = "https://server.example/api/v2/artwork/poster?exp=100&sig=old"
        let newPoster = "https://server.example/api/v2/artwork/poster?exp=200&sig=new"
        prime([makeRow("latest", type: "latest", total: 1, items: [try makeItem("movie", posterUrl: oldPoster)])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let fresh = makeRow("latest", type: "latest", total: 1, items: [try makeItem("movie", posterUrl: newPoster)])
        let model = HomeViewModel(fetchHomeSections: { SectionsResponse(sections: [fresh]) })

        XCTAssertEqual(model.sections.first?.items.first?.posterUrl, oldPoster)
        await model.loadSections()
        XCTAssertEqual(model.sections.first?.items.first?.posterUrl, newPoster)

        let size = CGSize(width: 180, height: 270)
        XCTAssertNotEqual(
            PosterImageCache.displayRequest(url: try XCTUnwrap(URL(string: oldPoster)), pixelSize: size),
            PosterImageCache.displayRequest(url: try XCTUnwrap(URL(string: newPoster)), pixelSize: size)
        )
    }

    @MainActor
    func testPlaybackRefreshesWhileHiddenWaitForTheNextEntry() async throws {
        ResponseCache.shared.remove(CacheKey.homeSections)
        let original = makeRow("latest", type: "latest", total: 1, items: [try makeItem("original")])
        let updated = makeRow("latest", type: "latest", total: 1, items: [try makeItem("updated")])
        var requests = 0
        let model = HomeViewModel(fetchHomeSections: {
            requests += 1
            return SectionsResponse(sections: [requests == 1 ? original : updated])
        })

        await model.refreshForHomeEntry(sinceLastHidden: nil, provider: .silo)
        XCTAssertEqual(requests, 1)
        await model.refreshPlaybackSections(refreshImmediately: false)
        await model.refreshPlaybackSections(refreshImmediately: false)
        XCTAssertEqual(requests, 1)

        await model.refreshForHomeEntry(sinceLastHidden: Date(), provider: .silo)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.sections.first?.items.map(\.contentId), ["updated"])

        await model.refreshForHomeEntry(sinceLastHidden: Date(), provider: .silo)
        XCTAssertEqual(requests, 2)
    }

    // MARK: Row edits

    func testContinueWatchingRemovalLeavesOtherRowsAlone() throws {
        let target = try makeItem("target")
        let rows = [
            makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")]),
            makeRow("watchlist", type: "watchlist", total: 1, items: [target]),
        ]
        let edited = HomeSectionsMutation.removingContinueWatchingItem(contentId: "target", from: rows)
        XCTAssertEqual(edited[0].items.map(\.contentId), ["other"])
        XCTAssertEqual(edited[0].totalCount, 1)
        XCTAssertEqual(edited[1].items.map(\.contentId), ["target"])
        XCTAssertEqual(edited[1].totalCount, 1)
    }

    func testInProgressRowLosesTheItem() throws {
        let rows = [makeRow("progress", type: "in_progress", total: 1, items: [try makeItem("target")])]
        let edited = HomeSectionsMutation.removingContinueWatchingItem(contentId: "target", from: rows)
        XCTAssertEqual(edited[0].items, [])
        XCTAssertEqual(edited[0].totalCount, 0)
    }

    func testTotalCountNeverGoesBelowZero() throws {
        let rows = [makeRow("continue", type: "continue_watching", total: 0, items: [try makeItem("target")])]
        let edited = HomeSectionsMutation.removingContinueWatchingItem(contentId: "target", from: rows)
        XCTAssertEqual(edited[0].totalCount, 0)
    }

    func testUnknownItemChangesNothing() throws {
        let rows = [makeRow("continue", type: "continue_watching", total: 2, items: [try makeItem("a"), try makeItem("b")])]
        let edited = HomeSectionsMutation.removingContinueWatchingItem(contentId: "missing", from: rows)
        XCTAssertEqual(edited[0].items.map(\.contentId), ["a", "b"])
        XCTAssertEqual(edited[0].totalCount, 2)
    }

    func testCompletedItemLeavesResumeAndNextUpRowsOnly() throws {
        let target = try makeItem("target")
        let rows = [
            makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")]),
            makeRow("next", type: "next_up", total: 1, items: [target]),
            makeRow("trending", type: "trending", total: 1, items: [target]),
        ]
        let edited = HomeSectionsMutation.removingCompletedItem(contentId: "target", from: rows)
        XCTAssertEqual(edited.map { $0.items.map(\.contentId) }, [["other"], [], ["target"]])
        XCTAssertEqual(edited.map(\.totalCount), [1, 0, 1])
    }

    // MARK: Card actions

    @MainActor
    func testDismissingAStartedItemUpdatesRowsAndCache() async throws {
        let target = try makeItem("target")
        prime([makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        var received: (contentId: String, stamp: String)?
        let model = HomeViewModel(
            dismissContinueWatching: { received = ($0, $1) },
            dismissNextUp: { _, _ in XCTFail("Next Up dismissal should not be sent") },
            fetchHomeSections: { throw StubFailure() }
        )

        await model.dismissContinueWatchingItem(target)
        XCTAssertEqual(received?.contentId, "target")
        XCTAssertEqual(received?.stamp, Self.progressStamp)
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["other"]])
        XCTAssertEqual(cachedItemIDs(), [["other"]])
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testDismissingANextUpCardUsesItsSeries() async throws {
        let target = try makeItem("target", progressUpdatedAt: nil, seriesId: "series-1")
        prime([
            makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")]),
            makeRow("next", type: "next_up", total: 1, items: [target]),
            makeRow("trending", type: "trending", total: 1, items: [target]),
        ])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        var received: (contentId: String, seriesId: String)?
        let model = HomeViewModel(
            dismissContinueWatching: { _, _ in XCTFail("Continue Watching dismissal should not be sent") },
            dismissNextUp: { received = ($0, $1) },
            fetchHomeSections: { throw StubFailure() }
        )

        await model.dismissContinueWatchingItem(target)
        XCTAssertEqual(received?.contentId, "target")
        XCTAssertEqual(received?.seriesId, "series-1")
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["other"], [], ["target"]])
        XCTAssertEqual(cachedItemIDs(), [["other"], [], ["target"]])
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testItemWithoutStampOrSeriesIsNotDismissed() async throws {
        let target = try makeItem("target", progressUpdatedAt: nil)
        prime([makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let model = HomeViewModel(
            dismissContinueWatching: { _, _ in XCTFail("Continue Watching dismissal should not be sent") },
            dismissNextUp: { _, _ in XCTFail("Next Up dismissal should not be sent") },
            fetchHomeSections: { throw StubFailure() }
        )

        await model.dismissContinueWatchingItem(target)
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["target", "other"]])
        XCTAssertEqual(cachedItemIDs(), [["target", "other"]])
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testFailedDismissalKeepsRowsAndShowsAnError() async throws {
        let target = try makeItem("target")
        prime([makeRow("continue", type: "continue_watching", total: 2, items: [target, try makeItem("other")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let model = HomeViewModel(
            dismissContinueWatching: { _, _ in throw StubFailure() },
            fetchHomeSections: { throw StubFailure() }
        )

        await model.dismissContinueWatchingItem(target)
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["target", "other"]])
        XCTAssertEqual(cachedItemIDs(), [["target", "other"]])
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(model.isShowingActionError)
    }

    @MainActor
    func testWatchedItemLeavesNextUpEvenWhenTheRefreshFails() async throws {
        let target = try makeItem("target")
        prime([
            makeRow("next", type: "next_up", total: 2, items: [target, try makeItem("other")]),
            makeRow("trending", type: "trending", total: 1, items: [target]),
        ])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        var received: (contentId: String, played: Bool)?
        let model = HomeViewModel(
            setWatched: { received = ($0, $1) },
            fetchHomeSections: { throw StubFailure() }
        )

        let saved = await model.setWatched(target, played: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(received?.contentId, "target")
        XCTAssertEqual(received?.played, true)
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["other"], ["target"]])
        XCTAssertEqual(model.sections.first?.totalCount, 1)
        XCTAssertEqual(cachedItemIDs(), [["other"], ["target"]])
        XCTAssertEqual(
            ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self)?.sections.first?.totalCount, 1
        )
        XCTAssertNil(model.actionError)
    }

    @MainActor
    func testFailedWatchedChangeKeepsRowsAndShowsAnError() async throws {
        let target = try makeItem("target")
        prime([makeRow("next", type: "next_up", total: 2, items: [target, try makeItem("other")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let model = HomeViewModel(
            setWatched: { _, _ in throw StubFailure() },
            fetchHomeSections: { throw StubFailure() }
        )

        let saved = await model.setWatched(target, played: true)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.sections.map { $0.items.map(\.contentId) }, [["target", "other"]])
        XCTAssertEqual(cachedItemIDs(), [["target", "other"]])
        XCTAssertNotNil(model.actionError)
        XCTAssertTrue(model.isShowingActionError)
    }

    @MainActor
    func testPlaybackWriteRefreshShowsTheNewPosition() async throws {
        for (contentId, position) in [("episode-one", 450.0), ("episode-two", 30.0)] {
            try await assertPlaybackWriteRefresh(contentId: contentId, position: position)
        }
    }

    @MainActor
    private func assertPlaybackWriteRefresh(contentId: String, position: Double) async throws {
        prime([makeRow("continue", type: "continue_watching", total: 1, items: [try makeItem("episode-one", type: "episode")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let fresh = makeRow("continue", type: "continue_watching", total: 1, items: [
            try makeItem(contentId, type: "episode", extra: [
                "title": "Synthetic episode",
                "positionSeconds": position,
                "durationSeconds": 1200,
            ]),
        ])
        let model = HomeViewModel(fetchHomeSections: { SectionsResponse(sections: [fresh]) })
        let refreshAfterWrite = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
        XCTAssertEqual(model.sections.first?.items.first?.contentId, "episode-one")
        XCTAssertNotNil(cachedItemIDs())

        let refreshed = expectation(description: "Home refreshed")
        refreshed.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .homeSectionsShouldRefresh, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                XCTAssertNil(ResponseCache.shared.get(CacheKey.homeSections, as: SectionsResponse.self))
                Task { @MainActor in
                    await model.refreshPlaybackSections()
                    refreshed.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        refreshAfterWrite()
        await fulfillment(of: [refreshed], timeout: 2)
        let first = model.sections.first?.items.first
        XCTAssertEqual(first?.contentId, contentId)
        XCTAssertEqual(first?.positionSeconds, position)
    }

    @MainActor
    func testPlaybackWriteFromAnotherProfileChangesNothing() async throws {
        let refreshAfterWrite = StartupContentPrefetcher.homeRefreshAfterPlaybackWrite()
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        prime([makeRow("continue", type: "continue_watching", total: 1, items: [try makeItem("episode-one", type: "episode")])])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }
        let posted = expectation(forNotification: .homeSectionsShouldRefresh, object: nil)
        posted.isInverted = true

        refreshAfterWrite()
        await fulfillment(of: [posted], timeout: 0.2)
        XCTAssertEqual(cachedItemIDs(), [["episode-one"]])
    }

    @MainActor
    func testWatchRefreshDuringAnOlderFetchKeepsTheNewState() async throws {
        for played in [true, false] {
            try await assertRefreshDuringOlderFetch(played: played)
        }
    }

    @MainActor
    private func assertRefreshDuringOlderFetch(played: Bool) async throws {
        let stale = makeRow("movies", type: "recently_added", total: 1, items: [try watchedMovie(played: !played)])
        let fresh = makeRow("movies", type: "recently_added", total: 1, items: [try watchedMovie(played: played)])
        prime([stale])
        defer { ResponseCache.shared.remove(CacheKey.homeSections) }

        var requests = 0
        var heldFetch: CheckedContinuation<SectionsResponse, Never>?
        let started = expectation(description: "first fetch started")
        let model = HomeViewModel(fetchHomeSections: {
            requests += 1
            guard requests == 1 else { return SectionsResponse(sections: [fresh]) }
            return await withCheckedContinuation { continuation in
                heldFetch = continuation
                started.fulfill()
            }
        })

        let load = Task { await model.loadSections() }
        await fulfillment(of: [started], timeout: 2)
        await model.refreshPlaybackSections()
        await model.refreshPlaybackSections()
        heldFetch?.resume(returning: SectionsResponse(sections: [stale]))
        await load.value

        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.sections.first?.items.first?.userState?.played, played)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isRefreshing)
    }

    private func watchedMovie(played: Bool) throws -> SectionItem {
        let state = MediaItemUserState(played: played, isFavorite: false, inWatchlist: false)
        let stateJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        return try makeItem("target", extra: ["title": "Test", "userState": stateJSON])
    }
}
