import XCTest
@testable import Vivid

/// Browse works out a library's kind from what it's given, or from the
/// cached library list, without going to the network.
@MainActor
final class BrowseLibraryModelTests: XCTestCase {
    override func tearDown() {
        ResponseCache.shared.remove(CacheKey.userLibraries)
        super.tearDown()
    }

    func testGivenLibraryTypeSetsTheMediaType() async {
        let model = BrowseView.Model()
        await model.configure(libraryId: 8, libraryType: "mixed")
        XCTAssertEqual(model.mediaType, .mixed)
    }

    func testCachedLibraryListSetsTheMediaType() async {
        let library = Library(id: 8, name: "Mixed Media", type: "mixed", sortOrder: nil, posterUrl: nil)
        ResponseCache.shared.set(LibrariesResponse(libraries: [library]), for: CacheKey.userLibraries)
        let model = BrowseView.Model()
        await model.configure(libraryId: 8)
        XCTAssertEqual(model.mediaType, .mixed)
    }
}
