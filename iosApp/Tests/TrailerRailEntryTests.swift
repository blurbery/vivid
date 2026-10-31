import XCTest
@testable import Vivid

/// The trailer rail lists YouTube videos (when the app can open them) and
/// then the title's own extras, with stable ids, readable titles and the
/// YouTube links its cards use.
final class TrailerRailEntryTests: XCTestCase {
    private func video(_ key: String, kind: String = "trailer", site: String = "youtube", name: String? = nil) -> ItemVideo {
        ItemVideo(kind: kind, site: site, siteKey: key, name: name, isOfficial: true)
    }

    private func extra(_ id: String, kind: String = "featurette", title: String? = nil) -> ItemExtra {
        ItemExtra(contentId: id, kind: kind, title: title, durationSeconds: 120, fileId: 1)
    }

    func testVideosComeBeforeExtrasInServerOrder() {
        let entries = TrailerRail.entries(videos: [video("k1"), video("k2", kind: "teaser")],
                                          extras: [extra("extra:1"), extra("extra:2")], allowRemote: true)
        XCTAssertEqual(entries.map(\.id), ["remote:youtube:k1", "remote:youtube:k2", "local:extra:1", "local:extra:2"])
    }

    func testOnlyYouTubeVideosAreListed() {
        let entries = TrailerRail.entries(videos: [video("v1", site: "vimeo"), video("k1"), video("d1", site: "dailymotion")],
                                          extras: nil, allowRemote: true)
        XCTAssertEqual(entries.map(\.id), ["remote:youtube:k1"])
    }

    func testSiteMatchIgnoresCase() {
        XCTAssertEqual(TrailerRail.entries(videos: [video("k1", site: "YouTube")], extras: nil, allowRemote: true).count, 1)
    }

    func testWithoutRemoteOnlyExtrasAreListed() {
        let entries = TrailerRail.entries(videos: [video("k1"), video("k2")], extras: [extra("extra:1")], allowRemote: false)
        XCTAssertEqual(entries.map(\.id), ["local:extra:1"])
    }

    func testNothingInGivesNothingOut() {
        XCTAssertTrue(TrailerRail.entries(videos: nil, extras: nil, allowRemote: true).isEmpty)
        XCTAssertTrue(TrailerRail.entries(videos: [], extras: [], allowRemote: true).isEmpty)
    }

    func testAnExtraCannotShadowAVideoWithTheSameKey() {
        let entries = TrailerRail.entries(videos: [video("dup")], extras: [extra("dup")], allowRemote: true)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }

    func testTitlesComeFromTheItemElseItsKind() {
        let entries: [TrailerRailEntry] = [
            .remote(video("a", name: "Official Trailer")),
            .remote(video("b", kind: "behind_the_scenes")),
            .local(extra("c", title: "Making Of")),
            .local(extra("d", kind: "deleted_scene")),
        ]
        XCTAssertEqual(entries.map(\.title), ["Official Trailer", "Behind the Scenes", "Making Of", "Deleted Scene"])
    }

    func testBlankNameFallsBackToTheKind() {
        XCTAssertEqual(TrailerRailEntry.remote(video("a", kind: "clip", name: "   ")).title, "Clip")
    }

    func testEveryKnownKindHasALabel() {
        let kinds = ["trailer", "teaser", "featurette", "clip", "behind_the_scenes", "bloopers", "deleted_scene", "other"]
        XCTAssertEqual(kinds.map(ExtraKindLabels.label(for:)),
                       ["Trailer", "Teaser", "Featurette", "Clip", "Behind the Scenes", "Bloopers", "Deleted Scene", "Extra"])
    }

    func testUnlistedKindsReadExtra() {
        XCTAssertEqual(ExtraKindLabels.label(for: "opening_credits"), "Extra")
        XCTAssertEqual(ExtraKindLabels.label(for: ""), "Extra")
    }

    func testLinksForAPlainKey() {
        assertLinks(for: "tFMo3UJ4B4g")
    }

    func testLinksForAKeyWithPunctuation() {
        assertLinks(for: "a-B_c1D2e3F")
    }

    private func assertLinks(for key: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TrailerRail.thumbnailURL(siteKey: key)?.absoluteString,
                       "https://i.ytimg.com/vi/\(key)/hqdefault.jpg", file: file, line: line)
        XCTAssertEqual(TrailerRail.youtubeDeepLinkURL(siteKey: key)?.absoluteString,
                       "youtube://www.youtube.com/watch?v=\(key)", file: file, line: line)
        XCTAssertEqual(TrailerRail.youtubeWatchURL(siteKey: key)?.absoluteString,
                       "https://www.youtube.com/watch?v=\(key)", file: file, line: line)
    }
}
