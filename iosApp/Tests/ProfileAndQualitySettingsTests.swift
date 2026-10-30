import XCTest
@testable import Vivid

/// Tests for the two things C2c moved onto the canonical settings contract:
/// the shared quality presets (`playback.preferred_quality` +
/// `playback.max_bitrate_kbps`) and the profile-scoped preferences that used
/// to travel as fields on `PUT /profiles/{id}`.
///
/// The preset table is asserted against the *contract*, not against a copy of
/// itself: a preset whose resolution is not a member of the manifest's enum is
/// a permanent `invalid_value` on the server, and the failure would otherwise
/// only show up as a preference that silently stops syncing.
@MainActor
final class ProfileAndQualitySettingsTests: XCTestCase {

    // MARK: - Language catalog

    func testLanguageOptionsUnionContractRuntimeAndExactCurrentValue() {
        let options = PlaybackLanguageOption.options(
            for: .playbackSubtitleLanguage,
            currentValue: "pt-BR",
            runtimeValues: ["eng", "es-MX"]
        ).map(\.code)

        XCTAssertTrue(options.contains("en"))
        XCTAssertFalse(options.contains("eng"), "a true ISO alias must not create a duplicate row")
        XCTAssertTrue(options.contains("te"), "the generated contract floor must be present")
        XCTAssertTrue(options.contains("es-MX"), "deployment-observed region tags must be present")
        XCTAssertTrue(options.contains("pt"), "a base language is not an alias for a region choice")
        XCTAssertTrue(options.contains("pt-BR"), "the exact current wire value must stay selectable")
    }

    func testCurrentAliasReplacesTheContractWireValue() {
        let options = PlaybackLanguageOption.options(
            for: .playbackAudioLanguage,
            currentValue: "eng"
        ).map(\.code)

        XCTAssertTrue(options.contains("eng"))
        XCTAssertFalse(options.contains("en"))
    }

    func testBibliographicAliasesReplaceTheirCanonicalContractRows() {
        let aliases = [
            "fre": "fr",
            "ger": "de",
            "chi": "zh",
            "mao": "mi",
            "iw": "he",
            "in": "id",
            "ji": "yi",
        ]

        for (alias, canonical) in aliases {
            let options = PlaybackLanguageOption.options(
                for: .playbackAudioLanguage,
                currentValue: alias
            ).map(\.code)

            XCTAssertTrue(options.contains(alias), "the exact current value \(alias) must win")
            XCTAssertFalse(options.contains(canonical), "\(alias) must replace its alias \(canonical)")
        }
    }

    // MARK: - Preset table

    /// The contract's `playback.preferred_quality` members. Spelled out here
    /// rather than read from the generated bindings because the bindings
    /// generate the key list, not each key's enum — so this is the pin that
    /// catches a preset naming a resolution the server would refuse.
    private static let contractResolutions: Set<String> = [
        "auto", "480p", "720p", "1080p", "2160p", "original",
    ]

    func testEveryPresetResolutionIsAContractEnumMember() {
        for preset in VividQualityPresets.all {
            XCTAssertTrue(
                Self.contractResolutions.contains(preset.resolution),
                "preset \(preset.id) sends resolution \(preset.resolution), which the contract's enum does not define"
            )
        }
    }

    func testEveryPresetBitrateIsWithinTheContractsBounds() {
        for preset in VividQualityPresets.all {
            guard let bitrate = preset.bitrateKbps else { continue }
            // The manifest declares minimum 100, maximum 200000 on
            // playback.max_bitrate_kbps.
            XCTAssertGreaterThanOrEqual(bitrate, 100, "preset \(preset.id) is below the contract minimum")
            XCTAssertLessThanOrEqual(bitrate, 200_000, "preset \(preset.id) is above the contract maximum")
        }
    }

    /// The preset ids, labels and pairs the web and Android clients ship, in
    /// order. A divergence here is a user seeing "1080p High" mean one thing on
    /// the phone and another in a browser, which is exactly what the shared
    /// table exists to prevent.
    func testPresetTableMatchesTheOtherClients() {
        let expected: [(id: String, label: String, resolution: String, bitrate: Int?)] = [
            ("auto", "Auto", "auto", nil),
            ("original", "Original", "original", nil),
            ("2160p", "4K", "2160p", nil),
            ("1080p-high", "1080p High", "1080p", 10_000),
            ("1080p", "1080p", "1080p", 6_000),
            ("1080p-low", "1080p Low", "1080p", 3_000),
            ("720p-high", "720p High", "720p", 4_000),
            ("720p", "720p", "720p", 2_000),
            ("480p", "480p", "480p", 1_500),
        ]

        XCTAssertEqual(VividQualityPresets.all.count, expected.count)
        for (actual, want) in zip(VividQualityPresets.all, expected) {
            XCTAssertEqual(actual.id, want.id)
            XCTAssertEqual(actual.label, want.label, "\(want.id) label")
            XCTAssertEqual(actual.resolution, want.resolution, "\(want.id) resolution")
            XCTAssertEqual(actual.bitrateKbps, want.bitrate, "\(want.id) bitrate")
        }
    }

    func testEveryPresetRoundTripsFromItsStoredPair() {
        for preset in VividQualityPresets.all {
            let recovered = VividQualityPresets.preset(
                resolution: preset.resolution,
                bitrateKbps: preset.bitrateKbps
            )
            XCTAssertEqual(recovered?.id, preset.id, "\(preset.id) did not round-trip")
        }
    }

    /// Two presets share the `1080p` resolution and differ only by bitrate, so
    /// a lookup that ignored the bitrate axis would collapse them.
    func testPresetsAreDistinguishedByBothAxes() {
        XCTAssertEqual(VividQualityPresets.preset(resolution: "1080p", bitrateKbps: 10_000)?.id, "1080p-high")
        XCTAssertEqual(VividQualityPresets.preset(resolution: "1080p", bitrateKbps: 6_000)?.id, "1080p")
        XCTAssertEqual(VividQualityPresets.preset(resolution: "1080p", bitrateKbps: 3_000)?.id, "1080p-low")
    }

    /// A pair no preset covers must report itself rather than resolve to a
    /// nearby preset: showing "1080p" for a stored 1080p/8000 would tell the
    /// user their cap is 6 Mbps when it is 8.
    func testAPairNoPresetCoversHasNoPresetAndDescribesItself() {
        XCTAssertNil(VividQualityPresets.preset(resolution: "1080p", bitrateKbps: 8_000))
        XCTAssertEqual(VividQualityPresets.describe(resolution: "1080p", bitrateKbps: 8_000), "1080p at 8 Mbps")
        XCTAssertEqual(VividQualityPresets.describe(resolution: "720p", bitrateKbps: 1_800), "720p at 1.8 Mbps")
        // A covered pair answers with the preset's own label.
        XCTAssertEqual(VividQualityPresets.describe(resolution: "720p", bitrateKbps: 4_000), "720p High")
        XCTAssertEqual(VividQualityPresets.describe(resolution: "auto", bitrateKbps: nil), "Auto")
        XCTAssertEqual(VividQualityPresets.describe(resolution: "2160p", bitrateKbps: nil), "4K")
    }

    /// Legacy compound spellings reduce to the contract's enum. The bitrate
    /// half is dropped rather than guessed at — the bitrate axis carries it,
    /// and inventing a cap would silently throttle playback.
    func testCompoundLegacyResolutionsNormalizeToContractMembers() {
        XCTAssertEqual(VividQualityPresets.normalizeResolution("1080p-high"), "1080p")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("720p-medium"), "720p")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("1080p-8"), "1080p")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("4k"), "2160p")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("uhd"), "2160p")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("  1080P  "), "1080p")
        // 328p and 420p predate the contract's ladder and have no member.
        XCTAssertEqual(VividQualityPresets.normalizeResolution("328p"), "auto")
        XCTAssertEqual(VividQualityPresets.normalizeResolution(nil), "auto")
        XCTAssertEqual(VividQualityPresets.normalizeResolution(""), "auto")
        XCTAssertEqual(VividQualityPresets.normalizeResolution("1440p"), "auto")

        for resolution in VividQualityPresets.all.map(\.resolution) {
            XCTAssertTrue(
                Self.contractResolutions.contains(VividQualityPresets.normalizeResolution(resolution)),
                "normalizing \(resolution) escaped the contract's enum"
            )
        }
    }

    // MARK: - Preset writes

    func testApplyingAPresetWritesBothAxes() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setQualityPreset(try XCTUnwrap(VividQualityPresets.preset(id: "720p-high")))
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertEqual(restored.preferredQualityResolution, "720p")
        XCTAssertEqual(restored.maxBitrateKbps, 4_000)
        XCTAssertEqual(restored.currentQualityPreset?.id, "720p-high")
    }

    /// An uncapped preset must send an explicit null, not omit the write:
    /// leaving the previous cap in place would keep throttling a preference the
    /// user just widened.
    func testAnUncappedPresetClearsTheBitrateAxis() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setQualityPreset(try XCTUnwrap(VividQualityPresets.preset(id: "480p")))
        harness.settings.setQualityPreset(try XCTUnwrap(VividQualityPresets.preset(id: "2160p")))
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertEqual(restored.preferredQualityResolution, "2160p")
        XCTAssertNil(restored.maxBitrateKbps)
    }

    /// Every preset must survive a write/read cycle unchanged. This is the
    /// regression that motivated storing the pair: `1080p-high` names 10 Mbps
    /// in the preset table and 20 Mbps in the in-player ladder, so a client
    /// that stored the *id* would reinterpret the user's choice depending on
    /// which table read it back.
    func testEveryPresetSurvivesALocalRoundTrip() async throws {
        for preset in VividQualityPresets.all {
            let harness = try PlayerSettingsHarness()
            harness.settings.setQualityPreset(preset)
            let restored = PlayerSettings(defaults: harness.defaults)
            XCTAssertEqual(restored.currentQualityPreset?.id, preset.id)
        }
    }

    /// A pair authored elsewhere is adopted verbatim rather than snapped onto
    /// this client's ladder. Quantizing here would rewrite the profile's stored
    /// choice on the next edit made from this device.
    func testAForeignPairIsAdoptedWithoutBeingQuantized() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.preferredQualityResolution = "1080p"
        harness.settings.maxBitrateKbps = 8_000
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertEqual(restored.preferredQualityResolution, "1080p")
        XCTAssertEqual(restored.maxBitrateKbps, 8_000)
        XCTAssertNil(restored.currentQualityPreset)
        XCTAssertEqual(restored.preferredQualityLabel, "1080p at 8 Mbps")
    }

    /// The server spells uncapped as JSON null; the client must read that as
    /// "no cap" rather than as the integer 0, which the contract would refuse.
    func testANullBitrateReadsBackAsUncapped() async throws {
        let harness = try PlayerSettingsHarness()
        harness.settings.setQualityPreset(try XCTUnwrap(VividQualityPresets.preset(id: "original")))
        let restored = PlayerSettings(defaults: harness.defaults)
        XCTAssertNil(restored.maxBitrateKbps)
        XCTAssertEqual(restored.currentQualityPreset?.id, "original")
    }
}
