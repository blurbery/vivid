import XCTest
#if os(tvOS)
@testable import VividTV
#else
@testable import Vivid
#endif

/// Bitmap subtitles (PGS, VobSub, DVB) on Emby and Jellyfin transcodes, which
/// the server draws into the video.
@MainActor
final class ServerSubtitleBurnInTests: XCTestCase {
    private let source = "source-1"

    private func catalogue(_ index: Int, codec: String, forced: Bool = false, external: Bool = false) -> SubtitleTrack {
        SubtitleTrack(index: index, codec: codec, language: "eng", title: nil, embeddedTitle: nil, forced: forced,
                      hearingImpaired: false, isDefault: false, external: external, externalPath: nil)
    }

    private func version(_ subtitles: [SubtitleTrack]) -> FileVersion {
        FileVersion(fileId: 42, fileName: "film.mkv", resolution: "3840x2160", codecVideo: "hevc",
                    codecAudio: "eac3", hdr: false, container: "mkv", fileSize: 1_000,
                    duration: 7_200, bitrate: 20_000_000, videoTracks: nil,
                    audioTracks: nil, subtitleTracks: subtitles, chapters: nil)
    }

    private func info(session: String, direct: Bool, url: String? = nil) -> [String: Any] {
        var media: [String: Any] = ["Id": source, "SupportsDirectPlay": direct, "SupportsTranscoding": true]
        media["TranscodingUrl"] = url
        return ["MediaSources": [media], "PlaySessionId": session]
    }

    private func offer(direct: Bool, url: String? = nil) throws -> ServerSubtitleBurnIn.Offer {
        try XCTUnwrap(ServerSubtitleBurnIn.Offer(info(session: "probe", direct: direct, url: url), sourceID: source))
    }

    // MARK: - Negotiation

    func testDirectPlayNeverAsksForABurnIn() async throws {
        var bodies: [[String: Any]] = []
        let result = try await ServerSubtitleBurnIn.negotiate(try offer(direct: true), burnIn: 3, sourceVideoCodec: "hevc",
                                                              body: ["SubtitleStreamIndex": -1], sourceID: source) {
            bodies.append($0)
            return [:]
        }
        XCTAssertTrue(bodies.isEmpty, "Lucid Engine draws the bitmap track itself on direct play")
        XCTAssertEqual(result.offer.playSessionID, "probe")
        XCTAssertNil(result.subtitles)
    }

    func testATranscodeAsksAgainForTheBurnInAndPlaysTheConfirmedAnswer() async throws {
        var bodies: [[String: Any]] = []
        let probe = try offer(direct: false, url: "/videos/1/master.m3u8?TranscodeReasons=ContainerBitrateExceedsLimit")
        let result = try await ServerSubtitleBurnIn.negotiate(probe, burnIn: 3, sourceVideoCodec: "h264",
                                                              body: ["SubtitleStreamIndex": -1, "UserId": "user"], sourceID: source) {
            bodies.append($0)
            return self.info(session: "burned", direct: false,
                             url: "/videos/1/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode")
        }
        XCTAssertEqual(bodies.map { $0["SubtitleStreamIndex"] as? Int }, [3])
        XCTAssertEqual(bodies.first?["UserId"] as? String, "user", "The rest of the request stays the same")
        XCTAssertEqual(result.offer.playSessionID, "burned")
        XCTAssertEqual(result.subtitles, ServerTranscodeSubtitles(burnedIndex: 3, failedIndex: nil, copiesVideo: false))
    }

    func testAnUnconfirmedBurnInPlaysTheFirstAnswerWithoutIt() async throws {
        let probe = try offer(direct: false, url: "/videos/1/master.m3u8?TranscodeReasons=ContainerBitrateExceedsLimit")
        let answers: [[String: Any]] = [
            info(session: "hls", direct: false, url: "/videos/1/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Hls"),
            info(session: "other", direct: false, url: "/videos/1/master.m3u8?SubtitleStreamIndex=4&SubtitleMethod=Encode"),
            ["ErrorCode": "NoCompatibleStream"],
        ]
        for answer in answers {
            let result = try await ServerSubtitleBurnIn.negotiate(probe, burnIn: 3, sourceVideoCodec: "hevc",
                                                                  body: [:], sourceID: source) { _ in answer }
            XCTAssertEqual(result.offer.playSessionID, "probe")
            XCTAssertEqual(result.subtitles, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: 3, copiesVideo: false))
        }
    }

    /// A dropped or refused request says nothing about the subtitle, so it
    /// isn't held against the track.
    func testABurnInRequestWithNoAnswerIsOnlyMissedThisTime() async throws {
        let probe = try offer(direct: false, url: "/videos/1/master.m3u8?TranscodeReasons=ContainerBitrateExceedsLimit")
        let result = try await ServerSubtitleBurnIn.negotiate(probe, burnIn: 3, sourceVideoCodec: "hevc",
                                                              body: [:], sourceID: source) { _ in
            throw URLError(.timedOut)
        }
        XCTAssertEqual(result.offer.playSessionID, "probe")
        XCTAssertEqual(result.subtitles, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: 3, failureIsTemporary: true,
                                                                  copiesVideo: false))
    }

    func testATranscodeWithoutABitmapPickIsAskedOnce() async throws {
        var asked = false
        let probe = try offer(direct: false, url: "/videos/1/master.m3u8?TranscodeReasons=ContainerNotSupported")
        let result = try await ServerSubtitleBurnIn.negotiate(probe, burnIn: nil, sourceVideoCodec: "h264",
                                                              body: [:], sourceID: source) { _ in
            asked = true
            return [:]
        }
        XCTAssertFalse(asked)
        XCTAssertEqual(result.subtitles, ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: nil, copiesVideo: true))
        let resized = try await ServerSubtitleBurnIn.negotiate(probe, burnIn: nil, sourceVideoCodec: "h264",
                                                               body: ["AllowVideoStreamCopy": false], sourceID: source) { _ in [:] }
        XCTAssertEqual(resized.subtitles?.copiesVideo, false, "Vivid asked for a smaller or SDR picture")
    }

    // MARK: - Reading the server's answer

    /// Emby's own logs show `SubtitleMethod=Encode` and comma-separated
    /// `TranscodeReasons`; Jellyfin builds the same query.
    func testConfirmationNeedsAnEncodeOfTheRequestedStream() {
        func confirms(_ url: String?, _ streams: [[String: Any]] = []) -> Bool {
            ServerSubtitleBurnIn.confirms(3, transcodingURL: url, mediaStreams: streams)
        }
        XCTAssertTrue(confirms("/videos/1/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode"))
        XCTAssertTrue(confirms("/Videos/1/master.m3u8?subtitlestreamindex=3&subtitlemethod=encode"))
        XCTAssertFalse(confirms("/videos/1/master.m3u8?SubtitleStreamIndex=4&SubtitleMethod=Encode"))
        XCTAssertFalse(confirms("/videos/1/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Hls"))
        XCTAssertFalse(confirms("/videos/1/master.m3u8?VideoCodec=h264"))
        XCTAssertFalse(confirms(nil))
        let encode: [[String: Any]] = [["Type": "Subtitle", "Index": 3, "DeliveryMethod": "Encode"]]
        let external: [[String: Any]] = [["Type": "Subtitle", "Index": 3, "DeliveryMethod": "External"]]
        XCTAssertTrue(confirms("/videos/1/master.m3u8?SubtitleStreamIndex=3", encode),
                      "Without a method in the URL, the subtitle's delivery decides")
        XCTAssertFalse(confirms("/videos/1/master.m3u8?SubtitleStreamIndex=3", external))
    }

    func testOnlyAnH264TranscodeForAudioOrContainerReasonsCopiesTheVideo() {
        func copies(_ query: String, _ codec: String? = "h264") -> Bool {
            ServerSubtitleBurnIn.copiesVideo(transcodingURL: "/videos/1/master.m3u8?" + query, sourceVideoCodec: codec)
        }
        XCTAssertTrue(copies("TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported"))
        XCTAssertTrue(copies("TranscodeReasons=AudioCodecNotSupported", "H264"))
        XCTAssertFalse(copies("TranscodeReasons=ContainerBitrateExceedsLimit"))
        XCTAssertFalse(copies("TranscodeReasons=ContainerNotSupported,VideoCodecNotSupported"))
        XCTAssertFalse(copies("TranscodeReasons=ContainerNotSupported", "hevc"), "Vivid's transcoding profile asks for H.264")
        XCTAssertFalse(copies("TranscodeReasons=ContainerNotSupported&allowVideoStreamCopy=false"))
        XCTAssertFalse(copies("VideoCodec=h264"), "Without reasons the video isn't known to be copied")
    }

    // MARK: - Picks and rows

    func testOnlyABitmapTrackOfTheFileIsDrawnIn() {
        let file = version([catalogue(2, codec: "subrip"), catalogue(3, codec: "PGSSUB"),
                            catalogue(5, codec: "dvdsub", external: true)])
        XCTAssertEqual(ServerSubtitleBurnIn.bitmapStreamIndex(3, in: file), 3)
        XCTAssertEqual(ServerSubtitleBurnIn.bitmapStreamIndex(5, in: file), 5)
        XCTAssertNil(ServerSubtitleBurnIn.bitmapStreamIndex(2, in: file), "Text travels beside the transcode")
        XCTAssertNil(ServerSubtitleBurnIn.bitmapStreamIndex(9, in: file))
        XCTAssertNil(ServerSubtitleBurnIn.bitmapStreamIndex(-1, in: file))
        XCTAssertNil(ServerSubtitleBurnIn.bitmapStreamIndex(nil, in: file))
    }

    func testBurnInRowsUseTheServerIndexInTheSidecarSpace() {
        let file = version([catalogue(2, codec: "subrip"), catalogue(3, codec: "pgssub", forced: true),
                            catalogue(4, codec: "dvbsub"), catalogue(5, codec: "dvdsub", external: true)])
        let rows = ServerSubtitleBurnIn.rows(version: file, excluding: [4])
        XCTAssertEqual(rows.map(\.trackId), [3, 5].map { SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0) })
        XCTAssertEqual(rows.map(\.srcId), [3, 5])
        XCTAssertTrue(rows.allSatisfy { $0.ffIndex == nil }, "No engine track may match a row")
        XCTAssertEqual(rows.map(\.isForced), [true, false])
        XCTAssertEqual(rows.map(\.isExternal), [false, true])
    }

    func testAReloadIsNeededOnlyWhenTheBurnInChanges() {
        XCTAssertEqual(ServerSubtitleBurnIn.reload(wanted: nil, burned: nil), .none)
        XCTAssertEqual(ServerSubtitleBurnIn.reload(wanted: 3, burned: 3), .none, "Already drawn in")
        XCTAssertEqual(ServerSubtitleBurnIn.reload(wanted: 3, burned: nil), .burnIn(3))
        XCTAssertEqual(ServerSubtitleBurnIn.reload(wanted: 4, burned: 3), .burnIn(4))
        XCTAssertEqual(ServerSubtitleBurnIn.reload(wanted: nil, burned: 3), .removeBurnIn)
    }

    /// Rows come after the subtitles Vivid plays itself, so Auto takes a
    /// text track over a bitmap one of the same kind, and still finds a
    /// forced track that only exists as a bitmap.
    func testATextTrackWinsOverABurnInRowOfTheSameKind() {
        func text(_ index: Int, forced: Bool) -> PlayerTrack {
            PlayerTrack(trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: index), kind: .sub, title: nil,
                        lang: "eng", codec: "srt", audioChannelCount: nil, bitrate: nil, isDefault: false,
                        isForced: forced, isHearingImpaired: false, isExternal: true, isSelected: false,
                        ffIndex: nil, srcId: index)
        }
        let rows = ServerSubtitleBurnIn.rows(version: version([catalogue(3, codec: "pgssub", forced: true)]), excluding: [])
        func pick(_ tracks: [PlayerTrack]) -> SubtitleAutoSelection {
            SubtitleAutoResolver.resolve(.init(preferredLanguage: "en", mode: .auto, showForced: true,
                                               disableWhenNoLanguageMatch: true, trackSignature: nil,
                                               availableSubtitles: tracks, currentAudioLanguage: "eng"))
        }
        let forcedText = text(2, forced: true)
        XCTAssertEqual(pick([forcedText] + rows), .select(forcedText))
        XCTAssertEqual(pick([text(2, forced: false)] + rows), .select(rows[0]))
    }

    // MARK: - Player

    private func watchDetail() throws -> WatchDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WatchDetail.self, from: Data("""
            {"content_id":"film","type":"movie","title":"Film"}
            """.utf8))
    }

    private func transcodingModel(burned: Int?, copiesVideo: Bool = false) throws -> PlayerViewModel {
        let model = PlayerViewModel()
        model.currentWatchDetail = try watchDetail()
        model.currentSelectedVersion = version([catalogue(2, codec: "subrip"), catalogue(3, codec: "pgssub", forced: true)])
        model.serverTranscodeSubtitles = ServerTranscodeSubtitles(burnedIndex: burned, failedIndex: nil, copiesVideo: copiesVideo)
        model.subtitleTracks = model.refreshServerBurnInRows()
        return model
    }

    private func finish(_ model: PlayerViewModel) async {
        model.cleanup()
        await model.waitForCleanupCompletion()
    }

    func testTheBurnedRowStaysSelectedAndCarriesItsServerIndex() async throws {
        let model = try transcodingModel(burned: 3)
        let row = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        model.pendingSubtitleFfIndex = 3
        model.reassertServerBurnedInSubtitle(loadIsEstablished: false)
        XCTAssertEqual(model.selectedSubtitleId, row)
        XCTAssertNil(model.pendingSubtitleFfIndex, "The load armed the burn-in; nothing arms it again")
        XCTAssertTrue(model.isServerBurnedInSubtitle(row))
        XCTAssertEqual(model.serverBurnInReload, .none, "No reload while it's already drawn in")
        XCTAssertEqual(model.resolvedSubtitleTrackIndexForResume(), 3, "A quality change or renewal asks for it again")
        XCTAssertNil(model.resolvedSidecarSubtitleTrackIdForResume(), "A burn-in row has no file of its own")
        XCTAssertFalse(model.backendCapabilities.supportsSubtitleStyling)
        await finish(model)
    }

    /// A quality change can carry Auto's pick into a load that burns it in.
    /// Auto mustn't run again there: on a transcode that only copies the
    /// video it would hide the row, switch the burn-in off and reload.
    func testAConfirmedBurnInHoldsForTheItemEvenWhenAutoChoseIt() async throws {
        let model = PlayerViewModel()
        model.hasExplicitSubtitleChoice = false
        model.prefsForCurrentItem = .init(
            preferredLanguage: "en", additionalPreferredLanguages: [], mode: .auto,
            showForced: true, forcedOnly: false, preferAccessibilityTracks: false,
            disableWhenNoLanguageMatch: true, trackSignature: nil
        )
        let file = version([catalogue(2, codec: "subrip", forced: true), catalogue(3, codec: "pgssub", forced: true)])
        let session = PlaybackSessionResponse(sessionId: "burned", userId: nil, profileId: nil, mediaFileId: 42,
            playMethod: "Transcode", position: 0, isPaused: false, streamUrl: "https://media.example.test/master.m3u8",
            audioTrackIndex: nil, durationSeconds: 7_200, subtitleUrls: [], playbackInfo: nil)
        model.adoptServerTranscodeSubtitles(PreparedPlayback(
            watchDetail: try watchDetail(), selectedVersion: file, session: session,
            transcodeSubtitles: ServerTranscodeSubtitles(burnedIndex: 3, failedIndex: nil, copiesVideo: true)))
        XCTAssertTrue(model.hasExplicitSubtitleChoice)
        XCTAssertNil(model.prefsForCurrentItem)
        model.currentWatchDetail = try watchDetail()
        model.currentSelectedVersion = file
        model.subtitleTracks = model.refreshServerBurnInRows()
        model.reassertServerBurnedInSubtitle(loadIsEstablished: false)
        model.applyAutoSubtitlePreferencesIfNeeded(forceReevaluation: true)
        XCTAssertEqual(model.selectedSubtitleId, SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3))
        XCTAssertEqual(model.serverBurnInReload, .none)
        await finish(model)
    }

    func testLeavingOrChoosingABurnInRowNeedsAReload() async throws {
        let burned = try transcodingModel(burned: 3)
        burned.reassertServerBurnedInSubtitle(loadIsEstablished: false)
        burned.selectedSubtitleId = nil
        XCTAssertEqual(burned.serverBurnInReload, .removeBurnIn)
        burned.selectedSubtitleId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)
        XCTAssertEqual(burned.serverBurnInReload, .removeBurnIn)
        await finish(burned)

        let plain = try transcodingModel(burned: nil)
        plain.selectedSubtitleId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        XCTAssertEqual(plain.serverBurnInReload, .burnIn(3))
        await finish(plain)
    }

    func testAutoLeavesBurnInRowsAloneWhileTheVideoIsOnlyCopied() async throws {
        let copied = try transcodingModel(burned: nil, copiesVideo: true)
        XCTAssertTrue(copied.subtitleTracksForAutomaticPick.isEmpty)
        XCTAssertEqual(copied.subtitleTracks.map(\.srcId), [3], "The row can still be picked by hand")
        await finish(copied)
        let encoded = try transcodingModel(burned: nil)
        XCTAssertEqual(encoded.subtitleTracksForAutomaticPick.map(\.srcId), [3])
        await finish(encoded)
    }

    func testAnUnconfirmedBurnInIsDroppedForTheItemAndSubtitlesGoOff() async throws {
        let model = PlayerViewModel()
        model.pendingSubtitleFfIndex = 3
        let file = version([catalogue(3, codec: "pgssub")])
        let session = PlaybackSessionResponse(sessionId: "probe", userId: nil, profileId: nil, mediaFileId: 42,
            playMethod: "Transcode", position: 0, isPaused: false, streamUrl: "https://media.example.test/master.m3u8",
            audioTrackIndex: nil, durationSeconds: 7_200, subtitleUrls: [], playbackInfo: nil)
        model.adoptServerTranscodeSubtitles(PreparedPlayback(
            watchDetail: try watchDetail(), selectedVersion: file, session: session,
            transcodeSubtitles: ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: 3, copiesVideo: false)))
        XCTAssertEqual(model.failedServerBurnIns, [.init(contentId: "film", fileId: 42, index: 3)])
        XCTAssertEqual(model.pendingSubtitleFfIndex, -1)
        XCTAssertNotNil(model.activeNotice)
        model.currentWatchDetail = try watchDetail()
        model.currentSelectedVersion = file
        XCTAssertTrue(model.refreshServerBurnInRows().isEmpty, "Its row is gone, so Auto can't pick it again")
        await finish(model)
    }

    func testAMissedBurnInTurnsSubtitlesOffButCanBeChosenAgain() async throws {
        let model = PlayerViewModel()
        model.pendingSubtitleFfIndex = 3
        let file = version([catalogue(3, codec: "pgssub")])
        let session = PlaybackSessionResponse(sessionId: "probe", userId: nil, profileId: nil, mediaFileId: 42,
            playMethod: "Transcode", position: 0, isPaused: false, streamUrl: "https://media.example.test/master.m3u8",
            audioTrackIndex: nil, durationSeconds: 7_200, subtitleUrls: [], playbackInfo: nil)
        model.adoptServerTranscodeSubtitles(PreparedPlayback(
            watchDetail: try watchDetail(), selectedVersion: file, session: session,
            transcodeSubtitles: ServerTranscodeSubtitles(burnedIndex: nil, failedIndex: 3, failureIsTemporary: true,
                                                         copiesVideo: false)))
        XCTAssertTrue(model.failedServerBurnIns.isEmpty)
        XCTAssertEqual(model.pendingSubtitleFfIndex, -1)
        XCTAssertNotNil(model.activeNotice)
        model.currentWatchDetail = try watchDetail()
        model.currentSelectedVersion = file
        XCTAssertEqual(model.refreshServerBurnInRows().map(\.srcId), [3])
        await finish(model)
    }

    /// Only a failure of the burned-in stream itself is blamed on the
    /// subtitle; connection, sign-in and rate-limit failures take the usual
    /// path and leave the track alone.
    func testOnlyAFailureOfTheTranscodeItselfIsBlamedOnTheBurnIn() {
        func blames(_ kind: PlaybackErrorKind, domain: String? = nil, code: Int? = nil) -> Bool {
            let failure = PlaybackErrorInfo(kind: kind, message: "failed", underlyingDomain: domain, underlyingCode: code)
            return PlayerViewModel.loadFailureBlamesServerBurnIn(
                VividPlaybackController.LoadFailure(failure: failure, underlying: failure))
        }
        XCTAssertTrue(blames(.sourceRefused, code: 500), "The server's transcode refused to start")
        XCTAssertTrue(blames(.sourceRefused, domain: NSURLErrorDomain, code: 502),
                      "An HTTP status counts whichever domain carries it")
        XCTAssertFalse(blames(.sourceRefused, domain: NSURLErrorDomain, code: 401))
        XCTAssertTrue(blames(.masterPlaylistRejected))
        XCTAssertTrue(blames(.softwarePipelineFailed))
        XCTAssertFalse(blames(.sourceRefused, domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertFalse(blames(.sourceRefused, domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertFalse(blames(.sourceRefused, code: 401))
        XCTAssertFalse(blames(.sourceRefused, code: 408))
        XCTAssertFalse(blames(.sourceRefused, code: 429))
        XCTAssertFalse(blames(.nativeItemFailed, domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
                       "A connection failure counts as one whatever kind the engine gives it")
        XCTAssertFalse(blames(.vodSourceFailed, domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
        XCTAssertFalse(blames(.sourceRateLimited))
        XCTAssertFalse(blames(.audioSessionUnavailable))
        XCTAssertFalse(PlayerViewModel.loadFailureBlamesServerBurnIn(URLError(.badURL)), "Not an engine failure")
    }

    /// The pick rides on the load's subtitle index, which every reload of
    /// the same item carries, and only Emby and Jellyfin use it this way.
    func testReloadsCarryTheBitmapPickUntilItFails() {
        var request = PlayerViewModel.LoadRequest(contentId: "film", preferredFileId: 42, preferredAudioTrackIndex: 1,
                                                  preferredSubtitleTrackIndex: 3, preferredSidecarSubtitleTrackId: nil,
                                                  startFromBeginning: true)
        func candidate(_ request: PlayerViewModel.LoadRequest, native: Bool = true,
                       failures: Set<PlayerViewModel.ServerBurnInFailure> = []) -> Int? {
            PlayerViewModel.serverBurnInCandidate(for: request, usesNativeUser: native, failures: failures)
        }
        XCTAssertEqual(candidate(request), 3)
        XCTAssertEqual(candidate(request.resumingInPlace()), 3, "Seek reloads and retries")
        XCTAssertEqual(candidate(request.copyForRecovery(preferredFileId: 42, preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: 3, preferredSidecarSubtitleTrackId: nil, offlineDownloadId: nil)), 3,
            "Quality changes and renewals")
        XCTAssertNil(candidate(request, native: false), "Silo plans are left alone")
        XCTAssertNil(candidate(request, failures: [.init(contentId: "film", fileId: 42, index: 3)]))
        XCTAssertEqual(candidate(request, failures: [.init(contentId: "other", fileId: 42, index: 3)]), 3)
        request.offlineDownloadId = "download"
        XCTAssertNil(candidate(request))
    }
}
