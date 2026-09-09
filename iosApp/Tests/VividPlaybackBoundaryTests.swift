import VividKit
import AVFoundation
import Foundation
import Network
import XCTest
@testable import Vivid

@MainActor
final class VividPlaybackBoundaryTests: XCTestCase {
    func testDirectCredentialUpdatePreservesPausedPlaybackAndRejectsStaleEpoch() async throws {
        let file = try embeddedMediaFixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let server = try CredentialPlaybackServer(media: Data(contentsOf: file))
        let url = try await server.start()
        defer { server.stop() }
        let old = ["Authorization": "Bearer fixture-old"]
        let next = ["Authorization": "Bearer fixture-new"]
        let controller = try VividPlaybackController()
        controller.setMuted(true)
        defer { controller.stop() }
        let spec = try VividLoadSpec(directURL: url, headers: old, startPosition: 0, audioOnly: true)
        let epoch = controller.beginLoad(spec, shouldPlayWhenReady: false)
        try await controller.finishLoad(epoch)
        let player = controller.engine.player
        let deadline = Date().addingTimeInterval(5)
        while player.state != .paused && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(player.state, .paused)
        XCTAssertGreaterThan(player.bufferedAhead, 0)
        let buffered = player.bufferedAhead
        let time = player.currentTime
        let track = player.selectedAudioTrack
        XCTAssertTrue(controller.updateSourceHeaders(next, for: epoch, expectedHeaders: old, sourceURL: url))
        XCTAssertEqual(controller.activeLoadEpoch, epoch)
        XCTAssertEqual(controller.activeSpec?.options.httpHeaders, next)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(player.currentTime, time)
        XCTAssertEqual(player.selectedAudioTrack, track)
        XCTAssertGreaterThanOrEqual(player.bufferedAhead, buffered)
        XCTAssertFalse(controller.shouldPlayWhenReady)
        XCTAssertFalse(controller.updateSourceHeaders(old, for: epoch, expectedHeaders: old, sourceURL: url))
        _ = controller.beginLoad(spec, shouldPlayWhenReady: false)
        XCTAssertFalse(controller.updateSourceHeaders(next, for: epoch, expectedHeaders: old, sourceURL: url))
    }

    private func embeddedMediaFixture(secondAudio: Bool = false) throws -> URL {
        func integer(_ value: UInt64, width: Int? = nil) -> Data {
            let count = width ?? max(1, (64 - value.leadingZeroBitCount + 7) / 8)
            return Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func element(_ id: UInt64, _ data: Data) -> Data {
            var count = 1
            while UInt64(data.count) >= (UInt64(1) << (count * 7)) - 1 { count += 1 }
            return integer(id) + integer(UInt64(data.count) | (UInt64(1) << (count * 7)), width: count) + data
        }
        func number(_ id: UInt64, _ value: UInt64) -> Data { element(id, integer(value)) }
        let header = number(0x4286, 1) + number(0x42F7, 1) + number(0x42F2, 4) + number(0x42F3, 8)
            + element(0x4282, Data("matroska".utf8)) + number(0x4287, 4) + number(0x4285, 2)
        let info = number(0x2AD7B1, 1_000_000)
            + element(0x4489, integer(Double(3000).bitPattern, width: 8))
        let audio = number(0xD7, 1) + number(0x73C5, 1) + number(0x83, 2)
            + element(0x86, Data("A_PCM/INT/LIT".utf8))
            + element(0xE1, element(0xB5, integer(Double(48000).bitPattern, width: 8))
                + number(0x9F, 1) + number(0x6264, 16))
        func subtitle(_ id: UInt64, _ language: String) -> Data {
            element(0xAE, number(0xD7, id) + number(0x73C5, id) + number(0x83, 17)
                + element(0x86, Data("S_TEXT/UTF8".utf8)) + element(0x22B59C, Data(language.utf8)))
        }
        let alternative = number(0xD7, 4) + number(0x73C5, 4) + number(0x83, 2)
            + element(0x86, Data("A_PCM/INT/LIT".utf8))
            + element(0xE1, element(0xB5, integer(Double(48000).bitPattern, width: 8))
                + number(0x9F, 2) + number(0x6264, 16))
        let alternateTrack = secondAudio ? element(0xAE, alternative) : Data()
        var segment = element(0x1549A966, info)
            + element(0x1654AE6B, element(0xAE, audio) + subtitle(2, "eng") + subtitle(3, "fra") + alternateTrack)
        for index in 0..<30 {
            var cluster = number(0xE7, UInt64(index * 100))
            cluster += element(0xA3, Data([0x81, 0, 0, 0x80]) + Data(repeating: 0, count: 9600))
            if secondAudio {
                cluster += element(0xA3, Data([0x84, 0, 0, 0x80]) + Data(repeating: 0, count: 19200))
            }
            if index == 0 {
                for (id, text) in [(UInt8(0x82), "First embedded caption"), (UInt8(0x83), "Second embedded caption")] {
                    cluster += element(0xA0, element(0xA1, Data([id, 0, 0, 0]) + Data(text.utf8)) + number(0x9B, 3000))
                }
            }
            segment += element(0x1F43B675, cluster)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mkv")
        try (element(0x1A45DFA3, header) + element(0x18538067, segment)).write(to: url)
        return url
    }

    func testEmbeddedPickerTracksRemainSelectableAfterPrimaryClears() async throws {
        let url = try embeddedMediaFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try VividPlaybackController()
        controller.setMuted(true)
        defer { controller.stop() }
        let epoch = controller.beginLoad(try VividLoadSpec(offlineURL: url, startPosition: 0, audioOnly: false))
        try await controller.finishLoad(epoch)
        let tracks = controller.engine.nativeSubtitleTracks
        XCTAssertEqual(tracks.map(\.id), [1, 2])
        for track in tracks {
            XCTAssertTrue(controller.containsSubtitle(appTrackID: Int64(track.id)))
            XCTAssertEqual(controller.vividSubtitleID(forAppID: Int64(track.id)), track.id)
        }
        XCTAssertFalse(controller.containsSubtitle(appTrackID: 99))
        XCTAssertFalse(controller.containsSubtitle(appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)))
        controller.selectSubtitleTrack(id: 2)
        let deadline = Date().addingTimeInterval(5)
        while controller.engine.subtitleCues.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(controller.engine.subtitleCues.contains { if case .text("Second embedded caption") = $0.body { return true }; return false })
        controller.selectSubtitleTrack(id: nil)
        XCTAssertTrue(controller.containsSubtitle(appTrackID: 2))
        XCTAssertEqual(controller.vividSubtitleID(forAppID: 2), 2)
        controller.selectSecondarySubtitleTrack(id: 2)
        let secondaryDeadline = Date().addingTimeInterval(5)
        while controller.engine.secondarySubtitleCues.isEmpty && Date() < secondaryDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(controller.engine.secondarySubtitleCues.contains { if case .text("Second embedded caption") = $0.body { return true }; return false })
        XCTAssertNil(controller.engine.player.error)
        controller.stop()
        XCTAssertFalse(controller.containsSubtitle(appTrackID: 2))
    }

    private struct LiveStreamFixture: Decodable {
        let label: String?
        let url: URL
        let headers: [String: String]
    }

    private struct LiveStreamFixtureEnvelope: Decodable {
        let streams: [LiveStreamFixture]
    }

    func testLocalAudioLanguageSelectsTrackBeforeServerPlanning() {
        let tracks = [makeAudioTrack(language: "eng", isDefault: true), makeAudioTrack(language: "jpn", isDefault: false)]
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: "ja"), 1)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: 0, tracks: tracks, preferredLanguage: "ja"), 0)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: "fr"), 0)
        XCTAssertNil(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: [], preferredLanguage: "ja"))
    }

    func testExplicitV3AudioSelectionOverridesProfileLanguageForInitialLoad() {
        let languages = VividInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [
                makeAudioTrack(language: "pt", isDefault: true),
                makeAudioTrack(language: "en", isDefault: false),
            ],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, ["pt"])
    }

    func testUnlabeledExplicitAudioSelectionDoesNotFallBackToProfileLanguage() {
        let languages = VividInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [makeAudioTrack(language: nil, isDefault: false)],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, [])
    }

    func testUnavailableExplicitAudioInventoryDoesNotResurrectProfileLanguage() {
        for tracks in [
            [AudioTrack](),
            [makeAudioTrack(language: "pt", isDefault: true)],
        ] {
            let languages = VividInitialAudioPreference.languages(
                selectedOrdinal: 1,
                tracks: tracks,
                fallbackLanguage: "en"
            )

            XCTAssertEqual(languages, [])
        }
    }

    func testWhitespaceOnlyExplicitAudioLanguageDoesNotBecomeAnVividHint() {
        let languages = VividInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [makeAudioTrack(language: "  ", isDefault: false)],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, [])
    }

    func testProfileAudioLanguageRemainsFallbackWithoutExplicitSelection() {
        let languages = VividInitialAudioPreference.languages(
            selectedOrdinal: nil,
            tracks: [makeAudioTrack(language: "pt", isDefault: true)],
            fallbackLanguage: " en "
        )

        XCTAssertEqual(languages, ["en"])
    }

    func testInitialAudioOrdinalResolvesInsideTheFirstOpen() async throws {
        let url = try embeddedMediaFixture(secondAudio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try VividPlaybackController()
        controller.setMuted(true)
        defer { controller.stop() }
        var opens = 0
        let observation = controller.engine.$startupProgress.sink { progress in
            if progress?.checkpoint == "Opening source" { opens += 1 }
        }
        defer { observation.cancel() }
        let spec = try VividLoadSpec(offlineURL: url, startPosition: 0, audioOnly: true, audioTrackOrdinal: 1)
        let epoch = controller.beginLoad(spec)
        try await controller.finishLoad(epoch)
        XCTAssertEqual(controller.engine.audioTracks.map(\.id), [0, 3])
        XCTAssertEqual(controller.engine.activeAudioTrackIndex, 3)
        XCTAssertEqual(controller.engine.player.selectedAudioTrack, 3)
        XCTAssertEqual(opens, 1)
        XCTAssertNil(controller.engine.errorInfo)
    }

    func testAutoAudioPrefersCompatibilityTrackInTheSameLanguage() {
        let tracks = [makeAudioTrack(language: "eng", isDefault: true, codec: "truehd"),
            makeAudioTrack(language: "eng", isDefault: false, codec: "ac3")]
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: "en"), 1)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: ""), 1)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: 0, tracks: tracks, preferredLanguage: "en"), 0)
    }

    func testAutoAudioKeepsLanguageAndFallsBackWhenNoAlternativeExists() {
        let tracks = [makeAudioTrack(language: "eng", isDefault: true, codec: "truehd"),
            makeAudioTrack(language: "fra", isDefault: false, codec: "aac")]
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: "en"), 0)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: tracks, preferredLanguage: "fr"), 1)
        XCTAssertEqual(VividInitialAudioPreference.selectedOrdinal(manual: nil, tracks: [tracks[0]], preferredLanguage: "en"), 0)
    }

    private func makeAudioTrack(language: String?, isDefault: Bool, codec: String = "eac3") -> AudioTrack {
        AudioTrack(
            index: nil,
            codec: codec,
            channels: 6,
            channelLayout: "5.1(side)",
            bitrate: 640,
            sampleRate: 48_000,
            language: language,
            title: nil,
            embeddedTitle: nil,
            isDefault: isDefault
        )
    }

    func testHeaderAuthenticatedStreamResolutionStaysOnAPIMediaOrigin() throws {
        let request = try XCTUnwrap(StreamRequest.resolve(
            rawURL: "/playback/transcode/session-1/master.m3u8?seek=12",
            serverURL: "https://dev.example.test/",
            additionalHeaders: [
                "authorization": "Bearer stale-wire-token",
                "X-Transport": "preserved",
            ],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true
        ))

        XCTAssertEqual(
            request.url.absoluteString,
            "https://dev.example.test/api/v1/playback/transcode/session-1/master.m3u8?seek=12"
        )
        XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        XCTAssertNil(request.headers["authorization"])
        XCTAssertEqual(request.headers["X-Transport"], "preserved")
    }

    func testExpiredBearerRecoveryRecognizesTypedSourceAndAVPlayer401Failures() {
        XCTAssertTrue(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(
            PlaybackErrorInfo(kind: .sourceRefused, message: "engine failure",
                underlyingDomain: NSURLErrorDomain, underlyingCode: 401)
        ))
        XCTAssertTrue(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(
            PlaybackErrorInfo(
                kind: .sourceRefused,
                message: "origin refused source",
                underlyingCode: 401
            )
        ))
        XCTAssertTrue(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(
            PlaybackErrorInfo(
                kind: .nativeItemFailed,
                message: "localized AVPlayer failure",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: NSURLErrorUserAuthenticationRequired
            )
        ))
    }

    func testTransientRecoveryRequiresRecognisedSourceDomainAndCode() {
        XCTAssertEqual(PlaybackErrorInfo(kind: .sourceRefused, message: "read failed",
            underlyingDomain: NSURLErrorDomain, underlyingCode: NSURLErrorTimedOut).transientSourceCode,
            NSURLErrorTimedOut)
        for failure in [
            PlaybackErrorInfo(kind: .sourceRefused, message: "auth", underlyingDomain: NSURLErrorDomain, underlyingCode: 401),
            PlaybackErrorInfo(kind: .sourceRefused, message: "unrelated", underlyingDomain: "Decoder", underlyingCode: 503),
            PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "decoder", underlyingDomain: NSURLErrorDomain, underlyingCode: 503),
            PlaybackErrorInfo(kind: .sourceRefused, message: "unknown", underlyingCode: 503),
            PlaybackErrorInfo(kind: .sourceRateLimited, message: "limited", underlyingDomain: NSURLErrorDomain, underlyingCode: 429)
        ] {
            XCTAssertNil(failure.transientSourceCode)
        }
    }

    func testExpiredBearerRecoveryRejectsNonAuthenticationFailures() {
        XCTAssertFalse(PlaybackErrorInfo.isHTTPAuthenticationFailure(
            NSError(domain: "UnrelatedDecoder", code: 401)
        ))
        XCTAssertFalse(PlaybackErrorInfo.isHTTPAuthenticationFailure(
            PlaybackErrorInfo(kind: .sourceRefused, message: "unrelated",
                underlyingDomain: "UnrelatedDecoder", underlyingCode: 401)
        ))
        for failure in [
            PlaybackErrorInfo(
                kind: .sourceRefused,
                message: "forbidden",
                underlyingCode: 403
            ),
            PlaybackErrorInfo(
                kind: .nativeItemFailed,
                message: "timed out",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: NSURLErrorTimedOut
            ),
            PlaybackErrorInfo(
                kind: .vodSourceFailed,
                message: "read failed",
                underlyingCode: 401
            ),
        ] {
            XCTAssertFalse(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(failure))
        }
    }

    func testExpiredBearerRecoveryRequiresAChangedAuthorizationHeader() {
        XCTAssertTrue(VividAuthenticationRecoveryPolicy.shouldReload(
            failedHeaders: ["authorization": "Bearer old-token"],
            refreshedHeaders: ["Authorization": "Bearer new-token"]
        ))
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.shouldReload(
            failedHeaders: ["Authorization": "Bearer current-token"],
            refreshedHeaders: ["authorization": "Bearer current-token"]
        ))
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.shouldReload(
            failedHeaders: ["Authorization": "Bearer old-token"],
            refreshedHeaders: [:]
        ))
    }

    func testAuthenticationFailureSurvivesKnownUnderlyingErrorChains() {
        XCTAssertTrue(PlaybackErrorInfo.isHTTPAuthenticationFailure(VividPlaybackError.network(401)))
        XCTAssertTrue(PlaybackErrorInfo.isHTTPAuthenticationFailure(NSError(
            domain: AVFoundationErrorDomain, code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain,
                code: NSURLErrorUserAuthenticationRequired)]
        )))
        XCTAssertFalse(PlaybackErrorInfo.isHTTPAuthenticationFailure(NSError(
            domain: AVFoundationErrorDomain, code: -11800,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "Decoder", code: 401)]
        )))
    }

    func testAuthenticationRecoveryBudgetSurvivesReconstructionAndRejectsStaleCompletion() {
        var budget = VividAuthenticationRecoveryBudget()
        XCTAssertFalse(budget.attempted)
        XCTAssertTrue(budget.begin(generation: 1))
        XCTAssertFalse(budget.begin(generation: 1))
        XCTAssertFalse(budget.begin(generation: 1))
        XCTAssertTrue(budget.begin(generation: 2))
        budget.recovered(generation: 1)
        XCTAssertFalse(budget.begin(generation: 2))
        budget.recovered(generation: 2)
        XCTAssertTrue(budget.begin(generation: 2))
    }

    func testAuthenticationRecoveryRequiresAdvancementAndDoesNotCountASeek() {
        var readiness = VividAuthenticationRecoveryReadiness()
        for time in [10.0, 10.0, 10.0, 40.0] {
            XCTAssertFalse(readiness.observe(time: time, ready: true, wantsPlayback: true,
                playing: true, paused: false, seeking: false))
        }
        XCTAssertFalse(readiness.observe(time: 40.2, ready: true, wantsPlayback: true,
            playing: true, paused: false, seeking: true))
        XCTAssertFalse(readiness.observe(time: 40.4, ready: true, wantsPlayback: true,
            playing: true, paused: false, seeking: false))
        XCTAssertTrue(readiness.observe(time: 40.8, ready: true, wantsPlayback: true,
            playing: true, paused: false, seeking: false))
    }

    func testPausedAuthenticationRecoveryRequiresUsableSession() {
        var readiness = VividAuthenticationRecoveryReadiness()
        XCTAssertFalse(readiness.observe(time: 20, ready: false, wantsPlayback: false,
            playing: false, paused: true, seeking: false))
        XCTAssertTrue(readiness.observe(time: 20, ready: true, wantsPlayback: false,
            playing: false, paused: true, seeking: false))
    }

    func testAuthenticationRecoverySurfacesReplacementFailureRatherThanOriginal401() {
        let final = PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "Decoder failed",
            underlyingDomain: "Decoder", underlyingCode: -5)
        let wrapped = VividPlaybackController.LoadFailure(failure: final, underlying: VividPlaybackError.media(-5))
        XCTAssertEqual(VividAuthenticationRecoveryPolicy.finalFailure(wrapped), final)
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(final))
        let network = VividAuthenticationRecoveryPolicy.finalFailure(
            HTTPError.network(underlying: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        XCTAssertEqual(network.kind, .vodSourceFailed)
        XCTAssertEqual(network.underlyingCode, NSURLErrorTimedOut)
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(network))
        XCTAssertTrue(VividAuthenticationRecoveryPolicy.isExpiredBearerFailure(
            VividAuthenticationRecoveryPolicy.finalFailure(HTTPError.http(statusCode: 401, body: nil))))
    }

    func testPeriodicProgressReloadsOnlyAfterSuccessWithChangedAuthorization() {
        let active = ["Authorization": "Bearer old-token"]
        let refreshed = ["authorization": "Bearer new-token"]

        XCTAssertTrue(VividAuthenticationRecoveryPolicy.shouldReloadAfterProgress(
            .success,
            activeHeaders: active,
            currentHeaders: refreshed
        ))
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.shouldReloadAfterProgress(
            .success,
            activeHeaders: refreshed,
            currentHeaders: refreshed
        ))
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.shouldReloadAfterProgress(
            .missingSession,
            activeHeaders: active,
            currentHeaders: refreshed
        ))
        XCTAssertFalse(VividAuthenticationRecoveryPolicy.shouldReloadAfterProgress(
            .transientFailure,
            activeHeaders: active,
            currentHeaders: refreshed
        ))
    }

    func testHeaderAuthenticatedStreamRejectsAbsoluteAndNonMediaRoutes() {
        for raw in [
            "https://dev.example.test/api/v1/stream/session-1",
            "https://cdn.example.test/stream/session-1",
            "//cdn.example.test/stream/session-1",
            "/admin/settings",
            "/api/v1/stream/session-1",
            "/stream/../admin/settings",
            "/stream/%2e%2e/admin/settings",
            "/stream/session-1?st=legacy-secret",
            "/stream/session-1?token=legacy-secret",
            "/stream/session-1?access_token=legacy-secret",
            "/stream/session-1?credential=legacy-secret",
            "/stream/session-1?seek=not-a-number",
            "/stream/session-1?seek=-1",
            "/stream/session-1?seek=12&seek=13",
            "/stream/session-1#token=legacy-secret",
            "file:///private/movie.mkv",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly accepted \(raw)")
        }
    }

    func testHeaderAuthenticatedStreamAcceptsSubtitleArtifactIdentifiers() throws {
        for raw in [
            "/stream/session-1/subtitles/2.vtt?file_id=631745",
            "/stream/session-1/subtitles/2.vtt?file_id=631745&downloaded_subtitle_id=8",
            "/stream/session-1/subtitles/2/fonts?file_id=631745",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly rejected \(raw)")
            XCTAssertEqual(
                request.url.absoluteString,
                "https://dev.example.test/api/v1" + raw
            )
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        }
    }

    func testHeaderAuthenticatedStreamRejectsSubtitleIdentifiersOnMediaAndMalformedValues() {
        for raw in [
            // Media routes keep the seek-only rule.
            "/stream/session-1?file_id=631745",
            "/stream/session-1/master.m3u8?file_id=631745",
            "/playback/transcode/session-1/master.m3u8?downloaded_subtitle_id=8",
            // Unknown names stay rejected on the subtitle artifact family.
            "/stream/session-1/subtitles/2.vtt?st=legacy-secret",
            "/stream/session-1/subtitles/2.vtt?file_id=631745&token=legacy-secret",
            // Non-negative integers only, and no duplicates.
            "/stream/session-1/subtitles/2.vtt?file_id=-1",
            "/stream/session-1/subtitles/2.vtt?file_id=abc",
            "/stream/session-1/subtitles/2.vtt?file_id=1.5",
            "/stream/session-1/subtitles/2.vtt?file_id=",
            "/stream/session-1/subtitles/2.vtt?downloaded_subtitle_id=-8",
            "/stream/session-1/subtitles/2.vtt?file_id=1&file_id=2",
            "/stream/session-1/subtitles/2.vtt?file_id=1#token=legacy-secret",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly accepted \(raw)")
        }
    }

    // MARK: - authorized_media_origins_v1

    private static let proxyOrigin = "https://proxy.example.test:8443"

    func testAuthorizedOriginsStillAcceptRelativeAPIMediaURLs() throws {
        for raw in [
            "/stream/v3/session-1",
            "/stream/v3/session-1/master.m3u8?seek=12",
            "/playback/transcode/session-1/master.m3u8",
            "/stream/session-1/subtitles/2.vtt?file_id=631745",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly rejected \(raw)")
            XCTAssertEqual(request.url.absoluteString, "https://dev.example.test/api/v1" + raw)
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        }
    }

    func testAuthorizedOriginsAcceptProxyMediaFamilyVerbatim() throws {
        for raw in [
            "\(Self.proxyOrigin)/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12.5",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8?seek=0",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-00042.m4s",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: ["X-Transport": "preserved"],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly rejected \(raw)")
            // Used exactly as handed: no `/api/v1` prefix, no rewriting.
            XCTAssertEqual(request.url.absoluteString, raw)
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
            XCTAssertEqual(request.headers["X-Transport"], "preserved")
            XCTAssertEqual(request.serverUrl, "https://dev.example.test")
        }
    }

    func testAuthorizedOriginsAcceptHTTPProxyWhenServerIsHTTP() throws {
        let raw = "http://proxy.example.test:8080/stream/v3/session-1"
        let request = try XCTUnwrap(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "http://dev.example.test",
            additionalHeaders: ["X-Transport": "preserved"],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ), "unexpectedly rejected \(raw) with an http server")
        XCTAssertEqual(request.url.absoluteString, raw)
        XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        XCTAssertEqual(request.headers["X-Transport"], "preserved")
    }

    func testAuthorizedOriginsRejectHTTPProxyWhenServerIsHTTPS() {
        let raw = "http://proxy.example.test:8080/stream/v3/session-1"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ), "an https deployment must never downgrade the bearer to an http proxy origin")
    }

    func testProxyMediaURLsAreRejectedWithoutNegotiatedOrigins() {
        for raw in [
            "\(Self.proxyOrigin)/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-1.m4s",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly accepted \(raw) without negotiated origins")

            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: false
            ), "unexpectedly accepted \(raw) in legacy mode")
        }
    }

    func testAuthorizedOriginsRejectEverythingOutsideTheProxyMediaFamily() {
        for raw in [
            // Wrong route family, or the API family spelled absolutely.
            "\(Self.proxyOrigin)/stream/session-1",
            "\(Self.proxyOrigin)/api/v1/stream/v3/session-1",
            "\(Self.proxyOrigin)/playback/transcode/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3",
            "\(Self.proxyOrigin)/stream/v3/",
            "\(Self.proxyOrigin)/stream/v3/session-1/",
            "\(Self.proxyOrigin)/stream/v3/session-1/index.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8/extra",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-1/extra",
            "\(Self.proxyOrigin)/stream/v3/session-1/subtitles/0.vtt",
            // Traversal and encoded separators.
            "\(Self.proxyOrigin)/stream/v3/session-1/../../admin/settings",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/%2e%2e",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/a%2fb",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/a%5cb",
            // Credentials, fragments, foreign schemes, scheme-relative.
            "https://user:pass@proxy.example.test/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1#token=legacy-secret",
            "ftp://proxy.example.test/stream/v3/session-1",
            "//proxy.example.test/stream/v3/session-1",
            // Query allowlist: `seek` only, and subtitle identifiers never
            // travel on an absolute URL.
            "\(Self.proxyOrigin)/stream/v3/session-1?st=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?access_token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?file_id=631745",
            "\(Self.proxyOrigin)/stream/v3/session-1?downloaded_subtitle_id=8",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12&token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12&seek=13",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=not-a-number",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=-1",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly accepted \(raw)")
        }
    }

    func testAuthorizedOriginsRejectAnotherSessionsGrant() throws {
        let foreign = "\(Self.proxyOrigin)/stream/v3/session-2/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: foreign,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ))
    }

    func testAuthorizedOriginsRejectEmptySessionId() {
        let raw = "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: ""
        ), "empty session id must not enable absolute proxy URLs")
    }

    func testAuthorizedOriginsRejectWhitespaceOnlySessionId() {
        let raw = "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: " "
        ), "whitespace-only session id must not enable absolute proxy URLs")
    }

    func testAuthorizedOriginsDoNotRelaxTheRelativeMediaContract() {
        for raw in [
            "/admin/settings",
            "/api/v1/stream/v3/session-1",
            "/stream/../admin/settings",
            "/stream/v3/session-1?st=legacy-secret",
            "/stream/v3/session-1#token=legacy-secret",
            "file:///private/movie.mkv",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly accepted \(raw)")
        }
    }

    func testLegacyResolutionStillNeverForwardsBearerAcrossOrigins() {
        XCTAssertNil(StreamRequest.resolve(
            rawURL: "https://cdn.example.test/movie.mkv",
            serverURL: "https://dev.example.test",
            additionalHeaders: ["Authorization": "Bearer private-token"],
            accessToken: "private-token",
            requiresHeaderAuthenticatedMedia: false
        ))

        let offline = StreamRequest.resolve(
            rawURL: "file:///private/movie.mkv",
            serverURL: "https://dev.example.test",
            additionalHeaders: ["Authorization": "Bearer private-token"],
            accessToken: "private-token",
            requiresHeaderAuthenticatedMedia: false
        )
        XCTAssertEqual(offline?.url.absoluteString, "file:///private/movie.mkv")
        XCTAssertEqual(offline?.headers, [:])
    }

    func testV3FixtureMapsToAuthenticatedVividLoad() throws {
        let response = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self,
            named: "decision_response",
            bundleClass: Self.self
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable fixture")
        }
        let resolvedSource = try XCTUnwrap(URL(string: "https://dev.example.test/media/file"))
        let spec = try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: resolvedSource,
            requestHeaders: [
                "X-Plan-Header": "preserved",
                "Authorization": "Bearer current-token",
            ],
            resolveURL: { URL(string: $0, relativeTo: URL(string: "https://dev.example.test")) },
            audioSourceStreamIndex: 7,
            preferredAudioLanguages: ["eng"]
        )

        XCTAssertEqual(spec.sourceURL, resolvedSource)
        XCTAssertEqual(spec.timeline.vividStartPosition, 12.5)
        XCTAssertEqual(spec.options.httpHeaders, [
            "X-Plan-Header": "preserved",
            "Authorization": "Bearer current-token",
        ])
        XCTAssertEqual(spec.options.preferredAudioLanguages, ["eng"])
        XCTAssertEqual(
            spec.options.preferredSubtitleLanguages,
            [],
            "the V3 plan's exact subtitle artifact must not be overridden by engine language policy"
        )
        XCTAssertEqual(spec.options.nativeSubtitlePreferredLanguages, [])
        XCTAssertEqual(spec.audioSourceStreamIndex, 7)
        XCTAssertFalse(spec.options.audioOnly)
        XCTAssertFalse(spec.options.autoplay)
        XCTAssertFalse(spec.options.nativeRemoteHLS)
    }

    func testServerHLSUsesVividAuthenticatedRemoteBypass() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        planObject["delivery"] = PlaybackProtocolV3.PlanDelivery.transcodeHLS
        var streamObject = try XCTUnwrap(planObject["stream"] as? [String: Any])
        streamObject["protocol"] = "hls"
        streamObject["container"] = "mpegts"
        streamObject["mime_type"] = "application/vnd.apple.mpegurl"
        streamObject["headers"] = ["Authorization": "Bearer test"]
        planObject["stream"] = streamObject
        object["playback_plan"] = planObject
        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable HLS fixture")
        }

        let spec = try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            resolveURL: { URL(string: $0, relativeTo: URL(string: "https://dev.example.test")) }
        )

        XCTAssertTrue(spec.options.nativeRemoteHLS)
        XCTAssertEqual(spec.options.httpHeaders["Authorization"], "Bearer test")
    }

    func testV3CredentialReloadTranslatesCurrentSourcePositionOntoPlanTimeline() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var timeline = try XCTUnwrap(planObject["timeline"] as? [String: Any])
        timeline["source_start_seconds"] = 42.5
        timeline["stream_origin_seconds"] = 30.0
        timeline["player_start_seconds"] = 12.5
        timeline["timeline_offset_seconds"] = 30.0
        planObject["timeline"] = timeline
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable fixture")
        }
        let spec = try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: false,
            sourceURLOverride: URL(string: "https://dev.example.test/api/v1/stream/session"),
            requestHeaders: ["Authorization": "Bearer refreshed-token"],
            resumeSourcePosition: 92.0,
            panelIsInHDRMode: false
        )

        XCTAssertEqual(spec.timeline.vividStartPosition, 12.5)
        XCTAssertEqual(spec.vividStartPosition, 62.0)
    }

    func testV3MediaKeepsCurrentHeadersWithoutLoadingSubtitleArtifacts() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = [
            "id": "file:42:subtitle:0",
            "index": 0,
        ]
        planObject["selected_tracks"] = selectedTracks
        var subtitle = try XCTUnwrap(planObject["subtitle"] as? [String: Any])
        subtitle["mode"] = "render"
        subtitle["track_id"] = "file:42:subtitle:0"
        subtitle["artifact"] = [
            "url": "/stream/session/subtitles/0.vtt",
            "mime_type": "text/vtt",
            "format": "vtt",
            "timing_origin_seconds": 0,
        ]
        planObject["subtitle"] = subtitle
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable subtitle fixture")
        }
        let currentHeaders = [
            "X-Plan-Header": "preserved",
            "Authorization": "Bearer refreshed-token",
        ]
        let spec = try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: URL(string: "https://dev.example.test/media")!,
            requestHeaders: currentHeaders,
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            }
        )

        XCTAssertEqual(spec.options.httpHeaders, currentHeaders)
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
    }

    func testV3ProxyMediaDoesNotMountServerSubtitles() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = ["id": "file:42:subtitle:0", "index": 0]
        planObject["selected_tracks"] = selectedTracks
        var subtitle = try XCTUnwrap(planObject["subtitle"] as? [String: Any])
        subtitle["mode"] = "render"
        subtitle["track_id"] = "file:42:subtitle:0"
        subtitle["artifact"] = [
            "url": "/stream/session/subtitles/0.vtt",
            "mime_type": "text/vtt",
            "format": "vtt",
            "timing_origin_seconds": 0,
        ]
        planObject["subtitle"] = subtitle
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable subtitle fixture")
        }
        let currentHeaders = ["Authorization": "Bearer current-token"]
        let proxySource = try XCTUnwrap(
            URL(string: "\(Self.proxyOrigin)/stream/v3/\(sessionID)")
        )
        let spec = try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: proxySource,
            requestHeaders: currentHeaders,
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            },
            apiOriginURL: URL(string: "https://dev.example.test")
        )

        XCTAssertEqual(spec.options.httpHeaders, currentHeaders)
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
    }

    func testV3IgnoresExternalSubtitleArtifactURLs() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        let fixtureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )

        for artifactURL in [
            "https://subtitles.example.net/movie.vtt",
            "/admin/settings",
            "/stream/session/../admin/settings",
            "/stream/session/subtitle.vtt?st=legacy-secret",
            "/stream/session/subtitle.vtt?credential=legacy-secret",
        ] {
            var object = fixtureObject
            var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
            var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
            selectedTracks["subtitle"] = ["id": "file:42:subtitle:0", "index": 0]
            planObject["selected_tracks"] = selectedTracks
            var subtitle = try XCTUnwrap(planObject["subtitle"] as? [String: Any])
            subtitle["mode"] = "render"
            subtitle["track_id"] = "file:42:subtitle:0"
            subtitle["artifact"] = [
                "url": artifactURL,
                "mime_type": "text/vtt",
                "format": "vtt",
                "timing_origin_seconds": 0,
            ]
            planObject["subtitle"] = subtitle
            object["playback_plan"] = planObject
            let response = try PlaybackV3FixtureTestSupport.decoder.decode(
                PlaybackV3DecisionResponse.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
                return XCTFail("Expected a playable subtitle fixture")
            }

            let spec = try VividLoadSpec(
                validating: plan,
                sessionID: sessionID,
                matchContentEnabled: true,
                sourceURLOverride: URL(string: "https://dev.example.test/api/v1/stream/session")!,
                requestHeaders: ["Authorization": "Bearer current-token"],
                resolveURL: {
                    StreamRequest.resolve(
                        rawURL: $0,
                        serverURL: "https://dev.example.test",
                        additionalHeaders: [:],
                        accessToken: nil,
                        requiresHeaderAuthenticatedMedia: true
                    )?.url
                }
            )
            XCTAssertTrue(spec.options.externalSubtitles.isEmpty, "Mounted an external subtitle")
        }
    }

    func testOfflineLoadUsesEmbeddedSubtitlesOnly() throws {
        let media = URL(fileURLWithPath: "/tmp/vivid-offline/movie.mkv")
        let spec = try VividLoadSpec(
            offlineURL: media,
            startPosition: 91,
            audioOnly: false,
            audioSourceStreamIndex: 7,
            preferredAudioLanguages: ["eng"],
            forwardBufferSegments: Int.max
        )

        XCTAssertEqual(spec.sourceURL, media)
        XCTAssertEqual(spec.timeline.vividStartPosition, 91)
        XCTAssertEqual(spec.audioSourceStreamIndex, 7)
        XCTAssertEqual(spec.options.preferredAudioLanguages, ["eng"])
        XCTAssertEqual(spec.options.forwardBufferSegments, Int.max)
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
        XCTAssertThrowsError(try VividLoadSpec(
            offlineURL: URL(string: "https://example.test/movie.mkv")!,
            startPosition: 0,
            audioOnly: false
        ))
    }

    func testDirectLoadKeepsMediaBearerWithoutMountingExternalSubtitles() throws {
        let media = try XCTUnwrap(URL(string: "https://dev.example.test/media/movie.mkv"))
        let spec = try VividLoadSpec(
            directURL: media,
            headers: ["Authorization": "Bearer media-token"],
            startPosition: 0,
            audioOnly: false
        )

        XCTAssertEqual(spec.options.httpHeaders["Authorization"], "Bearer media-token")
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
    }

    /// The reproduction for the ordering mismatch: a plan whose subtitle mode
    /// is `off` declares no external track to Vivid, so it must publish no
    /// alias either — even when a stale artifact and `track_id` survive on the
    /// decision. An alias here would claim Vivid id `base + 0`, which belongs
    /// to whichever sidecar is registered first afterwards (Arabic), so picking
    /// English would render Arabic.
    func testSubtitlesOffPublishesNoDeclaredAliasDespiteStaleArtifact() throws {
        let plan = try sidecarInventoryPlan(
            mode: "off",
            selectedTrackId: "file:42:subtitle:2",
            includeArtifact: true
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)

        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
    }

    /// Server inventory must not become player tracks or subtitle aliases.
    func testServerSubtitleInventoryDoesNotCreatePlayerTracks() throws {
        let plan = try sidecarInventoryPlan(
            mode: "off",
            selectedTrackId: "file:42:subtitle:2",
            includeArtifact: true
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        controller.beginLoad(spec)

        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
        XCTAssertTrue(controller.engine.subtitleTracks.isEmpty)
        for item in plan.plan.subtitle.inventory {
            let serverTrackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            XCTAssertFalse(controller.containsSubtitle(appTrackID: serverTrackID))
            XCTAssertNil(controller.vividSubtitleID(forAppID: serverTrackID))
        }
    }

    /// Server artifacts are not registered as local subtitle tracks.
    func testServerSelectedSubtitleArtifactCreatesNoPlayerTrack() throws {
        let plan = try sidecarInventoryPlan(mode: "render", selectedTrackId: "file:42:subtitle:2", includeArtifact: true)
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        controller.beginLoad(spec)
        for index in 0...3 {
            XCTAssertFalse(controller.containsSubtitle(appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: index)))
        }
    }

    func testServerSubtitleIdentityDoesNotCreateALocalAlias() throws {
        let plan = try sidecarInventoryPlan(
            mode: "render",
            selectedTrackId: "file:42:subtitle:3",
            includeArtifact: true,
            decisionTrackId: "opaque-selected-track"
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)

        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
    }

    /// The four-sidecar inventory from the reported file: ar, da, en, es at
    /// combined indices 0...3 plus an embedded PGS track at 4.
    private func sidecarInventoryPlan(
        mode: String,
        selectedTrackId: String,
        includeArtifact: Bool,
        decisionTrackId: String? = nil
    ) throws -> (plan: PlaybackV3Plan, sessionID: String) {
        let selectedCombinedIndex = try XCTUnwrap(
            Int(selectedTrackId.split(separator: ":").last ?? "")
        )
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var inventory: [[String: Any]] = [
            ("ara", "Arabic"), ("dan", "Danish"), ("eng", "English"), ("spa", "Spanish"),
        ].enumerated().map { combinedIndex, entry in
            [
                "track_id": "file:42:subtitle:\(combinedIndex)",
                "combined_index": combinedIndex,
                "source": "external",
                "codec": "srt",
                "language": entry.0,
                "label": entry.1,
                "forced": false,
                "default": false,
                "hearing_impaired": false,
                "delivery": "sidecar",
                "url": "/stream/session/subtitles/\(combinedIndex).srt?file_id=42",
            ]
        }
        inventory.append([
            "track_id": "file:42:subtitle:4",
            "combined_index": 4,
            "source": "embedded",
            "codec": "pgs",
            "language": "jpn",
            "label": "Japanese",
            "forced": false,
            "default": false,
            "hearing_impaired": false,
            "delivery": "burn_in_only",
        ])
        var subtitle: [String: Any] = [
            "mode": mode,
            "track_id": decisionTrackId ?? selectedTrackId,
            "inventory": inventory,
        ]
        if includeArtifact {
            subtitle["artifact"] = [
                "url": "/stream/session/subtitles/\(selectedCombinedIndex).srt?file_id=42",
                "mime_type": "application/x-subrip",
                "format": "srt",
                "timing_origin_seconds": 0,
            ]
        }
        planObject["subtitle"] = subtitle
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = [
            "id": selectedTrackId,
            "index": selectedCombinedIndex,
        ]
        planObject["selected_tracks"] = selectedTracks
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            throw XCTSkip("Expected a playable sidecar-inventory fixture")
        }
        return (plan, sessionID)
    }

    private static func loadSpec(
        for plan: PlaybackV3Plan,
        sessionID: String
    ) throws -> VividLoadSpec {
        try VividLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: false,
            sourceURLOverride: URL(string: "https://dev.example.test/api/v1/stream/session"),
            requestHeaders: ["Authorization": "Bearer current-token"],
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            },
            panelIsInHDRMode: false
        )
    }

    func testMissingEmbeddedStreamIsRejectedBeforePlanCommit() throws {
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        XCTAssertThrowsError(try controller.validateEmbeddedSubtitleSelection(11)) { error in
            XCTAssertTrue(error is VividPlaybackController.EmbeddedSubtitleSelectionError)
        }
    }

    /// Opt-in local fixture: two embedded SRT tracks, with the second stream
    /// at FFmpeg index 3 and text "Native track 2". No sidecar is registered.
    func testOriginalHTTPSelectsExactEmbeddedSubtitleWithoutSidecar() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["VIVID_EMBEDDED_FIXTURE_URL"],
              let url = URL(string: rawURL) else {
            throw XCTSkip("Set VIVID_EMBEDDED_FIXTURE_URL to the local two-track MKV fixture")
        }
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let spec = try VividLoadSpec(directURL: url, headers: [:], startPosition: 0, audioOnly: false)
        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
        let epoch = controller.beginLoad(spec)
        try await controller.finishLoad(epoch)
        try controller.validateEmbeddedSubtitleSelection(3)
        controller.selectSubtitleTrack(id: 3)
        controller.play()
        let deadline = Date().addingTimeInterval(15)
        func containsText(_ text: String) -> Bool {
            controller.engine.subtitleCues.contains { cue in
                if case .text(let value) = cue.body { return value == text }
                return false
            }
        }
        while !containsText("Native track 2"),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(controller.engine.activeSubtitleTrackIndex, 3)
        XCTAssertTrue(containsText("Native track 2"))
        XCTAssertFalse(containsText("Native track 1"))
    }

    func testMovieTimelineUsesExternalTrackStateWithoutRequiringAnAlias() throws {
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let raw = controller.engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/unaliased-subtitle.srt")))
        XCTAssertFalse(controller.containsSubtitle(appTrackID: Int64(raw.id)))
        XCTAssertTrue(controller.subtitleUsesMovieTimeline(appTrackID: Int64(raw.id), slot: .primary))
        XCTAssertTrue(controller.subtitleUsesMovieTimeline(appTrackID: Int64(raw.id), slot: .secondary))
        controller.engine.selectSubtitleTrack(index: raw.id)
        XCTAssertTrue(controller.subtitleUsesMovieTimeline(appTrackID: nil, slot: .primary))
        XCTAssertFalse(controller.subtitleUsesMovieTimeline(appTrackID: nil, slot: .secondary))
        XCTAssertFalse(controller.subtitleUsesMovieTimeline(appTrackID: 3, slot: .primary))
        XCTAssertFalse(controller.subtitleUsesMovieTimeline(
            appTrackID: Int64.max, slot: .primary))
        let alias = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 4)
        controller.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/aliased-subtitle.srt")), appTrackID: alias)
        XCTAssertTrue(controller.subtitleUsesMovieTimeline(appTrackID: alias, slot: .primary))
    }

    func testControllerConstructsOnlyVividEngine() throws {
        let controller = try VividPlaybackController()
        XCTAssertEqual(controller.engine.state, .idle)
        controller.setVolume(0.4)
        controller.setMuted(true)
        controller.setVolume(0.7)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(controller.volume, 0.7, accuracy: 0.001)
        XCTAssertEqual(controller.engine.volume, 0, accuracy: 0.001)
        controller.setMuted(false)
        XCTAssertEqual(controller.engine.volume, 0.7, accuracy: 0.001)

        let appTrackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 42)
        controller.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/subtitle.srt")),
            appTrackID: appTrackID
        )
        XCTAssertTrue(controller.containsSubtitle(appTrackID: appTrackID))
        XCTAssertEqual(
            controller.appSubtitleID(forVividID: VividEngine.externalSubtitleTrackIDBase),
            appTrackID
        )
        controller.stop()
    }

    func testReplacementPreparationInvalidatesOutgoingLoadAndAllowsSuccessorEpoch() throws {
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let spec = try VividLoadSpec(
            directURL: URL(string: "https://dev.example.test/api/v1/stream/session")!,
            headers: [:],
            startPosition: 0,
            audioOnly: false
        )

        let outgoingEpoch = controller.beginLoad(spec)
        XCTAssertEqual(controller.activeLoadEpoch, outgoingEpoch)
        XCTAssertNotNil(controller.activeSpec)
        XCTAssertTrue(controller.shouldPlayWhenReady)

        controller.prepareForReplacement()

        XCTAssertNil(controller.activeLoadEpoch)
        XCTAssertNil(controller.activeSpec)
        XCTAssertEqual(controller.engine.state, .idle)
        XCTAssertTrue(controller.shouldPlayWhenReady)

        let successorEpoch = controller.beginLoad(spec)
        XCTAssertNotEqual(successorEpoch, outgoingEpoch)
        XCTAssertEqual(controller.activeLoadEpoch, successorEpoch)
    }

    func testReplacementExternalPlaybackPolicyOnlyWinsForReceiverSafeSuccessor() {
        XCTAssertTrue(VividPlaybackController.externalPlaybackAllowed(
            activePolicy: false,
            preservedReplacementPolicy: true,
            preservedPolicyIsReceiverSafe: true
        ))
        XCTAssertFalse(VividPlaybackController.externalPlaybackAllowed(
            activePolicy: false,
            preservedReplacementPolicy: true,
            preservedPolicyIsReceiverSafe: false
        ))
        XCTAssertFalse(VividPlaybackController.externalPlaybackAllowed(
            activePolicy: true,
            preservedReplacementPolicy: false,
            preservedPolicyIsReceiverSafe: true
        ))
        XCTAssertTrue(VividPlaybackController.externalPlaybackAllowed(
            activePolicy: true,
            preservedReplacementPolicy: nil,
            preservedPolicyIsReceiverSafe: false
        ))
    }

    /// Opt-in shared-dev proof for the complete server -> StreamRequest ->
    /// Vivid boundary. The fixture stays outside the repository because it
    /// contains a short-lived bearer credential. Normal test runs skip this;
    /// validation supplies only its mode-0600 path through the test process
    /// environment.
    func testLiveHeaderAuthenticatedStreamLoadsAndAdvancesInVivid() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["VIVID_LIVE_FIXTURE_PATH"],
              !fixturePath.isEmpty else {
            throw XCTSkip("Set VIVID_LIVE_FIXTURE_PATH for shared-dev playback proof")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        let fixtures: [LiveStreamFixture]
        if let envelope = try? decoder.decode(LiveStreamFixtureEnvelope.self, from: data) {
            fixtures = envelope.streams
        } else {
            fixtures = [try decoder.decode(LiveStreamFixture.self, from: data)]
        }
        XCTAssertFalse(fixtures.isEmpty, "Live fixture envelope must contain at least one stream")

        for fixture in fixtures {
            try await assertLiveFixtureLoadsAndAdvances(fixture)
        }
    }

    private func assertLiveFixtureLoadsAndAdvances(_ fixture: LiveStreamFixture) async throws {
        let label = fixture.label ?? "live stream"
        guard let scheme = fixture.url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              fixture.url.host != nil else {
            return XCTFail("\(label): URL must be an absolute HTTP(S) URL")
        }
        XCTAssertNotNil(
            fixture.headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame },
            "\(label): fixture must exercise Vivid's authenticated HTTP transport"
        )

        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let spec = try VividLoadSpec(
            directURL: fixture.url,
            headers: fixture.headers,
            startPosition: 0,
            audioOnly: false
        )
        let epoch = controller.beginLoad(spec)
        try await controller.finishLoad(epoch)

        XCTAssertNotEqual(controller.engine.videoRoute, .none)
        XCTAssertGreaterThan(controller.engine.duration, 0)
        XCTAssertFalse(controller.engine.audioTracks.isEmpty)

        controller.play()
        let deadline = Date().addingTimeInterval(15)
        while controller.engine.clock.currentTime <= 0.25, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(
            controller.engine.clock.currentTime,
            0.25,
            "\(label): Vivid loaded the authenticated source but its playback clock never advanced"
        )
    }

    // MARK: - Deferred track selection

    // Vivid publishes its track inventory during startup, before it has
    // dispatched the source onto a decode backend. A deferred pick applied
    // there makes the engine rebuild its pipeline on a route it has not chosen
    // yet, which on a software-decode source (VC-1) is rejected for the codec
    // and takes the in-flight load down with it — the player then sits on the
    // spinner forever. The gate is what keeps that pick held.

    func testDeferredTrackSelectionIsHeldUntilTheLoadIsEstablished() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: false,
                engineAlreadyMatches: false
            ),
            .deferUntilEstablished
        )
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: false,
                engineAlreadyMatches: true
            ),
            .deferUntilEstablished,
            "an unestablished load must not consume the pending pick even when it looks satisfied"
        )
    }

    func testEstablishedLoadSkipsTheEngineCallWhenTheTrackAlreadyMatches() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: true,
                engineAlreadyMatches: true
            ),
            .adoptWithoutEngineCall
        )
    }

    func testEstablishedLoadDrivesTheEngineWhenTheTrackDiffers() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: true,
                engineAlreadyMatches: false
            ),
            .applyToEngine
        )
    }

    // MARK: - Play during in-flight load

    // `beginLoad` installs spec/epoch before `engine.load` returns. That
    // window looks like a background teardown (route `.none`, session not
    // ready). Play in that window must not call `reloadAtCurrentPosition()`,
    // which starts a second `load` and cancels startup.

    func testPlayDuringUncommittedLoadDoesNotRestore() {
        XCTAssertEqual(
            VividPlayIntent.action(
                hasCommittedActiveLoad: false,
                sessionRequiresRestore: true
            ),
            .ignore
        )
        XCTAssertEqual(
            VividPlayIntent.action(
                hasCommittedActiveLoad: false,
                sessionRequiresRestore: false
            ),
            .ignore,
            "an uncommitted load must not start transport even when the route looks live"
        )
    }

    func testTransportIntentCanChangeDuringAnUncommittedLoad() throws {
        let controller = try VividPlaybackController()
        defer { controller.stop() }
        let spec = try VividLoadSpec(
            directURL: URL(string: "https://dev.example.test/media.mp4")!,
            headers: [:],
            startPosition: 0,
            audioOnly: false
        )

        controller.beginLoad(spec, shouldPlayWhenReady: false)
        XCTAssertFalse(controller.shouldPlayWhenReady)

        // Play is deliberately ignored by the engine until finishLoad, but
        // the user's intent must still be retained for the commit boundary.
        controller.play()
        XCTAssertTrue(controller.shouldPlayWhenReady)

        controller.pause()
        XCTAssertFalse(controller.shouldPlayWhenReady)
    }

    func testPlayAfterCommitRestoresATornDownSession() {
        XCTAssertEqual(
            VividPlayIntent.action(
                hasCommittedActiveLoad: true,
                sessionRequiresRestore: true
            ),
            .restoreThenPlay
        )
    }

    func testPlayAfterCommitStartsTransportWhenTheSessionIsLive() {
        XCTAssertEqual(
            VividPlayIntent.action(
                hasCommittedActiveLoad: true,
                sessionRequiresRestore: false
            ),
            .play
        )
    }
}

// A real loopback server exercises the production ephemeral URLSession. Global
// URLProtocol registration is not reliably inherited by that session on iOS.
private final class CredentialPlaybackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "VividTests.credentialPlayback")
    private let media: Data
    private var connections: [NWConnection] = []

    init(media: Data) throws {
        self.media = media
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var waiting = true
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, waiting else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    waiting = false
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/media.mkv")!)
                case .failed(let error):
                    waiting = false
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            guard request.count <= 32_768, error == nil else { connection.cancel(); return }
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(connection, request: text)
            } else if complete {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
        let range = rangeLine?.dropFirst("Range: bytes=".count).split(separator: "-") ?? []
        guard range.count == 2, let start = Int(range[0]), let requestedEnd = Int(range[1]),
              start >= 0, start < media.count, requestedEnd >= start else {
            connection.cancel()
            return
        }
        let end = min(requestedEnd, media.count - 1)
        let headers = "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Range: bytes \(start)-\(end)/\(media.count)\r\nContent-Length: \(end - start + 1)\r\nETag: \"playback-fixture\"\r\nConnection: close\r\n\r\n"
        let response = Data(headers.utf8) + media.subdata(in: start..<(end + 1))
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
