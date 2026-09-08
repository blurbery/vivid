import XCTest
@testable import Vivid

final class EmbyAdapterTests: XCTestCase {
    private var adapter: EmbyAdapter {
        EmbyAdapter(connection:EmbyConnection(serverURL:"https://media.example.test",token:nil,userID:"user-1",identity:nil))
    }

    func testServerAddressPreservesProxyPrefixAndAvoidsDuplicateAPIPrefix() throws {
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test:443/proxy",path:"/Users/AuthenticateByName").absoluteString,
                       "https://media.example.test:443/proxy/emby/Users/AuthenticateByName")
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test/emby/",path:"/System/Info/Public").path,"/emby/System/Info/Public")
        XCTAssertEqual(try EmbyConnection.url(serverURL:"https://media.example.test",path:"/Items",query:["SearchTerm":"a&b #c"]).query,"SearchTerm=a%26b%20%23c")
    }

    func testRejectsCredentialURLsAndPathInjection() {
        for base in ["file:///tmp/server", "https://user:password@media.example.test", "https://media.example.test?api_key=secret"] {
            XCTAssertThrowsError(try EmbyConnection.url(serverURL:base,path:"/Items"))
        }
        for path in ["//other.example.test/Items", "/../Users", "https://other.example.test/Items"] {
            XCTAssertThrowsError(try EmbyConnection.url(serverURL:"https://media.example.test",path:path))
        }
        for id in ["", "../1", "1?token=x", "1/2", "%2f"] { XCTAssertThrowsError(try EmbyConnection.id(id)) }
    }

    func testProviderNamespacesKeepExistingServerIdentity() {
        XCTAssertEqual(MediaServerProvider.forServerID("existing-id"),.silo)
        XCTAssertEqual(MediaServerProvider.forServerID("emby:existing-id"),.emby)
        XCTAssertEqual(EmbyAdapter.numberID("12345"),12345)
        XCTAssertEqual(EmbyAdapter.numberID("source-a"),EmbyAdapter.numberID("source-a"))
        XCTAssertNotEqual(EmbyAdapter.numberID("source-a"),EmbyAdapter.numberID("source-b"))
    }

    func testEpisodeMappingDecodesExistingScreensAndConvertsTicks() throws {
        let raw: [String:Any] = ["Id":"123", "Name":"Episode", "Type":"Episode", "SeriesId":"456", "SeriesName":"Series",
            "ParentIndexNumber":2,"IndexNumber":3,"RunTimeTicks":36_000_000_000 as Int64,
            "UserData":["PlaybackPositionTicks":900_000_000,"Played":false,"IsFavorite":true],
            "ImageTags":["Primary":"tag-a"],"MediaSources":[["Id":"source-a","Container":"mkv","RunTimeTicks":36_000_000_000 as Int64,
                "MediaStreams":[["Type":"Video","Index":0,"Codec":"hevc","Height":2160],
                                ["Type":"Audio","Index":2,"Codec":"aac","Language":"eng"],
                                ["Type":"Audio","Index":4,"Codec":"flac","Language":"eng"],
                                ["Type":"Subtitle","Index":6,"Codec":"srt","IsExternal":true]]]]]
        let mapped = try adapter.item(raw)
        let browse: BrowseItem = try EmbyAdapter.decode(mapped)
        let section: SectionItem = try EmbyAdapter.decode(mapped)
        let detail: ItemDetail = try EmbyAdapter.decode(mapped)
        let watch: WatchDetail = try EmbyAdapter.decode(mapped)
        let episode: EpisodeListItem = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(browse.runtime,60)
        XCTAssertEqual(section.positionSeconds,90)
        XCTAssertEqual(detail.seriesId,"456")
        XCTAssertEqual(episode.episodeNumber,3)
        XCTAssertEqual(watch.versions[0].audioTracks?.compactMap(\.index),[0,1])
        XCTAssertEqual(watch.versions[0].subtitleTracks?.first?.index,6)
        XCTAssertEqual(watch.versions[0].duration,3600)
        XCTAssertTrue(browse.userState?.isFavorite == true)
        XCTAssertFalse(browse.posterUrl?.contains("api_key") == true)
    }

    func testMinimalMovieAndSeasonHaveRequiredFields() throws {
        let movie = try adapter.item(["Id":"1","Name":"Movie","Type":"Movie"])
        let watch: WatchDetail = try EmbyAdapter.decode(movie)
        XCTAssertEqual(watch.versions.count,0)
        let season: Season = try EmbyAdapter.decode(adapter.item(["Id":"2","Name":"Specials","Type":"Season","IndexNumber":0,"RecursiveItemCount":4]))
        XCTAssertEqual(season.seasonNumber,0)
        XCTAssertEqual(season.episodeCount,4)
    }

    func testProgressTicksAreBounded() {
        XCTAssertEqual(EmbyPlayback.ticks(90.25),902_500_000)
        XCTAssertEqual(EmbyPlayback.ticks(-1),0)
        XCTAssertEqual(EmbyPlayback.ticks(.nan),0)
        XCTAssertEqual(EmbyPlayback.ticks(.infinity),0)
        XCTAssertEqual(EmbyPlayback.ticks(.greatestFiniteMagnitude),Int64.max)
    }

    func testUnsupportedServerFeatureDoesNotSendSiloRequest() async throws {
        do {
            _ = try await adapter.route(method:"POST",path:"/api/v1/playback/start",query:[:],body:[:])
            XCTFail("A Silo playback route must not reach Emby")
        } catch EmbyError.unsupportedFeature { }
    }
    func testSubtitleSettingsReachWatchAndSeriesOverridesWin() throws {
        let raw: [String:Any] = ["Id":"1","Name":"Movie","Type":"Movie"]
        let prefs: [String:Any] = ["playback.subtitle_language":"eng","playback.subtitle_mode":"always","playback.show_forced_subtitles":true]
        let watch: WatchDetail = try EmbyAdapter.decode(adapter.watch(raw,preferences:prefs))
        XCTAssertEqual(watch.effectiveSubtitleLanguage,"eng")
        XCTAssertEqual(watch.effectiveSubtitleMode,"always")
        XCTAssertEqual(watch.effectiveShowForcedSubtitles,true)
        let overridden: WatchDetail = try EmbyAdapter.decode(adapter.watch(raw,preferences:prefs,subtitle:["subtitle_mode":"off","show_forced_subtitles":false]))
        XCTAssertEqual(overridden.effectiveSubtitleMode,"off")
        XCTAssertEqual(overridden.effectiveShowForcedSubtitles,false)
    }

    func testSubtitlePreferencesPersistAndDeviceOverridesCanBeRemoved() async throws {
        let suite = "Vivid.EmbyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = EmbyLocalPreferences(defaults:defaults)
        let path = ["api","v1","settings","values","playback.subtitle_language"]
        _ = try await store.apply(storageKey:"account-a",user:"user",method:"PUT",path:path,query:["scope":"profile"],body:["value":"eng"])
        _ = try await store.apply(storageKey:"account-a",user:"user",method:"PUT",path:path,query:["scope":"profile_device"],body:["value":"fra"])
        let reopened = EmbyLocalPreferences(defaults:defaults)
        func effective(_ account: String) async throws -> String? {
            let result = try await reopened.apply(storageKey:account,user:"user",method:"GET",path:["effective"],query:["keys":"playback.subtitle_language"],body:[:]) as? [String:Any]
            return (result?["settings"] as? [[String:Any]])?.first?["value"] as? String
        }
        let device = try await effective("account-a")
        XCTAssertEqual(device,"fra")
        let otherAccount = try await effective("account-b")
        XCTAssertNil(otherAccount)
        _ = try await reopened.apply(storageKey:"account-a",user:"user",method:"DELETE",path:path,query:["scope":"profile_device"],body:[:])
        let inherited = try await effective("account-a")
        XCTAssertEqual(inherited,"eng")
    }

    func testQualityAndHDRPreferencesConstrainEmbyNegotiation() {
        let source: [String:Any] = ["MediaStreams":[["Type":"Video","Height":2160,"VideoRange":"HDR10"]]]
        var limited: [String:Any] = ["EnableDirectPlay":true,"DeviceProfile":["TranscodingProfiles":[["Type":"Video"]]]]
        EmbyPlayback.applyPlaybackLimits(to:&limited,source:source,quality:"720p",hdr:true,dolbyVision:true)
        XCTAssertEqual(limited["EnableDirectPlay"] as? Bool,false)
        XCTAssertEqual(limited["AllowVideoStreamCopy"] as? Bool,false)
        let profile = limited["DeviceProfile"] as? [String:Any]
        XCTAssertEqual((profile?["TranscodingProfiles"] as? [[String:Any]])?.first?["MaxHeight"] as? Int,720)
        var sdr: [String:Any] = ["EnableDirectPlay":true]
        EmbyPlayback.applyPlaybackLimits(to:&sdr,source:source,quality:"auto",hdr:false,dolbyVision:true)
        XCTAssertEqual(sdr["EnableDirectPlay"] as? Bool,false)
        var original: [String:Any] = ["EnableDirectPlay":true]
        EmbyPlayback.applyPlaybackLimits(to:&original,source:source,quality:"original",hdr:true,dolbyVision:true)
        XCTAssertEqual(original["EnableDirectPlay"] as? Bool,true)
    }

    func testHomeSectionPreservesServerIdentityAndTitle() throws {
        let mapped = adapter.homeSection(["Id":"custom-row","Name":"My chosen row","SectionType":"Resume"],catalog:["items":[],"total":0])
        let row: ResolvedSection = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(row.id,"custom-row")
        XCTAssertEqual(row.title,"My chosen row")
        XCTAssertEqual(row.sectionType,"continue_watching")
        XCTAssertTrue(row.items.isEmpty)
    }

    func testEmbyCollectionsBecomePosterCardsAndExcludeNavigationFolders() throws {
        XCTAssertNil(adapter.collection(["Id":"1","Name":"Movies","Type":"CollectionFolder"]))
        XCTAssertNil(adapter.collection(["Id":"2","Name":"Playlist","Type":"Playlist"]))
        let mapped = try XCTUnwrap(adapter.collection(["Id":"3","Name":"Film collection","Type":"BoxSet","ChildCount":4,"ImageTags":["Primary":"poster-tag"]]))
        let card: LibraryCollection = try EmbyAdapter.decode(mapped)
        XCTAssertEqual(card.id,"3")
        XCTAssertEqual(card.name,"Film collection")
        XCTAssertEqual(card.itemCount,4)
        XCTAssertEqual(card.kind,.regular)
        XCTAssertNotNil(card.posterUrl)
    }

    func testSeasonTabsExcludeEpisodeRecordsAndPreserveCounts() throws {
        let rows: [[String:Any]] = [
            ["Id":"season-4","Name":"Gone Tomorrow","Type":"Season","IndexNumber":4,"ChildCount":8],
            ["Id":"episode-1","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1],
            ["Id":"season-0","Name":"Behind the Scenes","Type":"Season","IndexNumber":0,"ChildCount":2]]
        let response: SeasonsResponse = try EmbyAdapter.decode(["seasons":adapter.seasonRows(rows)])
        XCTAssertEqual(response.seasons.map(\.contentId),["season-4","season-0"])
        XCTAssertEqual(response.seasons.map(\.title),["Season 4","Specials"])
        XCTAssertEqual(response.seasons.map(\.episodeCount),[8,2])
        XCTAssertEqual(response.seasons.last?.isSpecials,true)
    }

    func testCroppedVersionsUseDisplayResolutionClass() throws {
        for (width,height,expected) in [(3840,1606,"2160p"),(1920,802,"1080p"),(1280,534,"720p"),(1920,1080,"1080p")] {
            let raw: [String:Any] = ["Id":"source","MediaStreams":[["Type":"Video","Width":width,"Height":height]]]
            let version: FileVersion = try EmbyAdapter.decode(adapter.version(raw))
            XCTAssertEqual(version.resolution,expected)
            XCTAssertEqual(version.videoTracks?.first?.height,height)
            XCTAssertEqual(version.videoTracks?.first?.width,width)
        }
    }

    func testHomeUsesLegacyEndpointsBefore41004() {
        XCTAssertFalse(EmbyAdapter.usesServerHomeSections(version:"4.9.5.0"))
        XCTAssertFalse(EmbyAdapter.usesServerHomeSections(version:"4.10.0.3"))
        XCTAssertTrue(EmbyAdapter.usesServerHomeSections(version:"4.10.0.4"))
        XCTAssertTrue(EmbyAdapter.usesServerHomeSections(version:"4.11.0.0"))
    }

    func testLegacyHomePreservesConfiguredOrderAndDisabledRows() {
        let settings: [String:Any] = ["homesection0":"collections","homesection1":"nextup","homesection2":"resume","homesection3":"none","homesection4":"none","homesection5":"none","homesection6":"none"]
        XCTAssertEqual(EmbyAdapter.legacyHomeSectionTypes(settings:settings),["collections","nextup","resume"])
    }

}
