import XCTest
@testable import Vivid

@MainActor
final class PlayerSettingsTests: XCTestCase {
    func testWatchProgressRequiresSixtySecondsOfViewing() {
        var gate = PlaybackWatchTimeGate()
        for second in 0...59 {
            gate.observe(position: Double(second), uptime: Double(second), playing: true, rate: 1)
        }
        XCTAssertFalse(gate.isEligible)
        gate.observe(position: 60, uptime: 60, playing: true, rate: 1)
        XCTAssertTrue(gate.isEligible)
    }

    func testWatchTimeExcludesSeekingPausesBufferingAndBackgroundGaps() {
        var gate = PlaybackWatchTimeGate()
        gate.observe(position: 0, uptime: 0, playing: true, rate: 1)
        gate.observe(position: 30, uptime: 1, playing: true, rate: 1)
        XCTAssertEqual(gate.watchedSeconds, 0)
        gate.interrupt()
        gate.observe(position: 600, uptime: 2, playing: true, rate: 1)
        gate.observe(position: 601, uptime: 3, playing: true, rate: 1)
        gate.observe(position: 601, uptime: 4, playing: false, rate: 1)
        gate.observe(position: 601, uptime: 80, playing: true, rate: 1)
        gate.observe(position: 900, uptime: 400, playing: true, rate: 1)
        XCTAssertEqual(gate.watchedSeconds, 1)
        XCTAssertFalse(gate.isEligible)
    }

    func testPlaybackSpeedDoesNotShortenOneMinuteThreshold() {
        for rate in [0.5, 1, 2.0] {
            var gate = PlaybackWatchTimeGate()
            for second in 0...59 {
                gate.observe(position: Double(second) * rate, uptime: Double(second), playing: true, rate: rate)
            }
            XCTAssertFalse(gate.isEligible)
            gate.observe(position: 60 * rate, uptime: 60, playing: true, rate: rate)
            XCTAssertTrue(gate.isEligible)
        }
    }

    func testRecapAndIntroRemainSeparatePrompts() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.duration = 200
        model.updateIntroDBSegments(.init(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: .init(start_ms: 30_000, end_ms: 40_000), outro: nil,
            recap: .init(start_ms: 0, end_ms: 20_000)))
        model.currentTime = 10
        XCTAssertEqual(model.introSkipLabel, "Skip Recap")
        XCTAssertEqual(model.activeIntroSkipRange, TimeRange(start: 0, end: 20))
        model.currentTime = 35
        XCTAssertEqual(model.introSkipLabel, "Skip Intro")
        XCTAssertEqual(model.activeIntroSkipRange, TimeRange(start: 30, end: 40))
        XCTAssertEqual(model.openingSkipRanges.count, 2)
    }

    func testSelectedFileMarkersSurviveBeforeDurationAndRejectInvalidRanges() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let intro = VividIntroDBClient.Segment(range: TimeRange(start: 454, end: 467))
        let credits = VividIntroDBClient.Segment(range: TimeRange(start: 2194, end: 2434))
        model.updateIntroDBSegments(.init(imdb_id: "", season: 4, episode: 6, intro: intro, outro: credits))
        XCTAssertNil(model.introRange)
        model.duration = 2434
        XCTAssertEqual(model.introRange, TimeRange(start: 454, end: 467))
        XCTAssertEqual(model.creditsRange, TimeRange(start: 2194, end: 2434))
        XCTAssertNil(VividIntroDBClient.Segment(range: TimeRange(start: -1, end: 10)))
        XCTAssertNil(VividIntroDBClient.Segment(range: TimeRange(start: 20, end: 10)))
        XCTAssertNil(VividIntroDBClient.Segment(range: TimeRange(start: 0, end: .infinity)))
    }

    func testFallbackPreservesEachPrimaryMarker() {
        typealias Client = VividIntroDBClient
        let fallback = Client.Segments(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: .init(start_ms: 0, end_ms: 20_000),
            outro: .init(start_ms: 90_000, end_ms: nil))
        let primary = Client.Segments(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: .init(start_ms: 10_000, end_ms: 30_000), outro: nil)
        let combined = primary.fillingMissing(from: fallback)
        XCTAssertEqual(combined.intro?.range(duration: 100), TimeRange(start: 10, end: 30))
        XCTAssertEqual(combined.outro?.range(duration: 100), TimeRange(start: 90, end: 100))
        let creditsOnly = Client.Segments(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: nil, outro: .init(start_ms: 80_000, end_ms: 95_000))
        XCTAssertEqual(creditsOnly.fillingMissing(from: fallback).outro?.range(duration: 100),
                       TimeRange(start: 80, end: 95))
        XCTAssertNil(primary.fillingMissing(from: nil).outro)
        let wrongEpisode = Client.Segments(imdb_id: "tt1234567", season: 1, episode: 2,
            intro: nil, outro: fallback.outro)
        XCTAssertNil(primary.fillingMissing(from: wrongEpisode).outro)
    }

    func testFallbackDecodesNullBoundsAndKeepsSeparateSegments() throws {
        let data = Data(#"{"intro":[{"start_ms":-1,"end_ms":50},{"start_ms":null,"end_ms":20000}],"credits":[{"start_ms":90000,"end_ms":null},{"start_ms":70000,"end_ms":80000}]}"#.utf8)
        let response = try JSONDecoder().decode(VividIntroDBClient.FallbackResponse.self, from: data)
        let markers = response.segments(for: .init(imdbID: "tt1234567", season: 1, episode: 1))
        XCTAssertEqual(markers.intro?.range(duration: 100), TimeRange(start: 0, end: 20))
        XCTAssertEqual(markers.outro?.range(duration: 100), TimeRange(start: 70, end: 80))
        let openCredits = VividIntroDBClient.FallbackResponse.Timestamp(start_ms: 90_000, end_ms: nil)
            .segment(credits: true)
        XCTAssertNil(openCredits?.range(duration: 0))
        XCTAssertEqual(openCredits?.range(duration: 100), TimeRange(start: 90, end: 100))
        XCTAssertNil(VividIntroDBClient.FallbackResponse.Timestamp(start_ms: 1, end_ms: nil).segment(credits: false))
        XCTAssertNil(VividIntroDBClient.FallbackResponse.Timestamp(start_ms: nil, end_ms: 20).segment(credits: true))
        let empty = try JSONDecoder().decode(VividIntroDBClient.FallbackResponse.self, from: Data("{}".utf8))
        XCTAssertNil(empty.segments(for: .init(imdbID: "tt1234567", season: 1, episode: 1)).intro)
    }

    func testIntroMarkersSurviveLookupBeforeDuration() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.updateIntroDBSegments(.init(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: .init(start_ms: 10_000, end_ms: 50_000),
            outro: .init(start_ms: 90_000, end_ms: 100_000)))
        XCTAssertNil(model.introRange)
        model.duration = 100
        XCTAssertEqual(model.introRange, TimeRange(start: 10, end: 50))
        XCTAssertEqual(model.creditsRange, TimeRange(start: 90, end: 100))
        model.updateIntroDBSegments(nil)
        model.duration = 200
        XCTAssertNil(model.introRange)
        XCTAssertNil(model.creditsRange)
    }

    func testIntroMarkersDoNotCrossCleanupOrAcceptInvalidDuration() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.duration = .infinity
        model.updateIntroDBSegments(.init(imdb_id: "tt1234567", season: 1, episode: 1,
            intro: .init(start_ms: 10_000, end_ms: 50_000), outro: nil))
        XCTAssertNil(model.introRange)
        model.cleanup()
        model.duration = 100
        XCTAssertNil(model.introRange)
        XCTAssertNil(VividIntroDBClient.Segment(start_ms: 10_000, end_ms: 150_000).range(duration: 100))
    }

    func testFallbackNeedsEightContinuousSecondsAndRunsOnlyOnce() {
        var gate = PlaybackFallbackGate()
        gate.update(buffering: true, eligible: true, now: 100)
        XCTAssertFalse(gate.consumeIfReady(now: 107.99, eligible: true))
        XCTAssertTrue(gate.consumeIfReady(now: 108, eligible: true))
        gate.update(buffering: true, eligible: true, now: 120)
        XCTAssertFalse(gate.consumeIfReady(now: 140, eligible: true))
    }

    func testFallbackTimerResetsOnPlaybackRecoveryOrIneligibleState() {
        for stillBuffering in [false, true] {
            var gate = PlaybackFallbackGate()
            gate.update(buffering: true, eligible: true, now: 0)
            gate.update(buffering: stillBuffering, eligible: false, now: 7)
            XCTAssertFalse(gate.consumeIfReady(now: 20, eligible: true))
            gate.update(buffering: true, eligible: true, now: 30)
            XCTAssertFalse(gate.consumeIfReady(now: 37, eligible: true))
            XCTAssertTrue(gate.consumeIfReady(now: 38, eligible: true))
        }
    }

    func testFallbackRechecksEligibilityBeforeConsuming() {
        var gate = PlaybackFallbackGate()
        gate.update(buffering: true, eligible: true, now: 0)
        XCTAssertFalse(gate.consumeIfReady(now: 8, eligible: false))
        XCTAssertFalse(gate.consumed)
    }

    func testFallbackCannotActOnARejectedOrUnrelatedQualityChoice() {
        let mode = PlaybackFallbackMode.fullHD
        XCTAssertTrue(mode.isActive(qualityID: mode.rawValue))
        XCTAssertTrue(mode.isActive(qualityID: mode.fallbackID))
        for active in ["auto", "original", "1080p", PlaybackFallbackMode.ultraHD.rawValue] {
            XCTAssertFalse(mode.isActive(qualityID: active))
        }
    }

    func testFallbackModesSendSeparateResolutionAndBitrateCaps() {
        let expected = [(PlaybackFallbackMode.ultraHD, 80_000, 20_000),
                        (.fullHD, 10_000, 4_000), (.hd, 4_000, 1_500)]
        for (mode, maximum, fallback) in expected {
            for (id, cap) in [(mode.rawValue, maximum), (mode.fallbackID, fallback)] {
                let axes = AppleQualityAxes.split(id)
                XCTAssertEqual(axes.resolution, mode.resolution)
                XCTAssertEqual(axes.bitrateKbps, cap)
                let selection = ApplePlaybackQuality.protocolV3Selection(
                    requestedQualityId: id, availableQualities: [])
                XCTAssertEqual(selection.serverPreference, mode.resolution)
                XCTAssertEqual(selection.bandwidthCapKbps, cap)
                XCTAssertFalse(selection.isServerOwned)
                XCTAssertEqual(AppleQualityAxes.resolvedBitrateCap(
                    qualityOverride: id, fallbackBitrateKbps: 200_000), cap)
            }
        }
        XCTAssertNil(PlaybackFallbackMode.matching("auto"))
        XCTAssertNil(PlaybackFallbackMode.matching("original"))
        XCTAssertEqual(VividQualityPresets.selectable.count, 5)
    }

    func testFallbackIsOptInAndSurvivesSettingsReload() async throws {
        let harness = try PlayerSettingsHarness()
        let settings = harness.settings
        settings.setQualityPreset(try XCTUnwrap(VividQualityPresets.preset(id: "1080p-high")))
        XCTAssertNil(settings.fallbackMode)
        for mode in PlaybackFallbackMode.allCases {
            settings.setQualityPreset(mode.preset)
            let restored = PlayerSettings(defaults: harness.defaults)
            XCTAssertEqual(restored.fallbackMode, mode)
            XCTAssertEqual(restored.currentQualityPreset?.id, mode.rawValue)
            XCTAssertEqual(restored.preferredQuality, mode.rawValue)
            XCTAssertEqual(restored.maxBitrateKbps, mode.maximumKbps)
        }
        settings.setPreferredQuality("original")
        XCTAssertNil(PlayerSettings(defaults: harness.defaults).fallbackMode)
        XCTAssertNil(settings.maxBitrateKbps)
        settings.setQualityPreset(PlaybackFallbackMode.ultraHD.preset)
        await settings.resetAllDeviceSettings()
        XCTAssertNil(PlayerSettings(defaults: harness.defaults).fallbackMode)
    }

    func testIntroDBTogglePersistsAndResetRestoresIt() async throws {
        let harness = try PlayerSettingsHarness()
        harness.defaults.set("off", forKey: VividSkipSource.defaultsKey)
        let settings = PlayerSettings(defaults: harness.defaults)
        XCTAssertFalse(settings.introDBEnabled)
        settings.introDBEnabled = true
        XCTAssertTrue(PlayerSettings(defaults: harness.defaults).introDBEnabled)
        settings.introDBEnabled = false
        await settings.resetAllDeviceSettings()
        XCTAssertTrue(PlayerSettings(defaults: harness.defaults).introDBEnabled)
    }

    func testCustomSubtitleAppearanceSurvivesDisablingTheOverride() async throws {
        let harness = try PlayerSettingsHarness()
        var custom = SubtitleAppearance.default
        custom.fontSize = .large
        custom.position = .top
        await harness.settings.setSubtitleAppearance(custom)
        await harness.settings.setSubtitleDeviceOverrideEnabled(false)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance, .default)
        XCTAssertEqual(harness.settings.subtitleAppearance, custom)
        let restored = PlayerSettings(defaults: harness.defaults)
        await restored.setSubtitleDeviceOverrideEnabled(true)
        XCTAssertEqual(restored.effectiveSubtitleAppearance, custom)
    }

    func testPlaybackAndSubtitlePreferencesSurviveLocalReload() async throws {
        let harness = try PlayerSettingsHarness()
        let settings = harness.settings
        XCTAssertFalse(settings.preferLosslessAudio)
        settings.preferLosslessAudio = true
        settings.setBufferAhead(.seconds30)
        settings.setBackgroundPlaybackEnabled(false)
        settings.setAutoPlayNextEpisode(false)
        settings.setPlaybackSpeed(1.33)
        settings.preferredSubtitleLanguage = "ja"
        settings.preferredSubtitleMode = "always"
        settings.showForcedSubtitles = false
        await settings.reloadForCurrentProfile()
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertTrue(restored.preferLosslessAudio)
        XCTAssertEqual(restored.bufferAhead, .seconds30)
        XCTAssertFalse(restored.backgroundPlaybackEnabled)
        XCTAssertFalse(restored.autoPlayNextEpisode)
        XCTAssertEqual(restored.playbackSpeed, 1.35, accuracy: 0.001)
        XCTAssertEqual(restored.preferredSubtitleLanguage, "ja")
        XCTAssertEqual(restored.preferredSubtitleMode, "always")
        XCTAssertFalse(restored.showForcedSubtitles)
    }

    func testResetRestoresLocalPlaybackDefaults() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.preferLosslessAudio = true
        harness.settings.setBufferAhead(.seconds30)
        harness.settings.setPlaybackSpeed(2)
        harness.settings.preferredSubtitleLanguage = "ja"
        harness.settings.setSubtitleMatchesSystemAppearance(true)
        await harness.settings.resetAllDeviceSettings()
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertFalse(restored.preferLosslessAudio)
        XCTAssertEqual(restored.bufferAhead, .automatic)
        XCTAssertEqual(restored.playbackSpeed, 1)
        XCTAssertEqual(restored.preferredSubtitleLanguage, PlaybackPrefSentinel.none)
        XCTAssertEqual(restored.preferredSubtitleMode, "auto")
        XCTAssertTrue(restored.showForcedSubtitles)
        XCTAssertFalse(restored.subtitleMatchesSystemAppearance)
    }

    func testBufferTargetsMatchTheSettingsLabels() {
        XCTAssertNil(BufferAheadMode.automatic.forwardBufferSegments)
        XCTAssertEqual(BufferAheadMode.automatic.label, "Automatic")
        XCTAssertEqual(BufferAheadMode.seconds20.forwardBufferSegments, 15)
        XCTAssertEqual(BufferAheadMode.seconds30.forwardBufferSegments, 20)
        #if os(tvOS)
        XCTAssertEqual(BufferAheadMode.seconds20.label, "1 minute")
        XCTAssertEqual(BufferAheadMode.seconds30.label, "80 seconds")
        XCTAssertEqual(BufferAheadMode.fiveMinutes.forwardBufferSegments, 75)
        XCTAssertEqual(BufferAheadMode.maximum.forwardBufferSegments, 150)
        XCTAssertEqual(BufferAheadMode.unlimited.forwardBufferSegments, Int.max)
        #else
        XCTAssertEqual(BufferAheadMode.seconds20.label, "30 seconds")
        XCTAssertEqual(BufferAheadMode.seconds30.label, "40 seconds")
        XCTAssertEqual(BufferAheadMode.allCases.map(\.label), ["Automatic", "30 seconds", "40 seconds"])
        #endif
        XCTAssertEqual(BufferAheadMode(rawValue: "seconds10") ?? .automatic, .automatic)
        XCTAssertEqual(BufferAheadMode(rawValue: "seconds20"), .seconds20)
        XCTAssertEqual(BufferAheadMode(rawValue: "seconds30"), .seconds30)
    }

    func testPlaybackSpeedRemainsWithinSupportedRange() throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setPlaybackSpeed(9)
        XCTAssertEqual(harness.settings.playbackSpeed, 3)
        harness.settings.setPlaybackSpeed(0.01)
        XCTAssertEqual(harness.settings.playbackSpeed, 0.25)
    }

    // MARK: - Quality axes

    func testEveryQualityTierRoundTripsThroughTheTwoAxes() throws {
        // Splitting and rejoining must be the identity for every id this
        // client's picker can produce, or a user's tier would silently drift a
        // rung on the first refresh after they set it.
        for option in ApplePlaybackQuality.settingsOptions {
            let axes = AppleQualityAxes.split(option.id)
            XCTAssertEqual(
                AppleQualityAxes.join(resolution: axes.resolution, bitrateKbps: axes.bitrateKbps),
                option.id,
                "\(option.id) did not survive the round trip"
            )
        }
    }

    func testSplitProducesOnlyContractEnumMembers() throws {
        // The whole reason for the split: the server validates this key against
        // its enum, so anything else is a permanent invalid_value.
        for option in ApplePlaybackQuality.settingsOptions {
            let resolution = AppleQualityAxes.split(option.id).resolution
            XCTAssertTrue(
                AppleQualityAxes.resolutionMembers.contains(resolution),
                "\(option.id) split to \(resolution), which the contract's enum does not allow"
            )
        }
    }

    func testTheTightestTierKeepsItsCapRatherThanWidening() throws {
        // 328p predates the contract's ladder and has no member of its own. It
        // maps up to 480p but keeps its 700 kbps cap, because dropping the cap
        // would uncap the connection of the user who asked for the least.
        let axes = AppleQualityAxes.split("328p")
        XCTAssertEqual(axes.resolution, "480p")
        XCTAssertEqual(axes.bitrateKbps, 700)
    }

    /// The stored resolution is what the join answers with, on every client.
    ///
    /// This is the cross-client contract: the V3 start request carries only a
    /// bare resolution, so a join that traded a resolution tier away to stay
    /// under the cap would send `720p` from a pair the web and Android send
    /// `1080p` from. Apple's ladder having no 1080p rung below 8 Mbps is a fact
    /// about its rung table, not about the user's choice.
    func testASharedPresetResolvesToItsOwnResolutionNotALowerOne() throws {
        for (resolution, bitrateKbps) in [("1080p", 10_000), ("1080p", 6_000), ("1080p", 3_000),
                                          ("720p", 4_000), ("720p", 2_000), ("480p", 1_500)] {
            let id = AppleQualityAxes.join(resolution: resolution, bitrateKbps: bitrateKbps)
            XCTAssertEqual(
                AppleQualityAxes.split(id).resolution, resolution,
                "\(resolution) at \(bitrateKbps) kbps joined to \(id), a different resolution"
            )
        }
    }

    /// The specific regression: the two most common shared presets used to
    /// resolve to 720p rungs here while the other clients kept 1080p.
    func testTheWebs1080pPresetsStay1080p() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 6_000), "1080p-8")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 3_000), "1080p-8")
    }

    /// The bitrate axis still chooses *which* rung of the stored resolution.
    func testTheCapChoosesTheRungWithinTheStoredResolution() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 12_000), "1080p-medium")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 20_000), "1080p-high")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "720p", bitrateKbps: 3_000), "720p-medium")
    }

    func testACapBelowEveryRungKeepsTheResolutionAndTakesTheSmallestRung() throws {
        // The resolution is what the request carries, so it is kept; the cap is
        // enforced at request time instead of by shrinking the picture.
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 300), "1080p-8")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "480p", bitrateKbps: 300), "328p")
    }

    /// What the join gave up, the transcode request has to honour: the stored
    /// cap clamps the encode target rather than being lost.
    func testTheStoredCapClampsTheLegacyTranscodeTarget() throws {
        let id = AppleQualityAxes.join(resolution: "1080p", bitrateKbps: 6_000)
        let option = try XCTUnwrap(ApplePlaybackQuality.settingsOptions.first { $0.id == id })
        XCTAssertEqual(option.bitrateKbps, 8_000, "precondition: the chosen rung is above the cap")

        let source = Self.version(fileId: 1, resolution: "1080p", bitrateKbps: 30_000)
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(for: option, selectedVersion: source, capKbps: 6_000),
            6_000,
            "the cap must bound the encode target, not the rung"
        )
        // And a source inside the rung but over the cap still has to be
        // re-encoded, or the cap would be silently uncapped.
        let modest = Self.version(fileId: 2, resolution: "1080p", bitrateKbps: 7_000)
        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: id, selectedVersion: modest, capKbps: 6_000
            ),
            "a source above the cap must transcode even when it is under the rung"
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: id, selectedVersion: modest, capKbps: nil
            ),
            "without a cap the rung alone decides"
        )
    }

    func testAutoResolutionStillEnforcesANumericBitrateCap() throws {
        let qualityId = AppleQualityAxes.join(resolution: "auto", bitrateKbps: 6_000)
        XCTAssertEqual(qualityId, ApplePlaybackQuality.autoId)
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first { $0.id == qualityId }
        )
        let source = Self.version(fileId: 3, resolution: "1080p", bitrateKbps: 7_000)

        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: qualityId,
                selectedVersion: source,
                capKbps: 6_000
            ),
            "Auto removes the resolution ceiling, not the independent bandwidth ceiling"
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: source,
                capKbps: 6_000
            ),
            6_000
        )
    }

    func testOriginalResolutionStillEnforcesANumericBitrateCapOnLegacyPlayback() throws {
        let qualityId = AppleQualityAxes.join(resolution: "original", bitrateKbps: 6_000)
        XCTAssertEqual(qualityId, ApplePlaybackQuality.originalId)
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first { $0.id == qualityId }
        )
        let source = Self.version(fileId: 4, resolution: "2160p", bitrateKbps: 30_000)

        let forcedByQuality = ApplePlaybackQuality.shouldForceTranscode(
            preferredQualityId: qualityId,
            selectedVersion: source,
            capKbps: 6_000
        )
        XCTAssertTrue(
            forcedByQuality,
            "Original removes the resolution ceiling, not the independent bandwidth ceiling"
        )
        for delivery in [PlaybackDeliveryStrategy.direct, .remux, .transcode] {
            XCTAssertFalse(
                ApplePlaybackQuality.shouldUseLegacyCopyVideo(
                    delivery: delivery,
                    option: option,
                    forcedByQuality: forcedByQuality
                ),
                "legacy playback must encode rather than copy video above the cap"
            )
        }
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: source,
                capKbps: 6_000
            ),
            6_000
        )
    }

    func testWideningToOriginalOr4KReselectsAHigherResolutionSource() throws {
        let sevenTwenty = Self.version(fileId: 1, resolution: "720p", bitrateKbps: 4_000)
        let tenEighty = Self.version(fileId: 2, resolution: "1080p", bitrateKbps: 10_000)
        let fourK = Self.version(fileId: 3, resolution: "2160p", bitrateKbps: 30_000)
        let versions = [sevenTwenty, tenEighty, fourK]

        XCTAssertTrue(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "original",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            )
        )
        XCTAssertTrue(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "2160p",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            )
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "720p-high",
                selectedVersion: sevenTwenty,
                availableVersions: versions
            ),
            "a higher file above the requested ceiling is not eligible"
        )
        XCTAssertFalse(
            ApplePlaybackQuality.shouldReselectSource(
                preferredQualityId: "2160p",
                selectedVersion: fourK,
                availableVersions: versions
            ),
            "the selected file already satisfies the highest eligible resolution"
        )
    }

    func testInitialOriginalSelectionIgnoresARememberedLowerResolutionSource() throws {
        let sevenTwenty = Self.version(fileId: 1, resolution: "720p", bitrateKbps: 4_000)
        let fourK = Self.version(fileId: 2, resolution: "2160p", bitrateKbps: 30_000)
        let versions = [sevenTwenty, fourK]

        XCTAssertEqual(
            PlaybackSessionBridge.selectVersion(
                from: versions,
                lastFileId: sevenTwenty.fileId,
                preferredQuality: "original"
            ).fileId,
            fourK.fileId
        )
        XCTAssertEqual(
            PlaybackSessionBridge.selectVersion(
                from: versions,
                lastFileId: sevenTwenty.fileId,
                preferredQuality: nil
            ).fileId,
            sevenTwenty.fileId,
            "Auto must retain the remembered-version fallback"
        )
    }

    func testOriginalCopyFailureCannotFallBackToATranscode() throws {
        XCTAssertFalse(
            ApplePlaybackQuality.allowsLegacyCopyFallbackToTranscode(
                preferredQualityId: "original"
            )
        )
        XCTAssertTrue(
            ApplePlaybackQuality.allowsLegacyCopyFallbackToTranscode(
                preferredQualityId: nil
            ),
            "Auto retains the older-server compatibility fallback"
        )
    }

    func testLegacyCopyRejectionFallbackRetainsTheBandwidthCap() throws {
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: nil), 6_000)
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: 12_000), 6_000)
        XCTAssertEqual(ApplePlaybackQuality.legacyCopyFallbackBitrateKbps(capKbps: 3_000), 3_000)
    }

    func testAnUncappedResolutionPicksThatResolutionsBestTier() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1080p", bitrateKbps: nil), "1080p-high")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "720p", bitrateKbps: nil), "720p-high")
    }

    func testTheContracts4KResolutionRemainsDistinctFromAuto() throws {
        let option = try XCTUnwrap(
            ApplePlaybackQuality.settingsOptions.first(where: { $0.id == "2160p" })
        )
        XCTAssertEqual(option.labelWithBitrate, "4K")
        XCTAssertNil(option.subtitle)
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("2160p"), "2160p")
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("4K"), "2160p")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "2160p", bitrateKbps: nil), "2160p")
        XCTAssertEqual(
            AppleQualityAxes.split("2160p"),
            .init(resolution: "2160p", bitrateKbps: nil)
        )
        XCTAssertEqual(
            ApplePlaybackQuality.activeQualityId(
                requestedQualityId: "2160p",
                selectedVersion: Self.version(
                    fileId: 4,
                    resolution: "2160p",
                    bitrateKbps: 30_000
                ),
                delivery: .direct
            ),
            "2160p"
        )

        let fourKSource = Self.version(fileId: 5, resolution: "2160p", bitrateKbps: 60_000)
        XCTAssertFalse(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: "2160p",
                selectedVersion: fourKSource
            )
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetResolution(for: option, selectedVersion: fourKSource),
            ""
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: fourKSource
            ),
            0,
            "the resolution-only option must not invent a bitrate ceiling"
        )
        XCTAssertEqual(
            ApplePlaybackQuality.targetBitrateKbps(
                for: option,
                selectedVersion: fourKSource,
                capKbps: 15_000
            ),
            15_000,
            "an independent bandwidth cap still applies to 4K"
        )
        XCTAssertTrue(
            ApplePlaybackQuality.shouldForceTranscode(
                preferredQualityId: "2160p",
                selectedVersion: fourKSource,
                capKbps: 15_000
            )
        )
    }

    func testAnInPlayerQualityChoiceReplacesBothStoredAxes() throws {
        XCTAssertEqual(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: nil,
                fallbackBitrateKbps: 6_000
            ),
            6_000,
            "a foreign stored cap must survive exactly when there is no session override"
        )
        XCTAssertNil(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "auto",
                fallbackBitrateKbps: 3_000
            ),
            "explicit Auto must clear a persisted cap"
        )
        XCTAssertNil(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "original",
                fallbackBitrateKbps: 3_000
            ),
            "explicit Original must clear a persisted cap"
        )
        XCTAssertEqual(
            AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: "1080p-high",
                fallbackBitrateKbps: 3_000
            ),
            20_000,
            "a higher in-player rung must replace, not retain, the lower persisted cap"
        )
    }

    func testUnknownResolutionsStillResolveToAuto() throws {
        XCTAssertEqual(AppleQualityAxes.join(resolution: nil, bitrateKbps: 4000), "auto")
        // A member added by a newer server that this build has never seen.
        XCTAssertEqual(AppleQualityAxes.join(resolution: "1440p", bitrateKbps: nil), "auto")
    }

    func testOriginalRemainsDistinctFromAuto() throws {
        XCTAssertEqual(ApplePlaybackQuality.normalizeStoredId("original"), "original")
        XCTAssertEqual(AppleQualityAxes.join(resolution: "original", bitrateKbps: nil), "original")
        XCTAssertEqual(AppleQualityAxes.split("original"), .init(resolution: "original", bitrateKbps: nil))
    }

    func testRecoveryLoadRequestsKeepTheSessionQualityOverride() throws {
        let original = PlayerViewModel.LoadRequest(
            contentId: "movie-1",
            preferredFileId: 10,
            preferredAudioTrackIndex: 2,
            preferredSubtitleTrackIndex: 3,
            preferredSidecarSubtitleTrackId: 4,
            startFromBeginning: true,
            offlineDownloadId: "download-1",
            preferredQualityOverride: "720p-high"
        )

        let recovery = original.copyForRecovery(
            preferredFileId: 11,
            preferredAudioTrackIndex: 5,
            preferredSubtitleTrackIndex: 6,
            preferredSidecarSubtitleTrackId: 7,
            offlineDownloadId: nil
        )

        XCTAssertEqual(recovery.contentId, "movie-1")
        XCTAssertEqual(recovery.preferredFileId, 11)
        XCTAssertEqual(recovery.preferredAudioTrackIndex, 5)
        XCTAssertEqual(recovery.preferredSubtitleTrackIndex, 6)
        XCTAssertEqual(recovery.preferredSidecarSubtitleTrackId, 7)
        XCTAssertFalse(recovery.startFromBeginning)
        XCTAssertNil(recovery.offlineDownloadId)
        XCTAssertEqual(recovery.preferredQualityOverride, "720p-high")
    }

    // MARK: - Helpers

    /// A source file with only the two fields the quality policy reads.
    private static func version(fileId: Int, resolution: String, bitrateKbps: Int) -> FileVersion {
        FileVersion(
            fileId: fileId,
            fileName: nil,
            resolution: resolution,
            codecVideo: "h264",
            codecAudio: "aac",
            hdr: false,
            container: "mp4",
            fileSize: nil,
            duration: nil,
            bitrate: bitrateKbps,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil
        )
    }

}

@MainActor
final class PlayerSettingsHarness {
    let settings: PlayerSettings
    let defaults: UserDefaults
    private let suiteName: String
    init() throws {
        suiteName = "vivid-local-settings-tests-" + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = PlayerSettings(defaults: defaults)
    }
    deinit { defaults.removePersistentDomain(forName: suiteName) }
}
