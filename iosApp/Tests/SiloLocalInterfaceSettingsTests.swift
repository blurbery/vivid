import XCTest
@testable import Vivid

/// On Silo, Vivid's interface settings stay on the device, so a menu or card
/// size saved in Silo's own apps can't change Vivid's tabs or cards. Every
/// other setting still goes to the server.
final class SiloLocalInterfaceSettingsTests: XCTestCase {

    private static let menu: SettingJSONValue = .object([
        "items": .array([
            .object(["type": .string("builtin"), "destination": .string("home")]),
            .object(["type": .string("builtin"), "destination": .string("for_you")]),
        ]),
    ])

    func testSiloInterfaceSettingsSaveReadAndClearWithoutTheServer() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = try await makeSiloAPI()

        _ = try await api.putValue(
            key: .navPrimaryMenu,
            scope: .profileClient,
            value: Self.menu,
            mutationId: newSettingMutationId()
        )
        let saved = try await api.getEffectiveValues(keys: [.navPrimaryMenu, .uiCardPresentation])

        XCTAssertEqual(saved.value(for: .navPrimaryMenu)?.value, Self.menu)
        XCTAssertEqual(saved.value(for: .navPrimaryMenu)?.source, .scope(.profileClient))
        // Nothing saved in Vivid means Vivid's default, never Silo's value.
        XCTAssertEqual(saved.value(for: .uiCardPresentation)?.source, .contractDefault)
        XCTAssertEqual(
            saved.value(for: .uiCardPresentation)?.value.objectValue?["poster_size"],
            .string("standard")
        )

        try await api.deleteValue(key: .navPrimaryMenu, scope: .profileClient)
        let cleared = try await api.getEffectiveValues(keys: [.navPrimaryMenu])
        XCTAssertEqual(cleared.value(for: .navPrimaryMenu)?.value, .null)

        XCTAssertTrue(
            SettingsStubProtocol.state().requestCounts.isEmpty,
            "interface settings must never reach the Silo server"
        )
    }

    func testMixedSiloReadAsksTheServerOnlyForTheOtherKeys() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = try await makeSiloAPI()

        let response = try await api.getEffectiveValues(keys: [.uiCardPresentation, .playbackAutoPlayNext])

        let recorded = try XCTUnwrap(SettingsStubProtocol.state().lastRequest)
        XCTAssertEqual(recorded.path, "/api/v1/settings/values/effective")
        XCTAssertEqual(recorded.query["keys"], "playback.auto_play_next")
        XCTAssertEqual(response.value(for: .playbackAutoPlayNext)?.value, .bool(true))
        XCTAssertEqual(response.value(for: .uiCardPresentation)?.source, .contractDefault)
    }

    func testSiloPlaybackWritesStillGoToTheServer() async throws {
        SettingsStubProtocol.reset(mode: .normal)
        let api = try await makeSiloAPI()

        _ = try await api.putValue(
            key: .playerHdrEnabled,
            scope: .profileDevice,
            value: .bool(false),
            mutationId: newSettingMutationId()
        )

        XCTAssertEqual(
            SettingsStubProtocol.state().lastRequest?.path,
            "/api/v1/settings/values/player.hdr_enabled"
        )
    }

    func testInterfaceCustomizationDoesNotDependOnTheSiloServerVersion() async throws {
        SettingsStubProtocol.reset(mode: .serverTooOld)
        let transport = VividUICustomizationTransport(api: try await makeSiloAPI())
        let identity = HTTPRequestIdentity(
            serverId: Self.siloServerId,
            serverURL: "http://settings-test.invalid",
            profileId: SettingValuesAPITests.stubProfileId,
            clientFamily: "mobile"
        )

        guard case .available(let capabilities) = await transport.contractCapabilities(
            requestIdentity: identity
        ) else {
            return XCTFail("Silo interface settings must not need a current server")
        }
        XCTAssertTrue(capabilities.supportsUICustomizationRevision)
        XCTAssertTrue(SettingsStubProtocol.state().requestCounts.isEmpty)
    }

    func testOnlySiloInterfaceKeysAreTakenOver() {
        XCTAssertTrue(SiloLocalInterfaceSettings.applies(toServerID: Self.siloServerId))
        XCTAssertFalse(SiloLocalInterfaceSettings.applies(toServerID: "emby:server"))
        XCTAssertFalse(SiloLocalInterfaceSettings.applies(toServerID: "jellyfin:server"))

        XCTAssertTrue(SiloLocalInterfaceSettings.owns(.navPrimaryMenu))
        XCTAssertTrue(SiloLocalInterfaceSettings.owns(.uiCardPresentation))
        XCTAssertTrue(SiloLocalInterfaceSettings.owns(.uiLibraryPageState))
        XCTAssertFalse(SiloLocalInterfaceSettings.owns(.playbackSubtitleLanguage))
        XCTAssertFalse(SiloLocalInterfaceSettings.owns(.catalogMetadataLanguage))
    }

    // MARK: - Harness

    private static let siloServerId = "silo-settings-test"

    private func makeSiloAPI() async throws -> VividAPI {
        let suiteName = "silo-interface-settings-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "SiloLocalInterfaceSettingsTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: Self.siloServerId)
        await tokenStore.setServerUrl("http://settings-test.invalid")
        await tokenStore.setProfileId(SettingValuesAPITests.stubProfileId)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsStubProtocol.self]
        let http = HTTPClient(
            apiDiscovery: SiloAPIDiscovery(legacyOnly: true),
            session: URLSession(configuration: config),
            tokenStore: tokenStore
        )
        return VividAPI(
            http: http,
            tokenStore: tokenStore,
            localInterfaceSettings: SiloLocalInterfaceSettings(defaults: suite)
        )
    }
}
