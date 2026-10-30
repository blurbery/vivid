import XCTest
@testable import Vivid

/// The iPhone and iPad detail sheet, its own stack and the players it opens.
@MainActor
final class AppRouterNavigationTests: XCTestCase {
    func testSignInChangesCloseTheDetail() {
        for state in [AppRouter.AuthState.needsLogin, .needsServerSetup, .needsProfile] {
            let router = AppRouter()
            router.authState = .authenticated
            router.presentItemDetail(contentId: "movie")
            router.itemDetailPath.append("nested-detail")
            router.authState = state
            XCTAssertNil(router.presentedItemDetail, "\(state)")
            XCTAssertTrue(router.itemDetailPath.isEmpty, "\(state)")
            XCTAssertFalse(router.isItemDetailPresentationActive, "\(state)")
            router.resetToHome()
            XCTAssertFalse(router.isItemDetailPresentationActive, "\(state)")
        }
    }

    func testReassigningTheSameStateKeepsTheDetail() throws {
        let router = AppRouter()
        router.authState = .authenticated
        let detail = try open("movie", in: router)
        router.authState = .authenticated
        XCTAssertEqual(router.presentedItemDetail?.id, detail.id)
        XCTAssertTrue(router.isItemDetailPresentationActive)
    }

    func testActiveFlagLastsUntilTheSheetHasGone() throws {
        let router = AppRouter()
        try open("first", in: router)
        router.dismissItemDetail()
        XCTAssertTrue(router.isItemDetailPresentationActive)
        router.itemDetailPresentationDidDismiss()
        XCTAssertFalse(router.isItemDetailPresentationActive)

        router.presentItemDetail(contentId: "second")
        router.itemDetailPresentationDidDismiss()
        XCTAssertEqual(router.presentedItemDetail?.contentId, "second")
        XCTAssertTrue(router.isItemDetailPresentationActive)
    }

    func testPlayerFromARootDetailBelongsToThatDetail() throws {
        let router = AppRouter()
        let detail = try open("search-result", in: router)
        XCTAssertTrue(router.path.isEmpty)

        router.presentPlayer(contentId: "search-result")
        let player = try XCTUnwrap(router.playerPresentation(forDetailID: detail.id))
        XCTAssertNil(router.playerPresentation(forDetailID: nil))
        XCTAssertEqual(router.presentedItemDetail, detail)

        router.dismissPlayerPresentation(id: player.id)
        XCTAssertNil(router.presentedPlayer)
        XCTAssertEqual(router.presentedItemDetail, detail)

        close(router)
        XCTAssertNil(router.presentedPlayer)
        XCTAssertTrue(router.path.isEmpty)
    }

    func testContinueWatchingEpisodeOpensItsSeries() throws {
        let router = AppRouter()
        let card = try sectionItem("""
        {"contentId": "episode-s3e2", "type": "episode", "title": "The Episode", "seriesId": "series",
         "seriesTitle": "The Series", "seasonNumber": 3, "episodeNumber": 2,
         "positionSeconds": 450, "durationSeconds": 2700}
        """)
        router.presentContinueWatchingDetail(for: card)
        let detail = try XCTUnwrap(router.presentedItemDetail)
        XCTAssertEqual(detail.contentId, "series")
        XCTAssertEqual(detail.resumeContext?.episodeContentId, "episode-s3e2")
        XCTAssertEqual(detail.resumeContext?.seasonNumber, 3)
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertNil(router.presentedPlayer)

        close(router)
        let plain = try open("series", in: router)
        XCTAssertEqual(plain.contentId, "series")
        XCTAssertNil(plain.resumeContext)
    }

    func testContinueWatchingWithoutAUsableSeriesOpensTheCard() throws {
        let cards = [
            #"{"contentId": "movie", "type": "movie", "title": "Movie"}"#,
            #"{"contentId": "episode", "type": "episode", "title": "Episode", "seriesId": "   "}"#,
            #"{"contentId": "unknown", "type": "document", "title": "Document"}"#,
        ]
        let router = AppRouter()
        for json in cards {
            let card = try sectionItem(json)
            router.presentContinueWatchingDetail(for: card)
            XCTAssertEqual(router.presentedItemDetail?.contentId, card.contentId)
            XCTAssertNil(router.presentedItemDetail?.resumeContext)
            close(router)
        }
    }

    func testPlayerInsideANestedDetailPageHasOneOwner() throws {
        let router = AppRouter()
        let detail = try seriesWithPersonPage(router)
        router.presentItemDetail(contentId: "movie")

        router.presentPlayer(contentId: "movie")
        let player = try XCTUnwrap(router.playerPresentation(forDetailID: detail.id))
        XCTAssertNil(router.playerPresentation(forDetailID: nil))
        XCTAssertNil(router.playerPresentation(forDetailID: UUID()))

        router.dismissPlayerPresentation(id: player.id)
        XCTAssertEqual(router.presentedItemDetail, detail)
        XCTAssertEqual(router.presentedItemDetail?.contentId, "series")
        XCTAssertEqual(router.itemDetailPath.count, 2)
    }

    func testRootPlayerHasNoOwner() throws {
        let router = AppRouter()
        router.presentPlayer(contentId: "movie")
        let player = try XCTUnwrap(router.playerPresentation(forDetailID: nil))
        XCTAssertNil(player.detailPresentationID)
        router.dismissPlayerPresentation(id: player.id)
        XCTAssertNil(router.presentedItemDetail)
        XCTAssertTrue(router.itemDetailPath.isEmpty)
    }

    func testOfflinePlayerKeepsItsOwner() throws {
        let router = AppRouter()
        let detail = try open("movie", in: router)
        router.presentOfflinePlayer(downloadId: "download", contentId: "movie")
        let player = try XCTUnwrap(router.presentedPlayer)
        XCTAssertEqual(player.detailPresentationID, detail.id)
        XCTAssertEqual(player.offlineDownloadId, "download")
        router.dismissPlayerPresentation(id: player.id)
        XCTAssertEqual(router.presentedItemDetail, detail)
    }

    func testOlderPlayerCannotCloseANewerOne() throws {
        let router = AppRouter()
        router.presentPlayer(contentId: "first")
        let first = try XCTUnwrap(router.presentedPlayer)
        router.presentPlayer(contentId: "second")
        router.dismissPlayerPresentation(id: first.id)
        XCTAssertEqual(router.presentedPlayer?.contentId, "second")
    }

    func testReopenedPlayerKeepsEverythingButItsID() throws {
        let router = AppRouter()
        try open("series", in: router)
        router.presentPlayer(contentId: "episode", fileId: 7, audioTrackIndex: 2, subtitleTrackIndex: 3, resumePosition: 120)
        let player = try XCTUnwrap(router.presentedPlayer)
        let reopened = player.reopened()
        XCTAssertNotEqual(reopened.id, player.id)
        XCTAssertEqual(reopened.detailPresentationID, player.detailPresentationID)
        XCTAssertEqual(reopened.contentId, "episode")
        XCTAssertEqual(reopened.fileId, 7)
        XCTAssertEqual(reopened.audioTrackIndex, 2)
        XCTAssertEqual(reopened.subtitleTrackIndex, 3)
        XCTAssertEqual(reopened.resumePosition, 120)
    }

    func testBackInsideTheSheetNeverClosesIt() throws {
        let router = AppRouter()
        let detail = try open("series", in: router)
        router.presentItemDetail(contentId: "episode")
        router.navigate(to: .personDetail(personId: 42))

        router.goBackInItemDetail()
        XCTAssertEqual(router.itemDetailPath.count, 1)
        XCTAssertEqual(router.presentedItemDetail, detail)
        router.goBackInItemDetail()
        router.goBackInItemDetail()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
        XCTAssertEqual(router.presentedItemDetail, detail)
    }

    func testLateDismissalReportChangesNothing() throws {
        let router = AppRouter()
        let detail = try seriesWithPersonPage(router)
        router.presentPlayer(contentId: "episode")
        let player = try XCTUnwrap(router.presentedPlayer)

        router.itemDetailPresentationDidDismiss()
        XCTAssertEqual(router.presentedItemDetail, detail)
        XCTAssertEqual(router.presentedPlayer, player)
        XCTAssertEqual(router.itemDetailPath.count, 1)
    }

    func testDismissalReportEmptiesTheSheetStackOnceTheDetailIsGone() throws {
        let router = AppRouter()
        try seriesWithPersonPage(router)
        router.presentedItemDetail = nil
        router.itemDetailPresentationDidDismiss()
        XCTAssertTrue(router.itemDetailPath.isEmpty)
    }

    /// Opens a detail sheet and returns it.
    @discardableResult
    private func open(_ contentId: String, in router: AppRouter) throws -> AppRouter.ItemDetailPresentation {
        router.presentItemDetail(contentId: contentId)
        return try XCTUnwrap(router.presentedItemDetail)
    }

    /// Closes the sheet the way it closes on screen: the close call, then
    /// the cover's report once it has gone.
    private func close(_ router: AppRouter) {
        router.dismissItemDetail()
        router.itemDetailPresentationDidDismiss()
    }

    /// A series sheet with a person page pushed inside it.
    @discardableResult
    private func seriesWithPersonPage(_ router: AppRouter) throws -> AppRouter.ItemDetailPresentation {
        let detail = try open("series", in: router)
        router.navigate(to: .personDetail(personId: 42))
        return detail
    }

    private func sectionItem(_ json: String) throws -> SectionItem {
        try JSONDecoder().decode(SectionItem.self, from: Data(json.utf8))
    }
}
