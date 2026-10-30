import XCTest
@testable import Vivid

/// The top menu and card models, the helpers that turn them into tabs and
/// library roots, and the synced interface preferences store.
@MainActor
final class InterfacePreferencesTests: XCTestCase {
    // MARK: Fixtures

    private static let mobileKey = "vivid.uiCustomization.server.profile.mobile"
    private static let tvKey = "vivid.uiCustomization.server.profile.tv"

    private static func identity(family: String) -> HTTPRequestIdentity {
        HTTPRequestIdentity(serverId: "server", serverURL: "http://settings-test.invalid", profileId: "profile", clientFamily: family)
    }

    private static func identity(forKey key: String) -> HTTPRequestIdentity {
        identity(family: String(key.split(separator: ".").last ?? ""))
    }

    private static func capabilities(atomicShortcuts: Bool = true) -> SettingsContractCapabilities {
        SettingsContractCapabilities(
            apiVersion: 1, revision: SettingKey.revision, contractEtag: "test", definitionCount: 3,
            scopes: ["profile", "profile_client", "profile_device"],
            supportsBatchedEffective: true, supportsIdempotentWrites: true, supportsAtomicShortcuts: atomicShortcuts
        )
    }

    private func freshDefaults() -> UserDefaults {
        let name = "interface-preferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// Separate halves unless the test needs one store for both.
    private func freshStorage(shared: Bool = false) -> SharedDefaults {
        let suite = freshDefaults()
        return SharedDefaults(suite: suite, standard: shared ? suite : freshDefaults())
    }

    private func makeStore(
        _ storage: SharedDefaults, _ transport: ScriptedTransport,
        key: String = mobileKey, start: UICustomizationCapabilityState = .checking
    ) -> UICustomizationPreferences {
        UICustomizationPreferences(
            storage: storage, transport: transport,
            activeCacheKey: { key }, activeIdentity: { Self.identity(forKey: key) },
            capabilityState: start
        )
    }

    private func storeDocument(_ object: [String: Any], in storage: SharedDefaults, key: String = mobileKey) throws {
        storage.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
    }

    private func storedDocument(_ storage: SharedDefaults, key: String = mobileKey) throws -> [String: Any] {
        let data = try XCTUnwrap(storage.data(forKey: key))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let largeArtworkCard: [String: Any] = ["caption": "artwork", "poster_size": "large"]
    private static let artwork = CardPresentationPreset.artworkOnly.presentation
    private static let compact = CardPresentationPreset.compact.presentation

    private static func row(_ key: SettingKey, _ value: some Encodable, source: SettingSource, scope: SettingScope, family: String? = nil, device: String? = nil) -> EffectiveSettingValue {
        EffectiveSettingValue(
            key: key.rawValue, value: try! SettingJSONValue.encoding(value), source: source,
            scope: scope, profileId: "profile", clientFamily: family, deviceId: device
        )
    }

    private static func menuRow(_ items: [PrimaryMenuItem], source: SettingSource, scope: SettingScope, family: String? = nil, device: String? = nil) -> EffectiveSettingValue {
        row(.navPrimaryMenu, PrimaryMenuPreference(items: items), source: source, scope: scope, family: family, device: device)
    }

    private static func cardRow(_ card: CardPresentationPreference, source: SettingSource, scope: SettingScope, family: String? = nil, device: String? = nil) -> EffectiveSettingValue {
        row(.uiCardPresentation, card, source: source, scope: scope, family: family, device: device)
    }

    /// The given rows, plus the contract default for every requested key without one.
    private static func completeDefaultAnswer(_ keys: [SettingKey], rows: [EffectiveSettingValue] = []) -> EffectiveSettingValuesResponse {
        var settings = rows
        for key in keys where !rows.contains(where: { $0.key == key.rawValue }) {
            let value: SettingJSONValue = key == .navPrimaryMenu ? .null : try! SettingJSONValue.encoding(CardPresentationPreference.standard)
            settings.append(EffectiveSettingValue(key: key.rawValue, value: value, source: .contractDefault, profileId: "profile"))
        }
        return EffectiveSettingValuesResponse(settings: settings, revision: SettingKey.revision)
    }

    private static let emptyAnswer = EffectiveSettingValuesResponse(settings: [], revision: SettingKey.revision)
    private static let offline = URLError(.notConnectedToInternet)

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Cache documents

    func testAccountSwitchRepaintsFromStorageOnly() throws {
        let storage = freshStorage(shared: true)
        try storeDocument(["cardPresentation": Self.largeArtworkCard, "supportProjection": "supported"], in: storage, key: "vivid.uiCustomization.first.profile.mobile")
        var key = "vivid.uiCustomization.first.profile.mobile"
        let transport = ScriptedTransport(capabilities: .available(Self.capabilities(atomicShortcuts: false)))
        let store = UICustomizationPreferences(
            storage: storage, transport: transport,
            activeCacheKey: { key }, activeIdentity: { Self.identity(family: "mobile") }
        )
        XCTAssertEqual(store.cardPresentation, Self.artwork)
        key = "vivid.uiCustomization.second.profile.mobile"
        store.restoreCachedPreferences()
        XCTAssertEqual(store.cardPresentation, .standard)
        key = "vivid.uiCustomization.first.profile.mobile"
        store.restoreCachedPreferences()
        XCTAssertEqual(store.cardPresentation, Self.artwork)
        XCTAssertTrue(transport.reads.isEmpty)
        XCTAssertTrue(transport.puts.isEmpty)
    }

    func testRetiredShortcutDataIsDroppedAndTheCardKept() async throws {
        let storage = freshStorage()
        try storeDocument([
            "primaryMenu": ["items": [
                ["type": "builtin", "destination": "home"],
                ["type": "builtin", "destination": "music"],
                ["type": "library", "library_id": 7, "label": "Old pin"],
                ["type": "builtin", "destination": "for_you"],
            ]],
            "shortcuts": [["type": "builtin", "destination": "calendar"]],
            "pendingShortcutOperations": ["bad": "anything"],
            "pendingSyncWrites": ["nav.shortcuts": ["mutationId": "old-write", "value": []]],
            "cardPresentation": Self.largeArtworkCard,
            "supportProjection": "supported",
        ], in: storage)
        let transport = ScriptedTransport(capabilities: .available(Self.capabilities(atomicShortcuts: false)))
        transport.onRead = { Self.completeDefaultAnswer($0) }
        let store = makeStore(storage, transport)

        XCTAssertEqual(store.cardPresentation, Self.artwork)
        XCTAssertEqual(store.resolvedPrimaryMenuItems(), [.builtin(.home), .builtin(.forYou)])
        let document = try storedDocument(storage)
        XCTAssertNil(document["shortcuts"])
        XCTAssertNil(document["pendingShortcutOperations"])
        XCTAssertNil(document["pendingSyncWrites"])

        await store.refresh()
        XCTAssertEqual(transport.reads.last, [.navPrimaryMenu, .uiCardPresentation])
        XCTAssertTrue(transport.puts.isEmpty)
        XCTAssertTrue(store.allowsEditing)
    }

    func testStoredHomeOnlyMenuResolvesToTheDefaultList() throws {
        let storage = freshStorage()
        try storeDocument([
            "primaryMenu": ["items": [["type": "builtin", "destination": "home"]]],
            "cardPresentation": ["caption": "title_metadata", "poster_size": "standard"],
            "supportProjection": "supported",
        ], in: storage)
        let store = makeStore(storage, ScriptedTransport())
        XCTAssertEqual(store.primaryMenu?.items, [.builtin(.home)])
        XCTAssertEqual(store.resolvedPrimaryMenuItems(), appleDefaultPrimaryMenuItems())
    }

    // MARK: Models and helpers

    func testPresetRecipes() {
        XCTAssertEqual(CardPresentationPreset.balanced.presentation, CardPresentationPreference(posterSize: .standard, caption: .titleMetadata))
        XCTAssertEqual(CardPresentationPreset.compact.presentation, CardPresentationPreference(posterSize: .compact, caption: .title))
        XCTAssertEqual(CardPresentationPreset.cinema.presentation, CardPresentationPreference(posterSize: .large, caption: .title))
        XCTAssertEqual(CardPresentationPreset.artworkOnly.presentation, CardPresentationPreference(posterSize: .large, caption: .artwork))
    }

    func testPosterSizes() {
        XCTAssertEqual(AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .compact), 6)
        XCTAssertEqual(AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .standard), 6)
        XCTAssertEqual(AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .large), 5)
        XCTAssertEqual(AdaptiveColumns.tvPosterCount(standardCount: 3, posterSize: .large), 3)
        XCTAssertEqual(CardPosterSize.compact.scale, 0.86, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.standard.scale, 1, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.large.scale, 1.2, accuracy: 0.001)
    }

    func testAppleTVRootChangeFocus() {
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: false, isShowingRoot: true, selectedRootWasRemoved: false), .none)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: false, isShowingRoot: true, selectedRootWasRemoved: true), .content)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: true, isShowingRoot: true, selectedRootWasRemoved: false), .topMenu)
        XCTAssertEqual(tvVisibleRootsFocusRearm(menuOwnedFocus: true, isShowingRoot: false, selectedRootWasRemoved: true), .none)
    }

    func testCaptionStyles() {
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsTitle)
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsMetadata)
        XCTAssertTrue(CardCaptionStyle.title.showsTitle)
        XCTAssertFalse(CardCaptionStyle.title.showsMetadata)
        XCTAssertFalse(CardCaptionStyle.artwork.showsTitle)
        XCTAssertFalse(CardCaptionStyle.artwork.showsMetadata)
    }

    func testCardAccessibilityLabels() {
        XCTAssertEqual(
            mediaCardAccessibilityLabel(title: "The Episode", episodeLabel: "S2 · E10", year: 2026, isWatched: true),
            "The Episode, S2 · E10, 2026, Watched"
        )
        XCTAssertEqual(
            episodeRailAccessibilityLabel(seasonNumber: 2, episodeNumber: 10, title: "The Episode", metadata: "Aug 3 · 52m", isCurrent: true, isPlayed: true),
            "Season 2, Episode 10, The Episode, Aug 3 · 52m, Now viewing, Watched"
        )
    }

    func testCollectionAccessibilityLabels() {
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(LibraryCollection(id: "collection-1", name: "Favorites", collectionType: "movies", itemCount: 12)),
            "Favorites, Movies, 12 items"
        )
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(LibraryCollection(id: "empty", name: "Empty", itemCount: 0)),
            "Empty, Collection, 0 items"
        )
    }

    func testRetiredBuiltinsAreSkippedWhenAMenuIsRead() throws {
        let json = #"{"items":[{"type":"builtin","destination":"home"},{"type":"builtin","destination":"calendar"},{"type":"builtin","destination":"music"},{"type":"library","library_id":7,"label":"Movies"},{"type":"builtin","destination":"for_you"}]}"#
        let menu = try JSONDecoder().decode(PrimaryMenuPreference.self, from: Data(json.utf8))
        XCTAssertEqual(menu.items, [.builtin(.home), .library(libraryId: 7, label: "Movies"), .builtin(.forYou)])
        XCTAssertTrue(menu.isValid)
        let encoded = try JSONEncoder().encode(menu)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("calendar"))
        XCTAssertEqual(try JSONDecoder().decode(PrimaryMenuPreference.self, from: encoded), menu)

        let wrongType = #"{"items":[{"type":"builtin","destination":"home"},{"type":"library","library_id":"invalid","label":"Movies"}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrimaryMenuPreference.self, from: Data(wrongType.utf8)))
    }

    func testWireShape() throws {
        let encoder = SettingsWireCoding.makeEncoder()
        XCTAssertEqual(String(decoding: try encoder.encode(Self.artwork), as: UTF8.self), #"{"caption":"artwork","poster_size":"large"}"#)

        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: 7, label: "Movies"),
            .section(libraryId: 7, sectionId: "recently-added", label: "Recently Added"),
            .collection(collectionId: "favorites", label: "Favorites", libraryId: 7),
        ])
        let data = try encoder.encode(menu)
        let decoded = try SettingsWireCoding.makeDecoder().decode(PrimaryMenuPreference.self, from: data)
        XCTAssertEqual(decoded, menu)
        XCTAssertTrue(decoded.isValid)
        let items = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["type"] as? String, "builtin")
        XCTAssertEqual(items[0]["destination"] as? String, "home")
        XCTAssertEqual(items[1]["library_id"] as? Int, 7)
        XCTAssertEqual(items[2]["section_id"] as? String, "recently-added")
        XCTAssertEqual(items[3]["collection_id"] as? String, "favorites")
    }

    func testCollectionItemIdentity() throws {
        let unscoped = PrimaryMenuItem.collection(collectionId: "12:featured", label: "Featured", libraryId: nil)
        let scoped = PrimaryMenuItem.collection(collectionId: "featured", label: "Featured", libraryId: 12)
        XCTAssertEqual(unscoped.id, "collection|0|0#|11#12:featured")
        XCTAssertEqual(scoped.id, "collection|1|2#12|8#featured")
        XCTAssertNotEqual(unscoped.id, scoped.id)
        XCTAssertEqual(PrimaryMenuItem.collection(collectionId: "12:featured", label: "Renamed", libraryId: nil).id, unscoped.id)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(unscoped)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "collection")
        XCTAssertEqual(object["collection_id"] as? String, "12:featured")
        XCTAssertNil(object["library_id"])
        XCTAssertNil(object["id"])
    }

    private static let moviesLibrary = Library(id: 7, name: "Movies", type: "movies", sortOrder: nil, posterUrl: nil)
    private static let seriesLibrary = Library(id: 8, name: "Series", type: "series", sortOrder: nil, posterUrl: nil)
    private static let fourTabs: [MainTabDestinationID] = [.app(.home), .libraryCategory(.movies), .libraryCategory(.series), .app(.recommendations)]

    func testTabsIgnoreRetiredDestinations() {
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home), .builtin(.movies), .builtin(.series),
            .library(libraryId: 7, label: "Movies"),
            .section(libraryId: 7, sectionId: "recent", label: "Recent"),
            .collection(collectionId: "favourites", label: "Favourites", libraryId: nil),
            .builtin(.forYou),
        ])
        let tabs = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: [Self.moviesLibrary, Self.seriesLibrary])
        XCTAssertEqual(tabs.map(\.id), Self.fourTabs)
    }

    func testHomeOnlyMenuShowsTheDefaultTabs() {
        let tabs = projectedMainTabDestinations(
            primaryMenu: PrimaryMenuPreference(items: [.builtin(.home)]),
            availableLibraries: [Self.moviesLibrary, Self.seriesLibrary]
        )
        XCTAssertEqual(tabs.map(\.id), Self.fourTabs)
    }

    func testRequestedLibrariesTab() {
        let series = visible([.app(.home), .libraryCategory(.series), .app(.downloads)])
        XCTAssertEqual(resolvedRequestedMainTabDestination(.libraries, visibleDestinations: series), .libraryCategory(.series))
        let libraries = visible([.app(.home), .app(.libraries), .libraryCategory(.series)])
        XCTAssertEqual(resolvedRequestedMainTabDestination(.libraries, visibleDestinations: libraries), .app(.libraries))
        let neither = visible([.app(.home), .app(.downloads)])
        XCTAssertEqual(resolvedRequestedMainTabDestination(.libraries, visibleDestinations: neither), .app(.home))
    }

    func testCategoryTabsNeedMatchingLibraries() {
        let menu = PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies), .builtin(.series)])
        XCTAssertEqual(projectedMainTabDestinations(primaryMenu: menu).map(\.id), [.app(.home), .app(.recommendations)])
        let mixed = Library(id: 9, name: "Everything", type: "mixed", sortOrder: nil, posterUrl: nil)
        XCTAssertEqual(
            projectedMainTabDestinations(primaryMenu: menu, availableLibraries: [mixed]).map(\.id),
            [.app(.home), .libraryCategory(.movies), .libraryCategory(.series)]
        )
    }

    func testLibrarySnapshotsBelongToOneProfile() throws {
        let profileA = try XCTUnwrap(MainTabLibraryAuthority(serverId: "server", profileId: "profile-a"))
        let profileB = try XCTUnwrap(MainTabLibraryAuthority(serverId: "server", profileId: "profile-b"))
        let menu = PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies)])

        let other = MainTabLibrarySnapshot(authority: profileA, libraries: [Self.moviesLibrary])
        let otherTabs = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: other.availableLibraries(for: profileB))
        XCTAssertEqual(otherTabs.map(\.id), [.app(.home), .app(.recommendations)])
        XCTAssertEqual(resolvedVisibleMainTabDestination(.libraryCategory(.movies), visibleDestinations: otherTabs), .app(.home))

        let own = MainTabLibrarySnapshot(authority: profileB, libraries: [Self.moviesLibrary])
        XCTAssertEqual(
            projectedMainTabDestinations(primaryMenu: menu, availableLibraries: own.availableLibraries(for: profileB)).map(\.id),
            [.app(.home), .libraryCategory(.movies)]
        )

        let empty = MainTabLibrarySnapshot(authority: profileB, libraries: [])
        let emptyTabs = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: empty.availableLibraries(for: profileB))
        XCTAssertEqual(emptyTabs.map(\.id), [.app(.home), .app(.recommendations)])
        XCTAssertEqual(resolvedVisibleMainTabDestination(.libraryCategory(.movies), visibleDestinations: emptyTabs), .app(.home))
    }

    func testMenuItemIcons() {
        XCTAssertEqual(PrimaryMenuItem.builtin(.home).navigationIcon, AppTab.home.icon)
        XCTAssertEqual(PrimaryMenuItem.builtin(.movies).navigationIcon, "film.stack")
        XCTAssertEqual(PrimaryMenuItem.builtin(.series).navigationIcon, "tv")
        XCTAssertEqual(PrimaryMenuItem.builtin(.forYou).navigationIcon, AppTab.recommendations.icon)
        XCTAssertEqual(PrimaryMenuItem.library(libraryId: 7, label: "Movies").navigationIcon, "rectangle.stack")
    }

    func testFixedMixedLibraryRoot() {
        let libraries = [
            Library(id: 1, name: "Mixed", type: "mixed", sortOrder: nil, posterUrl: nil),
            Library(id: 2, name: "Mixed Too", type: "mixed", sortOrder: nil, posterUrl: nil),
            Library(id: 3, name: "Movies", type: "movies", sortOrder: nil, posterUrl: nil),
            Library(id: 4, name: "Series", type: "series", sortOrder: nil, posterUrl: nil),
        ]
        XCTAssertEqual(visibleLibrariesForRoot(libraries, category: nil, fixedLibraryId: 1).map(\.id), [1, 2])
    }

    func testLibraryCategories() {
        let mixed = Library(id: 9, name: "Everything", type: "mixed", sortOrder: nil, posterUrl: nil)
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(Self.moviesLibrary, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .movies))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(Self.seriesLibrary, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(Self.seriesLibrary, category: .series))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .series))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(Self.moviesLibrary, category: .series))
    }

    func testDirectLibraryRoot() {
        let libraries = [Self.moviesLibrary, Self.seriesLibrary]
        XCTAssertEqual(visibleLibrariesForRoot(libraries, category: nil, fixedLibraryId: 8).map(\.id), [8])
        XCTAssertTrue(visibleLibrariesForRoot(libraries, category: nil, fixedLibraryId: 99).isEmpty)
        XCTAssertFalse(libraryRootCanSwitch(fixedLibraryId: 8, visibleLibraryCount: 1))
        XCTAssertTrue(libraryRootCanSwitch(fixedLibraryId: 8, visibleLibraryCount: 2))
        XCTAssertTrue(libraryRootCanSwitch(fixedLibraryId: nil, visibleLibraryCount: 2))
        XCTAssertEqual(resolvedLibraryIdForRoot(libraries, category: nil, fixedLibraryId: 7, storedLibraryId: 8), 7)
        XCTAssertEqual(resolvedLibraryIdForRoot(libraries, category: nil, fixedLibraryId: 8, storedLibraryId: 7), 8)
        let withMore = libraries + [Library(id: 9, name: "More Series", type: "series", sortOrder: nil, posterUrl: nil)]
        XCTAssertEqual(resolvedLibraryIdForRoot(withMore, category: nil, fixedLibraryId: 8, storedLibraryId: 0, currentSelectionId: 9), 9)
        XCTAssertEqual(resolvedLibraryIdForRoot(withMore, category: nil, fixedLibraryId: 8, storedLibraryId: 0, currentSelectionId: 7), 8)
    }

    func testLibrarySelectionKeys() throws {
        let profileA = try XCTUnwrap(MainTabLibraryAuthority(serverId: "server", profileId: "profile-a"))
        let profileB = try XCTUnwrap(MainTabLibraryAuthority(serverId: "server", profileId: "profile-b"))
        let aggregate = librarySelectionStorageKey(category: nil, fixedLibraryId: nil, authority: profileA)
        XCTAssertEqual(aggregate, "librariesTabSelectedLibraryId")
        let movies = try XCTUnwrap(librarySelectionStorageKey(category: .movies, fixedLibraryId: nil, authority: profileA))
        let series = try XCTUnwrap(librarySelectionStorageKey(category: .series, fixedLibraryId: nil, authority: profileA))
        XCTAssertNotEqual(movies, series)
        XCTAssertNotEqual(movies, librarySelectionStorageKey(category: .movies, fixedLibraryId: nil, authority: profileB))
        XCTAssertNil(librarySelectionStorageKey(category: .movies, fixedLibraryId: 7, authority: profileA))
        XCTAssertNil(librarySelectionStorageKey(category: .movies, fixedLibraryId: nil, authority: nil))

        let defaults = freshDefaults()
        defaults.set(8, forKey: "librariesTabSelectedLibraryId")
        XCTAssertEqual(storedLibrarySelectionId(for: movies, defaults: defaults), 8)
        defaults.set(9, forKey: movies)
        defaults.set(10, forKey: series)
        XCTAssertEqual(storedLibrarySelectionId(for: movies, defaults: defaults), 9)
        XCTAssertEqual(storedLibrarySelectionId(for: series, defaults: defaults), 10)
    }

    func testAppleTVEditingGate() {
        XCTAssertTrue(tvCustomizationMutationIsEnabled(allowsEditing: true, usesDeviceMenuOverride: false, changesFamilyMenu: true))
        XCTAssertFalse(tvCustomizationMutationIsEnabled(allowsEditing: false, usesDeviceMenuOverride: false, changesFamilyMenu: true))
        XCTAssertFalse(tvCustomizationMutationIsEnabled(allowsEditing: true, usesDeviceMenuOverride: true, changesFamilyMenu: true))
        XCTAssertTrue(tvCustomizationMutationIsEnabled(allowsEditing: true, usesDeviceMenuOverride: true, changesFamilyMenu: false))
        XCTAssertFalse(tvCustomizationMutationIsEnabled(allowsEditing: false, usesDeviceMenuOverride: true, changesFamilyMenu: false))
    }

    func testHiddenRequestedTabFallsBackToHome() {
        let tabs = visible([.app(.downloads), .libraryCategory(.movies), .app(.home)])
        XCTAssertEqual(resolvedRequestedMainTabDestination(.recommendations, visibleDestinations: tabs), .app(.home))
        XCTAssertEqual(resolvedRequestedMainTabDestination(.downloads, visibleDestinations: tabs), .app(.downloads))
    }

    func testMenuValidity() {
        let invalid: [[PrimaryMenuItem]] = [
            [.builtin(.movies)],
            [.builtin(.home), .builtin(.home)],
            [.builtin(.home), .library(libraryId: 7, label: "Movies"), .library(libraryId: 7, label: "Films")],
            [.builtin(.home), .library(libraryId: 7, label: "  \n")],
            [.builtin(.home), .section(libraryId: 7, sectionId: " \n ", label: "Recent")],
            [.builtin(.home), .collection(collectionId: "\t", label: "Favourites", libraryId: nil)],
        ]
        for items in invalid {
            XCTAssertFalse(PrimaryMenuPreference(items: items).isValid, "\(items)")
        }
    }

    /// The visible tab list, built the way the shell builds it.
    private func visible(_ ids: [MainTabDestinationID]) -> [MainTabDestination] {
        ids.compactMap(destination)
    }

    private func destination(_ id: MainTabDestinationID) -> MainTabDestination? {
        let all = projectedMainTabDestinations(
            primaryMenu: PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies), .builtin(.series), .builtin(.forYou)]),
            availableLibraries: [Self.moviesLibrary, Self.seriesLibrary]
        )
        if let found = all.first(where: { $0.id == id }) { return found }
        if case .app(let tab) = id { return MainTabDestination.app(tab) }
        return nil
    }

    // MARK: Saving

    func testRapidEditsAreSentInOrder() async throws {
        let transport = ScriptedTransport()
        let release = transport.holdFirstPut()
        let store = makeStore(freshStorage(), transport, start: .supported)
        store.setCardPresentation(Self.compact)
        store.setCardPresentation(Self.artwork)
        XCTAssertTrue(store.isSaving)

        try await eventually { transport.putsStarted == 1 }
        try await Task.sleep(for: .milliseconds(50))
        release()
        try await eventually { transport.putsFinished == 2 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertLessThanOrEqual(transport.maxPutsInFlight, 1)
        XCTAssertEqual(try transport.puts.map { try $0.value.decoded(as: CardPresentationPreference.self) }, [Self.compact, Self.artwork])
        XCTAssertFalse(store.isSaving)
    }

    func testEditAndOutboxAreStoredTogether() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport()
        let release = transport.holdFirstPut()
        let store = makeStore(storage, transport, start: .supported)
        store.setCardPresentation(Self.artwork)
        try await eventually { transport.putsStarted == 1 }

        let document = try storedDocument(storage)
        XCTAssertEqual((document["cardPresentation"] as? [String: Any])?["poster_size"] as? String, "large")
        XCTAssertNotNil((document["pendingSyncWrites"] as? [String: Any])?["ui.card_presentation"])
        release()
        try await eventually { transport.putsFinished == 1 }
    }

    func testOfflineEditIsSentBeforeTheNextRead() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport()
        var online = false
        var serverCard: CardPresentationPreference?
        transport.onPut = { value, _, _, _ in
            guard online else {
                transport.events.append("failed write")
                throw Self.offline
            }
            serverCard = try value.decoded(as: CardPresentationPreference.self)
            transport.events.append("write")
        }
        transport.onRead = { keys in
            transport.events.append("read")
            let rows = serverCard.map { [Self.cardRow($0, source: .scope(.profileClient), scope: .profileClient, family: "mobile")] } ?? []
            return Self.completeDefaultAnswer(keys, rows: rows)
        }
        let first = makeStore(storage, transport, start: .supported)
        first.setCardPresentation(Self.artwork)
        try await eventually { transport.events == ["failed write"] }
        online = true

        let second = makeStore(storage, transport)
        XCTAssertEqual(second.cardPresentation, Self.artwork)
        await second.refresh()
        XCTAssertEqual(transport.events, ["failed write", "write", "read"])
        XCTAssertEqual(transport.puts.count, 2)
        XCTAssertEqual(Set(transport.puts.map(\.mutationId)).count, 1)
        XCTAssertEqual(serverCard, Self.artwork)
        XCTAssertEqual(second.cardPresentation, Self.artwork)
        XCTAssertNil(second.syncErrorMessage)
    }

    func testPermanentlyRejectedEditShowsTheServerValue() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport()
        transport.onPut = { _, _, _, _ in throw HTTPError.http(statusCode: 422, body: nil) }
        transport.onRead = { Self.completeDefaultAnswer($0) }
        let store = makeStore(storage, transport, start: .supported)
        store.setCardPresentation(Self.artwork)
        try await eventually { !store.isSaving }

        XCTAssertEqual(store.cardPresentation, .standard)
        XCTAssertNil(store.syncErrorMessage)
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertEqual(transport.reads, [[.uiCardPresentation]])

        let second = makeStore(storage, transport)
        XCTAssertEqual(second.cardPresentation, .standard)
        await second.refresh()
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertNil(second.syncErrorMessage)
    }

    func testFailedProbeLeavesTheOutboxAlone() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport(capabilities: .failed(.transport(description: "offline")))
        transport.onPut = { _, _, _, _ in throw Self.offline }
        transport.onRead = { _ in Self.emptyAnswer }
        let first = makeStore(storage, transport, start: .supported)
        first.setCardPresentation(Self.artwork)
        first.setPrimaryMenuItems([.builtin(.home), .builtin(.forYou)])
        try await eventually { transport.puts.count == 2 }

        let second = makeStore(storage, transport)
        for description in ["offline", "still offline"] {
            transport.capabilities = .failed(.transport(description: description))
            await second.refresh()
            XCTAssertEqual(second.capabilityState, .unavailable)
            XCTAssertFalse(second.allowsEditing)
            XCTAssertEqual(second.cardPresentation, Self.artwork)
            XCTAssertEqual(second.primaryMenu?.items, [.builtin(.home), .builtin(.forYou)])
            XCTAssertEqual(transport.puts.count, 2)
            XCTAssertTrue(transport.reads.isEmpty)
        }

        // A server an older build recorded as unable to sync shows the
        // defaults until a refresh finds it can.
        let remembered = freshStorage()
        try storeDocument([
            "supportProjection": "known_unsupported",
            "cardPresentation": Self.largeArtworkCard,
            "primaryMenu": ["items": [["type": "builtin", "destination": "home"], ["type": "builtin", "destination": "for_you"]]],
        ], in: remembered)
        transport.capabilities = .failed(.transport(description: "offline"))
        let third = makeStore(remembered, transport)
        XCTAssertEqual(third.cardPresentation, .standard)
        XCTAssertNil(third.primaryMenu)
        await third.refresh()
        XCTAssertEqual(third.capabilityState, .unavailable)
        XCTAssertEqual(third.cardPresentation, .standard)
        XCTAssertNil(third.primaryMenu)
        XCTAssertEqual(try storedDocument(remembered)["supportProjection"] as? String, "known_unsupported")

        transport.capabilities = .available(Self.capabilities())
        await third.refresh()
        XCTAssertEqual(third.capabilityState, .supported)
        XCTAssertEqual(third.cardPresentation, Self.artwork)
        XCTAssertEqual(third.primaryMenu?.items, [.builtin(.home), .builtin(.forYou)])
        XCTAssertEqual(third.syncErrorMessage, "The server did not return this interface preference.")
    }

    func testResettingTheCardSurvivesGoingOffline() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport()
        var online = false
        var familyRow = true
        transport.onRead = { keys in
            transport.events.append("read")
            let rows = familyRow ? [Self.cardRow(Self.compact, source: .scope(.profileClient), scope: .profileClient, family: "mobile")] : []
            return Self.completeDefaultAnswer(keys, rows: rows)
        }
        transport.onDelete = { _, _ in
            guard online else {
                transport.events.append("failed delete")
                throw Self.offline
            }
            familyRow = false
            transport.events.append("delete")
        }
        let first = makeStore(storage, transport)
        await first.refresh()
        XCTAssertTrue(first.cardPresentationUsesFamilyOverride)
        XCTAssertEqual(first.cardPresentation, Self.compact)

        transport.events = []
        first.resetCardPresentationToInherited()
        try await eventually { transport.deletes.count == 1 }
        try await eventually { !first.isSaving }
        online = true

        let second = makeStore(storage, transport)
        await second.refresh()
        XCTAssertEqual(transport.events, ["failed delete", "delete", "read"])
        XCTAssertEqual(transport.deletes.map(\.scope), [.profileClient, .profileClient])
        XCTAssertEqual(second.cardPresentation, .standard)
        XCTAssertFalse(second.cardPresentationUsesFamilyOverride)
        XCTAssertNil(second.syncErrorMessage)
    }

    func testQueuedWorkNeverFollowsAChangedIdentity() async throws {
        var identity = Self.identity(family: "mobile")
        let transport = ScriptedTransport()
        let release = transport.holdFirstPut()
        let store = UICustomizationPreferences(
            storage: freshStorage(), transport: transport,
            activeCacheKey: { UICustomizationPreferences.cacheKey(for: identity) },
            activeIdentity: { identity },
            capabilityState: .supported
        )
        store.setCardPresentation(Self.compact)
        store.setCardPresentation(Self.artwork)
        try await eventually { transport.putsStarted == 1 }
        identity = HTTPRequestIdentity(serverId: "server-b", serverURL: "http://server-b.invalid", profileId: "profile-b", clientFamily: "mobile")
        release()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(transport.puts.allSatisfy { $0.identity == Self.identity(family: "mobile") })
        XCTAssertEqual(transport.puts.count, 1)
        XCTAssertFalse(store.isSaving)
    }

    // MARK: Device rows

    func testDeviceRowsAreReported() async {
        let transport = ScriptedTransport()
        transport.onRead = { _ in
            EffectiveSettingValuesResponse(settings: [
                Self.menuRow([.builtin(.home), .builtin(.movies)], source: .scope(.profileDevice), scope: .profileDevice, device: "device"),
                Self.cardRow(Self.compact, source: .scope(.profileDevice), scope: .profileDevice, device: "device"),
            ], revision: SettingKey.revision)
        }
        let store = makeStore(freshStorage(), transport, key: Self.tvKey, start: .supported)
        await store.refresh()
        XCTAssertTrue(store.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(store.cardPresentationUsesDeviceOverride)
        XCTAssertTrue(store.hasDeviceOverrides)
    }

    func testOneDeviceDeleteFailingLeavesTheOtherReconciled() async throws {
        let storage = freshStorage()
        let transport = DeviceRowsServer(failingDelete: .navPrimaryMenu)
        let store = makeStore(storage, transport.transport, key: Self.tvKey, start: .supported)
        await store.refresh()
        XCTAssertTrue(store.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(store.cardPresentationUsesDeviceOverride)

        store.useFamilySettings()
        try await eventually { !store.isSaving }
        XCTAssertTrue(store.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(store.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(store.cardPresentation, .standard)
        XCTAssertNotNil(store.syncErrorMessage)
        XCTAssertEqual(transport.transport.deletes.map(\.key), [.navPrimaryMenu, .uiCardPresentation])
        XCTAssertEqual(transport.singleKeyReads, [.uiCardPresentation])

        let second = makeStore(storage, transport.transport, key: Self.tvKey)
        await second.refresh()
        XCTAssertEqual(transport.transport.deletes.map(\.key), [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu])
        XCTAssertFalse(second.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(second.cardPresentation, .standard)
    }

    func testDeviceDeleteWhoseReadFailsStaysQueued() async throws {
        let storage = freshStorage()
        let transport = DeviceRowsServer(failingRead: .navPrimaryMenu)
        let store = makeStore(storage, transport.transport, key: Self.tvKey, start: .supported)
        await store.refresh()
        store.useFamilySettings()
        try await eventually { !store.isSaving }
        XCTAssertTrue(store.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(store.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(store.syncErrorMessage)

        let second = makeStore(storage, transport.transport, key: Self.tvKey)
        await second.refresh()
        XCTAssertEqual(transport.transport.deletes.map(\.key), [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu])
        XCTAssertEqual(transport.singleKeyReads, [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu])
        XCTAssertFalse(second.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(second.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(second.primaryMenu?.items, [.builtin(.home), .builtin(.series)])
        XCTAssertEqual(second.cardPresentation, .standard)
        XCTAssertNil(second.syncErrorMessage)
    }

    func testEachKeyReconcilesOnItsOwn() async throws {
        let storage = freshStorage()
        let transport = ScriptedTransport()
        var answer = EffectiveSettingValuesResponse(settings: [
            Self.menuRow([.builtin(.home), .builtin(.movies)], source: .scope(.profileDevice), scope: .profileDevice, device: "device"),
            Self.cardRow(Self.compact, source: .scope(.profileDevice), scope: .profileDevice, device: "device"),
        ], revision: SettingKey.revision)
        transport.onRead = { _ in answer }
        let store = makeStore(storage, transport, start: .supported)
        await store.refresh()

        let futureCard: SettingJSONValue = .object(["poster_size": .string("future-size"), "caption": .string("title")])
        answer = EffectiveSettingValuesResponse(settings: [
            Self.menuRow([.builtin(.home), .builtin(.series)], source: .scope(.profileClient), scope: .profileClient, family: "mobile"),
            EffectiveSettingValue(key: SettingKey.uiCardPresentation.rawValue, value: futureCard, source: .scope(.profileClient), scope: .profileClient, profileId: "profile", clientFamily: "mobile"),
        ], revision: SettingKey.revision)
        await store.refresh()
        XCTAssertEqual(store.primaryMenu?.items, [.builtin(.home), .builtin(.series)])
        XCTAssertFalse(store.primaryMenuUsesDeviceOverride)
        XCTAssertEqual(store.cardPresentation, Self.compact)
        XCTAssertTrue(store.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(store.syncErrorMessage)

        answer = EffectiveSettingValuesResponse(settings: [
            Self.menuRow([.builtin(.movies)], source: .scope(.profileDevice), scope: .profileDevice, device: "device"),
            Self.cardRow(Self.artwork, source: .scope(.profileClient), scope: .profileClient, family: "mobile"),
        ], revision: SettingKey.revision)
        await store.refresh()
        XCTAssertEqual(store.primaryMenu?.items, [.builtin(.home), .builtin(.series)])
        XCTAssertFalse(store.primaryMenuUsesDeviceOverride)
        XCTAssertEqual(store.cardPresentation, Self.artwork)
        XCTAssertFalse(store.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(store.syncErrorMessage)

        let reopened = makeStore(storage, transport)
        XCTAssertEqual(reopened.primaryMenu?.items, [.builtin(.home), .builtin(.series)])
        XCTAssertEqual(reopened.cardPresentation, Self.artwork)
        XCTAssertFalse(reopened.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(reopened.cardPresentationUsesDeviceOverride)
    }

    func testStoredValuesSurviveAnOfflineRefresh() async throws {
        let storage = freshStorage()
        let menu: [PrimaryMenuItem] = [.builtin(.home), .builtin(.movies), .builtin(.forYou)]
        let transport = ScriptedTransport()
        transport.onRead = { _ in
            EffectiveSettingValuesResponse(settings: [
                Self.menuRow(menu, source: .scope(.profileClient), scope: .profileClient, family: "mobile"),
                Self.cardRow(Self.artwork, source: .scope(.profileClient), scope: .profileClient, family: "mobile"),
            ], revision: SettingKey.revision)
        }
        let store = makeStore(storage, transport)
        await store.refresh()
        XCTAssertEqual(store.primaryMenu?.items, menu)
        XCTAssertEqual(store.cardPresentation, Self.artwork)
        XCTAssertNil(store.syncErrorMessage)

        let offlineTransport = ScriptedTransport()
        offlineTransport.onRead = { _ in throw Self.offline }
        let second = makeStore(storage, offlineTransport)
        XCTAssertEqual(second.primaryMenu?.items, menu)
        XCTAssertEqual(second.cardPresentation, Self.artwork)
        await second.refresh()
        XCTAssertEqual(second.primaryMenu?.items, menu)
        XCTAssertEqual(second.cardPresentation, Self.artwork)
        XCTAssertNotNil(second.syncErrorMessage)
    }
}

// MARK: - Fakes

/// A settings service whose answers each test scripts, recording every call.
@MainActor
private final class ScriptedTransport: InterfaceSettingsTransport {
    struct Put {
        let key: SettingKey
        let value: SettingJSONValue
        let mutationId: String
        let identity: HTTPRequestIdentity
    }

    var capabilities: SettingsCapabilitiesResult
    var onRead: @MainActor ([SettingKey]) async throws -> EffectiveSettingValuesResponse = { _ in
        EffectiveSettingValuesResponse(settings: [], revision: SettingKey.revision)
    }
    var onPut: @MainActor (SettingJSONValue, SettingKey, String, HTTPRequestIdentity) async throws -> Void = { _, _, _, _ in }
    var onDelete: @MainActor (SettingKey, SettingScopeIdentity) async throws -> Void = { _, _ in }
    var events: [String] = []
    private(set) var reads: [[SettingKey]] = []
    private(set) var puts: [Put] = []
    private(set) var deletes: [(key: SettingKey, scope: SettingScopeIdentity)] = []
    private(set) var putsStarted = 0
    private(set) var putsFinished = 0
    private(set) var maxPutsInFlight = 0
    private var putsInFlight = 0
    private var heldPut: CheckedContinuation<Void, Never>?
    private var holdsFirstPut = false
    private var released = false

    init(capabilities: SettingsCapabilitiesResult = .available(SettingsContractCapabilities(
        apiVersion: 1, revision: SettingKey.revision, contractEtag: "test", definitionCount: 3,
        scopes: ["profile", "profile_client", "profile_device"],
        supportsBatchedEffective: true, supportsIdempotentWrites: true, supportsAtomicShortcuts: true
    ))) {
        self.capabilities = capabilities
    }

    /// Holds the first write open until the returned closure runs.
    func holdFirstPut() -> @MainActor () -> Void {
        holdsFirstPut = true
        return { [self] in
            released = true
            heldPut?.resume()
            heldPut = nil
        }
    }

    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        capabilities
    }

    func effectiveValues(for keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        reads.append(keys)
        return try await onRead(keys)
    }

    func putValue(_ value: SettingJSONValue, for key: SettingKey, scope: SettingScopeIdentity, mutationId: String, requestIdentity: HTTPRequestIdentity) async throws {
        puts.append(Put(key: key, value: value, mutationId: mutationId, identity: requestIdentity))
        putsStarted += 1
        putsInFlight += 1
        maxPutsInFlight = max(maxPutsInFlight, putsInFlight)
        defer {
            putsInFlight -= 1
            putsFinished += 1
        }
        if holdsFirstPut, putsStarted == 1, !released {
            await withCheckedContinuation { heldPut = $0 }
        }
        try await onPut(value, key, mutationId, requestIdentity)
    }

    func deleteValue(for key: SettingKey, scope: SettingScopeIdentity, requestIdentity: HTTPRequestIdentity) async throws {
        deletes.append((key, scope))
        try await onDelete(key, scope)
    }
}

/// A server holding device rows for both keys, for the "use this profile's
/// settings" tests. One delete or one read can be made to fail.
@MainActor
private final class DeviceRowsServer {
    let transport = ScriptedTransport()
    private(set) var singleKeyReads: [SettingKey] = []
    private var menuDeviceRow = true
    private var cardDeviceRow = true
    private var readFailureUsed = false

    init(failingDelete: SettingKey? = nil, failingRead: SettingKey? = nil) {
        transport.onRead = { [unowned self] keys in
            if keys.count == 1, let key = keys.first {
                singleKeyReads.append(key)
                if key == failingRead, !readFailureUsed {
                    readFailureUsed = true
                    throw URLError(.notConnectedToInternet)
                }
            }
            return EffectiveSettingValuesResponse(settings: keys.map(row), revision: SettingKey.revision)
        }
        transport.onDelete = { [unowned self] key, _ in
            if key == failingDelete { throw URLError(.notConnectedToInternet) }
            switch key {
            case .navPrimaryMenu:
                guard menuDeviceRow else { throw SettingsAPIError.noValueAtScope }
                menuDeviceRow = false
            default:
                guard cardDeviceRow else { throw SettingsAPIError.noValueAtScope }
                cardDeviceRow = false
            }
        }
    }

    private func row(_ key: SettingKey) -> EffectiveSettingValue {
        func encoded(_ value: some Encodable) -> SettingJSONValue { try! SettingJSONValue.encoding(value) }
        if key == .navPrimaryMenu {
            return menuDeviceRow
                ? EffectiveSettingValue(key: key.rawValue, value: encoded(PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies)])), source: .scope(.profileDevice), scope: .profileDevice, profileId: "profile", deviceId: "device")
                : EffectiveSettingValue(key: key.rawValue, value: encoded(PrimaryMenuPreference(items: [.builtin(.home), .builtin(.series)])), source: .scope(.profileClient), scope: .profileClient, profileId: "profile", clientFamily: "tv")
        }
        return cardDeviceRow
            ? EffectiveSettingValue(key: key.rawValue, value: encoded(CardPresentationPreset.compact.presentation), source: .scope(.profileDevice), scope: .profileDevice, profileId: "profile", deviceId: "device")
            : EffectiveSettingValue(key: key.rawValue, value: encoded(CardPresentationPreference.standard), source: .contractDefault, profileId: "profile")
    }
}
