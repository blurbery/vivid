import Foundation
import XCTest
@testable import Vivid

final class SiloAirPlayReceiverTests: XCTestCase {
    private let apiBase = URL(string: "https://media.example.com/silo/api/v2")!
    private let session = "11111111-1111-4111-8111-111111111111"
    /// Shaped like a signed reference, with characters re-encoding would change.
    private let reference = "eyJhbGciOi.J9-abc_def%2B%2F%3D"

    // MARK: - Capabilities

    func testReceiverFeaturesLeaveOutHeaderAuthenticationAndAuthorisedOrigins() {
        let features = SiloAirPlayReceiver.startFeatures
        XCTAssertTrue(features.contains(PlaybackProtocolV3.planFeature))
        XCTAssertFalse(features.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature))
        XCTAssertFalse(features.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature))
        XCTAssertFalse(features.contains(PlaybackProtocolV3.clientTransformFeature))
        XCTAssertFalse(features.contains(PlaybackProtocolV3.embeddedSubtitlesFeature))
        XCTAssertFalse(features.contains(PlaybackProtocolV3.softwareVideoDecodeFeature))
    }

    func testReceiverDeliveriesDescribeOnlyWhatAnAirPlayReceiverPlays() throws {
        let snapshot = SiloAirPlayReceiver.snapshot(base: ApplePlaybackV3Capabilities.snapshot())
        let deliveries = snapshot.context.deliveries

        let original = try XCTUnwrap(deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP])
        XCTAssertTrue(original.enabled && original.supportedOnDevice)
        XCTAssertEqual(Set(original.containers), ["mp4", "mov", "m4v"])
        XCTAssertEqual(Set(original.videoCodecs), ["h264", "hevc"])
        XCTAssertEqual(Set(original.audioDecodeCodecs), ["aac", "ac3", "eac3", "alac"])

        let progressive = try XCTUnwrap(deliveries[PlaybackProtocolV3.DeliveryClass.progressive])
        XCTAssertFalse(progressive.enabled)
        XCTAssertFalse(progressive.supportedOnDevice)

        let hls = try XCTUnwrap(deliveries[PlaybackProtocolV3.DeliveryClass.hls])
        XCTAssertTrue(hls.enabled && hls.supportedOnDevice)
        XCTAssertEqual(Set(hls.containers), ["hls", "mpegts", "fmp4"])
        XCTAssertEqual(Set(hls.videoCodecs), ["h264", "hevc"])
        XCTAssertEqual(Set(hls.audioDecodeCodecs), ["aac", "ac3", "eac3"])

        for delivery in deliveries.values {
            XCTAssertTrue(delivery.validatedClaims.isEmpty)
            XCTAssertTrue(delivery.transformations.isEmpty)
            XCTAssertTrue(delivery.audioPassthroughCodecs.isEmpty)
            XCTAssertFalse(delivery.subtitles.embeddedText || delivery.subtitles.sidecarText
                || delivery.subtitles.embeddedBitmap || delivery.subtitles.sidecarBitmap)
            XCTAssertNil(delivery.subtitles.nativeEmbedded)
            XCTAssertEqual(delivery.hdrDetails?.dolbyVisionProfiles, [])
        }
    }

    func testReceiverSnapshotDeclaresConservativeHDRAndItsOwnOutput() {
        let base = ApplePlaybackV3Capabilities.snapshot()
        let snapshot = SiloAirPlayReceiver.snapshot(base: base)

        let hdr = snapshot.context.output.hdrDetails
        XCTAssertEqual(hdr?.hdr10, true)
        XCTAssertEqual(hdr?.hlg, true)
        XCTAssertEqual(hdr?.hdr10Plus, false)
        XCTAssertEqual(hdr?.dolbyVisionProfiles, [])
        XCTAssertNil(snapshot.context.output.audioPassthrough)
        XCTAssertEqual(snapshot.capabilities.videoEvidence, PlaybackProtocolV3.Evidence.declared)
        XCTAssertTrue(snapshot.capabilities.videoDecode.isEmpty)
        XCTAssertEqual(Set(snapshot.capabilities.codecsVideo), ["h264", "hevc"])

        let receiverId = snapshot.outputContextId
        XCTAssertNotNil(receiverId)
        XCTAssertNotEqual(receiverId, base.outputContextId)
        XCTAssertTrue(receiverId?.hasPrefix("apple-airplay:") == true)
        XCTAssertEqual(receiverId, SiloAirPlayReceiver.snapshot(base: base).outputContextId)
        XCTAssertEqual(snapshot.context.device, base.context.device)
    }

    // MARK: - API base

    func testAPIBaseIsOnlyOfferedForNativeV2() {
        XCTAssertEqual(
            SiloAirPlayReceiver.apiBase(serverURL: "https://media.example.com/silo/", nativeApiMajor: 2)?.absoluteString,
            "https://media.example.com/silo/api/v2"
        )
        XCTAssertNil(SiloAirPlayReceiver.apiBase(serverURL: "https://media.example.com", nativeApiMajor: nil))
        XCTAssertNil(SiloAirPlayReceiver.apiBase(serverURL: "https://user:pw@media.example.com", nativeApiMajor: 2))
    }

    // MARK: - Resolver: accepted forms

    func testRelativeDirectStreamResolvesOnTheAPIBaseWithTheReferenceUntouched() throws {
        let url = try resolve("/stream/\(session)?st=\(reference)")
        XCTAssertEqual(url.absoluteString, "https://media.example.com/silo/api/v2/stream/\(session)?st=\(reference)")
    }

    func testRelativeStreamWithTheV2PrefixResolvesTheSame() throws {
        let url = try resolve("/api/v2/stream/\(session)?st=\(reference)")
        XCTAssertEqual(url.absoluteString, "https://media.example.com/silo/api/v2/stream/\(session)?st=\(reference)")
    }

    func testTranscodeManifestKeepsStAndSeekAndAddsNothing() throws {
        let url = try resolve("/api/v2/playback/transcode/\(session)/master.m3u8?st=\(reference)&seek=12.5")
        XCTAssertEqual(
            url.absoluteString,
            "https://media.example.com/silo/api/v2/playback/transcode/\(session)/master.m3u8?st=\(reference)&seek=12.5"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["st", "seek"])
    }

    func testAbsoluteURLOnTheAPIBaseIsAccepted() throws {
        let raw = "https://media.example.com/silo/api/v2/stream/\(session)?st=\(reference)"
        XCTAssertEqual(try resolve(raw).absoluteString, raw)
    }

    func testProxyFormsOnTheAPIOriginAreAcceptedAsTheyCame() throws {
        for raw in [
            "https://media.example.com/stream/direct/signed-token",
            "https://media.example.com:443/stream/remux/signed-token",
            "https://media.example.com/stream/remux/audio-v2/signed-token",
            "https://media.example.com/stream/transcode/signed-token/master.m3u8",
        ] {
            XCTAssertEqual(try resolve(raw).absoluteString, raw, raw)
        }
        let httpBase = URL(string: "http://192.0.2.10:8080/api/v2")!
        let httpRaw = "http://192.0.2.10:8080/stream/direct/signed-token"
        XCTAssertEqual(
            try SiloAirPlayReceiver.receiverURL(planStreamURL: httpRaw, apiBase: httpBase, sessionId: session).absoluteString,
            httpRaw
        )
    }

    /// A receiver attempt never negotiates authorised media origins, so a
    /// proxy node on another origin is refused.
    func testProxyFormsOnAnotherOriginAreRefused() {
        for raw in [
            "https://proxy.example.net/stream/direct/signed-token",
            "https://proxy.example.net/stream/transcode/signed-token/master.m3u8",
            "https://media.example.com:8443/stream/direct/signed-token",
            "http://media.example.com/stream/direct/signed-token",
            "https://proxy.example.net/silo/api/v2/stream/\(session)?st=\(reference)",
        ] {
            assertRejected(raw, .unsupportedOrigin)
        }
    }

    /// Silo doesn't know the reverse-proxy subpath and emits `/api/v2/…`, so
    /// a relative URL repeating the subpath isn't one of its shapes.
    func testRelativeURLCarryingTheSubpathIsRefused() {
        assertRejected("/silo/api/v2/stream/\(session)?st=\(reference)", .unsupportedPath)
    }

    func testStrippingTheStreamReferenceKeepsEverythingElse() {
        XCTAssertEqual(
            SiloAirPlayReceiver.strippingStreamReference("/api/v2/stream/\(session)?st=\(reference)"),
            "/api/v2/stream/\(session)"
        )
        XCTAssertEqual(
            SiloAirPlayReceiver.strippingStreamReference(
                "/api/v2/playback/transcode/\(session)/master.m3u8?seek=12.5&st=\(reference)&silo_rendition=video"
            ),
            "/api/v2/playback/transcode/\(session)/master.m3u8?seek=12.5&silo_rendition=video"
        )
        XCTAssertEqual(SiloAirPlayReceiver.strippingStreamReference("/stream/\(session)?%73t=x&stx=1"), "/stream/\(session)?stx=1")
        XCTAssertEqual(
            SiloAirPlayReceiver.strippingStreamReference("https://media.example.com/stream/direct/signed-token"),
            "https://media.example.com/stream/direct/signed-token"
        )
    }

    // MARK: - Resolver: rejected forms

    func testAccountCredentialsAreRefused() {
        for raw in [
            "/stream/\(session)?st=\(reference)&token=jwt",
            "/stream/\(session)?token=jwt",
            "/stream/\(session)?st=\(reference)&access_token=jwt",
            "/stream/\(session)?api_key=key&st=\(reference)",
            "/stream/\(session)?ApiKey=key&st=\(reference)",
            "https://proxy.example.net/stream/direct/signed-token?token=jwt",
        ] {
            assertRejected(raw, .credentialInQuery)
        }
    }

    func testOtherQueriesAreRefused() {
        assertRejected("/stream/\(session)?st=\(reference)&remux_range=refuse", .unexpectedQuery)
        assertRejected("/stream/\(session)?st=\(reference)&st=other", .unexpectedQuery)
        assertRejected("/stream/\(session)?st=", .unexpectedQuery)
        assertRejected("/stream/\(session)?st=\(reference)&seek=-1", .unexpectedQuery)
        assertRejected("https://media.example.com/stream/direct/signed-token?seek=12", .unexpectedQuery)
    }

    func testMissingReferenceIsRefused() {
        assertRejected("/stream/\(session)", .missingStreamReference)
        assertRejected("/playback/transcode/\(session)/master.m3u8?seek=4", .missingStreamReference)
    }

    func testAnotherSessionIsRefused() {
        assertRejected("/stream/22222222-2222-4222-8222-222222222222?st=\(reference)", .sessionMismatch)
        assertRejected("/playback/transcode/other/master.m3u8?st=\(reference)", .sessionMismatch)
    }

    func testDotSegmentsAndEncodedSeparatorsAreRefused() {
        for raw in [
            "/stream/../admin/settings?st=\(reference)",
            "/stream/%2e%2e?st=\(reference)",
            "/stream/\(session)%2Fsubtitles?st=\(reference)",
            "/playback/transcode/\(session)%5Cx/master.m3u8?st=\(reference)",
            "https://media.example.com/stream/direct/../../admin",
            "https://media.example.com/stream/direct/a%2Fb",
        ] {
            assertRejected(raw, .unsupportedPath)
        }
    }

    func testOtherRoutesAreRefused() {
        assertRejected("/api/v1/stream/\(session)?st=\(reference)", .unsupportedPath)
        assertRejected("/stream/\(session)/subtitles/2.vtt?st=\(reference)", .unsupportedPath)
        assertRejected("/playback/transcode/\(session)/segment/0001.ts?st=\(reference)", .unsupportedPath)
        // The header-authenticated proxy form needs a bearer the receiver can't send.
        assertRejected("https://media.example.com/stream/v3/\(session)", .unsupportedPath)
        assertRejected("https://media.example.com/silo/api/v1/stream/\(session)?st=\(reference)", .unsupportedPath)
    }

    func testUnsafeOriginsAreRefused() {
        assertRejected("ftp://proxy.example.net/stream/direct/signed-token", .unsupportedOrigin)
        assertRejected("https://user:pw@proxy.example.net/stream/direct/signed-token", .unsupportedOrigin)
        assertRejected("//proxy.example.net/stream/direct/signed-token", .malformedURL)
        assertRejected("/stream/\(session)?st=\(reference)#fragment", .malformedURL)
    }

    func testAPIBaseMustBeV2() {
        let v1 = URL(string: "https://media.example.com/api/v1")!
        XCTAssertThrowsError(
            try SiloAirPlayReceiver.receiverURL(planStreamURL: "/stream/\(session)?st=x", apiBase: v1, sessionId: session)
        ) { XCTAssertEqual($0 as? SiloAirPlayReceiverError, .unsupportedAPIBase) }
    }

    // MARK: - Plan to stream

    func testTranscodePlanBecomesAReceiverStreamOnTheSourceAxis() throws {
        let plan = makePlan(
            delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS,
            streamProtocol: "hls",
            container: "hls",
            url: "/api/v2/playback/transcode/\(session)/master.m3u8?st=\(reference)",
            timelineOffset: 600
        )
        let stream = try SiloAirPlayReceiver.receiverStream(plan: plan, sessionId: session, apiBase: apiBase)
        XCTAssertEqual(stream.sourceOffset, 600)
        XCTAssertTrue(stream.isTranscode)
        XCTAssertEqual(stream.serverSessionId, session)
        XCTAssertFalse(stream.showsSubtitleRendition)
        XCTAssertEqual(
            stream.url.absoluteString,
            "https://media.example.com/silo/api/v2/playback/transcode/\(session)/master.m3u8?st=\(reference)"
        )
    }

    func testOriginalMP4PlanIsDirect() throws {
        let plan = makePlan(
            delivery: PlaybackProtocolV3.PlanDelivery.originalHTTP,
            streamProtocol: "http_progressive",
            container: "mp4",
            url: "/api/v2/stream/\(session)?st=\(reference)",
            timelineOffset: 0
        )
        let stream = try SiloAirPlayReceiver.receiverStream(plan: plan, sessionId: session, apiBase: apiBase)
        XCTAssertFalse(stream.isTranscode)
        XCTAssertEqual(stream.sourceOffset, 0)
    }

    func testPlansTheReceiverCantPlayAreRefused() {
        let matroska = makePlan(delivery: PlaybackProtocolV3.PlanDelivery.originalHTTP, streamProtocol: "http_progressive",
                                container: "mkv", url: "/stream/\(session)?st=\(reference)", timelineOffset: 0)
        XCTAssertThrowsError(try SiloAirPlayReceiver.validate(matroska)) {
            XCTAssertEqual($0 as? SiloAirPlayReceiverError, .unsupportedContainer("mkv"))
        }
        let progressive = makePlan(delivery: PlaybackProtocolV3.PlanDelivery.remuxProgressive, streamProtocol: "http_progressive",
                                   container: "mp4", url: "/stream/\(session)?st=\(reference)", timelineOffset: 0)
        XCTAssertThrowsError(try SiloAirPlayReceiver.validate(progressive)) {
            XCTAssertEqual($0 as? SiloAirPlayReceiverError, .unsupportedDelivery(PlaybackProtocolV3.PlanDelivery.remuxProgressive))
        }
        let headers = makePlan(delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS, streamProtocol: "hls", container: "hls",
                               url: "/playback/transcode/\(session)/master.m3u8?st=\(reference)", timelineOffset: 0,
                               headerRefresh: "session")
        XCTAssertThrowsError(try SiloAirPlayReceiver.validate(headers)) {
            XCTAssertEqual($0 as? SiloAirPlayReceiverError, .requiresHeaders)
        }
    }

    // MARK: - Helpers

    private func resolve(_ raw: String) throws -> URL {
        try SiloAirPlayReceiver.receiverURL(planStreamURL: raw, apiBase: apiBase, sessionId: session)
    }

    private func assertRejected(_ raw: String, _ expected: SiloAirPlayReceiverError, line: UInt = #line) {
        XCTAssertThrowsError(try resolve(raw), raw, line: line) {
            XCTAssertEqual($0 as? SiloAirPlayReceiverError, expected, raw, line: line)
        }
    }

    private func makePlan(
        delivery: String,
        streamProtocol: String,
        container: String,
        url: String,
        timelineOffset: Double,
        headerRefresh: String = "none"
    ) -> PlaybackV3Plan {
        PlaybackV3Plan(
            nativeApiMajor: 2,
            protocolVersion: 3,
            planId: "plan:receiver",
            sessionId: session,
            expiresAt: "2030-01-01T00:00:00Z",
            delivery: delivery,
            planAttemptKey: "v3:receiver",
            stream: PlaybackV3Stream(
                url: url,
                protocol: streamProtocol,
                container: container,
                mimeType: streamProtocol == "hls" ? "application/vnd.apple.mpegurl" : "video/mp4",
                headers: [:],
                headerRefresh: headerRefresh,
                headerRefreshUrl: nil
            ),
            timeline: PlaybackV3Timeline(
                sourceStartSeconds: timelineOffset,
                streamOriginSeconds: timelineOffset,
                playerStartSeconds: 0,
                timelineOffsetSeconds: timelineOffset,
                seekWindowStartSeconds: nil,
                seekWindowEndSeconds: nil,
                canSeekAnywhere: true,
                seekRestoration: "player_position"
            ),
            selectedTracks: PlaybackV3SelectedTracks(
                audio: PlaybackV3TrackIdentity(id: "file:42:audio:0", index: 0),
                subtitle: nil
            ),
            effectiveRecipe: PlaybackV3EffectiveRecipe(
                videoCodec: "hevc", audioCodec: "aac", width: 3_840, height: 2_160, frameRate: 23.976,
                bitrateKbps: 20_000, dynamicRange: "hdr10", audioChannels: 6, audioLayout: "5.1"
            ),
            claims: PlaybackV3ValidationClaims(
                video: PlaybackV3VideoClaims(hdr10: true, hdr10Plus: false, hlg: false, dolbyVision: false,
                                             dolbyVisionReason: nil),
                audio: PlaybackV3AudioClaims(codec: "aac", passthrough: false, atmosPreserved: false,
                                             dtsVariant: nil, reason: nil),
                subtitles: PlaybackV3SubtitleClaims(assStylingPreserved: false, bitmapOverlay: false,
                                                    bitmapSidecar: false, reason: nil)
            ),
            subtitle: PlaybackV3SubtitleDecision(mode: "off", trackId: nil, artifact: nil, inventory: []),
            transformations: [],
            appliedQuirks: [],
            runtimeCorrections: [],
            degradationWarnings: [],
            decisionReason: "receiver_fixture",
            requestedMediaFileId: 42,
            effectiveMediaFileId: 42,
            source: PlaybackV3SourceDescriptor(
                mediaFileId: 42, durationSeconds: 5_400, container: container, videoCodec: "hevc",
                videoProfile: "main10", videoLevel: 153, bitDepth: 10, colorRange: "tv", width: 3_840,
                height: 2_160, frameRate: 23.976, bitrateKbps: 20_000, dynamicRange: "hdr10", hdr10Plus: false,
                dolbyVisionProfile: nil, dvBlCompatId: nil, dvEnhancementLayer: "none", audioCodec: "aac",
                audioChannels: 6, audioLayout: "5.1", videoCopyUnsafe: false
            ),
            subtitleFidelityPolicy: "allow_simplified_rendering",
            availableQualities: []
        )
    }
}
