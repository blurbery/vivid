import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Subtitles Silo stores for a file (downloaded, uploaded or AI-made) are
/// offered like its subtitle files: as player rows fetched only when chosen,
/// in the detail menus, and as candidates for the automatic pick, with the
/// detail page and the player agreeing on which one Auto plays.
@MainActor
final class SiloStoredSubtitleTests: XCTestCase {
    private let request = StreamRequest(url: URL(string: "https://silo.example.test/stream/session-1")!,
                                        headers: ["Authorization": "Bearer test"], serverUrl: "https://silo.example.test")

    private func item(_ index: Int, source: String, codec: String = "srt", language: String = "en",
                      label: String? = nil, hearingImpaired: Bool = false, delivery: String = "sidecar",
                      storedID: Int? = nil) -> PlaybackV3SubtitleInventoryItem {
        let identity = storedID.map { "&downloaded_subtitle_id=\($0)" } ?? ""
        return PlaybackV3SubtitleInventoryItem(
            trackId: "file:42:subtitle:\(index)", combinedIndex: index, source: source, codec: codec,
            language: language, label: label, forced: false, default: false, hearingImpaired: hearingImpaired,
            delivery: delivery,
            url: delivery == "sidecar" ? "/stream/session-1/subtitles/\(index).vtt?file_id=42\(identity)" : nil,
            fontBundleUrl: nil)
    }

    private func catalogTrack(index: Int?, codec: String, language: String = "eng", external: Bool = false,
                              forced: Bool = false, title: String? = nil) -> SubtitleTrack {
        SubtitleTrack(index: index, codec: codec, language: language, title: title, embeddedTitle: nil,
                      forced: forced, hearingImpaired: false, isDefault: false, external: external,
                      externalPath: external ? "movie.\(language).\(codec)" : nil)
    }

    private func version(_ tracks: [SubtitleTrack]) -> FileVersion {
        FileVersion(fileId: 42, fileName: "movie.mkv", resolution: "1920x1080", codecVideo: "h264",
                    codecAudio: "aac", hdr: false, container: "mkv", fileSize: 1_000, duration: 120,
                    bitrate: 8_000_000, videoTracks: nil, audioTracks: nil, subtitleTracks: tracks, chapters: nil)
    }

    private func withPlayer(_ body: (PlayerViewModel) throws -> Void) async throws {
        let model = PlayerViewModel()
        var failure: Error?
        do { try body(model) } catch { failure = error }
        model.cleanup()
        await model.waitForCleanupCompletion()
        if let failure { throw failure }
    }

    // MARK: - Player rows

    func testPlayerOffersStoredTextSubtitlesAfterTheFilesOwnTracks() async throws {
        let inventory = [
            item(0, source: "external", label: "movie.en.srt"),
            item(1, source: "embedded", codec: "subrip"),
            item(2, source: "embedded", codec: "hdmv_pgs_subtitle"),
            item(3, source: "downloaded", label: "Movie.2020.WEB (opensubtitles)", storedID: 8),
            // A stored bitmap file has no sidecar Vivid can fetch.
            item(4, source: "downloaded", codec: "sub", delivery: "burn_in_only", storedID: 9),
            item(5, source: "downloaded", codec: "ass", language: "fr", label: "Film (subdl)", storedID: 12),
        ]
        try await withPlayer { model in
            for entry in inventory { model.offerSiloSidecar(entry, request: request, nativeApiMajor: nil) }
            XCTAssertEqual(Set(model.lazySubtitleSidecars.keys),
                           Set([0, 3, 5].map { SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0) }),
                           "external and stored text subtitles become rows; embedded and bitmap ones don't")
            let rows = PlayerViewModel.siloSidecarRows(model.lazySubtitleSidecars)
            XCTAssertEqual(rows.map(\.srcId), [0, 3, 5], "rows follow the combined index")
            XCTAssertEqual(rows[1].title, "Movie.2020.WEB (opensubtitles)")
            XCTAssertTrue(rows.allSatisfy(\.isExternal))
            let stored = model.lazySubtitleSidecars[SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)]
            XCTAssertEqual(stored.flatMap { ServerSubtitleSidecars.storedSubtitleID(in: $0.url) }, 8)
            XCTAssertEqual(ServerSubtitleSidecars.sidecarTrackID(storedSubtitleID: 12, in: model.lazySubtitleSidecars),
                           SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 5))
            XCTAssertNil(ServerSubtitleSidecars.sidecarTrackID(storedSubtitleID: 9, in: model.lazySubtitleSidecars))
            XCTAssertNil(model.lazySubtitleSidecars[SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0)]
                .flatMap { ServerSubtitleSidecars.storedSubtitleID(in: $0.url) }, "a file beside the media has no stored ID")
        }
    }

    func testStoredSubtitlePickStaysLocal() async throws {
        try await withPlayer { model in
            model.offerSiloSidecar(item(3, source: "downloaded", storedID: 8), request: request, nativeApiMajor: nil)
            model.selectedSubtitleId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
            model.hasExplicitSubtitleChoice = true
            XCTAssertNil(model.resolvedSidecarSubtitleTrackIdForResume())
            XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), -1)
        }
    }

    // MARK: - Subtitles Silo makes during playback

    func testSubtitleReadyEventOffersTheNewSubtitle() async throws {
        let json = """
        {"session_id": "session-1", "file_id": 42, "subtitle_id": 15, "language": "de", "label": "AI (de)",
         "track": {"track_id": "file:42:subtitle:6", "combined_index": 6, "source": "downloaded", "codec": "vtt",
                   "language": "de", "label": "AI (de)", "forced": false, "default": false,
                   "hearing_impaired": false, "delivery": "sidecar",
                   "url": "/stream/session-1/subtitles/6.vtt?file_id=42&downloaded_subtitle_id=15",
                   "sync_key": "stored:15"}}
        """
        let payload = try JSONDecoder().decode(PlaybackRealtimePayload.self, from: Data(json.utf8))
        XCTAssertNil(PlayerViewModel.readySiloSubtitle(payload, fileID: 7), "another file's subtitle is ignored")
        let ready = try XCTUnwrap(PlayerViewModel.readySiloSubtitle(payload, fileID: 42))
        XCTAssertEqual(ready.combinedIndex, 6)
        try await withPlayer { model in
            XCTAssertTrue(model.offerSiloSidecar(ready, request: request, nativeApiMajor: nil))
            let row = try XCTUnwrap(model.lazySubtitleSidecars[SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 6)])
            XCTAssertEqual(row.language, "de")
            XCTAssertEqual(ServerSubtitleSidecars.storedSubtitleID(in: row.url), 15)
            XCTAssertFalse(model.offerSiloSidecar(ready, request: request, nativeApiMajor: nil), "offered once")
        }
        let withoutTrack = try JSONDecoder().decode(PlaybackRealtimePayload.self,
            from: Data(#"{"session_id": "session-1", "file_id": 42, "subtitle_id": 15}"#.utf8))
        XCTAssertNil(PlayerViewModel.readySiloSubtitle(withoutTrack, fileID: 42), "an older Silo names no track")
    }

    // MARK: - Detail pages

    func testStoredListDecodesSiloV1AndV2IDs() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode(SiloStoredSubtitleList.self, from: Data("""
        {"subtitles": [
          {"id": 8, "provider": "opensubtitles", "language": "en", "format": "srt",
           "release_name": "Movie.2020.WEB", "hearing_impaired": true},
          {"id": "12", "media_file_id": "42", "provider": "", "language": "fr", "format": "ass", "release_name": ""}
        ]}
        """.utf8))
        XCTAssertEqual(list.subtitles.map(\.id), [8, 12])
        XCTAssertEqual(list.subtitles[0].planLabel, "Movie.2020.WEB (opensubtitles)")
        XCTAssertTrue(list.subtitles[0].hearingImpaired)
        XCTAssertEqual(list.subtitles[1].planLabel, "fr", "with no release or provider, Silo labels it by language")
    }

    func testDetailRowsFollowTheCatalogueAndNameTheirStoredSubtitle() {
        let catalog = [
            catalogTrack(index: 2, codec: "subrip"),
            catalogTrack(index: nil, codec: "srt", external: true),
        ]
        let stored = [
            SiloStoredSubtitle(id: 8, provider: "opensubtitles", language: "en", format: "srt", releaseName: "Movie"),
            SiloStoredSubtitle(id: 9, language: "en", format: "sub"),
            SiloStoredSubtitle(id: 12, language: "fr", format: "vtt"),
        ]
        let rows = ServerSubtitleSidecars.storedRows(stored, catalog: catalog)
        // Silo's combined index puts stored subtitles after every catalogue
        // track: 2 + their position. The bitmap one gets no row.
        XCTAssertEqual(rows.map(\.srcId), [2, 4])
        XCTAssertEqual(rows.map(\.codec), ["srt", "vtt"])
        XCTAssertEqual(rows.map { ServerSubtitleSidecars.storedSubtitleID(forDetailRow: $0.trackId, stored: stored, catalog: catalog) },
                       [8, 12])
        XCTAssertNil(ServerSubtitleSidecars.storedSubtitleID(forDetailRow: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0),
                                                              stored: stored, catalog: catalog), "a subtitle file isn't stored")
        XCTAssertNil(ServerSubtitleSidecars.storedSubtitleID(forDetailRow: 2, stored: stored, catalog: catalog))
    }

    /// English Always, and the file itself has only a forced English track:
    /// the full English subtitle Silo stores wins, on the detail page and in
    /// the player alike.
    func testAutoPickAgreesOnAStoredSubtitle() async throws {
        let catalog = [catalogTrack(index: 3, codec: "subrip", forced: true, title: "Forced")]
        let stored = [SiloStoredSubtitle(id: 8, provider: "opensubtitles", language: "en", format: "srt", releaseName: "Movie.2020.WEB")]
        let context = DetailPlaybackFormatting.SubtitleAutoContext(preferredLanguage: "en", mode: "always", audioLanguage: "en")

        let preview = try XCTUnwrap(DetailPlaybackFormatting.automaticSubtitle(version: version(catalog), context: context, stored: stored))
        XCTAssertEqual(preview.track.title, "Movie.2020.WEB (opensubtitles)")
        XCTAssertEqual(DetailPlaybackFormatting.subtitleShortLabel(preview.track, ordinal: preview.ordinal), "English")
        XCTAssertNil(DetailPlaybackFormatting.automaticSubtitle(version: version(catalog), context: .init(
            preferredLanguage: "en", mode: "auto", audioLanguage: "en"), stored: stored), "Auto with English audio plays none")

        try await withPlayer { model in
            model.offerSiloSidecar(item(1, source: "downloaded", label: "Movie.2020.WEB (opensubtitles)", storedID: 8),
                                   request: request, nativeApiMajor: nil)
            let embedded = PlayerTrack(trackId: 3, kind: .sub, title: "Forced", lang: "eng", codec: "subrip",
                                       audioChannelCount: nil, bitrate: nil, isDefault: false, isForced: true,
                                       isHearingImpaired: false, isExternal: false, isSelected: false, ffIndex: 3, srcId: nil)
            let tracks = [embedded] + PlayerViewModel.siloSidecarRows(model.lazySubtitleSidecars)
            let pick = SubtitleAutoResolver.resolve(.init(preferredLanguage: "en", mode: .always, showForced: false,
                disableWhenNoLanguageMatch: true, trackSignature: nil, availableSubtitles: tracks, currentAudioLanguage: "en"))
            guard case .select(let chosen) = pick else { return XCTFail("expected a subtitle, got \(pick)") }
            XCTAssertEqual(chosen.trackId, SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 1))
        }
    }

    /// A release name saying SDH makes a stored subtitle an accessibility
    /// track for both resolvers, so a plain English track wins on both.
    func testStoredSubtitleTitleCountsOnBothSides() async throws {
        let stored = [SiloStoredSubtitle(id: 8, provider: "opensubtitles", language: "en", format: "srt", releaseName: "Movie.SDH"),
                      SiloStoredSubtitle(id: 9, provider: "opensubtitles", language: "en", format: "srt", releaseName: "Movie")]
        let context = DetailPlaybackFormatting.SubtitleAutoContext(preferredLanguage: "en", mode: "always", audioLanguage: "ja")
        let preview = try XCTUnwrap(DetailPlaybackFormatting.automaticSubtitle(version: version([]), context: context, stored: stored))
        XCTAssertEqual(preview.track.title, "Movie (opensubtitles)")

        try await withPlayer { model in
            model.offerSiloSidecar(item(0, source: "downloaded", label: "Movie.SDH (opensubtitles)", storedID: 8),
                                   request: request, nativeApiMajor: nil)
            model.offerSiloSidecar(item(1, source: "downloaded", label: "Movie (opensubtitles)", storedID: 9),
                                   request: request, nativeApiMajor: nil)
            let pick = SubtitleAutoResolver.resolve(.init(preferredLanguage: "en", mode: .always, showForced: false,
                disableWhenNoLanguageMatch: true, trackSignature: nil,
                availableSubtitles: PlayerViewModel.siloSidecarRows(model.lazySubtitleSidecars), currentAudioLanguage: "ja"))
            guard case .select(let chosen) = pick else { return XCTFail("expected a subtitle, got \(pick)") }
            XCTAssertEqual(chosen.trackId, SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 1))
        }
    }
}
