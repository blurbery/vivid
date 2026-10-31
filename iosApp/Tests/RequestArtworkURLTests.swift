import XCTest
@testable import Vivid

final class RequestArtworkURLTests: XCTestCase {
    func testTMDbPathsGetTheirSize() {
        XCTAssertEqual(RequestArtworkURL.poster("/abc123.jpg"), "https://image.tmdb.org/t/p/w342/abc123.jpg")
        XCTAssertEqual(RequestArtworkURL.backdrop("/abc123.jpg"), "https://image.tmdb.org/t/p/w1280/abc123.jpg")
    }

    func testAbsoluteURLsAreKept() {
        XCTAssertEqual(RequestArtworkURL.poster("https://example.com/x.jpg"), "https://example.com/x.jpg")
    }

    func testMissingOrRelativePathsGiveNoURL() {
        XCTAssertNil(RequestArtworkURL.poster(nil))
        XCTAssertNil(RequestArtworkURL.poster(""))
        XCTAssertNil(RequestArtworkURL.poster("abc123.jpg"))
    }
}
