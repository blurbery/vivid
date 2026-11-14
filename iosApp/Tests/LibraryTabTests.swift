import XCTest
@testable import Vivid

final class LibraryTabTests: XCTestCase {
    private static func library(_ id: Int, _ name: String, type: String = "movies", sortOrder: Int? = nil) -> Library {
        Library(id: id, name: name, type: type, sortOrder: sortOrder, posterUrl: nil)
    }

    // MARK: Tab bar

    func testLibraryTakesThePlaceOfTheFirstSavedLibraryTab() {
        let homeFirst: [PrimaryMenuItem] = [.builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou)]
        XCTAssertEqual(tvTabBarLibraryAnchor(in: homeFirst), .builtin(.movies))
        XCTAssertFalse(tvTabBarLibraryLeadsHome(in: homeFirst))
        XCTAssertEqual(libraryMainTabDestinations(menuItems: homeFirst).map(\.id), [.app(.home), .app(.libraries)])

        let libraryFirst: [PrimaryMenuItem] = [.builtin(.forYou), .builtin(.home), .builtin(.movies)]
        XCTAssertEqual(tvTabBarLibraryAnchor(in: libraryFirst), .builtin(.forYou))
        XCTAssertTrue(tvTabBarLibraryLeadsHome(in: libraryFirst))
        XCTAssertEqual(libraryMainTabDestinations(menuItems: libraryFirst).map(\.id), [.app(.libraries), .app(.home)])
    }

    func testLibraryIsOfferedWhenTheMenuHoldsOnlyHome() {
        let homeOnly: [PrimaryMenuItem] = [.builtin(.home)]
        XCTAssertNil(tvTabBarLibraryAnchor(in: homeOnly))
        XCTAssertEqual(libraryMainTabDestinations(menuItems: homeOnly).map(\.id), [.app(.home), .app(.libraries)])
    }

    func testMovingLibraryKeepsTheOtherSavedTabsInOrder() {
        let saved: [PrimaryMenuItem] = [.builtin(.movies), .builtin(.home), .builtin(.series), .builtin(.forYou)]
        XCTAssertEqual(tabBarMenu(saved, libraryLeads: false),
                       [.builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou)])
        XCTAssertEqual(tabBarMenu(saved, libraryLeads: true),
                       [.builtin(.movies), .builtin(.series), .builtin(.forYou), .builtin(.home)])
        XCTAssertTrue(PrimaryMenuPreference(items: tabBarMenu(saved, libraryLeads: true)).isValid)
    }

    // MARK: Library row

    func testBrowsableLibrariesFollowTheServerOrder() {
        let libraries = [
            Self.library(3, "Music", type: "music", sortOrder: 0),
            Self.library(9, "Series", type: "series"),
            Self.library(4, "Movies", sortOrder: 2),
            Self.library(2, "Mixed", type: "mixed", sortOrder: 1),
            Self.library(5, "Kids", type: "movie"),
        ]
        XCTAssertEqual(LibraryRowOrderStore.browsable(libraries).map(\.id), [2, 4, 5, 9])
    }

    func testArrangedLibrariesPutUnplacedOnesLast() {
        let libraries = [Self.library(1, "A"), Self.library(2, "B"), Self.library(3, "C"), Self.library(4, "D")]
        XCTAssertEqual(LibraryRowOrderStore.arranged(libraries, saved: []).map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(LibraryRowOrderStore.arranged(libraries, saved: [3, 1]).map(\.id), [3, 1, 2, 4])
        // A saved library the profile can no longer see is skipped.
        XCTAssertEqual(LibraryRowOrderStore.arranged(libraries, saved: [9, 4, 2]).map(\.id), [4, 2, 1, 3])
    }

    func testOrderKeyIsPerServerAndProfile() {
        XCTAssertEqual(LibraryRowOrderStore.defaultsKey(serverId: "server", profileId: "profile"),
                       "vivid.libraryRowOrder.v1.server.profile")
    }

    // MARK: A to Z

    func testNamesFileUnderTheirSortLetter() {
        XCTAssertTrue(TitleSortOrder.name("The Matrix Collection", startsWith: "M"))
        XCTAssertFalse(TitleSortOrder.name("The Matrix Collection", startsWith: "T"))
        XCTAssertTrue(TitleSortOrder.name("\u{00C9}pop\u{00E9}e", startsWith: "E"))
        XCTAssertTrue(TitleSortOrder.name("alien", startsWith: "A"))
        XCTAssertTrue(TitleSortOrder.name("007", startsWith: "#"))
        XCTAssertFalse(TitleSortOrder.name("007", startsWith: "A"))
        XCTAssertFalse(TitleSortOrder.name("Alien", startsWith: "#"))
    }
}
