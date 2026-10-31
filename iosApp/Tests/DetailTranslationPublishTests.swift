import XCTest
@testable import Vivid

/// A translated description re-fetched for a movie or episode keeps the
/// playback metadata the page already had, on screen and in the cache.
@MainActor
final class DetailTranslationPublishTests: XCTestCase {
    private let contentId = "translation-publish-movie"

    func testRefetchedMovieKeepsTheCachedPlaybackMetadata() throws {
        let cache = ResponseCache.shared
        defer {
            cache.remove(CacheKey.itemDetail(contentId))
            cache.remove(CacheKey.itemWatchDetail(contentId))
        }
        let snakeCase = JSONDecoder()
        snakeCase.keyDecodingStrategy = .convertFromSnakeCase
        let watch = try snakeCase.decode(WatchDetail.self, from: Data(#"""
            {"content_id":"translation-publish-movie","type":"movie","title":"Film",
             "versions":[{"file_id":7,"resolution":"1080p"}]}
            """#.utf8))
        cache.set(watch, for: CacheKey.itemWatchDetail(contentId))
        let translated = try JSONDecoder().decode(ItemDetail.self, from: Data(#"""
            {"contentId":"translation-publish-movie","type":"movie","title":"Film","overview":"Translated"}
            """#.utf8))

        let model = ItemDetailViewModel()
        model.publishRefetchedDetail(translated, contentId: contentId)

        XCTAssertEqual(model.detail?.overview, "Translated")
        XCTAssertEqual(model.detail?.versions?.map(\.fileId), [7])
        XCTAssertEqual(cache.get(CacheKey.itemDetail(contentId), as: ItemDetail.self)?.versions?.map(\.fileId), [7])
        XCTAssertNil(model.watchDetailFollowUp, "With a cached watch detail nothing is requested")
    }
}
