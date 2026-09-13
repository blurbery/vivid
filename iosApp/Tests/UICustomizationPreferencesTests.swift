import XCTest
@testable import Vivid

@MainActor
final class UICustomizationPreferencesTests: XCTestCase {
    func testLegacyShortcutCacheIsDiscardedWithoutLosingCardPreferences() async throws {
        let suiteName = "ui-retired-navigation-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let legacy: [String: Any] = [
            "primaryMenu": ["items": [
                ["type": "builtin", "destination": "home"],
                ["type": "builtin", "destination": "music"],
                ["type": "library", "library_id": 7, "label": "Old pin"],
                ["type": "builtin", "destination": "for_you"],
            ]],
            "shortcuts": ["items": [["type": "library", "library_id": 7, "label": "Old pin"]]],
            "pendingShortcutOperations": ["bad": "retired data must not be decoded"],
            "pendingSyncWrites": ["nav.shortcuts": ["value": ["items": []], "mutationId": "old-write"]],
            "cardPresentation": ["poster_size": "large", "caption": "artwork"],
            "supportProjection": "supported",
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: cacheKey)
        let transport = RetiredNavigationProbe()
        let preferences = UICustomizationPreferences(
            defaults: defaults, transport: transport,
            cacheKey: { cacheKey }, requestIdentity: { testRequestIdentity(family: "mobile") }
        )
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreset.artworkOnly.presentation)
        XCTAssertEqual(preferences.resolvedPrimaryMenuItems(), [.builtin(.home), .builtin(.forYou)])
        let data = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(saved["shortcuts"])
        XCTAssertNil(saved["pendingShortcutOperations"])
        XCTAssertNil(saved["pendingSyncWrites"])
        await preferences.refresh()
        let observed = await transport.snapshot()
        XCTAssertEqual(observed.keys, [.navPrimaryMenu, .uiCardPresentation])
        XCTAssertEqual(observed.writes, 0)
        XCTAssertTrue(preferences.allowsEditing, "tab/card settings no longer require atomic shortcut support")
    }

    func testResolvedHomeOnlyMenuUsesTheSameDefaultsAsMainTabs() throws {
        let suiteName = "ui-home-sentinel-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let cached: [String: Any] = [
            "primaryMenu": ["items": [["type": "builtin", "destination": "home"]]],
            "cardPresentation": ["poster_size": "standard", "caption": "title_metadata"],
            "supportProjection": "supported",
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: cached), forKey: cacheKey)
        let preferences = UICustomizationPreferences(
            defaults: defaults, transport: RetiredNavigationProbe(),
            cacheKey: { cacheKey }, requestIdentity: { testRequestIdentity(family: "mobile") }
        )
        XCTAssertEqual(preferences.primaryMenu?.items, [.builtin(.home)], "the sentinel must be loaded from cache")
        XCTAssertEqual(preferences.resolvedPrimaryMenuItems(), appleDefaultPrimaryMenuItems())
    }

    func testNamedPresetsMatchTheCrossClientRecipes() {
        XCTAssertEqual(
            CardPresentationPreset.balanced.presentation,
            .init(posterSize: .standard, caption: .titleMetadata)
        )
        XCTAssertEqual(
            CardPresentationPreset.compact.presentation,
            .init(posterSize: .compact, caption: .title)
        )
        XCTAssertEqual(
            CardPresentationPreset.cinema.presentation,
            .init(posterSize: .large, caption: .title)
        )
        XCTAssertEqual(
            CardPresentationPreset.artworkOnly.presentation,
            .init(posterSize: .large, caption: .artwork)
        )
    }

    func testPosterSizeAdjustsTVGridDensityAndArtworkScale() {
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .compact),
            6
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .standard),
            6
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .large),
            5
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 3, posterSize: .large),
            3
        )
        XCTAssertEqual(CardPosterSize.compact.scale, 0.86, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.standard.scale, 1, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.large.scale, 1.2, accuracy: 0.001)
    }

    func testVisibleRootChangesOnlyRearmTheAffectedFocusOwner() {
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: false,
                isShowingRoot: true,
                selectedRootWasRemoved: false
            ),
            .none,
            "reordering an unrelated root must preserve the currently focused card"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: false,
                isShowingRoot: true,
                selectedRootWasRemoved: true
            ),
            .content,
            "removing content's selected root must hand focus to the Home content"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: true,
                isShowingRoot: true,
                selectedRootWasRemoved: false
            ),
            .topMenu,
            "a changing focus graph must explicitly re-arm the top menu when it owns focus"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: true,
                isShowingRoot: false,
                selectedRootWasRemoved: true
            ),
            .none,
            "a pushed route must not re-arm hidden root content"
        )
    }

    func testCaptionStylesGateTitleAndMetadataIndependently() {
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsTitle)
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsMetadata)
        XCTAssertTrue(CardCaptionStyle.title.showsTitle)
        XCTAssertFalse(CardCaptionStyle.title.showsMetadata)
        XCTAssertFalse(CardCaptionStyle.artwork.showsTitle)
        XCTAssertFalse(CardCaptionStyle.artwork.showsMetadata)
    }

    func testCardAccessibilityLabelsRetainHiddenIdentityAndStatus() {
        XCTAssertEqual(
            mediaCardAccessibilityLabel(
                title: "The Episode",
                episodeLabel: "S2 · E10",
                year: 2026,
                isWatched: true
            ),
            "The Episode, S2 · E10, 2026, Watched"
        )
        XCTAssertEqual(
            episodeRailAccessibilityLabel(
                seasonNumber: 2,
                episodeNumber: 10,
                title: "The Episode",
                metadata: "Aug 3 · 52m",
                isCurrent: true,
                isPlayed: true
            ),
            "Season 2, Episode 10, The Episode, Aug 3 · 52m, Now viewing, Watched"
        )
    }

    func testSpecializedCardAccessibilityLabelsIncludeOverlayMetadata() {
        let collection = LibraryCollection(
            id: "collection-1",
            name: "Favorites",
            collectionType: "movies",
            itemCount: 12
        )
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(collection),
            "Favorites, Movies, 12 items"
        )
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(
                LibraryCollection(id: "empty", name: "Empty", itemCount: 0)
            ),
            "Empty, Collection, 0 items"
        )

    }

    func testLegacyCalendarMenuEntryIsRemovedWithoutLosingOtherTabs() throws {
        let data = Data(#"{"items":[{"type":"builtin","destination":"home"},{"type":"builtin","destination":"calendar"},{"type":"builtin","destination":"music"},{"type":"library","library_id":7,"label":"Movies"},{"type":"builtin","destination":"for_you"}]}"#.utf8)
        let menu = try JSONDecoder().decode(PrimaryMenuPreference.self, from: data)
        XCTAssertEqual(menu.items, [
            .builtin(.home),
            .library(libraryId: 7, label: "Movies"),
            .builtin(.forYou)
        ])
        XCTAssertTrue(menu.isValid)
        let encoded = try JSONEncoder().encode(menu)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("calendar"))
        XCTAssertEqual(try JSONDecoder().decode(PrimaryMenuPreference.self, from: encoded), menu)
        let malformed = Data(#"{"items":[{"type":"builtin","destination":"home"},{"type":"library","library_id":"invalid","label":"Movies"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PrimaryMenuPreference.self, from: malformed))
    }

    func testCustomizationModelsUseTheExactSettingsContractShape() throws {
        let cards = CardPresentationPreference(posterSize: .large, caption: .artwork)
        XCTAssertEqual(
            String(data: try SettingsWireCoding.makeEncoder().encode(cards), encoding: .utf8),
            #"{"caption":"artwork","poster_size":"large"}"#
        )

        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: 7, label: "Movies"),
            .section(libraryId: 7, sectionId: "recently-added", label: "Recently Added"),
            .collection(collectionId: "favorites", label: "Favorites", libraryId: 7),
        ])
        let encoded = try SettingsWireCoding.makeEncoder().encode(menu)
        let decoded = try SettingsWireCoding.makeDecoder().decode(
            PrimaryMenuPreference.self,
            from: encoded
        )

        XCTAssertEqual(decoded, menu)
        XCTAssertTrue(decoded.isValid)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["type"] as? String, "builtin")
        XCTAssertEqual(items[0]["destination"] as? String, "home")
        XCTAssertEqual(items[1]["library_id"] as? Int, 7)
        XCTAssertEqual(items[2]["section_id"] as? String, "recently-added")
        XCTAssertEqual(items[3]["collection_id"] as? String, "favorites")
    }

    func testCollectionIdentityIsStructuredWithoutChangingTheWireFormat() throws {
        let unscoped = PrimaryMenuItem.collection(
            collectionId: "12:featured",
            label: "Featured",
            libraryId: nil
        )
        let scoped = PrimaryMenuItem.collection(
            collectionId: "featured",
            label: "Featured",
            libraryId: 12
        )
        let renamed = PrimaryMenuItem.collection(
            collectionId: "12:featured",
            label: "Renamed",
            libraryId: nil
        )

        XCTAssertEqual(unscoped.id, "collection|0|0#|11#12:featured")
        XCTAssertEqual(scoped.id, "collection|1|2#12|8#featured")
        XCTAssertNotEqual(unscoped.id, scoped.id)
        XCTAssertEqual(unscoped.id, renamed.id, "a display label is not semantic identity")

        let data = try SettingsWireCoding.makeEncoder().encode(unscoped)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "collection")
        XCTAssertEqual(object["collection_id"] as? String, "12:featured")
        XCTAssertNil(object["library_id"])
        XCTAssertNil(object["id"], "the structured client identity must not enter the wire contract")
    }

    func testMainTabProjectionIgnoresRetiredLibraryDestinations() {
        let movie = Library(id: 7, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
        let series = Library(id: 8, name: "Series", type: "series", sortOrder: 1, posterUrl: nil)
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home), .builtin(.movies), .builtin(.series),
            .library(libraryId: 7, label: "Old pin"),
            .section(libraryId: 7, sectionId: "recent", label: "Recent"),
            .collection(collectionId: "old", label: "Old collection", libraryId: 7),
            .builtin(.forYou),
        ])
        let destinations = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: [movie, series])
        XCTAssertEqual(destinations.map(\.id), [
            .app(.home), .libraryCategory(.movies), .libraryCategory(.series), .app(.recommendations),
        ])
    }

    func testHomeOnlyMainTabProjectionRestoresAppleDefaults() {
        let menu = PrimaryMenuPreference(items: [.builtin(.home)])
        let destinations = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: [
                Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil),
                Library(id: 2, name: "Series", type: "series", sortOrder: 1, posterUrl: nil),
            ]
        )

        XCTAssertEqual(
            destinations.map(\.id),
            [
                .app(.home),
                .libraryCategory(.movies),
                .libraryCategory(.series),
                .app(.recommendations),
            ]
        )
    }

    func testLibraryTabRequestUsesFirstAuthoredLibraryRoot() {
        let authoredDestinations: [MainTabDestination] = [
            .app(.home),
            .libraryCategory(.series),
            .app(.downloads),
        ]
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: authoredDestinations
            ),
            .libraryCategory(.series),
            "Browse Libraries should follow authored menu order when the aggregate root is hidden"
        )

        let aggregateDestinations: [MainTabDestination] = [
            .app(.home),
            .app(.libraries),
            .libraryCategory(.series),
        ]
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: aggregateDestinations
            ),
            .app(.libraries)
        )
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: [.app(.home), .app(.downloads)]
            ),
            .app(.home)
        )
    }

    func testMainTabProjectionOnlyShowsCategoriesBackedByCurrentLibraries() {
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.series),
        ])
        XCTAssertEqual(
            projectedMainTabDestinations(primaryMenu: menu).map(\.id),
            [.app(.home), .app(.recommendations)],
            "unavailable library categories must fall back to app roots without rendering dead library roots"
        )

        let mixed = Library(id: 4, name: "Mixed", type: "mixed", sortOrder: 0, posterUrl: nil)
        XCTAssertEqual(
            projectedMainTabDestinations(
                primaryMenu: menu,
                availableLibraries: [mixed]
            ).map(\.id),
            [.app(.home), .libraryCategory(.movies), .libraryCategory(.series)]
        )
    }

    func testMainTabLibrarySnapshotRejectsPreviousProfileWithOverlappingId() throws {
        let serverId = "server"
        let firstProfile = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: serverId, profileId: "profile-a")
        )
        let secondProfile = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: serverId, profileId: "profile-b")
        )
        let library = Library(
            id: 7,
            name: "Same Numeric ID",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
        ])
        let staleSnapshot = MainTabLibrarySnapshot(
            authority: firstProfile,
            libraries: [library]
        )

        let staleProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: staleSnapshot.availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(
            staleProjection.map(\.id),
            [.app(.home), .app(.recommendations)],
            "a previous profile's library must stay hidden while the app fallback remains available"
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(
                .libraryCategory(.movies),
                visibleDestinations: staleProjection
            ),
            .app(.home)
        )

        let currentSnapshot = MainTabLibrarySnapshot(
            authority: secondProfile,
            libraries: [library]
        )
        let currentProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: currentSnapshot.availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(currentProjection.map(\.id), [.app(.home), .libraryCategory(.movies)])

        let revokedProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: MainTabLibrarySnapshot(
                authority: secondProfile,
                libraries: []
            ).availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(
            revokedProjection.map(\.id),
            [.app(.home), .app(.recommendations)],
            "revoking library access must restore app roots without retaining an inaccessible category"
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(
                .libraryCategory(.movies),
                visibleDestinations: revokedProjection
            ),
            .app(.home),
            "a same-authority access revocation must remove the category and select Home"
        )
    }

    func testPrimaryMenuItemsUseMainMenuNavigationIcons() {
        XCTAssertEqual(PrimaryMenuItem.builtin(.home).navigationIcon, AppTab.home.icon)
        XCTAssertEqual(PrimaryMenuItem.builtin(.movies).navigationIcon, "film.stack")
        XCTAssertEqual(PrimaryMenuItem.builtin(.series).navigationIcon, "tv")
        XCTAssertEqual(
            PrimaryMenuItem.builtin(.forYou).navigationIcon,
            AppTab.recommendations.icon
        )
        XCTAssertEqual(
            PrimaryMenuItem.library(libraryId: 1, label: "Movies").navigationIcon,
            "rectangle.stack"
        )
    }

    func testFixedMixedLibraryOnlySwitchesAmongMixedLibraries() {
        let mixed = Library(
            id: 1, name: "Mixed A", type: "mixed", sortOrder: 0, posterUrl: nil
        )
        let otherMixed = Library(
            id: 2, name: "Mixed B", type: "mixed", sortOrder: 1, posterUrl: nil
        )
        let movies = Library(
            id: 3, name: "Movies", type: "movies", sortOrder: 2, posterUrl: nil
        )
        let series = Library(
            id: 4, name: "Series", type: "series", sortOrder: 3, posterUrl: nil
        )

        XCTAssertEqual(
            visibleLibrariesForRoot(
                [mixed, otherMixed, movies, series],
                category: nil,
                fixedLibraryId: mixed.id
            ).map(\.id),
            [mixed.id, otherMixed.id]
        )
    }

    func testPrimaryMenuLibraryCategoriesKeepTheirAuthoredMediaScope() {
        let movie = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
        let series = Library(id: 2, name: "Shows", type: "series", sortOrder: 1, posterUrl: nil)
        let mixed = Library(id: 3, name: "Mixed", type: "mixed", sortOrder: 2, posterUrl: nil)
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(movie, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .movies))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(series, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(series, category: .series))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .series))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(movie, category: .series))
    }

    func testDirectLibraryRootUsesExactAccessibleLibraryAndFixedChrome() {
        let first = Library(id: 7, name: "First", type: "movies", sortOrder: 0, posterUrl: nil)
        let second = Library(id: 8, name: "Second", type: "series", sortOrder: 1, posterUrl: nil)

        XCTAssertEqual(
            visibleLibrariesForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: second.id
            ),
            [second]
        )
        XCTAssertTrue(
            visibleLibrariesForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: 99
            ).isEmpty,
            "an inaccessible pinned ID must not fall through to another library"
        )
        XCTAssertFalse(
            libraryRootCanSwitch(fixedLibraryId: second.id, visibleLibraryCount: 1),
            "a direct root with no same-type siblings disables the library picker"
        )
        XCTAssertTrue(
            libraryRootCanSwitch(fixedLibraryId: second.id, visibleLibraryCount: 2),
            "a direct root with same-type siblings allows switching via the top selector"
        )
        XCTAssertTrue(libraryRootCanSwitch(fixedLibraryId: nil, visibleLibraryCount: 2))

        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: first.id,
                storedLibraryId: second.id
            ),
            first.id
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: second.id,
                storedLibraryId: first.id
            ),
            second.id,
            "changing a reused fixed-root scope must immediately select the new exact library"
        )

        let sibling = Library(
            id: 9, name: "Sibling", type: "series", sortOrder: 2, posterUrl: nil
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second, sibling],
                category: nil,
                fixedLibraryId: second.id,
                storedLibraryId: 0,
                currentSelectionId: sibling.id
            ),
            sibling.id,
            "an in-session switch to a same-type sibling must survive re-resolution"
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second, sibling],
                category: nil,
                fixedLibraryId: second.id,
                storedLibraryId: 0,
                currentSelectionId: first.id
            ),
            second.id,
            "a selection outside the root scope must fall back to the pinned library"
        )
    }

    func testLibrarySelectionPersistenceIsScopedByAuthorityAndRoot() throws {
        let firstAuthority = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: "server", profileId: "profile-a")
        )
        let secondAuthority = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: "server", profileId: "profile-b")
        )
        let aggregateKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: nil,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let moviesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let seriesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .series,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let otherProfileMoviesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: secondAuthority
            )
        )

        XCTAssertEqual(aggregateKey, "librariesTabSelectedLibraryId")
        XCTAssertNotEqual(moviesKey, seriesKey)
        XCTAssertNotEqual(moviesKey, otherProfileMoviesKey)
        XCTAssertNil(
            librarySelectionStorageKey(
                category: nil,
                fixedLibraryId: 7,
                authority: firstAuthority
            ),
            "a fixed root derives its selection from the destination and must not persist it"
        )
        XCTAssertNil(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: nil
            ),
            "an unauthenticated category root must not persist under a shared none:none key"
        )

        let suiteName = "library-selection-scope-suite-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set(8, forKey: aggregateKey)
        XCTAssertEqual(
            storedLibrarySelectionId(for: moviesKey, defaults: defaults),
            8,
            "a missing scoped value seeds from the legacy aggregate selection"
        )
        defaults.set(9, forKey: moviesKey)
        defaults.set(10, forKey: seriesKey)
        XCTAssertEqual(storedLibrarySelectionId(for: moviesKey, defaults: defaults), 9)
        XCTAssertEqual(storedLibrarySelectionId(for: seriesKey, defaults: defaults), 10)
    }

    func testTVCustomizationControlsDisableAcrossCapabilityChanges() {
        XCTAssertTrue(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: false,
                changesFamilyMenu: true
            )
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: false,
                usesDeviceMenuOverride: false,
                changesFamilyMenu: true
            ),
            "an already-presented menu or picker must stop accepting mutations"
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: true
            )
        )
        XCTAssertTrue(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: false
            ),
            "card preferences remain editable under a device menu override"
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: false,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: false
            )
        )
    }

    func testHiddenRequestedTabFallsBackToHomeAfterMenuReordering() {
        let visible = [
            MainTabDestination.app(.downloads),
            MainTabDestination.libraryCategory(.movies),
            MainTabDestination.app(.home),
        ]

        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .recommendations,
                visibleDestinations: visible
            ),
            .app(.home)
        )
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(.downloads, visibleDestinations: visible),
            .app(.downloads)
        )
    }

    func testPrimaryMenuRejectsMissingOrDuplicateHomeAndDuplicateShortcuts() {
        XCTAssertFalse(PrimaryMenuPreference(items: [.builtin(.movies)]).isValid)
        XCTAssertFalse(
            PrimaryMenuPreference(items: [.builtin(.home), .builtin(.home)]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .library(libraryId: 7, label: "Movies"),
                .library(libraryId: 7, label: "Renamed Movies"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .library(libraryId: 7, label: "  \n"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .section(libraryId: 7, sectionId: " \n ", label: "Recent"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .collection(collectionId: "\t", label: "Favorites", libraryId: nil),
            ]).isValid
        )
    }

    func testRapidEditsAreWrittenInOrderAndSavingCoversTheWholeQueue() async throws {
        let suiteName = "ui-customization-writes-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-writes-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = OrderedWriteProbe()
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "vivid.uiCustomization.server.profile.mobile" },
            requestIdentity: { testRequestIdentity(family: "mobile") },
            initialCapabilityState: .supported
        )

        preferences.setCardPresentation(CardPresentationPreset.compact.presentation)
        preferences.setCardPresentation(CardPresentationPreset.artworkOnly.presentation)
        XCTAssertTrue(preferences.isSaving)

        let release = Task {
            await transport.waitForStartedWrites(1)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await transport.releaseFirstWrite()
        }
        await transport.waitForCompletedWrites(2)
        await release.value
        try await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await transport.snapshot()
        let presentations = try snapshot.values.map {
            try $0.decoded(as: CardPresentationPreference.self)
        }
        XCTAssertEqual(snapshot.maxInFlight, 1, "writes must never overtake one another")
        XCTAssertEqual(
            presentations,
            [
                CardPresentationPreset.compact.presentation,
                CardPresentationPreset.artworkOnly.presentation,
            ]
        )
        XCTAssertFalse(preferences.isSaving, "saving ends only after the queue drains")
    }

    func testCardPresentationAndOutboxShareOneDurableCacheSnapshot() async throws {
        let suiteName = "ui-customization-card-cache-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-card-cache-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let transport = OrderedWriteProbe()
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let desired = CardPresentationPreset.artworkOnly.presentation

        preferences.setCardPresentation(desired)
        await transport.waitForStartedWrites(1)

        let cachedData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        let card = try XCTUnwrap(cache["cardPresentation"] as? [String: Any])
        let pending = try XCTUnwrap(cache["pendingSyncWrites"] as? [String: Any])
        XCTAssertEqual(card["poster_size"] as? String, "large")
        XCTAssertNotNil(pending[SettingKey.uiCardPresentation.rawValue])

        await transport.releaseFirstWrite()
        await transport.waitForCompletedWrites(1)
    }

    func testOfflineWriteIsDurablyReplayedBeforeEffectiveRefresh() async throws {
        let suiteName = "ui-customization-outbox-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-outbox-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = RecoveringWriteProbe()
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let desired = CardPresentationPreset.artworkOnly.presentation

        offline.setCardPresentation(desired)
        await transport.waitForPutAttempts(1)
        await transport.setOnline()

        // A fresh store proves the failed write was journaled in the cache,
        // not merely retained by the first in-memory instance.
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(restarted.cardPresentation, desired)

        await restarted.refresh()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.events, ["put-failed", "put-succeeded", "effective"])
        XCTAssertEqual(snapshot.mutationIds.count, 2)
        XCTAssertEqual(
            Set(snapshot.mutationIds).count,
            1,
            "a connectivity retry must reuse the original idempotency key"
        )
        XCTAssertEqual(snapshot.storedPresentation, desired)
        XCTAssertEqual(restarted.cardPresentation, desired)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testUnavailableOrOldCapabilitiesDoNotDrainRevisionFiveOutbox() async throws {
        let suiteName = "ui-customization-capability-gate-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-capability-gate-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let transport = CapabilityGateProbe(
            capabilities: .failed(.transport(description: "offline"))
        )
        let desired = CardPresentationPreset.artworkOnly.presentation
        let authored = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        authored.setCardPresentation(desired)
        let customMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.forYou),
        ])
        authored.setPrimaryMenuItems(customMenu.items)
        await transport.waitForPutAttempts(2)

        let unavailable = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await unavailable.refresh()

        var snapshot = await transport.snapshot()
        XCTAssertEqual(unavailable.capabilityState, .unavailable)
        XCTAssertEqual(unavailable.supportProjection, .unknown)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, desired)
        XCTAssertEqual(unavailable.primaryMenu, customMenu)
        XCTAssertEqual(snapshot.putAttempts, 2)
        XCTAssertEqual(snapshot.effectiveReads, 0)

        await transport.setCapabilities(.serverUpgradeRequired)
        await unavailable.refresh()

        snapshot = await transport.snapshot()
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(snapshot.putAttempts, 2, "a known old server must not receive the outbox")
        XCTAssertEqual(snapshot.effectiveReads, 0)

        await transport.setCapabilities(.available(testCapabilities(batchedEffective: false)))
        await unavailable.refresh()

        snapshot = await transport.snapshot()
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertFalse(unavailable.hasExplicitPrimaryMenu)
        XCTAssertEqual(
            snapshot.putAttempts,
            2,
            "the client must not use a multi-key read when the server does not advertise it"
        )
        XCTAssertEqual(snapshot.effectiveReads, 0)

        await transport.setCapabilities(.failed(.transport(description: "offline again")))
        await unavailable.refresh()

        snapshot = await transport.snapshot()
        XCTAssertEqual(unavailable.capabilityState, .unavailable)
        XCTAssertEqual(
            unavailable.supportProjection,
            .knownUnsupported,
            "a later transient probe failure must not forget an explicit incompatibility"
        )
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(snapshot.putAttempts, 2)
        XCTAssertEqual(snapshot.effectiveReads, 0)

        let restartedKnownUnsupported = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await restartedKnownUnsupported.refresh()
        XCTAssertEqual(restartedKnownUnsupported.capabilityState, .unavailable)
        XCTAssertEqual(restartedKnownUnsupported.supportProjection, .knownUnsupported)
        XCTAssertEqual(restartedKnownUnsupported.cardPresentation, .standard)
        XCTAssertNil(restartedKnownUnsupported.primaryMenu)

        await transport.setCapabilities(.available(testCapabilities(idempotentWrites: false)))
        await unavailable.refresh()

        snapshot = await transport.snapshot()
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(
            snapshot.putAttempts,
            2,
            "an outbox must not replay when the server cannot deduplicate an ambiguous retry"
        )
        XCTAssertEqual(snapshot.effectiveReads, 0)
    }

    func testProfileClientCardResetIsDurableAndResolvesInheritedValueAfterRestart() async throws {
        let suiteName = "ui-customization-card-reset-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-card-reset-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let transport = RecoveringDeleteProbe()
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )

        await preferences.refresh()
        XCTAssertTrue(preferences.cardPresentationUsesFamilyOverride)
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreset.compact.presentation)

        await transport.clearEvents()
        preferences.resetCardPresentationToInherited()
        await transport.waitForDeleteAttempts(1)
        await transport.setDeletesOnline()

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await restarted.refresh()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.events, ["delete-failed", "delete-succeeded", "effective"])
        XCTAssertEqual(snapshot.deleteScopes, [.profileClient, .profileClient])
        XCTAssertEqual(restarted.cardPresentation, .standard)
        XCTAssertFalse(restarted.cardPresentationUsesFamilyOverride)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testQueuedWriteNeverFollowsAChangedServerProfileIdentity() async throws {
        let suiteName = "ui-customization-identity-race-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-identity-race-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let identity = MutableRequestIdentity(testRequestIdentity(family: "mobile"))
        let transport = OrderedWriteProbe()
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { testCacheKey(for: identity.value) },
            requestIdentity: { identity.value },
            initialCapabilityState: .supported
        )

        preferences.setCardPresentation(CardPresentationPreset.compact.presentation)
        preferences.setCardPresentation(CardPresentationPreset.artworkOnly.presentation)
        await transport.waitForStartedWrites(1)

        identity.value = HTTPRequestIdentity(
            serverId: "server-b",
            serverURL: "http://server-b.invalid",
            profileId: "profile-b",
            clientFamily: "mobile"
        )
        await transport.releaseFirstWrite()
        try await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.identities, [testRequestIdentity(family: "mobile")])
        XCTAssertEqual(
            snapshot.values.count,
            1,
            "queued work for the old cache must be retained, not sent through the new identity"
        )
        XCTAssertFalse(preferences.isSaving)
    }

    func testRefreshPreservesHigherPrecedenceDeviceOverrideSource() async throws {
        let suiteName = "ui-customization-source-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-source-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let menu = PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies)])
        let response = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(menu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(CardPresentationPreset.compact.presentation),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
            ],
            revision: SettingKey.revision
        )
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: UICustomizationTransportStub(result: .success(response)),
            cacheKey: { "vivid.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )

        await preferences.refresh()

        XCTAssertTrue(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertTrue(preferences.hasDeviceOverrides)
    }

    func testSuccessfulDeviceDeleteReconcilesWhenSiblingFailsAndOnlyFailureReplays() async throws {
        let suiteName = "ui-customization-partial-device-delete-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-partial-device-delete-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "vivid.uiCustomization.server.profile.tv"
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = DeviceOverrideDeleteProbe(deleteFailureKey: .navPrimaryMenu)
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        XCTAssertTrue(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)

        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.primaryMenuUsesDeviceOverride,
            "the failed device delete must keep its effective value and source"
        )
        XCTAssertFalse(
            preferences.cardPresentationUsesDeviceOverride,
            "the successful sibling must reconcile even while another delete remains pending"
        )
        XCTAssertEqual(preferences.cardPresentation, .standard)
        XCTAssertNotNil(preferences.syncErrorMessage)

        var snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.deleteKeys, [.navPrimaryMenu, .uiCardPresentation])
        XCTAssertEqual(snapshot.targetedReadKeys, [.uiCardPresentation])

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        snapshot = await transport.snapshot()
        XCTAssertEqual(
            snapshot.deleteKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu],
            "restart must replay only the failed device delete"
        )
        XCTAssertFalse(restarted.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(restarted.cardPresentation, .standard)
    }

    func testDeviceDeleteReadFailureRemainsDurableUntilRestartReconcilesIt() async throws {
        let suiteName = "ui-customization-device-delete-read-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-device-delete-read-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "vivid.uiCustomization.server.profile.tv"
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = DeviceOverrideDeleteProbe(
            targetedReadFailureKey: .navPrimaryMenu
        )
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.primaryMenuUsesDeviceOverride,
            "a successful delete without its inherited value must retain the safe cached pair"
        )
        XCTAssertFalse(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(preferences.syncErrorMessage)

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(
            snapshot.deleteKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu],
            "only the delete whose effective read failed remains in the durable outbox"
        )
        XCTAssertEqual(
            snapshot.targetedReadKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu]
        )
        XCTAssertFalse(restarted.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(restarted.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(
            restarted.primaryMenu,
            PrimaryMenuPreference(items: [.builtin(.home), .builtin(.series)])
        )
        XCTAssertEqual(restarted.cardPresentation, .standard)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testRefreshReconcilesValidKeysAndPreservesEachInvalidValueAndSource() async throws {
        let suiteName = "ui-customization-independent-decode-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-independent-decode-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let originalMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
        ])
        let updatedMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.series),
        ])
        let initialResponse = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(originalMenu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreset.compact.presentation
                    ),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
            ],
            revision: SettingKey.revision
        )
        let transport = MutableEffectiveValuesProbe(response: initialResponse)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()

        await transport.setResponse(EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(updatedMenu),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: .object([
                        "poster_size": .string("future-size"),
                        "caption": .string("title"),
                    ]),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
            ],
            revision: SettingKey.revision
        ))
        await preferences.refresh()

        XCTAssertEqual(preferences.primaryMenu, updatedMenu)
        XCTAssertFalse(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreset.compact.presentation)
        XCTAssertTrue(
            preferences.cardPresentationUsesDeviceOverride,
            "a failed decode must retain the matching prior source with its prior value"
        )
        XCTAssertNotNil(preferences.syncErrorMessage)

        let invalidMenu = PrimaryMenuPreference(items: [.builtin(.movies)])
        await transport.setResponse(EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(invalidMenu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreset.artworkOnly.presentation
                    ),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
            ],
            revision: SettingKey.revision
        ))
        await preferences.refresh()

        XCTAssertEqual(preferences.primaryMenu, updatedMenu)
        XCTAssertFalse(
            preferences.primaryMenuUsesDeviceOverride,
            "an invalid menu must not pair its source with the previous valid menu"
        )
        XCTAssertEqual(
            preferences.cardPresentation,
            CardPresentationPreset.artworkOnly.presentation
        )
        XCTAssertFalse(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(preferences.syncErrorMessage)

        let cached = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(cached.primaryMenu, updatedMenu)
        XCTAssertEqual(cached.cardPresentation, CardPresentationPreset.artworkOnly.presentation)
        XCTAssertFalse(cached.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(cached.cardPresentationUsesDeviceOverride)
    }

    func testRefreshReconcilesTheFamilyScopedCacheAndOfflineRestoreKeepsIt() async throws {
        let suiteName = "ui-customization-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.forYou),
        ])
        let cards = CardPresentationPreference(posterSize: .large, caption: .artwork)
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(.navPrimaryMenu, menu, scope: .profileClient),
                try effective(.uiCardPresentation, cards, scope: .profileClient),
            ],
            revision: SettingKey.revision
        )
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "vivid.uiCustomization.server.profile.mobile"
        let online = UICustomizationPreferences(
            defaults: defaults,
            transport: UICustomizationTransportStub(result: .success(response)),
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        await online.refresh()

        XCTAssertEqual(online.primaryMenu, menu)
        XCTAssertEqual(online.cardPresentation, cards)
        XCTAssertNil(online.syncErrorMessage)

        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: UICustomizationTransportStub(result: .failure(URLError(.notConnectedToInternet))),
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(offline.primaryMenu, menu)
        XCTAssertEqual(offline.cardPresentation, cards)

        await offline.refresh()

        XCTAssertEqual(offline.primaryMenu, menu, "a failed refresh must not erase the cached menu")
        XCTAssertEqual(offline.cardPresentation, cards)
        XCTAssertNotNil(offline.syncErrorMessage)
    }

    private func effective<T: Encodable>(
        _ key: SettingKey,
        _ value: T,
        scope: SettingScope
    ) throws -> EffectiveSettingValue {
        EffectiveSettingValue(
            key: key.rawValue,
            value: try SettingJSONValue.encoding(value),
            source: .scope(scope),
            scope: scope,
            profileId: "profile",
            clientFamily: scope == .profileClient ? "mobile" : nil
        )
    }
}

private func testRequestIdentity(family: String) -> HTTPRequestIdentity {
    HTTPRequestIdentity(
        serverId: "server",
        serverURL: "http://settings-test.invalid",
        profileId: "profile",
        clientFamily: family
    )
}

private func testRequestIdentity(for cacheKey: String) -> HTTPRequestIdentity {
    testRequestIdentity(family: cacheKey.split(separator: ".").last.map(String.init) ?? "mobile")
}

private func testCacheKey(for identity: HTTPRequestIdentity) -> String {
    "vivid.uiCustomization.\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
}

private func testCapabilities(
    batchedEffective: Bool = true,
    idempotentWrites: Bool = true,
    atomicShortcuts: Bool = true
) -> SettingsContractCapabilities {
    SettingsContractCapabilities(
        apiVersion: 1,
        revision: SettingKey.revision,
        contractEtag: "test",
        definitionCount: 3,
        scopes: ["profile", "profile_client", "profile_device"],
        supportsBatchedEffective: batchedEffective,
        supportsIdempotentWrites: idempotentWrites,
        supportsAtomicShortcuts: atomicShortcuts
    )
}

private func completeCustomizationEffectiveResponse(
    keys: [SettingKey],
    settings: [EffectiveSettingValue]
) throws -> EffectiveSettingValuesResponse {
    var completed = settings
    let presentKeys = Set(settings.compactMap(\.settingKey))
    for key in keys where !presentKeys.contains(key) {
        let value: SettingJSONValue
        switch key {
        case .navPrimaryMenu:
            value = .null
        case .uiCardPresentation:
            value = try SettingJSONValue.encoding(CardPresentationPreference.standard)
        default:
            continue
        }
        completed.append(EffectiveSettingValue(
            key: key.rawValue,
            value: value,
            source: .contractDefault,
            profileId: "profile"
        ))
    }
    return EffectiveSettingValuesResponse(
        settings: completed,
        revision: SettingKey.revision
    )
}

private final class MutableRequestIdentity: @unchecked Sendable {
    var value: HTTPRequestIdentity

    init(_ value: HTTPRequestIdentity) {
        self.value = value
    }
}

private protocol CurrentCapabilitiesTransport: UICustomizationTransport {}

private extension CurrentCapabilitiesTransport {
    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        .available(testCapabilities())
    }
}

private final class UICustomizationTransportStub: CurrentCapabilitiesTransport, @unchecked Sendable {
    private let result: Result<EffectiveSettingValuesResponse, Error>

    init(result: Result<EffectiveSettingValuesResponse, Error>) {
        self.result = result
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try result.get()
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {}
}

private actor CapabilityGateProbe: UICustomizationTransport {
    private var capabilities: SettingsCapabilitiesResult
    private var putAttempts = 0
    private var effectiveReads = 0
    private var putWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(capabilities: SettingsCapabilitiesResult) {
        self.capabilities = capabilities
    }

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        capabilities
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        effectiveReads += 1
        return EffectiveSettingValuesResponse(settings: [], revision: SettingKey.revision)
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        putAttempts += 1
        let ready = putWaiters.filter { putAttempts >= $0.0 }
        putWaiters.removeAll { putAttempts >= $0.0 }
        ready.forEach { $0.1.resume() }
        throw URLError(.notConnectedToInternet)
    }

    func waitForPutAttempts(_ count: Int) async {
        guard putAttempts < count else { return }
        await withCheckedContinuation { continuation in
            putWaiters.append((count, continuation))
        }
    }

    func setCapabilities(_ capabilities: SettingsCapabilitiesResult) {
        self.capabilities = capabilities
    }

    func snapshot() -> (putAttempts: Int, effectiveReads: Int) {
        (putAttempts, effectiveReads)
    }
}

private actor MutableEffectiveValuesProbe: CurrentCapabilitiesTransport {
    private var response: EffectiveSettingValuesResponse

    init(response: EffectiveSettingValuesResponse) {
        self.response = response
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        response
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {}

    func setResponse(_ response: EffectiveSettingValuesResponse) {
        self.response = response
    }
}

private actor DeviceOverrideDeleteProbe: CurrentCapabilitiesTransport {
    private let deleteFailureKey: SettingKey?
    private let targetedReadFailureKey: SettingKey?
    private var didFailTargetedRead = false
    private var deviceOverrideKeys: Set<SettingKey> = [
        .navPrimaryMenu,
        .uiCardPresentation,
    ]
    private var deleteKeys: [SettingKey] = []
    private var targetedReadKeys: [SettingKey] = []

    init(
        deleteFailureKey: SettingKey? = nil,
        targetedReadFailureKey: SettingKey? = nil
    ) {
        self.deleteFailureKey = deleteFailureKey
        self.targetedReadFailureKey = targetedReadFailureKey
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        if keys.count == 1, let key = keys.first {
            targetedReadKeys.append(key)
            if key == targetedReadFailureKey, !didFailTargetedRead {
                didFailTargetedRead = true
                throw URLError(.notConnectedToInternet)
            }
        }
        var settings: [EffectiveSettingValue] = []
        for key in keys {
            if let value = try effectiveValue(for: key) {
                settings.append(value)
            }
        }
        return EffectiveSettingValuesResponse(
            settings: settings,
            revision: SettingKey.revision
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {}

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        deleteKeys.append(key)
        if key == deleteFailureKey {
            throw URLError(.notConnectedToInternet)
        }
        guard deviceOverrideKeys.remove(key) != nil else {
            throw SettingsAPIError.noValueAtScope
        }
    }

    func snapshot() -> (deleteKeys: [SettingKey], targetedReadKeys: [SettingKey]) {
        (deleteKeys, targetedReadKeys)
    }

    private func effectiveValue(for key: SettingKey) throws -> EffectiveSettingValue? {
        switch key {
        case .navPrimaryMenu:
            let hasDeviceOverride = deviceOverrideKeys.contains(key)
            let menu = PrimaryMenuPreference(items: [
                .builtin(.home),
                .builtin(hasDeviceOverride ? .movies : .series),
            ])
            return EffectiveSettingValue(
                key: key.rawValue,
                value: try SettingJSONValue.encoding(menu),
                source: .scope(hasDeviceOverride ? .profileDevice : .profileClient),
                scope: hasDeviceOverride ? .profileDevice : .profileClient,
                profileId: "profile",
                clientFamily: hasDeviceOverride ? nil : "tv",
                deviceId: hasDeviceOverride ? "device" : nil
            )
        case .uiCardPresentation:
            let hasDeviceOverride = deviceOverrideKeys.contains(key)
            let presentation = hasDeviceOverride
                ? CardPresentationPreset.compact.presentation
                : CardPresentationPreference.standard
            return EffectiveSettingValue(
                key: key.rawValue,
                value: try SettingJSONValue.encoding(presentation),
                source: hasDeviceOverride
                    ? .scope(.profileDevice)
                    : .contractDefault,
                scope: hasDeviceOverride ? .profileDevice : nil,
                profileId: "profile",
                deviceId: hasDeviceOverride ? "device" : nil
            )
        default:
            return nil
        }
    }
}

private actor RecoveringDeleteProbe: CurrentCapabilitiesTransport {
    private var deletesOnline = false
    private var familyRowPresent = true
    private var deleteAttempts = 0
    private var deleteScopes: [SettingScopeIdentity] = []
    private var events: [String] = []
    private var deleteWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        events.append("effective")
        let presentation = familyRowPresent
            ? CardPresentationPreset.compact.presentation
            : CardPresentationPreference.standard
        return try completeCustomizationEffectiveResponse(
            keys: keys,
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(presentation),
                    source: familyRowPresent ? .scope(.profileClient) : .contractDefault,
                    scope: familyRowPresent ? .profileClient : nil,
                    profileId: "profile",
                    clientFamily: familyRowPresent ? "mobile" : nil
                ),
            ]
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {}

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        deleteAttempts += 1
        deleteScopes.append(scope)
        let ready = deleteWaiters.filter { deleteAttempts >= $0.0 }
        deleteWaiters.removeAll { deleteAttempts >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard deletesOnline else {
            events.append("delete-failed")
            throw URLError(.notConnectedToInternet)
        }
        familyRowPresent = false
        events.append("delete-succeeded")
    }

    func waitForDeleteAttempts(_ count: Int) async {
        guard deleteAttempts < count else { return }
        await withCheckedContinuation { continuation in
            deleteWaiters.append((count, continuation))
        }
    }

    func setDeletesOnline() {
        deletesOnline = true
    }

    func clearEvents() {
        events.removeAll()
    }

    func snapshot() -> (events: [String], deleteScopes: [SettingScopeIdentity]) {
        (events, deleteScopes)
    }
}

private actor OrderedWriteProbe: CurrentCapabilitiesTransport {
    private var values: [SettingJSONValue] = []
    private var identities: [HTTPRequestIdentity] = []
    private var inFlight = 0
    private var maxInFlight = 0
    private var completedWrites = 0
    private var firstWriteReleased = false
    private var firstWriteGate: CheckedContinuation<Void, Never>?
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        EffectiveSettingValuesResponse(settings: [], revision: SettingKey.revision)
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        values.append(value)
        identities.append(requestIdentity)
        let ordinal = values.count
        resumeStartedWaiters()

        if ordinal == 1, !firstWriteReleased {
            await withCheckedContinuation { continuation in
                if firstWriteReleased {
                    continuation.resume()
                } else {
                    firstWriteGate = continuation
                }
            }
        }

        inFlight -= 1
        completedWrites += 1
        resumeCompletedWaiters()
    }

    func waitForStartedWrites(_ count: Int) async {
        guard values.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitForCompletedWrites(_ count: Int) async {
        guard completedWrites < count else { return }
        await withCheckedContinuation { continuation in
            completedWaiters.append((count, continuation))
        }
    }

    func releaseFirstWrite() {
        firstWriteReleased = true
        firstWriteGate?.resume()
        firstWriteGate = nil
    }

    func snapshot() -> (
        values: [SettingJSONValue],
        identities: [HTTPRequestIdentity],
        maxInFlight: Int
    ) {
        (values, identities, maxInFlight)
    }

    private func resumeStartedWaiters() {
        let ready = startedWaiters.filter { values.count >= $0.0 }
        startedWaiters.removeAll { values.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    private func resumeCompletedWaiters() {
        let ready = completedWaiters.filter { completedWrites >= $0.0 }
        completedWaiters.removeAll { completedWrites >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}

private actor RecoveringWriteProbe: CurrentCapabilitiesTransport {
    private var isOnline = false
    private var putAttempts = 0
    private var putWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var events: [String] = []
    private var mutationIds: [String] = []
    private var storedPresentation = CardPresentationPreference.standard

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        events.append("effective")
        return try completeCustomizationEffectiveResponse(
            keys: keys,
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(storedPresentation),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
            ]
        )
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        mutationId: String,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        putAttempts += 1
        mutationIds.append(mutationId)
        let ready = putWaiters.filter { putAttempts >= $0.0 }
        putWaiters.removeAll { putAttempts >= $0.0 }
        ready.forEach { $0.1.resume() }

        guard isOnline else {
            events.append("put-failed")
            throw URLError(.notConnectedToInternet)
        }
        if key == .uiCardPresentation {
            storedPresentation = try value.decoded(as: CardPresentationPreference.self)
        }
        events.append("put-succeeded")
    }

    func waitForPutAttempts(_ count: Int) async {
        guard putAttempts < count else { return }
        await withCheckedContinuation { continuation in
            putWaiters.append((count, continuation))
        }
    }

    func setOnline() {
        isOnline = true
    }

    func snapshot() -> (
        events: [String],
        mutationIds: [String],
        storedPresentation: CardPresentationPreference
    ) {
        (events, mutationIds, storedPresentation)
    }
}

private actor RetiredNavigationProbe: UICustomizationTransport {
    private var keys: [SettingKey] = []
    private var writes = 0
    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        .available(testCapabilities(atomicShortcuts: false))
    }
    func effectiveValues(keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        self.keys = keys
        return try completeCustomizationEffectiveResponse(keys: keys, settings: [])
    }
    func putValue(key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue, mutationId: String, requestIdentity: HTTPRequestIdentity) async throws {
        writes += 1
    }
    func snapshot() -> (keys: [SettingKey], writes: Int) { (keys, writes) }
}
