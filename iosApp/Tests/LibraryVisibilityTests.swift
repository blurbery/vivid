import Foundation
import XCTest
@testable import Vivid

final class LibraryVisibilityTests: XCTestCase {
    func testLibrariesResponseOnlyIncludesSupportedAppleLibraryTypes() throws {
        let json = """
        [
          { "id": 1, "name": "Movies", "type": "movies" },
          { "id": 2, "name": "Series", "type": "series" },
          { "id": 3, "name": "Music", "type": "music" },
          { "id": 4, "name": "Documents", "type": "documents" },
          { "id": 5, "name": "Photos", "type": "photos" },
          { "id": 6, "name": "Podcasts", "type": "podcasts" },
          { "id": 7, "name": "Mixed Media", "type": "mixed" }
        ]
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(LibrariesResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.libraries.map(\.id), [1, 2, 7])
    }

    func testSectionsResponseStripsItemsFromUnsupportedLibraryTypes() throws {
        let json = """
        {
          "sections": [
            {
              "id": "continue",
              "section_type": "continue_watching",
              "title": "Continue Watching",
              "items": [
                { "content_id": "m1", "type": "movie", "title": "A Movie" },
                { "content_id": "d1", "type": "document", "title": "A Document" },
                { "content_id": "ep1", "type": "episode", "title": "An Episode" },
                { "content_id": "p1", "type": "photo", "title": "A Photo" },
                { "content_id": "mu1", "type": "music", "title": "An Album" }
              ]
            },
            {
              "id": "unsupported-recent",
              "section_type": "recently_added",
              "title": "Recently Added Unsupported Media",
              "items": [
                { "content_id": "g1", "type": "game", "title": "A Game" }
              ]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(SectionsResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.sections.map(\.id), ["continue", "unsupported-recent"])
        XCTAssertEqual(response.sections[0].items.map(\.contentId), ["m1", "ep1"])
        XCTAssertTrue(response.sections[1].items.isEmpty)
    }

    func testSectionsResponseMemberwiseInitAlsoStripsUnsupportedItems() throws {
        let itemJson = """
        { "content_id": "d1", "type": "document", "title": "A Document" }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(SectionItem.self, from: Data(itemJson.utf8))

        let response = SectionsResponse(sections: [
            ResolvedSection(
                id: "discover_0_similar",
                sectionType: "similar",
                title: "Because You Watched",
                featured: false,
                itemLimit: 1,
                totalCount: 1,
                isCustom: false,
                customized: false,
                items: [item]
            )
        ])

        XCTAssertTrue(response.sections[0].items.isEmpty)
    }
}
