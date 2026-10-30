#if os(tvOS)
import SwiftUI

extension TVSettingsView {
    /// Settings > General on Apple TV: language, theme, Home, posters and
    /// the tab bar.
    struct GeneralPane: View {
        let focus: FocusState<Focus?>.Binding

        @State private var language = VividAppLanguage.saved
        @State private var reopenLanguage: VividAppLanguage = .system
        @State private var showsReopen = false
        @AppStorage(VividAppTheme.storageKey) private var theme: VividAppTheme = .graphite
        @State private var preferences = UICustomizationPreferences.shared
        @State private var sections = HomeSectionPreferences.shared
        @State private var studios = StudiosNetworksStore.shared
        @State private var collections = HomeCollectionsStore.shared
        @State private var tmdb = TVTMDbStore.shared
        @State private var cards = TVHomeCardPreferences.shared
        @State private var registry = ServerRegistry.shared
        @State private var snapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
        @State private var showsHomeScreen = false
        @State private var showsStudios = false
        @State private var showsHomeSections = false
        @State private var showsCollections = false
        @State private var showsTabBar = false
        @Environment(\.scenePhase) private var scenePhase

        private var provider: MediaServerProvider { MediaServerProvider.forServerID(registry.activeServerId) }

        private var authority: MainTabLibraryAuthority? {
            MainTabLibraryAuthority(serverId: registry.activeServerId, profileId: registry.activeProfileId)
        }

        private var libraries: [Library] { snapshot.availableLibraries(for: authority) }

        private var languageOptions: [MenuOption] {
            VividAppLanguage.allCases.map {
                MenuOption(id: $0.rawValue, label: $0 == .system ? String(localized: "System") : $0.nativeName ?? $0.rawValue)
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: TVSettingsLayout.scaled(8)) {
                TVSettingsSectionHeader("LANGUAGE")
                TVSettingsGroup {
                    OptionMenu(title: "Language", detail: "Vivid follows this Apple TV’s language unless you choose one.",
                               value: TVSettingsView.optionLabel(languageOptions, language.rawValue),
                               options: languageOptions, selection: language.rawValue, choose: chooseLanguage)
                        .focused(focus, equals: .generalLanguage)
                }
                TVSettingsFooter("A new choice takes effect after you close Vivid in the app switcher and open it again.")
                TVSettingsSectionHeader("THEMES")
                TVSettingsGroup {
                    OptionMenu(title: "Theme", value: theme.title,
                               options: VividAppTheme.allCases.map { MenuOption(id: $0.rawValue, label: $0.title) },
                               selection: theme.rawValue) { id in
                        if let choice = VividAppTheme(rawValue: id) { theme = choice }
                    }
                    .focused(focus, equals: .theme)
                }
                TVSettingsFooter("Graphite uses the charcoal background, Black uses solid black, and Native removes Vivid’s background and uses the system appearance.")
                homeScreenGroup
                if preferences.capabilityState != .checking, let message = preferences.capabilityMessage {
                    TVSettingsSectionHeader("SERVER SUPPORT")
                    TVSettingsFooter(message)
                }
                TVSettingsSectionHeader("POSTER CONFIGURATION")
                TVSettingsGroup {
                    OptionMenu(title: "Captions", value: cards.presentation.caption.title,
                               options: CardCaptionStyle.allCases.map { MenuOption(id: $0.rawValue, label: $0.title) },
                               selection: cards.presentation.caption.rawValue) { id in
                        if let caption = CardCaptionStyle(rawValue: id) { cards.setCaptionStyle(caption) }
                    }
                    Button { cards.reset() } label: { TVSettingsRowLabel(title: "Use Profile Default") }
                        .buttonStyle(TVSettingsPaneRowStyle())
                }
                TVSettingsSectionHeader("TAB BAR")
                TVSettingsGroup {
                    Button { showsTabBar = true } label: {
                        HStack(spacing: TVSettingsLayout.scaled(16)) {
                            TVSettingsRowLabel(title: "Customise Tab Bar")
                            Spacer(minLength: TVSettingsLayout.scaled(16))
                            Text("\(tabBarItemCount) items")
                                .font(.tvSettings(24))
                                .opacity(0.68)
                            chevron
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused(focus, equals: .customiseTabBar)
                    .disabled(!preferences.allowsEditing)
                }
                if let error = preferences.syncErrorMessage, error != preferences.capabilityMessage {
                    TVSettingsFooter(error)
                }
            }
            .navigationDestination(isPresented: $showsHomeScreen) { HomeScreenPage() }
            .navigationDestination(isPresented: $showsStudios) { TVStudiosNetworksSettingsView() }
            .navigationDestination(isPresented: $showsHomeSections) { HomeSectionsEditorPage() }
            .navigationDestination(isPresented: $showsCollections) { TVHomeCollectionsSettingsView() }
            .navigationDestination(isPresented: $showsTabBar) { TabBarEditorPage(libraries: libraries) }
            .onAppear {
                sections.refresh()
                tmdb.reloadForCurrentProfile()
                studios.refresh()
                collections.refresh()
            }
            .onChange(of: registry.activeServerId) {
                sections.refresh()
                collections.refresh()
            }
            .task { await preferences.refresh() }
            .task(id: authority) { await refreshLibraries(for: authority) }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let current = authority
                Task {
                    async let menu: Void = preferences.refresh()
                    async let shelves: Void = refreshLibraries(for: current)
                    _ = await (menu, shelves)
                }
            }
            .tvSystemAlert("Reopen Vivid", isPresented: $showsReopen, message: reopenMessage, buttons: [.cancel("OK")])
        }

        private var homeScreenGroup: some View {
            Group {
                TVSettingsSectionHeader("HOME SCREEN")
                TVSettingsGroup {
                    Button { showsHomeScreen = true } label: {
                        PickerRowLabel(title: "Spotlight", value: Text("Discovery Spotlight"))
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused(focus, equals: .spotlight)
                    Button { showsStudios = true } label: {
                        PickerRowLabel(title: "Studios & Networks",
                                       value: Text(!tmdb.isConfigured ? "Needs sign-in" : studios.isEnabled ? "On" : "Off"))
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    Button { showsHomeSections = true } label: {
                        HStack(spacing: TVSettingsLayout.scaled(16)) {
                            TVSettingsRowLabel(title: "Home Sections")
                            Spacer(minLength: TVSettingsLayout.scaled(16))
                            chevron
                        }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused(focus, equals: .homeSections)
                    Button { showsCollections = true } label: {
                        PickerRowLabel(title: "Collections", value: Text(collections.isEnabled ? "On" : "Off"))
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused(focus, equals: .collections)
                    if provider == .emby {
                        TVSettingsToggleRow(title: "Combine Next Up with Continue Watching", isOn: sections.combineEmbyNextUp) {
                            sections.setCombineEmbyNextUp(!sections.combineEmbyNextUp)
                        }
                    } else if provider == .jellyfin {
                        TVSettingsToggleRow(title: "Combine Next Up with Continue Watching", isOn: sections.combineJellyfinNextUp) {
                            sections.setCombineJellyfinNextUp(!sections.combineJellyfinNextUp)
                        }
                    }
                }
            }
        }

        private var chevron: some View {
            Image(systemName: "chevron.right")
                .font(.tvSettings(18, weight: .semibold))
                .opacity(0.55)
        }

        private var tabBarItemCount: Int {
            TVSettingsView.tabBarItems(preferences.resolvedPrimaryMenuItems(), libraries: libraries).count
        }

        private var reopenMessage: LocalizedStringResource {
            if reopenLanguage == .system {
                return "Vivid will use this Apple TV’s language the next time it opens. Press the TV button twice, swipe up on Vivid, then open it again."
            }
            let name = reopenLanguage.nativeName ?? ""
            return "Vivid will use \(name) the next time it opens. Press the TV button twice, swipe up on Vivid, then open it again."
        }

        private func chooseLanguage(_ id: String) {
            guard let choice = VividAppLanguage(rawValue: id) else { return }
            language = choice
            VividAppLanguage.save(choice)
            if VividAppLanguage.needsReopen(for: choice) {
                reopenLanguage = choice
                showsReopen = true
            }
        }

        /// Keeps libraries only for the server and profile they belong to,
        /// then fetches that profile's libraries.
        private func refreshLibraries(for authority: MainTabLibraryAuthority?) async {
            if snapshot.authority != authority {
                snapshot = MainTabLibrarySnapshot(authority: authority, libraries: [])
            }
            guard let authority else { return }
            guard let response = try? await StartupContentPrefetcher.fetchUserLibraries(),
                  !Task.isCancelled, self.authority == authority else { return }
            snapshot = MainTabLibrarySnapshot(authority: authority, libraries: response.libraries)
        }
    }

    /// The tab bar items the Apple TV editor and its count show: built-in
    /// destinations only, with Movies and Series only when a matching
    /// library exists.
    static func tabBarItems(_ items: [PrimaryMenuItem], libraries: [Library]) -> [PrimaryMenuItem] {
        items.filter { tabBarShows($0, libraries: libraries) }
    }

    static func tabBarShows(_ item: PrimaryMenuItem, libraries: [Library]) -> Bool {
        switch item {
        case .builtin(.home), .builtin(.forYou): true
        case .builtin(.movies): libraries.contains { TVLibraryTabType.movies.matches($0) }
        case .builtin(.series): libraries.contains { TVLibraryTabType.series.matches($0) }
        default: false
        }
    }
}
#endif
